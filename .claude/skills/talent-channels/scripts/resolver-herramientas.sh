#!/usr/bin/env bash
# resolver-herramientas.sh — resuelve la versión de cada herramienta npm del paquete y escribe herramientas.lock (issue 9564).
# Política (CEO, 22-oct-2026; umbral de audit por severidad, 24-oct-2026):
#   - última versión ESTABLE (X.Y.Z) publicada hace >= 72 h (UTC), o un override con versión y motivo registrado;
#   - npm audit sobre un proyecto temporal y OSV: high/critical, MAL-* (malware) y toda severidad ilegible BLOQUEAN;
#     low/moderate no bloquean: se imprimen y quedan en el lock (# avisos_no_bloqueantes:). Sin override del audit;
#   - fail-closed: red, timeout, JSON ilegible o ninguna versión elegible → rc ≠ 0 y NO se escribe lock (no hay golden).
# Uso: resolver-herramientas.sh --lista F --salida F [--trabajo DIR] [--overrides-file F]
#   lista: paquete<TAB>uso (global | npx) · overrides: paquete<TAB>versión<TAB>motivo (10-200 caracteres)
# rc: 0 ok · 2 entrada · 3 registro/red · 4 ninguna versión de >= 72 h · 5 npm audit bloquea o no concluye · 6 OSV bloquea o no concluye
# No borra nada: el directorio de trabajo (package.json + package-lock.json auditados) queda como evidencia.
# shellcheck disable=SC2016  # los programas de jq van en comillas simples A PROPÓSITO ($x es de jq, no de bash)
set -euo pipefail
umask 022
EDAD_MIN_H=72
REGISTRO="https://registry.npmjs.org/"
OSV_URL="https://api.osv.dev/v1/query"
NOBLOQ='["info","low","moderate"]'; BLOQ='["high","critical"]'
# npm y curl corren con el entorno LIMPIO (env -i: sin npm_config_*, NODE_OPTIONS, *_PROXY ni CURL_*) y con la configuración AISLADA
# (userconfig y globalconfig vacíos, registro fijo y el registro de cada scope): un .npmrc o una variable no pueden cambiar el registro.
limpio() { env -i PATH="$PATH" HOME="${HOME:-/root}" LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR="${TMPDIR:-/tmp}" "$@"; }
RE_VER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
RE_PKG='^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$'
RE_ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
# En jq el «$» final acepta un salto de línea antes del fin: a jq se le pasan las mismas expresiones con «\z» (fin estricto).
RE_VER_JQ="${RE_VER%\$}\\z"; RE_ISO_JQ="${RE_ISO%\$}\\z"
T_VIEW="${RH_TIMEOUT_S:-60}"   # solo puede ACORTARSE (la prueba lo usa); fuera de 1-60 vale 60
{ [[ "$T_VIEW" =~ ^[0-9]+$ ]] && [ "$T_VIEW" -ge 1 ] && [ "$T_VIEW" -le 60 ]; } || T_VIEW=60
die() { echo "resolver-herramientas: $2" >&2; exit "$1"; }

LISTA=""; SALIDA=""; TRABAJO=""; OVF=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die 2 "$1 exige un valor"
  case "$1" in --lista) LISTA="$2";; --salida) SALIDA="$2";; --trabajo) TRABAJO="$2";; --overrides-file) OVF="$2";; *) die 2 "opción desconocida: $1";; esac
  shift 2
done
[ -r "$LISTA" ] && [ -n "$SALIDA" ] || die 2 "uso: --lista <fichero> --salida <lock> [--trabajo <dir>] [--overrides-file <fichero>]"

PKGS=(); USOS=()
while IFS=$'\t' read -r p u rest || [ -n "$p" ]; do
  case "$p" in ''|'#'*) continue;; esac
  [[ "$p" =~ $RE_PKG ]] && { [ "$u" = global ] || [ "$u" = npx ]; } && [ -z "$rest" ] || die 2 "lista inválida (esperado 'paquete<TAB>global|npx'): '$p' '$u'"
  for q in "${PKGS[@]}"; do [ "$q" != "$p" ] || die 2 "paquete repetido en la lista: $p"; done
  PKGS+=("$p"); USOS+=("$u")
done < "$LISTA"
[ "${#PKGS[@]}" -gt 0 ] || die 2 "la lista no define ninguna herramienta"

OVP=(); OVV=(); OVM=()
if [ -n "$OVF" ]; then
  [ -r "$OVF" ] || die 2 "no puedo leer el fichero de overrides: $OVF"
  while IFS=$'\t' read -r p v m || [ -n "$p" ]; do
    case "$p" in ''|'#'*) continue;; esac
    m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"
    [[ "$p" =~ $RE_PKG ]] && [[ "$v" =~ $RE_VER ]] || die 2 "override inválido (paquete y versión estable X.Y.Z): '$p' '$v'"
    en_lista=no; for q in "${PKGS[@]}"; do [ "$q" != "$p" ] || en_lista=yes; done
    [ "$en_lista" = yes ] || die 2 "override de un paquete que no está en la lista: $p"
    [ "${#m}" -ge 10 ] && [ "${#m}" -le 200 ] && [[ "$m" != *[[:cntrl:]]* ]] || die 2 "override de $p sin motivo válido (10-200 caracteres, sin tabuladores ni saltos de línea): el override exige motivo registrado"
    OVP+=("$p"); OVV+=("$v"); OVM+=("$m")
  done < "$OVF"
fi

if [ -z "$TRABAJO" ]; then TRABAJO="$(mktemp -d "${TMPDIR:-/tmp}/herr-resolver.XXXXXX")"
elif [ -e "$TRABAJO" ]; then { [ -d "$TRABAJO" ] && [ -z "$(ls -A "$TRABAJO")" ]; } || die 2 "--trabajo existe y no está vacío: $TRABAJO (el resolvedor no borra nada)"
else mkdir -p "$TRABAJO"; fi
TRABAJO="$(cd "$TRABAJO" && pwd)"; mkdir -p "$(dirname "$SALIDA")"
# userconfig y globalconfig tienen que ser rutas DISTINTAS (el npm real rechaza la misma ruta dos veces: «double-loading config»):
# un npmrc vacío propio y de solo lectura en el directorio de trabajo, y /dev/null. Todas las órdenes npm corren con cwd en ese
# directorio nuevo (sin .npmrc de proyecto): ver npm_aislado.
VACIO="$TRABAJO/npmrc-vacio"; : > "$VACIO"; chmod 0444 "$VACIO"
# package.json mínimo ANTES de la primera orden npm: así npm toma este directorio como raíz del proyecto y no un ancestro con su .npmrc.
printf '%s\n' '{"name":"herramientas-auditoria","version":"0.0.0","private":true}' > "$TRABAJO/package.json"
NPMO=("--userconfig=$VACIO" --globalconfig=/dev/null "--registry=$REGISTRO")
for p in "${PKGS[@]}"; do case "$p" in @*) s="--${p%%/*}:registry=$REGISTRO"; [[ " ${NPMO[*]} " == *" $s "* ]] || NPMO+=("$s");; esac; done
npm_aislado() { local t="$1"; shift; ( cd "$TRABAJO" && limpio timeout "$t" npm "$@" "${NPMO[@]}" ); }

AHORA="$(date -u +%s)"; [[ "$AHORA" =~ ^[0-9]+$ ]] || die 3 "el reloj no devolvió segundos de época"
LIM=$((AHORA - EDAD_MIN_H * 3600))   # elegible: publicada en o antes de LIM (el borde de 72 h exactas SÍ entra)
JQ_ENT='.versions as $vs | .time | to_entries
  | map(select(.key | test($rv)))
  | map(select(.key as $k | ($vs | index($k)) != null))
  | map(select(.value | type == "string" and test($rd)))
  | map(.ep = (try (.value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null))
  | map(select(.ep != null))
  | map(select((.ep | todate) == (.value | sub("\\.[0-9]+Z$"; "Z"))))'   # un día imposible (02-30) se normaliza a otra fecha: no es fiable
JQ_ELEGIR="$JQ_ENT"'
  | map(select(.ep <= $lim))
  | sort_by(.key | split(".") | map(tonumber)) | reverse | .[]
  | "\(.key)\t\(.ep | todate)"'   # todas las elegibles, de la más nueva a la más vieja
JQ_OVR="$JQ_ENT"' | map(select(.key == $ver)) | first // empty | "\(.key)\t\(.ep | todate)"'

VER=(); PUB=(); ORI=(); MOT=()
for i in "${!PKGS[@]}"; do
  pkg="${PKGS[$i]}"
  raw="$(npm_aislado "$T_VIEW" view "$pkg" time versions --json 2>/dev/null)" || die 3 "npm view $pkg time falló o venció ($T_VIEW s): sin registro no hay golden (fail-closed)"
  printf '%s' "$raw" | jq -e 'type == "object" and (has("error") | not) and (.time | type == "object") and (.versions | type == "array")' >/dev/null 2>&1 || die 3 "npm view $pkg time versions no devolvió fechas y versiones"
  ov=""; for j in "${!OVP[@]}"; do [ "${OVP[$j]}" != "$pkg" ] || ov="$j"; done
  if [ -n "$ov" ]; then
    out="$(printf '%s' "$raw" | jq -r --arg rv "$RE_VER_JQ" --arg rd "$RE_ISO_JQ" --arg ver "${OVV[$ov]}" "$JQ_OVR")" || die 3 "las fechas de $pkg no son legibles"
    [ -n "$out" ] || die 3 "override: la versión ${OVV[$ov]} de $pkg no existe en el registro o no tiene fecha fiable"
    ORI+=(override); MOT+=("${OVM[$ov]}")
  else
    cands="$(printf '%s' "$raw" | jq -r --arg rv "$RE_VER_JQ" --arg rd "$RE_ISO_JQ" --argjson lim "$LIM" "$JQ_ELEGIR")" || die 3 "las fechas de $pkg no son legibles"
    [ -n "$cands" ] || die 4 "$pkg: ninguna versión estable publicada con >= $EDAD_MIN_H h de edad"
    out=""; n=0   # la más nueva elegible que NO esté deprecada (se prueban como mucho 20)
    while IFS= read -r c && [ "$n" -lt 20 ]; do
      n=$((n + 1)); dep="$(npm_aislado "$T_VIEW" view "$pkg@${c%%$'\t'*}" deprecated --json 2>/dev/null)" || die 3 "npm view $pkg@${c%%$'\t'*} deprecated falló o venció"
      if [ -z "${dep//[[:space:]]/}" ] || [ "$dep" = '""' ]; then out="$c"; break; fi
    done <<< "$cands"
    [ -n "$out" ] || die 4 "$pkg: las versiones elegibles más nuevas están deprecadas"
    ORI+=(edad72h); MOT+=(-)
  fi
  VER+=("${out%%$'\t'*}"); PUB+=("${out#*$'\t'}")
done

# --- npm audit sobre un proyecto temporal NUEVO (solo package-lock; no instala ni ejecuta scripts) -------------------
args=(); for i in "${!PKGS[@]}"; do args+=("${PKGS[$i]}" "${VER[$i]}"); done
dependencias="$(jq -n '[range(0; $ARGS.positional | length; 2) as $i | {($ARGS.positional[$i]): $ARGS.positional[$i + 1]}] | add' --args "${args[@]}")"
jq -n --argjson d "$dependencias" '{name: "herramientas-auditoria", version: "0.0.0", private: true, dependencies: $d}' > "$TRABAJO/package.json"
# --before: las transitivas tampoco entran con menos de 72 h. Con un override (parche urgente de < 72 h) el tope es la fecha de resolución,
# porque la versión pedida no sería resoluble antes; ese caso queda declarado en el lock (origen override y # before_override=).
# +1 s (issue 9681, D14): la elegibilidad compara fechas TRUNCADAS al segundo y npm compara «publicada <= --before» al milisegundo;
# una versión publicada en el segundo del límite con fracción > 0 es elegible y sin el redondeo daría ETARGET.
BEFORE="$(jq -nr --argjson t "$([ "${#OVP[@]}" -gt 0 ] && echo "$AHORA" || echo "$LIM")" '($t + 1) | todate')"
BOV=""; for j in "${!OVP[@]}"; do BOV="${BOV:+$BOV,}${OVP[$j]}@${OVV[$j]}"; done
npm_aislado 180 install --package-lock-only --ignore-scripts --no-audit --no-fund "--before=$BEFORE" > "$TRABAJO/install.log" 2>&1 \
  || die 3 "npm install --package-lock-only falló o venció: no se pudo preparar el audit (ver $TRABAJO/install.log)"
aud_rc=0
npm_aislado 180 audit --package-lock-only --json > "$TRABAJO/audit.json" 2> "$TRABAJO/audit.err" || aud_rc=$?
# npm sale con 1 si hay avisos de cualquier nivel: el rc solo distingue «terminó» (0/1) de «cortado» (124...); decide la forma y la SEVERIDAD.
# Pasa solo si: .vulnerabilities es un objeto; los seis contadores existen y son enteros; high+critical valen 0; total == info+low+moderate;
# y ningún aviso trae otra severidad (cualquier forma inesperada o severidad desconocida bloquea).
if [ "$aud_rc" -le 1 ] && jq -e --argjson nb "$NOBLOQ" --argjson bl "$BLOQ" '(.vulnerabilities | type == "object")
    and (.metadata.vulnerabilities as $m | ($m | type == "object")
      and (["info", "low", "moderate", "high", "critical", "total"] | all(.[]; . as $k | ($m[$k] | type) == "number" and ($m[$k] | . == floor and . >= 0)))
      and ([$bl[] as $s | $m[$s]] | all(. == 0)) and $m.total == ([$nb[] as $s | $m[$s]] | add))
    and ([.vulnerabilities[].severity | select(IN($nb[]) | not)] | length == 0)' "$TRABAJO/audit.json" >/dev/null 2>&1; then :
else die 5 "npm audit con avisos high/critical, severidad desconocida o salida no concluyente (rc=$aud_rc; ver $TRABAJO/audit.json): el golden no se crea"; fi
AVISOS="$(jq -r --argjson nb "$NOBLOQ" --slurpfile pl "$TRABAJO/package-lock.json" '(.vulnerabilities // {}) | to_entries[] | select(.value.severity | IN($nb[]))
    | .key as $n | ($pl[0].packages["node_modules/" + $n].version? // "?") as $v
    | ([.value.via[]? | objects | .url? // empty | (capture("(?<g>GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4})") | .g)?] | unique | join(",")) as $g
    | "\($n)@\($v) \(.value.severity) \(if $g == "" then "sin-GHSA" else $g end)"' "$TRABAJO/audit.json" 2>/dev/null)" || AVISOS=""

# --- OSV por herramienta: high/critical, MAL-* y severidad ilegible bloquean; LOW/MODERATE no ---------------------------
JQ_OSV='def sev: ((.database_specific.severity // "") | ascii_upcase);
  .vulns[]? | (.id // "") as $id
  | if (([$id] + (.aliases // [])) | any(ascii_upcase | startswith("MAL-"))) or ((sev | IN("LOW", "MODERATE", "MEDIUM")) | not) then "B\t\($id)\t\(sev)" else "N\t\($id)\t\(sev)" end'
for i in "${!PKGS[@]}"; do
  nv="${PKGS[$i]}@${VER[$i]}"
  body="$(jq -nc --arg n "${PKGS[$i]}" --arg v "${VER[$i]}" '{package: {name: $n, ecosystem: "npm"}, version: $v}')"
  resp="$(printf '%s' "$body" | limpio curl -q -sS --fail --max-time 20 --retry 1 -X POST -H 'Content-Type: application/json' --data-binary @- "$OSV_URL" 2>"$TRABAJO/osv.err")" \
    || die 6 "OSV inalcanzable para $nv: sin consulta no hay golden (fail-closed)"
  # solo la clave vulns es conocida: next_page_token (paginado), code/message (error con HTTP 200) y cualquier otra bloquean
  printf '%s' "$resp" | jq -e 'type == "object" and ((keys - ["vulns"]) | length == 0) and ((has("vulns") | not) or (.vulns | type == "array"))' >/dev/null 2>&1 || die 6 "OSV: respuesta no concluyente o con claves desconocidas para $nv"
  lineas="$(printf '%s' "$resp" | jq -r "$JQ_OSV")" || die 6 "OSV: respuesta ilegible para $nv"
  if [[ $'\n'"$lineas" == *$'\nB'* ]]; then die 6 "OSV bloquea $nv: ${lineas//$'\t'/ }"; fi
  while IFS=$'\t' read -r _ id sev; do [ -z "$id" ] || AVISOS="${AVISOS:+$AVISOS$'\n'}$nv $sev $id"; done <<< "$lineas"
done

# --- lock: solo si TODO pasó; temporal junto al destino y mv (atómico) ---------------------------------------------------
[ -z "$AVISOS" ] || while IFS= read -r l; do echo "resolver-herramientas: aviso NO bloqueante: $l" >&2; done <<< "$AVISOS"
AVISOS_N=(); [ -z "$AVISOS" ] || mapfile -t AVISOS_N <<< "$AVISOS"
tmp="$(mktemp "${SALIDA}.XXXXXX")"
RES_ISO="$(jq -nr --argjson t "$AHORA" '$t | todate')" || die 3 "no pude formatear la fecha de resolución"
# El texto se arma ENTERO en una variable y se escribe de UNA vez: un fallo de escritura no deja un lock a medias, y el temporal huérfano
# se aparta (nunca se borra). Un grupo `{ … } > f || …` perdería el efecto de `set -e` dentro del grupo.
apartar() { mkdir -p "$(dirname "$SALIDA")/apartado" && mv -- "$tmp" "$(dirname "$SALIDA")/apartado/"; die 3 "$1: el temporal queda en $(dirname "$SALIDA")/apartado/ (no se borra nada)"; }
LOCK_TXT="$({
  echo "# herramientas.lock v1 (generado por resolver-herramientas.sh; no editar a mano)"
  echo "# edad_minima_horas=$EDAD_MIN_H"
  echo "# registro=$REGISTRO"
  echo "# resuelta_utc=$RES_ISO"
  echo "# before=$BEFORE"
  [ -z "$BOV" ] || echo "# before_override=$BOV (el --before se relajó a la fecha de resolución para TODAS las herramientas)"
  echo "# npm_audit=sin-avisos-high-critical osv=sin-avisos-high-critical-ni-malware"
  echo "# avisos_no_bloqueantes: ${#AVISOS_N[@]}"
  [ -z "$AVISOS" ] || printf '%s\n' "$AVISOS" | while IFS= read -r l; do echo "#   $l"; done
  echo "# columnas: paquete<TAB>version<TAB>publicada_utc<TAB>resuelta_utc<TAB>origen<TAB>uso<TAB>motivo"
  for i in "${!PKGS[@]}"; do printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${PKGS[$i]}" "${VER[$i]}" "${PUB[$i]}" "$RES_ISO" "${ORI[$i]}" "${USOS[$i]}" "${MOT[$i]}"; done
})"
printf '%s\n' "$LOCK_TXT" > "$tmp" || apartar "no pude escribir el lock"
chmod 0644 "$tmp" || apartar "no pude fijar el modo del lock"
mv -f "$tmp" "$SALIDA" || apartar "no pude publicar el lock"
echo "resolver-herramientas: lock escrito en $SALIDA (${#PKGS[@]} herramientas)"
