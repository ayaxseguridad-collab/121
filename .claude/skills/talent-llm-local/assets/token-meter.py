#!/usr/bin/env python3
"""
Medidor de tokens por usuario delante de vLLM.

Proxy 127.0.0.1:8001 -> 127.0.0.1:8000 que AUTENTICA a los cinco usuarios,
atribuye el consumo a cada uno y expone GET /stats (JSON, sin auth, solo
loopback) para el visor de la barra.

El medidor es el unico que habla con el motor. Las claves de usuario viven aqui
(ALIAS_MAP, desde un fichero de entorno restringido) y NO en la linea de
arranque del motor: los argumentos de un proceso los ve cualquier usuario con
`ps`. Hacia el motor se reescribe la cabecera con UPSTREAM_KEY, una sola clave
interna.

- No bufferiza los streamings: relaya chunk a chunk y parsea el SSE al vuelo.
- En peticiones stream inyecta stream_options.include_usage=true para que el
  chunk final traiga el usage real (los clientes OpenAI lo toleran).
- El agregado y las tasas se calculan aqui con una ventana deslizante para que
  el visor sea tonto: solo pinta lo que /stats devuelve.

Config por entorno: METER_ADDR (127.0.0.1) · METER_PORT (8001) ·
UPSTREAM (http://127.0.0.1:8000) · UPSTREAM_KEY (clave interna del motor) · ALIAS_MAP (nombre legible por
clave, "clave=nombre;clave=nombre") · HIST_DIR (historico; ~/llm-local/history).
Ninguna clave viene por defecto: se generan al azar al montar.
"""
import collections
import http.client
import json
import os
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDR = os.environ.get("METER_ADDR", "127.0.0.1")
PORT = int(os.environ.get("METER_PORT", "8001"))
UP = urllib.parse.urlparse(os.environ.get("UPSTREAM", "http://127.0.0.1:8000"))
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}

# Nombre legible por clave. Llega del entorno porque las claves son aleatorias por
# maquina:  ALIAS_MAP="sk-xxxx=tu sesion;sk-yyyy=hermes-1;..."
# Una clave sin alias se muestra recortada, nunca entera: este JSON acaba en pantalla.
ALIAS = {}
for _par in os.environ.get("ALIAS_MAP", "").split(";"):
    if "=" in _par:
        _k, _v = _par.split("=", 1)
        _k, _v = _k.strip(), _v.strip()
        if _k:
            ALIAS[_k] = _v


def alias_de(k):
    return ALIAS.get(k) or (k[:6] + "…" + k[-4:] if len(k) > 12 else "desconocida")


# El medidor AUTENTICA. Las claves de los cinco usuarios viven aqui y no en la linea
# de arranque del motor: un argumento de proceso lo ve cualquier usuario con `ps`, y
# eso tiraria por tierra la atribucion por usuario (cualquiera podria suplantar a
# cualquiera). El motor detras lleva UNA sola clave interna, que nunca sale de su
# fichero de entorno.
AUTORIZADAS = set(ALIAS)
UPSTREAM_KEY = os.environ.get("UPSTREAM_KEY", "")

_lock = threading.Lock()
_totals = {}          # key -> {"out": int, "in": int, "reqs": int}
_history = collections.deque(maxlen=6)   # (ts, {key: out_total}) cada ~2 s

# Historico persistente: una linea JSONL por minuto CON actividad, rotado por mes.
# Cada linea lleva los DELTAS del minuto y los totales del proceso (los totales se
# resetean si el servicio reinicia; para agregar historicamente, sumar deltas).
HIST_DIR = os.environ.get(
    "HIST_DIR", os.path.join(os.path.expanduser("~"), "llm-local", "history"))
_last_written = {}    # key -> {"out","in","reqs"} en el momento del ultimo volcado

_RUNWAIT = re.compile(
    r'^vllm:num_requests_(running|waiting)\{[^}]*\}\s+([0-9.e+]+)', re.M)


def _account(key, usage):
    if not usage:
        return
    with _lock:
        t = _totals.setdefault(key, {"out": 0, "in": 0, "reqs": 0})
        t["out"] += usage.get("completion_tokens", 0) or 0
        t["in"] += usage.get("prompt_tokens", 0) or 0
        t["reqs"] += 1


def _write_history():
    global _last_written
    with _lock:
        snap = {k: dict(v) for k, v in _totals.items()}
    deltas = {}
    for k, t in snap.items():
        prev = _last_written.get(k, {"out": 0, "in": 0, "reqs": 0})
        d_out, d_in, d_reqs = t["out"] - prev["out"], t["in"] - prev["in"], t["reqs"] - prev["reqs"]
        if d_out or d_in or d_reqs:
            deltas[alias_de(k)] = {"out": d_out, "in": d_in, "reqs": d_reqs}
    if not deltas:
        return
    _last_written = snap
    os.makedirs(HIST_DIR, exist_ok=True)
    path = os.path.join(HIST_DIR, f"usage-{time.strftime('%Y-%m')}.jsonl")
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "deltas": deltas,
           "totals": {alias_de(k): t for k, t in snap.items()}}
    try:
        with open(path, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _sampler():
    n = 0
    while True:
        with _lock:
            snap = {k: v["out"] for k, v in _totals.items()}
        _history.append((time.time(), snap))
        n += 1
        if n % 30 == 0:          # cada ~60 s
            _write_history()
        time.sleep(2)


def _rates():
    if len(_history) < 2:
        return {}, 0.0
    (t0, old), (t1, new) = _history[0], _history[-1]
    dt = t1 - t0
    if dt <= 0:
        return {}, 0.0
    rates = {}
    for k, v in new.items():
        rates[k] = max(0.0, (v - old.get(k, 0)) / dt)
    return rates, sum(rates.values())


def _run_wait():
    try:
        c = http.client.HTTPConnection(UP.hostname, UP.port, timeout=3)
        c.request("GET", "/metrics", headers={"Authorization": f"Bearer {UPSTREAM_KEY}"})
        text = c.getresponse().read().decode()
        c.close()
        vals = {"running": 0, "waiting": 0}
        for kind, num in _RUNWAIT.findall(text):
            vals[kind] = int(float(num))
        return vals
    except Exception:
        return {"running": -1, "waiting": -1}


class Meter(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # silencioso: esto recibe un poll cada 2 s

    def _key(self):
        auth = self.headers.get("Authorization", "")
        return auth.removeprefix("Bearer ").strip() or "sin-clave"

    def _autorizado(self):
        """Fail-closed: sin lista de claves no se sirve nada, en vez de abrirse."""
        if self._key() in AUTORIZADAS and AUTORIZADAS:
            return True
        cuerpo = json.dumps({"error": {
            "type": "authentication_error",
            "message": ("clave no valida" if AUTORIZADAS else
                        "el medidor no tiene claves configuradas (falta ALIAS_MAP)"),
        }}).encode()
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)
        return False

    def do_GET(self):
        if urllib.parse.urlparse(self.path).path == "/stats":
            rates, agg = _rates()
            rw = _run_wait()
            with _lock:
                users = []
                for k, t in sorted(_totals.items()):
                    users.append({
                        "user": alias_de(k),
                        "gen_tps": round(rates.get(k, 0.0), 1),
                        "out_total": t["out"],
                        "in_total": t["in"],
                        "reqs": t["reqs"],
                    })
            body = json.dumps({
                "agg_gen_tps": round(agg, 1),
                "running": rw["running"],
                "waiting": rw["waiting"],
                "users": users,
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not self._autorizado():
            return
        self._forward(b"")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""

        if not self._autorizado():
            return

        path = urllib.parse.urlparse(self.path).path
        if path == "/v1/chat/completions":
            self._forward_chat(body)
        else:
            self._forward(body)

    # -- passthrough generico ------------------------------------------------

    def _open_upstream(self, body, headers_extra=None):
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Host"] = f"{UP.hostname}:{UP.port}"
        # La clave del usuario NO viaja al motor: se cambia por la interna. Asi la
        # identidad se resuelve aqui, donde se contabiliza, y el motor solo conoce
        # una clave que nunca aparece en la linea de arranque de ningun proceso.
        headers["Authorization"] = f"Bearer {UPSTREAM_KEY}"
        if headers_extra:
            headers.update(headers_extra)
        if body is not None:
            headers["Content-Length"] = str(len(body))
        c = http.client.HTTPConnection(UP.hostname, UP.port, timeout=1800)
        c.request(self.command, self.path, body, headers)
        return c, c.getresponse()

    def _relay_head(self, r):
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()

    def _forward(self, body):
        try:
            c, r = self._open_upstream(body)
        except Exception as e:
            self.send_error(502, str(e))
            return
        # c se cierra SIEMPRE (finally): si el cliente aborta a mitad del relay
        # (BrokenPipeError/ConnectionResetError), la conexion al motor no debe
        # quedar abierta generando (mismo patron que _forward_chat en streaming).
        try:
            self._relay_head(r)
            while True:
                chunk = r.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            c.close()

    # -- chat/completions con contabilidad ------------------------------------

    def _forward_chat(self, body):
        key = self._key()
        stream = False
        try:
            req = json.loads(body)
            stream = bool(req.get("stream"))
            if stream:
                so = req.setdefault("stream_options", {})
                if not so.get("include_usage"):
                    so["include_usage"] = True
                    body = json.dumps(req).encode()
        except (json.JSONDecodeError, AttributeError):
            pass

        try:
            c, r = self._open_upstream(body)
        except Exception as e:
            self.send_error(502, str(e))
            return

        if not stream or r.status != 200:
            raw = r.read()
            c.close()
            if r.status == 200:
                try:
                    _account(key, json.loads(raw).get("usage"))
                except json.JSONDecodeError:
                    pass
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
            return

        # streaming: relay inmediato + parseo de lineas para el usage final
        self._relay_head(r)
        buf = b""
        usage = None
        try:
            while True:
                chunk = r.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line.startswith(b"data: ") or line == b"data: [DONE]":
                        continue
                    try:
                        d = json.loads(line[6:])
                    except json.JSONDecodeError:
                        continue
                    if d.get("usage"):
                        usage = d["usage"]
        except BrokenPipeError:
            pass
        finally:
            c.close()
            _account(key, usage)


if __name__ == "__main__":
    threading.Thread(target=_sampler, daemon=True).start()
    srv = ThreadingHTTPServer((ADDR, PORT), Meter)
    srv.daemon_threads = True
    print(f"[meter] {ADDR}:{PORT} -> {UP.geturl()}", flush=True)
    srv.serve_forever()
