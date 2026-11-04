#!/usr/bin/env bash
# pozos-selftest.sh — prueba de humo SIN RED de pozos-lib.sh y pozos-rotador.sh: parseo del mapa de consumidores (grupo A/B),
# lectura de uso (five_hour/seven_day + cubo Fable con scope.model dict Y string, y JSON roto), escritura 0600 del env de token,
# filtro de `habilitada_fabrica`, ALLOWLIST anti-inyección (host/ct/sesión/modelo/pozo), quoting `%q` de un CWD con comilla
# simple, filtro de filas de cuota inválidas y BLOQUEO de instancia única del rotador (flock ya tomado → rc=3).
# Usa fixtures inline en un directorio temporal; no toca $SECRET_DIR real, ni el ledger real, ni el estado real. rc=0 si todo pasa.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TCO_MODELOS_REGISTRO="$T/modelos.conf"
printf 'OPUS_MODEL="claude-opus-4-8"\nSONNET_MODEL="claude-sonnet-5"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' > "$TCO_MODELOS_REGISTRO"
export SECRET_DIR=$T/secret AM_LEDGER=$T/ledger.json; mkdir -p "$SECRET_DIR/tokens"
export POZOS_STATE_DIR=$T/state POZOS_LEGACY_TMP_PREFIX=$T/legacy-inexistente POZOS_LEGACY_CACHE=$T/legacy-cache-inexistente
. "$(dirname "$0")/pozos-lib.sh"
fail=0; ok(){ echo "ok   $1"; }; ko(){ echo "FALLO $1"; fail=$((fail+1)); }
# 1) mapa de consumidores: el grupo es el ÚLTIMO campo; defaults canal=A, resto=B
cat > "$T/map" <<'EOF'
# comentario
canal 01 A
canal 41 B
canal 09
torre torre-c1 B
torre torre-x
remoto m3 omega.tailnet.example vibe-channel-121 B
remoto m9 10.0.0.9 vibe-channel-999
EOF
got=$(map_entries "$T/map" | tr '\n' ';')
exp='canal 01 - - A;canal 41 - - B;canal 09 - - A;torre torre-c1 - - B;torre torre-x - - B;remoto m3 omega.tailnet.example vibe-channel-121 B;remoto m9 10.0.0.9 vibe-channel-999 B;'
[ "$got" = "$exp" ] && ok "map_entries (grupo B de canal 41 y defaults)" || { ko "map_entries: $got"; }
# 2) uso: scope.model como DICT
cat > "$T/u1.json" <<'EOF'
{"five_hour":{"utilization":64,"resets_at":"2026-09-01T23:59:00Z"},"seven_day":{"utilization":13,"resets_at":"2026-09-02T15:59:00Z"},
 "limits":[{"kind":"weekly_scoped","percent":20,"resets_at":"2026-09-02T15:59:00Z","scope":{"model":{"display_name":"Fable"}}}]}
EOF
row=$(POZOS_USAGE_JSON_FILE=$T/u1.json pozo_usage_row p4); set -- $row
[ "$1 $2 $4 $6" = "p4 64 13 20" ] && [ "$3" -gt 0 ] && [ "$7" -gt 0 ] && ok "usage_row scope.model dict → $row" || ko "usage_row dict: $row"
# 3) uso: scope.model como STRING (variante que reventaba con sc.get)
cat > "$T/u2.json" <<'EOF'
{"five_hour":{"utilization":5,"resets_at":"2026-09-01T23:59:00Z"},"seven_day":{"utilization":2,"resets_at":"2026-09-05T14:59:00Z"},
 "limits":[{"kind":"weekly_scoped","percent":7,"resets_at":"2026-09-05T14:59:00Z","scope":{"model":"Fable"}},
           {"kind":"weekly_scoped","percent":99,"scope":{"model":"Otro"}},{"kind":"otro","scope":"basura"}]}
EOF
row=$(POZOS_USAGE_JSON_FILE=$T/u2.json pozo_usage_row p6); set -- $row
[ "$1 $2 $4 $6" = "p6 5 2 7" ] && ok "usage_row scope.model string → $row" || ko "usage_row string: $row"
# 4) uso: sin cubo Fable y sin resets → -1 y nunca revienta; JSON roto → todo -1
cat > "$T/u3.json" <<'EOF'
{"five_hour":{"utilization":"33"},"seven_day":null,"limits":"no-es-lista"}
EOF
row=$(POZOS_USAGE_JSON_FILE=$T/u3.json pozo_usage_row p9); [ "$row" = "p9 33 -1 -1 -1 -1 -1" ] && ok "usage_row sin Fable/resets → $row" || ko "usage_row sin fable: $row"
printf 'esto no es json' > "$T/u4.json"; row=$(POZOS_USAGE_JSON_FILE=$T/u4.json pozo_usage_row p1); [ "$row" = "p1 -1 -1 -1 -1 -1 -1" ] && ok "usage_row JSON roto → $row" || ko "usage_row roto: $row"
# 5) token_env_write: fichero 0600 antes del contenido, contenido correcto, valor no en argv
printf 'sk-ant-oat-FAKE-selftest\n' | token_env_write "$T/tok.env"; perm=$(stat -c %a "$T/tok.env")
[ "$perm" = 600 ] && grep -qx 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-FAKE-selftest' "$T/tok.env" && ok "token_env_write 0600 + contenido" || ko "token_env_write perm=$perm"
# 5b) token_env_write (M5-BOUNCE ronda-2, TAL-5115): el VALOR viajaba con %s sin escapar — un
# token con espacio/metacarácter rompía (o ejecutaba algo) al hacer `source` del fichero. Con
# %q el fichero debe seguir siendo válido para `source` y devolver el valor EXACTO al re-leerlo.
printf '%s' "tok'con espacio\$(id)" | token_env_write "$T/tok2.env"
( . "$T/tok2.env"; [ "$CLAUDE_CODE_OAUTH_TOKEN" = "tok'con espacio\$(id)" ] ) \
  && ok "token_env_write %q sobrevive comilla/espacio/\$() al hacer source" \
  || ko "token_env_write %q: source dio «$(. "$T/tok2.env"; echo "$CLAUDE_CODE_OAUTH_TOKEN")»"
# 6) ledger: habilitada_fabrica false queda fuera; ausente cuenta como habilitado
cat > "$AM_LEDGER" <<'EOF'
{"pozos":{"p1":{"cuenta":"a@x","habilitada_fabrica":true},"p2":{"cuenta":"b@x","habilitada_fabrica":false},"p3":{"cuenta":"c@x"},"p10":{"cuenta":"d@x"}}}
EOF
[ "$(pozos_list)" = "p1 p2 p3 p10" ] && ok "pozos_list ordena p1..p10" || ko "pozos_list: $(pozos_list)"
[ "$(pozos_list_habilitados)" = "p1 p3 p10" ] && ok "pozos_list_habilitados excluye habilitada_fabrica=false" || ko "habilitados: $(pozos_list_habilitados)"
# 7) ALLOWLIST anti-inyección: solo pasan los formatos legítimos; todo metacarácter se rechaza
for v in vibe-channel-121 ct_1.a; do pozos_valid ct "$v" && ok "allowlist ct acepta «$v»" || ko "allowlist ct rechazó «$v»"; done
for v in "c1; false #" 'c1$(id)' 'c1|sh' "c1 c2" 'c1`id`' "c1'x"; do pozos_valid ct "$v" && ko "allowlist ct ACEPTÓ «$v»" || ok "allowlist ct rechaza «$v»"; done
for v in omega.tailnet.example host-01.tail.ts.net; do pozos_valid host "$v" && ok "allowlist host acepta «$v»" || ko "allowlist host rechazó «$v»"; done
for v in 'h$(id)' 'h;id' '-oProxyCommand=x' "h h"; do pozos_valid host "$v" && ko "allowlist host ACEPTÓ «$v»" || ok "allowlist host rechaza «$v»"; done
for v in "mi sesion" 'v;id' 'v$(id)'; do pozos_valid sesion "$v" && ko "allowlist sesion ACEPTÓ «$v»" || ok "allowlist sesion rechaza «$v»"; done
pozos_valid sesion torre-c1 && ok "allowlist sesion acepta «torre-c1»" || ko "allowlist sesion rechazó torre-c1"
for v in claude-opus-4-8 claude-sonnet-5; do pozos_valid modelo "$v" && ok "allowlist modelo acepta «$v»" || ko "allowlist modelo rechazó «$v»"; done
for v in "claude-opus; id" gpt-5 'claude-$(id)'; do pozos_valid modelo "$v" && ko "allowlist modelo ACEPTÓ «$v»" || ok "allowlist modelo rechaza «$v»"; done
pozos_valid pozo p10 && ok "allowlist pozo acepta «p10»" || ko "allowlist pozo rechazó p10"
pozos_valid uuid 00000000-0000-4000-8000-000000000013 && ok "allowlist uuid acepta un uuid de sesión" || ko "allowlist uuid rechazó un uuid válido"
for v in "" 'no-es-uuid' '00000000-0000-4000-8000-000000000013; id'; do pozos_valid uuid "$v" && ko "allowlist uuid ACEPTÓ «$v»" || ok "allowlist uuid rechaza «$v»"; done
for v in 'p1;id' pX '../p1'; do pozos_valid pozo "$v" && ko "allowlist pozo ACEPTÓ «$v»" || ok "allowlist pozo rechaza «$v»"; done
# pozos_require: rc=2, mensaje a stderr y NADA ejecutado (el centinela no se crea)
CANARIO=$T/canario; err=$(pozos_require ct "c1; touch $CANARIO #" "selftest" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$CANARIO" ] && case "$err" in *FORMATO-INVALIDO*) true;; *) false;; esac \
  && ok "pozos_require fail-closed (rc=2, sin ejecución)" || ko "pozos_require rc=$rc err=$err canario=$([ -e "$CANARIO" ] && echo SI || echo no)"
# 8) quoting %q: un CWD con comilla simple sobrevive el round-trip (era el vector de los instaladores)
CW="/home/o'brien/Academia Ejemplo \$(id)"; Q=$(printf %q "$CW"); eval "back=$Q"
[ "$back" = "$CW" ] && ok "printf %q round-trip de CWD con comilla simple" || ko "%q round-trip: «$back» ≠ «$CW»"
grep -q 'printf %q' "$(dirname "$0")/pozos-install-token.sh" && grep -q 'printf %q' "$(dirname "$0")/pozos-install-token-torre.sh" \
  && grep -q 'printf %q' "$(dirname "$0")/pozos-install-token-remote.sh" && ok "los 3 instaladores escapan con %q" || ko "algún instalador sin %q"
# 8b) M5-BOUNCE CRÍTICO-1 (TAL-5115): pozos-install-token.sh y pozos-install-token-remote.sh
# usaban rc=6 para DOS estados distintos (OCUPADO Y probe FALLIDO) — el rotador no podía
# distinguir «diferido, reintenta» de «falló de verdad». El probe fallido ahora sale con rc=7,
# propio (pozos-install-token-torre.sh ya usaba un rc distinto — 5 — y no tenía este defecto).
# Los dobles solo cuentan las etapas (escritura, relanzamiento, sonda); nunca ejecutan
# las órdenes recibidas. El texto de la sonda contradice su rc para probar qué decide.
mkdir -p "$T/install-bin"
cat > "$T/install-bin/incus" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$POZOS_TEST_CALLS"); n=$((n+1)); printf '%s\n' "$n" > "$POZOS_TEST_CALLS"
case "$n" in
  1) cat >/dev/null; exit 0 ;;
  2) exit "$POZOS_TEST_RELAUNCH_RC" ;;
  3) [ "$POZOS_TEST_PROBE_RC" = 0 ] && echo ERROR || echo OK; exit "$POZOS_TEST_PROBE_RC" ;;
  *) exit 99 ;;
esac
EOF
cp "$T/install-bin/incus" "$T/install-bin/ssh"
chmod +x "$T/install-bin/incus" "$T/install-bin/ssh"
printf 'token-sintetico\n' > "$T/install-token"
for f in pozos-install-token.sh pozos-install-token-remote.sh; do
  P="$(dirname "$0")/$f"
  for caso in correcta fallo ocupado-como-sonda transporte ocupado; do
    probe_rc=0; relaunch_rc=0; esperado=7; llamadas=3
    case "$caso" in
      correcta) esperado=0 ;;
      fallo) probe_rc=1 ;;
      ocupado-como-sonda) probe_rc=6 ;;
      transporte) probe_rc=255 ;;
      ocupado) relaunch_rc=6; esperado=6; llamadas=2 ;;
    esac
    printf '0\n' > "$T/install-calls"
    args=(01 "$T/install-token")
    [ "$f" != pozos-install-token-remote.sh ] || args=(example.invalid vibe-channel-01 torre-c1 "$T/install-token")
    out=$(PATH="$T/install-bin:$PATH" POZOS_REPO_DIR=producto POZOS_TEST_CALLS="$T/install-calls" \
      POZOS_TEST_PROBE_RC="$probe_rc" POZOS_TEST_RELAUNCH_RC="$relaunch_rc" \
      timeout 10 bash "$P" "${args[@]}" 2>&1); rc=$?
    [ "$rc" = "$esperado" ] && [ "$(cat "$T/install-calls")" = "$llamadas" ] \
      && ok "$f: $caso rc=$rc ($llamadas etapas)" \
      || ko "$f: $caso esperaba rc=$esperado y $llamadas etapas; rc=$rc etapas=$(cat "$T/install-calls") out=$out"
  done
done
# 8c) M5-BOUNCE CRÍTICO-3 (TAL-5115): tras un reintento parcial que SIGUE fallando, el rotador
# caía al bloque de cuota y podía disparar un `rotar` SIN filtro (re-aplicando el token a
# consumidores que ya lo tenían). El branch que loguea ROTACION-PARCIAL (reintento debe saltar
# el resto del ciclo con `continue` ANTES de llegar a esa decisión de cuota — MIENTRAS no se haya
# agotado el techo de reintentos (ver 8d).
if grep -A3 'ROTACION-PARCIAL (reintento ' "$(dirname "$0")/pozos-rotador.sh" | grep -q 'continue'; then
  ok "rotador: reintento parcial que sigue fallando (bajo el techo) hace continue"
else
  ko "rotador: reintento parcial que sigue fallando NO hace continue — riesgo de re-aplicar a ya-aplicados"
fi
# 8d) CERO×2 ronda 1 (MAJOR sobre el fix de 8c): sin techo, un consumidor PERMANENTEMENTE roto
# dejaría el `continue` de 8c cortando TODOS los ciclos futuros — la flota SANA quedaría pegada
# a una cuenta capada indefinidamente. Tras MAX_RETRY_CYCLES el rotador debe DARSE POR VENCIDO
# (limpiar $FAILED/$ST.pendiente, loguear fuerte) y NO hacer continue esa vuelta, para que el
# resto del ciclo (decisión de cuota de la flota sana) sí se ejecute.
GIVEUP=$(grep -A2 'PERMANENTEMENTE ROTO' "$(dirname "$0")/pozos-rotador.sh")
if echo "$GIVEUP" | grep -q 'continue'; then
  ko "rotador: el branch de 'consumidor permanentemente roto' hace continue — seguiría bloqueando a la flota sana"
elif echo "$GIVEUP" | grep -q '> "\$FAILED"'; then
  ok "rotador: tras agotar MAX_RETRY_CYCLES se limpia \$FAILED SIN continue (la flota sana no queda rehén)"
else
  ko "rotador: no se encontró la limpieza de \$FAILED junto al aviso de consumidor permanentemente roto"
fi
# 8e) CERO×2 ronda 2 (MAJOR sobre el giveup de 8d): limpiar $FAILED sin sellar $ST dejaba `st`
# apuntando a la primaria VIEJA — el bloque de cuota, en la MISMA vuelta, releía esa `st`
# desactualizada y podía disparar OTRO `rotar` sin filtro al mismo target, reabriendo el daño de
# CRÍTICO-3 en bucle cada ~MAX_RETRY_CYCLES×EVERY. El giveup debe sellar $ST a $pend ANTES de
# limpiar $FAILED, para que el resto del ciclo vea la transición como ya completada.
if echo "$GIVEUP" | grep -q 'echo "\$pend" > "\$ST"'; then
  ok "rotador: el giveup sella \$ST=\$pend antes de limpiar \$FAILED (no reabre CRÍTICO-3 por otra puerta)"
else
  ko "rotador: el giveup NO sella \$ST — el bloque de cuota puede re-disparar un rotar sin filtro al mismo target"
fi
# 9) filtro de filas de cuota: solo 5h y 7d legibles (≥0) con AMBOS resets válidos (>0)
pozo_row_valida "p1 64 1756000000 13 1756600000 -1 -1" && ok "row válida entra al orden" || ko "row válida excluida"
pozo_row_valida "p2 -1 1756000000 13 1756600000 -1 -1" && ko "row con 5h=-1 ENTRÓ al orden" || ok "row con 5h=-1 excluida"
pozo_row_valida "p3 64 1756000000 -1 1756600000 -1 -1" && ko "row con 7d=-1 ENTRÓ al orden" || ok "row con 7d=-1 excluida"
pozo_row_valida "p4 64 -1 13 1756600000 -1 -1"         && ko "row con reset5 inválido ENTRÓ" || ok "row con reset5 inválido excluida"
pozo_row_valida "p5 64 1756000000 13 -1 -1 -1"         && ko "row con reset7 inválido ENTRÓ" || ok "row con reset7 inválido excluida"
pozo_row_valida "p6 -1 -1 -1 -1 -1 -1"                 && ko "row toda -1 ENTRÓ" || ok "row toda -1 excluida"
# 10) estado privado 0700 + rechazo de symlink
SDIR=$(pozos_state_dir); [ "$(stat -c %a "$SDIR")" = 700 ] && ok "pozos_state_dir crea $SDIR con modo 700" || ko "state_dir modo=$(stat -c %a "$SDIR" 2>/dev/null)"
ln -s /etc/passwd "$SDIR/trampa"; state_file "$SDIR/trampa" 2>/dev/null && ko "state_file ACEPTÓ un symlink" || ok "state_file rechaza symlink"
state_file "$SDIR/nuevo" && [ "$(stat -c %a "$SDIR/nuevo")" = 600 ] && ok "state_file crea 0600 con O_EXCL" || ko "state_file no creó 0600"
# 11) instancia única del rotador: con el flock YA tomado, la segunda instancia sale con rc=3 y no toca el estado
LK=$SDIR/rotador.lock; : > "$LK"
( flock -x 8; sleep 8 ) 8>"$LK" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n -x "$LK" -c true 2>/dev/null || break; sleep 0.2; done
out=$(bash "$(dirname "$0")/pozos-rotador.sh" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc" = 3 ] && case "$out" in *YA-CORRIENDO*) true;; *) false;; esac \
  && ok "rotador: segunda instancia rc=3 (YA-CORRIENDO)" || ko "rotador segunda instancia rc=$rc out=$out"
# 12) la caché de uso y el estado NO viven en /tmp (finding CR ronda 3): ningún pozos-*.sh escribe rutas /tmp fijas
if grep -nE '>[[:space:]]*/tmp/|mv[[:space:]]+[^ ]*[[:space:]]+/tmp/' "$(dirname "$0")"/pozos-*.sh | grep -v pozos-selftest.sh; then
  ko "algún pozos-*.sh sigue escribiendo en /tmp"; else ok "ningún pozos-*.sh escribe estado/caché en /tmp"; fi
# 13) sintaxis de los scripts hermanos
for f in "$(dirname "$0")"/pozos-*.sh; do bash -n "$f" && ok "bash -n $(basename "$f")" || ko "bash -n $(basename "$f")"; done
echo "---- selftest: $fail fallos"; exit $((fail>0))
