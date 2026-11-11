#!/usr/bin/env python3
"""extractor.py — campos de USO de un transcript de Claude, desde un offset (talent-medidor, F1).

Uso:  extractor.py <fichero.jsonl> [--offset N] [--normalizacion <tsv>] [--agent-type <tipo>]

Stdlib puro. Abre la fuente en SOLO LECTURA y emite JSONL con SOLO claves de la allowlist:

  {"k":"unidad", ...}   una por RESPUESTA (message.id), con el ÚLTIMO usage por timestamp
  {"k":"nodo", ...}     un nodo del DAG parentUuid por registro (origen cron/manual y fase)
  {"k":"fin", ...}      cursor nuevo y contadores (rechazos por forma, JSON roto)

Reglas selladas que viven aquí:
  * La unidad es message.id, nunca el uuid de la línea: N registros -> 1 unidad (F0 P1).
  * Entre registros de la misma unidad gana el de MAYOR timestamp; sin timestamp, el último del
    fichero. Nunca el máximo de un contador.
  * in_total sale de config/normalizacion.tsv, no de una fórmula escrita en el código.
  * La última línea sin '\\n' NO se consume: el cursor se queda antes de ella.
  * cwd sale SOLO como sha256. Contenido, requestId, rutas y descripciones no salen nunca.
  * Un identificador o un modelo con forma no válida RECHAZA el registro entero (se cuenta).
"""
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

AQUI = os.path.dirname(os.path.abspath(__file__))
NORMALIZACION_DEFECTO = os.path.join(AQUI, "..", "config", "normalizacion.tsv")

# ── Formas (eje de datos de personas). La validación de forma es la ÚNICA defensa para los
# valores de claves permitidas: si la forma no casa, el registro no sale. ──────────────────────
RE_MSG_ID = re.compile(r"^msg_[A-Za-z0-9_]+$")
RE_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
RE_MODEL = re.compile(r"^[a-z<][a-z0-9<>._-]{0,63}$")
RE_TS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$")
RE_AGENT_TYPE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
# Prefijos de credencial: un id con forma válida que empiece así es un token, no un id.
# Se construyen por partes para que este fichero no case con los barridos de secretos.
PREFIJOS_TOKEN = tuple(a + b for a, b in (
    ("sk-", "ant-"), ("sb", "p_"), ("sb_", "secret_"), ("sb_", "publishable_"), ("tskey", "-"),
    ("gh", "p_"), ("gh", "s_"), ("gh", "o_"), ("gh", "u_"), ("gh", "r_"), ("github", "_pat_"),
    ("lin_", "api_"),
))
EFFORTS = frozenset(("minimal", "low", "medium", "high", "xhigh", "max"))
SUBTIPOS = frozenset(("scheduled_task_fire", "compact_boundary"))
TIPOS = frozenset(("user", "assistant", "system"))
PERMISSION_MODES = frozenset(("default", "plan", "acceptEdits", "bypassPermissions", "auto", "dontAsk"))

NO_MEDIDO = "NO MEDIDO"


class Rechazo(Exception):
    """El registro no cumple la forma: se descarta entero y se cuenta."""


def id_opaco(valor, obligatorio=True):
    if valor is None and not obligatorio:
        return None
    if not isinstance(valor, str) or not RE_ID.match(valor):
        raise Rechazo("forma_id")
    if valor.startswith(PREFIJOS_TOKEN):
        raise Rechazo("forma_token")
    return valor


def modelo(valor):
    if valor is None:
        return None
    if not isinstance(valor, str) or not RE_MODEL.match(valor):
        raise Rechazo("forma_model")
    return valor


def entero(valor):
    """Contador de tokens: entero >= 0; ausente o de otro tipo -> 0."""
    if isinstance(valor, bool) or not isinstance(valor, int) or valor < 0:
        return 0
    return valor


def ts_epoch(valor):
    """ISO-8601 -> (epoch s, 'AAAA-MM'); ausente o sin forma -> (None, None)."""
    if not isinstance(valor, str) or not RE_TS.match(valor):
        return None, None
    try:
        dt = datetime.fromisoformat(valor.replace("Z", "+00:00"))
    except ValueError:
        return None, None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)
    return dt.timestamp(), dt.strftime("%Y-%m")


def sha256(texto):
    return hashlib.sha256(texto.encode("utf-8")).hexdigest()


def cargar_normalizacion(ruta):
    """{proveedor: [sumandos]} para in_total. Fichero ausente o sin la fila -> error (rc 2)."""
    formula = {}
    with open(ruta, "r", encoding="utf-8") as fh:
        cabecera = None
        for linea in fh:
            linea = linea.rstrip("\n")
            if not linea or linea.startswith("#"):
                continue
            campos = linea.split("\t")
            if cabecera is None:
                cabecera = campos
                continue
            if len(campos) != 3:
                raise ValueError("normalizacion.tsv: fila sin 3 columnas")
            prov, campo, sumandos = campos
            if campo == "in_total":
                formula[prov] = [s for s in sumandos.split("+") if s]
    return formula


def aplicar(sumandos, usage):
    return sum(entero(usage.get(s)) for s in sumandos)


def leer_lineas(ruta, offset):
    """Genera (offset_inicio, bytes_linea) de las líneas COMPLETAS desde offset.

    La última línea sin '\\n' no se entrega: puede estar a medio escribir."""
    with open(ruta, "rb") as fh:
        fh.seek(offset)
        pos = offset
        while True:
            linea = fh.readline()
            if not linea:
                return
            if not linea.endswith(b"\n"):
                return
            yield pos, linea
            pos += len(linea)


def emitir(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")


def extraer_claude(ruta, offset, sumandos, agent_type):
    unidades = {}
    orden = []
    cursor = offset
    lineas = 0
    rechazos = 0
    json_roto = 0
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
        try:
            nodo, unidad = procesar_registro(reg, sumandos, agent_type, pos)
        except Rechazo:
            rechazos += 1
            continue
        if nodo is not None:
            emitir(nodo)
        if unidad is None:
            continue
        clave = (unidad["session_id"], unidad["unidad_id"])
        previa = unidades.get(clave)
        if previa is None:
            unidad["uuids"] = [unidad["uuid"]] if unidad["uuid"] else []
            unidades[clave] = unidad
            orden.append(clave)
            continue
        uuids = previa["uuids"]
        if unidad["uuid"] and unidad["uuid"] not in uuids:
            uuids.append(unidad["uuid"])
        if gana(unidad, previa):
            unidad["uuids"] = uuids
            unidades[clave] = unidad
    for clave in orden:
        u = unidades[clave]
        u.pop("_pos", None)
        emitir(u)
    emitir({"k": "fin", "cursor": cursor, "lineas": lineas, "rechazadas_forma": rechazos,
            "descartadas_json": json_roto})


def gana(nueva, previa):
    """¿La nueva versión de la unidad sustituye a la previa? El ÚLTIMO usage por timestamp."""
    tn, tp = nueva["ts"], previa["ts"]
    if tn is not None and tp is not None and tn != tp:
        return tn > tp
    if tn is not None and tp is None:
        return True
    if tn is None and tp is not None:
        return False
    return nueva["_pos"] > previa["_pos"]


def procesar_registro(reg, sumandos, agent_type, pos):
    tipo = reg.get("type")
    uuid = reg.get("uuid")
    session = reg.get("sessionId")
    nodo = None
    if tipo in TIPOS and uuid is not None and session is not None:
        subtipo = reg.get("subtype") if tipo == "system" else None
        parent = reg.get("parentUuid")
        if subtipo == "compact_boundary" and parent is None:
            parent = reg.get("logicalParentUuid")
        pm = reg.get("permissionMode") if tipo == "user" else None
        nodo = {
            "k": "nodo",
            "session_id": id_opaco(session),
            "uuid": id_opaco(uuid),
            "parent_uuid": id_opaco(parent, obligatorio=False),
            "tipo": tipo,
            "subtipo": subtipo if subtipo in SUBTIPOS else None,
            "permission_mode": pm if pm in PERMISSION_MODES else None,
        }
    if tipo != "assistant":
        return nodo, None
    msg = reg.get("message")
    if not isinstance(msg, dict):
        return nodo, None
    usage = msg.get("usage")
    mid = msg.get("id")
    if not isinstance(usage, dict) or mid is None:
        return nodo, None
    if not isinstance(mid, str) or not RE_MSG_ID.match(mid):
        raise Rechazo("forma_msg_id")
    if mid.startswith(PREFIJOS_TOKEN):
        raise Rechazo("forma_token")
    ts, mes = ts_epoch(reg.get("timestamp"))
    cc = usage.get("cache_creation")
    cc = cc if isinstance(cc, dict) else {}
    det = usage.get("output_tokens_details")
    det = det if isinstance(det, dict) else {}
    effort = reg.get("effort")
    cwd = reg.get("cwd")
    unidad = {
        "k": "unidad",
        "proveedor": "claude",
        "session_id": id_opaco(session),
        "unidad_id": mid,
        "uuid": id_opaco(uuid, obligatorio=False),
        "ts": ts,
        "ts_month": mes,
        "model": modelo(msg.get("model")),
        "effort": effort if effort in EFFORTS else NO_MEDIDO,
        "es_subagente": 1 if reg.get("isSidechain") is True else 0,
        "agent_type": agent_type if reg.get("isSidechain") is True else None,
        "in_tok": entero(usage.get("input_tokens")),
        "cache_w": entero(usage.get("cache_creation_input_tokens")),
        "cache_w_5m": entero(cc.get("ephemeral_5m_input_tokens")),
        "cache_w_1h": entero(cc.get("ephemeral_1h_input_tokens")),
        "cache_r": entero(usage.get("cache_read_input_tokens")),
        "in_total": aplicar(sumandos, usage),
        "out_tok": entero(usage.get("output_tokens")),
        "thinking_tok": entero(det.get("thinking_tokens")),
        "cwd_sha": sha256(cwd) if isinstance(cwd, str) and cwd else None,
        "_pos": pos,
    }
    return nodo, unidad


def agent_type_de(ruta):
    """agentType del .meta.json hermano (subagentes). SOLO esa clave; el resto no se lee a salida."""
    if not ruta.endswith(".jsonl"):
        return None
    meta = ruta[: -len(".jsonl")] + ".meta.json"
    try:
        with open(meta, "r", encoding="utf-8") as fh:
            datos = json.load(fh)
    except (OSError, ValueError):
        return None
    valor = datos.get("agentType") if isinstance(datos, dict) else None
    if isinstance(valor, str) and RE_AGENT_TYPE.match(valor):
        return valor
    return None


def argumentos(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        sys.exit(0 if argv else 2)
    ruta = argv[0]
    opts = {"--offset": "0", "--normalizacion": NORMALIZACION_DEFECTO, "--agent-type": None}
    i = 1
    while i < len(argv):
        if argv[i] not in opts or i + 1 >= len(argv):
            sys.stderr.write("extractor: argumento desconocido o sin valor: %s\n" % argv[i])
            sys.exit(2)
        opts[argv[i]] = argv[i + 1]
        i += 2
    return ruta, int(opts["--offset"]), opts["--normalizacion"], opts["--agent-type"]


def main(argv):
    ruta, offset, norm, agent = argumentos(argv)
    try:
        sumandos = cargar_normalizacion(norm)["claude"]
    except (OSError, KeyError, ValueError) as exc:
        sys.stderr.write("extractor: normalizacion inservible (%s)\n" % type(exc).__name__)
        return 2
    if agent is None:
        agent = agent_type_de(ruta)
    try:
        extraer_claude(ruta, offset, sumandos, agent)
    except OSError as exc:
        sys.stderr.write("extractor: fuente ilegible (%s)\n" % type(exc).__name__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
