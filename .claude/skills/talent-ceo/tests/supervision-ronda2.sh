#!/usr/bin/env bash
# Reproducciones de variantes.sh y region-prompt.sh del acta, en el fixture aislado.
printf '== Ronda 2: gramática, identidad, fechas y región ==\n'
# shellcheck disable=SC2016 # sustituciones e instrucciones como datos hostiles del fixture
for dato in 'DATO="ok"; touch /tmp/efecto-prueba; DATO="ok"' 'A=1 B=2' 'DATO="ok"resto' 'DATO=ok"otro"' 'DATO=ok|cat' 'DATO=$(touch /tmp/efecto-prueba)' 'DATO=`touch /tmp/efecto-prueba`' 'DATO=ok(foo)' 'TCO_POSTMERGE_CMD=ok; touch /tmp/efecto-prueba' 'DATO=~' 'DATO=literal:~'; do
  fx_nuevo; printf '%s\n' "$dato" > "$T/secret/agents.conf"; dr
  assert_eq "R2-01 rechaza $dato" 1 "$RC"
done
for dato in 'DATO=literal' 'DATO="ok; | > < &"' "DATO='ok; | > < &'" 'DATO=""'; do
  fx_nuevo; printf '%s\n' "$dato" > "$T/secret/agents.conf"; dr
  assert_eq "R2-01 literal válido $dato" 0 "$RC"
done
for skill in talent-channel-operation talent-orchestrator; do
  while IFS='=' read -r clave valor; do
    case "$valor" in PENDIENTE-*) : ;; *) continue ;; esac
    fx_nuevo
    conf="$FXSK/$skill/scripts/repo-identity.conf"
    sed -i "/^$clave=/d" "$conf"
    printf '%s=%s\n' "$clave" "$valor" >> "$conf"; dr
    assert_eq "R2-02 marcador $skill $clave" 1 "$RC"
  done < "$SK/$skill/scripts/repo-identity.conf.example"
done
for fecha in '2099-01-01T12:00:00Z' '2099-01-01' '2026-02-30T12:00:00Z' '2099-01-01T12:00:00Z extra'; do
  for menu in no si; do
    fx_nuevo
    sed -i '/\[rol: torre-uno\]/d' "$FXBUS"
    printf '%s [rol: torre-uno] [marcador: HITO-FUTURO]\n' "$fecha" >> "$FXBUS"
    fx_cursores
    [ "$menu" = no ] || printf '%s\n' "$CAP_MENU" > "$FX/tmux/daemon/ses-torre.cap"
    dr
    assert_eq "R2-03 fecha $fecha menu=$menu" '1|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK menu-reciente torre-uno:')"
  done
done
for texto in $'Informe de progreso:\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%' $'Informe de ejemplo:\n texto histórico\n>\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; do
  fx_nuevo; printf '%s\n' "$texto" > "$FX/tmux/daemon/ses-torre.cap"; dr
  assert_eq 'R2-04 selector activo después de informe o prompt' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^FALLA bloqueo-sin-escalar torre-uno:')"
done
fx_nuevo; dr; assert_eq 'R2 control normal y lectura inmutable' "0|0" "$RC|$READONLY_FAIL"
fx_nuevo; dr 'TCO_AUDIT_CLI=ABC=literal /usr/bin/codex-root'
assert_eq 'R2 rebase auditor usa el resolutor real de lanzadores' 0 "$RC"
fx_nuevo
assert_eq 'R2 rebase doctor comparte la acreditación de ruta real' si "$(grep -q '_tco_pane_agent_exes' "$ROOT/scripts/leer-auditor.sh" && echo si || echo no)"
fx_nuevo; dr TCO_POSTMERGE_CMD=PENDIENTE-TCO_POSTMERGE_CMD
assert_eq 'R2-02 marcador opcional efectivo por entorno' 1 "$RC"
fx_nuevo; printf 'TCO_POSTMERGE_CMD=PENDIENTE-TCO_POSTMERGE_CMD\n' > "$T/secret/agents.conf"; dr
assert_eq 'R2-02 marcador opcional efectivo por runtime' 1 "$RC"
fx_nuevo; printf 'CLAVE_DESCONOCIDA=literal\n' >> "$FXSK/talent-channel-operation/scripts/repo-identity.conf"; dr
assert_eq 'R2-02 clave ajena al lector real' 1 "$RC"
fx_nuevo; dr TORC_HOST_ENV=relativa/.env.local
assert_eq 'R2-02 override del orquestador debe ser absoluto' 1 "$RC"
fx_nuevo; rm "$T/home/ejemplo/.env.local"; ln -s "$TOK" "$T/home/ejemplo/.env.local"; dr
assert_eq 'R2-02 ruta relativa no puede escapar del HOME' 1 "$RC"
