#!/usr/bin/env bash
# test-runners-al-dia.sh — Tests HERMÉTICOS de runners-al-dia.sh (talent-ceo, ref 08).
#
# Sin red, sin ssh, sin incus, sin GitHub: repos git sintéticos, un bundle sintético y dobles de
# `ssh`, `incus` y `su` en un PATH temporal que ejecutan EN LOCAL. El doble de `ssh` junta los
# argumentos con espacios y los pasa a `bash -c`, como lo hace el shell remoto: si el script compone
# mal la cadena que viaja, los valores hostiles del perfil se EJECUTAN y el caso enrojece.
#
# ── MÉTODO: UN VERDE Y GUARDAS CON SU MUTANTE ──────────────────────────────────────────────────
# `TEST_RAD_SCRIPT` apunta a un script distinto del real SOLO para demostrar mutantes: una copia a la
# que se le quita UNA guarda debe enrojecer su caso. El script de juguete que imprime `ESPERADO=` y sale
# 0 enrojece las aserciones de rc de R2, R5 y R6.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final exige que ejecutados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RAD="${TEST_RAD_SCRIPT:-$ROOT/scripts/runners-al-dia.sh}"

TOTAL_ESPERADO=77
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/tdrad.XXXXXX")" || exit 2
_fin() {
  : "${T:?}"
  case "$T" in "${TMPDIR:-/tmp}"/tdrad.*) chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "$T" ;; esac
}
trap _fin EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
printf '== runners-al-dia: script bajo prueba: %s ==\n' "${RAD##*/}"

# ═══ dobles en un PATH temporal ════════════════════════════════════════════════════════════════
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'__FIN_DBL_SSH__'
#!/usr/bin/env bash
{ printf 'CALL\n'; printf '<%s>\n' "$@"; } >> "$FX_LOG/ssh.log"
while [ $# -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) shift ;; esac
done
host="$1"; shift
[ "${FX_SSH_FALLA-}" = "$host" ] && { echo "ssh: fallo simulado de conexión" >&2; exit 255; }
exec bash -c "$*"
__FIN_DBL_SSH__
cat > "$T/bin/incus" <<'__FIN_DBL_INCUS__'
#!/usr/bin/env bash
{ printf 'CALL\n'; printf '<%s>\n' "$1" "$2"; } >> "$FX_LOG/incus.log"
[ "$1" = exec ] || exit 2
cont="$2"; shift 2; [ "${1-}" = -- ] && shift
mkdir -p "$FX_CONT/$cont/tmp"
export TMPDIR="$FX_CONT/$cont/tmp"
[ -z "${FX_PLANTA-}" ] || printf 'ajeno\n' > "$TMPDIR/$FX_PLANTA"
[ "${FX_TMP_ROTO-}" = "$cont" ] && export TMPDIR="$FX_CONT/$cont/no-existe"
exec "$@"
__FIN_DBL_INCUS__
cat > "$T/bin/su" <<'__FIN_DBL_SU__'
#!/usr/bin/env bash
{ printf 'CALL\n'; printf '<%s>\n' "$1" "$2"; } >> "$FX_LOG/su.log"
[ "$1" = - ] && shift
u="$1"; shift
[ "$1" = -c ] || exit 2
cmd="$2"
export HOME="$FX_HOMES/$u"; mkdir -p "$HOME"
if [ -n "${FX_SHA_FALSO-}" ] && [ "$u" = "${FX_SHA_FALSO_USR-}" ]; then
  bash -c "$cmd" > /dev/null; rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$FX_SHA_FALSO"
  exit "$rc"
fi
exec bash -c "$cmd"
__FIN_DBL_SU__
chmod 755 "$T/bin/ssh" "$T/bin/incus" "$T/bin/su"

# ═══ repos sintéticos: base (A) -> up (A, B, tag) -> estación; runners clonados de la base ═════════
git init -q -b main "$T/base"
printf 'uno\n' > "$T/base/f.txt"; git -C "$T/base" add f.txt; git -C "$T/base" commit -q -m A
A="$(git -C "$T/base" rev-parse HEAD)"
git clone -q "$T/base" "$T/up" 2>/dev/null
printf 'dos\n' >> "$T/up/f.txt"; git -C "$T/up" commit -q -am B
B="$(git -C "$T/up" rev-parse HEAD)"; B9="${B:0:9}"; B8="${B:0:8}"
git -C "$T/up" tag t1
BUN="$T/main.bundle"
git -C "$T/up" bundle create "$BUN" main t1 --not "$A" >/dev/null 2>&1
git clone -q "$T/up" "$T/est" 2>/dev/null; EST="$T/est"
git init -q -b main "$T/ajeno"; git -C "$T/ajeno" commit -q --allow-empty -m X
HREF="q'\$(touch\${IFS}PWN4);\`touch\${IFS}PWN5\`"
git clone -q "$T/up" "$T/up2" 2>/dev/null
git -C "$T/up2" branch "$HREF" "$B"
BHOS="$T/hostil.bundle"
git -C "$T/up2" bundle create "$BHOS" "refs/heads/$HREF" --not "$A" >/dev/null 2>&1

export FX_LOG="$T/log" FX_CONT="$T/cont" FX_HOMES="$T/homes"
ESTMP="$T/est-tmp"
PF="$T/perfil.tsv"

fila() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
mkperfil() { { printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'; cat; } > "$1"; }
perfil_ok() {   # tres runners: r1 y r2 locales, r3 remoto
  { fila maquina m-loc m-loc - - acceso=local
    fila maquina m-rem m-rem - - rol=satelite
    fila runner r1 m-loc c1 - "usuario_contenedor=u1;repo=$T/repos/r1"
    fila runner r2 m-loc c2 - "usuario_contenedor=u1;repo=$T/repos/r2"
    fila runner r3 m-rem c3 - "usuario_contenedor=u2;repo=$T/repos/r3"; } | mkperfil "$PF"
}
reponer() {   # runners clonados de la base: HEAD = origin/main = A
  rm -rf "${T:?}/repos"; mkdir -p "$T/repos"
  for n in r1 r2 r3; do git clone -q "$T/base" "$T/repos/$n" 2>/dev/null; done
}
origen() { git -C "$1" rev-parse --short=9 refs/remotes/origin/main 2>/dev/null; }
# Huella de un repo: TODAS las refs con su naturaleza (simbólica: su destino; directa: su objeto)
# salvo refs/remotes/origin/main —que es lo único que el script puede cambiar— a menos que se pida
# `todo`; HEAD con su destino; el índice (modo, objeto y etapa de cada entrada); y modo + hash de los
# bytes de CADA fichero seguido y no seguido. `status --porcelain` no basta: conserva el mismo texto
# si cambia el contenido de un fichero que ya estaba modificado.
huella() {
  local r="$1" todo="${2-}" f
  {
    git -C "$r" for-each-ref --format='%(refname) %(if)%(symref)%(then)SIMBOLICA %(symref)%(else)%(objectname)%(end)' \
      | { if [ "$todo" = todo ]; then cat; else grep -v '^refs/remotes/origin/main '; fi; }
    printf 'HEAD %s %s\n' "$(git -C "$r" symbolic-ref -q HEAD || echo suelta)" "$(git -C "$r" rev-parse HEAD)"
    git -C "$r" ls-files -s
    git -C "$r" status --porcelain
    ( cd "$r" && git ls-files -co --exclude-standard | while IFS= read -r f; do
        printf 'FICHERO %s %s %s\n' "$(stat -c %a -- "$f")" "$(sha1sum < "$f" | cut -d' ' -f1)" "$f"
      done )
  } 2>&1
}
run_rad() {
  rm -rf "$FX_LOG" "$FX_CONT" "$ESTMP"; mkdir -p "$FX_LOG" "$FX_CONT" "$ESTMP"
  OUT="$(cd "${CWD:-$EST}" && env PATH="$T/bin:$PATH" TA_PERFIL="$PF" TMPDIR="$ESTMP" bash "$RAD" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
calls() { if [ -f "$FX_LOG/$1.log" ]; then grep -c '^CALL$' "$FX_LOG/$1.log" || true; else echo 0; fi; }
nocalls() { printf '%s%s%s' "$(calls ssh)" "$(calls incus)" "$(calls su)"; }
residuos() { find "$FX_CONT" -type f 2>/dev/null | wc -l | tr -d ' '; }
lineas() { printf '%s\n' "$OUT" | grep -c "$1" || true; }

# ═══ R1: dos runners locales y uno remoto ══════════════════════════════════════════════════════
printf '== R1: tres runners, todos al día ==\n'
perfil_ok; reponer
run_rad --bundle "$BUN" --ref main --esperado "${B:0:12}"
assert_eq 'R1 rc 0' 0 "$RC"
assert_eq 'R1 tres líneas RUNNER <id> OK <sha9>' 3 "$(lineas "^RUNNER r[123] OK $B9\$")"
last="${OUT##*$'\n'}"
resumen_ok=no
[[ "$last" =~ ^RUNNERS-AL-DIA\ ok=3/3\ origin/main=$B8\ [0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && resumen_ok=si
assert_eq 'R1 resumen citable ok=3/3' si "$resumen_ok"
assert_eq 'R1 el remoto entra por ssh -- <maquina> (una sola llamada)' "1|1" "$(calls ssh)|$(grep -A1 -x '<-->' "$FX_LOG/ssh.log" | grep -c -x '<m-rem>')"
assert_eq 'R1 un incus exec por runner' 3 "$(calls incus)"
assert_eq 'R1 origin/main de los tres runners = B' "$B9|$B9|$B9" "$(origen "$T/repos/r1")|$(origen "$T/repos/r2")|$(origen "$T/repos/r3")"

# ═══ R2: --esperado no coincide con el sha del ref ═════════════════════════════════════════════
printf '== R2: --esperado distinto del bundle ==\n'
reponer
run_rad --bundle "$BUN" --ref main --esperado "${A:0:9}"
assert_eq 'R2 rc 2' 2 "$RC"
assert_eq 'R2 stderr dice los dos sha' "1|1" "$(printf '%s' "$ERR" | grep -c "${A:0:9}")|$(printf '%s' "$ERR" | grep -c "$B")"
assert_eq 'R2 cero llamadas a ssh, incus y su' 000 "$(nocalls)"
assert_eq 'R2 ningún runner tocado' "$(origen "$T/repos/r1")" "${A:0:9}"

# ═══ R3: bundle corrupto, symlink, ausente, ref ausente, prerrequisito ausente ═════════════════
printf '== R3: bundle que no pasa las guardas ==\n'
printf 'esto no es un bundle\n' > "$T/basura.bundle"
ln -s "$BUN" "$T/enlace.bundle"
run_rad --bundle "$T/basura.bundle" --ref main --esperado "$B9"
assert_eq 'R3 bundle corrupto: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
run_rad --bundle "$T/enlace.bundle" --ref main --esperado "$B9"
assert_eq 'R3 bundle symlink: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
run_rad --bundle "$T/no-existe.bundle" --ref main --esperado "$B9"
assert_eq 'R3 bundle ausente: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
run_rad --bundle "$BUN" --ref no-esta --esperado "$B9"
assert_eq 'R3 --ref que no está en el bundle: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
CWD="$T/ajeno" run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R3 prerrequisito ausente en el repo de la estación: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"

# ═══ R4: filas sin contenedor ══════════════════════════════════════════════════════════════════
printf '== R4: runners sin contenedor ==\n'
reponer
{ fila maquina m-loc m-loc - - acceso=local
  fila runner r1 m-loc - - "usuario_contenedor=u1;repo=$T/repos/r1"
  fila runner r2 m-loc c2 - "usuario_contenedor=u1;repo=$T/repos/r2"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R4 fila sin contenedor: OMITIDO y rc 0 con la otra buena' "0|1|1" "$RC|$(lineas '^RUNNER r1 OMITIDO ')|$(lineas "^RUNNERS-AL-DIA ok=1/1 ")"
assert_eq 'R4 el omitido no se toca' "${A:0:9}" "$(origen "$T/repos/r1")"
{ fila maquina m-loc m-loc - - acceso=local
  fila runner r1 m-loc - - "usuario_contenedor=u1;repo=$T/repos/r1"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R4 ninguna fila ejecutable: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"

# ═══ R5: fila sin repo= o con repo= que no es repositorio ══════════════════════════════════════
printf '== R5: SIN-REPO ==\n'
reponer; mkdir -p "$T/norepo"
{ fila maquina m-loc m-loc - - acceso=local
  fila runner r1 m-loc c1 - "usuario_contenedor=u1;repo=$T/repos/r1"
  fila runner r2 m-loc c2 - "usuario_contenedor=u1"
  fila runner r3 m-loc c3 - "usuario_contenedor=u1;repo=$T/norepo"
  fila runner r4 m-loc c4 - "repo=$T/repos/r2"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R5 rc 1 al final' 1 "$RC"
assert_eq 'R5 fila sin repo=: SIN-REPO' 1 "$(lineas '^RUNNER r2 SIN-REPO sin repo= ')"
assert_eq 'R5 repo= que no es repositorio: SIN-REPO' 1 "$(lineas '^RUNNER r3 SIN-REPO ')"
assert_eq 'R5 fila sin usuario_contenedor=: SIN-REPO, sin valor por defecto' 1 "$(lineas '^RUNNER r4 SIN-REPO sin usuario_contenedor= ')"
assert_eq 'R5 el resto se procesa' "1|$B9|ok=1/4" "$(lineas "^RUNNER r1 OK $B9\$")|$(origen "$T/repos/r1")|$(printf '%s' "${OUT##*$'\n'}" | grep -o 'ok=[0-9]*/[0-9]*')"
assert_eq 'R5 el repo sin usuario no se actualiza (no hay valor por defecto)' "${A:0:9}" "$(origen "$T/repos/r2")"

# ═══ R6: al repo del runner le falta el commit prerrequisito del bundle ════════════════════════
printf '== R6: FETCH-FALLO ==\n'
perfil_ok; reponer
rm -rf "${T:?}/repos/r2"; git init -q -b main "$T/repos/r2"; git -C "$T/repos/r2" commit -q --allow-empty -m X
git -C "$T/repos/r2" update-ref refs/remotes/origin/main HEAD
X9="$(origen "$T/repos/r2")"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R6 rc 1' 1 "$RC"
assert_eq 'R6 FETCH-FALLO en el culpable, con causa' 1 "$(lineas '^RUNNER r2 FETCH-FALLO rc 4 .')"
assert_eq 'R6 su origin/main NO cambia' "$X9" "$(origen "$T/repos/r2")"
assert_eq 'R6 los demás se procesan' "2|ok=2/3" "$(lineas "^RUNNER r[13] OK $B9\$")|$(printf '%s' "${OUT##*$'\n'}" | grep -o 'ok=[0-9]*/[0-9]*')"
assert_eq 'R6 el bundle temporal del runner se borra también ante fallo' 0 "$(residuos)"

# ═══ R7: ssh que falla, copia que falla ════════════════════════════════════════════════════════
printf '== R7: SSH-FALLO y PUSH-FALLO ==\n'
perfil_ok; reponer
export FX_SSH_FALLA=m-rem
run_rad --bundle "$BUN" --ref main --esperado "$B9"
unset FX_SSH_FALLA
assert_eq 'R7 ssh que falla: SSH-FALLO y rc 1' "1|1" "$RC|$(lineas '^RUNNER r3 SSH-FALLO ')"
assert_eq 'R7 los locales siguen al día' "2" "$(lineas "^RUNNER r[12] OK $B9\$")"
perfil_ok; reponer
export FX_TMP_ROTO=c2
run_rad --bundle "$BUN" --ref main --esperado "$B9"
unset FX_TMP_ROTO
assert_eq 'R7 copia que falla: PUSH-FALLO y rc 1' "1|1" "$RC|$(lineas '^RUNNER r2 PUSH-FALLO ')"
assert_eq 'R7 tras el fallo no queda bundle en ningún runner' 0 "$(residuos)"
assert_eq 'R7 el runner con la copia rota no cambia' "${A:0:9}" "$(origen "$T/repos/r2")"

# ═══ R8: valores hostiles del perfil, del ref y de la ruta del bundle ══════════════════════════
printf '== R8: valores hostiles ==\n'
reponer
HREPO="$T/rep os/q'u \"d\" \$(touch PWN1) \`touch PWN2\` & | >x"
HREPO2="$HREPO 2"
HM='m h$(touch PWN3)'
mkdir -p "$T/rep os"
git clone -q "$T/base" "$HREPO" 2>/dev/null; git clone -q "$T/base" "$HREPO2" 2>/dev/null
{ fila maquina m-loc m-loc - - acceso=local
  fila maquina "$HM" "$HM" - - rol=x
  fila runner h1 m-loc c1 - "usuario_contenedor=u1;repo=$HREPO"
  fila runner h2 "$HM" c2 - "usuario_contenedor=u1;repo=$HREPO2"; } | mkperfil "$PF"
run_rad --bundle "$BHOS" --ref "$HREF" --esperado "$B9"
assert_eq 'R8 ruta con espacio, comilla, $(…), comillas dobles, acento grave, & y |: rc 0 y dos OK' "0|2" "$RC|$(lineas "^RUNNER h[12] OK $B9\$")"
assert_eq 'R8 el ref hostil y la ruta hostil llegaron como datos: origin/main = B en ambos' "$B9|$B9" "$(origen "$HREPO")|$(origen "$HREPO2")"
assert_eq 'R8 nada se ejecutó (ni $(touch) ni acento grave) en la estación' 0 "$(find "$EST" "$T" -maxdepth 1 -name 'PWN*' | wc -l | tr -d ' ')"
assert_eq 'R8 nada se ejecutó dentro de los repos de los runners' 0 "$(find "$HREPO" "$HREPO2" -maxdepth 1 -name 'PWN*' | wc -l | tr -d ' ')"
assert_eq 'R8 la máquina hostil viaja como UN solo argumento tras --' 1 "$(grep -A1 -x '<-->' "$FX_LOG/ssh.log" | grep -c -x "<$HM>")"
reponer
BNL="$T/b
n.bundle"; cp "$BUN" "$BNL"
perfil_ok
run_rad --bundle "$BNL" --ref main --esperado "$B9" --runner r1
assert_eq 'R8 ruta del bundle con salto de línea: rc 0 y OK' "0|1" "$RC|$(lineas "^RUNNER r1 OK $B9\$")"
{ fila maquina m-loc m-loc - - acceso=local
  fila runner 'r 1' m-loc c1 - "usuario_contenedor=u1;repo=$T/repos/r1"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R8 id fuera de charset: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
{ fila maquina m-loc m-loc - - acceso=local
  fila runner r1 m-loc 'c$(touch PWN6)' - "usuario_contenedor=u1;repo=$T/repos/r1"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R8 contenedor fuera de charset: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
{ fila maquina m-loc m-loc - - acceso=local
  fila runner r1 m-loc c1 - "usuario_contenedor=-x;repo=$T/repos/r1"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R8 usuario_contenedor que empieza por guion: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
perfil_ok
run_rad --bundle "$BUN" --ref main --esperado "$B9" --runner "r1;touch PWN7"
assert_eq 'R8 --runner hostil: rc 2 y nada ejecutado' "2|000|0" "$RC|$(nocalls)|$(find "$EST" -maxdepth 1 -name 'PWN*' | wc -l | tr -d ' ')"

# ═══ R9: --dry-run ═════════════════════════════════════════════════════════════════════════════
printf '== R9: --dry-run ==\n'
perfil_ok; reponer
run_rad --bundle "$BUN" --ref main --esperado "$B9" --dry-run
assert_eq 'R9 rc 0 y cero llamadas a ssh, incus y su' "0|000" "$RC|$(nocalls)"
assert_eq 'R9 no cambia ningún origin/main' "${A:0:9}" "$(origen "$T/repos/r1")"
assert_eq 'R9 imprime un comando por runner, con el bundle por stdin' "3|3" "$(printf '%s\n' "$OUT" | grep -c "^'incus' 'exec' 'c[123]' \|^'ssh' ")|$(printf '%s\n' "$OUT" | grep -c " < '$BUN'\$")"
assert_eq 'R9 el remoto lleva ssh con -- y la máquina' 1 "$(printf '%s\n' "$OUT" | grep -c "^'ssh' .* '--' 'm-rem' ")"
(cd "$EST" && env PATH="$T/bin:$PATH" TMPDIR="$ESTMP" bash -c "$OUT" >/dev/null 2>&1); rc2=$?
assert_eq 'R9 lo impreso, ejecutado tal cual, termina con rc 0' 0 "$rc2"
assert_eq 'R9 lo impreso, ejecutado tal cual, deja a los tres runners al día' "$B9|$B9|$B9" "$(origen "$T/repos/r1")|$(origen "$T/repos/r2")|$(origen "$T/repos/r3")"

# ═══ R10: solo cambia refs/remotes/origin/main ═════════════════════════════════════════════════
printf '== R10: nada más cambia ==\n'
perfil_ok; reponer
for n in r1 r2 r3; do
  printf 'sucio\n' >> "$T/repos/$n/f.txt"; printf 'nuevo\n' > "$T/repos/$n/sin-seguir.txt"
  printf 'indice\n' > "$T/repos/$n/en-indice.txt"; git -C "$T/repos/$n" add en-indice.txt
  printf 'mas\n' >> "$T/repos/$n/en-indice.txt"          # etapa en el índice distinta del árbol
  printf 'x\n' > "$T/repos/$n/ejecutable.sh"; chmod 755 "$T/repos/$n/ejecutable.sh"   # modo
done
h_antes="$(huella "$T/repos/r1")|$(huella "$T/repos/r2")|$(huella "$T/repos/r3")"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
h_despues="$(huella "$T/repos/r1")|$(huella "$T/repos/r2")|$(huella "$T/repos/r3")"
assert_eq 'R10 refs (con naturaleza), HEAD, índice y bytes+modos de ficheros seguidos y no seguidos idénticos en los tres runners (el bundle trae un tag)' "$h_antes" "$h_despues"
assert_eq 'R10 origin/HEAD sigue simbólica y apunta a origin/main en los tres runners' "refs/remotes/origin/main|refs/remotes/origin/main|refs/remotes/origin/main" "$(git -C "$T/repos/r1" symbolic-ref refs/remotes/origin/HEAD)|$(git -C "$T/repos/r2" symbolic-ref refs/remotes/origin/HEAD)|$(git -C "$T/repos/r3" symbolic-ref refs/remotes/origin/HEAD)"
assert_eq 'R10 solo origin/main cambió' "0|$B9|$B9|$B9" "$RC|$(origen "$T/repos/r1")|$(origen "$T/repos/r2")|$(origen "$T/repos/r3")"
assert_eq 'R10 ningún tag del bundle llegó al runner' 0 "$(git -C "$T/repos/r1" tag | wc -l | tr -d ' ')"
assert_eq 'R10 ningún bundle residual en el runner' 0 "$(residuos)"
reponer
export FX_PLANTA=ceo-main.bundle
run_rad --bundle "$BUN" --ref main --esperado "$B9" --runner r1
unset FX_PLANTA
assert_eq 'R10 el bundle temporal no tiene nombre fijo: un fichero ajeno con el nombre de la fuente anterior sobrevive' "0|ajeno" "$RC|$(cat "$FX_CONT/c1/tmp/ceo-main.bundle" 2>/dev/null)"
assert_eq 'R10 ningún residuo en la estación' 0 "$(find "$ESTMP" -mindepth 1 | wc -l | tr -d ' ')"

# R10 con una ref SIMBÓLICA: `update-ref` sin `--no-deref` la sigue y cambia la rama local y HEAD (el runner
# diría OK habiendo movido otra ref). El script la rechaza ANTES de tocar nada y nombra al runner.
printf '== R10: refs/remotes/origin/main simbólica ==\n'
perfil_ok; reponer
git -C "$T/repos/r2" symbolic-ref refs/remotes/origin/main refs/heads/main
printf 'sucio\n' >> "$T/repos/r2/f.txt"; printf 'nuevo\n' > "$T/repos/r2/sin-seguir.txt"
s_antes="$(huella "$T/repos/r2" todo)"
s_head="$(git -C "$T/repos/r2" symbolic-ref HEAD)|$(git -C "$T/repos/r2" rev-parse HEAD)|$(git -C "$T/repos/r2" rev-parse refs/heads/main)"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R10 ref simbólica: rc 1 y FETCH-FALLO nombrando al runner culpable (nunca OK)' "1|1|0" "$RC|$(lineas '^RUNNER r2 FETCH-FALLO .*simbolica')|$(lineas '^RUNNER r2 OK')"
assert_eq 'R10 ref simbólica: HEAD (con su destino) y la rama local intactos' "$s_head" "$(git -C "$T/repos/r2" symbolic-ref HEAD)|$(git -C "$T/repos/r2" rev-parse HEAD)|$(git -C "$T/repos/r2" rev-parse refs/heads/main)"
assert_eq 'R10 ref simbólica: origin/main sigue siendo simbólica y apunta a la rama local' "refs/heads/main" "$(git -C "$T/repos/r2" symbolic-ref refs/remotes/origin/main 2>&1)"
assert_eq 'R10 ref simbólica: huella completa idéntica (todas las refs con naturaleza, índice, bytes y modos)' "$s_antes" "$(huella "$T/repos/r2" todo)"
assert_eq 'R10 ref simbólica: los demás runners se procesan' "$B9|$B9|ok=2/3" "$(origen "$T/repos/r1")|$(origen "$T/repos/r3")|$(printf '%s' "${OUT##*$'\n'}" | grep -o 'ok=[0-9]*/[0-9]*')"

# ═══ R11: --runner ═════════════════════════════════════════════════════════════════════════════
printf '== R11: --runner ==\n'
perfil_ok; reponer
run_rad --bundle "$BUN" --ref main --esperado "$B9" --runner r1 --runner r3
assert_eq 'R11 --runner repetido: solo esos' "0|2|0|ok=2/2" "$RC|$(lineas "^RUNNER r[13] OK ")|$(lineas '^RUNNER r2 ')|$(printf '%s' "${OUT##*$'\n'}" | grep -o 'ok=[0-9]*/[0-9]*')"
assert_eq 'R11 el no pedido no se toca' "${A:0:9}" "$(origen "$T/repos/r2")"
run_rad --bundle "$BUN" --ref main --esperado "$B9" --runner r1 --runner inexistente
assert_eq 'R11 un id que no existe: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"

# ═══ R12: perfil ausente o inválido ════════════════════════════════════════════════════════════
printf '== R12: perfil ausente o inválido ==\n'
sv="$PF"
PF="$T/no-existe.tsv"; run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R12 perfil ausente: rc 2 con motivo' "2|1|000" "$RC|$(printf '%s' "$ERR" | grep -c 'PRECOND')|$(nocalls)"
PF="$T/malo.tsv"; printf 'esto no es un perfil\n' > "$PF"; run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R12 perfil inválido: rc 2 sin tocar nada' "2|000" "$RC|$(nocalls)"
PF="$sv"
{ fila maquina m-loc m-loc - - acceso=local; } | mkperfil "$PF"; run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R12 perfil sin ninguna fila runner: rc 2' "2|000" "$RC|$(nocalls)"
{ fila maquina m-loc m-loc - - rol=x
  fila runner r1 m-loc c1 - "usuario_contenedor=u1;repo=$T/repos/r1"; } | mkperfil "$PF"
run_rad --bundle "$BUN" --ref main --esperado "$B9"
assert_eq 'R12 ninguna máquina con acceso=local: rc 2 (fail-closed)' "2|000" "$RC|$(nocalls)"

# ═══ DIFIERE y uso ═════════════════════════════════════════════════════════════════════════════
printf '== DIFIERE y argumentos ==\n'
perfil_ok; reponer
export FX_SHA_FALSO=0123456789abcdef0123456789abcdef01234567 FX_SHA_FALSO_USR=u2
run_rad --bundle "$BUN" --ref main --esperado "$B9"
unset FX_SHA_FALSO FX_SHA_FALSO_USR
assert_eq 'DIFIERE un runner que no queda en el sha esperado: rc 1' "1|1|ok=2/3" "$RC|$(lineas '^RUNNER r3 DIFIERE 012345678 ')|$(printf '%s' "${OUT##*$'\n'}" | grep -o 'ok=[0-9]*/[0-9]*')"
run_rad --bundle "$BUN" --ref main --esperado xyz
assert_eq 'uso: --esperado mal formado: rc 2' "2|000" "$RC|$(nocalls)"
run_rad --bundle "$BUN" --ref main
assert_eq 'uso: falta --esperado: rc 2' 2 "$RC"
run_rad --ref main --esperado "$B9"
assert_eq 'uso: falta --bundle: rc 2' 2 "$RC"
run_rad --bundle "$BUN" --ref main --esperado "$B9" --nada
assert_eq 'uso: argumento desconocido: rc 2' 2 "$RC"
run_rad --help
assert_eq 'uso: --help: rc 0 y muestra el uso' "0|1" "$RC|$(lineas '^# Uso:')"

# ═══ invariantes del propio texto ═════════════════════════════════════════════════════════════
printf '== Invariantes ==\n'
assert_eq 'el script no contiene eval, kill ni pgrep' 0 "$(grep -cE 'eval|kill|pgrep' "$RAD" || true)"
assert_eq 'el script no contiene ficheros de hosts ni listas fijas de máquinas' 0 "$(grep -cE '\.ip\b|HOSTS' "$RAD" || true)"

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desapareció un caso?)"; rc=1; }
exit "$rc"
