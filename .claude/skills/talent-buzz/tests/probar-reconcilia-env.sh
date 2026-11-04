#!/usr/bin/env bash
# Fixtures de la reconciliacion del .env (huecos 6-7 de la ronda de
# seguridad, sin docker): un .env heredado con claves invariantes
# divergentes (imagen no pinneada, membership desactivado) se reconcilia por
# reescritura atomica CONSERVANDO los secretos byte a byte; permisos laxos
# fallan cerrado ANTES de tocar nada; el caso limpio es idempotente; el HMAC
# aparece exactamente una vez.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib-seguridad.sh
source "$DIR/../scripts/lib-seguridad.sh"

ok()  { echo "OK  $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else mal "$d"; fi; }

# Secretos sinteticos NO matcheables por el gate M5 (sin hex64 continuo).
SECRETO_PG="pass-postgres-sintetica-12345"
SECRETO_HMAC="hmac-sintetico-abcdef-67890"

env_heredado() { # $1 destino: .env con claves divergentes + secretos
  cat > "$1" <<EOF
BUZZ_IMAGE=ghcr.io/block/buzz:main
BUZZ_DOMAIN=viejo.example.com
RELAY_URL=ws://viejo.example.com
BUZZ_HTTP_PORT=80
BUZZ_REQUIRE_RELAY_MEMBERSHIP=false
POSTGRES_PASSWORD=$SECRETO_PG
BUZZ_GIT_HOOK_HMAC_SECRET=$SECRETO_HMAC
EOF
  chmod 600 "$1"
}

OBJETIVO=(
  "BUZZ_IMAGE=buzz-relay:pin-exacto"
  "BUZZ_DOMAIN=maquina.tailnet.ts.net"
  "RELAY_URL=ws://maquina.tailnet.ts.net"
  "BUZZ_HTTP_PORT=80"
  "BUZZ_BIND_IP=100.64.9.9"
  "BUZZ_REQUIRE_RELAY_MEMBERSHIP=true"
)

# Huella completa de inmutabilidad: contenido byte a byte (cmp) + modo,
# inode, dueño y mtime (CodeRabbit rA: "$(cat)" pierde bytes finales y no
# detecta un reemplazo del fichero).
huella() { stat -c '%a %i %U %Y' "$1"; }

# 1. Permisos laxos -> fail-closed ANTES de tocar (el fichero queda INTACTO)
E="$TMP/laxo.env"; env_heredado "$E"; chmod 644 "$E"
cp "$E" "$TMP/laxo.copia"; H_ANTES="$(huella "$E")"
rc=0; reconciliar_env "$E" "${OBJETIVO[@]}" 2>/dev/null || rc=$?
chk "0644 heredado falla cerrado" test "$rc" -ne 0
chk "0644: contenido byte a byte intacto" cmp -s "$E" "$TMP/laxo.copia"
chk "0644: modo/inode/dueño/mtime intactos" test "$(huella "$E")" = "$H_ANTES"

# 2. Heredado 0600 con claves divergentes -> reconciliado, secretos intactos
E="$TMP/heredado.env"; env_heredado "$E"
reconciliar_env "$E" "${OBJETIVO[@]}" || mal "reconciliacion devolvio error"
chk "imagen re-pinneada (bypass M3 cerrado)" grep -q "^BUZZ_IMAGE=buzz-relay:pin-exacto$" "$E"
chk "membership reactivado" grep -q "^BUZZ_REQUIRE_RELAY_MEMBERSHIP=true$" "$E"
chk "BUZZ_BIND_IP añadido (clave ausente)" grep -q "^BUZZ_BIND_IP=100.64.9.9$" "$E"
chk "RELAY_URL reconciliada" grep -q "^RELAY_URL=ws://maquina.tailnet.ts.net$" "$E"
chk "secreto postgres byte a byte" grep -q "^POSTGRES_PASSWORD=$SECRETO_PG$" "$E"
chk "secreto HMAC byte a byte" grep -q "^BUZZ_GIT_HOOK_HMAC_SECRET=$SECRETO_HMAC$" "$E"
chk "HMAC exactamente una ocurrencia" test "$(grep -c '^BUZZ_GIT_HOOK_HMAC_SECRET=' "$E")" -eq 1
chk "modo final 0600" test "$(stat -c '%a' "$E")" = "600"

# 2b. Clave DUPLICADA en el heredado (p. ej. dos HMAC: compose usaria "el
#     ultimo que gane" — identidad ambigua) -> fail-closed, fichero INTACTO
E2="$TMP/duplicado.env"; env_heredado "$E2"
echo "BUZZ_GIT_HOOK_HMAC_SECRET=otro-hmac-distinto-999" >> "$E2"
cp "$E2" "$TMP/dup.copia"; H_ANTES2="$(huella "$E2")"
rc=0; reconciliar_env "$E2" "${OBJETIVO[@]}" 2>/dev/null || rc=$?
chk "HMAC duplicado falla cerrado" test "$rc" -ne 0
chk "duplicado: contenido byte a byte intacto" cmp -s "$E2" "$TMP/dup.copia"
chk "duplicado: modo/inode/dueño/mtime intactos" test "$(huella "$E2")" = "$H_ANTES2"

# 2c. Valor con metacaracteres de sed (&, \, |) se reconcilia LITERAL
E3="$TMP/meta.env"; env_heredado "$E3"
reconciliar_env "$E3" 'BUZZ_DOMAIN=a&b\c|d.ts.net' || mal "metacaracteres: error inesperado"
chk "valor con &, \\ y | queda literal" grep -qF 'BUZZ_DOMAIN=a&b\c|d.ts.net' "$E3"

# 2d. Valor con salto de linea -> fail-closed (romperia el formato .env)
E4="$TMP/nl.env"; env_heredado "$E4"
rc=0; reconciliar_env "$E4" "BUZZ_DOMAIN=linea1
linea2" 2>/dev/null || rc=$?
chk "valor con salto de linea falla cerrado" test "$rc" -ne 0

# 3. Idempotencia: segunda pasada no cambia un byte (cmp, no $(cat)). Se fija E
#    explicitamente al .env YA reconciliado del caso 2 (heredado.env): mas
#    arriba se usan E2/E3/E4 para casos de rechazo (no reconciliados) — anclar
#    aqui evita cualquier ambiguedad sobre cual es la baseline.
E="$TMP/heredado.env"
cp "$E" "$TMP/idem.copia"
reconciliar_env "$E" "${OBJETIVO[@]}" || mal "segunda pasada devolvio error"
chk "idempotente (segunda pasada identica byte a byte)" cmp -s "$E" "$TMP/idem.copia"

# 4. Sin residuos de la escritura atomica
chk "sin temporales residuales" test -z "$(find "$TMP" -name '*.env.??????' -print -quit)"

if [ "$fallos" -eq 0 ]; then echo "probar-reconcilia-env: TODO OK"; else echo "probar-reconcilia-env: $fallos fallos"; exit 1; fi
