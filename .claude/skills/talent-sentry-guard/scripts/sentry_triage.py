#!/usr/bin/env python3
"""sentry_triage.py — sucesor versionado del ciclo.sh de C3 (TAL-5157 §B7).

Un barrido de los grupos Sentry no-resueltos: fetch con retry + validación de
estructura, diff contra ~/.vigia-sentry/cursor.json, clasifica por los sets
declarados en references/03-buckets-y-baselines.md (NO embebidos aquí) e
imprime MONEY-PATH / NUEVOS / SIN-CLASIF / ESCALA. Silencio si no hay novedad.
`--json` para el watcher.

Contrato de acceso (references/05): identidad del tenant por ENV (sin default
de marca, invariantes 25b/c/e); token por header-file 0600 (SENTRY_HDR),
JAMÁS impreso ni en argv. Solo LECTURA de Sentry — no muta nada.

Límites: no crea issues (eso es crear_issue_desde_sentry.py), no cierra ni
resuelve grupos, no toca prod.
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
REF_BUCKETS = SKILL_DIR / "references" / "03-buckets-y-baselines.md"

# Patrones money-path (culprit/transaction) — terminal vs transitorio en 02-…
MONEY_TERMINAL = re.compile(
    r"gave_up|dead-letter|reconcile-fail|sale_not_pending|checkout|webhook|"
    r"stripe|mercadopago|nowpayments|paypal|refund|credit",
    re.IGNORECASE,
)


def die(msg: str, code: int = 1) -> None:
    print(f"sentry_triage: {msg}", file=sys.stderr)
    sys.exit(code)


def env_requerido(nombre: str) -> str:
    """Config obligatoria por ENV — sin default de marca (invariante 25e)."""
    val = os.environ.get(nombre, "").strip()
    if not val:
        die(f"config ausente: {nombre} obligatorio por entorno (sin default de marca)")
    return val


def leer_authorization(hdr_path: Path) -> str:
    """Lee EXACTAMENTE la línea 'Authorization: <valor>' de un header-file 0600.

    Nunca imprime el valor. Exige permisos 0600 (mismo contrato que el doctor).
    """
    if not hdr_path.is_file():
        die(f"header-file ausente: {hdr_path}")
    modo = oct(hdr_path.stat().st_mode & 0o777)
    if modo != "0o600":
        die(f"header-file con permisos inseguros ({modo}, se exige 0o600): {hdr_path}")
    lineas = [ln for ln in hdr_path.read_text().splitlines() if ln.strip()]
    if len(lineas) != 1 or not lineas[0].startswith("Authorization: "):
        die("header-file con contenido inesperado (una línea 'Authorization: <valor>')")
    return lineas[0][len("Authorization: "):]


def cargar_buckets() -> dict[str, list[str]]:
    """Parsea los bloques ```bucket:NOMBRE de references/03. Sets como DATOS.

    Hallazgo TAL-5157 M3 (re-auditoría del bounce #2165): si el fichero de
    referencia EXISTE pero no tiene NINGÚN bloque ```bucket: reconocible
    (formato editado mal, fences rotos), esta función devolvía `{}` en
    silencio — indistinguible de "inventario vacío a propósito". Aguas
    abajo, `clasifica()` con buckets={} hace que TODO grupo caiga en
    SIN-CLASIF/NUEVOS sin que nadie sepa que la taxonomía en sí está rota.
    Un inventario existente-pero-malformado es una ANOMALÍA, no un dato
    ("cero categorías") — muere en vez de degradar en silencio."""
    if not REF_BUCKETS.is_file():
        die(f"reference de buckets ausente: {REF_BUCKETS}")
    texto = REF_BUCKETS.read_text()
    buckets: dict[str, list[str]] = {}
    # bloques cercados ```bucket:NOMBRE ... ```
    for m in re.finditer(r"```bucket:([A-Z0-9\-]+)\n(.*?)```", texto, re.DOTALL):
        nombre = m.group(1)
        entradas = []
        for ln in m.group(2).splitlines():
            ln = ln.split("#", 1)[0].strip()  # quita comentarios y espacio
            if ln:
                entradas.append(ln)
        buckets[nombre] = entradas
    if not buckets:
        die(f"reference de buckets sin NINGÚN bloque ```bucket: reconocido — "
            f"inventario existente pero vacío/malformado, NO se interpreta como "
            f"'sin categorías' ({REF_BUCKETS})")
    return buckets


def clasifica(grupo: dict, buckets: dict[str, list[str]]) -> str | None:
    """Devuelve el nombre del bucket que matchea, o None (→ SIN-CLASIF).

    Hallazgo CRITICAL del texto CR-CLI (M3-BOUNCE-2165-FINDINGS, corridas 1 y 3,
    cruzado contra este censo): `e in short_id` era substring SIN delimitar —
    `A93` casaba con la entrada `93`, `8EF` con `8E`. Falso positivo de
    clasificación real: un grupo se atribuye al miembro equivocado.

    Medido contra `references/03-buckets-y-baselines.md` antes de aplicar (la
    entrada literal NO se usa a ciegas — dos corridas sugerían `e == short_id`
    estricto, dos sugerían sufijo delimitado por guion): el fichero vigente
    tiene entradas cortas reales (`8E`, `93`) que son taquigrafía del ÚLTIMO
    segmento del shortId completo (`ACADEMIA-EJEMPLO-2-0-8E`), no el shortId
    entero — un `== ` estricto las habría desactivado en silencio. El sufijo
    delimitado por guion cierra el hueco (rechaza `A93`/`8EF`, exactamente los
    casos que motivan el hallazgo) SIN romper la configuración viva."""
    culprit = (grupo.get("culprit") or "") + " " + (grupo.get("title") or "")
    short_id = grupo.get("shortId") or ""
    for nombre, entradas in buckets.items():
        for e in entradas:
            if e.startswith("re:"):
                if re.search(e[3:], culprit, re.IGNORECASE):
                    return nombre
            elif e and (e == short_id or short_id.endswith(f"-{e}")):
                return nombre
    return None


def hay_novedad_en(money: list, nuevos: list, sin_clasif: list, escala: list) -> bool:
    """`escala` cuenta como novedad (NO-GO #MAYOR-2, TAL-5157 r11): un ciclo
    donde LO ÚNICO nuevo es un ítem de escala (bucket conocido, gatillo
    disparado) no puede salir en silencio — silencio ≡ "nada que revisar".

    Extraída como función PURA (hallazgo TAL-5157 M2, re-auditoría del bounce
    #2165): antes esta expresión vivía inline dentro de `main()`, y el smoke
    que debía vigilarla la REIMPLEMENTABA localmente en el propio test — con
    lo que retirar `escala` del código productivo dejaba el harness entero
    en verde (el test medía su propia copia, nunca el código real). Ahora el
    test llama a ESTA función."""
    return bool(money or nuevos or sin_clasif or escala)


STATS_PERIOD_CONTRATO = ("24h", "14d")


def stats_period_para(since: str, desde: datetime, ahora: datetime) -> str:
    """Deriva el `statsPeriod` REAL a enviar a Sentry a partir de `--since`.

    Hallazgo TAL-5157 M1 (re-auditoría del bounce #2165), CORREGIDO EN DOS
    RONDAS:
    - r3 (primera versión, INSUFICIENTE): si `--since` era ISO, se traducía
      a horas arbitrarias (`240h`) para no perder la ventana pedida — pero
      el endpoint REAL que usa `fetch_issues` (`GET
      /api/0/projects/{org}/{project}/issues/`, "List a Project's Issues")
      documenta `statsPeriod` limitado a EXACTAMENTE `"24h"`, `"14d"` o
      vacío. Generar `"240h"` sale del contrato documentado sin evidencia
      ejecutable de que el servidor lo acepte — "aproximar" en vez de
      "acreditar". Además, un `--since` ISO en el FUTURO devolvía `"1h"`
      (el suelo `max(1, ...)`) en vez de rechazar un rango imposible.
    - r4 (esta versión, veredicto r3 del bounce): SIN aproximar. Solo se
      aceptan los DOS valores literales documentados con `desde`/`ahora`
      concretos (`""` queda fuera: este CLI siempre necesita un `desde`
      concreto para el resto de `main()`, no tiene sentido "sin ventana").
      Cualquier otro `--since` (ISO, `Nh`/`Nd` arbitrario) se RECHAZA — el
      operador debe pedir exactamente `24h` o `14d`, no una aproximación.
      Un rango en el FUTURO (`desde > ahora`) se rechaza con un mensaje
      propio, antes de llegar a la comprobación de contrato."""
    if desde > ahora:
        die(f"--since '{since}' implica un rango en el FUTURO (desde={desde.isoformat()} > "
            f"ahora={ahora.isoformat()}) — rango imposible, no se traduce a un statsPeriod válido")
    if since in STATS_PERIOD_CONTRATO:
        return since
    die(f"--since '{since}' no es uno de los valores documentados de statsPeriod para "
        f"GET /api/0/projects/<org>/<project>/issues/ (\"24h\" o \"14d\") — no se aproxima, "
        f"usa uno de esos dos valores literales")
    raise  # unreachable


def es_grupo_nuevo(prev: dict | None, first_seen: datetime | None, desde: datetime) -> bool:
    """Extraída como función PURA (hallazgo MAYOR del texto CR-CLI, corridas 1
    y 3, medido y confirmado real): `firstSeen` es INMUTABLE (fecha de la
    primera vez que Sentry vio el grupo, nunca cambia). Antes,
    `prev is None or first_seen >= desde` re-marcaba como "nuevo" el MISMO
    grupo en cada barrido mientras `desde` no avanzara más allá de su
    firstSeen — un grupo ya cursoreado (`prev` presente) nunca debía
    re-entrar por esa rama. `first_seen is None` (dato faltante/no parseable)
    sigue tratándose como nuevo en el primer barrido sin cursor — fail hacia
    visibilidad, no hacia silencio."""
    return prev is None and (first_seen is None or first_seen >= desde)


def trepo(prev: dict | None, count: int) -> bool:
    return prev is not None and count > int(prev.get("count", 0) or 0)


def enruta_item(es_nuevo: bool, trepo_: bool, bucket: str | None) -> str | None:
    """Devuelve 'nuevos'/'sin_clasif'/'escala' (routing de item.append) o
    None (no se añade a ninguna lista de novedad — sigue clasificado y
    estable). Extraída como función PURA (hallazgo MAYOR del texto CR-CLI,
    corrida 2, medido y confirmado real): un grupo YA clasificado en un
    bucket (`bucket is not None`) que TREPA (`trepo_`) no caía en NINGUNA
    rama antes — se perdía en silencio. Un grupo conocido que crece es
    exactamente el gatillo de re-escalada que ESCALA existe para vigilar."""
    if es_nuevo:
        return "nuevos" if bucket is None else "escala"
    if trepo_:
        return "sin_clasif" if bucket is None else "escala"
    if bucket is None:
        return "sin_clasif"
    return None


def parse_since(since: str) -> datetime:
    """--since acepta ISO (2026-09-02T00:00:00Z) o Nh / Nd.

    Hallazgo del texto CR-CLI (corrida 3), medido y confirmado real: un ISO
    SIN offset explícito (p. ej. "2026-09-02T00:00:00", sin `Z` ni `+00:00`)
    producía un datetime NAIVE. `stats_period_para()` lo resta de `ahora`
    (aware) y el bucle de clasificación lo compara con `first_seen` (aware,
    viene de Sentry) — ambas operaciones revientan con
    `TypeError: can't compare offset-naive and offset-aware datetimes` antes
    de llegar a ningún die() controlado. Se asume UTC cuando el offset falta
    (consistente con el resto del script, UTC-first)."""
    m = re.fullmatch(r"(\d+)([hd])", since)
    if m:
        n = int(m.group(1))
        delta = timedelta(hours=n) if m.group(2) == "h" else timedelta(days=n)
        return datetime.now(timezone.utc) - delta
    try:
        dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
    except ValueError:
        die(f"--since inválido: '{since}' (usa ISO, Nh o Nd)")
        raise  # unreachable
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


TOPE_PAGINAS = 20


def parse_next_cursor(link_header: str | None) -> str | None:
    """Paginación de Sentry: cabecera Link con rel="next"; results="true" si hay
    más. Devuelve la URL siguiente o None. Mismo cuerpo que el de
    verificar_cese.py (no es importable sin traer sus efectos)."""
    if not link_header:
        return None
    for parte in link_header.split(","):
        seg = parte.strip()
        if 'rel="next"' in seg and 'results="true"' in seg:
            m = re.search(r"<([^>]+)>", seg)
            if m:
                return m.group(1)
    return None


def url_siguiente_valida(url: str, org: str, project: str) -> bool:
    """La URL del `Link` solo vale si es EXACTAMENTE el endpoint de issues del proyecto (otra página del
    mismo listado): https, host `sentry.io` sin usuario ni puerto, sin fragmento y con la ruta IGUAL a
    `/api/0/projects/<org>/<project>/issues/`. Un prefijo no basta: `…/issues/../../otro/issues/` o un
    segmento extra empiezan por el endpoint y apuntan a otra cosa. Se compara la ruta cruda (que no admite
    `.`/`..`, `//` ni `%`) Y la ruta normalizada tras decodificar, contra el endpoint exacto; el token
    solo viaja a una URL que pasa las dos."""
    try:
        partes = urllib.parse.urlsplit(url)
        host, puerto = partes.hostname, partes.port
    except ValueError:
        return False
    endpoint = f"/api/0/projects/{org}/{project}/issues/"
    ruta_norm = posixpath.normpath(urllib.parse.unquote(partes.path))
    return (partes.scheme == "https" and host == "sentry.io" and puerto is None
            and partes.netloc == "sentry.io" and not partes.fragment
            and partes.path == endpoint
            and ruta_norm + "/" == endpoint)


def _pedir_pagina(url: str, authorization: str) -> tuple[list[dict], str | None]:
    """Una página de issues y su cabecera Link. Retry en transitorios (es
    LECTURA, retry seguro)."""
    req = urllib.request.Request(url)
    req.add_header("Authorization", authorization)
    req.add_header("User-Agent", "talent-sentry-guard-triage/1")
    ultimo_err = None
    for intento in range(3):
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                if resp.status != 200:
                    die(f"sentry: HTTP {resp.status} (se esperaba 200)")
                data = json.loads(resp.read())
                if not isinstance(data, list):
                    die("sentry: la respuesta no es una lista (shape inesperado)")
                if not all(isinstance(g, dict) for g in data):
                    die("sentry: la lista contiene elementos que no son objetos (shape inesperado)")
                return data, resp.headers.get("Link")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                die(f"sentry: {e.code} credencial inválida/sin scope")
            ultimo_err = e
        except (urllib.error.URLError, TimeoutError) as e:
            ultimo_err = e
        time.sleep(2 * (intento + 1))
    die(f"sentry: fuente inalcanzable tras 3 intentos ({ultimo_err})")
    raise  # unreachable


def fetch_issues(org: str, project: str, authorization: str, stats_period: str, sort: str) -> list[dict]:
    """GET issues del PROYECTO configurado (NO org-wide — NO-GO #MAYOR-1,
    TAL-5157 r11: el endpoint org-scoped puede devolver grupos de otra
    superficie si la org tiene más de un proyecto Sentry). Mismo endpoint
    project-scoped ya verificado por sentry_doctor.sh (check_sentry).

    Sigue el cursor de Sentry (Link rel="next"; results="true") hasta agotarlo:
    lo que queda fuera de la primera página también se mira. Fail-closed:
    más de TOPE_PAGINAS páginas, una URL siguiente fuera del endpoint del
    proyecto (el token no viaja a otro destino) o repetida es un fallo, jamás
    una lista truncada en silencio. Sin duplicados entre páginas."""
    base = f"https://sentry.io/api/0/projects/{org}/{project}/issues/"
    url = f"{base}?query=is:unresolved&sort={sort}&statsPeriod={stats_period}"
    visitadas = {url}
    ids: set[str] = set()
    grupos: list[dict] = []
    for _ in range(TOPE_PAGINAS):
        pagina, link = _pedir_pagina(url, authorization)
        for g in pagina:
            clave = g.get("id") or g.get("shortId")
            if clave is not None:
                if clave in ids:
                    continue
                ids.add(clave)
            grupos.append(g)
        siguiente = parse_next_cursor(link)
        if siguiente is None:
            return grupos
        if not url_siguiente_valida(siguiente, org, project):
            die("sentry: la paginación apunta fuera del endpoint de issues del proyecto — no se sigue")
        if siguiente in visitadas:
            die("sentry: la paginación repite una página ya leída (bucle) — no se sigue")
        visitadas.add(siguiente)
        url = siguiente
    die(f"sentry: más de {TOPE_PAGINAS} páginas de issues (sort={sort}) — el barrido no se trunca en silencio")
    raise  # unreachable


def cargar_cursor(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        die(f"cursor.json existe pero no parsea: {path}")
        raise  # unreachable


def guardar_cursor(path: Path, vistos: dict[str, dict]) -> None:
    """Persiste el baseline de ESTE barrido — por grupo, `lastSeen`/`count`
    (references/01:18-20). Sin esto el próximo barrido nunca tiene cursor
    contra el que diferenciar y los mismos grupos reaparecen como nuevos
    indefinidamente (NO-GO #MAYOR-3, TAL-5157 r11). Escritura atómica
    (tmp + rename) — `sentry_doctor.sh` exige `cursor.json` JSON válido
    antes de abrir la puerta; un write a medias lo rompería."""
    nuevo = {
        gid: {"lastSeen": g.get("lastSeen"), "count": int(g.get("count", 0) or 0)}
        for gid, g in vistos.items()
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(nuevo, ensure_ascii=False))
    tmp.replace(path)


def main() -> int:
    ap = argparse.ArgumentParser(description="Barrido de triage Sentry (read-only).")
    ap.add_argument("--since", default="24h",
                     help="statsPeriod documentado de la API: 24h o 14d, literal (default 24h)")
    ap.add_argument("--json", action="store_true", help="salida JSON para el watcher")
    ap.add_argument(
        "--no-cursor", action="store_true",
        help="ignora el cursor (clasifica todo lo del período, no solo el delta)",
    )
    ap.add_argument(
        "--grupos", action="store_true",
        help="con --json, añade total_unresolved y la lista compacta de grupos (parte de guardia)",
    )
    args = ap.parse_args()
    if args.grupos and not args.json:
        ap.error("--grupos exige --json")

    org = env_requerido("SENTRY_ORG")
    project = env_requerido("SENTRY_PROJECT")
    hdr = Path(os.environ.get("SENTRY_HDR", str(Path.home() / ".vigia-sentry" / "hdr")))
    cursor_path = Path(
        os.environ.get("SENTRY_CURSOR", str(Path.home() / ".vigia-sentry" / "cursor.json"))
    )

    authorization = leer_authorization(hdr)
    buckets = cargar_buckets()
    desde = parse_since(args.since)
    stats_period = stats_period_para(args.since, desde, datetime.now(timezone.utc))
    cursor = {} if args.no_cursor else cargar_cursor(cursor_path)

    # dos pases (date + freq), dedup por id
    vistos: dict[str, dict] = {}
    for sort in ("date", "freq"):
        for g in fetch_issues(org, project, authorization, stats_period, sort):
            vistos[g.get("id", g.get("shortId", ""))] = g

    # Persiste el baseline de ESTE barrido ANTES de cualquier return (json o
    # texto) — todo camino de salida debe dejar cursor.json al día. Se omite
    # SOLO con --no-cursor (ese modo es "ignora el cursor", lectura Y
    # escritura, para no pisar el baseline real del ciclo automático con una
    # auditoría ad-hoc de todo el período).
    #
    # REFUTADO (texto CR-CLI, corrida 3, hallazgo "mueve guardar_cursor
    # después de clasificar/emitir"): medido contra el commit 93dc7e04e
    # (`git log -p`) — ANTES de esta línea, `guardar_cursor()` NO se llamaba
    # NUNCA, y los mismos grupos reaparecían como "nuevos" indefinidamente
    # (el bug que esta llamada temprana existe para cerrar). Moverla a
    # después del bloque de impresión exige replicar la llamada en los TRES
    # puntos de retorno (json / silencio-sin-novedad / reporte completo) o
    # perder la garantía "todo camino de salida persiste" que motivó ponerla
    # aquí — un riesgo real de reintroducir el bug original por un exit path
    # olvidado. La preocupación de fondo (un crash EN la clasificación deja
    # el cursor ya actualizado y el reporte de este barrido perdido para
    # siempre) es real y se cierra distinto: el bloque de abajo ya no puede
    # reventar por `count`/`userCount` no numéricos (try/except defensivo).
    if not args.no_cursor:
        guardar_cursor(cursor_path, vistos)

    money, nuevos, sin_clasif, escala = [], [], [], []
    for gid, g in vistos.items():
        short_id = g.get("shortId", "")
        prev = cursor.get(gid) or cursor.get(short_id)
        try:
            first_seen = datetime.fromisoformat((g.get("firstSeen") or "").replace("Z", "+00:00"))
        except ValueError:
            first_seen = None
        # count/userCount defensivos (hallazgo propio, cruce con el texto
        # CR-CLI): Sentry los sirve como string; un valor no numérico
        # inesperado hacía `int()` reventar main() a mitad del barrido —
        # DESPUÉS de que guardar_cursor() ya persistiera el baseline (línea
        # arriba, deliberado — ver nota `es_nuevo`). Sin esta guarda, ese
        # crash pierde el reporte ENTERO del barrido en curso Y el cursor ya
        # actualizado hace que la próxima corrida no vuelva a intentarlo:
        # exactamente "el productor que muere produce cero, y el cero se lee
        # como dato". 0 es conservador (nunca infla trepó/money-path).
        try:
            count = int(g.get("count", 0) or 0)
        except (TypeError, ValueError):
            count = 0
        try:
            user_count = int(g.get("userCount", 0) or 0)
        except (TypeError, ValueError):
            user_count = 0
        es_nuevo = es_grupo_nuevo(prev, first_seen, desde)
        trepó = trepo(prev, count)

        bucket = clasifica(g, buckets)
        item = {
            "shortId": short_id, "title": g.get("title", ""), "count": count,
            "userCount": user_count, "culprit": g.get("culprit", ""),
            "bucket": bucket, "permalink": g.get("permalink", ""),
        }
        # MAJOR (T07 v4, revisor #2165, hallazgo [4]): antes se añadía
        # incondicionalmente — un grupo money-path ESTABLE (ni nuevo ni
        # trepando) volvía a `money` en TODOS los ciclos mientras siguiera
        # vivo, y `hay_novedad_en()` trata `money` no vacío como novedad
        # siempre: el silencio entre ciclos (contrato B7) se rompía para
        # siempre por un grupo que no cambió. Mismo criterio de delta que
        # `enruta_item` (es_nuevo o trepó) — un grupo estable no contribuye.
        if MONEY_TERMINAL.search((g.get("culprit") or "") + " " + (g.get("title") or "")) and (
            es_nuevo or trepó
        ):
            money.append(item)
        destino = enruta_item(es_nuevo, trepó, bucket)
        if destino == "nuevos":
            nuevos.append(item)
        elif destino == "escala":
            escala.append(item)
        elif destino == "sin_clasif":
            sin_clasif.append(item)

    hay_novedad = hay_novedad_en(money, nuevos, sin_clasif, escala)
    if args.json:
        salida = {
            "money_path": money, "nuevos": nuevos, "sin_clasif": sin_clasif,
            "escala": escala, "hay_novedad": hay_novedad,
        }
        if args.grupos:
            salida["total_unresolved"] = len(vistos)
            salida["grupos"] = [
                {"id": g.get("id"), "shortId": g.get("shortId", ""), "title": g.get("title", ""),
                 "firstSeen": g.get("firstSeen"), "count": g.get("count"),
                 "userCount": g.get("userCount"), "permalink": g.get("permalink", "")}
                for g in vistos.values()
            ]
        print(json.dumps(salida, ensure_ascii=False, indent=2))
        return 0

    if not hay_novedad:
        return 0  # silencio si no hay novedad (contrato B7)

    def bloque(titulo: str, items: list[dict]) -> None:
        if not items:
            return
        print(f"\n=== {titulo} ({len(items)}) ===")
        for it in items:
            b = it["bucket"] or "SIN-CLASIF"
            print(f"  [{b}] {it['shortId']} c={it['count']} u={it['userCount']} — {it['title'][:80]}")

    bloque("MONEY-PATH", money)
    bloque("NUEVOS (sin bucket → triar con 02-taxonomia)", nuevos)
    bloque("SIN-CLASIF (trepó o desconocido)", sin_clasif)
    bloque("ESCALA (nuevo O trepando dentro de un bucket con gatillo — revisar gatillo)", escala)
    return 0


if __name__ == "__main__":
    sys.exit(main())
