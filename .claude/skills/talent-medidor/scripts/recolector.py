#!/usr/bin/env python3
"""recolector.py — recolector incremental del HOST (talent-medidor, F1).

Uso:
  recolector.py --tick                  una pasada incremental sobre todas las fuentes
  recolector.py --bootstrap             la primera carga, SIEMPRE bajo `nice -n 19`
  recolector.py --bootstrap --diagnostico   imprime la niceness efectiva y sale (sin trabajo)
  recolector.py --salud                 estado textual: por fuente ultima_ts, cursores, contadores

Entorno (todos opcionales; los tests los apuntan a un directorio temporal):
  TALENT_MEDIDOR_DB            almacén (defecto ~/.local/state/talent-medidor/medidor.db, dir 0700)
  TALENT_MEDIDOR_CLAUDE_DIR    transcripts de Claude (defecto ~/.claude/projects)
  TALENT_MEDIDOR_CODEX_DIR     rollouts de Codex (defecto ~/.codex/sessions)
  TALENT_MEDIDOR_PRECIOS       tabla de precios (defecto config/precios.tsv)
  TALENT_MEDIDOR_NORMALIZACION fórmula de in_total (defecto config/normalizacion.tsv)
  TA_PERFIL                    perfil de instancia (lo resuelve lib-perfil.sh, no este fichero)

Orden SELLADO por fuente: extraer -> insertar el lote -> COMMIT -> y SOLO DESPUÉS el cursor, en
su propia transacción. Si el proceso muere entre los dos COMMIT, el tick siguiente re-extrae
desde el cursor viejo y la unidad absorbe el duplicado (ON CONFLICT DO UPDATE): 0 pérdidas y
0 duplicados. Al revés —cursor primero— una muerte a mitad perdería el lote para siempre.

Los rollups 5m/1h/1d de cada bucket tocado se RECALCULAN desde usage_raw; nunca se suma un delta.
Las fuentes se abren en solo lectura y nunca se mueven, truncan ni reescriben.
"""
import fcntl
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

AQUI = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(AQUI)
NO_MEDIDO = "NO MEDIDO"
GRANOS = (("rollup_5m", 300), ("rollup_1h", 3600), ("rollup_1d", 86400))
COLUMNAS_UNIDAD = (
    "session_id", "unidad_id", "proveedor", "ts", "ts_month", "model", "effort", "fase",
    "origen_turno", "part_id", "rol", "pane_kind", "es_subagente", "agent_type", "turn_id",
    "nodo_uuid", "in_tok", "cache_w", "cache_w_5m", "cache_w_1h", "cache_r", "in_total",
    "out_tok", "thinking_tok", "cost_usd", "cost_estado", "cwd_sha",
)


def entorno(clave, defecto):
    valor = os.environ.get(clave)
    return os.path.expanduser(valor if valor else defecto)


def sha256(texto):
    return hashlib.sha256(texto.encode("utf-8")).hexdigest()


# ── almacén ────────────────────────────────────────────────────────────────────────────────────
def abrir_db():
    ruta = entorno("TALENT_MEDIDOR_DB", "~/.local/state/talent-medidor/medidor.db")
    directorio = os.path.dirname(os.path.abspath(ruta))
    os.makedirs(directorio, mode=0o700, exist_ok=True)
    os.chmod(directorio, 0o700)
    viejo = os.umask(0o077)
    try:
        db = sqlite3.connect(ruta, isolation_level=None, timeout=30)
    finally:
        os.umask(viejo)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    with open(os.path.join(AQUI, "esquema.sql"), "r", encoding="utf-8") as fh:
        db.executescript(fh.read())
    return db, directorio


def cerrojo(directorio):
    """Un solo tick a la vez (timer + bootstrap). Un kill -9 libera el flock con el proceso."""
    fd = os.open(os.path.join(directorio, "recolector.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return fd


# ── configuración ──────────────────────────────────────────────────────────────────────────────
def cargar_precios(ruta):
    """{modelo: [(desde_fecha, precios_dict), ...]} ordenado por fecha. Filas malas se cuentan."""
    tabla, malas, cabecera = {}, 0, None
    try:
        fh = open(ruta, "r", encoding="utf-8")
    except OSError:
        return tabla, 0
    with fh:
        for linea in fh:
            linea = linea.rstrip("\n")
            if not linea or linea.startswith("#"):
                continue
            campos = linea.split("\t")
            if cabecera is None:
                cabecera = campos
                continue
            try:
                desde, mod = campos[0], campos[1]
                datetime.strptime(desde, "%Y-%m-%d")
                p = {k: float(v) for k, v in zip(("in", "out", "cache_w_5m", "cache_w_1h", "cache_r"), campos[2:7])}
                if len(p) != 5 or any(v < 0 for v in p.values()):
                    raise ValueError
            except (IndexError, ValueError):
                malas += 1
                continue
            tabla.setdefault(mod, []).append((desde, p))
    for filas in tabla.values():
        filas.sort()
    return tabla, malas


def precio_vigente(tabla, model, ts):
    if model is None or ts is None or model not in tabla:
        return None
    fecha = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")
    vigente = None
    for desde, p in tabla[model]:
        if desde <= fecha:
            vigente = p
    return vigente


def coste(u, tabla):
    """(cost_usd, cost_estado). Sin precio vigente o con contadores incoherentes: NULL, NO MEDIDO."""
    p = precio_vigente(tabla, u["model"], u["ts"])
    if p is None:
        return None, NO_MEDIDO
    if u["proveedor"] == "claude":
        if u["cache_w"] != u["cache_w_5m"] + u["cache_w_1h"]:
            return None, NO_MEDIDO
        total = (u["in_tok"] * p["in"] + u["cache_w_5m"] * p["cache_w_5m"]
                 + u["cache_w_1h"] * p["cache_w_1h"] + u["cache_r"] * p["cache_r"]
                 + u["out_tok"] * p["out"])
    else:
        if u["cache_w"] > 0 or u["cache_r"] > u["in_tok"]:
            return None, NO_MEDIDO
        total = ((u["in_tok"] - u["cache_r"]) * p["in"] + u["cache_r"] * p["cache_r"]
                 + u["out_tok"] * p["out"])
    return round(total / 1_000_000, 12), "MEDIDO"


def cargar_partes():
    """{cwd_sha: (part_id, rol, pane_kind)} vía lib-medidor.sh (que hace source de lib-perfil.sh)."""
    try:
        r = subprocess.run(["bash", os.path.join(AQUI, "lib-medidor.sh"), "partes"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return {}, 2
    if r.returncode != 0:
        return {}, r.returncode
    partes = {}
    for linea in r.stdout.splitlines():
        campos = linea.split("\t")
        if len(campos) == 4:
            partes[campos[3]] = (campos[0], campos[1], campos[2])
    return partes, 0


# ── descubrimiento ─────────────────────────────────────────────────────────────────────────────
def fuentes():
    for proveedor, clave, defecto in (("claude", "TALENT_MEDIDOR_CLAUDE_DIR", "~/.claude/projects"),
                                      ("codex", "TALENT_MEDIDOR_CODEX_DIR", "~/.codex/sessions")):
        raiz = entorno(clave, defecto)
        if not os.path.isdir(raiz):
            continue
        halladas = []
        for d, subdirs, ficheros in os.walk(raiz, followlinks=False):
            subdirs.sort()
            for f in ficheros:
                if f.endswith(".jsonl"):
                    halladas.append(os.path.join(d, f))
        for ruta in sorted(halladas):
            if not os.path.islink(ruta):
                yield proveedor, ruta


# ── DAG de origen y fase ───────────────────────────────────────────────────────────────────────
def resolver_nodos(db, nodos):
    """Memo de origen (cron/manual/NO MEDIDO) y pm (permissionMode vigente) de los nodos nuevos.

    El padre se busca en el lote y, si no está, en el DAG PERSISTIDO: un fire del tick anterior
    tiene que seguir encadenando (K14)."""
    memo = {}
    for n in nodos:
        clave = (n["session_id"], n["uuid"])
        padre = None
        if n["parent_uuid"] is not None:
            padre = memo.get((n["session_id"], n["parent_uuid"]))
            if padre is None:
                fila = db.execute("SELECT origen, pm FROM nodos WHERE session_id=? AND uuid=?",
                                  (n["session_id"], n["parent_uuid"])).fetchone()
                if fila is not None:
                    padre = {"origen": fila[0], "pm": fila[1]}
        if n["subtipo"] == "scheduled_task_fire":
            origen = "cron"
        elif n["parent_uuid"] is None:
            origen = "manual" if n["tipo"] == "user" else NO_MEDIDO
        elif padre is not None:
            origen = padre["origen"]
        else:
            origen = None
        if n["tipo"] == "user" and n["permission_mode"] is not None:
            pm = n["permission_mode"]
        else:
            pm = padre["pm"] if padre is not None else None
        memo[clave] = {"origen": origen, "pm": pm}
        db.execute(
            "INSERT INTO nodos (session_id, uuid, parent_uuid, tipo, subtipo, permission_mode, origen, pm)"
            " VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(session_id, uuid) DO UPDATE SET"
            " origen=COALESCE(nodos.origen, excluded.origen), pm=COALESCE(nodos.pm, excluded.pm)",
            (n["session_id"], n["uuid"], n["parent_uuid"], n["tipo"], n["subtipo"],
             n["permission_mode"], origen, pm))


def enriquecer(db, u, partes, precios):
    parte = partes.get(u.get("cwd_sha")) if u.get("cwd_sha") else None
    u["part_id"], u["rol"], u["pane_kind"] = parte if parte else (NO_MEDIDO, NO_MEDIDO, NO_MEDIDO)
    origen, pm = None, None
    if u["proveedor"] == "claude" and u.get("uuid"):
        fila = db.execute("SELECT origen, pm FROM nodos WHERE session_id=? AND uuid=?",
                          (u["session_id"], u["uuid"])).fetchone()
        if fila is not None:
            origen, pm = fila
    u["origen_turno"] = origen if origen in ("cron", "manual") else NO_MEDIDO
    if pm == "plan":
        u["fase"] = "plan"
    elif u["rol"] == "coordinador":
        u["fase"] = "coordinacion"
    else:
        u["fase"] = NO_MEDIDO
    u["nodo_uuid"] = u.get("uuid")
    u.setdefault("agent_type", None)
    u.setdefault("turn_id", None)
    u["cost_usd"], u["cost_estado"] = coste(u, precios)


# ── lote ───────────────────────────────────────────────────────────────────────────────────────
def upsert_unidad(db, u):
    """(insertada, actualizada, ts_viejo). Gana el ÚLTIMO usage por timestamp (sellada 1)."""
    previa = db.execute("SELECT ts FROM usage_raw WHERE session_id=? AND unidad_id=?",
                        (u["session_id"], u["unidad_id"])).fetchone()
    valores = [u[c] for c in COLUMNAS_UNIDAD]
    asignar = ", ".join("%s=excluded.%s" % (c, c) for c in COLUMNAS_UNIDAD[2:])
    db.execute(
        "INSERT INTO usage_raw (%s) VALUES (%s) ON CONFLICT(session_id, unidad_id) DO UPDATE SET %s"
        " WHERE usage_raw.ts IS NULL OR (excluded.ts IS NOT NULL AND excluded.ts >= usage_raw.ts)"
        % (", ".join(COLUMNAS_UNIDAD), ", ".join("?" * len(COLUMNAS_UNIDAD)), asignar),
        valores)
    for uuid in u.get("uuids") or []:
        db.execute("INSERT OR IGNORE INTO registros_por_respuesta VALUES (?,?,?)",
                   (u["session_id"], u["unidad_id"], uuid))
    if previa is None:
        return 1, 0, None
    return 0, 1, previa[0]


def recalcular_rollups(db, tss):
    for tabla, grano in GRANOS:
        for bucket in sorted({int(t // grano) * grano for t in tss if t is not None}):
            db.execute("DELETE FROM %s WHERE bucket=?" % tabla, (bucket,))
            db.execute(
                "INSERT INTO %s SELECT ?, proveedor, COALESCE(model, ?), effort, fase, part_id,"
                " count(*), sum(in_total), sum(out_tok), sum(thinking_tok), sum(cache_r),"
                " sum(cache_w), COALESCE(sum(cost_usd), 0), sum(cost_usd IS NULL)"
                " FROM usage_raw WHERE ts >= ? AND ts < ?"
                " GROUP BY proveedor, COALESCE(model, ?), effort, fase, part_id" % tabla,
                (bucket, NO_MEDIDO, bucket, bucket + grano, NO_MEDIDO))


def recalcular_control_codex(db, turnos):
    for session_id, turn_id in sorted(turnos):
        suma = db.execute("SELECT COALESCE(sum(in_tok),0), COALESCE(sum(out_tok),0) FROM usage_raw"
                          " WHERE session_id=? AND turn_id=?", (session_id, turn_id)).fetchone()
        ultima = db.execute("SELECT turno_in, turno_out FROM codex_turno_snap WHERE session_id=? AND"
                            " turn_id=? ORDER BY ts IS NULL, ts DESC, orden DESC LIMIT 1",
                            (session_id, turn_id)).fetchone()
        if ultima is None:
            continue
        db.execute("INSERT OR REPLACE INTO control_turnos_codex VALUES (?,?,?,?,?,?,?)",
                   (session_id, turn_id, suma[0], suma[1], ultima[0], ultima[1],
                    1 if (suma[0], suma[1]) == (ultima[0], ultima[1]) else 0))


def recalcular_sesiones(db, sesiones):
    for s in sorted(sesiones):
        db.execute("DELETE FROM sesiones WHERE session_id=?", (s,))
        db.execute("INSERT INTO sesiones SELECT session_id, min(proveedor), min(ts), max(ts), count(*),"
                   " max(part_id) FROM usage_raw WHERE session_id=? GROUP BY session_id", (s,))


def pausa_de_prueba():
    """Solo tests (D5): bloquea entre insertar el lote y su COMMIT para poder matar el proceso."""
    fifo = os.environ.get("TALENT_MEDIDOR_PAUSA_FIFO")
    if not fifo:
        return
    with open(fifo + ".en-pausa", "w", encoding="utf-8"):
        pass
    with open(fifo, "r", encoding="utf-8") as fh:
        fh.read()


def extraer(proveedor, ruta, offset, estado):
    norm = entorno("TALENT_MEDIDOR_NORMALIZACION", os.path.join(SKILL, "config", "normalizacion.tsv"))
    if proveedor == "claude":
        cmd = [sys.executable, os.path.join(AQUI, "extractor.py"), ruta, "--offset", str(offset),
               "--normalizacion", norm]
    else:
        cmd = [sys.executable, os.path.join(AQUI, "extractor_codex.py"), ruta, "--offset", str(offset),
               "--normalizacion", norm, "--estado", estado or ""]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    salida = {"nodo": [], "unidad": [], "muestra": [], "fin": None}
    for linea in r.stdout.splitlines():
        obj = json.loads(linea)
        if obj["k"] == "fin":
            salida["fin"] = obj
        else:
            salida[obj["k"]].append(obj)
    return salida if salida["fin"] is not None else None


def procesar_fuente(db, proveedor, ruta, partes, precios, cuenta):
    st = os.stat(ruta)
    fuente_id = sha256(os.path.abspath(ruta))
    fila = db.execute("SELECT inode, offset, estado FROM cursores WHERE fuente_id=?", (fuente_id,)).fetchone()
    offset, estado = 0, None
    if fila is not None and fila[0] == st.st_ino and fila[1] <= st.st_size:
        offset, estado = fila[1], fila[2]
    if offset == st.st_size and fila is not None and fila[0] == st.st_ino:
        return
    salida = extraer(proveedor, ruta, offset, estado)
    if salida is None:
        cuenta["fuentes_con_error"] += 1
        return
    fin = salida["fin"]
    tss, sesiones, turnos = [], set(), set()
    db.execute("BEGIN IMMEDIATE")
    try:
        resolver_nodos(db, salida["nodo"])
        for u in salida["unidad"]:
            enriquecer(db, u, partes, precios)
            ins, act, ts_viejo = upsert_unidad(db, u)
            cuenta["insertadas"] += ins
            cuenta["actualizadas"] += act
            tss.extend((ts_viejo, u["ts"]))
            sesiones.add(u["session_id"])
            if proveedor == "codex" and u.get("turn_id"):
                db.execute("INSERT OR REPLACE INTO codex_turno_snap VALUES (?,?,?,?,?,?,?)",
                           (u["session_id"], u["unidad_id"], u["turn_id"], u["ts"], u["orden"],
                            u["turno_in"], u["turno_out"]))
                turnos.add((u["session_id"], u["turn_id"]))
        for m in salida["muestra"]:
            db.execute("INSERT OR IGNORE INTO cuota_muestras VALUES (?,?,?,?,?,?)",
                       (fuente_id, m["ts"], m["ventana"], m["window_minutes"], m["resets_at"],
                        m["used_percent"]))
        recalcular_rollups(db, tss)
        recalcular_control_codex(db, turnos)
        recalcular_sesiones(db, sesiones)
        ahora = time.time()
        for clave in ("rechazadas_forma", "descartadas_json"):
            if fin[clave]:
                db.execute("INSERT INTO eventos VALUES (?,?,?,?)", (ahora, proveedor, clave, fin[clave]))
                cuenta[clave] += fin[clave]
        pausa_de_prueba()
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    # SOLO DESPUÉS del COMMIT del lote, y en su propia transacción: el cursor.
    nuevo_estado = None
    if proveedor == "codex":
        nuevo_estado = json.dumps({"model": fin["estado_model"], "effort": fin["estado_effort"],
                                   "cwd_sha": fin["estado_cwd_sha"]}, sort_keys=True)
    ultima = max((t for t in tss if t is not None), default=None)
    db.execute("BEGIN IMMEDIATE")
    db.execute(
        "INSERT INTO cursores VALUES (?,?,?,?,?,?,?) ON CONFLICT(fuente_id) DO UPDATE SET"
        " proveedor=excluded.proveedor, inode=excluded.inode, offset=excluded.offset,"
        " estado=excluded.estado, ultima_ts=COALESCE(excluded.ultima_ts, cursores.ultima_ts),"
        " actualizado=excluded.actualizado",
        (fuente_id, proveedor, st.st_ino, fin["cursor"], nuevo_estado, ultima, time.time()))
    db.execute("COMMIT")
    cuenta["fuentes_leidas"] += 1


def tick():
    db, directorio = abrir_db()
    fd = cerrojo(directorio)
    if fd is None:
        print("recolector: otro tick en curso; se omite esta pasada")
        return 3
    precios, malas = cargar_precios(entorno("TALENT_MEDIDOR_PRECIOS", os.path.join(SKILL, "config", "precios.tsv")))
    partes, rc_perfil = cargar_partes()
    if rc_perfil == 2:
        print("aviso_perfil rc=2: sin perfil o perfil inválido; part_id/rol/pane_kind = NO MEDIDO",
              file=sys.stderr)
        db.execute("INSERT INTO eventos VALUES (?,?,?,?)", (time.time(), "perfil", "aviso_perfil_rc2", 1))
    cuenta = {k: 0 for k in ("insertadas", "actualizadas", "fuentes_leidas", "fuentes_con_error",
                             "rechazadas_forma", "descartadas_json")}
    for proveedor, ruta in fuentes():
        procesar_fuente(db, proveedor, ruta, partes, precios, cuenta)
    print("insertadas=%d actualizadas=%d fuentes_leidas=%d fuentes_con_error=%d rechazadas_forma=%d"
          " descartadas_json=%d precios_filas_malas=%d aviso_perfil_rc=%d"
          % (cuenta["insertadas"], cuenta["actualizadas"], cuenta["fuentes_leidas"],
             cuenta["fuentes_con_error"], cuenta["rechazadas_forma"], cuenta["descartadas_json"],
             malas, rc_perfil))
    return 1 if cuenta["fuentes_con_error"] else 0


def iso(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else NO_MEDIDO


def salud():
    db, _ = abrir_db()
    precios, _ = cargar_precios(entorno("TALENT_MEDIDOR_PRECIOS", os.path.join(SKILL, "config", "precios.tsv")))
    print("== /salud talent-medidor ==")
    for proveedor in ("claude", "codex"):
        cur = db.execute("SELECT count(*), max(ultima_ts), max(actualizado) FROM cursores WHERE proveedor=?",
                         (proveedor,)).fetchone()
        uni = db.execute("SELECT count(*) FROM usage_raw WHERE proveedor=?", (proveedor,)).fetchone()[0]
        print("fuente=%s cursores=%d ultima_ts=%s ultimo_tick=%s unidades=%d"
              % (proveedor, cur[0], iso(cur[1]), iso(cur[2]), uni))
    modelos = [r[0] for r in db.execute("SELECT DISTINCT model FROM usage_raw WHERE model IS NOT NULL")]
    fuera = sum(1 for m in modelos if m not in precios)
    sin_coste = db.execute("SELECT count(*) FROM usage_raw WHERE cost_estado=?", (NO_MEDIDO,)).fetchone()[0]
    print("modelo_fuera_de_catalogo=%d unidades_coste_no_medido=%d" % (fuera, sin_coste))
    for clave in ("rechazadas_forma", "descartadas_json", "aviso_perfil_rc2"):
        n = db.execute("SELECT COALESCE(sum(valor),0) FROM eventos WHERE clave=?", (clave,)).fetchone()[0]
        print("%s=%d" % (clave, n))
    return 0


def main(argv):
    if argv == ["--tick"]:
        return tick()
    if argv and argv[0] == "--bootstrap" and set(argv[1:]) <= {"--diagnostico"}:
        if os.environ.get("TALENT_MEDIDOR_BAJO_NICE") != "1":
            env = dict(os.environ, TALENT_MEDIDOR_BAJO_NICE="1")
            os.execvpe("nice", ["nice", "-n", "19", sys.executable, os.path.abspath(__file__)] + argv, env)
        if "--diagnostico" in argv:
            print("niceness=%d" % os.nice(0))
            return 0
        return tick()
    if argv == ["--salud"]:
        return salud()
    sys.stdout.write(__doc__)
    return 0 if argv in (["-h"], ["--help"]) else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
