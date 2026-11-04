#!/usr/bin/env bash
# Regresiones del acta: usa exclusivamente el fixture desechable de test-supervision.sh.
printf '== Ronda 1: H01-H10 ==\n'
fx_nuevo
# shellcheck disable=SC2016 # instrucción literal hostil que el doctor debe rechazar
printf 'printf escritura > "$XDG_RUNTIME_DIR/talent-ceo/efecto-config"\n' > "$T/secret/agents.conf"
h0="$(hash_estado)"; dr
assert_eq 'H01 config como datos: puerta cerrada sin escritura' "1|$h0" "$RC|$(hash_estado)"
rm -f "$T/secret/agents.conf"
fx_nuevo; printf 'DATO=ok; touch /tmp/efecto-config\n' > "$T/secret/agents.conf"
h0="$(hash_estado)"; dr
assert_eq 'H01 asignación seguida de instrucción no es dato' "1|$h0" "$RC|$(hash_estado)"
rm -f "$T/secret/agents.conf"
for caso in ilegible corrupto symlink directorio; do
  fx_nuevo; ad="$RUN/homes/daemon/.cache/talent-ceo/acreditacion"; mkdir -p "$ad"
  printf 'NO_ACREDITADO\n' > "$ad/torre-uno.estado"
  case "$caso" in
    ilegible) chmod 000 "$ad/torre-uno.estado" ;;
    corrupto) printf 'CORRUPTO\n' > "$ad/torre-uno.estado" ;;
    symlink) mv "$ad/torre-uno.estado" "$T/estado-externo"; ln -s "$T/estado-externo" "$ad/torre-uno.estado" ;;
    directorio) rm "$ad/torre-uno.estado"; mkdir "$ad/torre-uno.estado" ;;
  esac
  dr
  expected=NOVERIF; [ "$caso" = corrupto ] && expected=FALLA
  assert_eq "H02 estado $caso" "1|1" "$RC|$(printf '%s\n' "$OUT" | grep -c "^$expected acreditacion torre-uno:")"
done
fx_nuevo
mkdir -p "$T/noncebin"
cat > "$T/noncebin/head" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = -c4 ] && [ "${2-}" = /dev/urandom ]; then printf '\000\000\000\000'; exit 0; fi
exec /usr/bin/head "$@"
SH
chmod +x "$T/noncebin/head"
rea_fijo() { env -i PATH="$T/noncebin:/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$RUN" TA_PERFIL="$FXP" TA_BUS="$FXBUS" bash "$REAC" "$@" 2>"$T/rea.err"; }
rea_fijo --rol CEO --iniciar >/dev/null
sellar_como ACRED-CEO-00000000
rea_fijo --rol CEO --verificar >/dev/null; assert_eq 'H03 nonce fijo control positivo' 0 $?
rea_fijo --rol CEO --iniciar >/dev/null
rea_fijo --rol CEO --verificar >/dev/null; assert_eq 'H03 mismo nonce anterior al segundo inicio' 1 $?
rm -f "$CDIR/acred-CEO.cursor"
rea_fijo --rol CEO --verificar >/dev/null; assert_eq 'H03 cursor perdido nunca primera lectura' 1 $?
fx_nuevo; : > "$FXBUS"; fx_cursores; rea_fijo --rol CEO --iniciar >/dev/null
assert_eq 'H03 bus vacío persiste posición e identidad' "0|$(stat -c '%d:%i' "$FXBUS")" "$(cat "$RUN/talent-ceo/acreditacion/CEO.inicio" 2>/dev/null)"
printf '%s [rol: torre-uno] [marcador: ACRED-CEO-00000000]\n' "$(iso "$NOW0")" >> "$FXBUS"
rea_fijo --rol CEO --verificar >/dev/null; assert_eq 'H03 nonce correcto de otro rol' 1 $?
for cab in 'NO-ES-FECHA' '2026-02-30T12:00:00Z' '2026-10-03' '2026-10-03T12:00:00Z extra'; do
  fx_nuevo; rea_fijo --rol CEO --iniciar >/dev/null
  printf '%s [rol: CEO] [marcador: ACRED-CEO-00000000]\n' "$cab" >> "$FXBUS"
  rea_fijo --rol CEO --verificar >/dev/null; assert_eq "H04 cabecera inválida $cab" 1 $?
done
fx_nuevo; printf 'Necesito una decision del CEO. ¿Autorizas continuar?\nctx: 42%%\n' > "$FX/tmux/daemon/ses-torre.cap"; dr
assert_eq 'H05 pregunta sin escalado: aviso informativo rc 0' '0|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^AVISO posible-pregunta-sin-escalar torre-uno:')"
for texto in 'Texto con ? en medio y final informativo' $'Preguntas frecuentes?\n 1. paso uno\n 2. paso dos' $'Informe de ejemplo, no selector activo:\n ❯ 1. Yes\n   2. No\n Esc to cancel'; do
  fx_nuevo; printf '%s\nctx: 42%%\n' "$texto" > "$FX/tmux/daemon/ses-torre.cap"; dr
  assert_eq 'H05/H06 texto informativo y transcripción' '0|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^AVISO')"
done
fx_nuevo; conf_canal PENDIENTE-PKG_IDENTITY_PROJECT; conf_orq PENDIENTE-PKG_IDENTITY_PROJECT; dr
assert_eq 'H07 identidades iguales sin adjudicar' '1|identidad' "$RC|$(cats)"
fx_nuevo; cp "$FXBIN/tmux" "$T/tmux-original"
for sub in display-message list-panes capture-pane; do
  cp "$T/tmux-original" "$FXBIN/tmux"
  sed -i "/  $sub)/s/ ;;$/; exit 1 ;;/" "$FXBIN/tmux"
  dr; assert_eq "H08 tmux $sub rc 1 con salida" '1|si' "$RC|$([ "$(nnov)" -gt 0 ] && echo si || echo no)"
done
cp "$T/tmux-original" "$FXBIN/tmux"
fx_nuevo; cp "$FXBIN/incus" "$T/incus-original"
sed -i '/ps -e.*cat/s/ ;;$/; exit 1 ;;/' "$FXBIN/incus"
dr; assert_eq 'H08 auditor ps rc 1 con salida' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF auditor')"
cp "$T/incus-original" "$FXBIN/incus"
fx_nuevo; cp "$FXBIN/crontab" "$T/crontab-original"
printf '\nexit 1\n' >> "$FXBIN/crontab"
dr; assert_eq 'H08 crontab rc 1 con salida válida' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF cron')"
cp "$T/crontab-original" "$FXBIN/crontab"
fx_nuevo; sed -i '/list) cat/s/ ;;$/; exit 1 ;;/' "$FXBIN/incus"
dr; assert_eq 'H08 incus list rc 1 con salida válida' '1|2' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF canal')"
cp "$T/incus-original" "$FXBIN/incus"
fx_nuevo; conf_canal origen-neutro; conf_orq origen-neutro; dr
assert_eq 'H07 dos restos coincidentes de otro proyecto válido' '1|identidad' "$RC|$(cats)"
fx_nuevo; sed -i '/^TCO_HOST_ENV_REL=/d' "$FXSK/talent-channel-operation/scripts/repo-identity.conf"; dr
assert_eq 'H07 identidad real admite tokens absolutos sin ruta relativa' 0 "$RC"
fx_nuevo; sed -i '/^TORC_HOST_ENV_REL=/d' "$FXSK/talent-orchestrator/scripts/repo-identity.conf"; dr
assert_eq 'H07 igualdad de proyecto sin campos obligatorios del orquestador' '1|identidad' "$RC|$(cats)"
fx_nuevo; printf '¿Autorizas continuar?\nctx: 42%%\n' > "$FX/tmux/daemon/ses-torre.cap"; sello torre-uno ESCALA-torre-uno-r2 3; dr
assert_eq 'H05 escalado reciente evita aviso' '0|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^AVISO')"
fx_nuevo; printf '¿Autorizas continuar?\nesc to interrupt\nctx: 42%%\n' > "$FX/tmux/daemon/ses-torre.cap"; dr
assert_eq 'H05 pane ocupado evita aviso' '0|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^AVISO')"
assert_eq 'H09 doctrina lector restringido y aviso explícito' 'si' "$(grep -q 'leer-acreditacion.sh' "$ROOT/references/07-doctor-y-acreditacion.md" && grep -q 'AVISO posible-pregunta-sin-escalar' "$ROOT/references/07-doctor-y-acreditacion.md" && echo si || echo no)"
fx_nuevo; h0="$(hash_estado)"; printf '%s' 999 > "$CDIR/CEO.cursor"; touch -r "$CDIR/torre-uno.cursor" "$CDIR/CEO.cursor"
assert_eq 'H10 instantánea detecta contenido modificado' si "$([ "$h0" != "$(hash_estado)" ] && echo si || echo no)"
fx_nuevo; mkdir -p "$RUN/homes/daemon/.cache/talent-ceo/acreditacion"
printf 'ACREDITADO\000\n' > "$RUN/homes/daemon/.cache/talent-ceo/acreditacion/torre-uno.estado"; dr
assert_eq 'H02 estado con NUL no es contenido acreditado' '1|acreditacion' "$RC|$(cats)"
fx_nuevo; mkdir -p "$RUN/otro-runtime/talent-ceo/acreditacion"
printf 'NO_ACREDITADO\n' > "$RUN/otro-runtime/talent-ceo/acreditacion/torre-uno.estado"
sed -i "s|usuario=daemon|usuario=daemon;estado_runtime=$RUN/otro-runtime|" "$FXP"
dr; assert_eq 'H02 XDG propio adjudicado a otro usuario' '1|acreditacion' "$RC|$(cats)"
fx_nuevo; ad="$RUN/homes/daemon/.cache/talent-ceo/acreditacion"; mkdir -p "$ad"
printf 'ACREDITADO\n' > "$ad/torre-uno.estado"; chmod 000 "$ad/torre-uno.estado"
h0="$(hash_estado)"; chmod 600 "$ad/torre-uno.estado"; printf 'INVALIDADO\n' > "$ad/torre-uno.estado"; chmod 000 "$ad/torre-uno.estado"
h1="$(hash_estado)"
assert_eq 'H10 SHA256 incluye contenido del fixture 000 y restaura permisos' 'si|0' "$([ "$h0" != "$h1" ] && echo si || echo no)|$(stat -c '%a' "$ad/torre-uno.estado")"
fx_nuevo
cat > "$FXBIN/python3" <<'SH'
#!/usr/bin/env bash
case "${2-}" in
  */homes/daemon/.cache/talent-ceo)
    # El lector usa fstat sobre descriptores: inyectar el fallo en esa operación.
    exec /usr/bin/python3 -c '
import os
import sys
source = sys.stdin.read()
sys.argv = sys.argv[1:]
def fallo(fd):
    raise PermissionError("metadatos no comprobables")
os.fstat = fallo
exec(compile(source, "lector-fixture", "exec"))
' "$@" ;;
  *) exec /usr/bin/python3 "$@" ;;
esac
SH
chmod +x "$FXBIN/python3"
dr; assert_eq 'H02 stat fallido no se confunde con estado ausente' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF acreditacion torre-uno:')"
rm -f "$FXBIN/python3"
