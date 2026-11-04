#!/usr/bin/env bash
# Ronda 3: precisión en un solo sentido frente a los dos guards de identidad reales.
# shellcheck shell=bash
# shellcheck disable=SC2034 # contadores y fixtures compartidos con test-supervision.sh

guard_identidades() {
  env -i PATH=/usr/bin:/bin HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" \
    bash "$FXSK/talent-channel-operation/scripts/00-config.sh" > "$T/guard-canal.log" 2>&1
  GC=$?
  # Guard real, intacto hasta su primera lectura de tokens. Ancla única obligatoria.
  python3 - "$FXSK/talent-orchestrator/scripts/00-config.sh" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
anchor = '  v="$(grep -E'
assert s.count(anchor) == 1
p.with_name('guard-sin-tokens.sh').write_text(s[:s.index(anchor)] + '  return 0\n}\ntorc_load_tokens\n')
PY
  local preparo=$?
  if [ "$preparo" -ne 0 ]; then GO=2; return; fi
  env -i PATH=/usr/bin:/bin HOME="$T/home" HOST_HOME="$T/home" TORC_SECRET_DIR="$T/secret-orq" \
    bash "$FXSK/talent-orchestrator/scripts/guard-sin-tokens.sh" > "$T/guard-orq.log" 2>&1
  GO=$?
}
contraste() { # id doctor esperado motivo de exigencia adicional
  local id="$1" esperado="$2" motivo="$3" acredita=1
  dr TCO_HOST_ENV=
  if printf '%s\n' "$OUT" | grep -Eq '^(FALLA|NOVERIF) identidad '; then acredita=0; fi
  guard_identidades
  printf 'PARIDAD|%s|doctor=%s|canal=%s|orquestador=%s|%s\n' "$id" "$acredita" "$GC" "$GO" "$motivo"
  assert_eq "R3-01 $id doctor rc" "$esperado" "$RC"
  assert_eq "R3-01 $id doctor acredita implica guard canal acepta" si "$(if { [ "$GC" = 0 ] || [ "$GC" = 1 ]; } && { [ "$acredita" = 0 ] || [ "$GC" = 0 ]; }; then echo si; else echo no; fi)"
  assert_eq "R3-01 $id doctor acredita implica guard orquestador acepta" si "$(if { [ "$GO" = 0 ] || [ "$GO" = 1 ]; } && { [ "$acredita" = 0 ] || [ "$GO" = 0 ]; }; then echo si; else echo no; fi)"
}
fila_identidad() { # skill clave valor; vacío = eliminar
  conf="$FXSK/$1/scripts/repo-identity.conf"
  sed -i "/^$2=/d" "$conf"
  [ -z "$3" ] || printf '%s=%s\n' "$2" "$3" >> "$conf"
}
fx_nuevo; contraste valida 0 ninguna
for skill in talent-channel-operation talent-orchestrator; do
  # Incluye las opcionales de la plantilla, con valores adjudicados neutros.
  fx_nuevo
  if [ "$skill" = talent-channel-operation ]; then
    printf 'TCO_SUPABASE_REF=no-aplica\nTCO_POSTMERGE_CMD=literal\n' >> "$FXSK/$skill/scripts/repo-identity.conf"
  fi
  cp "$FXSK/$skill/scripts/repo-identity.conf" "$T/tabla-identidad.conf"
  while IFS='=' read -r clave valor; do
    for modo in doble simple pendiente pendiente-doble pendiente-simple ausente; do
      fx_nuevo
      case "$modo" in
        doble) dato="\"$valor\"" ;;
        simple) dato="'$valor'" ;;
        pendiente) dato="PENDIENTE-$clave" ;;
        pendiente-doble) dato="\"PENDIENTE-$clave\"" ;;
        pendiente-simple) dato="'PENDIENTE-$clave'" ;;
        ausente) dato='' ;;
      esac
      fila_identidad "$skill" "$clave" "$dato"
      esperado=1
      if [ "$clave" = TCO_POSTMERGE_CMD ] && { [ "$modo" = doble ] || [ "$modo" = simple ]; }; then esperado=0; fi
      if [ "$modo" = ausente ]; then
        case "$clave" in TCO_SUPABASE_REF|TCO_POSTMERGE_CMD) esperado=0 ;; esac
      fi
      contraste "$skill:$clave:$modo" "$esperado" formato-procedencia-y-valores-adjudicados
    done
  done < "$T/tabla-identidad.conf"
done
fx_nuevo; fila_identidad talent-channel-operation TCO_REPO_STACK desconocido
contraste stack-fuera-enum 1 enum
for clave in TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE; do
  fx_nuevo; fila_identidad talent-channel-operation "$clave" no-es-uuid
  contraste "$clave:uuid-mal-formado" 1 UUID-canonico
done
for skill in talent-channel-operation talent-orchestrator; do
  if [ "$skill" = talent-channel-operation ]; then clave=TCO_HOST_ENV_REL; else clave=TORC_HOST_ENV_REL; fi
  for modo in relativa doble simple absoluta traversal; do
    fx_nuevo
    case "$modo" in
      relativa) dato=ejemplo/.env.local; esperado=0 ;;
      doble) dato='"ejemplo/.env.local"'; esperado=1 ;;
      simple) dato="'ejemplo/.env.local'"; esperado=1 ;;
      absoluta) dato="$T/home/ejemplo/.env.local"; esperado=1 ;;
      traversal) dato=ejemplo/../ejemplo/.env.local; esperado=1 ;;
    esac
    fila_identidad "$skill" "$clave" "$dato"
    contraste "$clave:ruta:$modo" "$esperado" ruta-relativa-confinada
  done
  fx_nuevo; printf 'CLAVE_DESCONOCIDA=literal\n' >> "$FXSK/$skill/scripts/repo-identity.conf"
  contraste "$skill:desconocida" 1 claves-admitidas
  fx_nuevo; printf '\n# comentario neutro\n' >> "$FXSK/$skill/scripts/repo-identity.conf"
  contraste "$skill:blanco-comentario" 0 ninguna
done
fx_nuevo; printf '%s\n' 'DATO="interior\"escapada"' > "$T/secret/agents.conf"; dr
assert_eq 'R3-03 comilla interior escapada conserva rechazo literal' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^FALLA identidad canal-operation: agents.conf no es dato literal comprobable')"

for modo in frontera dentro cierre prompt transcripcion; do
  fx_nuevo
  case "$modo" in
    frontera) texto=$'```\nhistórico uno\nhistórico dos\nhistórico tres\n```\nInforme de progreso:\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado='1|1' ;;
    dentro) texto=$'```\n ❯ 1. Yes\n   2. No\n Esc to cancel\n```\nctx: 42%'; esperado='0|0' ;;
    cierre) texto=$'```\nhistórico\n```\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado='1|1' ;;
    prompt) texto=$'```\nhistórico uno\nhistórico dos\nhistórico tres\n>\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado='1|1' ;;
    transcripcion) texto=$'Informe de ejemplo, no selector activo:\n ❯ 1. Yes\n   2. No\n Esc to cancel\nctx: 42%'; esperado='0|0' ;;
  esac
  printf '%s\n' "$texto" > "$FX/tmux/daemon/ses-torre.cap"; dr
  assert_eq "R3-02 doctor cita $modo" "$esperado" "$RC|$(printf '%s\n' "$OUT" | grep -c '^FALLA bloqueo-sin-escalar torre-uno:')"
done
