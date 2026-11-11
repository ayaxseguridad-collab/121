#!/usr/bin/env bash
# Pruebas de higiene extraídas del arnés del motor fijado; residuos y runtime aislados.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 — [$2]"; fi; }

echo "== TAL-6809.2 runner-clean.sh: higiene ownership-gated =="
RC_6809="$SCRIPTS/runner-clean.sh"
( set -e
  RHOME="$WORK/tal6809-rhome"; mkdir -p "$RHOME/repo"
  git -C "$RHOME/repo" init -q; git -C "$RHOME/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$WORK/tmproot" "$WORK/xdg"
  RC_TMP_ROOT="$WORK/tmproot" XDG_RUNTIME_DIR="$WORK/xdg" bash "$RC_6809" --runner-home "$RHOME" --maquina test-vm >"$WORK/runner-clean.log" 2>&1
  grep -q '^RC_INODES test-vm ' "$WORK/runner-clean.log"; rc=$?
  rm -f "$WORK/runner-clean.log"; exit "$rc" )
chk "TAL-6809 runner-clean.sh: SIEMPRE emite RC_INODES con la máquina pedida (verde legítimo, no 'no corrí')" "[ $? -eq 0 ]"

# [Acta 1 v3, NO MEDIDO señalado] el caso real que motiva rc_umbral_inodos (%IUse alto) nunca se
# había ejercitado — el único test de arriba mide un filesystem ocioso (%IUse bajo). Seam
# `RC_DF_BIN`: un `df` señuelo reproduce la FORMA exacta de salida de `df -iP` con un %IUse alto,
# sin necesitar agotar inodos de verdad en este sandbox.
( set -e
  # shellcheck source=skills/talent-channels/scripts/runner-clean.sh
  RC_NO_MAIN=1 . "$RC_6809"
  FAKEDF="$WORK/tal6809-fakedf"; mkdir -p "$FAKEDF"
  cat > "$FAKEDF/df" <<'DFEOF'
#!/usr/bin/env bash
printf 'Filesystem      Inodes   IUsed   IFree IUse%% Mounted on\n'
printf '/dev/fake      1000000  967000   33000   97%% /\n'
DFEOF
  chmod +x "$FAKEDF/df"
  out="$(RC_DF_BIN="$FAKEDF/df" rc_umbral_inodos "$WORK" 85 test-vm)"
  [ "$out" = "RC_INODES test-vm 97 85" ] )
chk "TAL-6809 [Acta1-v3-NOMEDIDO] rc_umbral_inodos: %IUse ALTO (97%, señuelo df -iP) se extrae y publica correctamente — antes solo se probaba el caso ocioso" "[ $? -eq 0 ]"

(
  # shellcheck source=skills/talent-channels/scripts/runner-clean.sh
  RC_NO_MAIN=1 . "$RC_6809"
  PROPIO="$WORK/tal6809-propio.txt"; : > "$PROPIO"
  rc_es_propio "$PROPIO" )
chk "TAL-6809 rc_es_propio: fichero del uid actual -> rc 0 (es mío)" "[ $? -eq 0 ]"

(
  # shellcheck source=skills/talent-channels/scripts/runner-clean.sh
  RC_NO_MAIN=1 . "$RC_6809"
  AJENO="$WORK/tal6809-ajeno.txt"; : > "$AJENO"
  FAKEBIN="$WORK/tal6809-fakebin"; mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/id" <<'IDEOF'
#!/usr/bin/env bash
case "$*" in -u) echo 999999;; *) command id "$@";; esac
IDEOF
  chmod +x "$FAKEBIN/id"
  PATH="$FAKEBIN:$PATH" rc_es_propio "$AJENO" )
chk "TAL-6809 rc_es_propio: uid simulado DISTINTO del dueño real -> rc 1 (no es mío, PATH-shim local sin tocar el global)" "[ $? -eq 1 ]"

( set -e
  # shellcheck source=skills/talent-channels/scripts/runner-clean.sh
  RC_NO_MAIN=1 . "$RC_6809"
  DIRTMP="$WORK/tal6809-limpiatmp"; mkdir -p "$DIRTMP"
  AJENO="$DIRTMP/residuo-ajeno-XYZ"; echo dato-ajeno > "$AJENO"
  FAKEBIN="$WORK/tal6809-fakebin2"; mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/id" <<'IDEOF'
#!/usr/bin/env bash
case "$*" in -u) echo 999999;; *) command id "$@";; esac
IDEOF
  chmod +x "$FAKEBIN/id"
  out="$(PATH="$FAKEBIN:$PATH" rc_limpia_tmp "$DIRTMP/residuo-ajeno-*" 0)"
  [ -f "$AJENO" ] || exit 1
  printf '%s' "$out" | grep -q "TMP_AJENO $AJENO" )
chk "TAL-6809 rc_limpia_tmp: residuo de uid ajeno NO se borra y se reporta por nombre" "[ $? -eq 0 ]"

[ "$((PASS + FAIL))" -eq 5 ] || bad 'cobertura: deben ejecutarse los cinco casos del motor'
echo "test-agregador-runner-clean: FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
