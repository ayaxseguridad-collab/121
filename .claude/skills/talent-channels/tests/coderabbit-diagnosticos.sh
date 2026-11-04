#!/usr/bin/env bash
# Causas del método real con CLI y fallos de filesystem confinados.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin"
cat > "$T/bin/coderabbit" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'auth status' ] || exit 2
exit "${CLI_RC:-0}"
EOF
chmod +x "$T/bin/coderabbit"
export HOME="$T/home" PATH="$T/bin:$PATH"
source_file="$T/origen.env"
# shellcheck source=/dev/null
. "$HERE/../scripts/coderabbit-auth.sh"
probe() (
  case "$1" in
    directorio) mkdir() { return 1; } ;;
    temporal) mktemp() { return 1; } ;;
    escritura) mv() { return 1; } ;;
  esac
  tc_coderabbit_auth "$source_file"
)
for scenario in origen ausente serial directorio temporal escritura cli verde; do
  printf 'CODERABBIT_API_KEY=canario-sintetico\n' > "$source_file"
  chmod 600 "$source_file"
  CLI_RC=0; export CLI_RC
  case "$scenario" in
    origen) chmod 644 "$source_file"; cause='origen ausente, ajeno o modo inseguro' ;;
    ausente) printf 'OTRA_CLAVE=canario-sintetico\n' > "$source_file"; cause='clave ausente' ;;
    serial) printf 'CODERABBIT_API_KEY=canario-sintetico\001\n' > "$source_file"; cause='caracteres no serializables' ;;
    directorio) cause='no se pudo preparar el directorio' ;;
    temporal) cause='escritura temporal fallida' ;;
    escritura) cause='escritura de autenticación fallida' ;;
    cli) CLI_RC=1; cause='estado del CLI no autenticado' ;;
    verde) cause='' ;;
  esac
  rc=0; probe "$scenario" > "$T/out" 2> "$T/err" || rc=$?
  if [ "$scenario" = verde ]; then
    [ "$rc" = 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]
  else
    [ "$rc" != 0 ] && grep -qF "$cause" "$T/err" && grep -q 'fichero=' "$T/err"
    ! grep -q canario-sintetico "$T/out" "$T/err"
  fi
  printf 'PASS autenticación: %s\n' "$scenario"
done
