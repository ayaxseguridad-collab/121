#!/usr/bin/env bash
# 03-clone.sh — Clona golden -> vibe-channel-<maquina><y> (1..COUNT), identidad única,
# puerto Tailscale distinto, y los une al tailnet (userspace + SSH) con TS_AUTHKEY.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

# [TAL-2296] Aislamiento local-only INCONDICIONAL + fail-closed, aplicado POR IGUAL a canales
# preexistentes Y a clones NUEVOS (un clon recién copiado hereda del golden el servicio tailscaled y
# puede quedar habilitado). NO se condiciona a que 'tailscale ip -4' responda: el daemon puede estar
# PARADO con el estado PERSISTIDO en disco y reconectaría al reiniciar. Baja SIEMPRE (down + disable +
# borrar estado) y VERIFICA fail-closed: estado ausente + servicio no habilitado + sin IP.
# Definido a nivel de script (sourceable con TC_NO_MAIN=1 para pruebas conductuales).
_tc_local_isolate() { # <container>
  local ch="$1"
  tc_info "$ch: aislando del tailnet (local-only, incondicional)"
  incus exec "$ch" -- tailscale down >/dev/null 2>&1 || true
  incus exec "$ch" -- systemctl disable --now tailscaled >/dev/null 2>&1 || true
  incus exec "$ch" -- rm -f /var/lib/tailscale/tailscaled.state >/dev/null 2>&1 || true
  incus exec "$ch" -- test ! -e /var/lib/tailscale/tailscaled.state \
    || tc_die "$ch: tailscaled.state PERSISTE tras la limpieza local-only — aíslalo manualmente antes de continuar."
  ! incus exec "$ch" -- systemctl is-enabled tailscaled >/dev/null 2>&1 \
    || tc_die "$ch: tailscaled sigue HABILITADO tras la limpieza local-only (reconectaría al reiniciar)."
  ! incus exec "$ch" -- tailscale ip -4 >/dev/null 2>&1 \
    || tc_die "$ch: sigue con IP de tailnet tras la limpieza local-only."
}

# Cuerpo principal en función: sourceable en tests (TC_NO_MAIN=1) sin ejecutar el aprovisionamiento.
tc_clone_power() { # nombre estado-deseado; no ocultar errores de arranque/parada
  local name="$1" wanted="$2" observed
  observed="$(incus list "^${name}$" -f csv -c s)" || tc_die "$name: estado no verificable"
  case "$observed" in RUNNING|STOPPED) ;; *) tc_die "$name: estado ausente o no soportado"; return 1;; esac
  [ "$observed" != "$wanted" ] || return 0
  case "$wanted" in
    RUNNING) incus start "$name" || tc_die "$name: arranque fallido";;
    STOPPED) incus stop "$name" || tc_die "$name: parada fallida";;
    *) tc_die "$name: estado solicitado inválido";;
  esac
}

tc_clone_main() {
[ "$(id -u)" -eq 0 ] || tc_die "03-clone requiere root (sudo)."
[ -n "$MACHINE_NUM" ] && [ -n "$COUNT" ] || tc_die "MACHINE_NUM/COUNT no definidos (00-intake.sh)."
# Identidad git POR CANAL — gate temprano fail-closed: sin las plantillas del manifiesto
# de la fábrica no se clona NADA (ni herencia del host ni canales sin identidad). AMBAS
# plantillas deben contener el placeholder {channel}: una plantilla ESTÁTICA re-crearía la
# clase del bug (todos los canales firmando idéntico) — se rechaza antes de expandir.
[ -n "${TF_CHANNEL_GIT_NAME_TMPL:-}" ] && [ -n "${TF_CHANNEL_GIT_EMAIL_TMPL:-}" ] \
  || tc_die "TF_CHANNEL_GIT_NAME_TMPL/TF_CHANNEL_GIT_EMAIL_TMPL sin definir — la identidad git del canal es POR CANAL desde el manifiesto de la fábrica (placeholder {channel}); defínelas antes de clonar (fail-closed)."
case "$TF_CHANNEL_GIT_NAME_TMPL" in *"{channel}"*) : ;; *) tc_die "TF_CHANNEL_GIT_NAME_TMPL sin el placeholder {channel} (plantilla estática = todos los canales firmarían igual) — fail-closed";; esac
case "$TF_CHANNEL_GIT_EMAIL_TMPL" in *"{channel}"*) : ;; *) tc_die "TF_CHANNEL_GIT_EMAIL_TMPL sin el placeholder {channel} (plantilla estática = todos los canales firmarían igual) — fail-closed";; esac
# [TAL-2296] --local-only: canales SIN Tailscale (acceso solo local vía incus exec / launchers con
# fallback local, gotcha 13). En ese modo NO se pide authkey ni se hace 'tailscale up'.
LOCAL_ONLY="${TC_LOCAL_ONLY:-no}"
AUTHKEY=""
if [ "$LOCAL_ONLY" != yes ]; then
  tc_have_secret tailscale-authkey || tc_die "Falta tailscale-authkey (00-intake.sh). (o usa --local-only para canales sin Tailscale)"
  set +x   # [CR] antes de leer el secreto: con bash -x la asignación lo imprimiría
  AUTHKEY="$(tc_read_secret tailscale-authkey)"
  case "$AUTHKEY" in tskey-*) ;; *) tc_die "tailscale-authkey no empieza por tskey-";; esac
else
  tc_info "TC_LOCAL_ONLY=yes — canales SIN Tailscale (acceso local vía incus exec / launchers con fallback local)."
fi

tc_say "FASE 3 — CLONAR ($COUNT canales, máquina $MACHINE_NUM${LOCAL_ONLY:+, local-only=$LOCAL_ONLY})"
tc_clone_power "$GOLDEN" STOPPED

for y in $(seq 1 "$COUNT"); do
  ch="$(tc_channel_name "$y")"; port="$(tc_channel_port "$y")"
  echo; echo "########## $ch (puerto $port) ##########"
  if incus info "$ch" >/dev/null 2>&1; then
    # Existir NO basta para saltar: una corrida previa pudo fallar tras 'incus copy' y antes
    # de completar 'tailscale up' (canal a medias). Solo se salta si está REALMENTE provisionado
    # (arranca y tiene IP en el tailnet); si no, se aborta con instrucción de reintento.
    tc_clone_power "$ch" RUNNING
    tc_wait_container "$ch" || tc_die "$ch existe pero no arranca — revisa su estado o bórralo ('incus delete -f $ch') y relanza esta fase."
    if [ "$LOCAL_ONLY" = yes ]; then
      _tc_local_isolate "$ch"
      tc_info "ya provisionado (local-only, aislado: estado ausente + servicio deshabilitado + sin IP) -> SKIP"; continue
    fi
    if incus exec "$ch" -- tailscale ip -4 >/dev/null 2>&1; then
      tc_info "ya provisionado (en tailnet) -> SKIP"; continue
    fi
    tc_die "$ch existe pero NO completó el join al tailnet (quedó a medias). Bórralo ('incus delete -f $ch') y relanza esta fase."
  fi
  incus copy "$GOLDEN" "$ch"
  tc_clone_power "$ch" RUNNING
  tc_wait_container "$ch" || tc_die "$ch no arrancó."
  # identidad única
  incus exec "$ch" -- bash -c "echo '$ch' > /etc/hostname; hostname '$ch'
sed -i 's/^127.0.1.1.*/127.0.1.1 $ch/' /etc/hosts 2>/dev/null || true
grep -q 127.0.1.1 /etc/hosts || echo '127.0.1.1 $ch' >> /etc/hosts
rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup >/dev/null 2>&1 || true; dbus-uuidgen --ensure >/dev/null 2>&1 || true
rm -f /etc/ssh/ssh_host_*; ssh-keygen -A >/dev/null
rm -f /var/lib/tailscale/tailscaled.state"
  incus restart "$ch"; tc_wait_container "$ch" || tc_die "$ch no reinició."
  # Identidad git POR CANAL: expansión del ÚNICO placeholder {channel} sobre las plantillas del
  # manifiesto de la fábrica. El golden viaja SIN identidad (02-golden ya no hereda del host);
  # placeholder sin resolver o escritura no verificada ⇒ abort. Verificación de vuelta como $CUSER.
  gname="${TF_CHANNEL_GIT_NAME_TMPL//\{channel\}/$ch}"
  gmail="${TF_CHANNEL_GIT_EMAIL_TMPL//\{channel\}/$ch}"
  case "$gname$gmail" in *"{"*"}"*) tc_die "$ch: placeholder sin resolver en la identidad git (name='$gname' email='$gmail') — único placeholder soportado: {channel}";; esac
  incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.name "$1"; git config --global user.email "$2"' _ "$gname" "$gmail" \
    || tc_die "$ch: no pude escribir la identidad git del canal"
  eff_name="$(incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.name' 2>/dev/null || true)"
  eff_mail="$(incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.email' 2>/dev/null || true)"
  { [ "$eff_name" = "$gname" ] && [ "$eff_mail" = "$gmail" ]; } \
    || tc_die "$ch: identidad git efectiva ('$eff_name' <$eff_mail>) != esperada ('$gname' <$gmail>) — fail-closed"
  tc_info "$ch: identidad git del canal fijada ($gname <$gmail>)"
  if [ "$LOCAL_ONLY" = yes ]; then
    # Un clon RECIÉN copiado hereda del golden el servicio tailscaled (puede quedar habilitado): mismo
    # aislamiento INCONDICIONAL + fail-closed que la rama de canal preexistente (helper único).
    _tc_local_isolate "$ch"
    tc_info "$ch listo (local-only, aislado: estado ausente + servicio deshabilitado + sin IP; acceso vía incus exec / launcher local)."
    continue
  fi
  # puerto tailscale fijo y único + arranque
  incus exec "$ch" -- bash -c "printf 'FLAGS=\"--tun=userspace-networking\"\nPORT=\"$port\"\n' > /etc/default/tailscaled; systemctl enable --now tailscaled"
  for _ in $(seq 1 20); do incus exec "$ch" -- test -S /var/run/tailscale/tailscaled.sock && break; sleep 1; done
  # join: authkey por FICHERO en el contenedor (no por argv del host ni del contenedor).
  # UN SOLO exec atómico: stdin -> /run/tskey (tmpfs, 0600) -> trap shred EXIT -> tailscale --auth-key=file:.
  # Si el exec ni arranca, no se escribió nada; si arranca, el trap garantiza el shred aunque falle el join.
  set +x
  printf '%s' "$AUTHKEY" | incus exec "$ch" -- bash -c '
    umask 077; cat > /run/tskey
    trap "shred -u /run/tskey 2>/dev/null || rm -f /run/tskey" EXIT
    tailscale up --ssh --auth-key=file:/run/tskey --hostname="$1" --accept-dns=false' _ "$ch"
  tc_info "IP: $(incus exec "$ch" -- tailscale ip -4 2>/dev/null || echo n/d)"
done
unset AUTHKEY

echo; tc_say "RESUMEN"
incus list -c ns "$PREFIX$MACHINE_NUM"
echo "✅ FASE 3 COMPLETA. Siguiente: push-carril-env.sh all (env + gh por carril) → 04-autostart."
}

# Guard: sourceable en pruebas sin ejecutar (TC_NO_MAIN=1 expone _tc_local_isolate + tc_clone_main).
[ "${TC_NO_MAIN:-0}" = "1" ] || tc_clone_main "$@"
