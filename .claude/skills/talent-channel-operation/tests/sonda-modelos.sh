#!/usr/bin/env bash
# Sonda real con transporte doble: nunca se llega a leer una credencial.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TCO_MODELOS_REGISTRO="$T/modelos.conf"
# shellcheck source=/dev/null
. "$HERE/../scripts/lib.sh"
TCO_CUSER=operador
tco_container() { [ "${STATE:-}" != tardio ] || rm -f "$TCO_MODELOS_REGISTRO"; printf 'ct-%s' "$1"; }
incus() { printf '%s' "$*" > "$T/transporte"; return 7; }
pass=0; fail=0
for STATE in valido ausente invalido tardio; do
  rm -f "$TCO_MODELOS_REGISTRO" "$T/transporte"
  case "$STATE" in
    valido|tardio) printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 6.2 sonnet 6.2 > "$TCO_MODELOS_REGISTRO" ;;
    invalido) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;;
  esac
  rc=0; tco_reauth_carril 01 02 > "$T/out" 2>&1 || rc=$?
  good=0
  if [ "$STATE" = valido ]; then
    [ "$rc" != 0 ] && grep -Fq -- "--model 'claude-sonnet-6.2'" "$T/transporte" && good=1
  else
    [ "$rc" != 0 ] && [ ! -e "$T/transporte" ] && grep -q 'resolver-modelos.sh' "$T/out" && good=1
  fi
  if [ "$good" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL sonda $STATE"; fi
done
printf 'RESULTADO sonda PASS=%s FAIL=%s TOTAL=4\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 4 ]
