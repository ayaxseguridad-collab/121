#!/usr/bin/env bash
# scripts/parte_guardia.sh — parte de guardia del Vigía, como script (antes solo prosa).
#
# Una pasada: puerta del doctor, issues NUEVAS de Sentry frente al parte anterior y en la
# ventana post-despliegue, alertas de seguridad de GitHub y consultas de dinero de solo lectura.
# Cada medida sale en SU línea: `tree=<sha> instant=<UTC> metric=<n> value=<v> …`. Una cifra sin
# árbol e instante no es una medida. NO sella al bus ni instala cron: mide y emite.
#
# Estado (cabecera `PARTE-GUARDIA … estado=`; el único sitio donde se decide es el final del bloque Python):
#   LIMPIO      rc 0  todas las secciones corrieron y devolvieron 0 novedades.
#   NOVEDAD     rc 0  algo nuevo (issue nueva, post-despliegue, alerta de seguridad, dinero, silencio previo).
#   SONDA-ROJA  rc 1  alguna sección no corrió o no se pudo medir (doctor cerrado, fuente caída, ancla mal
#                     formada, DINERO-NO-CONFIGURADO, SILENCIO-NO-MEDIDO…). Jamás se lee como calma.
#   rc 2: precondición (config ausente, repo no declarado o con otra identidad, credencial declarada de menos de
#         4 caracteres). No se emite NINGUNA cifra.
#   Detalle de un error: se lee entero hasta 1 MiB (fstat); por encima, SONDA-ROJA `detalle-no-acotado` sin leerlo.
# Sin la sección de issues nuevas de Sentry el parte es inválido: se imprime siempre, aunque la consulta falle.
#
# Entorno (sin default de marca): SENTRY_ORG, SENTRY_PROJECT (las usa sentry_triage.py),
#   TA_PARTE_REPO (ruta ABSOLUTA del repo; nunca se deriva del cwd) + TA_PARTE_REPO_ID (`stat -c %d:%i <repo>/.git`),
#   SENTRY_MAIN_MOVIDO (fichero `<epoch entero> <sha>`; TA_PARTE_EXIGE_ANCLA=1 lo hace obligatorio),
#   SENTRY_PARTE_MONEY_SQL (TSV `nombre<TAB>select…`), SENTRY_PARTE_ESTADO (por defecto ~/.vigia-sentry/parte.json),
#   GITHUB_SEC_REPO (+ las de github_seguridad.py; sin ella GitHub sale «no vigilada»),
#   TA_PARTE_CRON_ID (fila `cron` del perfil, por defecto vigia-parte; la cadencia la lee tablas-cron.sh).
# Dinero reutiliza la config del doctor: SENTRY_DOCTOR_SUPABASE_PROJECT_REF / SENTRY_DOCTOR_SUPABASE_HDR.
set -uo pipefail

# Ejecutables externos: una función exportada no los sustituye y un PATH cambiado a mitad no los desvía
# (mismo endurecimiento que sentry_doctor.sh; el límite de confianza es el suyo: quien controla el entorno).
unset BASH_ENV
unset -f curl git python3 stat date timeout env mktemp rm 2>/dev/null || true
_CURL="$(command -v curl || echo curl)"
_GIT="$(command -v git || echo git)"
_PYTHON3="$(command -v python3 || echo python3)"
_STAT="$(command -v stat || echo stat)"
_DATE="$(command -v date || echo date)"
_TIMEOUT="$(command -v timeout || echo timeout)"
_ENV="$(command -v env || echo env)"
_MKTEMP="$(command -v mktemp || echo mktemp)"
_RM="$(command -v rm || echo rm)"
_BASH="${BASH:-bash}"
HERE="${BASH_SOURCE[0]%/*}"; [[ "${BASH_SOURCE[0]}" == */* ]] || HERE="."
HERE="$(cd "$HERE" && pwd -P)"

precond() { printf 'parte_guardia: PRECOND: %s\n' "$1" >&2; exit 2; }

# ── Precondiciones: ANTES de emitir una sola cifra ────────────────────────────────────────────
[ $# -eq 0 ] || precond "no admite argumentos"
for v in SENTRY_ORG SENTRY_PROJECT TA_PARTE_REPO TA_PARTE_REPO_ID; do
  [ -n "${!v:-}" ] || precond "falta $v (sin default de marca)"
done
case "$TA_PARTE_REPO" in /*) ;; *) precond "TA_PARTE_REPO debe ser ruta absoluta (el repo nunca sale del cwd)" ;; esac
[ -d "$TA_PARTE_REPO/.git" ] || precond "TA_PARTE_REPO sin directorio .git"
ID_REAL="$("$_STAT" -c '%d:%i' "$TA_PARTE_REPO/.git" 2>/dev/null)" || precond "no se pudo medir la identidad del repo"
[ "$ID_REAL" = "$TA_PARTE_REPO_ID" ] || precond "identidad del repo distinta de TA_PARTE_REPO_ID (medida $ID_REAL)"
# Todo Git con entorno vacío y rutas explícitas: ni cwd, ni config global, ni variables heredadas.
TREE="$("$_ENV" -i PATH="$PATH" HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  "$_GIT" --git-dir="$TA_PARTE_REPO/.git" --work-tree="$TA_PARTE_REPO" rev-parse HEAD 2>/dev/null)" \
  || precond "git no pudo leer HEAD del repo declarado"
[[ "$TREE" =~ ^[0-9a-f]{40,64}$ ]] || precond "HEAD del repo declarado no es un sha"

TMP="$("$_MKTEMP" -d)" || precond "no se pudo crear el temporal"
case "$TMP" in /?*) ;; *) precond "temporal no absoluto" ;; esac
trap '"$_RM" -rf -- "${TMP:?}"' EXIT
INSTANT="$("$_DATE" -u +%Y-%m-%dT%H:%M:%SZ)"
AHORA="$("$_DATE" -u +%s)"

# ── Secciones: cada una deja su rc y su salida; ninguna aborta a las demás ────────────────────
"$_TIMEOUT" 180 "$_BASH" "$HERE/sentry_doctor.sh" --solo-fuentes >"$TMP/doctor.out" 2>"$TMP/doctor.err"
DOCTOR_RC=$?

"$_TIMEOUT" 900 "$_PYTHON3" "$HERE/sentry_triage.py" --json --no-cursor --grupos --since 24h \
  >"$TMP/sentry.json" 2>"$TMP/sentry.err"
SENTRY_RC=$?

GH_MODO=no-vigilada; GH_RC=0
if [ -n "${GITHUB_SEC_REPO:-}" ]; then
  GH_MODO=activa
  "$_TIMEOUT" 600 "$_PYTHON3" "$HERE/github_seguridad.py" --json --no-cursor >"$TMP/github.json" 2>"$TMP/github.err"
  GH_RC=$?
elif [ -n "${SENTRY_DOCTOR_GITHUB_REPO:-}" ]; then
  GH_MODO=parcial        # el doctor lo vigila pero el barrido no tiene repo: config parcial, no calma
fi

# Dinero: TSV `nombre<TAB>select…` ejecutado como el doctor (Management API, solo lectura).
DINERO_ESTADO="configurado"
dinero_no_configurado() { DINERO_ESTADO="DINERO-NO-CONFIGURADO:$1"; }
dinero() {
  local archivo="${SENTRY_PARTE_MONEY_SQL:-}" ref hdr perms n=0 nombre sql raw status body valor
  : >"$TMP/dinero.tsv"
  if [ -z "$archivo" ] || [ ! -f "$archivo" ]; then dinero_no_configurado "SENTRY_PARTE_MONEY_SQL ausente"; return; fi
  ref="${SENTRY_DOCTOR_SUPABASE_PROJECT_REF:-}"; hdr="${SENTRY_DOCTOR_SUPABASE_HDR:-$HOME/.vigia-supabase/hdr}"
  [[ "$ref" =~ ^[a-z0-9]{20}$ ]] || { dinero_no_configurado "SENTRY_DOCTOR_SUPABASE_PROJECT_REF ausente o inválida"; return; }
  [ -f "$hdr" ] || { dinero_no_configurado "header-file ausente"; return; }
  perms="$("$_STAT" -c %a "$hdr" 2>/dev/null)"
  [ "$perms" = "600" ] || { dinero_no_configurado "header-file con permisos inseguros"; return; }
  if [ "$(grep -c . "$hdr")" != 1 ] || ! grep -q '^Authorization: ' "$hdr"; then
    dinero_no_configurado "header-file con contenido inesperado"; return
  fi
  while IFS=$'\t' read -r nombre sql || [ -n "${nombre:-}" ]; do
    case "$nombre" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    if ! [[ "$nombre" =~ ^[a-z][a-z0-9_]{0,40}$ ]]; then printf 'consulta%d\tRECHAZADA\tnombre-invalido\n' "$n" >>"$TMP/dinero.tsv"; continue; fi
    # Solo select/with, una sola sentencia y sin verbos de escritura (defensa en profundidad: la API va read_only).
    if ! [[ "${sql,,}" =~ ^[[:space:]]*(select|with)[[:space:]] ]] || [[ "$sql" == *\;* ]] \
       || [[ "${sql,,}" =~ (^|[^a-z0-9_])(insert|update|delete|drop|alter|create|grant|revoke|truncate|copy|call|do|into)([^a-z0-9_]|$) ]]; then
      printf '%s\tRECHAZADA\tno-es-select-o-with\n' "$nombre" >>"$TMP/dinero.tsv"; continue
    fi
    "$_PYTHON3" -c 'import json,sys; print(json.dumps({"query": sys.argv[1], "read_only": True}))' "$sql" >"$TMP/q.json"
    raw="$("$_TIMEOUT" 40 "$_CURL" -q -s --max-time 30 --noproxy '*' -H @"$hdr" -H 'Content-Type: application/json' \
      -H 'User-Agent: talent-sentry-guard-parte/1' -X POST --data-binary @"$TMP/q.json" -w '\n%{http_code}' \
      "https://api.supabase.com/v1/projects/${ref}/database/query" </dev/null 2>/dev/null)" \
      || { printf '%s\tFALLIDA\tinalcanzable\n' "$nombre" >>"$TMP/dinero.tsv"; continue; }
    status="${raw##*$'\n'}"; body="${raw%$'\n'*}"
    printf '%s' "$body" >"$TMP/q.out"
    # `[]` es válido (cero filas); lo que no es lista de objetos jamás cuenta como cero.
    valor="$("$_PYTHON3" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,list) and all(isinstance(x,dict) for x in d); print(len(d))' "$TMP/q.out" 2>/dev/null)" \
      && [ "$status" = "201" ] || { printf '%s\tFALLIDA\thttp-%s-o-shape\n' "$nombre" "$status" >>"$TMP/dinero.tsv"; continue; }
    printf '%s\tOK\t%s\n' "$nombre" "$valor" >>"$TMP/dinero.tsv"
  done <"$archivo"
  [ "$n" -gt 0 ] || dinero_no_configurado "archivo sin consultas"
}
dinero

# Ancla de despliegue: el CEO escribe `<epoch entero> <sha>` tras cada fusión.
ANCLA_ESTADO=sin-variable
if [ -n "${SENTRY_MAIN_MOVIDO:-}" ]; then
  if [ -f "$SENTRY_MAIN_MOVIDO" ]; then ANCLA_ESTADO=presente; else ANCLA_ESTADO=ausente; fi
fi
ANCLA_RAW=""; [ "$ANCLA_ESTADO" = presente ] && ANCLA_RAW="$(<"$SENTRY_MAIN_MOVIDO")"

# Cadencia: la lee el perfil (talent-ceo/tablas-cron.sh); sin fila no se inventa un número.
CRON_RC=127
TABLAS="$HERE/../../talent-ceo/scripts/tablas-cron.sh"
if [ -f "$TABLAS" ]; then
  "$_TIMEOUT" 30 "$_BASH" "$TABLAS" --minutos "${TA_PARTE_CRON_ID:-vigia-parte}" >"$TMP/cron.out" 2>"$TMP/cron.err" </dev/null
  CRON_RC=$?
fi

# ── Decisión y salida (un solo sitio decide el estado) ────────────────────────────────────────
read -r -d '' PY <<'__FIN_PARTE_PY__'
import json, os, re, sys, tempfile
from datetime import datetime, timezone

E = os.environ
TMP, TREE, INSTANT, AHORA = E["P_TMP"], E["P_TREE"], E["P_INSTANT"], int(E["P_AHORA"])
TOPE_LISTA = 50
lineas, roja, novedad = [], [], []


# ── Enmascarado y fallo cerrado ──
# Todo texto que el parte imprime de Sentry, GitHub, la API o un error (título, enlace, motivo) pasa por ocultar().
# Se enmascaran los valores de las credenciales declaradas (header-files y LINEAR_API_KEY), en sus formas literal,
# de una línea y escapada como JSON, y por patrón cualquier `Authorization: …` o `Bearer <valor>`. Si algo se
# enmascara, el parte NO es LIMPIO: credencial-reflejada es una sonda roja (rc 1), no un aviso.
MASCARA = "[OCULTO]"
OCULTOS = set()
TOLERANTES = set()      # credenciales sin blancos (4 o más caracteres), que se buscan aunque la fuente las parta
# Longitud mínima (caracteres compactos, sin blancos) de una credencial declarada: es el umbral de la coincidencia
# tolerante y a la vez el mínimo admitido. Una credencial más corta no se puede enmascarar sin falsos positivos
# masivos: es un error de configuración (precondición, rc 2, sin cifras). Mismo criterio que la fuente de GitHub (N=4).
LONGITUD_MIN_CREDENCIAL = 4
CORTAS = []
# Tope duro (bytes, medido con fstat antes de leer) del detalle de un error que el parte lee entero para enmascararlo.
# 1 MiB = 16 veces el límite anterior de 64 Ki caracteres; los .err son el stderr de tres comandos con plazo y miden
# pocos KB. Por encima no es un «motivo» legible: se trata como señal roja y NO se lee ni se publica. Constante del
# script, no configurable (un tope configurable por entorno permitiría desactivarlo).
TOPE_DETALLE = 1048576
SEPARADOR = r"(?:\s|\\[nrt]|[​-‍﻿])*"
REFLEJADO = []
PATRON_GENERICO = re.compile(r"(?i)authorization\s*:\s*\S+(?:[ \t]+\S+)?|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")


def registrar_oculto(valor):
    if not isinstance(valor, str) or not valor.strip():
        return
    valor = valor.strip()
    for forma in {valor, " ".join(valor.split()), re.sub(r"[\x00-\x1f\x7f\"`]+", " ", valor),
                  json.dumps(valor)[1:-1], json.dumps(valor, ensure_ascii=False)[1:-1]}:
        if forma:
            OCULTOS.add(forma)
    compacta = "".join(valor.split())
    if len(compacta) >= LONGITUD_MIN_CREDENCIAL:
        TOLERANTES.add(compacta)
    else:
        CORTAS.append(1)


def registrar_credenciales():
    for ruta in E.get("P_HDRS", "").split("\n"):
        try:
            lineas_hdr = open(ruta, errors="replace").read().splitlines() if ruta else []
        except OSError:
            continue
        for ln in lineas_hdr:
            valor = ln.split(":", 1)[1].strip() if ln.lower().startswith("authorization:") else ln.strip()
            registrar_oculto(valor)
            m = re.fullmatch(r"(?:Bearer|token)\s+(\S+)", valor, re.I)
            if m:
                registrar_oculto(m.group(1))
    registrar_oculto(E.get("LINEAR_API_KEY"))


def tolerante(valor):
    """Patrón del valor con CUALQUIER blanco (salto de línea, retorno de carro, espacio, tabulador, un `\\n` ya
    escapado o un carácter de ancho cero) entre sus caracteres: la fuente puede partir una credencial de una línea
    y las dos mitades, juntas, la reconstruyen. Se aplica al texto CRUDO, antes de normalizar, truncar o cortar."""
    return SEPARADOR.join(re.escape(c) for c in valor)


def ocultar(texto):
    antes = texto
    if OCULTOS:
        partes = [tolerante(v) for v in sorted(TOLERANTES, key=len, reverse=True)]
        partes += [re.escape(v) for v in sorted(OCULTOS, key=len, reverse=True)]
        texto = re.sub("|".join(partes), MASCARA, texto)
    texto = PATRON_GENERICO.sub(MASCARA, texto)
    if texto != antes:
        REFLEJADO.append(1)
    return texto


registrar_credenciales()
if CORTAS:
    # Precondición de configuración: ni una cifra por stdout, y el mensaje no lleva ningún valor.
    print(f"parte_guardia: PRECOND: una credencial declarada (header-file o LINEAR_API_KEY) mide menos de "
          f"{LONGITUD_MIN_CREDENCIAL} caracteres: no se puede enmascarar con seguridad; corrige la configuración", file=sys.stderr)
    sys.exit(2)


def limpio(t, n=120):
    t = ocultar(str(t if t is not None else ""))
    t = re.sub(r"[\x00-\x1f\x7f\"`]+", " ", t)
    return ocultar(" ".join(t.split()))[:n]


def metrica(nombre, valor, **extra):
    s = f"tree={TREE} instant={INSTANT} metric={nombre} value={limpio(valor, 80).replace(' ', '_') or 'vacio'}"
    for k, v in extra.items():
        s += f' {k}="{limpio(v)}"'
    lineas.append(s)


def primera_linea(nombre):
    try:
        # El enmascarado va sobre el fichero ENTERO (en bytes, hasta TOPE_DETALLE), antes de elegir la primera línea:
        # una credencial partida por un salto de línea, o que cruza cualquier posición, no puede publicarse en
        # fragmentos. Si el fichero supera el tope no se lee: señal roja y texto fijo, sin publicar contenido.
        with open(os.path.join(TMP, nombre), "rb") as f:
            if os.fstat(f.fileno()).st_size > TOPE_DETALLE:
                roja.append("detalle-no-acotado")
                return "detalle-no-acotado"
            crudo = f.read(TOPE_DETALLE).decode("utf-8", errors="replace")
        for ln in ocultar(crudo).splitlines():
            if ln.strip():
                return ln.strip()
    except OSError:
        pass
    return "sin detalle"


def leer_json(nombre):
    try:
        return json.load(open(os.path.join(TMP, nombre))), None
    except (OSError, ValueError) as e:
        return None, type(e).__name__


def epoch(iso):
    try:
        dt = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return None
    return int((dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp())


def clave(g):
    return str(g.get("id") or g.get("shortId") or "")


# Estado del parte anterior (propio del parte; el cursor del ciclo de 5 min no se toca).
ruta_estado = E.get("P_ESTADO") or os.path.join(os.path.expanduser("~"), ".vigia-sentry", "parte.json")
prev, prev_ids, prev_gh = None, set(), set()
if os.path.isfile(ruta_estado):
    try:
        prev = json.load(open(ruta_estado))
        assert isinstance(prev, dict) and isinstance(prev.get("instant_epoch"), int)
        prev_ids = set(map(str, prev.get("sentry_ids", [])))
        prev_gh = set(map(str, prev.get("github_ids", [])))
    except (ValueError, AssertionError, TypeError):
        roja.append("estado-previo-ilegible")
        metrica("sonda_roja", "estado-previo", motivo="parte.json ilegible: revisar o retirar a mano")
        prev, prev_ids, prev_gh = None, set(), set()

# Puerta del doctor
rc = int(E["P_DOCTOR_RC"])
metrica("doctor_puerta", "abierta" if rc == 0 else "cerrada", rc=rc)
if rc != 0:
    roja.append("doctor-puerta-cerrada")
    metrica("sonda_roja", "doctor", motivo=primera_linea("doctor.err"))

# Ancla de despliegue
ancla = None
estado_ancla = E["P_ANCLA_ESTADO"]
if estado_ancla == "presente":
    campos = E["P_ANCLA_RAW"].strip().split(" ")
    if (len(campos) == 2 and campos[0].isdigit() and len(campos[0]) <= 12 and re.fullmatch(r"[0-9a-f]{7,64}", campos[1])
            and 1_000_000_000 <= int(campos[0]) <= AHORA + 300):
        ancla = int(campos[0])
        edad = max(0, (AHORA - ancla) // 60)
        activa = AHORA - ancla <= 3600
        metrica("post_despliegue_ventana", "activa" if activa else "cerrada", edad_min=edad, ancla_sha=campos[1][:12])
    else:
        roja.append("ancla-mal-formada")
        metrica("post_despliegue_ventana", "ancla-mal-formada", motivo="se esperaba '<epoch entero> <sha>'")
else:
    metrica("post_despliegue_ventana", "sin-ancla", motivo="SENTRY_MAIN_MOVIDO no declarado" if estado_ancla == "sin-variable" else "fichero main-movido ausente")
    if E.get("P_EXIGE_ANCLA") == "1":
        roja.append("ancla-exigida-ausente")

# Sentry: issues nuevas (sección obligatoria)
lineas.append("== issues nuevas (Sentry) ==")
sj, err = leer_json("sentry.json")
grupos = None
if int(E["P_SENTRY_RC"]) != 0 or sj is None:
    roja.append("sentry-consulta-fallida")
    metrica("sentry_consulta_nuevas", "fallida", motivo=primera_linea("sentry.err") if int(E["P_SENTRY_RC"]) else "la salida de sentry_triage.py no es JSON")
elif not (isinstance(sj.get("total_unresolved"), int) and isinstance(sj.get("grupos"), list)
          and sj["total_unresolved"] == len(sj["grupos"]) and all(isinstance(g, dict) and clave(g) for g in sj["grupos"])):
    roja.append("sentry-esquema")
    metrica("sentry_consulta_nuevas", "fallida", motivo="esquema inesperado de sentry_triage.py --json --grupos")
else:
    grupos = sj["grupos"]
    metrica("sentry_consulta_nuevas", "ok")
    metrica("sentry_unresolved_total", len(grupos))
    if prev is not None:
        nuevos = [g for g in grupos if clave(g) not in prev_ids]
    else:   # primer parte: sin base, se mira la ventana de 24 h de la consulta
        nuevos = [g for g in grupos if epoch(g.get("firstSeen")) is None or epoch(g.get("firstSeen")) >= AHORA - 86400]
    post = []
    if ancla is not None and AHORA - ancla <= 3600:
        post = [g for g in grupos if (epoch(g.get("firstSeen")) or 0) >= ancla]
    metrica("sentry_nuevos_desde_ultimo_parte", len(nuevos))
    metrica("sentry_nuevos_post_despliegue", len(post) if (ancla is not None and AHORA - ancla <= 3600) else "NA")
    if nuevos or post:
        novedad.append("sentry-issues-nuevas")
    ids_post = {clave(g) for g in post}
    ids_nuevos = {clave(g) for g in nuevos}
    def eventos(g):
        c = str(g.get("count") or 0)
        return int(c) if c.isdigit() else 0

    union = sorted({clave(g): g for g in nuevos + post}.values(), key=lambda g: -eventos(g))
    for g in union[:TOPE_LISTA]:
        k = clave(g)
        origen = "ambos" if k in ids_post and k in ids_nuevos else ("post-despliegue" if k in ids_post else "ultimo-parte")
        metrica("sentry_issue_nueva", g.get("shortId") or k, eventos=g.get("count"), usuarios=g.get("userCount"),
                first_seen=g.get("firstSeen"), origen=origen, titulo=g.get("title"), enlace=g.get("permalink"))
    if len(union) > TOPE_LISTA:
        metrica("sentry_issues_nuevas_omitidas", len(union) - TOPE_LISTA)

# GitHub
lineas.append("== alertas de seguridad (GitHub) ==")
gh_ids = None
if E["P_GH_MODO"] == "no-vigilada":
    metrica("github_estado", "no-vigilada", motivo="GITHUB_SEC_REPO no declarado")
elif E["P_GH_MODO"] == "parcial":
    roja.append("github-config-parcial")
    metrica("github_estado", "config-parcial", motivo="el doctor declara repo pero falta GITHUB_SEC_REPO")
else:
    gj, err = leer_json("github.json")
    claves_ok = isinstance(gj, dict) and all(k in gj for k in ("superficies", "nuevos", "escala", "no_vigiladas", "total_abiertas"))
    if int(E["P_GH_RC"]) != 0 or not claves_ok or not isinstance(gj["total_abiertas"], int) or not isinstance(gj["nuevos"], list):
        roja.append("github-consulta-fallida")
        metrica("github_estado", "fallida", motivo=primera_linea("github.err") if int(E["P_GH_RC"]) else "esquema inesperado de github_seguridad.py --json")
    else:
        metrica("github_estado", "vigilada")
        metrica("github_abiertas", gj["total_abiertas"])
        gh_ids = sorted({f'{n.get("superficie")}:{n.get("id")}' for n in gj["nuevos"] + gj["escala"] if n.get("id") is not None})
        nuevas = [n for n in gj["nuevos"] if f'{n.get("superficie")}:{n.get("id")}' not in prev_gh]
        metrica("github_nuevas_desde_ultimo_parte", len(nuevas))
        if gj["no_vigiladas"]:
            metrica("github_superficies_no_vigiladas", ",".join(map(str, gj["no_vigiladas"])))
        if nuevas:
            novedad.append("github-alertas-nuevas")
        for n in nuevas[:TOPE_LISTA]:
            metrica("github_alerta_nueva", f'{n.get("superficie")}:{n.get("id")}', nivel=n.get("nivel"), titulo=n.get("titulo"), enlace=n.get("url"))
        if len(nuevas) > TOPE_LISTA:
            metrica("github_alertas_nuevas_omitidas", len(nuevas) - TOPE_LISTA)

# Dinero
lineas.append("== dinero (solo lectura) ==")
if E["P_DINERO_ESTADO"] != "configurado":
    roja.append("DINERO-NO-CONFIGURADO")
    metrica("dinero_estado", "DINERO-NO-CONFIGURADO", motivo=E["P_DINERO_ESTADO"].split(":", 1)[-1])
else:
    metrica("dinero_estado", "configurado")
    for fila in open(os.path.join(TMP, "dinero.tsv")):
        nombre, est, valor = (fila.rstrip("\n").split("\t") + ["", ""])[:3]
        if est == "OK":
            metrica(f"dinero_{nombre}", valor)
            if int(valor) > 0:
                novedad.append(f"dinero-{nombre}")
        else:
            roja.append(f"dinero-{est.lower()}")
            metrica(f"dinero_{nombre}", est, motivo=valor)

# Cadencia y silencio: el SILENCIO también es alerta (umbral = 2 x cadencia leída del perfil)
umbral = None
if int(E["P_CRON_RC"]) == 0:
    try:
        mins = set()
        for item in E["P_CRON_OUT"].strip().split(","):
            rango, _, paso = item.partition("/")
            a, b = (0, 59) if rango == "*" else ((int(rango.split("-")[0]), int(rango.split("-")[-1])))
            mins.update(range(a, b + 1, int(paso) if paso else 1))
        orden = sorted(mins)
        hueco = max((orden[(i + 1) % len(orden)] - m) % 60 or 60 for i, m in enumerate(orden))
        umbral = 2 * hueco
        metrica("cadencia_min", hueco)
    except (ValueError, ZeroDivisionError):
        umbral = None
if umbral is None:
    roja.append("SILENCIO-NO-MEDIDO")
    metrica("silencio_umbral", "SILENCIO-NO-MEDIDO", motivo="sin cadencia legible en el perfil (tablas-cron.sh rc=%s)" % E["P_CRON_RC"])
if prev is not None:
    previo_min = max(0, (AHORA - prev["instant_epoch"]) // 60)
    metrica("silencio_previo", previo_min, umbral_min=umbral if umbral is not None else "NA")
    if umbral is not None and previo_min > umbral:
        novedad.append("silencio-previo")
else:
    metrica("silencio_previo", "NA", motivo="sin parte previo")

ocultar("\n".join(lineas))   # pasada de control: si algún campo olvidó limpio(), también cuenta como reflejo
if REFLEJADO:
    roja.append("credencial-reflejada")
    metrica("sonda_roja", "credencial-reflejada", motivo="una fuente devolvió una credencial en su texto: se enmascaró y el parte no es LIMPIO")
estado = "SONDA-ROJA" if roja else ("NOVEDAD" if novedad else "LIMPIO")
causas = ",".join(dict.fromkeys(roja + novedad)) or "ninguna"
# Punto único de salida: ninguna línea sale sin pasar por el enmascarado, aunque un campo nuevo olvidara limpio().
print(ocultar(f"PARTE-GUARDIA tree={TREE} instant={INSTANT} estado={estado} causas={causas}"))
print(ocultar("\n".join(lineas)))

# El estado avanza solo si el parte está completo: una sonda roja no puede tragarse una novedad.
if not roja and grupos is not None:
    os.makedirs(os.path.dirname(ruta_estado), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ruta_estado), prefix=".parte-")
    with os.fdopen(fd, "w") as f:
        json.dump({"version": 1, "instant_epoch": AHORA, "instant": INSTANT,
                   "sentry_ids": sorted(clave(g) for g in grupos), "github_ids": gh_ids or []}, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ruta_estado)
sys.exit(1 if roja else 0)
__FIN_PARTE_PY__

P_HDRS="${SENTRY_HDR:-$HOME/.vigia-sentry/hdr}"$'\n'"${GITHUB_SEC_HDR:-$HOME/.vigia-github/hdr}"$'\n'"${SENTRY_DOCTOR_SUPABASE_HDR:-$HOME/.vigia-supabase/hdr}"$'\n'"${SENTRY_DOCTOR_SENTRY_HDR:-}"$'\n'"${SENTRY_DOCTOR_GITHUB_HDR:-}"$'\n'"${SENTRY_DOCTOR_BETTERSTACK_HDR:-}"$'\n'"${SENTRY_DOCTOR_LINEAR_HDR:-}" \
P_TMP="$TMP" P_TREE="$TREE" P_INSTANT="$INSTANT" P_AHORA="$AHORA" \
P_ESTADO="${SENTRY_PARTE_ESTADO:-}" P_DOCTOR_RC="$DOCTOR_RC" P_SENTRY_RC="$SENTRY_RC" \
P_GH_MODO="$GH_MODO" P_GH_RC="$GH_RC" P_DINERO_ESTADO="$DINERO_ESTADO" \
P_ANCLA_ESTADO="$ANCLA_ESTADO" P_ANCLA_RAW="$ANCLA_RAW" P_EXIGE_ANCLA="${TA_PARTE_EXIGE_ANCLA:-}" \
P_CRON_RC="$CRON_RC" P_CRON_OUT="$([ "$CRON_RC" = 0 ] && printf '%s' "$(<"$TMP/cron.out")")" \
  "$_PYTHON3" -c "$PY"
