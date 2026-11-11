#!/usr/bin/env bash
# herramientas-72h.sh — herramientas del paquete con 72 h de edad, audit/OSV por severidad y registro (issue 9564).
# Dobles de npm, curl, date y npx por PATH: sin red, sin incus, sin Node real. Del golden se ejecuta el fragmento REAL
# (extraído por ancla). Los mutantes mut-* aplican UN cambio al original y su grupo de casos debe enrojecer.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
ASSETS_REAL="$(cd "$HERE/../assets" && pwd)"
RAIZ="$(cd "$HERE/../../.." && pwd)"
RES="$SCRIPTS/resolver-herramientas.sh"; TSX="$RAIZ/scripts/tsx.sh"; G="$SCRIPTS/02-golden.sh"
PASS=0; FAIL=0; T=$'\t'
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1" >&2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herr72h.XXXXXX")"; BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/esc"
NOW=1792800000   # epoch fijo del reloj doble
iso()  { /bin/date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }
isoz() { /bin/date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NPMG="--globalconfig=/dev/null --registry=https://registry.npmjs.org/"   # aislamiento de npm: userconfig = fichero vacío PROPIO (npm real rechaza la misma ruta en user y global)
NPMS="--@scope:registry=https://registry.npmjs.org/"                      # + el registro de cada scope de la lista

cat > "$BIN/npm" <<'__FIN_NPM__'
#!/bin/bash
ESC="$(cat "$(dirname "$0")/esc")"   # el resolvedor limpia el entorno: el escenario viaja por fichero
echo "npm $*" >> "$ESC/npm.log"
env | grep -iE '^(npm_config|node_options|node_tls|curl_|[a-z_]*proxy)' >> "$ESC/npm.env" || true
# Modelo de npm real: un .npmrc de usuario o npm_config_registry cambian el registro; el scope solo se fija con su propia clave.
aj=""; uc=""; gc=""
for a in "$@"; do case "$a" in --userconfig=*) uc="${a#*=}";; --globalconfig=*) gc="${a#*=}";; esac; done
if [ -n "$uc" ] && [ "$uc" = "$gc" ]; then   # lo que hace el npm real: no carga el mismo fichero como user y como global
  echo "double-loading config \"$uc\" as \"global\", previously loaded as \"user\"" >&2; echo "REGISTRO-AJENO: double-loading" >> "$ESC/npm.log"; exit 1
fi
if [ -z "$uc" ] || grep -qvE '^[[:space:]]*([#;]|$)' "$uc" 2>/dev/null; then [ -f "$HOME/.npmrc" ] && aj="npmrc "; fi   # sin userconfig vacío (solo comentarios) se lee el ~/.npmrc
case " $* " in *" -g "*) ;; *) [ -f ./.npmrc ] && aj="${aj}npmrc-proyecto ";; esac   # el .npmrc de proyecto del cwd (con -g no se lee)
[ -n "${npm_config_registry:-}" ] && aj="${aj}entorno "
case " $* " in *" --registry=https://registry.npmjs.org/ "*) ;; *) aj="${aj}sin-registro ";; esac
for a in "$@"; do case "$a" in @*/*) sc="${a%%/*}"; case " $* " in *" --$sc:registry=https://registry.npmjs.org/ "*) ;; *) aj="${aj}sin-$sc ";; esac;; esac; done
if [ -n "$aj" ]; then echo "REGISTRO-AJENO: $aj" >> "$ESC/npm.log"; exit 1; fi
# Regla de npm (pick-manifest): una versión solo se resuelve si su publicación es <= --before, AL MILISEGUNDO (si no, ETARGET).
export LC_ALL=C; bef=""; for a in "$@"; do case "$a" in --before=*) bef="${a#*=}";; esac; done
etarget() { local f pub b="$bef"; [ -n "$b" ] || return 0; f="$ESC/time.$(printf %s "$1" | tr '/@' '__')"; [ -f "$f" ] || return 0
  pub="$(jq -r --arg v "$2" '.[$v] // empty' "$f")"; [ -n "$pub" ] || return 0; case "$b" in *.*Z) ;; *) b="${b%Z}.000Z";; esac
  if [[ "$b" < "$pub" ]]; then echo "npm error code ETARGET: No matching version found for $1@$2 with a date before $b" >&2; exit 1; fi; }
case "$1 $2" in
  "view "*) [ -f package.json ] || echo "VIEW-SIN-PACKAGE-JSON" >> "$ESC/npm.log"
    [ -f "$ESC/view-fail" ] && exit 1
    [ -f "$ESC/view-sleep" ] && exec sleep 5
    case "$2" in *@[0-9]*) d="$ESC/dep.$(printf %s "$2" | tr '/@' '__')"; [ -f "$d" ] && cat "$d"; exit 0;; esac   # view pkg@ver deprecated
    n="$(printf %s "$2" | tr '/@' '__')"; f="$ESC/time.$n"
    if [ -f "$f" ] && [ -f "$ESC/vers.$n" ]; then jq -c --slurpfile v "$ESC/vers.$n" '{time: ., versions: $v[0]}' "$f"; exit 0; fi
    if [ -f "$f" ]; then jq -c '{time: ., versions: (keys - ["created","modified"])}' "$f"; exit 0; fi
    echo '{"error":{"code":"E404"}}'; exit 1;;
  "install --package-lock-only") [ -f "$ESC/lock-fail" ] && exit 1
    while read -r n v; do etarget "$n" "$v"; done < <(jq -r '.dependencies // {} | to_entries[] | "\(.key) \(.value)"' package.json)
    echo '{"packages":{"node_modules/lodash":{"version":"4.17.20"}}}' > package-lock.json; exit 0;;
  "audit --package-lock-only") if [ -f "$ESC/audit.json" ]; then cat "$ESC/audit.json"; else echo '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'; fi
    exit "$(cat "$ESC/audit.rc" 2>/dev/null || echo 0)";;
  "install -g") for a in "$@"; do case "$a" in *@[0-9]*) etarget "${a%@*}" "${a##*@}";; esac; done
    exit "$(cat "$ESC/instg.rc" 2>/dev/null || echo 0)";;
  "ls -g") exit "$(cat "$ESC/ls.rc" 2>/dev/null || echo 0)";;
esac
exit 1
__FIN_NPM__
cat > "$BIN/curl" <<'__FIN_CURL__'
#!/bin/bash
ESC="$(cat "$(dirname "$0")/esc")"
env | grep -iE '^(curl_|[a-z_]*proxy)' >> "$ESC/curl.env" || true
body="$(cat)"; echo "$body" >> "$ESC/osv.log"
[ -f "$ESC/osv-fail" ] && exit 7
n="$(printf %s "$body" | jq -r .package.name | tr '/@' '__')"
if [ -f "$ESC/osv.$n" ]; then cat "$ESC/osv.$n"; else echo '{}'; fi
__FIN_CURL__
cat > "$BIN/date" <<'__FIN_DATE__'
#!/bin/bash
if [ "$1 $2" = "-u +%s" ]; then cat "$(cat "$(dirname "$0")/esc")/now"; exit 0; fi
exec /bin/date "$@"
__FIN_DATE__
cat > "$BIN/npx" <<'__FIN_NPX__'
#!/bin/bash
export LC_ALL=C
ESC="$(cat "$(dirname "$0")/esc")"
echo "npx $*" >> "$ESC/npx.log"
env | grep -iE '^(npm_config|node_options|node_tls|curl_|[a-z_]*proxy)' >> "$ESC/npx.env" || true
# Regla de npm (npm-pick-manifest): una versión solo se elige si su publicación es <= --before, AL MILISEGUNDO.
b=""; spec=""; for a in "$@"; do case "$a" in --before=*) b="${a#*=}";; tsx@*) spec="${a#tsx@}";; esac; done
if [ -n "$b" ] && [ -n "$spec" ]; then
  TS="$(cat "$(dirname "$0")/tsx.path")"   # la versión sellada y su marca salen del tsx.sh REAL del paquete (no se duplican aquí)
  if [ "$spec" = "$(grep -m1 -E '^TSX_VERSION_SELLADA=' "$TS" | cut -d'"' -f2)" ]; then pub="$(grep -m1 -E '^TSX_PUBLICADA_SELLADA=' "$TS" | cut -d'"' -f2)"
  else pub="$(jq -r --arg v "$spec" '.[$v] // empty' "$ESC/time.tsx" 2>/dev/null)"; fi
  case "$b" in *.*Z) ;; *) b="${b%Z}.000Z";; esac
  if [ -n "$pub" ] && [[ "$b" < "$pub" ]]; then echo "npm error code ETARGET: No matching version found for tsx@$spec with a date before $b" >&2; exit 1; fi
fi
exit 0
__FIN_NPX__
cat > "$BIN/mktemp" <<'__FIN_MK__'
#!/bin/bash
# Doble del creador de temporales: con $ESC/lock-ro deja el temporal del lock en solo lectura (la escritura posterior falla).
f="$("$(cat "$(dirname "$0")/real.mk")" "$@")" || exit $?
ESC="$(cat "$(dirname "$0")/esc")"
if [ -f "$ESC/lock-ro" ]; then case "$f" in *herramientas.lock.*) chmod 0400 "$f";; esac; fi
printf '%s\n' "$f"
__FIN_MK__
chmod +x "$BIN/npm" "$BIN/curl" "$BIN/date" "$BIN/npx" "$BIN/mktemp"
type -P mk""temp > "$BIN/real.mk"
printf '%s\n' "$TSX" > "$BIN/tsx.path"

tiempos() { # sufijo ver:segundos-de-edad ...
  local f="$ESC/time.$1" j='{"created":"2020-01-01T00:00:00.000Z","modified":"2026-10-23T00:00:00.000Z"' s; shift
  for s in "$@"; do j="$j,\"${s%%:*}\":\"$(iso $((NOW - ${s##*:})))\""; done; printf '%s}\n' "$j" > "$f"; }
NESC=0; NRUN=0; XENV=()
esc_new() { NESC=$((NESC+1)); ESC="$WORK/esc/$NESC"; mkdir -p "$ESC"; export ESC; echo "$NOW" > "$ESC/now"; echo "$ESC" > "$BIN/esc"
  printf '@scope/cli\tglobal\nplain\tglobal\ntsx\tnpx\n' > "$ESC/lista"
  for p in _scope_cli plain tsx; do tiempos "$p" 2.0.0:86400 1.9.0:360000 1.8.0:1080000 3.0.0-rc.1:720000; done; }
corre() { local tr="$ESC/trabajo.$((++NRUN))"; RC=0; ( cd "${CWD:-$PWD}" && env "${XENV[@]}" PATH="$BIN:$PATH" ESC="$ESC" RH_TIMEOUT_S="${RH_T:-}" bash "${RESX:-$RES}" --lista "$ESC/lista" --salida "$ESC/herramientas.lock" --trabajo "$tr" "$@" ) > "$ESC/out" 2>&1 || RC=$?; }
rc_es() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 — rc=$RC (esperado $2): $(tr '\n' ' ' < "$ESC/out" | cut -c1-220)"; fi; }
sin_lock() { if [ ! -e "$ESC/herramientas.lock" ]; then ok "$1"; else bad "$1 — existe herramientas.lock"; fi; }
fila() { if grep -E -q -- "^$2${T}$3" "$ESC/herramientas.lock" 2>/dev/null; then ok "$1"; else bad "$1 — fila: $(grep -E "^$2${T}" "$ESC/herramientas.lock" 2>/dev/null)"; fi; }
en_lock() { if grep -qF -- "$2" "$ESC/herramientas.lock" 2>/dev/null; then ok "$1"; else bad "$1 — falta '$2' en el lock"; fi; }
en_log() { if [[ "$(<"$ESC/npm.log")" == *"$2"* ]]; then ok "$1"; else bad "$1 — falta '$2' en npm.log"; fi; }
aud_raw() { printf '%s\n' "$1" > "$ESC/audit.json"; echo "$2" > "$ESC/audit.rc"; }
meta() { printf '"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":%s,"high":%s,"critical":%s,"total":%s}}' "$1" "$2" "$3" "$4"; }
audit_con() { # severidad-del-aviso rc  → un aviso de lodash con GHSA
  local m=0 h=0 c=0; case "$1" in moderate) m=1;; high) h=1;; critical) c=1;; esac
  printf '{"vulnerabilities":{"lodash":{"name":"lodash","severity":"%s","via":[{"source":1,"url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc","severity":"%s"}]}},%s}\n' \
    "$1" "$1" "$(meta "$m" "$h" "$c" 1)" > "$ESC/audit.json"; echo "$2" > "$ESC/audit.rc"; }

g_edad() {
  esc_new; tiempos plain 2.0.0:86400 1.9.0:360000 1.8.0:1080000; corre
  rc_es "R1 versión de 24 h descartada → rc 0" 0
  fila "R1 se elige 1.9.0 (100 h) y no 2.0.0 (24 h)" plain "1\.9\.0${T}"
  fila "R9 el lock lleva versión, publicada, resuelta, origen y uso" plain "1\.9\.0${T}$(isoz $((NOW-360000)))${T}$(isoz $NOW)${T}edad72h${T}global${T}-$"
  en_lock "R9 cabecera con edad mínima 72" "edad_minima_horas=72"
  en_log "M8 el package-lock del audit se resuelve con --before = resolución − 72 h + 1 s (transitivas incluidas)" "--before=$(isoz $((NOW-259199)))"
  en_lock "N8 el lock anota el --before usado (igual al de la orden npm)" "# before=$(isoz $((NOW-259199)))"
  esc_new; tiempos plain 2.0.0:259200 1.9.0:1000000; corre; fila "R3 borde: exactamente 72 h SÍ entra" plain "2\.0\.0${T}"
  rc_es "D14a versión publicada en el segundo del límite con fracción (.123Z): el --before +1 s la resuelve, sin ETARGET → rc 0" 0
  esc_new; tiempos plain 2.0.0:259199 1.9.0:1000000; corre; fila "R3 borde: 72 h menos 1 s NO entra" plain "1\.9\.0${T}"
  esc_new; tiempos plain 2.0.0:3600 1.9.0:7200; corre; rc_es "R5 ninguna versión de ≥ 72 h → rc 4" 4; sin_lock "R5 sin lock"
  esc_new; tiempos plain 2.0.0:-3600 1.9.0:1000000; corre; fila "R4 fecha futura no es elegible" plain "1\.9\.0${T}"
  esc_new; printf '{"2.0.0":"ayer","1.9.0":"%s"}\n' "$(iso $((NOW-1000000)))" > "$ESC/time.plain"; corre; fila "R4 fecha ilegible no es elegible" plain "1\.9\.0${T}"
  esc_new; tiempos plain 2.0.0:86400 1.9.0:360000; RH_EDAD_MIN_H=0 EDAD_MIN_H=0 corre; fila "R15 ninguna variable de entorno baja la edad mínima" plain "1\.9\.0${T}"
}
g_versiones() {
  esc_new; tiempos plain 2.0.0:400000 1.9.0:500000; echo '["1.9.0"]' > "$ESC/vers.plain"; corre; fila "V1 una versión con fecha que ya no está en versions (retirada) NO es elegible" plain "1\.9\.0${T}"
  esc_new; tiempos plain 2.0.0:400000 1.9.0:500000; echo '"usa la 2.0.1"' > "$ESC/dep.plain_2.0.0"; corre; fila "V2 una versión deprecada NO es elegible" plain "1\.9\.0${T}"
  esc_new; tiempos plain 2.0.0:400000 1.9.0:500000; echo '"d"' > "$ESC/dep.plain_2.0.0"; echo '"d"' > "$ESC/dep.plain_1.9.0"; corre; rc_es "V3 todas deprecadas → rc 4" 4; sin_lock "V3 sin lock"
  esc_new; printf '{"1.9.0":"%s","9.9.9\\n":"%s"}\n' "$(iso $((NOW-500000)))" "$(iso $((NOW-600000)))" > "$ESC/time.plain"; corre
  rc_es "V4 una clave de versión con salto de línea final no pasa la expresión (fin estricto, no «\$» de jq) → rc 0" 0; fila "V4 se elige la 1.9.0" plain "1\.9\.0${T}"
  esc_new; printf '{"2.0.0":"2026-02-30T00:00:00.000Z","1.9.0":"%s"}\n' "$(iso $((NOW-500000)))" > "$ESC/time.plain"; corre
  fila "V5 una fecha imposible (02-30, que jq normaliza a otro día) no es elegible" plain "1\.9\.0${T}"
}
g_pre() { esc_new; tiempos plain 3.0.0-rc.1:1000000 2.0.0-0:1000000 2.0.0+b1:1000000 1.9.0:400000; corre; rc_es "R2 prerrelease/build descartadas → rc 0" 0; fila "R2 se elige la estable 1.9.0" plain "1\.9\.0${T}"; }
g_audit() {
  esc_new; audit_con moderate 1; corre; rc_es "A1 solo moderate → rc 0 (no bloquea)" 0
  en_lock "A1 el aviso queda en el lock (sección)" "# avisos_no_bloqueantes:"; en_lock "A1 con paquete, versión, severidad y GHSA" "lodash@4.17.20 moderate GHSA-aaaa-bbbb-cccc"
  if grep -qF "GHSA-aaaa-bbbb-cccc" "$ESC/out"; then ok "A1 el aviso también va al log"; else bad "A1 el aviso no está en el log"; fi
  if [ -n "${HERR_MUESTRA:-}" ]; then echo "--- herramientas.lock de ejemplo (A1) ---"; cat "$ESC/herramientas.lock"; echo "--- fin ---"; fi
  esc_new; audit_con high 1; corre; rc_es "A2 un high → rc 5" 5; sin_lock "A2 sin lock"
  esc_new; audit_con critical 1; corre; rc_es "A3 un critical → rc 5" 5; sin_lock "A3 sin lock"
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"high":2}}}' 1; corre; rc_es "au1 contadores sin total y con high → rc 5" 5; sin_lock "au1 sin lock"
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{}}}' 0; corre; rc_es "au2 metadatos vacíos → rc 5 (faltan los contadores)" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"critical":1,"total":0}}}' 1; corre; rc_es "au3 critical con total 0 y contadores ausentes → rc 5" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":1,"total":0}}}' 1; corre; rc_es "au3b critical con total 0 y contadores completos → rc 5 (high/critical se miran solos)" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":"0","low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' 0; corre; rc_es "au4 contador que no es entero → rc 5" 5
  esc_new; aud_raw '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' 0; corre; rc_es "au5 sin .vulnerabilities → rc 5 (forma inesperada)" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":5,"critical":-5,"total":0}}}' 1; corre; rc_es "au6 high 5 y critical -5 que se compensan → rc 5" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":-1,"critical":1,"total":0}}}' 1; corre; rc_es "au6b high -1 y critical 1 → rc 5" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":2,"moderate":0,"high":2,"critical":-2,"total":2}}}' 1; corre; rc_es "au6c low 2, high 2 y critical -2 → rc 5" 5
  esc_new; aud_raw '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":-1,"low":1,"moderate":0,"high":0,"critical":0,"total":0}}}' 1; corre; rc_es "au7 un contador negativo aunque la suma cuadre → rc 5 (enteros NO negativos)" 5
  esc_new; printf '{"vulnerabilities":{},%s}\n' "$(meta 0 0 1 1)" > "$ESC/audit.json"; echo 1 > "$ESC/audit.rc"; corre; rc_es "A4 critical solo en los contadores → rc 5" 5
  esc_new; audit_con banana 1; corre; rc_es "A5 severidad desconocida → rc 5 (fail-closed)" 5
  esc_new; echo basura > "$ESC/audit.json"; corre; rc_es "A6 salida no JSON → rc 5" 5
  esc_new; echo '{"error":{"code":"ENOAUDIT"}}' > "$ESC/audit.json"; echo 1 > "$ESC/audit.rc"; corre; rc_es "A7 error de audit sin metadatos → rc 5" 5
  esc_new; echo 124 > "$ESC/audit.rc"; corre; rc_es "A8 audit cortado por timeout (rc 124) → rc 5" 5; sin_lock "A8 sin lock"
}
g_osv() {
  esc_new; echo '{"vulns":[{"id":"GHSA-x","database_specific":{"severity":"HIGH"}}]}' > "$ESC/osv.plain"; corre; rc_es "O1 OSV con severidad HIGH → rc 6" 6; sin_lock "O1 sin lock"
  esc_new; echo '{"vulns":[{"id":"MAL-2026-1","database_specific":{"severity":"LOW"}}]}' > "$ESC/osv.plain"; corre; rc_es "O2 OSV MAL-* (malware) bloquea → rc 6" 6
  esc_new; echo '{"vulns":[{"id":"GHSA-y"}]}' > "$ESC/osv.plain"; corre; rc_es "O3 OSV sin severidad legible bloquea → rc 6" 6
  esc_new; touch "$ESC/osv-fail"; corre; rc_es "O4 OSV inalcanzable → rc 6" 6; sin_lock "O4 sin lock"
  esc_new; echo '{"vulns":[{"id":"GHSA-z","database_specific":{"severity":"LOW"}}]}' > "$ESC/osv.plain"; corre; rc_es "O5 OSV solo LOW → rc 0" 0; en_lock "O5 el aviso LOW queda en el lock" "plain@1.9.0 LOW GHSA-z"
  esc_new; echo '{"vulns":[{"id":"GHSA-p","database_specific":{"severity":"LOW"}}],"next_page_token":"t"}' > "$ESC/osv.plain"; corre; rc_es "O6 OSV paginado (next_page_token) → rc 6" 6
  esc_new; echo '{"vulns":[{"id":"GHSA-t","database_specific":{"severity":"HIGH"}}]}' > "$ESC/osv.tsx"; corre; rc_es "O7 OSV se consulta también para tsx (uso npx) → rc 6" 6
  esc_new; echo '{"code":5,"message":"x"}' > "$ESC/osv.plain"; corre; rc_es "O8 respuesta con code/message (clave desconocida) → rc 6" 6
  esc_new; echo '{"vulns":[{"id":"OSV-2026-1","aliases":["MAL-2026-5"],"database_specific":{"severity":"LOW"}}]}' > "$ESC/osv.plain"; corre; rc_es "O9 MAL- en los aliases bloquea → rc 6" 6
  esc_new; echo '{"vulns":[{"id":"mal-2026-1","database_specific":{"severity":"LOW"}}]}' > "$ESC/osv.plain"; corre; rc_es "O10 MAL- en minúsculas bloquea → rc 6" 6
  local v; for v in '"x"' null 5 '{"id":"GHSA-q"}'; do
    esc_new; echo "{\"vulns\":$v}" > "$ESC/osv.plain"; corre; rc_es "O11 .vulns que no es un arreglo ($v) bloquea → rc 6" 6
  done
  esc_new; echo '{}' > "$ESC/osv.plain"; corre; rc_es "O12 {} (sin avisos) sigue pasando → rc 0" 0
}
g_aislado() {
  local h n=0 f
  esc_new; h="$ESC/home"; mkdir -p "$h"; printf 'registry=https://evil.invalid/\n@scope:registry=https://evil.invalid/\n' > "$h/.npmrc"
  XENV=(HOME="$h" npm_config_registry=https://evil.invalid/ NPM_CONFIG_USERCONFIG=/x NODE_OPTIONS=--require=/x NODE_TLS_REJECT_UNAUTHORIZED=0 HTTPS_PROXY=http://evil.invalid:1 https_proxy=http://evil.invalid:1 CURL_CA_BUNDLE=/x)
  corre; XENV=()
  rc_es "N1 .npmrc malicioso y variables hostiles no cambian el registro → rc 0" 0
  if [ -s "$ESC/npm.env" ] || [ -s "$ESC/curl.env" ]; then bad "N1 llegan variables hostiles a npm o a curl: $(tr '\n' ' ' < "$ESC/npm.env" 2>/dev/null)"; else ok "N1 npm y curl corren con el entorno limpio de npm_config_*, NODE_*, *_PROXY y CURL_*"; fi
  [[ "$(<"$ESC/npm.log")" == *" --userconfig="*"/npmrc-vacio "* ]] || n=1
  for f in $NPMG $NPMS; do [[ "$(<"$ESC/npm.log")" == *" $f"* ]] || n=1; done
  if [ "$n" -eq 0 ] && [[ "$(<"$ESC/npm.log")" != *REGISTRO-AJENO* ]]; then ok "N2 todas las órdenes npm llevan un userconfig vacío propio, globalconfig, registro y registro de cada scope"; else bad "N2 faltan flags de aislamiento: $(grep -m1 AJENO "$ESC/npm.log")"; fi
  esc_new; mkdir "$ESC/cwd"; printf 'registry=https://evil.invalid/\nproxy=http://evil.invalid:1\n' > "$ESC/cwd/.npmrc"; CWD="$ESC/cwd" corre
  rc_es "N4 un .npmrc de proyecto en el cwd del llamador no se lee (las órdenes npm corren en el directorio de trabajo nuevo) → rc 0" 0
  if grep -q VIEW-SIN-PACKAGE-JSON "$ESC/npm.log"; then bad "N5b un npm view corrió antes de existir el package.json del directorio de trabajo"; else ok "N5b el package.json mínimo existe ANTES de la primera orden npm (raíz de proyecto propia)"; fi
}
g_aislado_real() { g_aislado; g_npmreal; }   # el npm REAL (config get, sin red) también ata los mutantes de userconfig
# La doble de npm de la fixture de montaje rechaza lo que rechaza el npm real: una suborden desconocida (los flags desconocidos los tolera, como npm).
g_doble_npm() {
  local d r1 r2 r3 r4 r5
  esc_new; d="$ESC/infra"; mkdir -p "$d/bin"; printf '{"homes":{},"ceo":"x"}\n' > "$d/infra.json"
  cp "${INFRAX:-$RAIZ/tests/fixtures/instalacion/infra-real.py}" "$d/bin/npm"; chmod +x "$d/bin/npm"
  INFRA_BASE="$d" PYTHONDONTWRITEBYTECODE=1 "$d/bin/npm" frobnicate > "$ESC/o1" 2>&1; r1=$?
  INFRA_BASE="$d" PYTHONDONTWRITEBYTECODE=1 "$d/bin/npm" install -g --opcion-nueva x@1.0.0 > "$ESC/o2" 2>&1; r2=$?
  INFRA_BASE="$d" PYTHONDONTWRITEBYTECODE=1 "$d/bin/npm" ls -g --depth=0 > "$ESC/o3" 2>&1; r3=$?
  INFRA_BASE="$d" PYTHONDONTWRITEBYTECODE=1 "$d/bin/npm" uninstal x > "$ESC/o4" 2>&1; r4=$?   # prefijo único de uninstall
  INFRA_BASE="$d" PYTHONDONTWRITEBYTECODE=1 "$d/bin/npm" installTest > "$ESC/o5" 2>&1; r5=$?   # camelCase → install-test (deref de cmd-list.js)
  if [ "$r1" -eq 1 ] && grep -qF 'Unknown command: "frobnicate"' "$ESC/o1" && [ "$r2$r3$r4$r5" = 0000 ]; then ok "D41 la doble de npm rechaza una suborden desconocida y acepta install/ls/uninstall (prefijo único), installTest (camelCase) y flags nuevos, como npm"; else bad "D41 rc=$r1/$r2/$r3/$r4/$r5: $(tr '\n' ' ' < "$ESC/o1" | cut -c1-120)"; fi
}
# El npm REAL, sin red: `config get` solo lee configuración. Se le pasan los flags EXACTOS que cada script emitió (sacados de su log).
real_npm() { # etiqueta línea-del-log
  local et="$1" l="$2" fl=() t r s="https://registry.npmjs.org/"
  for t in $l; do case "$t" in --userconfig=*|--globalconfig=*|--registry=*|--@*:registry=*) fl+=("$t");; esac; done
  r="$(env -i PATH="$PATH" HOME="$ESC/home" npm config get registry "${fl[@]}" 2>&1)"
  [[ " ${fl[*]} " != *" --@scope:registry="* ]] || s="$(env -i PATH="$PATH" HOME="$ESC/home" npm config get @scope:registry "${fl[@]}" 2>&1)"
  if [ "$r" = "https://registry.npmjs.org/" ] && [ "$s" = "https://registry.npmjs.org/" ]; then ok "NR $et: el npm REAL acepta los flags y da el registro oficial (y el del scope si lo lleva) con un ~/.npmrc hostil"; else bad "NR $et: npm real → registry='$r' scope='$s' (flags: ${fl[*]})"; fi
  [ -z "${NR_LOG:-}" ] || printf 'npm config get registry %s\n%s\nnpm config get @scope:registry %s\n%s\n' "${fl[*]}" "$r" "${fl[*]}" "$s"
}
g_npmreal() {
  if ! command -v npm > /dev/null 2>&1; then echo "  NO-EJECUTADO NR (npm real): no hay npm en el PATH (motivo declarado)"; return; fi
  esc_new; mkdir -p "$ESC/home"; printf 'registry=https://evil.invalid/\n@scope:registry=https://evil.invalid/\nproxy=http://evil.invalid:1\n' > "$ESC/home/.npmrc"
  corre; real_npm resolvedor "$(grep -m1 '^npm view' "$ESC/npm.log")"
  esc_new; golden; real_npm golden "$(grep -m1 '^npm install -g' "$ESC/npm.log")"
  esc_new; corre; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/herramientas.lock"; real_npm tsx.sh "$(grep -m1 '^npx' "$ESC/npx.log")"
}
g_red() {
  esc_new; touch "$ESC/view-fail"; corre; rc_es "R8 sin red (npm view falla) → rc 3" 3; sin_lock "R8 sin lock"
  if grep -q audit "$ESC/npm.log" 2>/dev/null; then bad "R8 llamó a audit sin versiones"; else ok "R8 no llega a audit ni a OSV"; fi
  esc_new; touch "$ESC/view-sleep"; RH_T=1 corre; rc_es "R8 registro que no responde (timeout) → rc 3" 3
}
g_override() {
  esc_new; tiempos plain 2.0.0:86400 1.9.0:360000
  printf 'plain\t2.0.0\t\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 override sin motivo → rc 2" 2; sin_lock "R10 sin lock"
  printf 'plain\t2.0.0\tcorto\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 motivo demasiado corto → rc 2" 2
  printf 'plain\t2.0.0\tparche urgente de seguridad (aviso X)\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 override con motivo → rc 0" 0
  en_log "M8 con un override el --before es la fecha de resolución + 1 s (el parche de < 72 h tiene que poder resolverse)" "--before=$(isoz $((NOW+1)))"
  en_lock "N8 con override el lock anota el --before y qué override lo relajó" "# before_override=plain@2.0.0 (el --before se relajó"
  fila "R10 el motivo y el origen quedan registrados (versión de 24 h aceptada)" plain "2\.0\.0${T}.*${T}override${T}global${T}parche urgente de seguridad \(aviso X\)$"
  printf 'otro\t2.0.0\tparche urgente de seguridad (aviso X)\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 paquete fuera de la lista → rc 2" 2
  printf 'plain\t2.0.0-rc.1\tparche urgente de seguridad (aviso X)\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 versión prerrelease → rc 2" 2
  printf 'plain\t7.7.7\tparche urgente de seguridad (aviso X)\n' > "$ESC/ov"; corre --overrides-file "$ESC/ov"; rc_es "R10 versión inexistente → rc 3" 3
  printf 'plain\t2.0.0\tparche urgente de seguridad (aviso X)\n' > "$ESC/ov"; audit_con high 1; corre --overrides-file "$ESC/ov"; rc_es "R11 el override también pasa por audit (high) → rc 5" 5
}
g_resto() {
  esc_new; printf 'previo\n' > "$ESC/herramientas.lock"; audit_con high 1; corre
  if [ "$(cat "$ESC/herramientas.lock")" = previo ]; then ok "R12 un fallo no toca el lock previo"; else bad "R12 el lock previo cambió"; fi
  esc_new; touch "$ESC/lock-ro"; corre   # el temporal del lock nace en solo lectura: la escritura única falla
  if [ "$(id -u)" -eq 0 ]; then echo "  SKIP R16 root escribe en un fichero de solo lectura: el caso no se puede ejercitar"
  else rc_es "R16 si falla la escritura del lock → rc 3" 3; sin_lock "R16 no queda lock (ni a medias)"
    if compgen -G "$ESC/apartado/herramientas.lock.*" > /dev/null; then ok "R16 el temporal huérfano se aparta a apartado/ (no se borra)"; else bad "R16 el temporal no está en apartado/"; fi; fi
  esc_new; mkdir "$ESC/t13"; touch "$ESC/t13/x"; corre --trabajo "$ESC/t13"; rc_es "R13 --trabajo no vacío → rc 2 (no se borra nada)" 2
  esc_new; printf 'plain\tweird\n' > "$ESC/lista"; corre; rc_es "R14 uso desconocido en la lista → rc 2" 2
  esc_new; printf 'plain\tglobal\nplain\tnpx\n' > "$ESC/lista"; corre; rc_es "R14 paquete repetido → rc 2" 2
  esc_new; printf 'plain global\n' > "$ESC/lista"; corre; rc_es "R14 línea sin tabulador → rc 2" 2
}

# --- envoltorio tsx.sh -------------------------------------------------------------------------------------------
tsx_run() { TRC=0; env PATH="$BIN:$PATH" ESC="$ESC" "$@" bash "${TSXX:-$TSX}" a.ts --x > "$ESC/out" 2>&1 || TRC=$?; }
LH='# herramientas.lock v1 (generado por resolver-herramientas.sh; no editar a mano)'
NPMT="--userconfig=$RAIZ/scripts/npmrc-vacio $NPMG"   # lo que pasa tsx.sh a npx (con el npmrc vacío del paquete)
g_tsx() {
  esc_new; corre; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/herramientas.lock"
  if [ "$TRC" -eq 0 ] && grep -qxF "npx --yes $NPMT --before=$(isoz $((NOW-259199))) tsx@1.9.0 a.ts --x" "$ESC/npx.log" && grep -qxF "# before=$(isoz $((NOW-259199)))" "$ESC/herramientas.lock"; then ok "T1 usa la versión del lock real del resolvedor (tsx@1.9.0), con el --before que el lock anota, y pasa los argumentos"; else bad "T1 — rc=$TRC $(cat "$ESC/npx.log" 2>/dev/null)"; fi
  local v
  for v in "sin cabecera|tsx${T}1.2.3${T}x${T}x${T}edad72h${T}npx${T}-" "sin fila tsx|$LH" "fila repetida|$LH
tsx${T}1.2.3${T}x${T}x${T}edad72h${T}npx${T}-
tsx${T}1.2.4${T}x${T}x${T}edad72h${T}npx${T}-" "versión latest|$LH
tsx${T}latest${T}x${T}x${T}edad72h${T}npx${T}-"; do
    esc_new; printf '%s\n' "${v#*|}" > "$ESC/l"; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/l"
    if [ "$TRC" -eq 2 ] && [ ! -e "$ESC/npx.log" ]; then ok "T3 lock con ${v%%|*} → rc 2 y npx NO se llama"; else bad "T3 ${v%%|*} — rc=$TRC"; fi
  done
  esc_new; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/no-existe"
  if [ "$TRC" -eq 2 ] && [ ! -e "$ESC/npx.log" ]; then ok "T4 lock indicado e inexistente → rc 2"; else bad "T4 rc=$TRC"; fi
  if [ -e /etc/talent-channels/herramientas.lock ]; then echo "  NO-EJECUTADO T2 (esta máquina tiene un lock de golden; motivo declarado)"
  else esc_new; tsx_run; V="$(grep -m1 -E '^TSX_VERSION_SELLADA=' "$TSX" | tr -d '"')"
    if [ "$TRC" -eq 0 ] && grep -qxF "npx --yes $NPMT --before=2026-09-20T07:22:17.792Z tsx@${V#*=} a.ts --x" "$ESC/npx.log" && grep -q 'sellada' "$ESC/out"; then ok "T2 sin lock usa el valor sellado y lo avisa"; else bad "T2 rc=$TRC"; fi; fi
  if grep -Eq '^TSX_VERSION_SELLADA="[0-9]+\.[0-9]+\.[0-9]+"$' "$TSX" && ! grep -q 'tsx@latest' "$TSX"; then ok "T5 el valor sellado es X.Y.Z exacto (nunca latest)"; else bad "T5 valor sellado"; fi
  esc_new; corre; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/herramientas.lock" HOME="$ESC" npm_config_registry=https://evil.invalid/ NODE_OPTIONS=--require=/x HTTPS_PROXY=http://evil.invalid:1 CURL_CA_BUNDLE=/x
  if [ "$TRC" -eq 0 ] && [ ! -s "$ESC/npx.env" ]; then ok "T6 tsx.sh quita de npx npm_config_*, NODE_OPTIONS, *_PROXY y CURL_*"; else bad "T6 llegan variables hostiles a npx: $(tr '\n' ' ' < "$ESC/npx.env" 2>/dev/null)"; fi
  local r1 r2   # la doble imita la regla de npm: publicada <= before, al milisegundo (tsx 4.23.15 se publicó a las 07:22:17.792Z)
  esc_new; env PATH="$BIN:$PATH" npx --yes --before=2026-09-20T07:22:17Z tsx@4.23.15 f.ts > "$ESC/o1" 2>&1; r1=$?
  env PATH="$BIN:$PATH" npx --yes --before=2026-09-20T07:22:17.792Z tsx@4.23.15 f.ts > "$ESC/o2" 2>&1; r2=$?
  if [ "$r1" -ne 0 ] && grep -q ETARGET "$ESC/o1" && [ "$r2" -eq 0 ]; then ok "T7 la doble de npx imita npm: un --before truncado al segundo da ETARGET y con milisegundos resuelve"; else bad "T7 la doble de npx no imita la regla de npm (rc $r1 / $r2)"; fi
  esc_new; tsx_run
  if [ -e /etc/talent-channels/herramientas.lock ]; then echo "  NO-EJECUTADO T8 (esta máquina tiene un lock de golden)"
  elif [ "$TRC" -eq 0 ] && [[ "$(<"$ESC/out")" != *ETARGET* ]]; then ok "T8 sin lock, el --before sellado cubre la publicación al milisegundo: npx resuelve la versión sellada"; else bad "T8 sin lock, npx no resuelve (rc=$TRC): $(tr '\n' ' ' < "$ESC/out" | cut -c1-200)"; fi
  if grep -Eq '^TSX_PUBLICADA_SELLADA="[0-9T:-]+\.[0-9]{3}Z"' "$TSX"; then ok "T8b la marca sellada lleva milisegundos (.NNNZ), no está truncada al segundo"; else bad "T8b la marca sellada de tsx.sh no lleva milisegundos"; fi
  esc_new; tiempos tsx 2.0.0:86400 1.9.0:259200; corre; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/herramientas.lock"
  if [ "$TRC" -eq 0 ] && grep -qxF "npx --yes $NPMT --before=$(isoz $((NOW-259199))) tsx@1.9.0 a.ts --x" "$ESC/npx.log"; then ok "D14b tsx con lock: versión publicada en el segundo del límite (.123Z) → el --before +1 s la resuelve"; else bad "D14b rc=$TRC $(tr '\n' ' ' < "$ESC/out" | cut -c1-200)"; fi
  esc_new; printf '%s\n# resuelta_utc=2026-10-24T00:00:00Z\ntsx%s4.23.15%s2026-09-20T07:22:17Z%s2026-10-24T00:00:00Z%sedad72h%snpx%s-\n' "$LH" "$T" "$T" "$T" "$T" "$T" "$T" > "$ESC/l"; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/l"
  if [ "$TRC" -eq 0 ] && grep -qF -- "--before=2026-10-21T00:00:01Z tsx@4.23.15 " "$ESC/npx.log"; then ok "D14d la versión sellada 4.23.15 sigue resolviéndose con lock (--before = resolución − 72 h + 1 s)"; else bad "D14d rc=$TRC"; fi
  esc_new; printf '%s\n# resuelta_utc=2026-10-24T00:00:00Z\ntsx%s4.23.15%s2026-09-20T07:22:17Z%s2026-10-24T00:00:00Z%soverride%snpx%sparche urgente de seguridad\n' "$LH" "$T" "$T" "$T" "$T" "$T" "$T" > "$ESC/l"; tsx_run TF_HERRAMIENTAS_LOCK="$ESC/l"
  if [ "$TRC" -eq 0 ] && grep -qF -- "--before=2026-10-24T00:00:01Z tsx@4.23.15 " "$ESC/npx.log"; then ok "D14e tsx con lock y fila en override: --before = resolución + 1 s"; else bad "D14e rc=$TRC $(tr '\n' ' ' < "$ESC/out" | cut -c1-160)"; fi
}

# --- fragmento REAL del golden -----------------------------------------------------------------------------------
extrae() { local a b; a="$(grep -nxF -m1 "$1" "$G" | cut -d: -f1)"; b="$(grep -nxF -m1 "$2" "$G" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && sed -n "$((a + 1)),$((b - 1))p" "$G"; }
FRAG="$(extrae '# herramientas:ini' '# herramientas:fin')" || FRAG=""
HOST="$(extrae '# herramientas-host:ini' '# herramientas-host:fin')" || HOST=""
# shellcheck disable=SC2016  # el patrón busca el texto literal $RH_NPM de la línea de instalación
INST="$(grep -m1 '^npm install -g \$RH_NPM' "$G" || true)"; INST="${INST%%\'*}"
GTXT="$(cat "$G")"; GF="$G"   # GF: el fichero que miran las comprobaciones estáticas (el mutante lo sustituye por una copia alterada)
golden() { # preparación opcional ya hecha en $ESC; XENV = entorno hostil
  local d="$ESC" f="$FRAG"; NPMGO="--userconfig=$d/var/herramientas-audit/npmrc-vacio $NPMG $NPMS"; mkdir -p "$d/etc" "$d/var"; cp "$ESC/lista" "$d/var/herramientas.lista"; cp "$RES" "$d/var/resolver-herramientas.sh"
  f="${f//\/etc\/talent-channels/$d/etc}"; f="${f//\/var\/lib\/talent-channels/$d/var}"
  GRC=0; env "${XENV[@]}" PATH="$BIN:$PATH" bash -ec "$f"$'\n'"$INST" > "$ESC/out" 2>&1 || GRC=$?; }
g_golden() {
  if [ -z "$FRAG" ] || [ -z "$INST" ]; then bad "G0 anclas del fragmento de herramientas no encontradas en 02-golden.sh"; return; fi
  local h antes
  esc_new; h="$ESC/home"; mkdir -p "$h"; printf 'registry=https://evil.invalid/\n@scope:registry=https://evil.invalid/\n' > "$h/.npmrc"
  XENV=(HOME="$h" npm_config_registry=https://evil.invalid/ NODE_OPTIONS=--require=/x HTTPS_PROXY=http://evil.invalid:1); golden; XENV=()
  antes="--before=$(isoz $((NOW-259199)))"
  if [ "$GRC" -eq 0 ] && grep -qxF "npm install -g $NPMGO $antes @scope/cli@1.9.0 plain@1.9.0" "$ESC/npm.log"; then ok "G1 npm install -g: pkg@versión del lock, registro fijo, sin npmrc y con --before = resolución − 72 h (con .npmrc y entorno hostiles)"; else bad "G1 rc=$GRC $(grep -E 'install -g|AJENO' "$ESC/npm.log" 2>/dev/null)"; fi
  if [ -s "$ESC/npm.env" ]; then bad "G1 llegan variables hostiles a npm: $(tr '\n' ' ' < "$ESC/npm.env")"; else ok "G1 el install -g corre con el entorno limpio de variables de npm"; fi
  if grep -qE 'install -g .* tsx@' "$ESC/npm.log"; then bad "G1 tsx no se instala globalmente"; else ok "G1 tsx (uso npx) no se instala globalmente"; fi
  if grep -qxF "npm ls -g --depth=0 $NPMGO @scope/cli@1.9.0 plain@1.9.0" "$ESC/npm.log"; then ok "G3 se verifica lo instalado contra el lock"; else bad "G3 falta npm ls -g"; fi
  esc_new; audit_con high 1; golden
  if [ "$GRC" -ne 0 ] && ! grep -q 'install -g' "$ESC/npm.log"; then ok "G2 resolvedor en rc≠0 → el bloque aborta ANTES de instalar nada"; else bad "G2 rc=$GRC"; fi
  esc_new; echo 1 > "$ESC/ls.rc"; golden; if [ "$GRC" -ne 0 ]; then ok "G3 npm ls -g discrepante → el bloque falla"; else bad "G3 npm ls discrepante pasó"; fi
  esc_new; printf 'plain\t2.0.0\tparche con comilla '"'"' y ; punto y coma\n' > "$ESC/lib-ov"; mkdir -p "$ESC/var"; cp "$ESC/lib-ov" "$ESC/var/override.tsv"; tiempos plain 2.0.0:86400 1.9.0:360000; golden
  if [ "$GRC" -eq 0 ] && grep -qxF "npm install -g $NPMGO --before=$(isoz $((NOW+1))) @scope/cli@1.9.0 plain@2.0.0" "$ESC/npm.log"; then ok "G6 override por fichero: instalado desde el lock (--before = resolución + 1 s para el parche urgente), sin interpretar el motivo"; else bad "G6 rc=$GRC $(grep -E 'install -g|AJENO' "$ESC/npm.log" 2>/dev/null) $(tail -2 "$ESC/out")"; fi
  esc_new; tiempos plain 2.0.0:259200 1.9.0:1000000; golden
  if [ "$GRC" -eq 0 ] && grep -qxF "npm install -g $NPMGO --before=$(isoz $((NOW-259199))) @scope/cli@1.9.0 plain@2.0.0" "$ESC/npm.log"; then ok "D14c golden: versión publicada en el segundo del límite (.123Z) → el install -g con --before +1 s la resuelve"; else bad "D14c rc=$GRC $(grep -E 'install -g|ETARGET' "$ESC/npm.log" "$ESC/out" 2>/dev/null | cut -c1-160)"; fi
  local ln_ca ln_ini ln_npm
  ln_ca="$(grep -nxF -m1 'apt-get install -y -qq --only-upgrade ca-certificates' "$GF" | cut -d: -f1)"
  ln_ini="$(grep -nxF -m1 '# herramientas:ini' "$GF" | cut -d: -f1)"
  # shellcheck disable=SC2016  # patrón literal
  ln_npm="$(grep -n -m1 '^npm install -g \$RH_NPM' "$GF" | cut -d: -f1)"
  if [ -n "$ln_ca" ] && [ -n "$ln_ini" ] && [ -n "$ln_npm" ] && [ "$ln_ca" -lt "$ln_ini" ] && [ "$ln_ini" -lt "$ln_npm" ]; then ok "G4 orden: ca-certificates < resolvedor < instalación"; else bad "G4 orden ($ln_ca $ln_ini $ln_npm)"; fi
  if grep -qE '^npm install -g +[@a-z]' "$GF"; then bad "G5 hay un npm install -g con nombres sueltos (sin lock)"; else ok "G5 ningún npm install -g con nombres sueltos"; fi
  # shellcheck disable=SC2016  # texto literal del script
  if grep -qF '. "$HERE/coderabbit-pin.conf"' "$GF"; then ok "G5 CodeRabbit sigue por coderabbit-pin.conf"; else bad "G5 CodeRabbit sin su pin"; fi
  local npw nnw; npw="$(grep -cE 'npx( --[a-z-]+)* playwright install' "$GF")"; nnw="$(grep -cF 'npx --no-install playwright install' "$GF")"
  if [ "$npw" -ge 2 ] && [ "$npw" -eq "$nnw" ]; then ok "G5c ninguna orden npx de playwright instala sin lock (las $npw llevan --no-install)"; else bad "G5c hay $npw órdenes npx de playwright y solo $nnw con --no-install (instalarían sin lock)"; fi
  local want got; want="$(printf '%s\n' '@anthropic-ai/claude-code	global' '@openai/codex	global' '@railway/cli	global' 'convex	global' 'supabase	global' 'tsx	npx')"
  got="$(grep -v '^#' "$ASSETS_REAL/herramientas.lista" 2>/dev/null)"; if [ "$got" = "$want" ]; then ok "G5 herramientas.lista: los 5 CLIs globales + tsx"; else bad "G5 herramientas.lista distinta"; fi
}
g_host() {
  if [ -z "$HOST" ]; then bad "G7 anclas del lado host no encontradas"; return; fi
  esc_new
  # shellcheck disable=SC2034,SC2329  # ASSETS/HERE/GOLDEN y las funciones las usa el fragmento real, evaluado con eval
  hrun() { ( ASSETS="$ASSETS_REAL"; HERE="$SCRIPTS"; GOLDEN=g; tc_die() { echo "tc_die: $*" >&2; exit 1; }; tc_cexec() { :; }
      incus() { echo "incus $*" >> "$ESC/incus.log"; if [ "${3:-}" = "-" ]; then cat > "$ESC/pushed"; fi; return 0; }; eval "$HOST" ) > "$ESC/out" 2>&1; }
  if hrun && [ ! -e "$ESC/pushed" ]; then ok "G7 sin override no se empuja ninguna fila"; else bad "G7 sin override"; fi
  if TC_HERRAMIENTAS_OVERRIDE=plain=1.2.3 hrun; then bad "G7 override sin motivo pasó"; else ok "G7 override sin motivo → tc_die"; fi
  if TC_HERRAMIENTAS_OVERRIDE=plain=1.2.3 TC_HERRAMIENTAS_MOTIVO='parche urgente (aviso X)' hrun && [ "$(cat "$ESC/pushed")" = "plain${T}1.2.3${T}parche urgente (aviso X)" ]; then ok "G7 override válido: fila empujada tal cual"; else bad "G7 override válido"; fi
  local rd bp=0 l np
  rd="$(grep -m1 '^RH_DIR=' <<< "$FRAG" | cut -d= -f2)"; np="$(grep -c '^incus file push ' "$ESC/incus.log")"
  while read -r l; do [[ "${l##* }" == "g$rd/"* ]] || bp=1; done < <(grep '^incus file push ' "$ESC/incus.log")
  if [ -n "$rd" ] && [ "$np" -ge 3 ] && [ "$bp" -eq 0 ]; then ok "G7b las rutas de empuje del host cuelgan de RH_DIR ($rd), la del contenedor (resolvedor, lista y override)"; else bad "G7b ruta de empuje distinta de RH_DIR='$rd' ($np empujes, desajuste=$bp)"; fi
  if TC_HERRAMIENTAS_OVERRIDE=plain=1.2.3 TC_HERRAMIENTAS_MOTIVO=corto hrun; then bad "G7 motivo de 5 caracteres pasó"; else ok "G7 motivo corto (< 10) → tc_die en el host"; fi
  if TC_HERRAMIENTAS_OVERRIDE=plain=1.2.3 TC_HERRAMIENTAS_MOTIVO="$(printf '%0201d' 0)" hrun; then bad "G7 motivo de 201 caracteres pasó"; else ok "G7 motivo largo (> 200) → tc_die en el host"; fi
  if TC_HERRAMIENTAS_OVERRIDE='x;touch y=1.2.3' TC_HERRAMIENTAS_MOTIVO='parche urgente (aviso X)' hrun; then bad "G7 nombre con metacaracteres pasó"; else ok "G7 nombre con metacaracteres → tc_die"; fi
  if TC_HERRAMIENTAS_OVERRIDE=plain=1.2.3 TC_HERRAMIENTAS_MOTIVO=$'uno\ndos largo' hrun; then bad "G7 motivo con salto de línea pasó"; else ok "G7 motivo con salto de línea → tc_die"; fi
}

# --- censo de npx y tsx (ratchet) --------------------------------------------------------------------------------
CHK_AW="check-a""wk-portable.py"   # (partido: el barrido de programas del intérprete de líneas no debe tomarlo por un uso)
CENSO_EXC=("--exclude=$CHK_AW" --exclude=batch-issues.ts --exclude=check-fail-open-auth.ts --exclude=linear-client.ts --exclude=upload-attachment.ts
  --exclude=verify-webhook.ts --exclude=issue_craft_helper.ts --exclude=test-github-seguridad.py)   # los ficheros del censo declarado
formas() { # dirs → ficheros con formas ejecutables de npx/tsx fuera del envoltorio y del censo (-z: cada fichero ENTERO, las líneas unidas)
  grep -rlzE --exclude='CHANGELOG*' --exclude=herramientas-72h.sh --exclude=tsx.sh "${CENSO_EXC[@]}" \
    -e "[\"']npx[\"'][^]]{0,80}[\"']tsx[\"']" -e 'npx[[:space:]]+(-[-A-Za-z0-9=@.]+[[:space:]]+)*tsx' \
    -e '(^|[^A-Za-z0-9_-])npm[[:space:]]+(exec|x)([[:space:]]|$)' -e '(^|[^A-Za-z0-9_-])(dlx|bunx|pnpx)([^A-Za-z0-9_-]|$)' "$@" 2>/dev/null; }
# Tuberías cuyo lector puede cortar al escritor (SIGPIPE con pipefail). Las letras entre corchetes evitan que el patrón case consigo mismo.
cortes() { grep -nE '[^|]\| *(hea[d]|grep -[a-zA-Z]*q|grep --quie[t]|sed[^|]* [q]( |$)|a[w]k[^|]*exi[t]|rea[d]( |$))' "$@"; }
g_censo() {
  local esperado got n l
  esperado="$(printf '%s\n' "./scripts/$CHK_AW:4" ./skills/linear-skill/scripts/batch-issues.ts:4 ./skills/linear-skill/scripts/check-fail-open-auth.ts:1 \
    ./skills/linear-skill/scripts/linear-client.ts:7 ./skills/linear-skill/scripts/upload-attachment.ts:4 ./skills/linear-skill/scripts/verify-webhook.ts:5 \
    ./skills/talent-issue-craft/scripts/issue_craft_helper.ts:7 ./skills/talent-sentry-guard/tests/test-github-seguridad.py:1)"
  got="$(cd "$RAIZ" && grep -rcE --exclude='CHANGELOG*' --exclude=herramientas-72h.sh 'npx( -y| --yes)? tsx' . 2>/dev/null | grep -v ':0$' | sort)"
  if [ "$got" = "$(printf '%s\n' "$esperado" | sort)" ]; then ok "I1 censo: lo que queda de npx+tsx es EXACTAMENTE la lista declarada (33 líneas)"; else bad "I1 censo distinto: $(printf '%s' "$got" | tr '\n' ' ')"; fi
  got="$(cd "$RAIZ" && formas skills scripts tests)"
  if [ -z "$got" ]; then ok "I2 ninguna forma ejecutable de npx/tsx (npm exec, dlx, bunx...) fuera del envoltorio y del censo"; else bad "I2 quedan: $got"; fi
  mkdir -p "$WORK/censo"; n=0   # una forma por FICHERO (el ratchet lee cada fichero entero y lista ficheros)
  while IFS= read -r l; do n=$((n + 1)); printf '%s\n' "$l" > "$WORK/censo/f$n.mjs"; done <<'__FIN_FORMAS__'
execFileSync('npx', ['--yes', 'tsx', f]);
execFileSync("npx", ["-y", "tsx", f]);
subprocess.run(["npx", "--yes", "--package=tsx", "tsx", f])
npx  tsx  fichero.ts
npx -y  tsx fichero.ts
npx --package=tsx@4 tsx f.ts
npm exec tsx fichero.ts
npm x tsx fichero.ts
pnpm dlx tsx fichero.ts
bunx tsx fichero.ts
pnpx tsx f.ts
__FIN_FORMAS__
  printf 'execFileSync("npx", [\n  "--yes",\n  "tsx",\n  f]);\n' > "$WORK/censo/m1.mjs"; printf 'npx\n  tsx fichero.ts\n' > "$WORK/censo/m2.sh"
  got="$(formas "$WORK/censo" | wc -l)"
  if [ "$got" -eq 13 ]; then ok "I2b el ratchet caza las 13 formas de ficheros sintéticos (comillas, -y, --package, espacios dobles, npm exec/x, dlx, bunx, pnpx y DOS repartidas en varias líneas)"; else bad "I2b el ratchet solo caza $got de 13 formas"; fi
  P='|'; mkdir -p "$WORK/cortes"   # las tuberías de prueba se arman con $P para que ESTE fichero no las contenga literales
  printf '%s\n' "x $P sed q" "x $P aw""k '{exit}'" "x $P grep --quiet y" "x $P read -r v" "x $P head -1" "x $P grep y" > "$WORK/cortes/c.sh"
  got="$(cortes "$WORK/cortes/c.sh" | wc -l)"
  if [ "$got" -eq 5 ]; then ok "D1b el detector de tuberías con corte temprano caza sed q, aw""k exit, grep --quiet, read y head (y deja pasar grep a secas)"; else bad "D1b el detector caza $got de 5 formas"; fi
  got="$(cortes "${BASH_SOURCE[0]}" "$RES")"
  if [ -z "$got" ]; then ok "D1 ni la prueba ni el resolvedor usan una tubería cuyo lector pueda cortar al escritor (SIGPIPE con pipefail)"; else bad "D1 tuberías con corte temprano: $got"; fi
  got="$(find "$RAIZ/skills" -name '*.ts' -perm /111 2>/dev/null)"
  if [ -z "$got" ]; then ok "I3 ningún .ts de skills tiene bit de ejecución (los shebangs son inertes)"; else bad "I3 .ts ejecutables: $got"; fi
}

# --- mutantes ----------------------------------------------------------------------------------------------------
fallos_de() { local sv_pass=$PASS sv_fail=$FAIL; "$@" > "$WORK/g.out" 2>&1; NF=$((FAIL - sv_fail)); PASS=$sv_pass; FAIL=$sv_fail; }
mutante() { # nombre ancla reemplazo grupo [fichero [variable]]  (por defecto el resolvedor, que se sustituye por RESX)
  local n="$1" a="$2" r="$3" src="${5:-$RES}" var="${6:-RESX}" t m d="$WORK/mut/$1"
  t="$(cat "$src" 2>/dev/null)"; m="${t/"$a"/"$r"}"
  if [ -z "$t" ] || [ "$m" = "$t" ]; then bad "$n: ancla no encontrada en ${src##*/}"; return; fi
  mkdir -p "$d"; printf '%s\n' "$m" > "$d/${src##*/}"; cp "${src%/*}/npmrc-vacio" "$d/" 2>/dev/null || true
  printf -v "$var" '%s' "$d/${src##*/}"; fallos_de "$4"; printf -v "$var" '%s' ""; local con=$NF
  fallos_de "$4"
  if [ "$con" -gt 0 ] && [ "$NF" -eq 0 ]; then ok "$n: ROJO con el mutante ($con casos) y VERDE al revertir"; else bad "$n: con mutante fallan $con, sin mutante $NF"; fi
}
mut_texto() { # nombre variable ancla reemplazo grupo — mutante sobre un texto global extraído del golden (FRAG o HOST)
  local n="$1" v="$2" a="$3" r="$4" g="$5" orig="${!2}" con
  if [[ "$orig" != *"$a"* ]]; then bad "$n: ancla no encontrada en $v"; return; fi
  printf -v "$v" '%s' "${orig/"$a"/"$r"}"; fallos_de "$g"; con=$NF
  printf -v "$v" '%s' "$orig"; fallos_de "$g"
  if [ "$con" -gt 0 ] && [ "$NF" -eq 0 ]; then ok "$n: ROJO con el mutante ($con casos) y VERDE al revertir"; else bad "$n: con mutante fallan $con, sin mutante $NF"; fi
}
# shellcheck disable=SC2016  # las anclas son texto literal del resolvedor
g_mutantes() {
  mutante mut-sin-filtro-72h 'map(select(.ep <= $lim))' 'map(select(true))' g_edad
  mutante mut-tsx-before-truncado-al-segundo 'TSX_PUBLICADA_SELLADA="2026-09-20T07:22:17.792Z"' 'TSX_PUBLICADA_SELLADA="2026-09-20T07:22:17Z"' g_tsx "$TSX" TSXX
  mutante mut-audit-sucio-aceptado '[ "$aud_rc" -le 1 ] && jq -e' 'true || jq -e' g_audit
  mutante mut-high-no-bloqueante "NOBLOQ='[\"info\",\"low\",\"moderate\"]'; BLOQ='[\"high\",\"critical\"]'" "NOBLOQ='[\"info\",\"low\",\"moderate\",\"high\"]'; BLOQ='[\"critical\"]'" g_audit
  mutante mut-audit-sin-high-critical '([$bl[] as $s | $m[$s]] | all(. == 0))' 'true' g_audit
  mutante mut-audit-negativos-aceptados ' and . >= 0' '' g_audit
  mutante mut-userconfig-y-globalconfig-iguales '"--userconfig=$VACIO"' '--userconfig=/dev/null' g_aislado_real
  mutante mut-npm-view-sin-cwd-aislado 'cd "$TRABAJO" && limpio timeout "$t"' 'limpio timeout "$t"' g_aislado
  mutante mut-osv-vulns-no-arreglo '(has("vulns") | not) or (.vulns | type == "array")' 'true' g_osv
  mutante mut-versiones-no-miradas '($vs | index($k)) != null' 'true' g_versiones
  mutante mut-deprecada-elegible '[ -z "${dep//[[:space:]]/}" ] || [ "$dep" = '"'"'""'"'"' ]' 'true' g_versiones
  mutante mut-registro-del-entorno 'REGISTRO="https://registry.npmjs.org/"' 'REGISTRO="${npm_config_registry:-https://registry.npmjs.org/}"' g_aislado
  mutante mut-npm-sin-userconfig-vacio '"--userconfig=$VACIO" ' '' g_aislado_real
  mutante mut-osv-sin-claves-desconocidas '(keys - ["vulns"]) | length == 0' 'true' g_osv
  mutante mut-osv-no-consulta-tsx '  nv="${PKGS[$i]}@${VER[$i]}"' $'  nv="${PKGS[$i]}@${VER[$i]}"\n  [ "${USOS[$i]}" != npx ] || continue' g_osv
  mutante mut-override-sin-motivo '[ "${#m}" -ge 10 ]' 'true' g_override
  mutante mut-prerrelease-aceptada "RE_VER='^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\$'" "RE_VER='^[0-9].*\$'" g_pre
  mutante mut-osv-malware-aceptado 'startswith("MAL-")' 'startswith("NUNCA-")' g_osv
  mutante mut-before-sin-redondeo-resolvedor "'(\$t + 1) | todate'" "'\$t | todate'" g_edad
  mutante mut-before-sin-redondeo-tsx 'ep=$((ep - 259200 + 1))' 'ep=$((ep - 259200))' g_tsx "$TSX" TSXX
  mutante mut-before-override-sin-redondeo-tsx 'then ep=$((ep + 1))' 'then ep=$ep' g_tsx "$TSX" TSXX
  mutante mut-lock-sin-before '  echo "# before=$BEFORE"' '  :' g_edad
  mutante mut-lock-huerfano-suelto 'mkdir -p "$(dirname "$SALIDA")/apartado" && mv --' ':; : --' g_resto
  mutante mut-sin-package-json-previo "printf '%s\\n' '{\"name\":\"herramientas-auditoria\",\"version\":\"0.0.0\",\"private\":true}' > \"\$TRABAJO/package.json\"" ':' g_aislado
  mutante mut-re-con-dolar 'RE_VER_JQ="${RE_VER%\$}\\z"; RE_ISO_JQ="${RE_ISO%\$}\\z"' 'RE_VER_JQ="$RE_VER"; RE_ISO_JQ="$RE_ISO"' g_versiones
  mutante mut-fecha-imposible-aceptada '| map(select((.ep | todate) == (.value | sub("\\.[0-9]+Z$"; "Z"))))' '' g_versiones
  mutante mut-doble-npm-acepta-todo 'if orden is not None and' 'if False and orden is not None and' g_doble_npm "$RAIZ/tests/fixtures/instalacion/infra-real.py" INFRAX
  mut_texto mut-before-sin-redondeo-golden FRAG 'RH_EP=$((RH_EP - 259200 + 1))' 'RH_EP=$((RH_EP - 259200))' g_golden
  mut_texto mut-push-ruta-vieja HOST '"$GOLDEN/var/lib/talent-channels/resolver-herramientas.sh"' '"$GOLDEN/usr/local/lib/talent-channels/resolver-herramientas.sh"' g_host
  mut_texto mut-motivo-host-sin-longitud HOST '[ "${#TC_HERRAMIENTAS_MOTIVO}" -ge 10 ]' 'true' g_host
  local pwa conpw; mkdir -p "$WORK/mut"
  for pwa in install-deps 'install chromium'; do   # cada orden npx de playwright por separado: quitar el --no-install de CUALQUIERA la enrojece
    printf '%s\n' "${GTXT/"npx --no-install playwright $pwa"/"npx playwright $pwa"}" > "$WORK/mut/02-golden-pw.sh"
    GF="$WORK/mut/02-golden-pw.sh"; fallos_de g_golden; conpw=$NF; GF="$G"; fallos_de g_golden
    if [ "$conpw" -gt 0 ] && [ "$NF" -eq 0 ]; then ok "mut-playwright-sin-no-install ($pwa): ROJO con el mutante ($conpw casos) y VERDE al revertir"; else bad "mut-playwright-sin-no-install ($pwa): con mutante $conpw, sin mutante $NF"; fi
  done
  local t_ok="$INST" m_inst='npm install -g @anthropic-ai/claude-code @openai/codex @railway/cli convex supabase'
  mkdir -p "$WORK/mut"; printf '%s\n' "${GTXT/"$t_ok"/"$m_inst"}" > "$WORK/mut/02-golden.sh"
  INST="$m_inst"; GF="$WORK/mut/02-golden.sh"; fallos_de g_golden; local con=$NF
  INST="$t_ok"; GF="$G"; fallos_de g_golden
  if [ "$con" -gt 0 ] && [ "$NF" -eq 0 ]; then ok "mut-instala-sin-lock: ROJO con el mutante ($con casos) y VERDE al revertir"; else bad "mut-instala-sin-lock: con mutante $con, sin mutante $NF"; fi
}

for g in g_edad g_versiones g_pre g_audit g_osv g_aislado g_npmreal g_doble_npm g_red g_override g_resto g_tsx g_golden g_host g_censo g_mutantes; do echo "== ${g#g_} =="; $g; done
echo "================  PASS=$PASS  FAIL=$FAIL  ================"
[ "$FAIL" -eq 0 ]
