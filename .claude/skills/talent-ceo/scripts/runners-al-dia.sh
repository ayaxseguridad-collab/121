#!/usr/bin/env bash
# runners-al-dia.sh — Pone `origin/main` de cada runner al día con un bundle y comprueba que quedó en
# el sha esperado (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. No tiene credenciales ni red hacia el repositorio: el bundle y
# el sha esperado los aporta quien lo ejecuta (con `git bundle create` y `git ls-remote` en su máquina).
#
# Uso:
#   runners-al-dia.sh --bundle <fichero> --ref <ref-en-el-bundle> --esperado <sha> [--runner <ID>]... [--dry-run]
#   runners-al-dia.sh --help
#
# rc: 0 = TODOS los runners ejecutables quedaron en el sha esperado
#     1 = alguno no (DIFIERE, SIN-REPO, FETCH-FALLO, PUSH-FALLO o SSH-FALLO): el gate NO se lanza
#     2 = PRECONDICIÓN: argumento mal formado, bundle que no pasa las guardas, sha que no coincide,
#         perfil ausente o inválido, id o contenedor fuera de charset, ningún runner ejecutable.
#         Con rc 2 NO se ha tocado ningún runner.
#
# Salida: una línea por runner y, al final, el resumen que cita el sello del gate:
#   RUNNER <id> OK <sha9> | DIFIERE <sha9> | SIN-REPO <motivo> | FETCH-FALLO <causa>
#                         | PUSH-FALLO <causa> | SSH-FALLO <causa> | OMITIDO <motivo>
#   RUNNERS-AL-DIA ok=<n>/<m> origin/main=<sha8> <HH:MM:SSZ>
# `m` cuenta los runners ejecutables (los OMITIDO no entran); `ok=m/m` es lo único que autoriza el gate.
#
# ── LEY: ANTES DE CUALQUIER PRUEBA, `origin/main` DEL RUNNER = `main` REAL ─────────────────────────
# Un gate que lee `origin/main` de un runner atrasado da rojos que `main` puro no da. Se pone con un
# bundle sin credenciales y se COMPRUEBA: el script que sale con éxito mientras un runner queda en
# otro commit solo traslada el fallo al gate. Aquí el rc es el AND de todos los runners.
#
# ── ANTES DE TOCAR NADA ────────────────────────────────────────────────────────────────────────
# El bundle es un fichero regular (no symlink), `git bundle verify` lo acepta, `--ref` figura en
# `git bundle list-heads` y su sha empieza por `--esperado` (7..40 hex). Si algo falla: rc 2 y ningún
# runner se toca. `verify` se corre en el repo del directorio actual; sin repo, en uno vacío
# desechable (sirve para bundles completos; uno incremental exige ejecutar desde un clon con su base).
#
# ── QUÉ RUNNERS, Y CÓMO SE LLEGA ───────────────────────────────────────────────────────────────
# Las filas `runner` del perfil (o las pedidas con `--runner`). El repo y el usuario salen de los
# atributos `repo=` y `usuario_contenedor=` de la fila, tal como los escribe el instalador: si falta
# alguno la fila sale `SIN-REPO` (NO se aplica ningún valor por defecto: se actualizaría un repo
# equivocado). Una fila sin contenedor sale `OMITIDO`. `contenedor` es un identificador OPACO.
#   maquina distinta de la que declara acceso=local -> `ssh -- <maquina>`; la local -> directo;
#   luego `incus exec <contenedor> -- …` como root del contenedor y `su - <usuario_contenedor>`.
# Se ejecuta UNA orden por runner. Su guion es una constante de este fichero: los valores del perfil
# (usuario, repo) y el ref viajan como ARGUMENTOS y por stdin, jamás dentro del código. Nada se compone
# con el intérprete de cadenas del shell; las capas que exigen una cadena (el comando remoto de ssh)
# se serializan con `_citar_posix`, igual que en relay-ceo.sh.
# En el runner: el bundle entra por stdin a un `mktemp` del propio contenedor (nombre impredecible) y
# se borra SIEMPRE (trap), también ante fallo. Solo se cambia `refs/remotes/origin/main` del repo
# declarado: ni árbol de trabajo, ni índice, ni otras refs, ni procesos.
#
# Ejecución secuencial, máquina a máquina. Este script no lanza el gate ni se reintenta solo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"

# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }
_precond() { printf 'runners-al-dia: PRECOND: %s\n' "$1" >&2; exit 2; }

bundle=''; ref=''; esperado=''; dry=0; pedidos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)   _exige_valor $# "$1"; bundle="${2-}";   shift 2 ;;
    --ref)      _exige_valor $# "$1"; ref="${2-}";      shift 2 ;;
    --esperado) _exige_valor $# "$1"; esperado="${2-}"; shift 2 ;;
    --runner)   _exige_valor $# "$1"; pedidos+=("${2-}"); shift 2 ;;
    --dry-run)  dry=1; shift ;;
    --help)     sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "runners-al-dia: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$bundle" ]   || _precond "falta --bundle"
[ -n "$ref" ]      || _precond "falta --ref"
[ -n "$esperado" ] || _precond "falta --esperado"
case "$esperado" in *[!0-9a-fA-F]*) _precond "--esperado debe ser hexadecimal: $esperado" ;; esac
[ "${#esperado}" -ge 7 ] && [ "${#esperado}" -le 40 ] || _precond "--esperado debe tener entre 7 y 40 caracteres"
esperado="${esperado,,}"
case "$ref" in -*) _precond "--ref no puede empezar por guion: $ref" ;; esac
[[ "$ref" != *[[:cntrl:]]* ]] || _precond "--ref lleva caracteres de control"
_pi=0
while [ "$_pi" -lt "${#pedidos[@]}" ]; do
  [ -n "${pedidos[$_pi]}" ] || _precond "--runner exige un id no vacío"
  _pi=$((_pi + 1))
done

# Estación: un directorio desechable (repo vacío para `verify` y la salida de error del runner).
work="$(mktemp -d "${TMPDIR:-/tmp}/runners-al-dia.XXXXXX")" || _precond "no se pudo crear el directorio temporal"
_limpia() {
  : "${work:?}"
  case "$work" in "${TMPDIR:-/tmp}"/runners-al-dia.*) rm -rf -- "$work" ;; esac
}
trap _limpia EXIT

# ── 1. EL BUNDLE, ANTES DE TOCAR NADA ──────────────────────────────────────────────────────────
[ ! -L "$bundle" ] || _precond "el bundle es un symlink: $bundle"
[ -f "$bundle" ] && [ -r "$bundle" ] || _precond "bundle ausente, ilegible o no regular: $bundle"
case "$bundle" in /*) : ;; *) bundle="$PWD/$bundle" ;; esac
if git rev-parse --git-dir >/dev/null 2>&1; then
  vgit=(git)
else
  git init -q -- "$work/vrepo" >/dev/null 2>&1 || _precond "no se pudo crear el repo de verificación"
  vgit=(git -C "$work/vrepo")
fi
"${vgit[@]}" bundle verify "$bundle" >"$work/verify.out" 2>&1 \
  || _precond "git bundle verify rechaza el bundle: $(head -n 1 "$work/verify.out" | tr -c '[:print:]' ' ')"
heads="$("${vgit[@]}" bundle list-heads "$bundle" 2>"$work/heads.err")" \
  || _precond "git bundle list-heads falla: $(head -n 1 "$work/heads.err" | tr -c '[:print:]' ' ')"
fullref=''; bsha=''
for cand in "$ref" "refs/heads/$ref"; do
  while read -r _s _n _resto; do
    [ -n "${_n-}" ] || continue
    if [ "$_n" = "$cand" ]; then fullref="$_n"; bsha="$_s"; break; fi
  done <<< "$heads"
  [ -z "$fullref" ] || break
done
[ -n "$fullref" ] || _precond "--ref $ref no figura en el bundle"
[[ "$bsha" =~ ^[0-9a-f]{40,64}$ ]] || _precond "sha ilegible para $fullref en el bundle: $bsha"
case "$bsha" in
  "$esperado"*) : ;;
  *) _precond "--esperado $esperado no coincide con el sha $bsha de $fullref en el bundle" ;;
esac

# ── 2. EL PERFIL: QUÉ RUNNERS, EN QUÉ MÁQUINA, EN QUÉ REPO ─────────────────────────────────────
filas_runner="$(perfil_rows runner 2>"$work/perfil.err")"; rcp=$?
case "$rcp" in
  0) : ;;
  1) _precond "el perfil no declara ninguna fila runner" ;;
  *) _precond "sin perfil válido $(head -n 1 "$work/perfil.err" 2>/dev/null | tr -c '[:print:]' ' ')" ;;
esac
mapfile -t filas <<< "$filas_runner"

# La máquina LOCAL la dice el perfil (acceso=local), no el nombre de este equipo. Sin ella no se puede
# decidir si un runner es local o remoto: fail-closed.
local_id=''
while IFS= read -r _fila; do
  [ -n "$_fila" ] || continue
  perfil_campos "$_fila"
  if [ "$(perfil_attr "${PERFIL_CAMPOS[5]-}" acceso || true)" = local ]; then local_id="${PERFIL_CAMPOS[1]-}"; break; fi
done <<< "$(perfil_rows maquina 2>/dev/null || true)"
[ -n "$local_id" ] || _precond "ninguna fila 'maquina' declara acceso=local; no se puede decidir qué runner es local o remoto"

# Selección (orden del perfil) y validación de TODAS las filas elegidas antes de llamar a nadie.
s_id=(); s_maq=(); s_cont=(); s_usr=(); s_repo=()
for _fila in "${filas[@]}"; do
  perfil_campos "$_fila"
  _id="${PERFIL_CAMPOS[1]-}"
  if [ "${#pedidos[@]}" -gt 0 ]; then
    _quiero=0; _pi=0
    while [ "$_pi" -lt "${#pedidos[@]}" ]; do
      [ "${pedidos[$_pi]}" = "$_id" ] && _quiero=1
      _pi=$((_pi + 1))
    done
    [ "$_quiero" -eq 1 ] || continue
  fi
  s_id+=("$_id"); s_maq+=("${PERFIL_CAMPOS[2]-}"); s_cont+=("${PERFIL_CAMPOS[3]-}")
  _atrs="${PERFIL_CAMPOS[5]-}"
  s_usr+=("$(perfil_attr "$_atrs" usuario_contenedor || true)")
  s_repo+=("$(perfil_attr "$_atrs" repo || true)")
done
_pi=0
while [ "$_pi" -lt "${#pedidos[@]}" ]; do
  _hay=0; _k=0
  while [ "$_k" -lt "${#s_id[@]}" ]; do
    [ "${s_id[$_k]}" = "${pedidos[$_pi]}" ] && _hay=1
    _k=$((_k + 1))
  done
  [ "$_hay" -eq 1 ] || _precond "--runner ${pedidos[$_pi]} no existe en el perfil"
  _pi=$((_pi + 1))
done
ejecutables=0; _k=0
while [ "$_k" -lt "${#s_id[@]}" ]; do
  [[ "${s_id[$_k]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || _precond "id de runner fuera de charset: ${s_id[$_k]}"
  _c="${s_cont[$_k]}"
  if [ -n "$_c" ] && [ "$_c" != '-' ]; then
    [[ "$_c" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || _precond "contenedor de ${s_id[$_k]} fuera de charset: $_c"
    [ -n "${s_maq[$_k]}" ] && [ "${s_maq[$_k]}" != '-' ] || _precond "el runner ${s_id[$_k]} no declara en qué máquina vive"
    _u="${s_usr[$_k]}"
    if [ -n "$_u" ] && [ "$_u" != '-' ]; then
      [[ "$_u" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || _precond "usuario_contenedor de ${s_id[$_k]} fuera de charset: $_u"
    fi
    ejecutables=$((ejecutables + 1))
  fi
  _k=$((_k + 1))
done
[ "$ejecutables" -gt 0 ] || _precond "ningún runner ejecutable (todas las filas elegidas carecen de contenedor)"

# ── 3. SE SERIALIZA PARA UN SHELL POSIX (mismo serializador que relay-ceo.sh) ──────────────────
# Se citan TODAS las palabras, también las inofensivas: `--dry-run` imprime el comando EXACTO.
_citar_posix() {
  local s q="'\\''" out=''
  for s in "$@"; do out="$out'${s//\'/$q}' "; done
  printf '%s' "$out"
}

# Guion que corre en el contenedor, como root: $1 usuario, $2 repo, $3 ref; el bundle llega por stdin.
# Es una constante: ningún valor del perfil forma parte del código. Los tres valores viajan por stdin
# a la sesión del usuario y allí se leen como DATOS. Estados de salida: 11 = sin mktemp, 12 = el bundle
# no se pudo escribir, 3 = repo= no es un repositorio, 4 = fetch fallido, 5 = update-ref fallido,
# 6 = refs/remotes/origin/main es una ref SIMBOLICA: se rechaza ANTES de tocar nada (seguirla cambiaria
# otra ref, la rama local y HEAD). Ademas la actualizacion usa --no-deref: solo la ref nombrada.
IFS= read -r -d '' guion <<'__FIN_RAD_GUION__' || true
tmp=$(mktemp "${TMPDIR:-/tmp}/runners-al-dia.XXXXXX") || exit 11
trap 'rm -f -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$tmp" || exit 12
chmod 644 "$tmp" || exit 12
printf '%s\n%s\n%s\n' "$2" "$tmp" "$3" | su - "$1" -c 'IFS= read -r repo; IFS= read -r bnd; IFS= read -r ref; cd -- "$repo" 2>/dev/null && { [ -d .git ] || [ -f .git ]; } || exit 3; if git symbolic-ref -q refs/remotes/origin/main >/dev/null 2>&1; then exit 6; fi; git fetch -q --no-tags --no-recurse-submodules -- "$bnd" "$ref" || exit 4; git update-ref --no-deref refs/remotes/origin/main FETCH_HEAD || exit 5; git rev-parse refs/remotes/origin/main'
exit $?
__FIN_RAD_GUION__

_limpio() { printf '%s' "${1-}" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-160; }
tot=0; okn=0
_linea() { printf 'RUNNER %s %s' "$1" "$2"; [ -z "${3-}" ] || printf ' %s' "$3"; printf '\n'; }
_falla() { tot=$((tot + 1)); _linea "$1" "$2" "${3-}"; }

# ── 4. UN RUNNER ───────────────────────────────────────────────────────────────────────────────
_runner() {
  local id="$1" maq="$2" cont="$3" usr="$4" repo="$5" argv out rc last sha9 causa
  if [ -z "$cont" ] || [ "$cont" = '-' ]; then _linea "$id" OMITIDO "sin contenedor"; return; fi
  if [ -z "$usr" ] || [ "$usr" = '-' ]; then
    if [ "$dry" -eq 1 ]; then printf '# RUNNER %s SIN-REPO sin usuario_contenedor= en el perfil\n' "$id"; else _falla "$id" SIN-REPO "sin usuario_contenedor= en el perfil"; fi
    return
  fi
  if [ -z "$repo" ] || [ "$repo" = '-' ]; then
    if [ "$dry" -eq 1 ]; then printf '# RUNNER %s SIN-REPO sin repo= en el perfil\n' "$id"; else _falla "$id" SIN-REPO "sin repo= en el perfil"; fi
    return
  fi
  case "$repo" in /*) : ;; *)
    if [ "$dry" -eq 1 ]; then printf '# RUNNER %s SIN-REPO repo= no es una ruta absoluta\n' "$id"; else _falla "$id" SIN-REPO "repo= no es una ruta absoluta"; fi
    return ;; esac
  argv=(incus exec "$cont" -- sh -c "$guion" runners-al-dia "$usr" "$repo" "$fullref")
  if [ "$maq" != "$local_id" ]; then
    argv=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -- "$maq" "$(_citar_posix "${argv[@]}")")
  fi
  if [ "$dry" -eq 1 ]; then
    out="$(_citar_posix "$bundle")"
    printf '# RUNNER %s\n%s< %s\n' "$id" "$(_citar_posix "${argv[@]}")" "${out% }"
    return
  fi
  tot=$((tot + 1))
  out="$("${argv[@]}" < "$bundle" 2>"$work/err")"; rc=$?
  causa="$(_limpio "$(head -n 1 "$work/err" 2>/dev/null)")"
  case "$rc" in
    0) last="${out##*$'\n'}"
       if [[ "$last" =~ ^[0-9a-f]{40,64}$ ]]; then
         sha9="${last:0:9}"
         case "$last" in
           "$esperado"*) okn=$((okn + 1)); _linea "$id" OK "$sha9" ;;
           *) _linea "$id" DIFIERE "$sha9 esperado=$esperado" ;;
         esac
       else
         _linea "$id" FETCH-FALLO "salida inesperada del runner: $(_limpio "$last")"
       fi ;;
    3) _linea "$id" SIN-REPO "repo= no es un repositorio git" ;;
    6) _linea "$id" FETCH-FALLO "refs/remotes/origin/main es una ref simbolica en $repo; no se toca nada" ;;
    11|12) _linea "$id" PUSH-FALLO "rc $rc ${causa:-sin detalle}" ;;
    255) if [ "$maq" != "$local_id" ]; then _linea "$id" SSH-FALLO "rc 255 ${causa:-sin detalle}"
         else _linea "$id" FETCH-FALLO "rc 255 ${causa:-sin detalle}"; fi ;;
    *) _linea "$id" FETCH-FALLO "rc $rc ${causa:-sin detalle}" ;;
  esac
}

_k=0
while [ "$_k" -lt "${#s_id[@]}" ]; do
  _runner "${s_id[$_k]}" "${s_maq[$_k]}" "${s_cont[$_k]}" "${s_usr[$_k]}" "${s_repo[$_k]}"
  _k=$((_k + 1))
done

[ "$dry" -eq 0 ] || exit 0
printf 'RUNNERS-AL-DIA ok=%s/%s origin/main=%s %s\n' "$okn" "$tot" "${bsha:0:8}" "$(date -u +%H:%M:%SZ)"
[ "$okn" -eq "$tot" ]
