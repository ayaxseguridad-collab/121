#!/usr/bin/env bash
# run-tests.sh — arnés del MOVE transaccional de credenciales (TAL-2294).
# Ejercita auth-move-lib.sh con shims de incus/codex/claude por PATH y los failpoints del arnés,
# cubriendo los controles del plan TAL-2288 rev 10 (M8): endpoints tipados, locks deterministas +
# posesión por FD, coordinador único, freeze + vía autorizada (tx correcto/incorrecto/sin-locks),
# commit por mv atómico, cadena de durabilidad fsync, cleanup post-commit, reconciliación por
# inspección (digest→commit / ausente→restore / contradictorio→fail-closed), crash en cada frontera
# de fase (kill -9 real via subproceso + failpoints), timeout con refresh consumido, dos MOVE
# concurrentes al mismo destino. NO toca incus/credenciales reales.
# #16-17 (TAL-1968) añaden aserciones de VALOR/side-effect sobre 02-golden.sh: extraen el fragmento
# REAL del script (por ancla de contenido, no duplicado) para el fallback de Node y la instalación
# del CLI de CodeRabbit, y lo ejercitan con shims de curl/uname — no solo bash -n.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../tests/fixtures/instalacion/gh-dobles.sh" || exit 2
LIB="$SCRIPTS/auth-move-lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1" >&2; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 — [$2]"; fi; }

# --- sandbox global ---------------------------------------------------------
WORK="$(mktemp -d)"; trap 'kill -9 "${CANARIO_PID:-}" "${CANARIO2_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SHIMS="$WORK/bin"; mkdir -p "$SHIMS"
cp "$HERE/fake-incus.sh" "$SHIMS/incus"; chmod +x "$SHIMS/incus"
cp "$HERE/fake-codex.sh" "$SHIMS/codex"; chmod +x "$SHIMS/codex"
cp "$HERE/fake-codex.sh" "$SHIMS/claude"; chmod +x "$SHIMS/claude"
export PATH="$SHIMS:$PATH"

export AM_TEST=1
export CUSER; CUSER="$(id -un)"
export AM_HC_TIMEOUT=3

# --- CANARIOS de colateral (TAL-5507 → TAL-8042) ----------------------------------------------
# Dos procesos AJENOS creados ANTES de cualquier test y comprobados vivos al final del arnés
# (verificación final, justo antes del resumen). NUNCA se registran ni se excluyen en ningún sitio:
#   - CANARIO_PID  → argv[0] = `codex-centinela` (lleva "codex" en argv: la víctima del viejo `-f`).
#   - CANARIO2_PID → argv[0] EXACTO = `codex`: ES el ejecutable de un agente — lo único que lo salva
#     es el escudo hermético (fake-incus: lista de PIDs creados por el test). Es el peor caso: el
#     matcher por ejecutable SÍ lo vería.
# Si algún test (o un camino de quiesce/kill-wait) mata colateral, el canario muere TAMBIÉN y la suite
# enrojece aunque todos los `chk` individuales hubieran dado verde (medido el 2026-10-03: 114/0 con
# agentes reales de otras sesiones muertos).
exec -a codex-centinela sleep 300 &
CANARIO_PID=$!
exec -a codex sleep 300 &
CANARIO2_PID=$!
CANARIO_MURIO=0

# Prepara un entorno limpio (SECRET_DIR + CROOT + ledger) para un caso. Echoes vars por eval.
new_env() {
  local base="$WORK/case.$RANDOM.$1"
  mkdir -p "$base/secret" "$base/croot"
  cat > "$base/ledger.json" <<JSON
{
  "coordinator_host": "$(hostname)",
  "pozos": { "pz": { "estado": "CARGADO", "cuenta": "acme", "habilitada_fabrica": true, "curado_lead": "NO TOCAR" } },
  "cuentas": [ { "alias": "acme", "grants_vivos": ["pool:pz (origen)"], "nota_curada": "preservar" } ]
}
JSON
  printf 'SECRET_DIR=%q AM_LEDGER=%q AM_TEST_CROOT=%q\n' "$base/secret" "$base/ledger.json" "$base/croot"
}
# Siembra un auth.json (contenido único) en un endpoint tipo contenedor del CROOT dado.
seed_channel_auth() { # croot channel agent contenido
  local home="$1/$2/home/$CUSER" rel
  case "$3" in codex) rel=".codex/auth.json" ;; claude) rel=".claude/.credentials.json" ;; esac
  mkdir -p "$home/$(dirname "$rel")"; printf '%s' "$4" > "$home/$rel"; chmod 600 "$home/$rel"
}
auth_path() { # croot channel agent
  local rel; case "$3" in codex) rel=".codex/auth.json" ;; claude) rel=".claude/.credentials.json" ;; esac
  printf '%s/%s/home/%s/%s' "$1" "$2" "$CUSER" "$rel"
}

# ==========================================================================
echo "== 1. Endpoints tipados =="
( set -e; eval "$(new_env ep)"; . "$LIB"
  am_ep_validate "host:$(hostname)" && am_ep_validate "channel:vibe-channel-01" && am_ep_validate "pool:pz" \
    || exit 1
  am_ep_validate "host:otro-host" 2>/dev/null && exit 2   # host ajeno → rechazo
  am_ep_validate "banana:x" 2>/dev/null && exit 3         # tipo inválido → rechazo
  [ "$(am_ep_type channel:ch)" = channel ] && [ "$(am_ep_id channel:ch)" = ch ] || exit 4
  exit 0 )
chk "validación/tipado de endpoints (host propio ok; ajeno e inválido rechazados)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 2. Locks: hash por clave canónica, determinismo, posesión por FD, concurrencia =="
( set -e; eval "$(new_env locks)"; . "$LIB"
  la="$(am_lock_path "cuenta:acme")"; lb="$(am_lock_path "channel:x")"
  [ "$la" != "$lb" ] || exit 1                                   # claves distintas → paths distintos
  [ "$la" = "$(am_lock_path "cuenta:acme")" ] || exit 2          # determinista
  am_acquire_locks "cuenta:acme" "pool:pz" "channel:x" || exit 3
  am_locks_held || exit 4                                        # posesión real por FD
  # Segundo proceso: flock -n sobre una de las mismas claves debe FALLAR (concurrencia).
  if ( . "$LIB"; am_acquire_locks "channel:x" ) 2>/dev/null; then exit 5; fi
  am_release_locks
  am_locks_held && exit 6 || true                                # tras soltar, no se poseen
  exit 0 )
chk "locks deterministas + posesión por FD + rechazo concurrente" "[ $? -eq 0 ]"

# [ronda 2 · adquisición PARCIAL] si falla el 2.º lock, NO deben quedar FDs retenidos (auto-bloqueo).
( eval "$(new_env partial)"; . "$LIB"
  # Un holder toma channel:b; el intento de acquire [a,b] debe fallar en b y SOLTAR a → un
  # reintento posterior de channel:a debe PODER tomarlo (si quedara retenido, se auto-bloquearía).
  ready="$WORK/partial.ready.$RANDOM"
  ( . "$LIB"; am_acquire_locks "channel:b" >/dev/null && touch "$ready"; sleep 5 ) & h=$!
  for _ in $(seq 1 100); do [ -f "$ready" ] && break; sleep 0.1; done
  ( . "$LIB"; am_acquire_locks "channel:a" "channel:b" ) 2>/dev/null && { kill $h 2>/dev/null; exit 1; }
  # tras el fallo parcial, channel:a debe estar libre (se soltó):
  if ( . "$LIB"; am_acquire_locks "channel:a" ) 2>/dev/null; then rc=0; else rc=1; fi
  kill $h 2>/dev/null; wait $h 2>/dev/null || true
  [ "$rc" -eq 0 ] || exit 2
  exit 0 )
chk "adquisición parcial de locks NO deja FDs retenidos (sin auto-bloqueo)" "[ $? -eq 0 ]"

# [ronda 2 · am_ep_quiet fail-closed] error de pgrep (usuario inexistente) ⇒ NO quiescente.
( eval "$(new_env quiet)"; . "$LIB"
  # host endpoint con un usuario que no existe → pgrep -u falla con rc>1 → am_ep_quiet debe dar NO
  # quiescente (rc≠0), no "quiescente" por tragarse el error.
  CUSER="usuario-inexistente-xyz" am_ep_quiet "channel:z" codex && exit 1 || exit 0 )
chk "am_ep_quiet fail-closed ante error de pgrep (no lo trata como quiescente)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 3. Guard de coordinador único =="
( set -e; eval "$(new_env coord)"; . "$LIB"
  am_coordinator_guard || exit 1                                 # host coincide
  ( unset AM_LEDGER; . "$LIB"; am_coordinator_guard ) 2>/dev/null && exit 2   # sin ledger → fail-closed
  # coordinator_host distinto → rechazo
  sed -i 's/"coordinator_host": *"[^"]*"/"coordinator_host": "otra-estacion"/' "$AM_LEDGER"
  am_coordinator_guard 2>/dev/null && exit 3 || true
  exit 0 )
chk "coordinador único (match ok; sin-ledger y host-distinto rechazados)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 4. MOVE happy-path channel→channel (commit, cleanup, ledger, preservación) =="
out4="$WORK/out4"; eval "$(new_env happy)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "SECRETO-DE-ACME-v1"
( . "$LIB"; am_move acme codex channel:chA channel:chB ) >"$out4" 2>&1; rc4=$?
donorA="$(auth_path "$AM_TEST_CROOT" chA codex)"; destB="$(auth_path "$AM_TEST_CROOT" chB codex)"
chk "MOVE rc=0" "[ $rc4 -eq 0 ]"
chk "donante SIN auth tras el MOVE" "[ ! -f '$donorA' ]"
chk "destino CON auth" "[ -f '$destB' ]"
chk "destino conserva el contenido correcto" "[ \"\$(cat '$destB')\" = 'SECRETO-DE-ACME-v1' ]"
chk "snapshots destruidos (cero copias residuales)" "[ -z \"\$(ls -A '$SECRET_DIR/snapshots' 2>/dev/null)\" ]"
chk ".consumed del donante destruido" "[ -z \"\$(ls '$AM_TEST_CROOT/chA/home/$CUSER/.codex/'*.consumed.* 2>/dev/null)\" ]"
chk "freeze del destino retirado" "[ ! -f '$AM_TEST_CROOT/chB/home/$CUSER/.codex/.move-freeze' ]"
tx4="$(ls "$SECRET_DIR/journal" | sed 's/\.json//' | head -1)"
chk "journal en fase DONE" "grep -q '\"fase\": \"DONE\"' '$SECRET_DIR/journal/$tx4.json'"
chk "ledger: grant del destino registrado" "grep -q 'channel:chB (MOVE' '$AM_LEDGER'"
chk "ledger: clave curada ajena PRESERVADA" "grep -q 'nota_curada' '$AM_LEDGER'"
chk "ledger: clave de pozo curada PRESERVADA" "grep -q 'curado_lead' '$AM_LEDGER'"

# ==========================================================================
echo "== 5. Destino con auth preexistente → MOVE rechazado =="
eval "$(new_env preexist)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "ORIGEN"
seed_channel_auth "$AM_TEST_CROOT" chB codex "YA-VIVE-OTRA"
( . "$LIB"; am_move acme codex channel:chA channel:chB ) >/dev/null 2>&1; rc5=$?
chk "MOVE rechazado si el destino ya tiene auth" "[ $rc5 -ne 0 ]"
chk "auth preexistente del destino intacto" "[ \"\$(cat '$(auth_path "$AM_TEST_CROOT" chB codex)')\" = 'YA-VIVE-OTRA' ]"

# ==========================================================================
echo "== 6. Freeze + vía autorizada (tx correcto / incorrecto / sin locks) =="
( set -e; eval "$(new_env gate)"; . "$LIB"
  seed_channel_auth "$AM_TEST_CROOT" chA codex "X"
  am_acquire_locks "cuenta:acme" "channel:chA" >/dev/null
  am_freeze_set "channel:chA" codex "tx-BUENO" || exit 1
  export AM_TEST_CROOT SECRET_DIR
  # journal vigente para el tx bueno
  AM_CUENTA=acme AM_AGENT=codex AM_FROM=channel:chA AM_TO=channel:chB am_journal_write "tx-BUENO" "PREPARED" "test" || exit 2
  am_authorized_gate "channel:chA" codex "tx-BUENO" || exit 3           # tx correcto + locks → permitido
  am_authorized_gate "channel:chA" codex "tx-MALO" 2>/dev/null && exit 4 # tx incorrecto → rechazo
  am_authorized_gate "channel:chA" codex "" 2>/dev/null && exit 5        # sin tx → rechazo
  am_release_locks
  ( . "$LIB"; am_authorized_gate "channel:chA" codex "tx-BUENO" ) 2>/dev/null && exit 6  # sin locks → rechazo
  exit 0 )
chk "vía autorizada: solo tx+freeze+journal+locks simultáneos" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 7. Timeout con refresh consumido: health-check POST-commit falla → NO restaura donante =="
eval "$(new_env timeout)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "ACME-v2"
# El donante pasa su health-check (rc 0); el destino, POST-commit, lo FALLA por timeout (sleep>timeout).
# Distinguimos por endpoint con un wrapper que mira el freeze del destino… más simple: primer one-shot
# (donante) ok, segundo (destino) timeout. Usamos un contador en archivo.
cnt="$WORK/hc.$RANDOM"; echo 0 > "$cnt"
cat > "$SHIMS/codex" <<CODEX
#!/usr/bin/env bash
n=\$(cat "$cnt"); n=\$((n+1)); echo \$n > "$cnt"
# 1ª llamada = health del donante → OK; 2ª = health del destino → cuelga (timeout duro lo mata).
if [ "\$n" -ge 2 ]; then sleep 30; fi
exit 0
CODEX
chmod +x "$SHIMS/codex"
( . "$LIB"; am_move acme codex channel:chA channel:chB ) >/dev/null 2>&1; rc7=$?
chk "MOVE devuelve 4 (health POST-commit fallido, reparable en destino)" "[ $rc7 -eq 4 ]"
chk "donante NO restaurado (sigue sin auth)" "[ ! -f '$(auth_path "$AM_TEST_CROOT" chA codex)' ]"
chk "destino CONSERVA el auth (propietario tras commit)" "[ -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"
tx7="$(ls "$SECRET_DIR/journal" | sed 's/\.json//' | head -1)"
chk "freezes SIGUEN puestos (transacción abierta hasta repair)" "[ -f '$AM_TEST_CROOT/chB/home/$CUSER/.codex/.move-freeze' ]"
# resume con health OK → DONE, sin tocar al donante
cp "$HERE/fake-codex.sh" "$SHIMS/codex"; chmod +x "$SHIMS/codex"
( . "$LIB"; am_resume "$tx7" ) >/dev/null 2>&1; rc7b=$?
chk "resume tras reparar → rc 0 (DONE)" "[ $rc7b -eq 0 ]"
chk "resume: destino sigue siendo propietario" "[ -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"
chk "resume: freeze del destino retirado" "[ ! -f '$AM_TEST_CROOT/chB/home/$CUSER/.codex/.move-freeze' ]"
# [Mergeador finding] el path resume→DONE DEBE limpiar las copias de credencial (snapshot + .consumed),
# igual que am_reconcile — si no, un MOVE reanudado deja secretos residuales.
chk "resume: snapshot destruido (cero copia residual)" "[ -z \"\$(ls -A '$SECRET_DIR/snapshots' 2>/dev/null)\" ]"
chk "resume: .consumed del donante destruido" "[ -z \"\$(ls '$AM_TEST_CROOT/chA/home/$CUSER/.codex/'*.consumed.* 2>/dev/null)\" ]"

# ==========================================================================
echo "== 8. Crash en frontera pre_mv (kill -9 real) → reconcile restaura al donante =="
eval "$(new_env crashpre)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "ACME-pre"
MV_LIB="$LIB" MV_ACCOUNT=acme MV_AGENT=codex MV_FROM=channel:chA MV_TO=channel:chB \
  AM_FAILPOINT=pre_mv bash "$HERE/move-runner.sh" >/dev/null 2>&1
rc8=$?
chk "el subproceso MOVE murió por el failpoint pre_mv" "[ $rc8 -ne 0 ]"
tx8="$(ls "$SECRET_DIR/journal" | sed 's/\.json//' | head -1)"
chk "destino AÚN sin auth final (pre-commit)" "[ ! -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"
( . "$LIB"; am_resume "$tx8" ) >/dev/null 2>&1
chk "reconcile: donante RESTAURADO" "[ -f '$(auth_path "$AM_TEST_CROOT" chA codex)' ]"
chk "reconcile: donante con contenido correcto" "[ \"\$(cat '$(auth_path "$AM_TEST_CROOT" chA codex)')\" = 'ACME-pre' ]"
chk "reconcile: journal ABORTED" "grep -q '\"fase\": \"ABORTED\"' '$SECRET_DIR/journal/$tx8.json'"
chk "reconcile: freezes retirados tras restaurar" "[ ! -f '$AM_TEST_CROOT/chA/home/$CUSER/.codex/.move-freeze' ]"

# ==========================================================================
echo "== 9. Crash en frontera post_mv (kill -9 real) → reconcile COMMIT hacia adelante (no restaura) =="
eval "$(new_env crashpost)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "ACME-post"
MV_LIB="$LIB" MV_ACCOUNT=acme MV_AGENT=codex MV_FROM=channel:chA MV_TO=channel:chB \
  AM_FAILPOINT=post_mv bash "$HERE/move-runner.sh" >/dev/null 2>&1
tx9="$(ls "$SECRET_DIR/journal" | sed 's/\.json//' | head -1)"
chk "destino YA tiene auth (mv hecho antes del kill)" "[ -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"
( . "$LIB"; am_resume "$tx9" ) >/dev/null 2>&1
chk "reconcile: destino ES propietario (digest esperado → commit)" "[ -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"
chk "reconcile: donante NO restaurado" "[ ! -f '$(auth_path "$AM_TEST_CROOT" chA codex)' ]"
chk "reconcile: journal cerrado (DONE)" "grep -q '\"fase\": \"DONE\"' '$SECRET_DIR/journal/$tx9.json'"

# ==========================================================================
echo "== 10. fsync fallido en el snapshot → ABORTA sin cleanup, donante intacto =="
eval "$(new_env fsync)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
seed_channel_auth "$AM_TEST_CROOT" chA codex "ACME-fsync"
( . "$LIB"; AM_FAIL_FSYNC="snapshots" am_move acme codex channel:chA channel:chB ) >/dev/null 2>&1; rc10=$?
chk "MOVE aborta con rc≠0 ante fsync fallido del snapshot" "[ $rc10 -ne 0 ]"
chk "donante INTACTO (origen no retirado)" "[ \"\$(cat '$(auth_path "$AM_TEST_CROOT" chA codex)')\" = 'ACME-fsync' ]"
chk "destino sin auth" "[ ! -f '$(auth_path "$AM_TEST_CROOT" chB codex)' ]"

# ==========================================================================
echo "== 11. Dos MOVE concurrentes al MISMO destino → el segundo se rechaza por lock =="
eval "$(new_env concurrent)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT
# Un holder mantiene el lock del destino; el MOVE hacia ese destino debe fallar al adquirir locks.
# Señal de readiness (NO un sleep fijo, que en CI cargado falsea el caso): el holder toca $ready
# SOLO tras adquirir el flock; el test espera por ese fichero antes de disparar el MOVE.
ready="$WORK/holder.ready.$RANDOM"
( . "$LIB"; am_acquire_locks "channel:chDEST" >/dev/null && touch "$ready"; sleep 5 ) &
holder=$!
for _ in $(seq 1 100); do [ -f "$ready" ] && break; sleep 0.1; done
[ -f "$ready" ] || bad "test 11: el holder no adquirió el lock del destino a tiempo (readiness)"
seed_channel_auth "$AM_TEST_CROOT" chSRC codex "X"
( . "$LIB"; am_move acme codex channel:chSRC channel:chDEST ) >/dev/null 2>&1; rc11=$?
chk "segundo MOVE al destino bloqueado (lock del destino ocupado)" "[ $rc11 -ne 0 ]"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

# ==========================================================================
echo "== 12. Bash syntax de los scripts nuevos/tocados =="
for f in auth-move-lib.sh auth-move.sh refresh-codex-auth.sh refresh-claude-auth.sh 02-golden.sh \
         00-config.sh provision.sh 03-clone.sh verify.sh validate-manifest.sh lib.sh \
         channel-profiles.sh 00-intake.sh apply-renderer.sh; do
  chk "bash -n $f" "bash -n '$SCRIPTS/$f'"
done

# ==========================================================================
echo "== 13. validate-manifest.sh — predicados puros del validador de manifiestos (TAL-2296) =="
( export VM_NO_MAIN=1; . "$SCRIPTS/validate-manifest.sh"
  MF="$WORK/mf.$RANDOM"
  # Gramática REAL del manifiesto del motor: TF_REPO_URL (no TF_REPO) y valores CITADOS.
  printf 'TF_PROJECT="acme"\nTF_REPO_URL="https://github.com/org/repo.git"\n# comentario\nK1=v1\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = OK ]                                 || exit 1   # válido base (valores citados)
  [ "$(vm_validate "$MF" acme https://github.com/org/repo.git K1)" = OK ]  || exit 2   # coincidencias (tras des-citar) + require ok
  [ "$(vm_validate "$MF" otro "" "")" = "ABORT:project-mismatch" ]         || exit 3
  [ "$(vm_validate "$MF" "" https://otro/x.git "")" = "ABORT:repo-mismatch" ] || exit 4
  [ "$(vm_validate "$MF" "" "" K9)" = "ABORT:falta K9" ]                   || exit 5   # require ausente
  # des-citado de vm_get: comillas dobles y simples
  [ "$(vm_get "$MF" TF_PROJECT)" = acme ]                                  || exit 14
  printf "TF_PROJECT='acme'\nTF_REPO_URL='u'\n" > "$MF"
  [ "$(vm_get "$MF" TF_PROJECT)" = acme ]                                  || exit 15  # comilla simple
  printf 'TF_PROJECT="acme"\nTF_REPO_URL="u"\nK1=a\nK1=b\n' > "$MF"
  case "$(vm_validate "$MF" "" "" "")" in "ABORT:duplicado"*) ;; *) exit 6;; esac       # clave duplicada → rechazo
  printf 'TF_PROJECT="acme"\nTF_REPO_URL="u"\nlinea suelta sin igual\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = "ABORT:malformado" ]                 || exit 7
  # [re-fix #921/F5 FALSO POSITIVO] Las claves con minúscula en el sufijo SON válidas: el manifiesto real
  # usa TF_GATE_CMD_typecheck / TF_GATE_CMD_db_guards (gate-id en minúscula). Deben CONTAR como clave.
  printf 'TF_PROJECT="acme"\nTF_REPO_URL="u"\nTF_GATE_CMD_typecheck="npm run typecheck"\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = OK ]                                 || exit 17
  [ "$(vm_keys "$MF" | grep -cx TF_GATE_CMD_typecheck)" = 1 ]              || exit 18
  printf 'TF_REPO_URL="u"\nK1=v\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = "ABORT:falta TF_PROJECT" ]           || exit 8   # TF_PROJECT siempre requerida
  printf 'TF_PROJECT="acme"\nK1=v\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = "ABORT:falta TF_REPO_URL" ]          || exit 16  # TF_REPO_URL siempre requerida
  [ "$(vm_validate "$WORK/no-existe.$RANDOM" "" "" "")" = "ABORT:no-legible" ] || exit 9
  printf 'TF_PROJECT=\nTF_REPO_URL="u"\n' > "$MF"
  [ "$(vm_validate "$MF" "" "" "")" = "ABORT:falta TF_PROJECT" ]           || exit 10  # valor vacío no cuenta como presente
  printf 'A=1\nB=2\nA=3\n' > "$MF"
  [ "$(vm_dupes "$MF")" = A ]                                              || exit 11
  [ "$(vm_keys "$MF" | paste -sd, -)" = "A,B,A" ]                          || exit 12
  [ "$(vm_get "$MF" A)" = 1 ]                                              || exit 13  # PRIMERA aparición
  rm -f "$MF"; exit 0 )
chk "validate-manifest: predicados puros (real-grammar TF_REPO_URL + des-citado + dup/malformado/falta/orden)" "[ $? -eq 0 ]"
# Smoke contra el manifiesto REAL del motor si está presente en este entorno (no-op en canales sin él).
_REALMF="$HOME/Talent Engine/Talent Factory/manifiestos/academy.conf"
if [ -r "$_REALMF" ]; then
  ( export VM_NO_MAIN=1; . "$SCRIPTS/validate-manifest.sh"
    [ "$(vm_validate "$_REALMF" academy "" "TF_GATE_IDS,TF_LINEAR_TEAM_KEY")" = OK ] )
  chk "validate-manifest: acepta el academy.conf REAL (TF_REPO_URL + citado + require de gates/linear)" "[ $? -eq 0 ]"
fi

# ==========================================================================
echo "== 14. Guardas estáticas de las correcciones del code-audit P3a (sin Incus) =="
# Mayor 4 (+ re-fix bounce #921): el gestor declarado ausente ABORTA, PERO la ausencia se señala por
# MARCADOR (ABSENT:) — NO por un exit code sentinel que colisionaría con el del install (CR major).
# Guarda estructural: hay marcador ABSENT, NINGÚN 'exit <n>' como sentinel, y el fallo del install va a
# aviso transitorio (tc_info), no a tc_die (que queda SOLO para ausencia/salida inesperada).
chk "02-golden: PM ausente por MARCADOR (sin colisión de exit codes con el install; CR #921)" \
  "grep -q 'ABSENT:' '$SCRIPTS/02-golden.sh' && ! grep -qE '\\|\\| exit [0-9]' '$SCRIPTS/02-golden.sh' && ! grep -q 'fallback npm' '$SCRIPTS/02-golden.sh' && grep -q \"install de dependencias con .* falló (transitorio\" '$SCRIPTS/02-golden.sh'"
# Mayor 3: 02-golden y verify leen AMBOS TF_REPO_DIR (misma ruta de clonado/verificación).
chk "TF_REPO_DIR coherente: 02-golden usa el override y verify lo lee" \
  "grep -q 'TF_DIR_C=\"\${TF_REPO_DIR:-' '$SCRIPTS/02-golden.sh' && grep -q 'TF_REPO_DIR' '$SCRIPTS/verify.sh'"
# Mayor 2 (r1)/Mayor 1 (r2): --local-only aísla INCONDICIONAL + fail-closed (no condicionado a 'ip -4';
# aborta si el estado persiste o el servicio sigue habilitado — daemon parado con estado no pasa).
chk "03-clone: local-only aísla incondicional + fail-closed (aborta si persiste estado/servicio)" \
  "grep -q 'tailscale down' '$SCRIPTS/03-clone.sh' && grep -q 'tailscaled.state PERSISTE' '$SCRIPTS/03-clone.sh' && grep -q 'sigue HABILITADO' '$SCRIPTS/03-clone.sh'"
chk "verify: local-only AFIRMA aislamiento (no solo SKIP)" \
  "grep -q 'AISLADO del tailnet' '$SCRIPTS/verify.sh'"
# [TAL-2630 code-gate r3] la reconciliación captura el rc de tc_expected_channel_set ANTES del `for`
# (un `for ch in \$(tc_expected_channel_set)` DESCARTA el exit code → reconciliación omitida en silencio).
chk "verify: reconciliación captura rc del conjunto esperado (no lo pierde en el for)" \
  "grep -q 'expected_set=\"\$(tc_expected_channel_set)\"; expected_rc=\$?' '$SCRIPTS/verify.sh' && grep -q 'no se pudo computar el conjunto esperado' '$SCRIPTS/verify.sh'"
# [TAL-2630 code-gate r3] ni el seeder ni la config anuncian ya un "default produccion" inexistente.
chk "sin 'default produccion' obsoleto en channel-profiles.sh / 00-config.sh" \
  "! grep -qiE 'produccion \\(default\\)|default.*produccion|default → produccion' '$SCRIPTS/channel-profiles.sh' '$SCRIPTS/00-config.sh'"
# Mayor 2 (r2): TF_REPO_DIR del motor comillado (rutas con espacios, regla 12 — el manifiesto real trae espacios).
chk "02-golden: dir del motor comillado para espacios (\$HOME/...)" \
  "grep -qF 'git clone \"\$AUTHURL\" \"\$HOME/' '$SCRIPTS/02-golden.sh' && grep -qF 'git -C \"\$HOME/' '$SCRIPTS/02-golden.sh'"
# Sugerencia: hard-check anti-credencial repetido al FINAL del golden (post-deps).
chk "02-golden: hard-check anti-credencial repetido en [9/9] (post-deps)" \
  "[ \"\$(grep -c 'apareció una credencial de agente en el golden' '$SCRIPTS/02-golden.sh')\" -ge 2 ]"
# provision.sh: --force-golden mapea a --force de 02-golden; --local-only y --machine cableados.
chk "provision: --force-golden→--force · --local-only · --machine cableados" \
  "grep -q 'FORCE_GOLDEN=yes.*bash .*script.* --force\|--force$' '$SCRIPTS/provision.sh' && grep -q 'TC_LOCAL_ONLY=yes' '$SCRIPTS/provision.sh' && grep -q 'FLAG_MACHINE' '$SCRIPTS/provision.sh'"
# [F6/re-fix #921] Detección de Playwright ALINEADA entre el paso root (install-deps) y el paso usuario
# (install): AMBOS exigen la dep exacta ('@playwright/test' o \"playwright\"), no la subcadena suelta —
# si no, uno instala navegadores y el otro no las libs de sistema → navegadores rotos por CoW. Ambas
# líneas deben referenciar @playwright/test (conteo == 2). Un mutante que deje 'grep -q playwright' baja a 1.
chk "02-golden: detección Playwright alineada (root+usuario exigen dep exacta)" \
  "[ \"\$(grep -c '@playwright/test' '$SCRIPTS/02-golden.sh')\" -eq 2 ]"

# ==========================================================================
echo "== 15. Pruebas CONDUCTUALES del aislamiento local-only (03-clone sourceable, fakes) =="
# (A) tc_clone_main ejerce el LOOP con fakes: canal 1 PREEXISTENTE (incus info→0) y canal 2 CLON NUEVO
#     (incus info→1); en local-only AMBAS ramas deben invocar _tc_local_isolate (recorder). No basta grep.
( export TC_NO_MAIN=1
  . "$SCRIPTS/03-clone.sh" >/dev/null 2>&1
  set +e +u +o pipefail 2>/dev/null || true
  REC="$WORK/isolated.$RANDOM"; : > "$REC"
  incus() { case "$1 $2" in "info ch1") return 0;; "info ch2") return 1;;
    "list ^golden$"|"list ^ch1$") echo RUNNING;; "list ^ch2$") echo STOPPED;; esac; return 0; }
  tc_wait_container() { return 0; }; tc_channel_name() { echo "ch$1"; }; tc_channel_port() { echo "80$1"; }
  tc_say() { :; }; tc_info() { :; }; tc_die() { return 1; }
  _tc_local_isolate() { echo "$1" >> "$REC"; }   # recorder: prueba que la rama LO invoca
  # shellcheck disable=SC2034  # consumidas como globals por tc_clone_main (03-clone.sh sourceado)
  MACHINE_NUM=9 COUNT=2 GOLDEN=golden PREFIX=vibe- TC_LOCAL_ONLY=yes
  tc_clone_main >/dev/null 2>&1
  grep -qx ch1 "$REC" && grep -qx ch2 "$REC" && [ "$(grep -c . "$REC")" -eq 2 ] )
chk "03-clone conductual: _tc_local_isolate se invoca en AMBAS ramas (preexistente ch1 + clon nuevo ch2)" "[ $? -eq 0 ]"

( export TC_NO_MAIN=1
  . "$SCRIPTS/03-clone.sh" >/dev/null 2>&1
  POWER="$WORK/power.$RANDOM"; echo RUNNING > "$POWER"
  incus() {
    case "$1" in
      list) cat "$POWER";;
      start) [ "$(cat "$POWER")" = STOPPED ] || return 1; echo RUNNING > "$POWER";;
      stop) [ "$(cat "$POWER")" = RUNNING ] || return 1; echo STOPPED > "$POWER";;
      *) return 1;;
    esac
  }
  tc_clone_power golden STOPPED && tc_clone_power golden STOPPED &&
    tc_clone_power golden RUNNING && tc_clone_power golden RUNNING
)
chk "estado Incus: arranque y parada idempotentes con doble que rechaza repetición" "[ $? -eq 0 ]"

( export REC_BASE="$WORK/base-completa.$RANDOM"
  snippet="$(tail -3 "$SCRIPTS/02-golden.sh")"
  # Ejecutar solo el cierre real, con los clientes cerrados por funciones.
  export snippet
  tc_cuser() { return "${BASE_RC:-0}"; }
  incus() { printf '%s\n' "$*" > "$REC_BASE"; }
  export -f tc_cuser incus
  BASE_RC=1 CUSER=operador REPO_DIR=producto GOLDEN=golden bash -ec 'eval "$snippet"' >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ ! -e "$REC_BASE" ] || exit 1
  BASE_RC=0 CUSER=operador REPO_DIR=producto GOLDEN=golden bash -ec 'eval "$snippet"' >/dev/null 2>&1 || exit 1
  grep -qx 'config set golden user.fabrica.base-completa yes' "$REC_BASE"
)
chk "plantilla: marca base solo después de verificar el cierre sin fallo" "[ $? -eq 0 ]"

# (B) _tc_local_isolate REAL con fake incus: ejecuta 'systemctl disable' y es fail-closed ante estado
#     persistente / servicio habilitado / IP presente (cada uno → tc_die). Prueba el COMPORTAMIENTO, no strings.
( export TC_NO_MAIN=1
  . "$SCRIPTS/03-clone.sh" >/dev/null 2>&1
  set +e +u +o pipefail 2>/dev/null || true
  CALLS="$WORK/calls.$RANDOM"
  tc_info() { :; }; DIE=0; tc_die() { DIE=1; return 1; }
  incus() { shift 3 2>/dev/null || true; echo "$*" >> "$CALLS"
    case "$*" in
      "test ! -e /var/lib/tailscale/tailscaled.state"*) [ "${STATE_PRESENT:-0}" = 1 ] && return 1 || return 0;;
      "systemctl is-enabled tailscaled"*)               [ "${ENABLED:-0}" = 1 ] && return 0 || return 1;;
      "tailscale ip -4"*)                               [ "${HASIP:-0}" = 1 ] && return 0 || return 1;;
      *) return 0;;
    esac; }
  : > "$CALLS"; DIE=0 STATE_PRESENT=0 ENABLED=0 HASIP=0; _tc_local_isolate ch; r=$?
  grep -q 'systemctl disable --now tailscaled' "$CALLS" || exit 11      # ejecutó el disable
  [ "$r" -eq 0 ] && [ "$DIE" -eq 0 ] || exit 12                          # happy path: rc0, sin die
  DIE=0 STATE_PRESENT=1 ENABLED=0 HASIP=0; _tc_local_isolate ch >/dev/null 2>&1; [ "$DIE" -eq 1 ] || exit 13  # estado persiste → die
  DIE=0 STATE_PRESENT=0 ENABLED=1 HASIP=0; _tc_local_isolate ch >/dev/null 2>&1; [ "$DIE" -eq 1 ] || exit 14  # servicio habilitado → die
  DIE=0 STATE_PRESENT=0 ENABLED=0 HASIP=1; _tc_local_isolate ch >/dev/null 2>&1; [ "$DIE" -eq 1 ] || exit 15  # IP presente → die
  exit 0 )
chk "03-clone conductual: _tc_local_isolate ejecuta disable + fail-closed (estado/servicio/IP → tc_die)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 16. 02-golden.sh: fallback de Node resuelve a la Active LTS real (TAL-1968) =="
# Extrae el fragmento REAL de resolución de NV desde el script (ancla por contenido único, no
# duplica la lógica ni depende de números de línea) y lo ejecuta contra un repo SIN .nvmrc/engines.
( _start=$(grep -n '^NV=""$' "$SCRIPTS/02-golden.sh" | head -1 | cut -d: -f1)
  _end=$(grep -n 'Active LTS verificado' "$SCRIPTS/02-golden.sh" | head -1 | cut -d: -f1)
  [ -n "$_start" ] && [ -n "$_end" ] || { echo "anclas de extracción del fallback de Node no encontradas" >&2; exit 1; }
  RD="$WORK/nv-sin-config"; mkdir -p "$RD"
  eval "$(sed -n "${_start},${_end}p" "$SCRIPTS/02-golden.sh")"
  [ "$NV" = "24" ] || { echo "NV resolvió a '$NV', esperado 24" >&2; exit 1; }
)
chk "Node: repo sin .nvmrc/package.json → fallback real del script resuelve NV=24" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 17. 02-golden.sh: CodeRabbit CLI — arquitectura, fail-closed real, instalación (TAL-1968) =="
# Extrae el fragmento REAL (case de arquitectura + descarga + verificación sha256 + instalación),
# sustituyendo SOLO VER/SHA_X64/SHA_ARM64 por valores de prueba — la LÓGICA ejecutada es la del
# script real (curl/uname shimados), nunca una reimplementación paralela que pueda desincronizarse.
# No depende de los hashes reales pineados hoy (esos se re-verifican aparte, ver STOP-AUDIT).
_cr_start=$(grep -n '^case "\$(uname -m)" in$' "$SCRIPTS/02-golden.sh" | head -1 | cut -d: -f1)
_cr_err_line=$(grep -n 'no quedó instalado/visible' "$SCRIPTS/02-golden.sh" | head -1 | cut -d: -f1)
if [ -z "$_cr_start" ] || [ -z "$_cr_err_line" ]; then
  bad "CodeRabbit CLI: anclas de extracción no encontradas — revisa #17 en run-tests.sh"
elif [ "$(sed -n "$((_cr_err_line + 1))p" "$SCRIPTS/02-golden.sh")" != "fi'" ]; then
  bad "CodeRabbit CLI: la línea tras el error ya no es el cierre esperado del bloque — revisa #17 en run-tests.sh"
else
  CR_SNIPPET="$(sed -n "${_cr_start},${_cr_err_line}p" "$SCRIPTS/02-golden.sh"; echo 'fi')"

  # Fixture: zip real con un binario 'coderabbit' ejecutable dentro (permisos unix preservados).
  CR_FIXTURE_ZIP="$WORK/cr-fixture.zip"
  python3 - "$CR_FIXTURE_ZIP" <<'PYEOF'
import sys, zipfile
path = sys.argv[1]
with zipfile.ZipFile(path, "w") as zf:
    info = zipfile.ZipInfo("coderabbit")
    info.external_attr = 0o755 << 16
    zf.writestr(info, "#!/bin/sh\necho fixture-coderabbit-cli-0.0.0-test\n")
PYEOF
  CR_GOOD_HASH="$(sha256sum "$CR_FIXTURE_ZIP" | cut -d' ' -f1)"
  CR_WRONG_HASH="$(printf '%064d' 0)"

  _cr_run() { # $1=uname-m-fake $2=SHA_X64 $3=SHA_ARM64 $4=HOME $5=archivo-captura-url
    ( HOME="$4"; mkdir -p "$HOME"
      _CR_TEST_UNAME="$1"; _CR_URLCAP="$5"
      uname() { if [ "${1:-}" = "-m" ]; then echo "$_CR_TEST_UNAME"; else command uname "$@"; fi; }
      curl() {
        local dest="" url="" prev=""
        for a in "$@"; do [ "$prev" = "-o" ] && dest="$a"; prev="$a"; done
        for a in "$@"; do case "$a" in -*) ;; *) [ "$a" != "$dest" ] && url="$a" ;; esac; done
        printf '%s' "$url" > "$_CR_URLCAP"
        cp "$CR_FIXTURE_ZIP" "$dest"
      }
      VER="0.0.0-test"; SHA_X64="$2"; SHA_ARM64="$3"
      : "$VER" "$SHA_X64" "$SHA_ARM64"   # las consume el cuerpo real del snippet (eval de CR_SNIPPET extraído del golden); el no-op fija el uso para el linter
      set -e
      eval "$CR_SNIPPET"
    )
  }

  # (a) x64: hash correcto → éxito, URL con -linux-x64.zip, binario instalado y ejecutable
  _url_x64="$WORK/url-x64.txt"; _home_x64="$WORK/home-x64"
  _cr_run x86_64 "$CR_GOOD_HASH" "$CR_WRONG_HASH" "$_home_x64" "$_url_x64" >/dev/null 2>"$WORK/err-x64.txt"
  _rc_x64=$?
  chk "CR CLI x64: éxito con hash correcto (exit 0)" "[ $_rc_x64 -eq 0 ]"
  chk "CR CLI x64: URL de descarga selecciona -linux-x64.zip" "grep -q 'linux-x64.zip' '$_url_x64'"
  chk "CR CLI x64: binario instalado y ejecutable en \$HOME/.local/bin/coderabbit" "[ -x '$_home_x64/.local/bin/coderabbit' ]"
  chk "CR CLI x64: symlink cr apunta a coderabbit (no roto, no a otro destino)" "[ \"\$(readlink '$_home_x64/.local/bin/cr')\" = coderabbit ]"
  chk "CR CLI x64: coderabbit --version funcional" "[ -n \"\$('$_home_x64/.local/bin/coderabbit' --version)\" ]"
  chk "CR CLI x64: cr --version (vía symlink) funcional" "[ -n \"\$('$_home_x64/.local/bin/cr' --version)\" ]"

  # (b) arm64: hash correcto → éxito, URL con -linux-arm64.zip
  _url_arm64="$WORK/url-arm64.txt"; _home_arm64="$WORK/home-arm64"
  _cr_run aarch64 "$CR_WRONG_HASH" "$CR_GOOD_HASH" "$_home_arm64" "$_url_arm64" >/dev/null 2>"$WORK/err-arm64.txt"
  _rc_arm64=$?
  chk "CR CLI arm64: éxito con hash correcto (exit 0)" "[ $_rc_arm64 -eq 0 ]"
  chk "CR CLI arm64: URL de descarga selecciona -linux-arm64.zip" "grep -q 'linux-arm64.zip' '$_url_arm64'"
  chk "CR CLI arm64: binario instalado y ejecutable" "[ -x '$_home_arm64/.local/bin/coderabbit' ]"

  # (c) hash INCORRECTO → FAIL-CLOSED real: exit≠0, mensaje FAIL-CLOSED, y NADA instalado
  _url_bad="$WORK/url-bad.txt"; _home_bad="$WORK/home-bad"
  _cr_run x86_64 "$CR_WRONG_HASH" "$CR_WRONG_HASH" "$_home_bad" "$_url_bad" >/dev/null 2>"$WORK/err-bad.txt"
  _rc_bad=$?
  chk "CR CLI fail-closed: checksum incorrecto → exit≠0 (no silencioso)" "[ $_rc_bad -ne 0 ]"
  chk "CR CLI fail-closed: stderr reporta FAIL-CLOSED" "grep -q 'FAIL-CLOSED' '$WORK/err-bad.txt'"
  chk "CR CLI fail-closed: NO se instaló ningún binario" "[ ! -e '$_home_bad/.local/bin/coderabbit' ]"
fi
echo "== 16. [TAL-2630] Identidad/perfil por canal — detección de credencial EFECTIVA (fail-closed) =="
# Arnés con fake `incus` respaldado por un sandbox (CROOT/<canal> = fs del contenedor). Prueba el
# COMPORTAMIENTO de los helpers de lib.sh (no strings): identidad md5, ausencia efectiva, runner
# container-wide, scope por-fábrica, y la NO-regresión del falso positivo (checkout con creds.manifest/
# push-carril-env.sh presente y SIN credencial efectiva → PASS).
run_t16() (
  export TC_NO_AUTOLOAD=1
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib.sh"
  local B; B="$WORK/t16.$RANDOM"
  export CROOT="$B/croot"
  export SECRET_DIR="$B/secret"; mkdir -p "$SECRET_DIR/env"
  export PREFIX="vibe-channel-" MACHINE_NUM=9 COUNT=4 CUSER="vivecoder" REPO_DIR="repo" ENV_DEST=".env.local"
  export TC_MERGEADOR_CHANNELS="" TC_RUNNER_CHANNELS="" TC_CRED_SCANNER=""
  FAKE_CHANNELS=""; FAKE_LIST_FAIL=0

  # --- fake incus: list + exec con reescritura de rutas de contenedor al sandbox ---
  incus() {
    local sub="$1"; shift
    case "$sub" in
      list) [ "$FAKE_LIST_FAIL" = 1 ] && return 1; printf '%s\n' $FAKE_CHANNELS; return 0;;
      exec)
        local ch="$1"; shift; [ "${1:-}" = "--" ] && shift
        local bin="$1"; shift
        _rw() { case "$1" in /home*|/root*) printf '%s%s' "$CROOT/$ch" "$1";; *) printf '%s' "$1";; esac; }
        if [ "$bin" = sh ] || [ "$bin" = bash ]; then
          [ "$1" = "-c" ] && shift; local script="$1"; shift
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done
          "$bin" -c "$script" "${args[@]}"; return $?
        fi
        if [ "$bin" = su ]; then
          # `su - $CUSER -c '<script>' [args...]` → correr el script con HOME del sandbox del canal
          # (git config --global opera sobre $HOME/.gitconfig — fiel al efecto real, sin su).
          local suuser="" suscript=""
          while [ $# -gt 0 ]; do case "$1" in -) shift;; -c) suscript="$2"; shift 2; break;; *) suuser="$1"; shift;; esac; done
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done
          HOME="$CROOT/$ch/home/$suuser" bash -c "$suscript" "${args[@]}"; return $?
        fi
        local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done
        "$bin" "${args[@]}"; return $?;;
      *) return 2;;
    esac
  }
  mkcont()  { mkdir -p "$CROOT/$1/home/$CUSER/$REPO_DIR" "$CROOT/$1/root"; }
  cp_env()  { cp "$SECRET_DIR/env/$1.env" "$CROOT/$1/home/$CUSER/$REPO_DIR/$ENV_DEST"; }  # push fiel
  # checkout con menciones documentales (catálogo/código): NO deben contar como cred efectiva.
  seed_repo_docs() {
    local d="$CROOT/$1/home/$CUSER/$REPO_DIR/.claude/skills/talent-channels"
    mkdir -p "$d/assets" "$d/scripts"
    printf 'SUPABASE_ACCESS_TOKEN|^sbp_|no|percarril|x\nCODERABBIT_API_KEY|^cr-|no|percarril|x\nLINEAR_API_KEY|^lin_api_|no|percarril|x\n' > "$d/assets/creds.manifest"
    printf 'grep -q "^CODERABBIT_API_KEY=" "$envf"\n' > "$d/scripts/push-carril-env.sh"
    # incluso un .env.example (placeholders vacíos) no es el env operacional
    printf 'SUPABASE_ACCESS_TOKEN=\nCODERABBIT_API_KEY=\n' > "$CROOT/$1/home/$CUSER/$REPO_DIR/.env.example"
  }
  seed_cr_auth() { mkdir -p "$CROOT/$1/home/$CUSER/.coderabbit"; printf '{"type":"api_key","apiKey":"%s"}\n' "$2" > "$CROOT/$1/home/$CUSER/.coderabbit/auth.json"; }
  set_profile() { printf '%s=%s\n' "$1" "$2" >> "$SECRET_DIR/channel-profiles.list"; }
  local rc

  # (a) tc_expected_profile: mapa + overrides + default + conflictos (incl. produccion EXPLÍCITA)
  : > "$SECRET_DIR/channel-profiles.list"
  set_profile vibe-channel-91 mergeador; set_profile vibe-channel-92 runner
  [ "$(tc_expected_profile vibe-channel-91)" = mergeador ] || { echo "a1"; return 1; }
  [ "$(tc_expected_profile vibe-channel-92)" = runner ]    || { echo "a2"; return 1; }
  # [BLOQUEANTE #3] sin declaración → `undeclared` (NO `produccion`): un runner sin declarar no debe
  # colarse por el perfil producción (lenient con gh/claude/codex) → el llamador lo FALLA cerrado.
  [ "$(tc_expected_profile vibe-channel-93)" = undeclared ] || { echo "a3-sin-declarar-no-fail-closed"; return 1; }
  ( export TC_RUNNER_CHANNELS="vibe-channel-91"; [ "$(tc_expected_profile vibe-channel-91)" = invalid ] ) || { echo "a4-conflicto"; return 1; }
  ( export TC_MERGEADOR_CHANNELS="vibe-channel-93"; [ "$(tc_expected_profile vibe-channel-93)" = mergeador ] ) || { echo "a5-override-sobre-undeclared"; return 1; }
  # [BLOQUEANTE #1] produccion DECLARADA EXPLÍCITA participa en el conflicto (no se reclasifica en silencio)
  set_profile vibe-channel-97 produccion
  [ "$(tc_expected_profile vibe-channel-97)" = produccion ] || { echo "a6-prod-explicito"; return 1; }
  ( export TC_MERGEADOR_CHANNELS="vibe-channel-97"; [ "$(tc_expected_profile vibe-channel-97)" = invalid ] ) || { echo "a7-prod-explicito-conflicto"; return 1; }
  printf 'vibe-channel-94=banana\n' >> "$SECRET_DIR/channel-profiles.list"
  [ "$(tc_expected_profile vibe-channel-94)" = invalid ] || { echo "a8-perfil-corrupto"; return 1; }

  # (b) PRODUCCIÓN limpio CON checkout de docs presente → PASS (no falso positivo, BLOQUEANTE r4)
  printf 'GITHUB_TOKEN=ghp_abc123\nLINEAR_API_KEY=lin_api_xyz\n' > "$SECRET_DIR/env/vibe-channel-93.env"
  mkcont vibe-channel-93; cp_env vibe-channel-93; seed_repo_docs vibe-channel-93
  tc_verify_env_identity vibe-channel-93 || { echo "b-identidad"; return 1; }
  tc_prod_no_sensitive  vibe-channel-93 || { echo "b-prod-falso-positivo"; return 1; }

  # (c) PRODUCCIÓN + sbp_ EFECTIVA en el env operacional → FALLO (caso central)
  printf 'GITHUB_TOKEN=ghp_abc\nSUPABASE_ACCESS_TOKEN=sbp_leaked000\n' > "$SECRET_DIR/env/vibe-channel-93.env"
  cp_env vibe-channel-93
  tc_prod_no_sensitive vibe-channel-93 && { echo "c-no-detecto-sbp"; return 1; }
  # [BLOQUEANTE #5] valor ENTRE COMILLAS no debe evadir la detección
  # NO cambiar este literal DUMMY sin retirar el # gitleaks:allow de esta línea (allow por-LÍNEA, no por valor). Refs TAL-3812.
  printf 'GITHUB_TOKEN=ghp_abc\nSUPABASE_ACCESS_TOKEN="sbp_quoted01"\n' > "$SECRET_DIR/env/vibe-channel-93.env"; cp_env vibe-channel-93 # gitleaks:allow
  grep -q 'sbp_quoted01' "$SECRET_DIR/env/vibe-channel-93.env" || { echo "c2-fixture-drift"; return 1; }
  tc_prod_no_sensitive vibe-channel-93 && { echo "c2-comillas-evaden"; return 1; }
  # [BLOQUEANTE #3] sbp_ efectiva en OTRO home (p. ej. /home/runner) de un canal producción → FALLO (container-wide)
  printf 'GITHUB_TOKEN=ghp_abc\nLINEAR_API_KEY=lin_api_x\n' > "$SECRET_DIR/env/vibe-channel-93.env"; cp_env vibe-channel-93
  mkdir -p "$CROOT/vibe-channel-93/home/runner/$REPO_DIR"; printf 'SUPABASE_ACCESS_TOKEN=sbp_otrohome\n' > "$CROOT/vibe-channel-93/home/runner/$REPO_DIR/$ENV_DEST"
  tc_prod_no_sensitive vibe-channel-93 && { echo "c3-otro-home-no-detectado"; return 1; }
  rm -rf "$CROOT/vibe-channel-93/home/runner"

  # (d) PRODUCCIÓN + sesión CR canónica presente (bajo /home/$CUSER) → FALLO
  printf 'GITHUB_TOKEN=ghp_abc\n' > "$SECRET_DIR/env/vibe-channel-93.env"; cp_env vibe-channel-93
  seed_cr_auth vibe-channel-93 "cr-should-not-be-here"
  tc_prod_no_sensitive vibe-channel-93 && { echo "d-no-detecto-cr"; return 1; }
  rm -rf "$CROOT/vibe-channel-93/home/$CUSER/.coderabbit"
  # tras limpiar, PRODUCCIÓN vuelve a estar limpio → PASS (identidad+ausencia)
  tc_prod_no_sensitive vibe-channel-93 || { echo "d2-tras-limpiar"; return 1; }

  # (e) identidad env SIEMPRE evaluable, both-ways fail-closed
  # (e1) container ≠ escrow (push stale) → FALLO
  printf 'GITHUB_TOKEN=ghp_abc\n' > "$CROOT/vibe-channel-93/home/$CUSER/$REPO_DIR/$ENV_DEST"
  printf 'GITHUB_TOKEN=ghp_DIFERENTE\n' > "$SECRET_DIR/env/vibe-channel-93.env"
  tc_verify_env_identity vibe-channel-93 && { echo "e1-identidad-no-falla"; return 1; }
  # (e2) SIN escrow y SIN env en el contenedor → PASS (nada que empujar, consistente)
  mkdir -p "$CROOT/vibe-channel-96/home/$CUSER/$REPO_DIR"; rm -f "$SECRET_DIR/env/vibe-channel-96.env"
  tc_verify_env_identity vibe-channel-96 || { echo "e2-sin-escrow-sin-env-deberia-pasar"; return 1; }
  # (e3) escrow presente pero el contenedor NO tiene env (push no ocurrió) → FALLO
  printf 'GITHUB_TOKEN=ghp_x\n' > "$SECRET_DIR/env/vibe-channel-96.env"
  tc_verify_env_identity vibe-channel-96 && { echo "e3-escrow-sin-env-no-falla"; return 1; }
  # (e4) SIN escrow pero el contenedor SÍ trae un env inesperado → FALLO
  rm -f "$SECRET_DIR/env/vibe-channel-96.env"; printf 'X=1\n' > "$CROOT/vibe-channel-96/home/$CUSER/$REPO_DIR/$ENV_DEST"
  tc_verify_env_identity vibe-channel-96 && { echo "e4-env-inesperado-no-falla"; return 1; }

  # (e5-e8) IDENTIDAD GIT por canal (TAL-3473): expansión {channel} exacta, fail-closed
  export TF_CHANNEL_GIT_NAME_TMPL="{channel}" TF_CHANNEL_GIT_EMAIL_TMPL="{channel}@channels.example.test"
  # (e5) canal con identidad del HOST (la clase medida en producción) → FALLO
  ( HOME="$CROOT/vibe-channel-93/home/$CUSER" git config --global user.name "Host Owner"
    HOME="$CROOT/vibe-channel-93/home/$CUSER" git config --global user.email "founders@example.test" )
  tc_verify_git_identity vibe-channel-93 && { echo "e5-email-del-host-no-falla"; return 1; }
  # (e6) canal con la expansión EXACTA → PASS
  ( HOME="$CROOT/vibe-channel-93/home/$CUSER" git config --global user.name "vibe-channel-93"
    HOME="$CROOT/vibe-channel-93/home/$CUSER" git config --global user.email "vibe-channel-93@channels.example.test" )
  tc_verify_git_identity vibe-channel-93 || { echo "e6-identidad-canonica-no-pasa"; return 1; }
  # (e7) name correcto pero email de OTRO canal → FALLO (igualdad de AMBOS)
  ( HOME="$CROOT/vibe-channel-93/home/$CUSER" git config --global user.email "vibe-channel-94@channels.example.test" )
  tc_verify_git_identity vibe-channel-93 && { echo "e7-email-cruzado-no-falla"; return 1; }
  # (e8) sin plantillas definidas → FALLO fail-closed (no hay contrato que verificar)
  ( unset TF_CHANNEL_GIT_NAME_TMPL TF_CHANNEL_GIT_EMAIL_TMPL
    tc_verify_git_identity vibe-channel-93 ) && { echo "e8-sin-plantillas-no-falla"; return 1; }

  # (f) MERGEADOR: identidad CR ok + sbp_ presente → PASS; apiKey md5 distinto → FALLO
  # NO cambiar este literal DUMMY sin retirar el # gitleaks:allow de esta línea (allow por-LÍNEA, no por valor). Refs TAL-3812.
  printf 'GITHUB_TOKEN=ghp_m\nSUPABASE_ACCESS_TOKEN=sbp_prod01\nCODERABBIT_API_KEY=cr-key-EXACTA-123\n' > "$SECRET_DIR/env/vibe-channel-91.env" # gitleaks:allow
  grep -q 'cr-key-EXACTA-123' "$SECRET_DIR/env/vibe-channel-91.env" || { echo "f-fixture-drift"; return 1; }
  mkcont vibe-channel-91; cp_env vibe-channel-91; seed_repo_docs vibe-channel-91
  seed_cr_auth vibe-channel-91 "cr-key-EXACTA-123"
  tc_verify_env_identity vibe-channel-91 || { echo "f-id-env"; return 1; }
  tc_verify_cr_identity  vibe-channel-91 || { echo "f-id-cr"; return 1; }
  tc_mergeador_has_sbp   vibe-channel-91 || { echo "f-sbp"; return 1; }
  seed_cr_auth vibe-channel-91 "cr-key-OTRA-999"
  tc_verify_cr_identity vibe-channel-91 && { echo "f-cr-rotada-no-falla"; return 1; }

  # (g) RUNNER: CERO credencial en TODO el contenedor. limpio (con docs) → PASS; artefacto de auth o
  # CUALQUIER asignación en un .env.local bajo /home/runner → FALLO (container-wide, BLOQUEANTE #3)
  mkdir -p "$CROOT/vibe-channel-85/home/runner/$REPO_DIR/.claude" "$CROOT/vibe-channel-85/root"
  printf 'sbp_ y lin_api_ y CODERABBIT_API_KEY mencionados en docs\n' > "$CROOT/vibe-channel-85/home/runner/$REPO_DIR/.claude/notes.md"
  tc_runner_clean vibe-channel-85 || { echo "g-runner-falso-positivo"; return 1; }
  mkdir -p "$CROOT/vibe-channel-85/home/runner/.coderabbit"; printf '{"apiKey":"cr-x"}\n' > "$CROOT/vibe-channel-85/home/runner/.coderabbit/auth.json"
  tc_runner_clean vibe-channel-85 && { echo "g-runner-no-detecta-home-runner"; return 1; }
  rm -f "$CROOT/vibe-channel-85/home/runner/.coderabbit/auth.json"
  # CUALQUIER asignación (incluso benigna) en un .env.local → FALLO (un runner no debe tener env operacional)
  printf 'FOO=bar\n' > "$CROOT/vibe-channel-85/home/runner/$REPO_DIR/$ENV_DEST"
  tc_runner_clean vibe-channel-85 && { echo "g-runner-envlocal-benigno-no-falla"; return 1; }
  rm -f "$CROOT/vibe-channel-85/home/runner/$REPO_DIR/$ENV_DEST"
  tc_runner_clean vibe-channel-85 || { echo "g-runner-tras-limpiar"; return 1; }

  # (h) fail-closed: error de inspección (incus rc>1) NUNCA se trata como "ausente"/"limpio".
  ( incus() { return 3; }; tc_prod_no_sensitive vibe-channel-93 ) && { echo "h-prod-no-fail-closed"; return 1; }
  ( incus() { return 3; }; tc_runner_clean vibe-channel-85 )     && { echo "h-runner-no-fail-closed"; return 1; }
  ( incus() { return 3; }; tc_verify_env_identity vibe-channel-93 ) && { echo "h-identidad-no-fail-closed"; return 1; }
  ( incus() { return 3; }; tc_verify_cr_identity vibe-channel-91 )  && { echo "h-cr-no-fail-closed"; return 1; }
  ( incus() { return 3; }; tc_mergeador_has_sbp vibe-channel-91 )   && { echo "h-sbp-no-fail-closed"; return 1; }

  # (i) enumeración por-fábrica (M) + M1: solo vibe-channel-9x; otro MACHINE_NUM fuera de scope.
  FAKE_CHANNELS="vibe-channel-91 vibe-channel-92 vibe-channel-95 vibe-channel-51 golden"
  local real; real="$(tc_list_real_channels)"
  printf '%s\n' "$real" | grep -qx vibe-channel-95 || { echo "i-m1-fuera-de-count"; return 1; }  # 95 > COUNT: se incluye
  printf '%s\n' "$real" | grep -qx vibe-channel-51 && { echo "i-cruza-fabrica"; return 1; }        # otra fábrica: fuera
  printf '%s\n' "$real" | grep -qx golden && { echo "i-incluye-golden"; return 1; }
  # incus list falla → fail-closed
  ( FAKE_LIST_FAIL=1; tc_list_real_channels ) && { echo "i-list-no-fail-closed"; return 1; }
  # MACHINE_NUM vacío → fail-closed
  ( export MACHINE_NUM=""; tc_list_real_channels ) && { echo "i-machinenum-vacio"; return 1; }

  # (j) conjunto esperado (reconciliación): incluye escrow + mapa, acotado a la fábrica
  local exp; exp="$(tc_expected_channel_set)"
  printf '%s\n' "$exp" | grep -qx vibe-channel-91 || { echo "j-falta-91"; return 1; }
  printf '%s\n' "$exp" | grep -qx vibe-channel-51 && { echo "j-incluye-otra-fabrica"; return 1; }

  # (k) [BLOQUEANTE #2] ENV_DEST con RUTA (monorepo, p. ej. apps/web/.env.local): el barrido usa
  # -path (no -name), así que un sbp_ en esa ruta SÍ se detecta (con -name daría PASS con credencial).
  ( export ENV_DEST="apps/web/.env.local"
    mkdir -p "$CROOT/vibe-channel-98/home/$CUSER/$REPO_DIR/apps/web" "$CROOT/vibe-channel-98/root"
    printf 'SUPABASE_ACCESS_TOKEN=sbp_monorepo\n' > "$CROOT/vibe-channel-98/home/$CUSER/$REPO_DIR/apps/web/.env.local"
    tc_prod_no_sensitive vibe-channel-98 && exit 1   # debe FALLAR (detecta el env anidado)
    exit 0 ) || { echo "k-env_dest-con-ruta-no-detectado"; return 1; }

  # (l) [BLOQUEANTE #4] grep de scope con error (regex/PREFIX inválido) → tc_list_real_channels FALLA
  # cerrado (no "enumeración vacía exitosa"). Forzamos un error de grep con un PREFIX de regex roto.
  ( export PREFIX='('; FAKE_CHANNELS="vibe-channel-91"; tc_list_real_channels ) 2>/dev/null && { echo "l-grep-error-no-fail-closed"; return 1; }
  return 0
)
run_t16; chk "identidad/perfil por canal: detección efectiva, runner container-wide, scope fábrica, no-falso-positivo, fail-closed" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 17. [TAL-2630] Rollout: channel-profiles.sh idempotente + smoke post-apply (verify VERDE) =="
# (A) channel-profiles.sh set/unset/list idempotente (sin incus real).
run_t17a() (
  local B; B="$WORK/t17a.$RANDOM"
  export SECRET_DIR="$B/secret"
  SUDO_USER="$(id -un)"
  export SUDO_USER HOME_OVERRIDE=""
  export TC_INVOKE_CWD="$B"; mkdir -p "$B"
  # 00-config resuelve identidad host (usa SUDO_USER si root); en tests no somos root → usa USER/HOME.
  bash "$SCRIPTS/channel-profiles.sh" set vibe-channel-91 mergeador >/dev/null 2>&1 || return 1
  bash "$SCRIPTS/channel-profiles.sh" set vibe-channel-91 mergeador >/dev/null 2>&1 || return 1   # idempotente
  [ "$(grep -c '^vibe-channel-91=' "$SECRET_DIR/channel-profiles.list")" -eq 1 ] || return 2       # sin duplicar
  bash "$SCRIPTS/channel-profiles.sh" set vibe-channel-91 runner >/dev/null 2>&1 || return 3        # actualiza
  [ "$(grep -c '^vibe-channel-91=' "$SECRET_DIR/channel-profiles.list")" -eq 1 ] || return 4
  grep -qx 'vibe-channel-91=runner' "$SECRET_DIR/channel-profiles.list" || return 5
  bash "$SCRIPTS/channel-profiles.sh" set vibe-channel-91 banana >/dev/null 2>&1 && return 6        # perfil inválido → rechazo
  bash "$SCRIPTS/channel-profiles.sh" unset vibe-channel-91 >/dev/null 2>&1 || return 7
  grep -q '^vibe-channel-91=' "$SECRET_DIR/channel-profiles.list" && return 8
  # [BLOQUEANTE #1] el rollout lo invoca DIRECTAMENTE (no vía `bash`): exige bit +x + shebang.
  [ -x "$SCRIPTS/channel-profiles.sh" ] || return 9
  "$SCRIPTS/channel-profiles.sh" set vibe-channel-92 runner >/dev/null 2>&1 || return 10   # ejecución directa
  grep -qx 'vibe-channel-92=runner' "$SECRET_DIR/channel-profiles.list" || return 11
  return 0
)
run_t17a; chk "channel-profiles.sh set/unset idempotente + rechazo de perfil inválido" "[ $? -eq 0 ]"

# (B) Smoke post-apply: mapa sembrado (91-94 mergeador, 85-88 runner) + contenedores con checkout de
#     docs y credenciales EFECTIVAS correctas por perfil → el pase de verify.sh queda VERDE (bad=0).
run_t17b() (
  export TC_NO_AUTOLOAD=1
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib.sh"
  local B; B="$WORK/t17b.$RANDOM"
  export CROOT="$B/croot" SECRET_DIR="$B/secret"; mkdir -p "$SECRET_DIR/env"
  export PREFIX="vibe-channel-" MACHINE_NUM=9 COUNT=4 CUSER="vivecoder" REPO_DIR="repo" ENV_DEST=".env.local"
  export TC_MERGEADOR_CHANNELS="" TC_RUNNER_CHANNELS="" TC_CRED_SCANNER=""
  FAKE_CHANNELS="vibe-channel-91 vibe-channel-92 vibe-channel-93 vibe-channel-94"; FAKE_LIST_FAIL=0
  incus() {
    local sub="$1"; shift
    case "$sub" in
      list) [ "$FAKE_LIST_FAIL" = 1 ] && return 1; printf '%s\n' $FAKE_CHANNELS; return 0;;
      exec)
        local ch="$1"; shift; [ "${1:-}" = "--" ] && shift; local bin="$1"; shift
        _rw() { case "$1" in /home*|/root*) printf '%s%s' "$CROOT/$ch" "$1";; *) printf '%s' "$1";; esac; }
        if [ "$bin" = sh ] || [ "$bin" = bash ]; then [ "$1" = "-c" ] && shift; local script="$1"; shift
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" -c "$script" "${args[@]}"; return $?; fi
        if [ "$bin" = su ]; then
          local suuser="" suscript=""
          while [ $# -gt 0 ]; do case "$1" in -) shift;; -c) suscript="$2"; shift 2; break;; *) suuser="$1"; shift;; esac; done
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done
          HOME="$CROOT/$ch/home/$suuser" bash -c "$suscript" "${args[@]}"; return $?
        fi
        local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" "${args[@]}"; return $?;;
      *) return 2;;
    esac
  }
  # Identidad git por canal (TAL-3473): el rollout post-apply deja la identidad canónica sembrada —
  # el smoke la replica (plantillas + gitconfig expandido por canal) para que verify quede VERDE.
  export TF_CHANNEL_GIT_NAME_TMPL="{channel}" TF_CHANNEL_GIT_EMAIL_TMPL="{channel}@channels.example.test"
  # mapa sembrado por el rollout
  : > "$SECRET_DIR/channel-profiles.list"
  printf 'vibe-channel-91=mergeador\nvibe-channel-92=mergeador\nvibe-channel-93=produccion\nvibe-channel-94=produccion\n' >> "$SECRET_DIR/channel-profiles.list"
  seed_docs() { local d="$CROOT/$1/home/$CUSER/$REPO_DIR/.claude"; mkdir -p "$d"; printf 'sbp_ cr- lin_api_ (docs)\n' > "$d/notes.md"; }
  # mergeador 91/92: env con sbp_+CR + auth.json coincidente
  for ch in vibe-channel-91 vibe-channel-92; do
    mkdir -p "$CROOT/$ch/home/$CUSER/$REPO_DIR" "$CROOT/$ch/root"; seed_docs "$ch"
    printf 'GITHUB_TOKEN=ghp_m\nSUPABASE_ACCESS_TOKEN=sbp_ok01\nCODERABBIT_API_KEY=cr-abc123def\n' > "$SECRET_DIR/env/$ch.env"
    cp "$SECRET_DIR/env/$ch.env" "$CROOT/$ch/home/$CUSER/$REPO_DIR/$ENV_DEST"
    mkdir -p "$CROOT/$ch/home/$CUSER/.coderabbit"; printf '{"type":"api_key","apiKey":"cr-abc123def"}\n' > "$CROOT/$ch/home/$CUSER/.coderabbit/auth.json"
    HOME="$CROOT/$ch/home/$CUSER" git config --global user.name "$ch"
    HOME="$CROOT/$ch/home/$CUSER" git config --global user.email "$ch@channels.example.test"
  done
  # produccion 93/94: env sin sbp_/CR, con docs
  for ch in vibe-channel-93 vibe-channel-94; do
    mkdir -p "$CROOT/$ch/home/$CUSER/$REPO_DIR" "$CROOT/$ch/root"; seed_docs "$ch"
    printf 'GITHUB_TOKEN=ghp_p\nLINEAR_API_KEY=lin_api_p\n' > "$SECRET_DIR/env/$ch.env"
    cp "$SECRET_DIR/env/$ch.env" "$CROOT/$ch/home/$CUSER/$REPO_DIR/$ENV_DEST"
    HOME="$CROOT/$ch/home/$CUSER" git config --global user.name "$ch"
    HOME="$CROOT/$ch/home/$CUSER" git config --global user.email "$ch@channels.example.test"
  done
  # Smoke REAL de verify.sh [TAL-3117 fix 3]: invocar verify.sh en vez de reproducir su lógica.
  # El mock incus se exporta al subproceso via export -f; TC_VERIFY_SCOPE=identity activa el seam
  # de test (válido solo con TC_NO_AUTOLOAD=1 simultáneamente — el guard fail-closed lo exige).
  export -f incus
  export FAKE_CHANNELS FAKE_LIST_FAIL

  # Escenario VERDE: seed correcto (91/92 mergeador + 93/94 produccion sin sensibles) → exit 0.
  local _vgrc=0 _vredrc=0
  TC_NO_AUTOLOAD=1 TC_VERIFY_SCOPE=identity bash "$SCRIPTS/verify.sh" >/dev/null 2>&1 || _vgrc=$?

  # Escenario ROJO — test de mutación del fix 1 (sin -maxdepth):
  # plantar sbp_ a profundidad 7 bajo canal produccion 93. Con maxdepth 6 no se detectaría
  # (falso PASS); sin maxdepth tc_prod_no_sensitive lo encuentra → bad>0 → exit≠0.
  local _deep="$CROOT/vibe-channel-93/home/$CUSER/a/b/c/d/e/f/g"
  mkdir -p "$_deep"
  printf 'SUPABASE_ACCESS_TOKEN=sbp_deep7hidden\n' > "$_deep/$ENV_DEST"
  TC_NO_AUTOLOAD=1 TC_VERIFY_SCOPE=identity bash "$SCRIPTS/verify.sh" >/dev/null 2>&1 || _vredrc=$?
  rm -f "$_deep/$ENV_DEST"

  [ "$_vgrc" -eq 0 ] && [ "$_vredrc" -ne 0 ]
)
run_t17b; chk "smoke post-apply: verify VERDE (seed correcto) + ROJO (sbp_ a profundidad 7 detectado)" "[ $? -eq 0 ]"

# (C) [TAL-3117] Idempotencia del intake: re-ejecutar _tc_intake_seed_profiles con mapa preexistente
#     conserva canales fuera de COUNT, perfil no-default válido (Enter), y nuevo canal toma produccion.
run_t17c() (
  local B; B="$WORK/t17c.$RANDOM"
  export TC_NO_AUTOLOAD=1 TC_INTAKE_LIB_ONLY=1
  export SECRET_DIR="$B/secret" TC_INVOKE_CWD="$B"
  mkdir -p "$SECRET_DIR"
  CUSER="$(id -un)"
  export PREFIX="vibe-channel-" MACHINE_NUM=9 COUNT=3 CUSER
  # pre-sembrar: 91=runner + 92=piloto [TAL-5142] (ambos DENTRO de COUNT, perfil no-default) +
  # 99=mergeador (fuera de COUNT)
  ( umask 077; printf 'vibe-channel-91=runner\nvibe-channel-92=piloto\nvibe-channel-99=mergeador\n' > "$SECRET_DIR/channel-profiles.list" )
  chmod 600 "$SECRET_DIR/channel-profiles.list"
  # Ejecutar el flujo real de sembrado alimentando Enter para los 3 canales en COUNT (91, 92, 93)
  printf '\n\n\n' | bash -c ". \"$SCRIPTS/00-intake.sh\"; _tc_intake_seed_profiles" 2>/dev/null
  # (a) canal fuera de COUNT (99=mergeador) sobrevive — no truncado
  grep -qx 'vibe-channel-99=mergeador' "$SECRET_DIR/channel-profiles.list" || return 1
  # (b) 91 conserva runner — Enter sobre perfil preexistente válido no lo resetea a produccion
  grep -qx 'vibe-channel-91=runner' "$SECRET_DIR/channel-profiles.list" || return 2
  # (b2) [TAL-5142] 92 conserva 'piloto' — Enter NO lo declara inválido ni lo fuerza a otro valor
  # (regresión real: sin piloto en 00-intake.sh, esto imprime "perfil INVÁLIDO preexistente" y el
  # bucle de elección tampoco ofrece 'piloto', así que Enter no tiene default y el flujo se cuelga
  # esperando una entrada explícita entre produccion|mergeador|runner)
  grep -qx 'vibe-channel-92=piloto' "$SECRET_DIR/channel-profiles.list" || return 5
  # (c) 93 (nueva declaración) toma default produccion en Enter (canal sin declaración previa)
  grep -qx 'vibe-channel-93=produccion' "$SECRET_DIR/channel-profiles.list" || return 3
  # (d) sin duplicados para 91 ni 92
  [ "$(grep -c '^vibe-channel-91=' "$SECRET_DIR/channel-profiles.list")" -eq 1 ] || return 4
  [ "$(grep -c '^vibe-channel-92=' "$SECRET_DIR/channel-profiles.list")" -eq 1 ] || return 6
  return 0
)
run_t17c; chk "intake idempotente: re-sembrado conserva canal fuera de COUNT + perfil runner + [TAL-5142] perfil piloto + nueva declaracion" "[ $? -eq 0 ]"

# (D) [TAL-3117] Guard fail-closed: TC_VERIFY_SCOPE=identity sin TC_NO_AUTOLOAD=1 → exit≠0.
#     Un operador no puede saltarse el verificador de infra con una env var suelta en produccion.
chk "verify: TC_VERIFY_SCOPE=identity sin TC_NO_AUTOLOAD=1 → fail-closed (exit≠0)" \
  "! TC_VERIFY_SCOPE=identity bash '$SCRIPTS/verify.sh' 2>/dev/null"

echo

# ==========================================================================
echo "== 18. [TAL-3394] Fan-out escalonado: validación FAIL-CLOSED del override (sin Incus) =="
# Extrae del script REAL (por ancla, no duplicado) las funciones tc_fanout_validate_spec y
# tc_fanout_stagger_sec, y las ejercita puras con tc_die shimeado. Un override malformado debe
# ABORTAR (rc!=0) — jamás degradar en silencio a "sin espera" (burst).
FANOUT_SRC="$WORK/fanout-frag.sh"
sed -n '/^tc_fanout_validate_spec()/,/^}/p; /^tc_fanout_stagger_sec()/,/^}/p' \
  "$SCRIPTS/refresh-claude-auth.sh" > "$FANOUT_SRC"
chk "frag extraído contiene ambas funciones" \
  "grep -q 'tc_fanout_validate_spec()' '$FANOUT_SRC' && grep -q 'tc_fanout_stagger_sec()' '$FANOUT_SRC'"
_fanout_probe() { # $1=spec → rc de la validación (tc_die → exit 9)
  ( tc_die(){ exit 9; }
    # shellcheck source=/dev/null
    . "$FANOUT_SRC"
    TC_FANOUT_STAGGER_SEC="$1" tc_fanout_validate_spec )
}
_fanout_val() { # $1=spec → valor derivado post-validación
  ( tc_die(){ exit 9; }
    # shellcheck source=/dev/null
    . "$FANOUT_SRC"
    TC_FANOUT_STAGGER_SEC="$1" tc_fanout_stagger_sec )
}
chk "spec fija '45' → válida" "_fanout_probe 45"
chk "spec rango '30-60' → válida" "_fanout_probe 30-60"
chk "spec '0' (desactiva) → válida" "_fanout_probe 0"
chk "spec 'abc' → ABORT (fail-closed, no burst)" "! _fanout_probe abc"
chk "spec '60-30' (min>max) → ABORT" "! _fanout_probe 60-30"
chk "spec '30-60-90' → ABORT" "! _fanout_probe 30-60-90"
chk "spec '-30' → ABORT" "! _fanout_probe -30"
v="$(_fanout_val '')"; chk "spec vacía '' → default seguro 30-60 (jamás sin-espera)" "_fanout_probe '' && [ \"$v\" -ge 30 ] && [ \"$v\" -le 60 ]"
v="$(_fanout_val 45)";    chk "derivador fijo: 45 → 45" "[ \"$v\" = 45 ]"
v="$(_fanout_val 30-60)"; chk "derivador rango: 30-60 → [30,60]" "[ \"$v\" -ge 30 ] && [ \"$v\" -le 60 ]"
v="$(_fanout_val 0)";     chk "derivador cero: 0 → 0" "[ \"$v\" = 0 ]"
# Dominio ÚNICO validación↔derivación: lo que se acepta SE DERIVA sin fallar (repro del review:
# "08-09" pasaba la forma pero $(( )) lo leía como octal inválido DESPUÉS del primer canal).
chk "spec '08-09' (ceros iniciales) → válida" "_fanout_probe 08-09"
v="$(_fanout_val 08-09)"; chk "derivador '08-09' → [8,9] sin error octal" "[ -n \"$v\" ] && [ \"$v\" -ge 8 ] && [ \"$v\" -le 9 ]"
chk "spec '045' → válida" "_fanout_probe 045"
v="$(_fanout_val 045)";   chk "derivador '045' → 45 (base-10 explícita)" "[ \"$v\" = 45 ]"
chk "spec desbordada (21 dígitos) → ABORT antes del primer canal" "! _fanout_probe 999999999999999999999"
chk "spec '100000' (6 dígitos) → ABORT (cap de magnitud)" "! _fanout_probe 100000"
chk "spec '86401' → ABORT (cap 86400 s)" "! _fanout_probe 86401"
chk "spec '86400' (tope exacto) → válida" "_fanout_probe 86400"
# La validación corre ANTES del primer side-effect: la llamada a tc_fanout_validate_spec debe
# preceder en el fuente al loop de canales (primer uso de incus) — guard posicional.
L_VAL="$(grep -n '^tc_fanout_validate_spec$' "$SCRIPTS/refresh-claude-auth.sh" | head -1 | cut -d: -f1)"
L_LOOP="$(grep -n 'for ch in "\${targets\[@\]}"' "$SCRIPTS/refresh-claude-auth.sh" | head -1 | cut -d: -f1)"
chk "validación invocada ANTES del loop de canales" "[ -n \"$L_VAL\" ] && [ -n \"$L_LOOP\" ] && [ \"$L_VAL\" -lt \"$L_LOOP\" ]"
chk "el gate del sleep ya no silencia errores (sin 2>/dev/null)" \
  "! grep -q 'stagger\" -gt 0 \] 2>/dev/null' '$SCRIPTS/refresh-claude-auth.sh'"

echo
# ==========================================================================
echo "== 19. [TAL-5142] Perfil 'piloto' (canal de LABORATORIO): hereda VERBATIM las reglas de 'mergeador' =="
# Cada hunk del patch se ejercita EN AISLAMIENTO (nunca encadenado tras otro), para que revertir
# UN solo fichero de origen tumbe SOLO el sub-test de ESE fichero, no arrastre un falso-rojo por
# depender de que otro hunk ya funcione:
#   19a → channel-profiles.sh (CLI, solo depende de sí mismo)
#   19b → lib.sh (mapa escrito DIRECTO con printf, sin pasar por channel-profiles.sh)
#   19c → verify.sh (mapa escrito DIRECTO igual; 4 escenarios ROJO independientes — uno por
#         chk_fn: env, git, CR, sbp_ — más 1 escenario VERDE con todo correcto)

run_t19a() (
  local B; B="$WORK/t19a.$RANDOM"
  export SECRET_DIR="$B/secret" TC_INVOKE_CWD="$B"; mkdir -p "$B"
  SUDO_USER="$(id -un)"; export SUDO_USER
  bash "$SCRIPTS/channel-profiles.sh" set vibe-channel-95 piloto >/dev/null 2>&1 || { echo "cli-rechaza-piloto"; return 1; }
  grep -qx 'vibe-channel-95=piloto' "$SECRET_DIR/channel-profiles.list" || { echo "cli-no-persiste"; return 1; }
  return 0
)
run_t19a; chk "19a piloto: channel-profiles.sh CLI acepta y persiste 'piloto'" "[ $? -eq 0 ]"

run_t19b() (
  export TC_NO_AUTOLOAD=1
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib.sh"
  local B; B="$WORK/t19b.$RANDOM"
  export SECRET_DIR="$B/secret"; mkdir -p "$SECRET_DIR"
  # mapa escrito DIRECTO (sin channel-profiles.sh): aísla lib.sh de channel-profiles.sh.
  printf 'vibe-channel-95=piloto\n' > "$SECRET_DIR/channel-profiles.list"
  [ "$(tc_expected_profile vibe-channel-95)" = piloto ] || { echo "lib-no-reconoce-piloto"; return 1; }
  return 0
)
run_t19b; chk "19b piloto: lib.sh tc_expected_profile clasifica el canal como 'piloto' (no 'invalid')" "[ $? -eq 0 ]"

run_t19c() (
  export TC_NO_AUTOLOAD=1
  local B; B="$WORK/t19c.$RANDOM"
  export CROOT="$B/croot" SECRET_DIR="$B/secret" TC_INVOKE_CWD="$B"; mkdir -p "$SECRET_DIR/env" "$B"
  export PREFIX="vibe-channel-" MACHINE_NUM=9 COUNT=6 CUSER="vivecoder" REPO_DIR="repo" ENV_DEST=".env.local"
  export TC_MERGEADOR_CHANNELS="" TC_RUNNER_CHANNELS="" TC_CRED_SCANNER=""
  export TF_CHANNEL_GIT_NAME_TMPL="{channel}" TF_CHANNEL_GIT_EMAIL_TMPL="{channel}@channels.example.test"
  # mapa escrito DIRECTO (sin channel-profiles.sh): aísla verify.sh (+lib.sh, dependencia real y
  # honesta de tc_expected_profile) de channel-profiles.sh.
  printf 'vibe-channel-95=piloto\n' > "$SECRET_DIR/channel-profiles.list"
  FAKE_CHANNELS="vibe-channel-95"; FAKE_LIST_FAIL=0
  incus() {
    local sub="$1"; shift
    case "$sub" in
      list) [ "$FAKE_LIST_FAIL" = 1 ] && return 1; printf '%s\n' $FAKE_CHANNELS; return 0;;
      exec)
        local ch="$1"; shift; [ "${1:-}" = "--" ] && shift; local bin="$1"; shift
        _rw() { case "$1" in /home*|/root*) printf '%s%s' "$CROOT/$ch" "$1";; *) printf '%s' "$1";; esac; }
        if [ "$bin" = sh ] || [ "$bin" = bash ]; then [ "$1" = "-c" ] && shift; local script="$1"; shift
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" -c "$script" "${args[@]}"; return $?; fi
        if [ "$bin" = su ]; then
          local suuser="" suscript=""
          while [ $# -gt 0 ]; do case "$1" in -) shift;; -c) suscript="$2"; shift 2; break;; *) suuser="$1"; shift;; esac; done
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done
          HOME="$CROOT/$ch/home/$suuser" bash -c "$suscript" "${args[@]}"; return $?
        fi
        local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" "${args[@]}"; return $?;;
      *) return 2;;
    esac
  }
  export -f incus; export FAKE_CHANNELS FAKE_LIST_FAIL
  _seed_good() {
    mkdir -p "$CROOT/vibe-channel-95/home/$CUSER/$REPO_DIR" "$CROOT/vibe-channel-95/root"
    printf 'sbp_ cr- lin_api_ (docs)\n' > "$CROOT/vibe-channel-95/home/$CUSER/$REPO_DIR/notes-docs.md"
    printf 'GITHUB_TOKEN=ghp_p\nSUPABASE_ACCESS_TOKEN=sbp_piloto01\nCODERABBIT_API_KEY=cr-piloto-abc\n' > "$SECRET_DIR/env/vibe-channel-95.env"
    cp "$SECRET_DIR/env/vibe-channel-95.env" "$CROOT/vibe-channel-95/home/$CUSER/$REPO_DIR/$ENV_DEST"
    mkdir -p "$CROOT/vibe-channel-95/home/$CUSER/.coderabbit"
    printf '{"type":"api_key","apiKey":"cr-piloto-abc"}\n' > "$CROOT/vibe-channel-95/home/$CUSER/.coderabbit/auth.json"
    HOME="$CROOT/vibe-channel-95/home/$CUSER" git config --global user.name "vibe-channel-95"
    HOME="$CROOT/vibe-channel-95/home/$CUSER" git config --global user.email "vibe-channel-95@channels.example.test"
  }
  # Corre verify.sh capturando SALIDA COMPLETA (no solo el exit code) para poder exigir que el
  # FAIL concreto sea el esperado — un exit!=0 genérico no prueba que fallara EL check que se
  # queria aislar (podria estar cayendo por otro chk_fn distinto, falso-positivo de aislamiento).
  _verify_out() { TC_NO_AUTOLOAD=1 TC_VERIFY_SCOPE=identity bash "$SCRIPTS/verify.sh" 2>&1; }

  # VERDE: todo correcto → exit 0. Prueba base de la que parten los 4 escenarios ROJO.
  _seed_good
  local _out; _out="$(_verify_out)"
  echo "$_out" | grep -q '^  FAIL' && { echo "verde-con-todo-correcto-fallo: $_out"; return 1; }

  # ROJO 1/4 — identidad ENV rota SIN tocar sbp_/CR (ejercita tc_verify_env_identity EN AISLAMIENTO):
  # se desincroniza SOLO el escrow (simula un push stale, igual que el patrón e1 de la sección 16);
  # el fichero operacional del contenedor conserva sbp_+CR intactos, así que si desapareciera
  # tc_verify_env_identity de verify.sh el resto de checks seguirían en VERDE (aislamiento real).
  printf 'GITHUB_TOKEN=ghp_ESCROW_DESINCRONIZADO\nSUPABASE_ACCESS_TOKEN=sbp_piloto01\nCODERABBIT_API_KEY=cr-piloto-abc\n' > "$SECRET_DIR/env/vibe-channel-95.env"
  _out="$(_verify_out)"
  echo "$_out" | grep -q '^  FAIL.*identidad env' || { echo "rojo-env-no-aislado: $_out"; return 1; }
  printf 'GITHUB_TOKEN=ghp_p\nSUPABASE_ACCESS_TOKEN=sbp_piloto01\nCODERABBIT_API_KEY=cr-piloto-abc\n' > "$SECRET_DIR/env/vibe-channel-95.env"  # restaurar escrow

  # ROJO 2/4 — identidad GIT rota (ejercita tc_verify_git_identity): FAIL concreto de identidad git.
  HOME="$CROOT/vibe-channel-95/home/$CUSER" git config --global user.email "otro-canal@channels.example.test"
  _out="$(_verify_out)"
  echo "$_out" | grep -q '^  FAIL.*identidad git' || { echo "rojo-git-no-aislado: $_out"; return 1; }
  HOME="$CROOT/vibe-channel-95/home/$CUSER" git config --global user.email "vibe-channel-95@channels.example.test"  # restaurar

  # ROJO 3/4 — sin credencial CR (ejercita tc_verify_cr_identity): FAIL concreto de identidad CR.
  rm -f "$CROOT/vibe-channel-95/home/$CUSER/.coderabbit/auth.json"
  _out="$(_verify_out)"
  echo "$_out" | grep -q '^  FAIL.*identidad CR' || { echo "rojo-cr-no-aislado: $_out"; return 1; }
  mkdir -p "$CROOT/vibe-channel-95/home/$CUSER/.coderabbit"
  printf '{"type":"api_key","apiKey":"cr-piloto-abc"}\n' > "$CROOT/vibe-channel-95/home/$CUSER/.coderabbit/auth.json"  # restaurar

  # ROJO 4/4 — sin sbp_ efectiva SIN romper identidad env (ejercita tc_mergeador_has_sbp EN
  # AISLAMIENTO): se retira sbp_ de AMBAS copias (escrow y operacional) de forma IDÉNTICA, así que
  # su MD5 sigue coincidiendo (env identity pasa) y solo la ausencia de sbp_ puede tumbar el check.
  printf 'GITHUB_TOKEN=ghp_p\nCODERABBIT_API_KEY=cr-piloto-abc\n' > "$SECRET_DIR/env/vibe-channel-95.env"
  cp "$SECRET_DIR/env/vibe-channel-95.env" "$CROOT/vibe-channel-95/home/$CUSER/$REPO_DIR/$ENV_DEST"
  _out="$(_verify_out)"
  echo "$_out" | grep -q '^  FAIL.*sbp_ efectiva' || { echo "rojo-sbp-no-aislado: $_out"; return 1; }
  return 0
)
run_t19c; chk "19c piloto: verify.sh REAL trata 'piloto' como 'mergeador' — verde con todo correcto, rojo si falta env/git/CR/sbp_ (4 escenarios independientes)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 20. [TAL-8038] Renderer clásico + barra ctx: golden, canales ya clonados y verify =="
# Tres capas (settings .tui+statusLine · export bashrc con guard propio · tmux alternate-screen off) + versión mínima.
# Doble de incus por FUNCIÓN exportada (reescribe /home → $CROOT/<canal>/home); sin Incus real, sin tmux real.
R20="$WORK/t20"; mkdir -p "$R20/bin288" "$R20/bin277" "$R20/shims"
printf '#!/bin/sh\necho "${FAKE_CLAUDE_VER:-2.1.289} (Claude Code)"\n' > "$R20/shims/claude"
printf '#!/bin/sh\nexit 1\n' > "$R20/shims/tmux"          # el tmux «del contenedor»: sin servidor, jamás toca uno real
chmod +x "$R20/shims/claude" "$R20/shims/tmux"
chk "20.0 apply-renderer.sh y su dependencia talent-context pasan bash -n" \
  "bash -n '$SCRIPTS/apply-renderer.sh' && bash -n '$HERE/../../talent-context/scripts/install-statusline.sh' && bash -n '$HERE/../../talent-context/assets/statusline-ctx.sh'"

# Prepara un entorno de renderer (CROOT + escrow vacío + vars de config) y define el doble `incus`. Uso: r20_env <caso>
r20_env() {
  local B="$R20/$1.$RANDOM"; mkdir -p "$B"
  export CROOT="$B/croot" SECRET_DIR="$B/secret" TC_INVOKE_CWD="$B"; mkdir -p "$SECRET_DIR/env" "$CROOT"
  export TC_NO_AUTOLOAD=1 PREFIX="vibe-channel-" MACHINE_NUM=9 COUNT=2 CUSER="vivecoder" REPO_DIR="repo" ENV_DEST=".env.local"
  export POOL=pool-test BRIDGE=br-test GOLDEN=golden TS_PORT_BASE=41000 TC_LOCAL_ONLY=yes TC_MERGEADOR_CHANNELS="" TC_RUNNER_CHANNELS="" TC_CRED_SCANNER=""
  export TF_CHANNEL_GIT_NAME_TMPL="{channel}" TF_CHANNEL_GIT_EMAIL_TMPL="{channel}@channels.example.test"
  export FAKE_CHANNELS="vibe-channel-91 vibe-channel-92" FAKE_CLAUDE_VER=2.1.289
  PATH="$R20/shims:$PATH"; export PATH
  incus() {
    local sub="$1"; shift
    case "$sub" in
      list) printf '%s\n' $FAKE_CHANNELS; return 0;;
      exec)
        local ch="$1"; shift; [ "${1:-}" = "--" ] && shift; local bin="$1"; shift
        case " $FAKE_CHANNELS golden " in *" $ch "*) :;; *) echo "fake: contenedor $ch inexistente" >&2; return 1;; esac
        _rw() { case "$1" in /home*|/root*) printf '%s%s' "$CROOT/$ch" "$1";; *) printf '%s' "$1";; esac; }
        if [ "$bin" = sh ] || [ "$bin" = bash ]; then
          case "${1:-}" in -c|-lc) shift;; esac
          local script="$1"; shift
          case "$script" in *"/dev/tcp/"*) return 1;; esac   # sin red en el arnés
          local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" -c "$script" "${args[@]}"; return $?; fi
        if [ "$bin" = su ]; then
          local suuser="" suscript=""
          while [ $# -gt 0 ]; do case "$1" in -) shift;; -c) suscript="$2"; shift 2; break;; *) suuser="$1"; shift;; esac; done
          mkdir -p "$CROOT/$ch/home/$suuser"
          HOME="$CROOT/$ch/home/$suuser" bash -c "$suscript"; return $?
        fi
        local a args=(); for a in "$@"; do args+=("$(_rw "$a")"); done; "$bin" "${args[@]}"; return $?;;
      *) return 2;;
    esac
  }
  export -f incus; export FAKE_CHANNELS
}
r20_home() { printf '%s/%s/home/%s' "$CROOT" "$1" "$CUSER"; }

# 20a — capas del golden/canal: aplica, es idempotente (2 corridas → 1 export, 1 línea de tmux, mismo sha) y respeta lo previo
run_t20a() (
  r20_env t20a
  # shellcheck source=/dev/null
  . "$SCRIPTS/00-config.sh"; . "$SCRIPTS/lib.sh"; . "$SCRIPTS/apply-renderer.sh"
  local H; H="$(r20_home vibe-channel-91)"; mkdir -p "$H/.claude"
  printf '{"model":"claude-sonnet-5","otra":{"x":1}}\n' > "$H/.claude/settings.json"
  # bashrc YA con el alias claude-root (su guard NO sirve para el export nuevo) y tmux.conf previo
  printf 'alias claude-root="IS_SANDBOX=1 claude --dangerously-skip-permissions"\nexport DISABLE_AUTOUPDATER=1\n' > "$H/.bashrc"
  printf 'set -g mouse on\n' > "$H/.tmux.conf"
  local o1 o2
  o1="$(tc_renderer_apply_one vibe-channel-91 2>&1)" || { echo "1a-corrida-falla: $o1"; return 1; }
  echo "$o1" | grep -q 'aplicado' || { echo "1a-no-dice-aplicado: $o1"; return 1; }
  jq -e '.tui=="default" and .statusLine.type=="command" and .model=="claude-sonnet-5" and .otra.x==1' "$H/.claude/settings.json" >/dev/null || { echo "settings-mal"; return 1; }
  [ -x "$H/.claude/statusline-ctx.sh" ] || { echo "barra-no-instalada"; return 1; }
  [ "$(grep -c '^export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1' "$H/.bashrc")" = 1 ] || { echo "bashrc-sin-export"; return 1; }
  [ "$(grep -c '^set -g alternate-screen off$' "$H/.tmux.conf")" = 1 ] || { echo "tmux-sin-linea"; return 1; }
  grep -q '^set -g mouse on' "$H/.tmux.conf" && grep -q 'alias claude-root=' "$H/.bashrc" || { echo "pisa-lo-previo"; return 1; }
  local h1; h1="$(cat "$H/.claude/settings.json" "$H/.bashrc" "$H/.tmux.conf" | sha256sum)"
  o2="$(tc_renderer_apply_one vibe-channel-91 2>&1)" || { echo "2a-corrida-falla: $o2"; return 1; }
  echo "$o2" | grep -q 'sin cambios' || { echo "2a-no-dice-sin-cambios: $o2"; return 1; }
  [ "$(grep -c '^export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1' "$H/.bashrc")" = 1 ] || { echo "2-exports"; return 1; }
  [ "$h1" = "$(cat "$H/.claude/settings.json" "$H/.bashrc" "$H/.tmux.conf" | sha256sum)" ] || { echo "no-idempotente"; return 1; }
  return 0
)
out="$(run_t20a 2>&1)"; chk "20a 3 capas aplicadas e idempotentes (bashrc con guard propio: 2 corridas → 1 export; tmux 1 línea; sha estable): ${out:-ok}" "[ -z '$out' ]"

# 20a2 — ficheros AJENOS sin salto de línea final (bashrc y tmux.conf): la línea nueva no se pega a la última
run_t20a2() (
  r20_env t20a2
  # shellcheck source=/dev/null
  . "$SCRIPTS/00-config.sh"; . "$SCRIPTS/lib.sh"; . "$SCRIPTS/apply-renderer.sh"
  local H; H="$(r20_home vibe-channel-91)"; mkdir -p "$H"
  printf 'set -g mouse on' > "$H/.tmux.conf"; printf 'alias x=1' > "$H/.bashrc"   # SIN \n final
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1 || { echo "apply-falla"; return 1; }
  grep -qx 'set -g mouse on' "$H/.tmux.conf" || { echo "tmux-pegada-a-la-ultima"; return 1; }
  grep -qx 'set -g alternate-screen off' "$H/.tmux.conf" || { echo "tmux-sin-linea-propia"; return 1; }
  grep -qx 'alias x=1' "$H/.bashrc" || { echo "bashrc-pegada-a-la-ultima"; return 1; }
  grep -qx 'export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1' "$H/.bashrc" || { echo "bashrc-sin-export-propio"; return 1; }
  return 0
)
out="$(run_t20a2 2>&1)"; chk "20a2 tmux.conf/bashrc ajenos SIN salto final: la línea nueva queda en línea propia: ${out:-ok}" "[ -z '$out' ]"

# 20b — versión mínima fail-closed (2.1.277 → FAIL sin escribir nada) y statusLine ajena (FAIL salvo --force)
run_t20b() (
  r20_env t20b
  # shellcheck source=/dev/null
  . "$SCRIPTS/00-config.sh"; . "$SCRIPTS/lib.sh"; . "$SCRIPTS/apply-renderer.sh"
  local H; H="$(r20_home vibe-channel-91)"; mkdir -p "$H/.claude"
  FAKE_CLAUDE_VER=2.1.277; export FAKE_CLAUDE_VER
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1 && { echo "version-vieja-pasa"; return 1; }
  [ ! -e "$H/.claude/settings.json" ] && [ ! -e "$H/.bashrc" ] || { echo "escribio-con-version-vieja"; return 1; }
  FAKE_CLAUDE_VER=2.1.289; export FAKE_CLAUDE_VER
  printf '{"statusLine":{"type":"command","command":"bash /x/mia.sh"}}\n' > "$H/.claude/settings.json"
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1 && { echo "ajena-pasa-sin-force"; return 1; }
  [ "$(jq -r .statusLine.command "$H/.claude/settings.json")" = "bash /x/mia.sh" ] || { echo "piso-la-ajena"; return 1; }
  tc_renderer_apply_one vibe-channel-91 --force >/dev/null 2>&1 || { echo "force-falla"; return 1; }
  jq -e '.statusLine.command | test("statusline-ctx[.]sh")' "$H/.claude/settings.json" >/dev/null || { echo "force-no-pisa"; return 1; }
  return 0
)
out="$(run_t20b 2>&1)"; chk "20b versión 2.1.277 → FAIL sin escribir · statusLine ajena → FAIL sin --force, la pisa con --force: ${out:-ok}" "[ -z '$out' ]"

# 20c — CLI apply-renderer.sh sobre los canales reales: 2.ª pasada «sin cambios»; contenedor inexistente en --only → rc 1
run_t20c() (
  r20_env t20c
  local o1 o2
  o1="$(bash "$SCRIPTS/apply-renderer.sh" 2>&1)" || { echo "cli-1a-falla: $o1"; return 1; }
  [ "$(echo "$o1" | grep -c ' aplicado ')" = 2 ] || { echo "cli-1a-no-toca-ambos: $o1"; return 1; }
  o2="$(bash "$SCRIPTS/apply-renderer.sh" 2>&1)" || { echo "cli-2a-falla: $o2"; return 1; }
  [ "$(echo "$o2" | grep -c 'sin cambios')" = 2 ] || { echo "cli-2a-no-dice-sin-cambios: $o2"; return 1; }
  bash "$SCRIPTS/apply-renderer.sh" --only vibe-channel-77 >/dev/null 2>&1 && { echo "cli-contenedor-inexistente-pasa"; return 1; }
  bash "$SCRIPTS/apply-renderer.sh" --only >/dev/null 2>&1 && { echo "cli-only-sin-valor-pasa"; return 1; }
  return 0
)
out="$(run_t20c 2>&1)"; chk "20c apply-renderer.sh (CLI): aplica a todos los canales; 2.ª vez «sin cambios»; contenedor inexistente → rc≠0: ${out:-ok}" "[ -z '$out' ]"

# 20d — verify.sh (scope completo, doble de incus): FAIL por capa si falta tui / env / tmux / versión; PASS con todo
run_t20d() (
  r20_env t20d
  # La verificación completa consume un modelo: este caso declara su registro neutro.
  export TCO_MODELOS_REGISTRO="$R20/modelos.conf"
  printf 'OPUS_MODEL="claude-opus-4-8"\nSONNET_MODEL="claude-sonnet-5"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' > "$TCO_MODELOS_REGISTRO"
  export COUNT=1 FAKE_CHANNELS="vibe-channel-91"
  # shellcheck source=/dev/null
  . "$SCRIPTS/00-config.sh"; . "$SCRIPTS/lib.sh"; . "$SCRIPTS/apply-renderer.sh"
  local H; H="$(r20_home vibe-channel-91)"; mkdir -p "$H/.claude"
  _v() { bash "$SCRIPTS/verify.sh" 2>&1 | grep 'renderer'; }
  # sin aplicar: las 3 capas en FAIL
  local out; out="$(_v)"
  [ "$(echo "$out" | grep -c '^  FAIL')" -ge 3 ] || { echo "sin-aplicar-no-falla: $out"; return 1; }
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1 || { echo "apply-falla"; return 1; }
  out="$(_v)"; echo "$out" | grep -q '^  FAIL' && { echo "todo-aplicado-falla: $out"; return 1; }
  [ "$(echo "$out" | grep -c '^  PASS')" = 4 ] || { echo "no-hay-4-PASS: $out"; return 1; }
  # un canal sin tui → FAIL concreto de settings
  jq 'del(.tui)' "$H/.claude/settings.json" > "$H/t" && mv "$H/t" "$H/.claude/settings.json"
  out="$(_v)"; echo "$out" | grep -q '^  FAIL.*settings .tui=default' || { echo "sin-tui-no-falla: $out"; return 1; }
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1
  # sin export en bashrc
  grep -v 'DISABLE_ALTERNATE_SCREEN' "$H/.bashrc" > "$H/t"; mv "$H/t" "$H/.bashrc"
  out="$(_v)"; echo "$out" | grep -q '^  FAIL.*export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN' || { echo "sin-env-no-falla: $out"; return 1; }
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1
  # sin línea de tmux
  grep -v 'alternate-screen' "$H/.tmux.conf" > "$H/t"; mv "$H/t" "$H/.tmux.conf"
  out="$(_v)"; echo "$out" | grep -q '^  FAIL.*tmux.conf alternate-screen off' || { echo "sin-tmux-no-falla: $out"; return 1; }
  tc_renderer_apply_one vibe-channel-91 >/dev/null 2>&1
  # claude viejo → FAIL de versión
  FAKE_CLAUDE_VER=2.1.277; export FAKE_CLAUDE_VER
  out="$(_v)"; echo "$out" | grep -q '^  FAIL.*claude >= mínima' || { echo "version-vieja-no-falla: $out"; return 1; }
  # sin el fichero de versión mínima (skill talent-context ausente) → FAIL cerrado, no skip
  FAKE_CLAUDE_VER=2.1.289; export FAKE_CLAUDE_VER; TC_RENDERER_MIN_FILE="$R20/no-existe"; export TC_RENDERER_MIN_FILE
  out="$(_v)"; echo "$out" | grep -q '^  FAIL.*falta .*talent-context ausente' || { echo "sin-minima-no-falla: $out"; return 1; }
  return 0
)
out="$(run_t20d 2>&1)"; chk "20d verify.sh: FAIL por capa sin aplicar / sin tui / sin env / sin tmux / claude viejo / sin mínima; PASS (4) con todo: ${out:-ok}" "[ -z '$out' ]"
# 20e — 02-golden.sh invoca las tres capas (guarda estática: el golden no puede olvidar el renderer)
chk "20e 02-golden.sh carga apply-renderer.sh y lo aplica al golden con fail-closed" \
  "grep -q 'apply-renderer.sh' '$SCRIPTS/02-golden.sh' && grep -q 'tc_renderer_apply_one \"\\\$GOLDEN\" || tc_die' '$SCRIPTS/02-golden.sh'"

# ==========================================================================
# TAL-8042 — quiesce por EJECUTABLE (no por línea de comandos), hermético y con rc por fase.
# Convención: la LISTA de PIDs permitidos del escudo (`$AM_TEST_CROOT/.allowed-kill-pids`) la escribe
# cada test con SOLO los PID que él mismo creó; los señuelos llevan argv[0] EXACTO (`exec -a codex`).
# ==========================================================================
alive() { # PID → si|no. VIVO = existe y NO es zombi (un hijo matado sin `wait` sigue respondiendo a kill -0)
  local st; st="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)"
  if [ -n "$st" ] && [ "$st" != Z ] && [ "$st" != X ]; then echo si; else echo no; fi
}
# Agente SIMULADO en SESIÓN PROPIA (como en producción: cada agente vive en su sesión tmux). Un señuelo
# creado en la misma sesión/grupo que el quiesce es PROTEGIDO por diseño (no se mata y cuenta como vivo).
# Imprime el PID (argv[0] = $1; ejecutable = basename).
spawn_agent() { # argv0
  local f="$WORK/spawn.$RANDOM.$RANDOM" i
  setsid bash -c 'echo $$ > "$1"; exec -a "$2" sleep 300' _ "$f" "$1" >/dev/null 2>&1 &
  for i in $(seq 1 50); do [ -s "$f" ] && break; sleep 0.1; done
  cat "$f" 2>/dev/null
}

echo "== 20. [TAL-8042] am_ep_quiesce: casa el EJECUTABLE (argv[0]/comm), jamás la línea de comandos =="
run_t20() (
  eval "$(new_env t20)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; . "$LIB"
  : > "$WORK/t20-codex.log"
  agente="$(spawn_agent codex)"                          # ejecutable = codex (sesión propia): ES el objetivo
  exec -a codex-vecino sleep 300 & vecino=$!             # 'codex' dentro de argv[0], ejecutable DISTINTO
  tail -f "$WORK/t20-codex.log" >/dev/null 2>&1 & lector=$!   # 'codex.log' en la ruta de argv: NO es agente
  exec -a claude sleep 300 & otro=$!                     # OTRO agente: no es el objetivo
  sleep 0.3
  for p in "$agente" "$vecino" "$lector" "$otro"; do [ "$(alive "$p")" = si ] || { echo "setup: $p no arrancó"; return 9; }; done
  printf '%s\n' "$agente" "$vecino" "$lector" "$otro" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiesce "channel:t20" codex 3 >/dev/null 2>&1; rcA=$?
  sleep 0.2
  a="$(alive "$agente")"; v="$(alive "$vecino")"; l="$(alive "$lector")"; o="$(alive "$otro")"
  kill -9 "$agente" "$vecino" "$lector" "$otro" 2>/dev/null || true
  if [ "$rcA" -ne 0 ] || [ "$a" != no ] || [ "$v" != si ] || [ "$l" != si ] || [ "$o" != si ]; then
    echo "A FALLÓ: rc=$rcA agente=$a (esp. no) vecino=$v lector=$l otro-agente=$o (esp. si)"; return 1
  fi

  # B — default-deny del escudo: SIN lista de permitidos nada es visible ni matable (ni el argv[0] exacto).
  rm -f "$AM_TEST_CROOT/.allowed-kill-pids"
  agenteB="$(spawn_agent codex)"
  sleep 0.2
  am_ep_quiesce "channel:t20" codex 2 >/dev/null 2>&1; rcB=$?
  b="$(alive "$agenteB")"; kill -9 "$agenteB" 2>/dev/null || true
  if [ "$rcB" -ne 0 ] || [ "$b" != si ]; then echo "B (default-deny) FALLÓ: rc=$rcB sobrevive=$b"; return 1; fi

  # C1 — mismo GRUPO/SESIÓN que el quiesce: no se mata y cuenta como VIVO (falla cerrado, rc 1).
  exec -a codex sleep 300 & mismoGrupo=$!
  sleep 0.2
  printf '%s\n' "$mismoGrupo" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiesce "channel:t20" codex 2 >/dev/null 2>&1; rcC1=$?
  c1="$(alive "$mismoGrupo")"; kill -9 "$mismoGrupo" 2>/dev/null || true
  if [ "$rcC1" -ne 1 ] || [ "$c1" != si ]; then echo "C1 (mismo grupo) FALLÓ: rc=$rcC1 (esp. 1) sobrevive=$c1 (esp. si)"; return 1; fi

  # C2 — OTRA sesión (setsid): sin protección → se mata y el quiesce da rc 0.
  rm -f "$WORK/t20-sid.pid"
  setsid bash -c 'echo $$ > "$1"; exec -a codex sleep 300' _ "$WORK/t20-sid.pid" &
  for _ in $(seq 1 50); do [ -s "$WORK/t20-sid.pid" ] && break; sleep 0.1; done
  otraSesion="$(cat "$WORK/t20-sid.pid" 2>/dev/null)"
  [ -n "$otraSesion" ] || { echo "setup C2: sin pid"; return 9; }
  sleep 0.2
  printf '%s\n' "$otraSesion" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiesce "channel:t20" codex 3 >/dev/null 2>&1; rcC2=$?
  sleep 0.2; c2="$(alive "$otraSesion")"; kill -9 "$otraSesion" 2>/dev/null || true
  if [ "$rcC2" -ne 0 ] || [ "$c2" != no ]; then echo "C2 (otra sesión) FALLÓ: rc=$rcC2 (esp. 0) sobrevive=$c2 (esp. no)"; return 1; fi

  # D — ANCESTRO con argv[0]=codex: jamás se mata (auto-kill TAL-3539) y cuenta como vivo (rc 1).
  rm -f "$WORK/t20-anc.res" "$WORK/t20-anc.pid"
  cat > "$WORK/t20-anc.sh" <<'CHILD'
#!/usr/bin/env bash
set -u
. "$T20_LIB"
printf '%s\n' "$$" > "$AM_TEST_CROOT/.allowed-kill-pids"
printf '%s\n' "$$" > "$T20_PID"
am_ep_quiesce "channel:t20" codex 2 >/dev/null 2>&1
printf '%s\n' "$?" > "$T20_RES"
sleep 2
CHILD
  T20_LIB="$LIB" T20_RES="$WORK/t20-anc.res" T20_PID="$WORK/t20-anc.pid" exec -a codex bash "$WORK/t20-anc.sh" &
  anc=$!
  for _ in $(seq 1 100); do [ -s "$WORK/t20-anc.res" ] && break; sleep 0.1; done
  rcD="$(cat "$WORK/t20-anc.res" 2>/dev/null)"; d="$(alive "$anc")"; kill -9 "$anc" 2>/dev/null || true
  if [ "$rcD" != 1 ] || [ "$d" != si ]; then echo "D (ancestro) FALLÓ: rc=$rcD (esp. 1) ancestro vivo=$d (esp. si)"; return 1; fi

  # E — extra_excl (4.º parámetro): declaración EXPLÍCITA del caller → no se mata, cuenta como vivo.
  protegido="$(spawn_agent codex)"
  objetivo="$(spawn_agent codex)"
  sleep 0.2
  printf '%s\n%s\n' "$protegido" "$objetivo" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiesce "channel:t20" codex 2 "$protegido" >/dev/null 2>&1; rcE=$?
  sleep 0.2; pe="$(alive "$protegido")"; oe="$(alive "$objetivo")"
  kill -9 "$protegido" "$objetivo" 2>/dev/null || true
  if [ "$rcE" -ne 1 ] || [ "$pe" != si ] || [ "$oe" != no ]; then
    echo "E (extra_excl) FALLÓ: rc=$rcE (esp. 1) protegido=$pe (esp. si) objetivo=$oe (esp. no)"; return 1
  fi
  return 0
)
run_t20; chk "20 quiesce por ejecutable: A (solo muere el argv[0]=codex; vecino/lector/otro agente vivos) + B (default-deny) + C1 (mismo grupo = vivo, rc 1) + C2 (otra sesión se mata) + D (ancestro codex intacto, rc 1) + E (extra_excl)" "[ $? -eq 0 ]"

echo "== 21. [TAL-8042] am_ep_quiet: ejecutable vivo ⇒ NO quiescente; vecino de argv ⇒ quiescente =="
run_t21() (
  eval "$(new_env t21)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; . "$LIB"
  exec -a codex-vecino sleep 300 & vecino=$!
  tail -f "$WORK/t20-codex.log" >/dev/null 2>&1 & lector=$!
  sleep 0.2
  printf '%s\n%s\n' "$vecino" "$lector" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiet "channel:t21" codex >/dev/null 2>&1 || { echo "quiet con solo vecinos de argv debía ser rc 0"; kill -9 "$vecino" "$lector" 2>/dev/null; return 1; }
  agente="$(spawn_agent codex)"
  sleep 0.2
  printf '%s\n' "$vecino" "$lector" "$agente" > "$AM_TEST_CROOT/.allowed-kill-pids"
  am_ep_quiet "channel:t21" codex >/dev/null 2>&1; rc=$?
  kill -9 "$vecino" "$lector" "$agente" 2>/dev/null || true
  [ "$rc" -ne 0 ] || { echo "quiet con el ejecutable vivo debía ser rc≠0"; return 1; }
  # error de enumeración (escudo forzado) ⇒ NO quiescente (fail-closed)
  AM_TEST_FORCE_PGREP_ERR=1 am_ep_quiet "channel:t21" codex >/dev/null 2>&1 && { echo "quiet con pgrep en error debía ser rc≠0"; return 1; }
  return 0
)
run_t21; chk "21 am_ep_quiet por ejecutable: vecinos de argv => quiescente; agente vivo o error de pgrep => NO quiescente" "[ $? -eq 0 ]"

echo "== 22. [TAL-8042] tc_kill_wait: mismo criterio (ejecutable) + exclusiones + argumento inválido fail-closed =="
run_t22() (
  eval "$(new_env t22)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; . "$SCRIPTS/lib.sh"
  objetivo="$(spawn_agent codex)"
  exec -a codex-vecino sleep 300 & vecino=$!
  tail -f "$WORK/t20-codex.log" >/dev/null 2>&1 & lector=$!
  protegido="$(spawn_agent codex)"
  sleep 0.3
  printf '%s\n' "$objetivo" "$vecino" "$lector" "$protegido" > "$AM_TEST_CROOT/.allowed-kill-pids"
  tc_kill_wait t22 codex "$CUSER" 2 "$protegido" >/dev/null 2>&1; rc=$?
  sleep 0.2
  o="$(alive "$objetivo")"; v="$(alive "$vecino")"; l="$(alive "$lector")"; p="$(alive "$protegido")"
  kill -9 "$objetivo" "$vecino" "$lector" "$protegido" 2>/dev/null || true
  # el protegido SIGUE vivo y es un agente → timeout rc 1 (nunca "limpio")
  if [ "$rc" -ne 1 ] || [ "$o" != no ] || [ "$v" != si ] || [ "$l" != si ] || [ "$p" != si ]; then
    echo "FALLÓ: rc=$rc (esp. 1) objetivo=$o (esp. no) vecino=$v lector=$l protegido=$p (esp. si)"; return 1
  fi
  # limpio: sin agentes vivos => rc 0
  rm -f "$AM_TEST_CROOT/.allowed-kill-pids"
  tc_kill_wait t22 codex "$CUSER" 2 >/dev/null 2>&1 || { echo "sin agentes debía dar rc 0"; return 1; }
  # argumento de ejecutable inválido (patrón viejo con metacaracteres de pgrep -f) → rc 3, nada ejecutado
  tc_kill_wait t22 '[c]odex --foo' "$CUSER" 2 >/dev/null 2>&1; rcI=$?
  [ "$rcI" -eq 3 ] || { echo "ejecutable inválido debía dar rc 3, dio $rcI"; return 1; }
  return 0
)
run_t22; chk "22 tc_kill_wait por ejecutable: mata solo al agente, respeta la exclusión (rc 1 si el protegido sigue), limpio rc 0, ejecutable inválido rc 3" "[ $? -eq 0 ]"

echo "== 23. [TAL-8042] escudo hermético de fake-incus: formas no reconocidas rc 2; kill ajeno rechazado; fallo forzado => rc 3 =="
run_t23() (
  eval "$(new_env t23)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; . "$LIB"; . "$SCRIPTS/lib.sh"
  fail=0; errf="$WORK/t23-err"; MARKER='pgrep-shadow: forma no reconocida'
  check_form() {
    local desc="$1" cmd="$2" rc n
    : > "$errf"; incus exec dummy -- bash -c "$cmd" >/dev/null 2>"$errf"; rc=$?
    n=$(grep -c "$MARKER" "$errf" 2>/dev/null || true)
    [ "$rc" -eq 2 ] && [ "$n" -eq 1 ] || { echo "DIRECTA ($desc) rc=$rc marker=$n (esp. 2/1)"; fail=1; }
    : > "$errf"; incus exec dummy -- bash -c "bash -c $(printf '%q' "$cmd")" >/dev/null 2>"$errf"; rc=$?
    n=$(grep -c "$MARKER" "$errf" 2>/dev/null || true)
    [ "$rc" -eq 2 ] && [ "$n" -eq 1 ] || { echo "ANIDADA ($desc) rc=$rc marker=$n (esp. 2/1)"; fail=1; }
  }
  check_form "con -f (la forma vieja)"  "pgrep -u someuser -f codex"
  check_form "orden invertido"          "pgrep -f codex -u someuser"
  check_form "flag extra"               "pgrep -u someuser -x"
  check_form "sin -u"                   "pgrep codex"
  check_form "aridad incompleta"        "pgrep -u"
  : > "$errf"; incus exec dummy -- bash -c "comando_tal8042_inexistente" >/dev/null 2>"$errf"; rcn=$?
  [ "$rcn" -eq 127 ] && ! grep -q "$MARKER" "$errf" || { echo "control negativo FALLÓ: rc=$rcn"; fail=1; }
  [ "$fail" -eq 0 ] || return 1
  # kill de un PID NO registrado (el canario de argv[0]=codex) → rechazado, canario vivo
  incus exec dummy -- bash -c "kill -9 $CANARIO2_PID" >/dev/null 2>&1; rck=$?
  [ "$rck" -ne 0 ] && [ "$(alive "$CANARIO2_PID")" = si ] || { echo "kill ajeno NO fue rechazado (rc=$rck) o mató al canario"; return 1; }
  # fallo de pgrep inyectado: los callers REALES dan rc 3, nunca 0 (quiescencia falsa)
  AM_TEST_FORCE_PGREP_ERR=1 am_ep_quiesce "channel:t23" codex 2 >/dev/null 2>&1; rcq=$?
  [ "$rcq" -eq 3 ] || { echo "am_ep_quiesce con pgrep en error: rc=$rcq (esp. 3)"; return 1; }
  AM_TEST_FORCE_PGREP_ERR=1 tc_kill_wait t23 codex "$CUSER" 2 >/dev/null 2>&1; rck=$?
  [ "$rck" -eq 3 ] || { echo "tc_kill_wait con pgrep en error: rc=$rck (esp. 3)"; return 1; }
  return 0
)
run_t23; chk "23 escudo: 5 formas no reconocidas rc 2 (directa+anidada)+control negativo; kill del canario rechazado; am_ep_quiesce/tc_kill_wait REALES => rc 3 ante pgrep roto" "[ $? -eq 0 ]"

echo "== 24. [TAL-8042] CENTINELA permanente: un proceso ajeno con el agente en argv sobrevive a TODOS los caminos =="
run_t24() (
  eval "$(new_env t24)"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; . "$LIB"; . "$SCRIPTS/lib.sh"
  exec -a codex-centinela sleep 300 & cent=$!                 # lleva "codex" en argv (víctima del viejo -f)
  tail -f "$WORK/t20-codex.log" >/dev/null 2>&1 & cent2=$!    # ruta con 'codex' en argv
  obj="$(spawn_agent codex)"                                  # el ÚNICO objetivo legítimo (registrado, sesión propia)
  sleep 0.3
  printf '%s\n' "$obj" > "$AM_TEST_CROOT/.allowed-kill-pids"  # el centinela NO se registra
  am_ep_quiesce "channel:t24" codex 3 >/dev/null 2>&1
  am_ep_quiet "channel:t24" codex >/dev/null 2>&1 || true
  obj2="$(spawn_agent codex)"; sleep 0.2; printf '%s\n' "$obj2" > "$AM_TEST_CROOT/.allowed-kill-pids"
  tc_kill_wait t24 codex "$CUSER" 3 >/dev/null 2>&1
  sleep 0.2
  s1="$(alive "$cent")"; s2="$(alive "$cent2")"; o1="$(alive "$obj")"; o2="$(alive "$obj2")"
  kill -9 "$cent" "$cent2" "$obj" "$obj2" 2>/dev/null || true
  [ "$s1" = si ] && [ "$s2" = si ] && [ "$o1" = no ] && [ "$o2" = no ] \
    || { echo "FALLÓ: centinelas vivos=$s1/$s2 (esp. si/si) objetivos muertos=$o1/$o2 (esp. no/no)"; return 1; }
  return 0
)
run_t24; chk "24 centinela con 'codex' en argv sobrevive a quiesce/quiet/kill-wait; solo mueren los objetivos registrados" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 25. [TAL-8042] MOVE por CLI: rc por FASE del journal (SIGPIPE ignorado) =="
# auth-move.sh move corre el protocolo en un subshell con SIGPIPE ignorado y deriva el rc FINAL de la
# fase del journal del tx nuevo: DONE → 0 aunque la salida esté cerrada; commit (DEST_INSTALLED/VERIFIED)
# con anomalía → 4 (reparar EN destino, jamás restaurar al donante); antes del commit → rc original.
cli_env() { eval "$(new_env "$1")"; export SECRET_DIR AM_LEDGER AM_TEST_CROOT; seed_channel_auth "$AM_TEST_CROOT" chA codex "ACME-$1"; }
jfase() { grep -h -o '"fase": "[A-Z_]*"' "$SECRET_DIR"/journal/*.json 2>/dev/null | tail -1; }

run_t25a() (   # salida estándar CERRADA (lector que se va) tras DONE → rc 0
  cli_env cli-pipe
  bash "$SCRIPTS/auth-move.sh" move acme channel:chA channel:chB 2>"$WORK/t25a.err" | true
  rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || { echo "rc=$rc (esp. 0; 141 = SIGPIPE tras DONE)"; return 1; }
  [ "$(jfase)" = '"fase": "DONE"' ] || { echo "journal=$(jfase) (esp. DONE)"; return 1; }
  [ -f "$(auth_path "$AM_TEST_CROOT" chB codex)" ] && [ ! -f "$(auth_path "$AM_TEST_CROOT" chA codex)" ] || { echo "reparto de credencial incorrecto"; return 1; }
  return 0
)
run_t25a; chk "25a MOVE con la salida cerrada tras DONE → rc 0 (antes 141), journal DONE, destino propietario" "[ $? -eq 0 ]"

run_t25b() (   # muerte tras persistir DEST_INSTALLED → rc 4 (commit hecho; reparar EN destino)
  cli_env cli-post
  AM_FAILPOINT=post_persist_DEST_INSTALLED bash "$SCRIPTS/auth-move.sh" move acme channel:chA channel:chB >/dev/null 2>"$WORK/t25b.err"
  rc=$?
  [ "$rc" -eq 4 ] || { echo "rc=$rc (esp. 4)"; return 1; }
  [ "$(jfase)" = '"fase": "DEST_INSTALLED"' ] || { echo "journal=$(jfase) (esp. DEST_INSTALLED)"; return 1; }
  [ -f "$(auth_path "$AM_TEST_CROOT" chB codex)" ] && [ ! -f "$(auth_path "$AM_TEST_CROOT" chA codex)" ] || { echo "el destino debe ser propietario y el donante NO restaurado"; return 1; }
  return 0
)
run_t25b; chk "25b error tras DEST_INSTALLED → rc 4 (journal DEST_INSTALLED, destino propietario, donante NO restaurado)" "[ $? -eq 0 ]"

run_t25c() (   # error PREVIO al commit → rc≠0 y reconciliado (ABORTED, donante intacto)
  cli_env cli-pre
  AM_FAIL_FSYNC="snapshots" bash "$SCRIPTS/auth-move.sh" move acme channel:chA channel:chB >/dev/null 2>"$WORK/t25c.err"
  rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ] || { echo "rc=$rc (esp. ≠0 y ≠4)"; return 1; }
  [ "$(cat "$(auth_path "$AM_TEST_CROOT" chA codex)" 2>/dev/null)" = "ACME-cli-pre" ] || { echo "donante NO intacto"; return 1; }
  [ ! -f "$(auth_path "$AM_TEST_CROOT" chB codex)" ] || { echo "el destino no debe tener auth"; return 1; }
  return 0
)
run_t25c; chk "25c error previo al commit → rc≠0 (≠4), donante intacto, destino sin auth" "[ $? -eq 0 ]"

run_t25d() (   # health-check POST-commit fallido (timeout) → sigue siendo rc 4 por el CLI
  cli_env cli-health
  cnt="$WORK/t25d.cnt"; echo 0 > "$cnt"
  export AM_TEST_CODEX_COUNT="$cnt"
  cat > "$SHIMS/codex" <<'CODEX'
#!/usr/bin/env bash
n=$(cat "$AM_TEST_CODEX_COUNT"); n=$((n+1)); echo "$n" > "$AM_TEST_CODEX_COUNT"
if [ "$n" -ge 2 ]; then sleep 30; fi
exit 0
CODEX
  chmod +x "$SHIMS/codex"
  bash "$SCRIPTS/auth-move.sh" move acme channel:chA channel:chB >/dev/null 2>&1; rc=$?
  cp "$HERE/fake-codex.sh" "$SHIMS/codex"; chmod +x "$SHIMS/codex"
  [ "$rc" -eq 4 ] || { echo "rc=$rc (esp. 4)"; return 1; }
  return 0
)
run_t25d; chk "25d health-check post-commit fallido por el CLI → rc 4 (se conserva el contrato rc 0/3/4)" "[ $? -eq 0 ]"

# ==========================================================================
echo "== 26. [TAL-8042] paridad de las copias del snippet de procesos (duplicar antes que acoplar) =="
snippet_of() { # fichero → cuerpo del heredoc TF_PROC_EOF
  awk '/<<.TF_PROC_EOF.( \|\| true)?$/ {on=1; next} /^TF_PROC_EOF$/ {on=0} on' "$1"
}
S_LIB="$(snippet_of "$SCRIPTS/lib.sh")"; S_AM="$(snippet_of "$SCRIPTS/auth-move-lib.sh")"
snippet_ok() { [ -n "$1" ] && printf '%s' "$1" | grep -q '_tf_agent_scan()' && printf '%s' "$1" | grep -q '_tf_kill_wait()' && printf '%s' "$1" | grep -q '_tf_quiet()'; }
chk "snippet de lib.sh presente y con las tres funciones (_tf_agent_scan/_tf_kill_wait/_tf_quiet)" "snippet_ok \"\$S_LIB\""
chk "snippet de auth-move-lib.sh IDÉNTICO al de lib.sh" "[ \"\$S_LIB\" = \"\$S_AM\" ]"
TCO_LIB="$SCRIPTS/../../talent-channel-operation/scripts/lib.sh"
if [ -f "$TCO_LIB" ]; then
  S_TCO="$(snippet_of "$TCO_LIB")"
  chk "snippet de talent-channel-operation/lib.sh IDÉNTICO al de lib.sh" "[ \"\$S_LIB\" = \"\$S_TCO\" ]"
else
  ok "snippet TCO: skill vecino ausente en este layout (la paridad la asserta su propia suite)"
fi

# ==========================================================================
echo "== 27. [TAL-8042] RATCHET de la clase: ningún 'pgrep/pkill -u … -f' fuera de tests =="
# Detector aislado (con control positivo sintético): una línea de código con pgrep/pkill + -u + -f en
# cualquier orden. Los comentarios puros se ignoran. Allowlist de LO ACOTADO por `-P <pid>` (kill por
# PID concreto, nunca por patrón): talent-orchestrator/scripts/pozos-install-token*.sh — fuera de clase.
class_hits() { # raíz-de-skills → líneas "ruta:n" (sin tests, sin comentarios)
  grep -rnE '(pgrep|pkill)[^#]*(-u[[:space:]][^#]*[[:space:]]-[A-Za-z]*f[A-Za-z]*[[:space:]]|[[:space:]]-[A-Za-z]*f[A-Za-z]*[[:space:]][^#]*-u[[:space:]])' --include=*.sh "$@" 2>/dev/null \
    | grep -v '/tests/' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | cut -d: -f1,2
}
RAT_SYN="$WORK/ratchet-sintetico"; mkdir -p "$RAT_SYN"
printf '#!/bin/sh\npgrep -u "$U" -f codex | xargs kill -9\npkill -f x -u y\n# pgrep -u a -f b\n' > "$RAT_SYN/mal.sh"
chk "ratchet: control POSITIVO sintético (2 líneas de código cazadas, el comentario no)" "[ \"\$(class_hits '$RAT_SYN' | wc -l | tr -d ' ')\" = 2 ]"
SKILLS_ROOT="$(cd "$SCRIPTS/../.." && pwd)"
RAT_DIRS=("$SKILLS_ROOT"); [ -d "$SKILLS_ROOT/../scripts" ] && RAT_DIRS+=("$SKILLS_ROOT/../scripts")
chk "ratchet: el árbol REAL de skills/ y scripts/ tiene 0 líneas de la clase" "[ \"\$(class_hits \"\${RAT_DIRS[@]}\" | wc -l | tr -d ' ')\" = 0 ]"
# Excepciones DECLARADAS (no cuentan como la clase: acotadas por -P a un PID concreto, sin kill por patrón):
P_HITS="$(grep -rlE 'pgrep -P .* -f ' --include='pozos-install-token*.sh' "$SKILLS_ROOT" 2>/dev/null | wc -l | tr -d ' ')"
chk "ratchet: las excepciones '-P … -f' (pozos-install-token*, acotadas por PID padre) están anotadas y no crecen (<=3 ficheros)" "[ \"$P_HITS\" -le 3 ]"

# --- VERIFICACIÓN FINAL DE CANARIOS (TAL-5507 → TAL-8042) ---------------------------------------
# Debe ir DESPUÉS de todos los tests y ANTES del resumen: si CUALQUIER test mató colateral, los
# canarios (creados antes del primer test, jamás registrados ni excluidos) estarán muertos y la suite
# FALLA entera aunque todos los `chk` individuales sean verdes.
if [ "$(alive "$CANARIO_PID")" = si ] && [ "$(alive "$CANARIO2_PID")" = si ]; then
  ok "CANARIOS de colateral (argv 'codex-centinela' y argv[0] exacto 'codex') vivos al final del arnés"
else
  bad "CANARIO de colateral MURIÓ durante el arnés — algún test mató un proceso ajeno (ver TAL-8042)"
  CANARIO_MURIO=1
fi
kill -9 "$CANARIO_PID" "$CANARIO2_PID" 2>/dev/null || true

echo "== Ronda 1: identidad estable, comm íntegro y ejecutor protegido =="
for regression in exec reuse newline leading trailing comm self pipe heredoc; do
  python3 "$HERE/process-regressions.py" "$regression"
  chk "ronda1: $regression" "[ $? -eq 0 ]"
done
for regression in gone scan_gone unreadable reuse_stat; do
  python3 "$HERE/process-round2.py" "$regression"
  chk "ronda2: $regression (tres copias)" "[ $? -eq 0 ]"
done
for regression in zombie scan_zombie; do
  python3 "$HERE/process-round2.py" "$regression"
  chk "ronda3: $regression (tres copias)" "[ $? -eq 0 ]"
done

run_t25_old() (
  eval "$(new_env cli-old)"; . "$LIB"
  # Sin sesión ni MOVE: solo el diario sintético y el fallo temprano del CLI real.
  mkdir -p "$(am_journal_dir)"
  export SECRET_DIR AM_LEDGER
  for phase in DONE DEST_INSTALLED; do
    bash -c 'printf "{\"fase\": \"%s\"}\n" "$3" > "$1/journal/mv20000101T000000Z-$$-1.json"; exec bash "$2/auth-move.sh" move acme invalid invalid' _ "$SECRET_DIR" "$SCRIPTS" "$phase" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ] || return 1
  done
)
run_t25_old; chk "ronda2: diario antiguo DONE/DEST_INSTALLED del mismo PID no oculta fallo temprano" "[ $? -eq 0 ]"
run_t25_current() (
  eval "$(new_env cli-current)"; . "$LIB"
  mkdir -p "$(am_journal_dir)"
  for phase in DONE DEST_INSTALLED VERIFIED; do
    printf '{"fase": "%s"}\n' "$phase" > "$(am_journal_dir)/mv20260101T000000Z-$$-1.json"
    am_move_final_rc 7 "$$" 20260101T000000Z; rc=$?
    expected=4; [ "$phase" != DONE ] || expected=0
    [ "$rc" -eq "$expected" ] || return 1
  done
  am_move_final_rc 7 "$$" 20260101T000001Z; [ "$?" -eq 7 ]
)
run_t25_current; chk "ronda2: diario actual DONE=0, DEST_INSTALLED/VERIFIED=4; sin diario actual rc original" "[ $? -eq 0 ]"
if bash "$HERE/modelos-consumidores.sh"; then ok "salud y relanzamiento con registro; igualdad exacta del modelo"; else bad "salud, relanzamiento o igualdad exacta del modelo"; fi

# Consumidor real de env: solo incus y la configuración son fixtures.
push_git_case() (
  local fixture="$WORK/push-git-$1" target=vibe-channel-91 rc
  mkdir -p "$fixture/env"
  cp "$SCRIPTS/push-carril-env.sh" "$fixture/push-carril-env.sh"
  cp "$SCRIPTS/coderabbit-auth.sh" "$fixture/coderabbit-auth.sh"
  cat > "$fixture/00-config.sh" <<'EOF'
SECRET_DIR="$PUSH_FIXTURE"; COUNT=1; CUSER=actor; REPO_DIR=producto; ENV_DEST=.env.local
EOF
  cat > "$fixture/lib.sh" <<'EOF'
tc_channel_name() { echo vibe-channel-91; }
tc_channels() { tc_channel_name; }
tc_expected_profile() { [ "$PUSH_CASE" != runner ] && echo produccion || echo runner; }
tc_info() { :; }
tc_err() { echo "$*" >&2; }
tc_die() { echo "$*" >&2; exit 1; }
tc_push_secret_file() { printf 'push %s\n' "$2" >> "$PUSH_TRACE"; }
EOF
  printf 'GITHUB_TOKEN=token-sintetico\n' > "$fixture/env/vibe-channel-91.env"
  chmod 600 "$fixture/env/vibe-channel-91.env"
  export PUSH_FIXTURE="$fixture" PUSH_TRACE="$fixture/traza" PUSH_CASE="$1"
  incus() {
    python3 "$GH_CONTRATO" --orden incus "$@" || return $?
    printf '%s\n' "$*" >> "$PUSH_TRACE"
    case "${*: -1}" in
      *'gh auth login'*) [ "$(cat)" = token-sintetico ] ;;
      *'gh auth setup-git'*) [ "$PUSH_CASE" != fallo ] ;;
    esac
  }
  export -f incus
  [ "$1" != ajeno ] || target=runner-ajeno
  bash "$fixture/push-carril-env.sh" "$target" > "$fixture/salida" 2>&1; rc=$?
  case "$1" in
    verde) [ "$rc" = 0 ] && grep -q 'gh auth setup-git' "$PUSH_TRACE" && grep -q 'push vibe-channel-91' "$PUSH_TRACE" ;;
    fallo) [ "$rc" != 0 ] && grep -q 'gh auth setup-git' "$PUSH_TRACE" ;;
    ajeno) [ "$rc" != 0 ] && [ ! -e "$PUSH_TRACE" ] ;;
    runner) [ "$rc" != 0 ] && [ ! -e "$PUSH_TRACE" ] ;;
  esac
)
push_git_case verde; chk 'env canal: camino real configura login y ayudante git' '[ $? -eq 0 ]'
push_git_case fallo; chk 'env canal: fallo setup-git conserva rc rojo' '[ $? -eq 0 ]'
push_git_case ajeno; chk 'env canal: destino ajeno rechazado antes de transferir' '[ $? -eq 0 ]'
push_git_case runner; chk 'env canal: perfil runner rechazado antes de transferir' '[ $? -eq 0 ]'
# 21 — lanzadores EJECUTABLES claude-root/codex-root: `tmux respawn-pane` ejecuta con `bash -c` y NO lee el .bashrc, donde
# solo viven los alias. Las funciones se extraen del 02-golden.sh REAL (por ancla), no se duplican.
run_t21_texto() (
  unset -f incus
  t="$WORK/t21a"; mkdir -p "$t/bin"
  eval "$(sed -n '/^tc_launcher_text()/,/^}/p' "$SCRIPTS/02-golden.sh")"
  declare -F tc_launcher_text >/dev/null || { echo "sin-tc_launcher_text"; return 1; }
  tc_launcher_text claude --dangerously-skip-permissions > "$t/claude-root"
  tc_launcher_text codex --dangerously-bypass-approvals-and-sandbox > "$t/codex-root"
  chmod 755 "$t/claude-root" "$t/codex-root"
  bash -n "$t/claude-root" && bash -n "$t/codex-root" || { echo "bash-n"; return 1; }
  [ "$(head -n 1 "$t/claude-root")" = '#!/bin/bash' ] || { echo "shebang"; return 1; }
  grep -qxF 'IS_SANDBOX=1 exec claude --dangerously-skip-permissions "$@"' "$t/claude-root" || { echo "exec-claude"; return 1; }
  grep -qxF 'IS_SANDBOX=1 exec codex --dangerously-bypass-approvals-and-sandbox "$@"' "$t/codex-root" || { echo "exec-codex"; return 1; }
  printf '#!/bin/bash\nprintf "%%s|%%s\\n" "$IS_SANDBOX" "$*"\n' > "$t/bin/claude"; chmod 755 "$t/bin/claude"
  out="$(env -i PATH="$t:$t/bin:/usr/bin:/bin" /bin/bash -c 'claude-root --model m x')"
  [ "$out" = '1|--dangerously-skip-permissions --model m x' ] || { echo "ejecucion:$out"; return 1; }
)
out="$(run_t21_texto 2>&1)"; chk "21a lanzador: texto ejecutable (shebang, un solo exec con IS_SANDBOX=1 y los flags del alias, reenvía argumentos): ${out:-ok}" "[ -z '$out' ]"
run_t21_instala() (
  unset -f incus
  t="$WORK/t21b"; mkdir -p "$t/shim" "$t/home"
  printf '#!/bin/bash\nwhile [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done\nshift\nHOME="%s" exec /bin/bash -c "$1"\n' "$t/home" > "$t/shim/incus"
  chmod 755 "$t/shim/incus"
  eval "$(sed -n '/^tc_launcher_text()/,/^}/p;/^tc_install_launcher()/,/^}/p' "$SCRIPTS/02-golden.sh")"
  declare -F tc_install_launcher >/dev/null || { echo "sin-tc_install_launcher"; return 1; }
  GOLDEN=golden; CUSER=canal; tc_die() { echo "tc_die: $*" >&2; return 1; }
  export PATH="$t/shim:$PATH"
  tc_install_launcher claude-root claude --dangerously-skip-permissions || { echo "instala"; return 1; }
  tc_install_launcher claude-root claude --dangerously-skip-permissions || { echo "idempotencia"; return 1; }
  f="$t/home/.local/bin/claude-root"
  [ -x "$f" ] && [ "$(stat -c %a "$f")" = 755 ] || { echo "modo-o-ausente"; return 1; }
  [ "$(cat "$f")" = "$(tc_launcher_text claude --dangerously-skip-permissions)" ] || { echo "contenido"; return 1; }
)
out="$(run_t21_instala 2>&1)"; chk "21b lanzador: se instala en ~/.local/bin con modo 0755, por stdin e idempotente: ${out:-ok}" "[ -z '$out' ]"
run_t21_cableado() (
  g="$SCRIPTS/02-golden.sh"
  grep -qxF 'CLAUDE_ROOT_FLAGS="--dangerously-skip-permissions"' "$g" || { echo "flags-claude"; return 1; }
  grep -qxF 'CODEX_ROOT_FLAGS="--dangerously-bypass-approvals-and-sandbox"' "$g" || { echo "flags-codex"; return 1; }
  grep -qxF 'tc_install_launcher claude-root claude "$CLAUDE_ROOT_FLAGS"' "$g" || { echo "instala-claude"; return 1; }
  grep -qxF 'tc_install_launcher codex-root codex "$CODEX_ROOT_FLAGS"' "$g" || { echo "instala-codex"; return 1; }
  grep -qF 'alias claude-root=\"IS_SANDBOX=1 claude $CLAUDE_ROOT_FLAGS\"' "$g" || { echo "alias-claude-otra-fuente"; return 1; }
  grep -qF 'alias codex-root=\"IS_SANDBOX=1 codex $CODEX_ROOT_FLAGS\"' "$g" || { echo "alias-codex-otra-fuente"; return 1; }
)
out="$(run_t21_cableado 2>&1)"; chk "21c 02-golden.sh instala AMBOS lanzadores y los alias del .bashrc salen de los MISMOS flags (una sola fuente): ${out:-ok}" "[ -z '$out' ]"
run_t21_verifica() (
  g="$SCRIPTS/02-golden.sh"
  v="$(grep -nF 'test -x "$HOME/.local/bin/claude-root" && test -x "$HOME/.local/bin/codex-root"' "$g" | head -1 | cut -d: -f1)"
  r="$(grep -nF 'tc_renderer_apply_one "$GOLDEN" || tc_die' "$g" | head -1 | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$r" ] && [ "$v" -lt "$r" ] || { echo "orden-o-ausente"; return 1; }
  sed -n "$((v + 1)),$((v + 2))p" "$g" | grep -qF 'tc_die' || { echo "no-fail-closed"; return 1; }
)
out="$(run_t21_verifica 2>&1)"; chk "21d 02-golden.sh exige (fail-closed) con test -x, como el usuario del canal, que ambos lanzadores existan en ~/.local/bin y sean ejecutables, antes del renderer (que resuelvan en el PATH del pane lo comprueba el despacho): ${out:-ok}" "[ -z '$out' ]"
bash "$SCRIPTS/../tests/coderabbit-diagnosticos.sh"; chk 'autenticación real diagnostica cada causa sin mostrar valores' '[ $? -eq 0 ]'
# Los SKIP del consumidor son rutas soportadas, no casos omitidos del arnés.
# Conservarlos íntegros en evidencia; el agregado recibe el resumen de casos.
etapas_log="${TF_SUITES_LOG_DIR:-${SALIDA:-$WORK}}/verify-etapas-canales.log"
python3 "$HERE/verify-etapas.py" --log "$etapas_log"; etapas_rc=$?
[ "$etapas_rc" -eq 0 ] || tail -n 25 "$etapas_log" >&2
chk 'verificación real por etapas y F2 sin registro' "[ $etapas_rc -eq 0 ]"
if bash "$HERE/fase-papel-json.sh"; then ok "fase recuperada, papel literal y documento JSON único"; else bad "fase, papel literal o JSON único"; fi
if bash "$HERE/panel-durable.sh"; then ok "sesión persistida y selección estricta del panel"; else bad "sesión persistida o selección del panel"; fi
echo "================  PASS=$PASS  FAIL=$FAIL  ================"
[ "$FAIL" -eq 0 ] && [ "$CANARIO_MURIO" -eq 0 ]
