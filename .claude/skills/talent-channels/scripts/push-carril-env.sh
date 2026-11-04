#!/usr/bin/env bash
# push-carril-env.sh — Empuja el env POR CARRIL ($SECRET_DIR/env/<canal>.env) al repo del carril
# y autentica gh DENTRO del carril con su GITHUB_TOKEN. Uso: push-carril-env.sh <canal>|all
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
# shellcheck source=/dev/null
. "$HERE/coderabbit-auth.sh"

arg="${1:-all}"
targets=()
if [ "$arg" = "all" ]; then
  for y in $(seq 1 "${COUNT:?COUNT no definido}"); do targets+=("$(tc_channel_name "$y")"); done
else
  # Fail-closed ANTES de empujar secretos: solo canales del contrato de esta máquina
  # (${PREFIX}${MACHINE_NUM}<y> con y dentro de COUNT). Un typo o un contenedor ajeno no
  # debe recibir .env, auth de gh ni sesión de CodeRabbit.
  _valid=no
  for y in $(seq 1 "${COUNT:?COUNT no definido}"); do
    [ "$arg" = "$(tc_channel_name "$y")" ] && { _valid=yes; break; }
  done
  [ "$_valid" = yes ] || tc_die "target inválido: '$arg' (usa 'all' o un canal de esta máquina: $(tc_channels | tr '\n' ' '))"
  targets=("$arg")
fi

cr_auth_failures=0   # carriles con CODERABBIT_API_KEY presente pero auth fallida (fail-fast al final)

for ch in "${targets[@]}"; do
  case "$(tc_expected_profile "$ch")" in
    runner) tc_die "$ch: perfil runner no recibe credenciales" ;;
    invalid) tc_die "$ch: perfil inválido" ;;
  esac
  envf="$SECRET_DIR/env/$ch.env"
  [ -s "$envf" ] || { tc_info "$ch: sin $envf (saltado)"; continue; }
  echo "-- $ch --"
  # push del env al repo del carril (0600)
  tc_push_secret_file "$envf" "$ch" "/home/$CUSER/$REPO_DIR/$ENV_DEST" 600
  tc_info "env empujado a ~/$REPO_DIR/$ENV_DEST"
  # gh auth login --with-token dentro del carril (token de ESTE carril), sin imprimir
  # GITHUB_TOKEN es OPCIONAL: con set -e, un grep sin coincidencia abortaría la fase 'env'.
  ghtok_line="$(grep -m1 '^GITHUB_TOKEN=' "$envf" || true)"
  ghtok="${ghtok_line#GITHUB_TOKEN=}"
  # [CR] tolerar dotenv con comillas (KEY="valor"): gh recibiria las comillas literales
  ghtok="${ghtok%\"}"; ghtok="${ghtok#\"}"; ghtok="${ghtok%\'}"; ghtok="${ghtok#\'}"
  if [ -n "$ghtok" ]; then
    set +x
    # [CR] timeout acotado (mismo patron que coderabbit auth status): una llamada de red colgada
    # no debe detener el push multi-carril entero.
    printf '%s' "$ghtok" | incus exec "$ch" -- su - "$CUSER" -c 'rm -f ~/.config/gh/hosts.yml 2>/dev/null; if command -v timeout >/dev/null 2>&1; then timeout 30 gh auth login --with-token; else gh auth login --with-token; fi'
    incus exec "$ch" -- su - "$CUSER" -c 'if command -v timeout >/dev/null 2>&1; then timeout 30 gh auth setup-git; else gh auth setup-git; fi >/dev/null 2>&1 && echo "  gh autenticado per-carril"'
    unset ghtok
  else
    tc_info "sin GITHUB_TOKEN en el env de $ch (gh queda sin auth)"
  fi
  # CodeRabbit CLI auth per-carril (TAL-1512): el CLI NO lee CODERABBIT_API_KEY del entorno; usa la sesión
  # en ~/.coderabbit/auth.json. El host solo comprueba presencia (no lee el valor); la sesión se configura
  # DENTRO del carril sourceando el .env.local ya empujado y escribiendo el auth.json con printf builtin
  # (la key NUNCA toca el argv de un proceso externo). Así ni el setup ni el review pre-PR exponen el secret.
  # FAIL-FAST (no WARN-y-sigo): si la key está presente y el auth falla, el carril quedaría con un auth.json
  # viejo y el review pre-PR correría con identidad/org equivocada. Reemplazamos la sesión y validamos
  # `auth status`; si algo falla, se cuenta y el script sale no-cero al final.
  # SECRET HANDLING: el CLI solo acepta --api-key por argv (lo expondría en ps); escribimos
  # ~/.coderabbit/auth.json directo con `printf` BUILTIN (la key NO toca el argv de ningún proceso externo).
  # Formato verificado {"type":"api_key","apiKey":"<key>"}. NO hay fallback a `auth login` (reintroduciría el
  # secret en argv): si el formato cambiara, FALLA CERRADO y se escala. Leemos SOLO la key del .env.local
  # (sin `set -a`/source, que exportaría TODOS los secrets del .env.local al proceso hijo `auth status`).
  # Escritura temp+`mv` ATÓMICA y fail-closed: un printf a medias no deja un auth.json parcial/stale que
  # valide falsamente, y cualquier fallo aborta ANTES de `auth status`.
  if grep -q '^CODERABBIT_API_KEY=' "$envf"; then
    printf -v cr_command '%s\ntc_coderabbit_auth %q' "$(declare -f tc_coderabbit_auth)" "/home/$CUSER/$REPO_DIR/$ENV_DEST"
    if incus exec "$ch" -- su - "$CUSER" -c "$cr_command"; then
      tc_info "coderabbit autenticado per-carril"
    else
      tc_err "$ch: coderabbit auth (escritura de auth.json/status) FALLÓ — carril SIN auth válida para el review pre-PR"
      cr_auth_failures=$((cr_auth_failures + 1))
    fi
  else
    tc_info "sin CODERABBIT_API_KEY en el env de $ch (perfil PRODUCCION — correcto: CodeRabbit lo consume el Mergeador; ver references/05)"
    # Sin key: limpiar cualquier sesión vieja para que el carril NO reuse credenciales antiguas.
    # NO enmascarar el fallo con `|| true`: si no se puede limpiar, el carril quedaría con sesión CR stale
    # (review con org/identidad equivocada). Se cuenta como failure (no aborta el loop multi-carril, pero el
    # script sale no-cero al final → fail-closed diferido).
    if ! incus exec "$ch" -- su - "$CUSER" -c 'rm -f "$HOME/.coderabbit/auth.json" 2>/dev/null'; then
      tc_err "$ch: no se pudo limpiar el auth.json viejo (carril sin key) — posible sesión CR stale"
      cr_auth_failures=$((cr_auth_failures + 1))
    fi
  fi
done
[ "$cr_auth_failures" -eq 0 ] || tc_die "$cr_auth_failures carril(es) con CODERABBIT_API_KEY pero auth fallida — corregir antes de usar el review pre-PR (carriles afectados arriba)."
echo "✅ push-carril-env completo."
