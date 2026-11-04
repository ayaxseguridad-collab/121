#!/usr/bin/env bash
# 00-intake.sh — PRIMER paso del runtime. El skill PREGUNTA (no asume archivos):
#   nº de máquina, repo, nº de canales, y credenciales (globales + por carril).
# Escribe elecciones no-secretas en $SECRET_DIR/intake.conf y secretos (0600) en $SECRET_DIR.
# NUNCA imprime valores de secretos. NO toca Linear/Supabase/prod.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TC_INVOKE_CWD="${TC_INVOKE_CWD:-$PWD}"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

# Siembra/actualiza el perfil declarado de cada canal en channel-profiles.list (idempotente).
# Reutiliza channel-profiles.sh set (ya probado en run_t17a); no trunca el mapa, por lo que los
# canales fuera de COUNT quedan intactos. Enter conserva el perfil actual si es válido; un perfil
# corrupto preexistente se señala como inválido visible y requiere elección explícita (no default
# silencioso que enmascare el problema).
_tc_intake_seed_profiles() {
  tc_say "Perfil por canal (produccion / mergeador / piloto / runner)"
  local y ch _cur _def _p
  for y in $(seq 1 "${COUNT:-0}"); do
    ch="${PREFIX}${MACHINE_NUM}${y}"
    _cur="$(_tc_profile_from_map "$ch")"
    # Perfil corrupto en el mapa → inválido visible, nunca propagado como default silencioso.
    case "${_cur}" in
      ''|produccion|mergeador|piloto|runner) _def="${_cur:-produccion}";;
      *) tc_warn "perfil INVÁLIDO preexistente para $ch en el mapa: '${_cur}' — elige uno válido explícitamente"; _def="";;
    esac
    while :; do
      if [ -n "$_def" ]; then
        read -rp "  Perfil de $ch [$_def]: " _p; _p="${_p:-$_def}"
      else
        read -rp "  Perfil de $ch (produccion|mergeador|piloto|runner): " _p
      fi
      case "$_p" in produccion|mergeador|piloto|runner) break;; *) echo "    (usa produccion|mergeador|piloto|runner)";; esac
    done
    bash "$HERE/channel-profiles.sh" set "$ch" "$_p" >/dev/null
    unset _p _cur _def
  done
  tc_info "channel-profiles.list actualizado ($COUNT canales). Canales fuera de COUNT y perfiles no modificados quedan intactos."
}

# Guard lib-only: permite `source 00-intake.sh` en el arnés de test para exponer
# _tc_intake_seed_profiles sin disparar prompts, clonado de repo ni consumo de secretos.
if [ "${TC_INTAKE_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

tc_say "INTAKE — repo + máquina + credenciales"
tc_secret_dir

# --- 0) nº de máquina (x) -> nombres vibe-channel-<x><y> únicos en el tailnet ---
while :; do
  read -rp "  Número de ESTA máquina (0-9): " _m
  printf '%s' "$_m" | grep -qE '^[0-9]$' && { MACHINE_NUM="$_m"; break; }
  echo "  (un solo dígito 0-9)"
done

# --- 1) repo objetivo (repo-agnóstico) ---
_def="$REPO_URL"
read -rp "  Repo a usar (URL git)${_def:+ [$_def]}: " _r
REPO_URL="${_r:-$_def}"
[ -n "$REPO_URL" ] || tc_die "REPO_URL es requerido"
# Validación ESTRICTA: solo esquemas git conocidos y charset seguro (sin comillas, espacios,
# saltos de línea ni metacaracteres de shell). intake.conf lo cargan scripts root, así
# que un valor hostil aquí sería ejecución arbitraria — se rechaza en el origen.
# Transportes SIN cifrado/integridad (http://, git://) NO se aceptan: el flujo clona luego
# con credenciales y el token/código viajarían interceptables. file:// y ssh:// tampoco:
# la fase golden (02-golden.sh) solo clona vía https (tc_repo_https convierte git@host:path,
# pero no ssh://) — aceptarlos aquí dejaría una config "válida" que falla más tarde.
printf '%s' "$REPO_URL" | grep -qE '^(https://|git@)[A-Za-z0-9._~:/@%+-]+$' \
  || tc_die "REPO_URL con formato/charset no permitido: usa https://… o git@host:org/repo (sin espacios ni metacaracteres; http://, git://, ssh:// y file:// no se aceptan)."
# [CR] Sin userinfo embebido: https://token@host/... pasaría el regex y PERSISTIRÍA un secreto
# en intake.conf (contrato NO-secretos). Las credenciales de clon van por git-bootstrap-token.
case "$REPO_URL" in
  https://*)
    _authority="${REPO_URL#https://}"; _authority="${_authority%%/*}"
    case "$_authority" in
      *@*) tc_die "REPO_URL no debe incluir usuario/token embebido (https://…@…); usa la URL limpia — el clon usa el git-bootstrap-token." ;;
    esac
    unset _authority
    ;;
esac
REPO_DIR="$(tc_repo_dir_from_url "$REPO_URL")"
tc_info "REPO_DIR = $REPO_DIR"

# --- 2) nº de canales (sugerencia por RAM; cap real = suscripción Claude 2-3 activos) ---
_ram="$(free -g 2>/dev/null | awk '/Mem:/{print $2}')"; _ram="${_ram:-0}"
_sug=$(( _ram > 0 ? _ram / 8 : 4 )); [ "$_sug" -lt 2 ] && _sug=2; [ "$_sug" -gt 8 ] && _sug=8
echo "  RAM=${_ram}GB → sugerencia: crear $_sug canales (con 1 suscripción Claude, correr 2-3 activos)."
read -rp "  ¿Cuántos canales crear? (1-9) [$_sug]: " _c
COUNT="${_c:-$_sug}"
printf '%s' "$COUNT" | grep -qE '^[1-9]$' || tc_die "COUNT debe ser 1-9"

# --- persistir elecciones NO-secretas ---
# Serialización con printf %q: produce valores shell-safe que round-trip al hacer `source`,
# aunque contuvieran comillas/espacios/metacaracteres (defensa en profundidad junto a la
# validación estricta de REPO_URL de arriba). MACHINE_NUM/COUNT ya están validados a [0-9].
( umask 077; {
  printf 'MACHINE_NUM=%q\n' "$MACHINE_NUM"
  printf 'REPO_URL=%q\n'    "$REPO_URL"
  printf 'REPO_DIR=%q\n'    "$REPO_DIR"
  printf 'COUNT=%q\n'       "$COUNT"
} > "$SECRET_DIR/intake.conf" )
chmod 600 "$SECRET_DIR/intake.conf"
tc_info "intake.conf guardado (máquina $MACHINE_NUM, $COUNT canales: $(MACHINE_NUM=$MACHINE_NUM COUNT=$COUNT; for y in $(seq 1 "$COUNT"); do printf '%s ' "$PREFIX$MACHINE_NUM$y"; done))"

# --- 3) secretos globales (sin eco, 0600) ---
tc_say "Credenciales globales"
tc_prompt_secret cuser-pass        "Password del usuario '$CUSER' del contenedor" '.'        yes
tc_prompt_secret tailscale-authkey "Tailscale auth key (tskey-...)"                '^tskey-'  yes
# Acepta classic (ghp_/ghs_) y fine-grained (github_pat_) — ambos son PATs válidos para clonar.
tc_prompt_secret git-bootstrap-token "GitHub token EFÍMERO para clonar el repo en el golden" '^(gh[ps]_|github_pat_)' yes

# --- 4) credenciales por carril (manifest + .env.example del repo) ---
tc_say "Credenciales operacionales por carril (env)"
MANIFEST="$HERE/../assets/creds.manifest"
mkdir -p "$SECRET_DIR/env"; chmod 700 "$SECRET_DIR/env"

# Catálogo: arrays paralelos key/regex/required/scope/desc
_keys=(); _rx=(); _req=(); _scope=(); _desc=()
while IFS='|' read -r k rx rq sc ds; do
  case "${k// /}" in ''|\#*) continue;; esac
  _keys+=("${k// /}"); _rx+=("${rx// /}"); _req+=("${rq// /}"); _scope+=("${sc// /}"); _desc+=("$ds")
done < "$MANIFEST"

# Descubrir claves del .env.example del repo (clonado superficial temporal solo para leerlo).
# Repos privados: el clon de descubrimiento usa el git-bootstrap-token (ya pedido arriba) vía
# GIT_ASKPASS — el token NO va en argv ni queda en el remote; el askpass (0700 en tmpdir) lee
# del escrow 0600 al vuelo y el clon temporal se borra al salir.
_tmpr="$(mktemp -d)"; trap 'rm -rf "$_tmpr"' EXIT
_askpass="$_tmpr/askpass"
( umask 077; printf '#!/bin/sh\nexec cat %q\n' "$SECRET_DIR/git-bootstrap-token" > "$_askpass" )
chmod 700 "$_askpass"
_disc_url="$REPO_URL"
case "$REPO_URL" in
  https://*|git@*) _h="$(tc_repo_https "$REPO_URL")"; _disc_url="https://x-access-token@${_h#https://}";;
esac
if GIT_ASKPASS="$_askpass" GIT_TERMINAL_PROMPT=0 git clone --depth 1 --quiet "$_disc_url" "$_tmpr/r" 2>/dev/null; then
  for f in .env.example .env.sample .env.template; do
    [ -f "$_tmpr/r/$f" ] || continue
    while IFS= read -r line; do
      key="${line%%=*}"; key="${key## }"; key="${key%% }"
      printf '%s' "$key" | grep -qE '^[A-Z][A-Z0-9_]*$' || continue
      # añadir si no está ya en el catálogo
      _found=0; for ek in "${_keys[@]}"; do [ "$ek" = "$key" ] && _found=1 && break; done
      [ "$_found" = 1 ] && continue
      _keys+=("$key"); _rx+=("."); _req+=("no"); _scope+=("percarril"); _desc+=("$key (descubierta en $f)")
    done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$_tmpr/r/$f")
  done
  tc_info "claves del repo descubiertas en .env.example (si había)"
else
  tc_info "no pude clonar para leer .env.example (¿token sin acceso de lectura al repo?); uso solo el manifest"
fi

# Valores 'shared' se preguntan una vez.
declare -A _shared_val
for y in $(seq 1 "$COUNT"); do
  ch="$PREFIX$MACHINE_NUM$y"; envf="$SECRET_DIR/env/$ch.env"
  ( umask 077; : > "$envf" ); chmod 600 "$envf"
  echo "  -- $ch --"
  for i in "${!_keys[@]}"; do
    key="${_keys[$i]}"; rx="${_rx[$i]}"; req="${_req[$i]}"; sc="${_scope[$i]}"; ds="${_desc[$i]}"
    if [ "$sc" = "shared" ] && [ -n "${_shared_val[$key]+x}" ]; then
      ( umask 077; printf '%s=%s\n' "$key" "${_shared_val[$key]}" >> "$envf" ); continue
    fi
    set +x
    while :; do
      read -rsp "    $key — $ds: " _v; echo
      if [ -z "$_v" ]; then [ "$req" = yes ] && { echo "    (requerido)"; continue; }; break; fi
      if [ "$rx" != "." ] && ! printf '%s' "$_v" | grep -qE "$rx"; then echo "    (formato inválido)"; continue; fi
      # [CR] el .env es dotenv plano leido por varios parsers (bash literal, python-dotenv):
      # CR/LF partiria la linea (claves basura) y ' #' se truncaria en python-dotenv.
      case "$_v" in
        *$'\r'*|*$'\n'*) echo "    (el valor no puede contener saltos de línea)"; continue;;
        *' #'*) echo "    (el valor no puede contener ' #' — python-dotenv lo truncaría)"; continue;;
      esac
      break
    done
    if [ -n "$_v" ]; then
      ( umask 077; printf '%s=%s\n' "$key" "$_v" >> "$envf" )
      [ "$sc" = "shared" ] && _shared_val[$key]="$_v"
    fi
    unset _v
  done
done

# --- 5) [TAL-2630] perfil DECLARADO por canal (ground-truth de channel-profiles.list) ---
# El perfil (produccion/mergeador/runner) es DECLARACIÓN por nombre de canal, no inferencia; verify.sh
# valida contra él la credencial efectiva. Idempotente: preserva perfiles fuera de COUNT y el perfil
# actual de cada canal en COUNT (Enter lo conserva si es válido). Implementado en _tc_intake_seed_profiles.
_tc_intake_seed_profiles

tc_say "INTAKE COMPLETO"
tc_info "Secretos en \$SECRET_DIR ($SECRET_DIR): cuser-pass, tailscale-authkey, git-bootstrap-token, env/<canal>.env, channel-profiles.list"
tc_info "Siguiente: provision.sh continúa con preflight → disco → golden → clones…"
