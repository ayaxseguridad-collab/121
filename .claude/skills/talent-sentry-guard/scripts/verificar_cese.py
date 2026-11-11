#!/usr/bin/env python3
"""verificar_cese.py — E/D/5A: ¿cesó el error TRAS el deploy del fix? TAL-5157 §B5/§B7.

E/D/5A = *Error apagado / Deploy identificado / verificado en prod*. El criterio
de cierre del contrato (references/04): **cifra EXACTA** de eventos nuevos del
grupo Sentry en la ventana ≥N h POSTERIOR al release del fix, con el sha del
release. «0 eventos en 3h30m» (patrón real TAL-4725), NUNCA adjetivos.

FLUJO:
  1. Ancla de release LIVE: consulta el release `<SENTRY_RELEASE_PREFIX>@<sha8>` en la
     API de releases de Sentry (fuente fiable). Si Sentry aún no lo vio → NO
     está LIVE todavía → sale sin sellar (reintentar). Corroboración best-effort
     por `railway status --json` (exit + JSON válido, gotcha #10): si detecta
     `NEEDS_APPROVAL`, lo CANTA y sale — el Vigía REPORTA, no aprueba (límite B9).
  2. Cuenta eventos del grupo (shortId) estrictamente DESPUÉS del ancla, en la
     ventana declarada. Solo LECTURA.
  3. Sella `SENTRY-VERIFICA-<TAL>-OK` (0 eventos, filtro start/end verificado por
     CONDUCTA esta corrida), `-CONSULTA` (≥1, o ventana/release aún no listos) o
     `-NO-MEDIDO` (0 eventos, pero el filtro start/end del endpoint NO se pudo
     confirmar esta corrida — NUNCA se declara cese sin esa confirmación).

GARANTÍA DEL FILTRO start/end (hallazgo TAL-5157, re-auditoría ronda de bounce
#2165): `contar_eventos()` depende de que Sentry filtre por `start`/`end` en
`/issues/{id}/events/`. Eso está documentado (docs.sentry.io/api/events/
list-an-issues-events/, consultado 2026-09-03 vía `date -u` (fecha real de
consulta, no anotada a mano — corrección M4, r2 del bounce #2165: la fecha
publicada antes era futura respecto del reloj y del propio commit, lo que
invalidaba el vendor-claim aunque la URL fuera correcta). RECIBO de la
medición (veredicto r3 del bounce #2165: "M4 carece de recibo histórico de
`date -u`" — la cita sola no basta, hace falta el output crudo del comando
que la produjo): `date -u '+%Y-%m-%dT%H:%M:%SZ'` -> `2026-09-03T21:36:40Z`,
corroborable contra el autor-timestamp real del commit que introduce este
recibo (`git log -1 --format=%cI` sobre ese commit). El endpoint GET
`/api/0/organizations/{org}/issues/{issue_id}/events/` lista `start`/`end`/
`statsPeriod` como parámetros reales de filtrado) — pero una documentación
acredita la INTENCIÓN del proveedor, no la CONDUCTA de esta instancia (versión
de API, plan de Sentry, cambio silencioso). Por eso `filtro_start_end_verificado()`
comprueba en cada corrida, por conducta, que el filtro realmente actúa —
ver su docstring. Sin esa confirmación, el script FALLA CERRADO: sella
NO-MEDIDO, nunca OK. Esto NO se ha verificado empíricamente contra la
instancia real de Sentry desde este canal (sin credenciales) — la garantía en
runtime es la que cierra el hueco, no la cita documental por sí sola.

LÍMITES (duros): NO cierra la issue de Linear (lo hace `closes TAL-N` del PR).
NO aprueba deploys. NO resuelve/ignora el grupo en Sentry. NO muta nada.

Contrato de acceso (references/05): identidad por ENV (sin default de marca,
25b/c/e); token por header-file 0600 (SENTRY_HDR), JAMÁS impreso; User-Agent
explícito en toda petición.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


def die(msg: str, code: int = 1) -> None:
    print(f"verificar_cese: {msg}", file=sys.stderr)
    sys.exit(code)


def env_requerido(nombre: str) -> str:
    val = os.environ.get(nombre, "").strip()
    if not val:
        die(f"config ausente: {nombre} obligatorio por entorno (sin default de marca)")
    return val


def clave_team() -> str:
    """Clave del team Linear de la INSTANCIA (TAL-8037): jamás un default de casa. FAIL-CLOSED: env
    TF_LINEAR_TEAM_KEY → línea TF_LINEAR_TEAM_KEY= del manifiesto TF_MANIFEST (ruta absoluta, leída como
    DATO, sin ejecutarla) → die() nombrando la variable. Formato ^[A-Z][A-Z0-9]{0,9}$ (también el del env)."""
    key = os.environ.get("TF_LINEAR_TEAM_KEY", "").strip()
    if not key:
        mf = os.environ.get("TF_MANIFEST", "").strip()
        if mf:
            if not mf.startswith("/"):
                die(f"TF_MANIFEST debe ser ruta ABSOLUTA ({mf})")
            p = Path(mf)
            if p.is_file():
                for ln in p.read_text().splitlines():
                    m = re.match(r'^TF_LINEAR_TEAM_KEY=(?:"([^"]*)"|([^\s"#]*))', ln)
                    if m:
                        key = (m.group(1) if m.group(1) is not None else m.group(2)).strip()
    if not key:
        die("TF_LINEAR_TEAM_KEY sin resolver: ni la variable de entorno ni la línea TF_LINEAR_TEAM_KEY= "
            "del manifiesto (TF_MANIFEST) — fail-closed, jamás se asume una clave")
    if not re.fullmatch(r"[A-Z][A-Z0-9]{0,9}", key):
        die(f"TF_LINEAR_TEAM_KEY inválida ('{key}'): se espera ^[A-Z][A-Z0-9]{{0,9}}$")
    return key


def release_nombre(release: str) -> str:
    """`<prefijo>@<sha8>`: el prefijo del release de Sentry es de la INSTANCIA (SENTRY_RELEASE_PREFIX, obligatorio
    por entorno — TAL-8037: sin default de marca). Charset cerrado: el nombre viaja a la URL de la API."""
    pref = env_requerido("SENTRY_RELEASE_PREFIX")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", pref):
        die(f"SENTRY_RELEASE_PREFIX inválido ('{pref}'): se espera [A-Za-z0-9._-]+")
    return f"{pref}@{release}"


def leer_authorization(hdr_path: Path) -> str:
    if not hdr_path.is_file():
        die(f"header-file ausente: {hdr_path}")
    modo = oct(hdr_path.stat().st_mode & 0o777)
    if modo != "0o600":
        die(f"header-file con permisos inseguros ({modo}, se exige 0o600): {hdr_path}")
    lineas = [ln for ln in hdr_path.read_text().splitlines() if ln.strip()]
    if len(lineas) != 1 or not lineas[0].startswith("Authorization: "):
        die("header-file con contenido inesperado (una línea 'Authorization: <valor>')")
    return lineas[0][len("Authorization: "):]


# --- funciones puras (testables offline) ------------------------------------

def parse_ventana(ventana: str) -> timedelta:
    """Nh / Nd → timedelta. Sin otra forma aceptada (evita ambigüedad)."""
    m = re.fullmatch(r"(\d+)([hd])", ventana)
    if not m:
        die(f"--ventana inválida: '{ventana}' (usa Nh o Nd, p. ej. 3h)")
    n = int(m.group(1))
    return timedelta(hours=n) if m.group(2) == "h" else timedelta(days=n)


def parse_iso(s: str) -> datetime:
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        die(f"timestamp ISO inválido: '{s}'")
        raise  # unreachable
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def validar_sha8(sha: str) -> str:
    """El sha del release viaja a la URL — formato estricto para no inyectar."""
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        die(f"--release inválido: '{sha}' (se espera un sha git hex de 7-40, p. ej. a1b2c3d4)")
    return sha


def validar_tal(tal: str) -> str:
    clave = clave_team()
    if not re.fullmatch(rf"{clave}-\d+", tal):
        die(f"--tal inválido: '{tal}' (se espera {clave}-<n>)")
    return tal


def validar_short_id(short_id: str) -> str:
    """Hallazgo del texto CR-CLI (corrida 2), medido y confirmado real:
    `--release`/`--tal` tienen validador de formato dedicado
    (`validar_sha8`/`validar_tal`, comentario "viaja a la URL — formato
    estricto para no inyectar"); `--short-id` NO tenía ninguno pese a viajar
    igual de literal a la URL en `resolver_issue_id()`. Formato real de
    Sentry: `PROYECTO-EN-MAYUS-BASE32` (p. ej. `ACADEMIA-EJEMPLO-2-0-XX`,
    references/04-contrato-de-issue.md)."""
    if not re.fullmatch(r"[A-Z0-9][A-Z0-9-]*", short_id):
        die(f"--short-id inválido: '{short_id}' (se espera MAYÚSCULAS/dígitos/guiones, p. ej. ACADEMIA-EJEMPLO-2-0-XX)")
    return short_id


def parse_railway_status(out: str) -> tuple[bool, str | None]:
    """Corroboración best-effort. Devuelve (json_valido, estado_deploy|None).
    NO inventa campos: si el JSON no expone un status de deployment reconocible,
    estado=None (no es fallo — el ancla fiable es Sentry). Gotcha #10: validar
    que parsea como JSON; el CLI emite texto plano cuando falla."""
    try:
        d = json.loads(out)
    except (json.JSONDecodeError, TypeError):
        return (False, None)
    # Buscamos un status de deployment SOLO en campos conocidos-plausibles, sin
    # asumir que existen (el `railway status --json` es el objeto `project`).
    for clave in ("latestDeployment", "deployment"):
        v = d.get(clave) if isinstance(d, dict) else None
        if isinstance(v, dict) and isinstance(v.get("status"), str):
            return (True, v["status"])
    if isinstance(d, dict) and isinstance(d.get("status"), str):
        return (True, d["status"])
    return (True, None)


def decidir_sello(tal: str, release: str, count: int, ventana: str,
                  ancla_iso: str, capado: bool, filtro_ok: bool | None) -> tuple[str, int]:
    """OK si 0 eventos nuevos Y el filtro start/end quedó VERIFICADO por conducta
    esta corrida (filtro_ok is True). Si count==0 pero filtro_ok NO es True
    (False = refutado por conducta; None = sin base para comparar esta corrida),
    NUNCA se declara cese — sella NO-MEDIDO, exit 5 (fail-closed: la ausencia de
    prueba no es prueba de ausencia). CONSULTA para cualquier count>0 — ahí
    filtro_ok es irrelevante: un conteo positivo ya certifica que el error NO
    cesó, acote bien o mal la ventana. La CIFRA va literal en el sello (con '≥'
    si la cuenta se capó por paginación)."""
    cifra = f"≥{count}" if capado else f"{count}"
    base = (f"release={release_nombre(release)} ancla={ancla_iso} ventana={ventana} "
            f"eventos_nuevos={cifra}")
    if count == 0 and not capado:
        if filtro_ok is not True:
            motivo = ("filtro start/end REFUTADO por conducta esta corrida" if filtro_ok is False
                       else "sin base para verificar el filtro start/end esta corrida")
            return (f"SENTRY-VERIFICA-{tal}-NO-MEDIDO {base} ({motivo} — NO se declara cese)", 5)
        return (f"SENTRY-VERIFICA-{tal}-OK {base}", 0)
    return (f"SENTRY-VERIFICA-{tal}-CONSULTA {base} (el error NO cesó — no cerrar)", 3)


def parse_next_cursor(link_header: str | None) -> str | None:
    """Paginación de Sentry: cabecera Link con rel="next"; results="true" si hay
    más. Devuelve la URL siguiente o None."""
    if not link_header:
        return None
    for parte in link_header.split(","):
        seg = parte.strip()
        if 'rel="next"' in seg and 'results="true"' in seg:
            m = re.search(r"<([^>]+)>", seg)
            if m:
                return m.group(1)
    return None


def _parse_iso_safe(s: str | None) -> datetime | None:
    """Como parse_iso, pero devuelve None en vez de morir — para usar dentro de
    una guarda defensiva que NO debe abortar el proceso si firstSeen viene
    ausente o mal formado (eso es 'sin base para comparar', no un error fatal)."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def filtro_start_end_verificado(org: str, issue_id: str, first_seen_iso: str | None,
                                ancla: datetime, fin: datetime, count_estrecho: int,
                                authorization: str, ua: str) -> bool | None:
    """Verifica POR CONDUCTA (no por documentación) que /issues/{id}/events/
    realmente filtra por start/end — hallazgo TAL-5157 más importante de la
    re-auditoría de #2165 (ver comentario de ancla documental en la cabecera
    del módulo). Método: compara el conteo YA obtenido en la ventana ESTRECHA
    [ancla, fin] contra una ventana DELIBERADAMENTE MÁS ANCHA [firstSeen, fin]
    que incluye TODO el histórico del grupo. Si el filtro actúa, ancho >=
    estrecho SIEMPRE — y ESTRICTAMENTE mayor si firstSeen < ancla (el grupo
    tiene, por definición, al menos su primer evento antes de la ventana
    estrecha). Si son IGUALES pese a esa garantía, el filtro NO está actuando.

    Devuelve:
      True  — filtro CONFIRMADO esta corrida (ancho > estrecho).
      False — filtro REFUTADO esta corrida (ancho == estrecho pese a firstSeen
              < ancla; o ancho < estrecho, una anomalía imposible bajo un
              filtro correcto — fail-closed igual).
      None  — SIN BASE para comparar esta corrida (firstSeen ausente/inválido,
              firstSeen >= ancla — el grupo no garantiza actividad previa —, o
              el conteo ancho se capó por paginación y ya no es comparable con
              confianza). None se trata IGUAL que False en decidir_sello: la
              ausencia de prueba no es prueba de ausencia.
    """
    first_seen = _parse_iso_safe(first_seen_iso)
    if first_seen is None or first_seen >= ancla:
        return None
    ancho_count, ancho_capado = contar_eventos(org, issue_id, first_seen, fin, authorization, ua)
    if ancho_capado:
        return None
    if ancho_count < count_estrecho:
        return False
    return ancho_count > count_estrecho


def window_has_elapsed(ancla: datetime, ventana_td: timedelta, now: datetime) -> bool:
    """¿Ha VENCIDO ya la ventana [ancla, ancla+ventana)? Función PURA — testable y
    mutable en AISLAMIENTO (BLOQ3 TAL-5157). El sello OK exige que la ventana haya
    transcurrido; contar eventos con `fin` en el futuro certificaría un silencio que
    aún no ha ocurrido. Retirar este guard (mutante) hace que se selle prematuramente."""
    return now >= ancla + ventana_td


# --- I/O contra Sentry / Railway (corre en el HOST) -------------------------

def _get(url: str, authorization: str, ua: str) -> tuple[int, dict | list | None, str | None]:
    """Hallazgo del texto CR-CLI (corridas 1 y 3, idéntico en ambas), medido y
    confirmado real: solo se capturaba `HTTPError` — un fallo de RED
    (DNS, conexión rehusada, timeout de socket → `URLError`/`TimeoutError`) o
    una respuesta 200 con body NO-JSON (`json.JSONDecodeError`) escapaban sin
    capturar, como TRACEBACK crudo en vez de un `die()` controlado. Tercer
    caso de la misma familia que los hallazgos 7/10 de ronda 1: un fallo del
    INSTRUMENTO (la red, no Sentry) que no caía en su casilla de exit code.
    Se cierra con el MISMO exit code 4 ("no se puede verificar todavía") que
    ya usa el caller para "release aún no LIVE" — un fallo de red es,
    exactamente igual, un motivo legítimo de reintento, no de cese."""
    req = urllib.request.Request(url)
    req.add_header("Authorization", authorization)
    req.add_header("User-Agent", ua)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            crudo = resp.read()
            try:
                body = json.loads(crudo)
            except json.JSONDecodeError:
                die(f"sentry: respuesta no-JSON (HTTP {resp.status}) en {url.split('?')[0]}", 4)
                raise  # unreachable
            return (resp.status, body, resp.headers.get("Link"))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            die(f"sentry: {e.code} credencial inválida/sin scope")
        return (e.code, None, None)
    except (urllib.error.URLError, TimeoutError) as e:
        die(f"sentry: fuente inalcanzable ({type(e).__name__}) en {url.split('?')[0]} — reintentar", 4)
        raise  # unreachable


def release_live_at(org: str, release: str, authorization: str, ua: str) -> str | None:
    """Ancla desde la API de releases de Sentry. None SOLO si Sentry aún no vio
    el release (404 ⇒ no LIVE todavía, caso legítimo de reintento). Prefiere
    dateReleased > firstEvent > dateCreated.

    Un 200 con body válido pero SIN ninguno de los tres campos de fecha es un
    caso DISTINTO: el release SÍ existe pero la respuesta tiene un shape
    inesperado (versión de API distinta, campo renombrado). Eso NO es "aún no
    visto" — tratarlo igual que un 404 (return None → reintentar en silencio)
    escondería una anomalía real detrás del mensaje "todavía no está LIVE".
    Muere en vez de reintentar: hallazgo TAL-5157, re-auditoría de #2165."""
    url = f"https://sentry.io/api/0/organizations/{org}/releases/{release_nombre(release)}/"
    status, body, _ = _get(url, authorization, ua)
    if status == 404:
        return None
    if status != 200 or not isinstance(body, dict):
        die(f"sentry releases: HTTP {status} inesperado")
    for campo in ("dateReleased", "firstEvent", "dateCreated"):
        if body.get(campo):
            return str(body[campo])
    die(f"sentry releases: release {release_nombre(release)} presente (200) pero sin "
        f"dateReleased/firstEvent/dateCreated — shape de API inesperado, no es 'aún no visto'")
    raise  # unreachable


def resolver_issue_id(org: str, short_id: str, authorization: str, ua: str) -> tuple[str, str | None]:
    """Devuelve (issue_id, firstSeen|None) del grupo con ese shortId.

    La URL llevaba el parámetro `query` DUPLICADO
    (`?query=is:unresolved&shortIdLookup=1&query={short_id}`) — construcción
    objetivamente rota: cuál de los dos gana (o si Sentry los combina) no
    estaba verificado ni testeado. `shortIdLookup=1` es el modo de búsqueda
    EXACTA por shortId; no se combina con un filtro adicional de estado porque
    el grupo puede necesitar encontrarse AUNQUE ya esté resuelto en Sentry (el
    propio caller decide qué hacer si no hay match — ver el die() de abajo).
    Hallazgo TAL-5157, re-auditoría de #2165."""
    url = (f"https://sentry.io/api/0/organizations/{urllib.parse.quote(org, safe='')}/issues/"
           f"?shortIdLookup=1&query={urllib.parse.quote(short_id, safe='')}")
    status, body, _ = _get(url, authorization, ua)
    if status != 200 or not isinstance(body, list):
        die(f"sentry issues: HTTP {status} inesperado al resolver {short_id}")
    for g in body:
        if g.get("shortId") == short_id:
            return (str(g.get("id")), g.get("firstSeen"))
    die(f"sentry: no encontré el grupo shortId={short_id} (¿ya resuelto? entonces no hay eventos que contar)")
    raise  # unreachable


def contar_eventos(org: str, issue_id: str, start: datetime, end: datetime,
                   authorization: str, ua: str, cap_paginas: int = 20) -> tuple[int, bool]:
    """Cuenta eventos del grupo en [start, end]. Devuelve (count, capado)."""
    start_iso = start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    end_iso = end.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    url = (f"https://sentry.io/api/0/organizations/{org}/issues/{issue_id}/events/"
           f"?start={start_iso}&end={end_iso}&full=false")
    total = 0
    for _ in range(cap_paginas):
        status, body, link = _get(url, authorization, ua)
        if status != 200 or not isinstance(body, list):
            die(f"sentry events: HTTP {status} inesperado")
        total += len(body)
        nxt = parse_next_cursor(link)
        if not nxt:
            return (total, False)
        url = nxt
    return (total, True)  # se agotó el cap → count es un mínimo


def corroborar_railway(cli: str, expected: str | None) -> str | None:
    """Best-effort. Devuelve el estado de deploy si el CLI lo expone Y —cuando
    `expected` se declara— el proyecto de la sesión CLI coincide con él. El
    campo canónico de identidad es `.name` a nivel raíz del objeto `project`
    (mismo campo verificado contra railwayapp/cli que usa check_railway de
    sentry_doctor.sh — "tienes el patrón en casa"). Antes `expected` se recibía
    y NUNCA se usaba: un parámetro sin efecto es una comprobación que el lector
    cree que existe y no existe — si la sesión del CLI apuntara al proyecto
    equivocado, este script habría confiado en SU estado de deploy sin
    detectarlo. Hallazgo TAL-5157, re-auditoría de #2165.

    LÍMITE DECLARADO (r2 del bounce, MENOR): `expected` es OPCIONAL — si el
    caller no lo pasa (p. ej. `SENTRY_DOCTOR_RAILWAY_EXPECTED` sin configurar),
    la identidad NO se valida y se confía en el estado tal cual, igual que
    antes de este hallazgo. Esto es aceptable SOLO porque `corroborar_railway`
    es puramente best-effort (Sentry es el ancla fiable, NUNCA esta función) —
    pero si el parámetro es opcional, el guard de identidad también lo es: no
    se afirma más protección de la que hay cuando `expected` está ausente.
    Si el estado es NEEDS_APPROVAL, el caller lo canta y NO aprueba."""
    try:
        r = subprocess.run([cli, "status", "--json", "--environment", "production"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        proyecto = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    if expected and (not isinstance(proyecto, dict) or proyecto.get("name") != expected):
        print(f"verificar_cese: railway status corresponde a un proyecto distinto del "
              f"esperado ('{expected}') — corroboración best-effort DESCARTADA, no se usa "
              f"su estado de deploy", file=sys.stderr)
        return None
    ok, estado = parse_railway_status(r.stdout)
    return estado if ok else None


def main() -> int:
    ap = argparse.ArgumentParser(description="E/D/5A: verifica el cese post-deploy de un grupo Sentry.")
    ap.add_argument("--tal", required=True, help="issue Linear del fix (TAL-<n>) — va en el sello")
    ap.add_argument("--release", required=True, help="sha8 del release del fix (<SENTRY_RELEASE_PREFIX>@<sha8>)")
    ap.add_argument("--short-id", required=True, help="shortId del grupo Sentry a vigilar")
    ap.add_argument("--ventana", default="3h", help="ventana post-release (Nh/Nd, default 3h)")
    ap.add_argument("--desde", default=None,
                    help="ISO del release LIVE (override); por defecto se resuelve de la API de releases de Sentry")
    ap.add_argument("--poll", type=int, default=0,
                    help="si el release aún no está LIVE, reintentar N veces cada 60s (default 0: no espera)")
    args = ap.parse_args()

    tal = validar_tal(args.tal)
    release = validar_sha8(args.release)
    short_id = validar_short_id(args.short_id)
    ventana_td = parse_ventana(args.ventana)
    release_nombre(release)   # TAL-8037: SENTRY_RELEASE_PREFIX es obligatorio — falla ANTES de tocar la red
    ua = "talent-sentry-guard-verifica/1"

    org = env_requerido("SENTRY_ORG")
    hdr = Path(os.environ.get("SENTRY_HDR", str(Path.home() / ".vigia-sentry" / "hdr")))
    authorization = leer_authorization(hdr)

    # 1) Ancla de release LIVE
    ancla_iso = args.desde
    if not ancla_iso:
        intentos = args.poll + 1
        for i in range(intentos):
            ancla_iso = release_live_at(org, release, authorization, ua)
            if ancla_iso:
                break
            if i < intentos - 1:
                print(f"release {release_nombre(release)} aún no visto por Sentry — "
                      f"reintento {i+1}/{args.poll} en 60s", file=sys.stderr)
                time.sleep(60)
        if not ancla_iso:
            print(f"SENTRY-VERIFICA-{tal}-CONSULTA release={release_nombre(release)} "
                  f"aún NO está LIVE en Sentry — no se puede verificar el cese todavía", file=sys.stdout)
            return 4

    ancla = parse_iso(ancla_iso)

    # Corroboración best-effort por Railway (NUNCA aprueba)
    cli = os.environ.get("SENTRY_DOCTOR_RAILWAY_CLI", "railway")
    estado_rw = corroborar_railway(cli, os.environ.get("SENTRY_DOCTOR_RAILWAY_EXPECTED"))
    if estado_rw == "NEEDS_APPROVAL":
        print(f"SENTRY-VERIFICA-{tal}-CONSULTA release={release_nombre(release)} "
              f"el deploy está en NEEDS_APPROVAL — el Vigía REPORTA, NO aprueba (destrabar: railway-approve.sh)",
              file=sys.stdout)
        return 4
    if estado_rw:
        print(f"(railway corrobora estado de deploy: {estado_rw})", file=sys.stderr)

    # 2) La ventana debe haber TRANSCURRIDO antes de poder sellar — contar
    #    eventos en [ancla, fin) con fin en el futuro certifica un silencio
    #    que aún no ha ocurrido (NO-GO #1, TAL-5157 r11). Sale sin sellar
    #    (mismo tratamiento que "release aún no LIVE": CONSULTA + exit 4,
    #    para que el cron reintente) hasta que `ahora >= fin`.
    fin = ancla + ventana_td
    ahora = datetime.now(timezone.utc)
    if not window_has_elapsed(ancla, ventana_td, ahora):
        restante = fin - ahora
        print(f"SENTRY-VERIFICA-{tal}-CONSULTA release={release_nombre(release)} ancla={ancla_iso} "
              f"ventana={args.ventana} fin={fin.isoformat()} — la ventana AÚN NO transcurrió "
              f"(faltan {restante}) — no se puede sellar todavía", file=sys.stdout)
        return 4

    # 3) Contar eventos del grupo en la ventana YA transcurrida
    issue_id, first_seen_iso = resolver_issue_id(org, short_id, authorization, ua)
    count, capado = contar_eventos(org, issue_id, ancla, fin, authorization, ua)

    # 3b) Guarda defensiva (solo si hace falta): "0 eventos" es la única cifra
    #     que puede convertirse en un cese falso si el filtro start/end no
    #     actúa — con count>0 el filtro es irrelevante (CONSULTA de todos
    #     modos), así que la llamada extra se evita cuando no aporta nada.
    filtro_ok: bool | None = None
    if count == 0 and not capado:
        filtro_ok = filtro_start_end_verificado(
            org, issue_id, first_seen_iso, ancla, fin, count, authorization, ua)

    # 4) Sellar con la CIFRA
    sello, code = decidir_sello(tal, release, count, args.ventana, ancla_iso, capado, filtro_ok)
    print(sello)
    print("(el Vigía NO cierra la issue: Linear pasa a Done por `closes TAL-N` del PR)", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
