#!/usr/bin/env bash
# lib-test.sh — Interfaz de pruebas compartida de talent-merger (se hace `source`; no ejecuta nada).
#
# Interfaz FIJA (la consumen las demás pruebas del skill; no se altera sin avisar al dueño del arnés):
#   t_ok<descripción> <esperado> <obtenido>   aserción de igualdad exacta
#   t_rc <comando…>                            ejecuta en silencio, imprime el rc y lo devuelve
#   t_repo_sintetico <dir>                     git con rama main, un commit y `origin` local (<dir>.origin.git)
#   t_gh_doble <dir-bin> <dir-fixtures>        `gh api <ruta>` sirve <dir-fixtures>/<ruta con / → __>.json; con
#                                              --paginate sirve ….p1.json, ….p2.json… aplicando --jq por página;
#                                              los `-X POST … statuses/<sha>` se registran y (salvo
#                                              GH_ESTADO_STATUS=ignorar) cambian la respuesta posterior de
#                                              commits/<sha>/status; todas las llamadas van a $GH_LOG; cerrado
#                                              con cerrar_doble_gh
#   t_sellador_doble <fichero>                 sellador de prueba: un renglón por llamada en <fichero>.log y copia
#                                              del --src en <fichero>.src.<n>
#   t_fin                                      imprime `RESULTADO: PASS=N FAIL=M` y devuelve 0 solo si M es 0
# Auxiliares: t_contiene · t_no_contiene · t_tmp · t_limpiar · t_commit · t_rama · t_buscar_arriba · t_motor ·
#   t_sustituir · t_montar_copia · t_mutante.

T_PASS=0; T_FAIL=0; T_W=''
T_AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T_SCRIPTS_REAL="$T_AQUI/../scripts"

t_ok() {
  if [ "$2" = "$3" ]; then T_PASS=$((T_PASS + 1)); else
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s: esperaba [%s] obtuvo [%s]\n' "$1" "$2" "$3"
  fi
}
t_contiene() {
  case "$2" in *"$3"*) T_PASS=$((T_PASS + 1)) ;; *) T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s: no contiene [%s] en [%s]\n' "$1" "$3" "$2" ;; esac
}
t_no_contiene() {
  case "$2" in *"$3"*) T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s: contiene [%s] en [%s]\n' "$1" "$3" "$2" ;; *) T_PASS=$((T_PASS + 1)) ;; esac
}
# t_linea <descripción> <línea exacta> — contra la variable OUT (salida capturada de la última ejecución).
t_linea() {
  if printf '%s\n' "${OUT-}" | grep -qxF -- "$2"; then T_PASS=$((T_PASS + 1)); else
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s: falta la línea [%s] en:\n%s\n' "$1" "$2" "${OUT-}"
  fi
}
t_rc() { local rc; "$@" >/dev/null 2>&1; rc=$?; printf '%s\n' "$rc"; return "$rc"; }
t_fin() {
  printf 'RESULTADO: PASS=%s FAIL=%s\n' "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

t_tmp() { T_W="$(mktemp -d "${TMPDIR:-/tmp}/tf-test.XXXXXX")" || return 1; }
t_limpiar() {
  [ -n "${T_W-}" ] || return 0
  case "$T_W" in "${TMPDIR:-/tmp}"/tf-test.*) rm -rf -- "$T_W" ;; esac
  T_W=''
}

# t_buscar_arriba <ruta-relativa> — primera ruta existente subiendo desde este directorio.
t_buscar_arriba() {
  local d="$T_AQUI"
  while :; do
    if [ -e "$d/$1" ]; then printf '%s\n' "$d/$1"; return 0; fi
    [ "$d" != / ] || return 1
    d="$(dirname "$d")"
  done
}
t_motor() {
  local p
  p="$(t_buscar_arriba scripts/lib/insumos-por-gate.sh)" || return 1
  printf '%s\n' "${p%/scripts/lib/insumos-por-gate.sh}"
}

_GH_DOBLES="$(t_buscar_arriba tests/fixtures/instalacion/gh-dobles.sh)" || _GH_DOBLES=''
# shellcheck source=/dev/null
[ -z "$_GH_DOBLES" ] || . "$_GH_DOBLES"

# Identidad de git para fixtures: la arroba se compone para no dejar un correo literal en el fichero.
T_ARROBA='@'
T_GIT_ID="prueba${T_ARROBA}ejemplo.invalid"

t_repo_sintetico() {
  local d="$1"
  git init -q --bare -b main "$d.origin.git" || return 1
  git init -q -b main "$d" || return 1
  git -C "$d" config user.name Prueba && git -C "$d" config user.email "$T_GIT_ID" && git -C "$d" config commit.gpgsign false || return 1
  printf 'base\n' > "$d/README"
  git -C "$d" add README && git -C "$d" commit -q -m base || return 1
  git -C "$d" remote add origin "$d.origin.git" && git -C "$d" push -q origin main 2>/dev/null
}

# t_commit <repo> <fichero> <contenido> <mensaje> — commit en la rama actual; imprime el sha.
t_commit() {
  mkdir -p "$(dirname "$1/$2")" && printf '%s\n' "$3" > "$1/$2" || return 1
  git -C "$1" add -- "$2" && git -C "$1" commit -q -m "$4" || return 1
  git -C "$1" rev-parse HEAD
}

# t_rama <repo> <rama> <fichero> <contenido> [base] — rama nueva desde base (main), un commit, push a origin; imprime el sha.
t_rama() {
  local sha
  git -C "$1" checkout -q -b "$2" "${5:-main}" || return 1
  sha="$(t_commit "$1" "$3" "$4" "rama $2")" || return 1
  git -C "$1" push -q origin "$2" 2>/dev/null || return 1
  git -C "$1" checkout -q main || return 1
  printf '%s\n' "$sha"
}

t_gh_doble() {
  local bin="$1" fix="$2"
  mkdir -p "$bin" "$fix" || return 1
  GH_FIXTURES="$fix"; GH_LOG="${GH_LOG:-$bin/gh.log}"; export GH_FIXTURES GH_LOG
  cat > "$bin/gh" <<'__FIN_GH_DOBLE__'
#!/usr/bin/env bash
# Doble de `gh api`: sirve ficheros de GH_FIXTURES y registra todo en GH_LOG.
set -u
FIX="${GH_FIXTURES:?}"; LOG="${GH_LOG:?}"
printf 'gh %s\n' "$*" >> "$LOG"
[ "${1-}" = api ] || { echo "doble gh: subcomando no soportado: ${1-}" >&2; exit 1; }
shift
pag=0; jq_e=''; metodo=GET; ruta=''; campos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) pag=1; shift ;;
    --jq | -q) jq_e="$2"; shift 2 ;;
    -X | --method) metodo="$2"; shift 2 ;;
    -f | -F | --field | --raw-field) campos+=("$2"); shift 2 ;;
    -H | --header | --hostname) shift 2 ;;
    -*) shift ;;
    *) ruta="$1"; shift ;;
  esac
done
base="$FIX/${ruta//\//__}"
emite() { if [ -n "$jq_e" ]; then jq -r "$jq_e" "$1"; else cat "$1"; fi; }
if [ "$metodo" = POST ]; then
  if [[ "$ruta" =~ /statuses/([0-9a-f]{40})$ ]] && [ "${GH_ESTADO_STATUS:-}" != ignorar ]; then
    sha="${BASH_REMATCH[1]}"; st=''; ctx=''
    for kv in "${campos[@]}"; do
      case "$kv" in state=*) st="${kv#state=}" ;; context=*) ctx="${kv#context=}" ;; esac
    done
    if [ -n "$st" ] && [ -n "$ctx" ]; then mkdir -p "$FIX/.estado"; printf '%s' "$st" > "$FIX/.estado/$sha.$ctx"; fi
  fi
  echo '{}'; exit 0
fi
if [ "$pag" = 1 ] && [ -f "$base.p1.json" ]; then
  i=1
  while [ -f "$base.p$i.json" ]; do emite "$base.p$i.json" || exit 1; i=$((i + 1)); done
  exit 0
fi
f="$base.json"
if [[ "$ruta" =~ /commits/([0-9a-f]{40})/status$ ]] && [ "${GH_ESTADO_STATUS:-}" != ignorar ]; then
  sha="${BASH_REMATCH[1]}"
  if compgen -G "$FIX/.estado/$sha.*" >/dev/null; then
    tmp="$(mktemp)"
    if [ -f "$f" ]; then cp "$f" "$tmp"; else echo '{"statuses":[]}' > "$tmp"; fi
    for e in "$FIX/.estado/$sha".*; do
      ctx="${e##*/}"; ctx="${ctx#"$sha".}"
      jq --arg c "$ctx" --arg s "$(cat "$e")" '.statuses = ([.statuses[]? | select(.context != $c)] + [{context: $c, state: $s}])' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
    done
    f="$tmp"
  fi
fi
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
emite "$f"; rc=$?
exit "$rc"
__FIN_GH_DOBLE__
  chmod +x "$bin/gh" || return 1
  cerrar_doble_gh "$bin/gh"
}

t_sellador_doble() {
  local s="$1"
  : > "$s.log"
  cat > "$s" <<'__FIN_SELLADOR_DOBLE__'
#!/usr/bin/env bash
set -u
yo="$0"
printf '%s\n' "$*" >> "$yo.log"
n="$(grep -c . "$yo.log")"
prev=''
for a in "$@"; do
  if [ "$prev" = --src ]; then cp -- "$a" "$yo.src.$n" 2>/dev/null; fi
  prev="$a"
done
exit "${SELLADOR_DOBLE_RC:-0}"
__FIN_SELLADOR_DOBLE__
  chmod +x "$s"
}

# t_sustituir <fichero> <viejo> <nuevo> — UNA sola ocurrencia exacta; rc 1 si hay cero o más de una.
t_sustituir() {
  local c r
  c="$(cat -- "$1"; printf x)" || return 1
  c="${c%x}"
  case "$c" in *"$2"*) ;; *) return 1 ;; esac
  r="${c#*"$2"}"
  case "$r" in *"$2"*) return 1 ;; esac
  printf '%s' "${c/"$2"/"$3"}" > "$1"
}

# t_montar_copia <dest> — replica scripts/ del skill en <dest>/skills/talent-merger/scripts y enlaza el motor
# (scripts/) y talent-ceo, para que la búsqueda hacia arriba funcione igual que en el árbol real.
t_montar_copia() {
  local dest="$1" motor
  motor="$(t_motor)" || return 1
  mkdir -p "$dest/skills/talent-merger" && cp -R "$T_SCRIPTS_REAL" "$dest/skills/talent-merger/scripts" &&
    ln -s "$motor/scripts" "$dest/scripts" && ln -s "$motor/skills/talent-ceo" "$dest/skills/talent-ceo"
}

# t_mutante <id> <fichero-en-scripts> <viejo> <nuevo> <prueba.sh> — siembra el mutante en una COPIA, exige que la
# prueba dé ROJO (con al menos un FAIL) y que el original dé VERDE. Imprime `mutante <id> detectado …` si es así.
# Requiere T_W (t_tmp). La prueba lee TF_SCRIPTS_DIR para apuntar a la copia.
t_mutante() {
  local id="$1" rel="$2" viejo="$3" nuevo="$4" prueba="$5" m base out rc fallos
  m="$T_W/mut-$id"; base="$T_W/mut-base-$id"
  if ! t_montar_copia "$base"; then T_FAIL=$((T_FAIL + 1)); printf '  FAIL mutante %s: no pude montar la copia base\n' "$id"; return; fi
  out="$(TF_SCRIPTS_DIR="$base/skills/talent-merger/scripts" bash "$prueba" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then T_FAIL=$((T_FAIL + 1)); printf '  FAIL mutante %s: el original no está en verde en la copia (rc=%s)\n' "$id" "$rc"; return; fi
  if ! cmp -s "$T_SCRIPTS_REAL/$rel" "$base/skills/talent-merger/scripts/$rel"; then
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL mutante %s: la copia base difiere del original\n' "$id"; return
  fi
  if ! t_montar_copia "$m" || ! t_sustituir "$m/skills/talent-merger/scripts/$rel" "$viejo" "$nuevo"; then
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL mutante %s: no pude sembrar la mutación (texto ausente o repetido)\n' "$id"; return
  fi
  out="$(TF_SCRIPTS_DIR="$m/skills/talent-merger/scripts" bash "$prueba" 2>&1)"; rc=$?
  fallos="${out##*RESULTADO: PASS=}"; fallos="${fallos#* FAIL=}"; fallos="${fallos%%[!0-9]*}"
  if [ "$rc" -ne 0 ] && [ -n "$fallos" ] && [ "$fallos" -gt 0 ]; then
    T_PASS=$((T_PASS + 1)); printf 'mutante %s detectado (rojo: %s aserciones; original verde)\n' "$id" "$fallos"
  else
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL mutante %s: sin detectar (rc=%s)\n' "$id" "$rc"
  fi
}
