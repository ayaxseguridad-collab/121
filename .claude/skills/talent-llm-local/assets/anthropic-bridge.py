#!/usr/bin/env python3
"""
Puente Anthropic Messages API -> {api.anthropic.com | vLLM local}.

Objetivo: que Claude Code liste en /model tanto los modelos de Anthropic
(servidos con la suscripcion de claude.ai, intactos) como el modelo local.

Reglas no negociables para la rama Anthropic (doc oficial del gateway protocol):
  - Passthrough CRUDO: no se toca Authorization, anthropic-beta ni anthropic-version.
  - El array `system` viaja byte a byte (si se reordena se pierde el prompt caching).
  - Los errores del upstream se reenvian sin envolver (la logica de reintento
    de Claude Code hace match sobre el texto del error).
  - El streaming es pasante, sin bufferizar (bufferizar cuelga al cliente).

Config por entorno:
  BRIDGE_ADDR        (default 127.0.0.1)
  BRIDGE_PORT        (default 8787)
  LOCAL_MODEL_ID     (default qwen3.6-35b-local)  id que se desvia a vLLM
  VLLM_URL           (default http://127.0.0.1:8000)
  VLLM_MODEL         (default claude-qwen-local)  nombre servido por vLLM
  VLLM_API_KEY       (obligatoria; sin valor por defecto)
  ENABLE_THINKING    (default 0)  el razonamiento del modelo se gasta tokens del
                     presupuesto y ademas filtra tool calls a texto en Qwen3
                     (vllm-project/vllm#42021). Con 1, se emite como bloque
                     `thinking` de Anthropic en vez de perderse.
"""
import http.client
import json
import os
import sys
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDR = os.environ.get("BRIDGE_ADDR", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "8787"))
LOCAL_ID = os.environ.get("LOCAL_MODEL_ID", "qwen3.6-35b-local")
VLLM = urllib.parse.urlparse(os.environ.get("VLLM_URL", "http://127.0.0.1:8000"))
VLLM_MODEL = os.environ.get("VLLM_MODEL", "claude-qwen-local")
# Sin clave por defecto: se genera al azar al montar y llega por el entorno de
# la unidad systemd. Si falta, el motor devolvera 401 y se vera enseguida.
VLLM_KEY = os.environ.get("VLLM_API_KEY", "")
THINKING = os.environ.get("ENABLE_THINKING", "0") not in ("0", "", "false", "no")
# Variante pensadora: mismo modelo con el razonamiento encendido. Se selecciona
# tecleando el id en /model (Claude Code no valida nombres tras un base URL propio).
# OJO: con thinking activo Qwen3 puede filtrar tool calls al texto (vLLM #42021) —
# usarla para analisis/razonamiento, no para trabajo con herramientas.
THINK_ID = os.environ.get("LOCAL_THINK_MODEL_ID", LOCAL_ID + "-think")
# Alias cortos para teclear en /model: `qwen` = rapida · `qwent` = pensadora.
FAST_IDS = {LOCAL_ID, "qwen"}
THINK_IDS = {THINK_ID, "qwent"}

UPSTREAM = "api.anthropic.com"
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}


# --------------------------------------------------------------------------
# Traduccion Anthropic Messages -> OpenAI chat/completions
# --------------------------------------------------------------------------

def _text_of(content):
    """Aplana un content Anthropic (str o lista de bloques) a texto."""
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if b.get("type") == "text":
            out.append(b.get("text", ""))
    return "".join(out)


def to_openai(req, thinking=False):
    msgs = []

    system = req.get("system")
    if system:
        msgs.append({"role": "system", "content": _text_of(system)})

    for m in req.get("messages", []):
        role, content = m.get("role"), m.get("content")

        # Claude Code emite mensajes `system` a mitad de conversacion (el gateway
        # protocol lo contempla); la plantilla de Qwen solo acepta system en la
        # posicion 0. Se degradan a turno de user marcado, que es el equivalente
        # que estos modelos entienden.
        if role not in ("user", "assistant"):
            txt = _text_of(content)
            if txt:
                msgs.append({"role": "user",
                             "content": f"<system-reminder>{txt}</system-reminder>"})
            continue

        if isinstance(content, str):
            msgs.append({"role": role, "content": content})
            continue

        # Un turno de assistant puede traer texto + varias tool_use.
        # Un turno de user puede traer tool_result, que en OpenAI son mensajes aparte.
        text_parts, tool_calls, tool_results = [], [], []
        reasoning_parts = []
        for b in content or []:
            t = b.get("type")
            if t == "text":
                text_parts.append(b.get("text", ""))
            elif t == "thinking":
                reasoning_parts.append(b.get("thinking", ""))
            elif t == "tool_use":
                tool_calls.append({
                    "id": b.get("id"),
                    "type": "function",
                    "function": {"name": b.get("name"),
                                 "arguments": json.dumps(b.get("input", {}))},
                })
            elif t == "tool_result":
                tool_results.append({
                    "role": "tool",
                    "tool_call_id": b.get("tool_use_id"),
                    "content": _text_of(b.get("content")) or "",
                })

        if role == "assistant":
            entry = {"role": "assistant", "content": "".join(text_parts) or None}
            if tool_calls:
                entry["tool_calls"] = tool_calls
            if reasoning_parts:
                # vLLM >=0.20 renombro el campo de ENTRADA a `reasoning` y descarta
                # `reasoning_content` en silencio; la plantilla Jinja lee el segundo.
                # Se mandan ambos para no depender de la version del servidor.
                joined = "".join(reasoning_parts)
                entry["reasoning"] = joined
                entry["reasoning_content"] = joined
            msgs.append(entry)
        else:
            # Los tool_result van primero: responden a la llamada previa.
            msgs.extend(tool_results)
            if text_parts:
                msgs.append({"role": "user", "content": "".join(text_parts)})

    think_on = thinking or THINKING
    max_tok = req.get("max_tokens", 4096)
    if think_on:
        max_tok = max(max_tok, THINK_MIN_TOKENS)

    oa_tools = None
    if req.get("tools"):
        oa_tools = [{"type": "function",
                     "function": {"name": t["name"],
                                  "description": t.get("description", ""),
                                  "parameters": t.get("input_schema", {})}}
                    for t in req["tools"]]

    ctk = {"enable_thinking": think_on, "preserve_thinking": think_on}
    n_in = count_input_tokens(msgs, ctk, oa_tools)
    hueco = MAX_MODEL_LEN - n_in - RESERVE
    # El hueco es un techo DURO: pedir mas desborda la ventana y vLLM devuelve
    # 400, incluido el /compact que sacaria del atasco. MIN_OUT es solo una
    # preferencia; jamas puede superar el hueco real (ese fue un bug propio:
    # el suelo de 1024 desbordaba por 1 token con prompts de ~130k).
    max_tok = max(1, min(max_tok, hueco))

    out = {
        "model": VLLM_MODEL,
        "messages": msgs,
        "max_tokens": max_tok,
        "stream": bool(req.get("stream")),
        # preserve_thinking mantiene el historial append-only: sin el, cada turno
        # nuevo del usuario borra los <think> previos, el prefijo diverge y se
        # re-prefilla todo. Es lo que Qwen entreno para uso agentico.
        "chat_template_kwargs": ctk,
        **SAMPLING[think_on],
    }
    # El cliente manda; el muestreo por modo es solo el default.
    for k in ("temperature", "top_p", "stop_sequences"):
        if k in req:
            out["stop" if k == "stop_sequences" else k] = req[k]

    if oa_tools:
        out["tools"] = oa_tools
        tc = req.get("tool_choice") or {}
        kind = tc.get("type")
        if kind == "tool" and tc.get("name"):
            out["tool_choice"] = {"type": "function", "function": {"name": tc["name"]}}
        elif kind == "any":
            out["tool_choice"] = "required"
        elif kind == "none":
            out["tool_choice"] = "none"
        else:
            out["tool_choice"] = "auto"

    if out["stream"]:
        out["stream_options"] = {"include_usage": True}
    return out


STOP_MAP = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use"}

# Muestreo oficial de Qwen por modo (model card de Qwen3.6-35B-A3B). Difieren:
# el rapido estrecha top_p a 0.80, y el perfil de codigo preciso pone
# presence_penalty a 0.0 (no 1.5). Como este puente sirve a Claude Code y a
# agentes de codigo, la variante pensante usa el perfil de codigo preciso.
SAMPLING = {
    False: {"temperature": 0.7, "top_p": 0.80, "top_k": 20,
            "presence_penalty": 1.5, "repetition_penalty": 1.0},
    True:  {"temperature": 0.6, "top_p": 0.95, "top_k": 20,
            "presence_penalty": 0.0, "repetition_penalty": 1.0},
}
# En modo pensante el razonamiento consume miles de tokens ANTES de la respuesta:
# con presupuestos bajos se agota dentro del <think> y no sale contenido
# (vllm#38894, sglang#27021). Se eleva el suelo.
THINK_MIN_TOKENS = int(os.environ.get("THINK_MIN_TOKENS", "6000"))

# Ventana del servidor (--max-model-len). Claude Code no la conoce y pide
# max_tokens fijos (32k), asi que en sesiones largas entrada+salida se pasa del
# limite y vLLM responde 400 — incluido el /compact, que es justo lo que sacaria
# de ese atasco. El puente recorta max_tokens al hueco real que queda.
MAX_MODEL_LEN = int(os.environ.get("MAX_MODEL_LEN", "131072"))
RESERVE = int(os.environ.get("CTX_RESERVE", "512"))       # margen de plantilla
MIN_OUT = int(os.environ.get("MIN_OUT_TOKENS", "1024"))   # suelo util para resumir


def count_input_tokens(msgs, kwargs, tools=None):
    """Cuenta exacta via /tokenize de vLLM; si falla, estimacion chars/4.

    Las `tools` DEBEN incluirse: Claude Code manda decenas de definiciones que
    pesan miles de tokens y van dentro del prompt renderizado.
    """
    try:
        payload = {"model": VLLM_MODEL, "messages": msgs,
                   "chat_template_kwargs": kwargs}
        if tools:
            payload["tools"] = tools
        body = json.dumps(payload).encode()
        c = http.client.HTTPConnection(VLLM.hostname, VLLM.port or 80, timeout=20)
        c.request("POST", "/tokenize", body,
                  {"Content-Type": "application/json",
                   "Authorization": f"Bearer {VLLM_KEY}"})
        d = json.load(c.getresponse())
        c.close()
        return int(d["count"])
    except Exception:
        return (len(json.dumps(msgs)) + len(json.dumps(tools or []))) // 4


def vllm_request(payload, stream):
    conn = http.client.HTTPConnection(VLLM.hostname, VLLM.port or 80, timeout=1800)
    conn.request("POST", "/v1/chat/completions", json.dumps(payload).encode(),
                 {"Content-Type": "application/json",
                  "Authorization": f"Bearer {VLLM_KEY}",
                  "Accept": "text/event-stream" if stream else "application/json"})
    return conn, conn.getresponse()


# --------------------------------------------------------------------------

class Bridge(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[bridge] {fmt % args}\n")

    # -- utilidades -------------------------------------------------------

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _sse_open(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def _sse(self, event, data):
        self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    # -- rama Anthropic: passthrough crudo --------------------------------

    def _passthrough(self, body):
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP}
        headers["Host"] = UPSTREAM
        if body:
            headers["Content-Length"] = str(len(body))

        # up se cierra SIEMPRE (finally), igual que conn en _local_stream/_local_blocking:
        # si el cliente aborta a mitad del relay (BrokenPipeError/ConnectionResetError, muy
        # comun con ESC en Claude Code) la conexion upstream no debe quedar abierta.
        up = http.client.HTTPSConnection(UPSTREAM, 443, timeout=1800)
        try:
            try:
                up.request(self.command, self.path, body, headers)
                r = up.getresponse()
            except Exception as e:
                self.log_message("upstream error: %s", e)
                self._json(502, {"type": "error",
                                 "error": {"type": "api_error", "message": str(e)}})
                return

            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()

            # Copia byte a byte, sin bufferizar: el SSE debe fluir segun llega.
            try:
                while True:
                    chunk = r.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        finally:
            up.close()

    # -- rama local: traduccion -------------------------------------------

    def _local_blocking(self, req, thinking=False):
        t0 = time.time()
        conn, r = vllm_request(to_openai(req, thinking), False)
        try:
            raw = r.read()
        finally:
            conn.close()
        if r.status != 200:
            self._json(r.status, {"type": "error",
                                  "error": {"type": "api_error",
                                            "message": raw.decode("utf-8", "replace")}})
            return
        d = json.loads(raw)
        ch = d["choices"][0]
        msg = ch.get("message", {})

        content = []
        # vLLM >=0.26 lo llama `reasoning`; versiones previas, `reasoning_content`.
        reasoning = msg.get("reasoning") or msg.get("reasoning_content")
        if reasoning:
            content.append({"type": "thinking", "thinking": reasoning,
                            "signature": ""})
        if msg.get("content"):
            content.append({"type": "text", "text": msg["content"]})
        for tc in msg.get("tool_calls") or []:
            fn = tc.get("function", {})
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            content.append({"type": "tool_use", "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:24]}",
                            "name": fn.get("name"), "input": args})

        u = d.get("usage", {})
        dt = time.time() - t0
        if dt > 0 and u.get("completion_tokens"):
            self.log_message("local: %d tok en %.1fs = %.1f tok/s",
                             u["completion_tokens"], dt, u["completion_tokens"] / dt)
        self._json(200, {
            "id": f"msg_{uuid.uuid4().hex[:24]}",
            "type": "message", "role": "assistant",
            "model": req.get("model", LOCAL_ID),
            "content": content,
            "stop_reason": STOP_MAP.get(ch.get("finish_reason"), "end_turn"),
            "stop_sequence": None,
            "usage": {"input_tokens": u.get("prompt_tokens", 0),
                      "output_tokens": u.get("completion_tokens", 0)},
        })

    def _local_stream(self, req, thinking=False):
        t0 = time.time()
        conn, r = vllm_request(to_openai(req, thinking), True)
        try:
            self._stream_body(req, conn, r, t0)
        finally:
            conn.close()

    # conn se cierra SIEMPRE en _local_stream (try/finally), aunque el cliente
    # aborte a mitad (BrokenPipeError) o self._sse falle: si no, la conexion al
    # motor queda abierta generando y agota max_num_seqs (ver gotcha 1).
    def _stream_body(self, req, conn, r, t0):
        if r.status != 200:
            raw = r.read()
            self._json(r.status, {"type": "error",
                                  "error": {"type": "api_error",
                                            "message": raw.decode("utf-8", "replace")}})
            return

        mid = f"msg_{uuid.uuid4().hex[:24]}"
        # Estimacion de entrada para message_start (el real de vLLM llega al FINAL
        # del stream, pero Anthropic lo manda al principio y el indicador de
        # contexto de Claude Code lo lee de aqui). Se corrige en message_delta.
        est_in = max(1, len(json.dumps(req.get("messages", []))
                            + json.dumps(req.get("system", ""))
                            + json.dumps(req.get("tools", ""))) // 4)
        self._sse_open()
        self._sse("message_start", {"type": "message_start", "message": {
            "id": mid, "type": "message", "role": "assistant",
            "model": req.get("model", LOCAL_ID), "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": est_in, "output_tokens": 0}}})

        idx = -1              # indice del bloque abierto
        open_kind = None      # "text" | "tool"
        tool_slots = {}       # indice OpenAI de tool_call -> indice de bloque Anthropic
        finish = "stop"
        usage = {"input_tokens": 0, "output_tokens": 0}

        def close_block():
            nonlocal open_kind
            if open_kind is not None:
                self._sse("content_block_stop", {"type": "content_block_stop", "index": idx})
                open_kind = None

        buf = b""
        while True:
            chunk = r.read(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line.startswith(b"data: "):
                    continue
                payload = line[6:]
                if payload == b"[DONE]":
                    continue
                try:
                    d = json.loads(payload)
                except json.JSONDecodeError:
                    continue

                if d.get("usage"):
                    usage = {"input_tokens": d["usage"].get("prompt_tokens", 0),
                             "output_tokens": d["usage"].get("completion_tokens", 0)}
                if not d.get("choices"):
                    continue
                c = d["choices"][0]
                if c.get("finish_reason"):
                    finish = c["finish_reason"]
                delta = c.get("delta") or {}

                r_delta = delta.get("reasoning") or delta.get("reasoning_content")
                if r_delta:
                    if open_kind != "thinking":
                        close_block()
                        idx += 1
                        open_kind = "thinking"
                        self._sse("content_block_start", {
                            "type": "content_block_start", "index": idx,
                            "content_block": {"type": "thinking", "thinking": ""}})
                    self._sse("content_block_delta", {
                        "type": "content_block_delta", "index": idx,
                        "delta": {"type": "thinking_delta", "thinking": r_delta}})

                if delta.get("content"):
                    if open_kind != "text":
                        close_block()
                        idx += 1
                        open_kind = "text"
                        self._sse("content_block_start", {
                            "type": "content_block_start", "index": idx,
                            "content_block": {"type": "text", "text": ""}})
                    self._sse("content_block_delta", {
                        "type": "content_block_delta", "index": idx,
                        "delta": {"type": "text_delta", "text": delta["content"]}})

                for tc in delta.get("tool_calls") or []:
                    slot = tc.get("index", 0)
                    fn = tc.get("function") or {}
                    if slot not in tool_slots:
                        close_block()
                        idx += 1
                        open_kind = "tool"
                        tool_slots[slot] = idx
                        self._sse("content_block_start", {
                            "type": "content_block_start", "index": idx,
                            "content_block": {"type": "tool_use",
                                              "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:24]}",
                                              "name": fn.get("name") or "", "input": {}}})
                    if fn.get("arguments"):
                        self._sse("content_block_delta", {
                            "type": "content_block_delta", "index": tool_slots[slot],
                            "delta": {"type": "input_json_delta",
                                      "partial_json": fn["arguments"]}})

        close_block()
        dt = time.time() - t0
        if dt > 0 and usage["output_tokens"]:
            self.log_message("local(stream): %d tok en %.1fs = %.1f tok/s",
                             usage["output_tokens"], dt, usage["output_tokens"] / dt)
        final_usage = {"output_tokens": usage["output_tokens"]}
        if usage["input_tokens"]:
            final_usage["input_tokens"] = usage["input_tokens"]  # el real, corrige el estimado
        self._sse("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": STOP_MAP.get(finish, "end_turn"),
                                              "stop_sequence": None},
                                    "usage": final_usage})
        self._sse("message_stop", {"type": "message_stop"})

    # -- rutas ------------------------------------------------------------

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        # Solo cortesia: con suscripcion el descubrimiento no se usa
        # (bug anthropics/claude-code#69116), el modelo entra por
        # ANTHROPIC_CUSTOM_MODEL_OPTION.
        if self.path.startswith("/v1/models"):
            self._json(200, {"data": [
                {"id": LOCAL_ID, "display_name": "Qwen3.6 35B (local)"},
                {"id": THINK_ID, "display_name": "Qwen3.6 35B (local, thinking)"}]})
        else:
            self._json(404, {"type": "error", "error": {"type": "not_found_error",
                                                        "message": "no encontrado"}})

    def do_POST(self):
        body = self._body()
        path = urllib.parse.urlparse(self.path).path

        if not path.startswith("/v1/messages"):
            self._passthrough(body)
            return

        try:
            req = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._passthrough(body)
            return

        model = req.get("model")
        if model not in FAST_IDS and model not in THINK_IDS:
            self._passthrough(body)      # Opus / Sonnet / Fable: intacto
            return
        thinking = model in THINK_IDS

        if path.endswith("/count_tokens"):
            # Heuristica chars/4 sobre la peticion ENTERA (system + tools + messages):
            # el indicador de contexto de Claude Code se alimenta de esto y de los
            # usage de las respuestas; contar solo messages lo dejaba en cero.
            approx = max(1, len(body) // 4)
            self._json(200, {"input_tokens": approx})
            return

        try:
            if req.get("stream"):
                self._local_stream(req, thinking)
            else:
                self._local_blocking(req, thinking)
        except BrokenPipeError:
            pass
        except Exception as e:
            self.log_message("error rama local: %s", e)
            try:
                self._json(500, {"type": "error",
                                 "error": {"type": "api_error", "message": str(e)}})
            except Exception:
                pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer((ADDR, PORT), Bridge)
    srv.daemon_threads = True
    print(f"[bridge] escuchando en http://{ADDR}:{PORT}", file=sys.stderr)
    print(f"[bridge] '{LOCAL_ID}' -> {VLLM.geturl()} ({VLLM_MODEL})", file=sys.stderr)
    print(f"[bridge] resto -> https://{UPSTREAM} (passthrough crudo)", file=sys.stderr)
    srv.serve_forever()
