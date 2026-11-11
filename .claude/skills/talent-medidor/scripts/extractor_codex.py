#!/usr/bin/env python3
"""extractor_codex.py — campos de USO de un rollout de Codex, desde un offset (talent-medidor, F1).

Uso:  extractor_codex.py <rollout.jsonl> [--offset N] [--estado JSON] [--normalizacion <tsv>]

Stdlib puro, fuente en SOLO LECTURA. Emite JSONL con SOLO claves de la allowlist:

  {"k":"unidad", ...}   una por RESPUESTA (payload.response_id) con SU payload.usage
  {"k":"muestra", ...}  una por ventana de rate_limits de un event_msg token_count (NUNCA uso)
  {"k":"fin", ...}      cursor nuevo, contadores y el turn_context VIGENTE al final (estado)

Reglas selladas que viven aquí:
  * La unidad es response_id con payload.usage. turn_token_usage viaja SOLO como control
    (turno_in/turno_out) y thread_token_usage no se lee: nunca es "esta respuesta".
  * in_total sale de config/normalizacion.tsv (Codex: input_tokens, que YA incluye el cacheado).
  * model/effort/cwd salen del turn_context VIGENTE en ese punto del fichero; el vigente al
    empezar llega por --estado (el tick anterior lo dejó en el cursor).
  * La última línea sin '\\n' no se consume.
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # no dejar __pycache__ en el árbol del skill
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extractor import (  # noqa: E402  (módulo hermano; stdlib puro)
    EFFORTS, NO_MEDIDO, NORMALIZACION_DEFECTO, Rechazo, aplicar, cargar_normalizacion,
    emitir, entero, gana, id_opaco, leer_lineas, modelo, sha256, ts_epoch,
)

VENTANAS = ("primary", "secondary")


def estado_inicial(texto):
    base = {"model": None, "effort": NO_MEDIDO, "cwd_sha": None}
    if not texto:
        return base
    try:
        previo = json.loads(texto)
    except ValueError:
        return base
    if not isinstance(previo, dict):
        return base
    try:
        base["model"] = modelo(previo.get("model"))
    except Rechazo:
        base["model"] = None
    if previo.get("effort") in EFFORTS:
        base["effort"] = previo["effort"]
    cwd_sha = previo.get("cwd_sha")
    if isinstance(cwd_sha, str) and len(cwd_sha) == 64 and all(c in "0123456789abcdef" for c in cwd_sha):
        base["cwd_sha"] = cwd_sha
    return base


def numero(valor):
    if isinstance(valor, bool) or not isinstance(valor, (int, float)):
        return None
    return valor


def extraer_codex(ruta, offset, sumandos, estado):
    unidades = {}
    orden = []
    cursor = offset
    lineas = rechazos = json_roto = 0
    for pos, crudo in leer_lineas(ruta, offset):
        cursor = pos + len(crudo)
        lineas += 1
        try:
            reg = json.loads(crudo)
        except (ValueError, UnicodeDecodeError):
            json_roto += 1
            continue
        if not isinstance(reg, dict):
            json_roto += 1
            continue
        payload = reg.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        tipo = reg.get("type")
        try:
            if tipo == "turn_context":
                nuevo = dict(estado)
                nuevo["model"] = modelo(payload.get("model"))
                eff = payload.get("effort")
                nuevo["effort"] = eff if eff in EFFORTS else NO_MEDIDO
                cwd = payload.get("cwd")
                nuevo["cwd_sha"] = sha256(cwd) if isinstance(cwd, str) and cwd else estado["cwd_sha"]
                estado = nuevo
            elif tipo == "event_msg" and payload.get("type") == "token_count":
                muestras(reg, payload, pos)
            elif tipo == "token_usage_record":
                u = unidad(reg, payload, sumandos, estado, pos)
                if u is None:
                    continue
                clave = (u["session_id"], u["unidad_id"])
                previa = unidades.get(clave)
                if previa is None:
                    unidades[clave] = u
                    orden.append(clave)
                elif gana(u, previa):
                    unidades[clave] = u
        except Rechazo:
            rechazos += 1
    for clave in orden:
        u = unidades[clave]
        u.pop("_pos", None)
        emitir(u)
    emitir({"k": "fin", "cursor": cursor, "lineas": lineas, "rechazadas_forma": rechazos,
            "descartadas_json": json_roto, "estado_model": estado["model"],
            "estado_effort": estado["effort"], "estado_cwd_sha": estado["cwd_sha"]})


def muestras(reg, payload, pos):
    limites = payload.get("rate_limits")
    if not isinstance(limites, dict):
        return
    ts, _ = ts_epoch(reg.get("timestamp"))
    for ventana in VENTANAS:
        v = limites.get(ventana)
        if not isinstance(v, dict):
            continue
        emitir({"k": "muestra", "ts": ts, "ventana": ventana, "orden": pos,
                "window_minutes": numero(v.get("window_minutes")),
                "resets_at": numero(v.get("resets_at")),
                "used_percent": numero(v.get("used_percent"))})


def unidad(reg, payload, sumandos, estado, pos):
    usage = payload.get("usage")
    rid = payload.get("response_id")
    if not isinstance(usage, dict) or rid is None:
        return None
    turno = payload.get("turn_token_usage")
    turno = turno if isinstance(turno, dict) else {}
    ts, mes = ts_epoch(reg.get("timestamp"))
    turn_id = payload.get("turn_id")
    return {
        "k": "unidad",
        "proveedor": "codex",
        "session_id": id_opaco(payload.get("session_id")),
        "unidad_id": id_opaco(rid),
        "turn_id": id_opaco(turn_id, obligatorio=False),
        "orden": pos,
        "ts": ts,
        "ts_month": mes,
        "model": estado["model"],
        "effort": estado["effort"],
        "es_subagente": 0,
        "in_tok": entero(usage.get("input_tokens")),
        "cache_r": entero(usage.get("cached_input_tokens")),
        "cache_w": entero(usage.get("cache_write_input_tokens")),
        "cache_w_5m": 0,
        "cache_w_1h": 0,
        "in_total": aplicar(sumandos, usage),
        "out_tok": entero(usage.get("output_tokens")),
        "thinking_tok": entero(usage.get("reasoning_output_tokens")),
        "turno_in": entero(turno.get("input_tokens")),
        "turno_out": entero(turno.get("output_tokens")),
        "cwd_sha": estado["cwd_sha"],
        "_pos": pos,
    }


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if argv else 2
    ruta = argv[0]
    opts = {"--offset": "0", "--estado": "", "--normalizacion": NORMALIZACION_DEFECTO}
    i = 1
    while i < len(argv):
        if argv[i] not in opts or i + 1 >= len(argv):
            sys.stderr.write("extractor_codex: argumento desconocido o sin valor: %s\n" % argv[i])
            return 2
        opts[argv[i]] = argv[i + 1]
        i += 2
    try:
        sumandos = cargar_normalizacion(opts["--normalizacion"])["codex"]
    except (OSError, KeyError, ValueError) as exc:
        sys.stderr.write("extractor_codex: normalizacion inservible (%s)\n" % type(exc).__name__)
        return 2
    try:
        extraer_codex(ruta, int(opts["--offset"]), sumandos, estado_inicial(opts["--estado"]))
    except OSError as exc:
        sys.stderr.write("extractor_codex: fuente ilegible (%s)\n" % type(exc).__name__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
