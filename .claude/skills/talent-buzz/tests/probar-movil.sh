#!/usr/bin/env bash
# Fixtures de movil.sh (sin flutter: aqui se prueba la MECANICA de inyeccion
# y los validadores; el build y las verificaciones V1-V4 del APK se ejercitan
# en el build real). movil.sh se sourcea gracias a su guard (leccion
# INV-TB-002: sourcear jamas ejecuta).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/movil.sh
source "$DIR/../scripts/movil.sh"

ok()   { echo "OK  $1"; }
mal()  { echo "FALLO $1"; fallos=$((fallos+1)); }
caso() { # $1 descripcion, $2 rc esperado, resto: comando
  local desc="$1" esperado="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if { [ "$esperado" = "no0" ] && [ "$rc" -ne 0 ]; } \
     || { [ "$esperado" != "no0" ] && [ "$rc" -eq "$esperado" ]; }; then
    ok "$desc"
  else
    mal "$desc (rc=$rc, esperado $esperado)"
  fi
}

# ── ip_tailnet_valida: bordes exactos de 100.64.0.0/10 ──────────────────────
caso "100.64.0.0 es tailnet" 0 ip_tailnet_valida 100.64.0.0
caso "100.100.1.2 es tailnet" 0 ip_tailnet_valida 100.100.1.2
caso "100.127.255.255 es tailnet" 0 ip_tailnet_valida 100.127.255.255
caso "100.63.255.255 NO es tailnet" no0 ip_tailnet_valida 100.63.255.255
caso "100.128.0.0 NO es tailnet" no0 ip_tailnet_valida 100.128.0.0
caso "10.0.0.1 NO es tailnet" no0 ip_tailnet_valida 10.0.0.1
caso "basura NO es tailnet" no0 ip_tailnet_valida cualquier-cosa
caso "octeto fuera de rango NO es tailnet" no0 ip_tailnet_valida 100.64.0.999

# ── host_valido: MagicDNS exacto, sin guion bajo ni mayusculas ──────────────
caso "magicdns valido" 0 host_valido maquina.tailnet-abc.ts.net
caso "guion bajo rechazado (neutraliza placeholders)" no0 host_valido mal_host.ts.net
caso "mayusculas rechazadas" no0 host_valido Maquina.ts.net
caso "vacio rechazado" no0 host_valido ""

# ── host_acreditado (M11): un dominio publico jamas autoriza cleartext ──────
caso "example.com NO se acredita (no es *.ts.net)" no0 host_acreditado example.com
caso "magicdns inexistente NO se acredita (sin resolucion)" no0 host_acreditado no-existe-para-nada.ts.net
# Positivo oportunista: si esta maquina tiene tailscale con MagicDNS, su
# propio nombre debe acreditarse (si no hay tailnet: SKIP explicito).
SELF_DNS="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
if [ -n "$SELF_DNS" ]; then
  caso "el MagicDNS propio ($SELF_DNS) se acredita" 0 host_acreditado "$SELF_DNS"
else
  echo "SKIP host_acreditado positivo (esta maquina no tiene tailnet)"
fi

# ── exigir_0600 (M12): secretos reutilizados con permisos verificados ───────
SEC="$TMP/secreto.env"
touch "$SEC" && chmod 600 "$SEC"
caso "secreto 0600 propio se acepta" 0 exigir_0600 "$SEC"
chmod 644 "$SEC"
caso "secreto 0644 se rechaza (backup laxo)" no0 exigir_0600 "$SEC"
caso "secreto inexistente se rechaza" no0 exigir_0600 "$TMP/no-existe.env"

# ── inyectar_autoridad sobre un export sintetico ────────────────────────────
arbol() { # $1 destino; crea la pareja de ficheros con el placeholder 1 vez
  local d="$1"
  mkdir -p "$d/mobile/lib/shared/relay" "$d/mobile/android/app/src/main/res/xml"
  printf "const String kAuthorizedCleartextHost = '%s';\n" "$PLACEHOLDER" \
    > "$d/mobile/lib/shared/relay/relay_url_policy.dart"
  printf '<network-security-config>\n    <domain includeSubdomains="false">%s</domain>\n</network-security-config>\n' "$PLACEHOLDER" \
    > "$d/mobile/android/app/src/main/res/xml/network_security_config.xml"
}

HOST=maquina.tailnet-abc.ts.net

# 1. Inyeccion feliz con dos IPs extra
E="$TMP/e1"; arbol "$E"
if inyectar_autoridad "$E" "$HOST" 100.70.0.9 100.71.0.7 >/dev/null 2>&1; then
  NSC="$E/mobile/android/app/src/main/res/xml/network_security_config.xml"
  DARTF="$E/mobile/lib/shared/relay/relay_url_policy.dart"
  if grep -q "'$HOST'" "$DARTF" \
     && grep -q ">$HOST<" "$NSC" \
     && grep -q ">100.70.0.9<" "$NSC" \
     && grep -q ">100.71.0.7<" "$NSC" \
     && ! grep -q "$PLACEHOLDER" "$DARTF" "$NSC"; then
    ok "inyeccion sustituye host en ambas capas y añade las IPs"
  else
    mal "inyeccion: contenido inesperado tras sustituir"
  fi
else
  mal "inyeccion feliz devolvio error"
fi

# 1b. IP que el sed no puede insertar -> fail-closed (el sed que no matchea
#     no falla solo; finding CodeRabbit r-E2). Se rompe el patron del NSC
#     tras el placeholder para que la insercion de la IP no encuentre ancla.
E="$TMP/e1b"; arbol "$E"
sed -i 's|includeSubdomains="false"|includeSubdomains="true"|' \
  "$E/mobile/android/app/src/main/res/xml/network_security_config.xml"
caso "IP no insertada falla cerrado" no0 inyectar_autoridad "$E" "$HOST" 100.70.0.9

# 2. Placeholder duplicado en el Dart -> fail-closed (patch desalineado)
E="$TMP/e2"; arbol "$E"
echo "// $PLACEHOLDER" >> "$E/mobile/lib/shared/relay/relay_url_policy.dart"
caso "placeholder duplicado falla cerrado" no0 inyectar_autoridad "$E" "$HOST"

# 3. Falta el network security config -> fail-closed
E="$TMP/e3"; arbol "$E"
rm "$E/mobile/android/app/src/main/res/xml/network_security_config.xml"
caso "sin network_security_config falla cerrado" no0 inyectar_autoridad "$E" "$HOST"

# 4. Placeholder ausente (cero veces) -> fail-closed
E="$TMP/e4"; arbol "$E"
sed -i "s/$PLACEHOLDER/ya-sustituido.example/" \
  "$E/mobile/lib/shared/relay/relay_url_policy.dart"
caso "placeholder ausente falla cerrado" no0 inyectar_autoridad "$E" "$HOST"

# ── coherencia con los patches reales ───────────────────────────────────────
# El placeholder que movil.sh sustituye debe ser EXACTAMENTE el que traen los
# ficheros del patch 02 (una vez por fichero destino).
P02="$DIR/../assets/patches/02-movil-cleartext-esquemas.patch"
if [ "$(grep -c "kAuthorizedCleartextHost = '$PLACEHOLDER'" "$P02")" -eq 1 ] \
   && [ "$(grep -c ">$PLACEHOLDER<" "$P02")" -eq 1 ]; then
  ok "patch 02 trae el placeholder una vez por capa (Dart + xml)"
else
  mal "patch 02 y movil.sh discrepan en el placeholder"
fi

if [ "$fallos" -eq 0 ]; then echo "probar-movil: TODO OK"; else echo "probar-movil: $fallos fallos"; exit 1; fi
