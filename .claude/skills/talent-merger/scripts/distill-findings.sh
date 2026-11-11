#!/usr/bin/env bash
# distill-findings.sh — Destila los findings critical|major de CodeRabbit en CANDIDATOS a gotcha.
# Paso 8-bis del Mergeador: analítico, reintentable y NO bloqueante (no es gate de Done).
# NUNCA escribe `gotchas.md` ni ninguna memoria: la promoción de un candidato es decisión humana.
#
# Uso:
#   distill-findings.sh --limit <N> [--pr <n>] [--since <ISO>] [--markdown] [--dry-run]
#     --limit <N>    OBLIGATORIO en todos los modos: tope de VEHÍCULOS distintos (los N de `ts` más
#                    reciente) y de PR fusionados que se piden al App. Sin él, rc 2.
#     --pr <n>       solo el vehículo PR <n>.
#     --since <ISO>  solo ocurrencias con `ts` >= <ISO> (fecha o fecha-hora UTC); sustituye al watermark.
#     --markdown     el stdout es un fragmento markdown por candidato (cabecera `### [fecha] title_stem`).
#     --dry-run      calcula y escribe en stdout; no toca ningún fichero (ni salida, ni watermark, ni pendiente).
#
# Fuentes (la Fuente B nunca usa el flag de fuentes agregadas del lector: solo hilos inline):
#   A (CLI)  .claude/.cr-review-history.jsonl > .claude/.cr-review-findings.jsonl por precedencia (el
#            historial gana); .claude/.cr-review-known-debt.jsonl SOLO marca `waived=true` por `fp`,
#            nunca aporta ocurrencia ni vehículo. Los registros ya vienen normalizados por
#            `cr-finding-normalize.jq`; aquí solo se filtra por severity critical|major (defensivo). La
#            ventana es la que el ledger retiene (CR_REVIEW_HISTORY_RETENTION, 20 runs por rama: la
#            estación puede subirla si 20 pierden recurrencias). Los findings no llevan `fp`: se calcula
#            con la misma fórmula que `fp_of` de cr-review.sh.
#   B (App)  `fetch_cr_comments.sh <owner/repo> <pr>` con EXACTAMENTE dos argumentos, solo hilos inline
#            (`thread_id` no nulo) con severity critical|major, para los PR de
#            `gh pr list --state merged --limit <N>` posteriores al watermark. Límite aceptado del
#            lector: 100 hilos por PR y 20 comentarios por hilo. `occurrence_fp` de un hilo = sha256 de
#            su `thread_id`. El título es la primera línea `**…**` tras el bloque de badges; sin título
#            extraíble el hilo se omite y se cuenta en `omitidos_sin_titulo` (nunca se inventa).
#
# Identidad y conteo:
#   occurrence_fp = el `fp` existente del finding. candidate_key = sha256(clase ∥ title_stem ∥ file_class),
#   con title_stem = título en minúsculas sin backticks, comillas, tokens con barra (rutas) ni dígitos, y
#   file_class = directorio de primer nivel + extensión (`src/lib/x.ts` -> `src/*.ts`). Una ocurrencia como
#   máximo por vehículo; vehículo = nº de PR (para el ledger CLI: `gh pr list --head <rama> --state merged
#   --limit 1`; si no resuelve, la rama SANEADA). count = vehículos distintos. Limitación declarada: dos
#   ramas sin PR que el saneador reduce a la misma cadena cuentan como un vehículo.
#
# Salidas (las tres persisten con mktemp en el MISMO directorio + `mv -T`, GNU coreutils):
#   .claude/.gotcha-candidates.jsonl  un candidato por línea {candidate_key, occurrence_fps[], clase,
#       title_stem, file_class, count, vehicles[], waived, primera_vez, ultima_vez, sugerencia_regla}. El
#       fichero es ACUMULATIVO: cada ejecución se fusiona por candidate_key con lo ya persistido, pero el
#       stdout devuelve solo la ventana pedida (los filtros --since, --pr y --limit se aplican al resultado
#       de ESTA ejecución, no al índice acumulado). Con cero candidatos, la línea
#       {"candidates":0,"vehiculos":N,"omitidos_sin_titulo":M}.
#   .claude/.distill-watermark.json   {"watermark":"<ISO>"}: avanza SOLO tras persistir, y solo en una
#       ejecución completa (sin --pr ni --since). Marca desde dónde se piden los PR al App.
#   .claude/.distill-pending.json     {"motivo":<código>,"vehiculo":…,"ts":…} cuando algo falla. `motivo`
#       es un código enumerado (persist_fallido · entrada_invalida · lectura_fallida), jamás el texto de
#       un error. Una ejecución que persiste con éxito lo retira.
#   Ninguna salida lleva texto crudo: solo hashes, enumerados, números, fechas, `title_stem`,
#   `file_class` y vehículos saneados (correo, teléfono, token, cabecera, financiero, secreto). El cuerpo de
#   un finding NO se persiste nunca. NO CUBIERTO: un nombre de persona dentro de un título (sin forma
#   reconocible que un saneador pueda cazar).
#
# Códigos de salida: 0 ok · 2 uso inválido (incluye falta de --limit) · 3 entrada inválida (JSONL roto o con
# forma inesperada) · 4 persist fallido · 5 lectura externa fallida (gh o el lector del App).
# Entorno (para pruebas): DISTILL_FETCH_CR = ruta del lector del App; DISTILL_REPO = <owner/repo>.
set -uo pipefail
export LC_ALL=C

uso() { printf 'uso: %s --limit <N> [--pr <n>] [--since <ISO>] [--markdown] [--dry-run]\n' "${0##*/}" >&2; exit 2; }

LIMIT=""; PR_ARG=""; SINCE=""; MARKDOWN=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) [ $# -ge 2 ] || uso; LIMIT="$2"; shift 2 ;;
    --pr) [ $# -ge 2 ] || uso; PR_ARG="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || uso; SINCE="$2"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) uso ;;
  esac
done
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || uso
[ -z "$PR_ARG" ] || [[ "$PR_ARG" =~ ^[1-9][0-9]*$ ]] || uso
[ -z "$SINCE" ] || [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+Z)?$ ]] || uso
for dep in jq sha256sum mktemp base64; do
  command -v "$dep" >/dev/null 2>&1 || { printf 'distill-findings: falta %s\n' "$dep" >&2; exit 2; }
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(pwd -P)"
cd "$ROOT" || exit 2
CLAUDE_DIR="$ROOT/.claude"
HISTORY="$CLAUDE_DIR/.cr-review-history.jsonl"
FINDINGS="$CLAUDE_DIR/.cr-review-findings.jsonl"
KNOWN_DEBT="$CLAUDE_DIR/.cr-review-known-debt.jsonl"
OUT="$CLAUDE_DIR/.gotcha-candidates.jsonl"
WATERMARK="$CLAUDE_DIR/.distill-watermark.json"
PENDING="$CLAUDE_DIR/.distill-pending.json"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FETCH="${DISTILL_FETCH_CR:-$SELF_DIR/../../coderabbit-talent/scripts/fetch_cr_comments.sh}"

TMP="$(mktemp -d 2>/dev/null)" || { echo "distill-findings: sin directorio temporal" >&2; exit 2; }
TMPS=()
limpiar() { local f; for f in "${TMPS[@]}"; do rm -f -- "$f"; done; rm -rf -- "$TMP"; }
trap limpiar EXIT
trap 'exit 130' INT TERM

# --- jq compartido: saneador, reducción de título y clasificación ------------------------------------
# Cada regla del saneador va en su propia línea (una por clase de dato).
JQ_DEFS='
def grave: ((. // "") | tostring | ascii_downcase) | test("^(critical|major)$");
def san:
  gsub("[a-z0-9._%+-]+@[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}"; "redactado-correo"; "i")
  | gsub("(authorization|proxy-authorization|x-api-key|set-cookie|cookie)\\s*:\\s*((bearer|basic)\\s+)?[^\\s]+"; "redactado-cabecera"; "i")
  | gsub("(password|passwd|pwd|secret|api[_-]?key|private[_-]?key|token)\\s*[=:]\\s*[^\\s]+"; "redactado-secreto"; "i")
  | gsub("(gh[pousr]_|github_pat_|sbp_|sk-ant-|sk-|lin_api_|phc_|sntrys_|xox[abprs]-)[a-z0-9_-]{8,}|eyj[a-z0-9_-]+\\.[a-z0-9_-]+\\.[a-z0-9_-]+|[a-z0-9]{32,}"; "redactado-token"; "i")
  | gsub("(?<![0-9])[0-9]{13,19}(?![0-9])|(?<![0-9])[0-9]{4}([ -][0-9]{4}){3}(?![0-9])"; "redactado-financiero")
  | gsub("(?<![0-9])\\+?[0-9]{7,12}(?![0-9])"; "redactado-telefono");
def stem:
  ((. // "") | tostring | ascii_downcase)
  | gsub("`"; "")
  | gsub("[\u0027\"\u2018\u2019\u201c\u201d]"; "")
  | gsub("(^|\\s)[^\\s]*/[^\\s]*"; " ")
  | gsub("[0-9]+"; "")
  | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def file_class:
  ((. // "") | tostring | ascii_downcase | gsub("^(\\./|/)+"; "")) as $f
  | if $f == "" then "sin-fichero"
    else ($f | split("/")) as $p
      | (if ($p | length) > 1 then $p[0] + "/" else "" end) as $d
      | (($p[-1] | capture("\\.(?<e>[a-z0-9]{1,8})$").e) // "") as $e
      | $d + "*" + (if $e != "" then "." + $e else "" end)
    end
  | gsub("[^a-z0-9_*./-]"; "-") | san;
def clase:
  ((. // "") | tostring | ascii_downcase | gsub("\\s+"; "-") | gsub("[^a-z0-9_-]"; "") | gsub("-+"; "-") | .[0:32])
  | if . == "" then "other" else . end;
def titulo_app:
  ((.body // "") | tostring | gsub("\r"; "") | split("\n")) as $l
  | ($l | index("")) as $n
  | if $n == null then null
    else ($l[($n + 1):] | map(select(test("^\\s*\\*\\*.+\\*\\*\\s*$"))) | .[0]) as $t
      | if $t == null then null else ($t | sub("^\\s*\\*\\*"; "") | sub("\\*\\*\\s*$"; "")) end
    end;
'

pendiente() { # $1 motivo (código enumerado) · $2 vehículo opcional (se sanea)
  [ "$DRY" = 0 ] || return 0
  local json
  json="$(jq -n -c --arg m "$1" --arg v "${2:-}" --arg ts "$(date -u +%FT%TZ)" "$JQ_DEFS"'{motivo: $m, vehiculo: (if $v == "" then null else ($v | san) end), ts: $ts}')" || return 0
  mkdir -p -- "$CLAUDE_DIR" 2>/dev/null && atomico "$PENDING" "$json" || true
}
atomico() { # $1 destino · $2 contenido: mktemp en el MISMO directorio + mv -T (atómico)
  local tmp
  tmp="$(mktemp "$1.XXXXXX" 2>/dev/null)" || return 1
  TMPS+=("$tmp")
  printf '%s\n' "$2" > "$tmp" || return 1
  mv -T -- "$tmp" "$1" 2>/dev/null || return 1
}
fallar() { # $1 rc · $2 motivo (código enumerado) · $3 vehículo opcional
  printf 'distill-findings: %s\n' "$2" >&2
  pendiente "$2" "${3:-}"
  exit "$1"
}

# --- Lectura estricta: una línea rota es entrada inválida, nunca se salta en silencio ----------------
leer_jsonl() { # $1 fichero -> array JSON; ausente = []
  [ -f "$1" ] || { printf '[]'; return 0; }
  jq -s -c '.' "$1" 2>/dev/null
}
valida() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }
HIST="$(leer_jsonl "$HISTORY")" || fallar 3 entrada_invalida
FIN="$(leer_jsonl "$FINDINGS")" || fallar 3 entrada_invalida
KD="$(leer_jsonl "$KNOWN_DEBT")" || fallar 3 entrada_invalida
OLD="$(leer_jsonl "$OUT")" || fallar 3 entrada_invalida
valida "$HIST" 'all(.[]; type == "object" and ((.branch // "") | type == "string") and ((.findings // []) | type == "array" and all(.[]; type == "object")))' || fallar 3 entrada_invalida
valida "$FIN" 'all(.[]; type == "object")' || fallar 3 entrada_invalida
valida "$KD" 'all(.[]; type == "object")' || fallar 3 entrada_invalida
valida "$OLD" 'all(.[]; type == "object")' || fallar 3 entrada_invalida
WM=""
if [ -f "$WATERMARK" ]; then
  WM="$(jq -r 'if type == "object" and ((.watermark // "") | type == "string") then (.watermark // "") else error("forma") end' "$WATERMARK" 2>/dev/null)" || fallar 3 entrada_invalida
fi

# --- Fuente A: history > findings; known-debt solo aporta el conjunto de fp ----------------------------
fp_de() { # misma huella que fp_of de cr-review.sh
  printf '%s' "$1" | jq -j '[(.file // ""), ((.lineStart // "")|tostring), ((.lineEnd // "")|tostring), (.title // ""), (.category // ""), (.fpMaterial // [])] | tojson' 2>/dev/null | sha256sum | cut -d' ' -f1
}
FIN_E=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  FIN_E+="$(printf '%s' "$l" | jq -c --arg fp "$(fp_de "$l")" '. + {fp: (.fp // $fp)}')"$'\n'
done < <(printf '%s' "$FIN" | jq -c '.[]')
FIN="$(printf '%s' "$FIN_E" | jq -s -c '.')"
CUR_BRANCH="$(git branch --show-current 2>/dev/null)"; [ -n "$CUR_BRANCH" ] || CUR_BRANCH="sin-rama"
MTIME="$(date -u -r "$FINDINGS" +%FT%TZ 2>/dev/null)" || MTIME=""
printf '%s' "$KD" | jq -c '[.[] | .fp // empty | select(type == "string")]' > "$TMP/kd.json"
printf '%s' "$HIST" > "$TMP/hist.json"; printf '%s' "$FIN" > "$TMP/fin.json"
jq -n -c --slurpfile h "$TMP/hist.json" --slurpfile f "$TMP/fin.json" --arg cur "$CUR_BRANCH" --arg mt "$MTIME" "$JQ_DEFS"'
  ($h[0] | map({key: (.run_id // ""), value: .}) | from_entries) as $byrun
  | [ $h[0][] | . as $e | (.findings // [])[] | select(.severity | grave)
      | {src: "history", rank: 1, run_id: ($e.run_id // ""), branch: ($e.branch // ""), ts: ($e.ts // ""), fp: (.fp // ""), category: .category, file: .file, title: .title} ]
    + [ $f[0][] | select(.severity | grave) | (.run_id // "") as $r | ($byrun[$r] // null) as $he
      | {src: "findings", rank: 2, run_id: $r, branch: ($he.branch // $cur), ts: ($he.ts // $mt), fp: (.fp // ""), category: .category, file: .file, title: .title} ]
' > "$TMP/occ-a.json" || fallar 3 entrada_invalida

# Rama -> PR fusionado (una consulta por rama distinta). Sin resolver => la rama saneada es el vehículo.
BRMAP='{}'
while IFS= read -r br; do
  [ -n "$br" ] || continue
  command -v gh >/dev/null 2>&1 || fallar 5 lectura_fallida
  num="$(gh pr list --head "$br" --state merged --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)" || fallar 5 lectura_fallida
  [ -z "$num" ] || BRMAP="$(printf '%s' "$BRMAP" | jq -c --arg b "$br" --arg n "$num" '. + {($b): $n}')"
done < <(jq -r '[.[].branch | select(. != "")] | unique | .[]' "$TMP/occ-a.json")

# --- Fuente B: hilos inline del App con severity critical|major, PR fusionados desde el watermark -------
: > "$TMP/app-raw.ndjson"; OMIT_APP=0
command -v gh >/dev/null 2>&1 || fallar 5 lectura_fallida
REPO="${DISTILL_REPO:-}"
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || fallar 5 lectura_fallida
LIST="$(gh pr list --state merged --limit "$LIMIT" --json number,mergedAt,headRefName 2>/dev/null)" || fallar 5 lectura_fallida
PRS="$(printf '%s' "$LIST" | jq -r --arg s "$SINCE" --arg w "$WM" --arg p "$PR_ARG" '
    .[] | select(($s != "" and .mergedAt >= $s) or ($s == "" and ($w == "" or .mergedAt > $w)))
    | select($p == "" or (.number | tostring) == $p) | "\(.number) \(.mergedAt)"')" || fallar 5 lectura_fallida
while read -r n at; do
  [ -n "$n" ] || continue
  salida="$("$FETCH" "$REPO" "$n" 2>/dev/null)" || fallar 5 lectura_fallida "$n"
  printf '%s' "$salida" | jq -c --arg pr "$n" --arg ts "$at" "$JQ_DEFS"'
      select(type == "object") | select(.thread_id != null) | select(.severity | grave)
      | {pr: $pr, ts: $ts, thread_id: .thread_id, category: .category, file: .path, title: titulo_app}' >> "$TMP/app-raw.ndjson" || fallar 5 lectura_fallida "$n"
done <<< "$PRS"
OMIT_APP="$(jq -s '[.[] | select(.title == null)] | length' "$TMP/app-raw.ndjson")"
jq -c 'select(.title != null)' "$TMP/app-raw.ndjson" > "$TMP/app.ndjson"

# --- Identidad: occurrence_fp del App y candidate_key (hashes por tabla, sin texto crudo) --------------
mapa_hash() { # stdin: cadenas en base64, una por línea -> objeto {base64: sha256}
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    printf '%s\t%s\n' "$b" "$(printf '%s' "$b" | base64 -d | sha256sum | cut -d' ' -f1)"
  done | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}'
}
jq -r '.thread_id | @base64' "$TMP/app.ndjson" | sort -u | mapa_hash > "$TMP/tid-fp.json"
jq -n -c --slurpfile a "$TMP/occ-a.json" --slurpfile b "$TMP/app.ndjson" --slurpfile tf "$TMP/tid-fp.json" --argjson bm "$BRMAP" "$JQ_DEFS"'
  ( [ $a[0][] | . + {pr: ($bm[.branch] // null)} ]
    + [ $b[] | {src: "app", rank: 3, run_id: "", branch: null, pr: .pr, ts: .ts, fp: $tf[0][(.thread_id | @base64)], category: .category, file: .file, title: .title} ] ) as $raw
  | [ $raw[] | select((.fp // "") != "")
      | (.title | stem | san) as $s | (.category | clase) as $c | (.file | file_class) as $fc
      | select($s != "")
      | {src, rank, run_id, ts, fp, title, clase: $c, stem: $s, fclass: $fc,
         vehicle: (if .pr != null then .pr elif (.branch // "") == "" then "sin-rama" else (.branch | san) end),
         kk: ($c + "\u001f" + $s + "\u001f" + $fc)} ] as $occ
  | {occ: $occ, omitidos: ((($raw | map(select((.fp // "") != "")) | length) - ($occ | length)))}
' > "$TMP/occ.json" || fallar 3 entrada_invalida
jq -r '.occ | map(.kk | @base64) | unique | .[]' "$TMP/occ.json" | mapa_hash > "$TMP/keymap.json"

# --- Agregación: ventana (--since, --pr, --limit), una ocurrencia por vehículo, fusión con lo persistido --
printf '%s' "$OLD" | jq -c '[.[] | select(has("candidate_key"))]' > "$TMP/old.json"
jq -n -c --slurpfile o "$TMP/occ.json" --slurpfile km "$TMP/keymap.json" --slurpfile old "$TMP/old.json" --slurpfile kd "$TMP/kd.json" \
  --arg since "$SINCE" --arg pr "$PR_ARG" --argjson limit "$LIMIT" --argjson omit_app "$OMIT_APP" "$JQ_DEFS"'
  ($kd[0]) as $kd
  | [ $o[0].occ[] | . + {candidate_key: $km[0][(.kk | @base64)]} ]
  | map(select($since == "" or .ts >= $since))
  | (if $pr == "" then . else map(select(.vehicle == $pr)) end)
  | ( group_by(.vehicle) | map({v: .[0].vehicle, t: (map(.ts) | max)}) | sort_by([.t, .v]) | reverse | .[0:$limit] | map(.v) ) as $sel
  | map(. as $x | select(any($sel[]; . == $x.vehicle))) as $all
  | ( $all | group_by(.candidate_key) | map(
        . as $g
        | ( $g | group_by(.vehicle) | map( (map(.rank) | min) as $r | map(select(.rank == $r)) | max_by([.ts, .fp]) ) ) as $best
        | ( [$best[].vehicle] | unique ) as $veh
        | { candidate_key: $g[0].candidate_key,
            occurrence_fps: ([$best[].fp] | unique),
            clase: $g[0].clase, title_stem: $g[0].stem, file_class: $g[0].fclass,
            count: ($veh | length), vehicles: $veh,
            waived: any($best[].fp; . as $f | any($kd[]; . == $f)),
            primera_vez: ($g | map(.ts) | min), ultima_vez: ($g | map(.ts) | max) } ) ) as $new
  | def fin:
      map(. + {count: (.vehicles | length), waived: (.waived or any(.occurrence_fps[]; . as $f | any($kd[]; . == $f)))})
      | map(. + {sugerencia_regla: ("Recurrencia de " + .clase + " en " + .file_class + " (" + (.count | tostring) + " vehículos): " + .title_stem)})
      | map({candidate_key, occurrence_fps, clase, title_stem, file_class, count, vehicles, waived, primera_vez, ultima_vez, sugerencia_regla})
      | sort_by([-.count, .candidate_key]);
    ( ($old[0] + $new) | group_by(.candidate_key)
      | map( if length == 1 then .[0] else
             { candidate_key: .[0].candidate_key,
               occurrence_fps: (map(.occurrence_fps[]) | unique),
               clase: .[0].clase, title_stem: .[0].title_stem, file_class: .[0].file_class,
               vehicles: (map(.vehicles[]) | unique),
               waived: any(.[]; .waived),
               primera_vez: (map(.primera_vez) | min), ultima_vez: (map(.ultima_vez) | max) } end )
      | fin ) as $cands
  | ( $new | fin ) as $vista
  | { cands: $cands, vista: $vista, vehiculos: ($sel | length), omitidos: ($omit_app + $o[0].omitidos),
      ultimo: ($sel[0] // ""), maxts: ($all | map(.ts) | max // "") }
' > "$TMP/res.json" || fallar 3 entrada_invalida

# CONTENT = índice acumulado que se persiste; SALIDA = la ventana pedida (--since, --pr, --limit sobre
# lo recién calculado), que es lo que se devuelve por stdout: el filtro del usuario nunca se ensancha
# con lo que el índice ya tenía de ejecuciones anteriores.
CERO="$(jq -c '{candidates: 0, vehiculos: .vehiculos, omitidos_sin_titulo: .omitidos}' "$TMP/res.json")"
CONTENT="$(jq -c '.cands[]' "$TMP/res.json")"; [ -n "$CONTENT" ] || CONTENT="$CERO"
SALIDA="$(jq -c '.vista[]' "$TMP/res.json")"; [ -n "$SALIDA" ] || SALIDA="$CERO"
NC="$(jq '.vista | length' "$TMP/res.json")"
OMIT="$(jq '.omitidos' "$TMP/res.json")"
[ "$OMIT" = 0 ] || [ "$NC" = 0 ] || printf 'distill-findings: omitidos_sin_titulo=%s\n' "$OMIT" >&2
VEH_ULT="$(jq -r '.ultimo' "$TMP/res.json")"
MAXTS="$(jq -r '.maxts' "$TMP/res.json")"
FULL=0; [ -n "$PR_ARG$SINCE" ] || FULL=1

# --- Persistencia: candidatos primero, watermark solo después de persistir ---------------------------
if [ "$DRY" = 0 ]; then
  mkdir -p -- "$CLAUDE_DIR" 2>/dev/null || fallar 4 persist_fallido "$VEH_ULT"
  atomico "$OUT" "$CONTENT" || fallar 4 persist_fallido "$VEH_ULT"
  if [ "$FULL" = 1 ] && [ -n "$MAXTS" ] && [[ "$MAXTS" > "$WM" ]]; then
    atomico "$WATERMARK" "$(jq -n -c --arg w "$MAXTS" '{watermark: $w}')" || fallar 4 persist_fallido "$VEH_ULT"
  fi
  rm -f -- "$PENDING"
fi

# --- Salida ------------------------------------------------------------------------------------------
envolver() { # bullets largos: fold a 76 columnas con continuación sangrada
  local line
  while IFS= read -r line; do
    if [ "${#line}" -gt 78 ] && [ "${line:0:2}" = "- " ]; then
      printf '%s\n' "$line" | fold -s -w 76 | sed -e 's/[[:space:]]*$//' -e '2,$s/^/  /'
    else
      printf '%s\n' "$line"
    fi
  done
}
if [ "$MARKDOWN" = 1 ] && [ "$NC" != 0 ]; then
  jq -r '[.vista[] | "### [" + .ultima_vez[0:10] + "] " + .title_stem + "\n\n"
    + "- **Categoria:** otro\n"
    + "- **Que salio mal:** Hallazgo recurrente de clase " + .clase + " en " + .file_class + ".\n"
    + "- **Causa raiz:** Pendiente de revision humana.\n"
    + "- **Prevencion:** " + .sugerencia_regla + "\n"
    + "- **Ocurrencias:** " + (.count | tostring) + " (" + (.vehicles | join(", ")) + ")\n"
    + "- **Promovido:** no"] | join("\n\n")' "$TMP/res.json" | envolver
else
  printf '%s\n' "$SALIDA"
fi
exit 0
