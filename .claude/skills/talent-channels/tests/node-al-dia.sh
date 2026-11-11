#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # los textos de las aserciones y de los dobles van literales, sin expandir aquí
# node-al-dia.sh — prueba con dobles de scripts/node-al-dia.sh (contrato N1-N7 de la issue 10160), sin root, sin red,
# sin incus ni apt reales. Cada ejecución del script va con `env -i PATH=<dir de dobles>`: incus, apt-get, apt-cache,
# dpkg-query, node, su, stat, systemctl, id, find y getent son el doble multinombre fake-node-al-dia.sh (ver su cabecera).
# La guarda de sesiones es la REAL (scripts/lib-sesiones.sh) sobre un /proc sintético. El suelo de las pruebas es
# sintético (24=<a>, 22=<b>), salvo la paridad con el fragmento real de 02-golden.sh. Los mutantes se cargan en copias
# del script (una sustitución exacta por mutante) dentro de un árbol propio: ROJO con el mutante y VERDE al revertir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
RAIZ_PAQ="$(cd "$HERE/../../.." && pwd)"
REAL="$SCRIPTS/node-al-dia.sh"
# 59 = 49 casos + 10 mutantes. +12 (ronda de arreglos): 6 casos de identidad de la instancia con el entorno de sudo y sin
# TC_NO_AUTOLOAD (I-a a I-f), 2 del update acotado a NodeSource (U-a, U-b) y 4 mutantes (M11 a M14); 59 + 12 = 71.
# +5 (hallazgo en vivo, SIGPIPE de `incus file pull | parser`): P-a (dpkg/status grande con nodejs en medio), P-b (salida enorme
# de apt-get update con el aviso de NodeSource primero), P-c (estática: ninguna tubería termina en grep -q, head ni en el
# programa de columnas) y los
# mutantes M15 (el parser sale al hallar nodejs) y M16 (grep -q tras tubería); 71 + 5 = 76.
# +1 (revisión del censo de menciones): M17, una tubería que acaba en el programa de columnas, para que P-c siga cazándola
# con su patrón partido («[a]wk», sin la palabra entera); 76 + 1 = 77.
TOTAL_ESPERADO=77

WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-al-dia-prueba.XXXXXX")" || exit 2
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/st" "$WORK/mut" "$WORK/gbin"
for n in incus apt-get apt-cache dpkg-query node su stat systemctl id find getent; do cp "$HERE/fake-node-al-dia.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done
for n in bash sh env timeout cat sort sha256sum cut tr grep sed head tail date seq sleep readlink cp mkdir dirname; do
  ln -s "$(command -v "$n")" "$BIN/$n" || { echo "falta el binario real $n" >&2; exit 2; }
done
# Doble de node de la golden (para la paridad): node -v imprime v$NODE_FAKE.
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "-v" ]; then [ -n "${NODE_FAKE:-}" ] && echo "v${NODE_FAKE}"; exit 0; fi' 'exit 1' > "$WORK/gbin/node"
chmod +x "$WORK/gbin/node"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1" >&2; }

# ── Árbol del script bajo prueba ──────────────────────────────────────────────────────────────────────────────────────
mktree() { # directorio fuente-del-script
  local d="$1"
  mkdir -p "$d/skills/talent-channels/scripts" "$d/skills/talent-channels/assets" "$d/scripts"
  cp "$2" "$d/skills/talent-channels/scripts/node-al-dia.sh"
  ln -sf "$SCRIPTS/00-config.sh" "$d/skills/talent-channels/scripts/00-config.sh"
  ln -sf "$SCRIPTS/lib.sh" "$d/skills/talent-channels/scripts/lib.sh"
  ln -sf "$RAIZ_PAQ/scripts/lib-sesiones.sh" "$d/scripts/lib-sesiones.sh"
  printf '24\t24.5.0\n22\t22.5.0\n' > "$d/skills/talent-channels/assets/node-suelos.tsv"
}
TREE="$WORK/arbol"; mktree "$TREE" "$REAL"
SC="$TREE/skills/talent-channels/scripts/node-al-dia.sh"
TSV="$TREE/skills/talent-channels/assets/node-suelos.tsv"
tsv_ok() { rm -f -- "$TSV"; printf '24\t24.5.0\n22\t22.5.0\n' > "$TSV"; }

# ── Estado del doble ──────────────────────────────────────────────────────────────────────────────────────────────────
NC=0; ST=''; RC=0
caso_nuevo() { NC=$((NC + 1)); ST="$WORK/st/$NC"; mkdir -p "$ST/sujetos"; : > "$ST/calls.log"; printf 0 > "$ST/uid"; tsv_ok; }
suj() { mkdir -p "$ST/sujetos/$1"; [ "$1" = host ] || printf '%s' "$2" > "$ST/sujetos/$1/energia"; }   # nombre energía
nodo() { printf '%s' "$2" > "$ST/sujetos/$1/dpkg"; printf '%s' "${2%%-*}" > "$ST/sujetos/$1/node_v"; }   # sujeto versión-de-apt
mad() { printf ' nodejs | %s | https://deb.nodesource.com/node_%s.x nodistro/main amd64 Packages\n' "$3" "$2" >> "$ST/sujetos/$1/${4:-madison}"; }   # sujeto mayor versión [fichero]
fuente() { # sujeto → fuente de NodeSource bien autenticada en su raíz sintética
  local r="$ST/sujetos/$1/root"
  mkdir -p "$r/etc/apt/sources.list.d" "$r/usr/share/keyrings"
  printf 'Types: deb\nURIs: https://deb.nodesource.com/node_24.x\nSuites: nodistro\nComponents: main\nSigned-By: /usr/share/keyrings/nodesource.gpg\n' > "$r/etc/apt/sources.list.d/nodesource.sources"
  printf 'llavero' > "$r/usr/share/keyrings/nodesource.gpg"
}
proc_add() { # sujeto pid comm [argumentos…]  (PROC_CWD y PROC_DIR opcionales)
  local d="$ST/sujetos/$1/${PROC_DIR:-proc}/$2" a
  mkdir -p "$d"; printf '%s\n' "$3" > "$d/comm"
  shift 3; : > "$d/cmdline"
  for a in "$@"; do printf '%s\0' "$a" >> "$d/cmdline"; done
  ln -sfn "${PROC_CWD:-/}" "$d/cwd"
}
SUJETOS="host golden-t vibe-channel-11 vibe-channel-12 runner-t"
escenario() { # host, golden parada, dos canales y runner, todos en la misma versión vieja y con la misma nueva ofrecida
  caso_nuevo
  local s
  suj host RUNNING; suj golden-t STOPPED; suj vibe-channel-11 RUNNING; suj vibe-channel-12 RUNNING; suj runner-t RUNNING
  for s in $SUJETOS; do
    nodo "$s" 24.4.0-1nodesource1
    fuente "$s"
    mad "$s" 24 24.9.0-1nodesource1; mad "$s" 24 24.3.0-1nodesource1
    printf ' nodejs | 18.19.1+dfsg-6ubuntu5 | http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages\n' >> "$ST/sujetos/$s/madison"
  done
}
nad() { # argumentos… → RC; salida en $ST/out y $ST/err
  env -i PATH="$BIN" NAD_PATH="$BIN" NAD_STATE="$ST" NAD_RAIZ="$ST/sujetos/host/root" TC_NO_AUTOLOAD=1 \
    GOLDEN=golden-t PREFIX=vibe-channel- MACHINE_NUM=1 COUNT=2 CUSER=vivecoder bash "$SC" "$@" > "$ST/out" 2> "$ST/err"
  RC=$?
}
codigo() { nad --plan; sed -n 's/^CONFIRMACION=//p' "$ST/out"; }
# Lanzamiento con el entorno que deja `sudo` (env -i + SUDO_USER, HOME, USER, LOGNAME), SIN TC_NO_AUTOLOAD y SIN
# GOLDEN, MACHINE_NUM ni CUSER (salvo los que pida NADX): la identidad tiene que salir de la instancia. Lo demás
# (NAD_STATE, NAD_PATH, NAD_RAIZ, NAD_HOME) son los ganchos de los dobles. getent es el doble: con EUID 0 la
# identidad del host se resuelve por SUDO_USER; sin root, por USER y HOME.
SUDO_HOME="$WORK/home"; mkdir -p "$SUDO_HOME" "$WORK/id"
NADX=(); ID_N=0; SCI=''; PKGI=''
arbol_id() { # copia del script bajo prueba en un árbol propio (para poner o no contexto.conf)
  ID_N=$((ID_N + 1)); PKGI="$WORK/id/$ID_N"; mktree "$PKGI" "$SC"
  SCI="$PKGI/skills/talent-channels/scripts/node-al-dia.sh"
}
contexto() { # proyecto máquina canales usuario → contexto.conf del paquete y el fichero de respuestas que cita
  mkdir -p "$PKGI/instalacion/estado"
  printf 'proyecto=%s\nmaquina_n=%s\ncanales_n=%s\ncuser=%s\nrepo_rama=main\n' "$1" "$2" "$3" "$4" > "$WORK/id/respuestas-$ID_N.resp"
  printf 'respuestas=%s\nhome=%s\nclon=%s\n' "$WORK/id/respuestas-$ID_N.resp" "$SUDO_HOME" "$WORK/clon" > "$PKGI/instalacion/estado/contexto.conf"
}
nad_sudo() { # argumentos… → RC; salida en $ST/out y $ST/err
  env -i PATH="$BIN" NAD_PATH="$BIN" NAD_STATE="$ST" NAD_RAIZ="$ST/sujetos/host/root" NAD_HOME="$SUDO_HOME" \
    SUDO_USER=operador SUDO_UID=1000 HOME="$SUDO_HOME" USER=operador LOGNAME=operador "${NADX[@]}" bash "$SCI" "$@" > "$ST/out" 2> "$ST/err"
  RC=$?
}
plan_y_ejecuta() { CODE="$(codigo)"; nad --ejecutar "$CODE"; }
estado_hash() { (cd "$ST" && find . -type f ! -name calls.log ! -name out ! -name err ! -name 'guarda-recibida-*' -print0 | sort -z | xargs -0 -r sha256sum | sha256sum); }
sin_escrituras() { ! grep -qE '^apt-get[|]|^incus[|]host[|](start|stop) ' "$ST/calls.log"; }
dpkg_de() { cat "$ST/sujetos/$1/dpkg"; }
ene_de() { cat "$ST/sujetos/$1/energia"; }
NUEVA=24.9.0-1nodesource1
todo_subido() { local s; for s in $SUJETOS; do [ "$(dpkg_de "$s")" = "$NUEVA" ] || return 1; done; }
instalaciones() { grep -E '^apt-get[|][^|]*[|][^|]*[|][^|]*[|](.* )?install ' "$ST/calls.log"; }

# ── Casos: cada uno es una función pura de $SC/$TSV que devuelve 0 si pasa ─────────────────────────────────────────────
c_arranque() {
  bash -n "$SC" && bash -n "$HERE/fake-node-al-dia.sh" || return 1
  [ "$(env -i PATH="$BIN" bash -c 'command -v incus apt-get apt-cache dpkg-query node su stat systemctl id find getent' | grep -c "^$BIN/")" = 11 ] || return 1
  env -i PATH="$BIN" NAD_PATH="$BIN" TC_NO_AUTOLOAD=1 NAD_NO_MAIN=1 GOLDEN=golden-t PREFIX=vibe-channel- MACHINE_NUM=1 COUNT=2 CUSER=vivecoder \
    bash -c '. "$1" && declare -F nad_main nad_plan nad_ejecutar nad_guarda sesiones_vivas_en >/dev/null' _ "$SC"
}
c_n1a() {
  escenario; nad --plan
  [ "$RC" -eq 0 ] || return 1
  local s; for s in $SUJETOS; do grep -q "^$s " "$ST/out" || { echo "falta $s" >&2; return 1; }; done
  grep -q '24.4.0' "$ST/out" && grep -q '24.9.0' "$ST/out" && grep -q 'subir' "$ST/out" && grep -q '24=24.5.0' "$ST/out" || return 1
  [[ "$(tail -n 1 "$ST/out")" =~ ^CONFIRMACION=[0-9a-f]{12}$ ]]
}
c_n1b() {
  escenario; local h1 h2
  h1="$(estado_hash)"; nad --plan; h2="$(estado_hash)"
  [ "$RC" -eq 0 ] && [ "$h1" = "$h2" ] && sin_escrituras && [ "$(ene_de golden-t)" = STOPPED ] &&
    ! grep -qE '(^|[ |])(kill|rm|mv|tee)( |$)' "$ST/calls.log"
}
c_n1c() {
  local a b c d e f
  escenario; a="$(codigo)"; b="$(codigo)"
  escenario; nodo vibe-channel-11 24.4.5-1nodesource1; c="$(codigo)"
  escenario; mad host 24 24.9.5-1nodesource1; d="$(codigo)"
  escenario; printf '24\t24.6.0\n22\t22.5.0\n' > "$TSV"; e="$(codigo)"
  escenario; rm -rf -- "$ST/sujetos/vibe-channel-12"; f="$(codigo)"
  [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" != "$c" ] && [ "$a" != "$d" ] && [ "$a" != "$e" ] && [ "$a" != "$f" ]
}
c_n1d() {
  local a b
  escenario; a="$(codigo)"
  escenario; proc_add vibe-channel-11 100 'tmux: server' 'tmux: server'; printf 1 > "$ST/sujetos/host/stamp"; b="$(codigo)"
  grep -q 'se SALTARÍA' "$ST/out" && grep -q 'AVISO' "$ST/out" && [ -n "$a" ] && [ "$a" = "$b" ]
}
c_n1e() {
  escenario
  nodo vibe-channel-11 18.19.1+dfsg-6ubuntu5; printf 18.19.1 > "$ST/sujetos/vibe-channel-11/node_v"
  printf 24.9.9 > "$ST/sujetos/vibe-channel-12/node_v"
  : > "$ST/sujetos/runner-t/madison"
  nad --plan
  [ "$RC" -eq 0 ] || return 1
  grep '^vibe-channel-11 ' "$ST/out" | grep -q 'sin suelo conocido' &&
    grep '^vibe-channel-12 ' "$ST/out" | grep -q 'no gestionado por apt' &&
    grep '^runner-t ' "$ST/out" | grep -q 'sin repositorio NodeSource' &&
    grep '^host ' "$ST/out" | grep -q 'subir' && grep '^golden-t ' "$ST/out" | grep -q 'subir'
}
c_n2a() {
  escenario; local h1 h2
  h1="$(estado_hash)"; nad --ejecutar; h2="$(estado_hash)"
  [ "$RC" -eq 2 ] && [ "$h1" = "$h2" ] && [ ! -s "$ST/calls.log" ]
}
c_n2b() {
  escenario; local x
  for x in zzz '' 0123456789abc ABCDEF012345 0123456789a; do
    nad --ejecutar "$x"
    [ "$RC" -eq 2 ] && [ ! -s "$ST/calls.log" ] || { echo "código '$x' rc $RC" >&2; return 1; }
  done
}
c_n2c() {
  escenario; local code
  code="$(codigo)"; nodo vibe-channel-12 24.4.7-1nodesource1
  nad --ejecutar "$code"
  [ "$RC" -eq 2 ] && grep -q 'no casa' "$ST/err" && ! grep -q '^apt-get|' "$ST/calls.log" && sin_escrituras && [ "$(ene_de golden-t)" = STOPPED ]
}
c_n2d() {
  escenario; local code
  code="$(codigo)"; printf 1000 > "$ST/uid"; : > "$ST/calls.log"
  nad --ejecutar "$code"
  [ "$RC" -eq 2 ] && grep -q 'root' "$ST/err" && [ ! -s "$ST/calls.log" ]
}
c_n3a() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] && todo_subido || return 1
  local s; for s in $SUJETOS; do grep -q "^subido: $s 24.4.0-1nodesource1 -> $NUEVA" "$ST/out" || { echo "falta subido: $s" >&2; return 1; }; done
  [ "$(cat "$ST/sujetos/vibe-channel-11/node_v")" = 24.9.0 ] && grep -q 'NODE: 5 subidos, 0 saltados, 0 al día' "$ST/out"
}
c_n3b() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] && grep -q 'suelo 24.5.0' "$ST/out" && grep -q 'paquete anterior: nodejs 24.4.0-1nodesource1' "$ST/out" && grep -q 'no se borra nada' "$ST/out" || return 1
  escenario; printf 24.0.0 > "$ST/sujetos/vibe-channel-11/node_v_tras_install"
  plan_y_ejecuta
  [ "$RC" -eq 1 ] && grep -q 'vibe-channel-11' "$ST/err" && grep -q 'suelo' "$ST/err"
}
c_n3c() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] || return 1
  [ "$(instalaciones | wc -l)" -eq 5 ] || return 1
  [ "$(instalaciones | cut -d'|' -f2 | tr '\n' ' ')" = 'golden-t vibe-channel-11 vibe-channel-12 runner-t host ' ] || return 1
  ! instalaciones | grep -qv -- "install --only-upgrade -y nodejs=$NUEVA -o"
}
c_n3d() {
  escenario; mad host 24 24.9.9-1nodesource1 candidato_tras_update
  plan_y_ejecuta
  [ "$RC" -eq 0 ] && [ "$(dpkg_de host)" = 24.9.9-1nodesource1 ] && grep -q 'plan: 24.9.0-1nodesource1; instalado: 24.9.9-1nodesource1' "$ST/out"
}
c_n3e() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] && [ "$(dpkg_de golden-t)" = "$NUEVA" ] && [ "$(ene_de golden-t)" = STOPPED ] || return 1
  local ini fin gua
  ini="$(grep -n '^incus|host|start golden-t' "$ST/calls.log" | head -1 | cut -d: -f1)"
  fin="$(grep -n '^incus|host|stop golden-t' "$ST/calls.log" | head -1 | cut -d: -f1)"
  gua="$(grep -n '^incus|host|exec golden-t bash -c <guarda de sesiones>' "$ST/calls.log" | head -1 | cut -d: -f1)"
  [ -n "$ini" ] && [ -n "$fin" ] && [ -n "$gua" ] && [ "$ini" -lt "$gua" ] && [ "$gua" -lt "$fin" ]
}
c_n3f() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] || return 1
  grep -q '^apt-get|' "$ST/calls.log" && ! grep '^apt-get|' "$ST/calls.log" | grep -qv '|DEBIAN_FRONTEND=noninteractive|NEEDRESTART_MODE=l|'
}
c_n3g() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] || return 1
  ! grep -qE '(^|[ |])(remove|purge|autoremove|clean|autoclean|rm|kill)( |$)' "$ST/calls.log"
}
c_n3h() {
  escenario
  nodo vibe-channel-11 24.7.0-1nodesource1; : > "$ST/sujetos/vibe-channel-11/madison"; mad vibe-channel-11 24 24.3.0-1nodesource1
  : > "$ST/sujetos/runner-t/madison"; mad runner-t 26 26.1.0-1nodesource1
  plan_y_ejecuta
  [ "$RC" -eq 3 ] && [ "$(dpkg_de vibe-channel-11)" = 24.7.0-1nodesource1 ] && [ "$(dpkg_de runner-t)" = 24.4.0-1nodesource1 ] || return 1
  ! grep -qE '^apt-get[|](vibe-channel-11|runner-t)[|]' "$ST/calls.log" || return 1
  [ "$(dpkg_de host)" = "$NUEVA" ] && [ "$(dpkg_de vibe-channel-12)" = "$NUEVA" ]
}
n4() { # añade la sesión con la función $1 y comprueba que vibe-channel-11 se salta y el resto se sube
  escenario; "$1"; plan_y_ejecuta
  [ "$RC" -eq 3 ] && [ "$(dpkg_de vibe-channel-11)" = 24.4.0-1nodesource1 ] && [ "$(dpkg_de vibe-channel-12)" = "$NUEVA" ] || return 1
  grep -q 'saltado: vibe-channel-11: sesión viva' "$ST/out" && ! grep -qE '^apt-get[|]vibe-channel-11[|].*[|]install ' "$ST/calls.log"
}
s_tmux() { proc_add vibe-channel-11 100 'tmux: server' 'tmux: server'; }
s_claude() { proc_add vibe-channel-11 100 claude claude; }
s_codex() { proc_add vibe-channel-11 100 node node /usr/lib/node_modules/@openai/codex/bin/codex.js; }
s_cwd() { PROC_CWD=/home/vivecoder/motor-paquete/x proc_add vibe-channel-11 100 sleep sleep 99; }
s_falsos() { proc_add vibe-channel-11 100 vim vim claude.txt; proc_add vibe-channel-11 101 bash bash -c 'tmux claude codex'; }
c_n4a() { n4 s_tmux; }
c_n4b() { n4 s_claude; }
c_n4c() { n4 s_codex; }
c_n4d() { n4 s_cwd; }
c_n4e() {
  escenario; s_falsos; plan_y_ejecuta
  [ "$RC" -eq 0 ] && todo_subido
}
c_n4f() {
  escenario; s_tmux; plan_y_ejecuta
  [ "$RC" -eq 3 ] && [ -f "$ST/sujetos/vibe-channel-11/proc/100/comm" ] &&
    ! grep -qE '(^|[ |])kill( |$)|^incus[|]host[|]stop vibe-channel-11' "$ST/calls.log"
}
c_n4g() {
  escenario; PROC_DIR=proc_tras_start proc_add golden-t 100 claude claude
  plan_y_ejecuta
  [ "$RC" -eq 3 ] && [ "$(ene_de golden-t)" = STOPPED ] && [ "$(dpkg_de golden-t)" = 24.4.0-1nodesource1 ] &&
    grep -q 'saltado: golden-t: sesión viva' "$ST/out" && grep -q '^incus|host|stop golden-t' "$ST/calls.log" && [ "$(dpkg_de host)" = "$NUEVA" ]
}
c_n4h() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] && [[ "$(cat "$ST/guarda-recibida-vibe-channel-11")" == *"$(cat "$RAIZ_PAQ/scripts/lib-sesiones.sh")"* ]] &&
    ! grep -qE 'readlink|cmdline|sesiones_es_sesion' "$SC" && grep -q 'sesiones_vivas_en' "$SC"
}
c_n5a() {
  escenario; rm -f -- "$TSV"; nad --plan
  [ "$RC" -eq 1 ] && grep -q 'node-suelos.tsv' "$ST/err" && [ ! -s "$ST/calls.log" ]
}
c_n5b() {
  escenario; printf '24\t24.5.0\n' > "$WORK/real.tsv"; rm -f -- "$TSV"; ln -s "$WORK/real.tsv" "$TSV"; nad --plan
  [ "$RC" -eq 1 ] && grep -q 'enlace simbólico' "$ST/err" && [ ! -s "$ST/calls.log" ]
}
c_n5c() {
  escenario; printf '# solo comentarios\n\n' > "$TSV"; nad --plan
  [ "$RC" -eq 1 ] && grep -q 'ningún suelo' "$ST/err" && [ ! -s "$ST/calls.log" ]
}
c_n5d() {
  escenario; local x
  for x in '24\t22.5.0\n' '24\t24.5.0; touch x\n' '24 24.5.0\n' '24\t24.5.0\textra\n'; do
    # shellcheck disable=SC2059  # la fila de prueba es el formato de printf a propósito (\t y \n)
    printf "$x" > "$TSV"; nad --plan
    [ "$RC" -eq 1 ] && grep -q 'fila inválida' "$ST/err" && [ ! -s "$ST/calls.log" ] || { echo "fila '$x' rc $RC" >&2; return 1; }
  done
}
c_n5e() {
  escenario; printf '24\t24.5.0\n24\t24.6.0\n' > "$TSV"; nad --plan
  [ "$RC" -eq 1 ] && grep -q 'mayor repetida' "$ST/err" && [ ! -s "$ST/calls.log" ]
}
c_n5f() {
  escenario; nodo host 18.19.1+dfsg-6ubuntu5; printf 18.19.1 > "$ST/sujetos/host/node_v"
  plan_y_ejecuta
  [ "$RC" -eq 3 ] && grep -q 'saltado: host: mayor 18 sin suelo conocido' "$ST/out" && grep -q 'EMPIEZA-AQUI.md' "$ST/out" || return 1
  [ "$(dpkg_de host)" = 18.19.1+dfsg-6ubuntu5 ] && [ "$(dpkg_de vibe-channel-11)" = "$NUEVA" ] && [ "$(dpkg_de runner-t)" = "$NUEVA" ]
}
G="$SCRIPTS/02-golden.sh"
extrae() { # ancla-ini ancla-fin → líneas entre las dos anclas del golden real
  local a b
  a="$(grep -nxF "$1" "$G" | head -1 | cut -d: -f1)"; b="$(grep -nxF "$2" "$G" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || return 1
  sed -n "$((a + 1)),$((b - 1))p" "$G"
}
HOST_SNIPPET="$(extrae '# suelos-host:ini' '# suelos-host:fin')"
CONT_SNIPPET="$(extrae '# suelo:ini' '# suelo:fin')"
golden_ok() { # mayor versión → rc de la comprobación REAL de la golden con los suelos de $TSV
  (
    ASSETS="$(dirname "$TSV")"
    tc_die() { echo "tc_die: $*" >&2; exit 1; }
    eval "$HOST_SNIPPET"
    export SUELOS="$NODE_SUELOS" NV="$1" NODE_FAKE="$2"
    PATH="$WORK/gbin:$PATH"
    bash -ec "$CONT_SNIPPET"
  ) > /dev/null 2>&1
}
mio_ok() { # versión → rc de nad_suelo_ok del script bajo prueba
  env -i PATH="$BIN" NAD_PATH="$BIN" TC_NO_AUTOLOAD=1 NAD_NO_MAIN=1 GOLDEN=golden-t PREFIX=vibe-channel- MACHINE_NUM=1 COUNT=2 CUSER=vivecoder \
    bash -c '. "$1" && nad_cargar_suelos && nad_suelo_ok "$2"' _ "$SC" "$1" > /dev/null 2>&1
}
c_n5g() {
  [ -n "$HOST_SNIPPET" ] && [ -n "$CONT_SNIPPET" ] || return 1
  caso_nuevo
  local par g m
  for par in '24 24.4.9' '24 24.5.0' '24 24.5.1' '24 24.6.0' '24 24.10.0' '24 24.4.99' '22 22.4.9' '22 22.5.0' '30 30.0.0' '25 25.0.0' '24 24.5.0-rc.1' '24 24.20.0'; do
    # shellcheck disable=SC2086
    set -- $par
    golden_ok "$1" "$2"; g=$?; mio_ok "$2"; m=$?
    [ "$((g == 0))" = "$((m == 0))" ] || { echo "veredicto distinto para $par: golden rc $g, script rc $m" >&2; return 1; }
  done
  golden_ok 24 ''; g=$?; mio_ok ''; m=$?
  [ "$((g == 0))" = "$((m == 0))" ] && [ "$g" -ne 0 ]
}
n6() { # sujeto-a-estropear función-que-lo-estropea  → rc 1 y ninguna instalación en ningún sujeto
  escenario; "$2" "$1"; plan_y_ejecuta
  [ "$RC" -eq 1 ] && [ -z "$(instalaciones)" ]
}
f_sin_firmante() { printf 'Types: deb\nURIs: https://deb.nodesource.com/node_24.x\nSuites: nodistro\nComponents: main\n' > "$ST/sujetos/$1/root/etc/apt/sources.list.d/nodesource.sources"; }
f_no_verificada() { printf 'Types: deb\nURIs: https://deb.nodesource.com/node_24.x\nSigned-By: /usr/share/keyrings/nodesource.gpg\nTrusted: yes\n' > "$ST/sujetos/$1/root/etc/apt/sources.list.d/nodesource.sources"; }
f_llavero_vacio() { : > "$ST/sujetos/$1/root/usr/share/keyrings/nodesource.gpg"; }
f_llavero_ausente() { rm -f -- "$ST/sujetos/$1/root/usr/share/keyrings/nodesource.gpg"; }
f_aviso_pubkey() { printf 'W: GPG error: https://deb.nodesource.com nodistro InRelease: NO_PUBKEY 2F59B5F99B1BE0B4\n' > "$ST/sujetos/$1/aviso_update"; }
f_aviso_sin_firma() { printf 'W: The repository https://deb.nodesource.com nodistro InRelease is not signed.\n' > "$ST/sujetos/$1/aviso_update"; }
c_n6a() { n6 host f_sin_firmante; }
c_n6b() { n6 host f_no_verificada && n6 vibe-channel-12 f_no_verificada; }
c_n6c() { n6 host f_llavero_vacio && n6 runner-t f_llavero_ausente; }
c_n6d() { n6 runner-t f_aviso_pubkey && n6 host f_aviso_sin_firma; }
c_n6e() {
  escenario; printf ' nodejs | 24.9.9-0ubuntu1 | http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages\n' > "$ST/sujetos/runner-t/madison"
  plan_y_ejecuta
  [ "$RC" -eq 3 ] && [ "$(dpkg_de runner-t)" = 24.4.0-1nodesource1 ] && grep -q 'saltado: runner-t: SIN MEDIR: sin repositorio NodeSource' "$ST/out" &&
    ! grep -q '^apt-get|runner-t|' "$ST/calls.log" && [ "$(dpkg_de host)" = "$NUEVA" ]
}
c_n6f() {
  escenario; plan_y_ejecuta
  [ "$RC" -eq 0 ] && [ -n "$(instalaciones)" ] || return 1
  ! instalaciones | grep -qvE 'AllowUnauthenticated=false.*Acquire::AllowInsecureRepositories=false' &&
    ! grep -qE -- '--allow-unauthenticated|--force-yes|AllowUnauthenticated=true|trusted' "$ST/calls.log" &&
    ! grep '^apt-get|.*|update' "$ST/calls.log" | grep -qv 'AllowInsecureRepositories=false'
}
c_n6g() { ! grep -qnE 'curl|setup_|[|] *bash|bash *-( |$)' "$SC"; }
al_dia() { local s; escenario; for s in $SUJETOS; do nodo "$s" "$NUEVA"; done; }
c_n7a() {
  al_dia; local h1 h2
  h1="$(estado_hash)"; nad --plan; h2="$(estado_hash)"
  [ "$RC" -eq 0 ] && grep -q 'Nada que subir' "$ST/out" && ! grep -q 'CONFIRMACION=' "$ST/out" && [ "$h1" = "$h2" ] && sin_escrituras
}
c_n7b() {
  al_dia; nad --ejecutar 000000000000
  [ "$RC" -eq 0 ] && grep -q 'Nada que subir' "$ST/out" && sin_escrituras && ! grep -q '^apt-get|' "$ST/calls.log" && [ "$(ene_de golden-t)" = STOPPED ]
}
c_n7c() {
  al_dia; nad --plan
  [ "$RC" -eq 0 ] && grep -q '^incus|host|file pull golden-t/var/lib/dpkg/status -' "$ST/calls.log" && ! grep -q '^incus|host|start' "$ST/calls.log" &&
    grep '^golden-t ' "$ST/out" | grep -q 'al-dia'
}
c_sa() {
  ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+' "$SC" && ! grep -qwE '22|24|26' "$SC"
}
c_sb() {
  ! grep -qwE 'rm|kill|pkill|remove|purge|autoremove|clean|autoclean' "$SC" && ! grep -qE -- '--allow-unauthenticated|--force-yes|AllowUnauthenticated=true|trusted=yes' "$SC"
}
c_da() {
  local ref="$HERE/../references/06-operacion-y-launchers.md" skill="$HERE/../SKILL.md"
  local a='bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --plan'
  local b='sudo bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --ejecutar "$CODIGO"'
  grep -qF -- "$a" "$ref" && grep -qF -- "$b" "$ref" && grep -qF 'node-al-dia.sh' "$skill" && grep -q '^44\. ' "$skill"
}
c_db() {
  ! grep -qE 'TAL-[0-9]+' "$REAL" "$HERE/fake-node-al-dia.sh" "${BASH_SOURCE[0]}"
}
c_dc() {
  local f="$HERE/../../talent-ceo/scripts/doctor-sondas.tsv"
  [ "$(grep -P '^node-canal\t' "$f" | cut -f7,8,10,11)" = "$(printf 'su\t-\t-c\tnode -v')" ] && grep -qF "su - \"\$CUSER\" -c 'node -v'" "$SC"
}
c_dd() {
  local a
  for a in '# suelos-host:ini' '# suelos-host:fin' '# suelo:ini' '# suelo:fin'; do grep -qxF "$a" "$G" || return 1; done
  grep -qxF 'apt-get install -y -qq nodejs' "$G"
}

# ── Identidad de la instancia (sudo limpio, sin TC_NO_AUTOLOAD) y fuente de NodeSource acotada ─────────────────────────
c_i1() { # una instancia 2.0 con su contexto.conf: plan y ejecución sin una sola variable de identidad en el entorno
  escenario; arbol_id; contexto t 1 2 vivecoder
  nad_sudo --plan
  [ "$RC" -eq 0 ] || { echo "plan rc $RC: $(head -n 3 "$ST/err")" >&2; return 1; }
  local s code; for s in $SUJETOS; do grep -q "^$s " "$ST/out" || { echo "falta $s" >&2; return 1; }; done
  code="$(sed -n 's/^CONFIRMACION=//p' "$ST/out")"; [ -n "$code" ] || return 1
  nad_sudo --ejecutar "$code"
  [ "$RC" -eq 0 ] && todo_subido
}
c_i2() { # sin contexto.conf y sin variables: rc 2, dice qué falta y no escribe nada (nunca los defaults golden/vivecoder)
  escenario; arbol_id
  nad_sudo --plan
  [ "$RC" -eq 2 ] && grep -q 'falta la identidad de la instancia' "$ST/err" && grep -q 'GOLDEN MACHINE_NUM CUSER' "$ST/err" && sin_escrituras
}
c_i3() { # identidad explícita incompleta: rc 2; con la golden «por defecto» y golden-t presente no puede salir «Nada que subir»
  escenario; arbol_id; local s; for s in $SUJETOS; do nodo "$s" "$NUEVA"; done
  NADX=(MACHINE_NUM=1 CUSER=vivecoder); nad_sudo --plan; NADX=()
  [ "$RC" -eq 2 ] && grep -q 'faltan en el entorno: GOLDEN' "$ST/err" && ! grep -q 'Nada que subir' "$ST/out" || return 1
  NADX=(GOLDEN=golden-t); nad_sudo --plan; NADX=()
  [ "$RC" -eq 2 ] && grep -q 'faltan en el entorno: MACHINE_NUM CUSER' "$ST/err"
}
c_i4() { # el entorno contradice a la instancia: rc 2 sin escribir; si coincide, vale
  escenario; arbol_id; contexto t 1 2 vivecoder
  NADX=(GOLDEN=golden-x); nad_sudo --plan; NADX=()
  [ "$RC" -eq 2 ] && grep -q 'identidad en conflicto' "$ST/err" && sin_escrituras || return 1
  NADX=(GOLDEN=golden-t MACHINE_NUM=1 CUSER=vivecoder); nad_sudo --plan; NADX=()
  [ "$RC" -eq 0 ] && grep -q '^golden-t ' "$ST/out"
}
c_i5() { # respuestas inválidas, contexto.conf enlazado o identidad explícita inválida: rc 2
  escenario; arbol_id; contexto 'A_b' 1 2 vivecoder
  nad_sudo --plan; [ "$RC" -eq 2 ] && grep -q 'son inválidas en .*: proyecto' "$ST/err" || return 1
  arbol_id; contexto t 1 2 vivecoder
  mv "$PKGI/instalacion/estado/contexto.conf" "$WORK/id/ctx-real-$ID_N"
  ln -s "$WORK/id/ctx-real-$ID_N" "$PKGI/instalacion/estado/contexto.conf"
  nad_sudo --plan; [ "$RC" -eq 2 ] && grep -q 'enlace simbólico' "$ST/err" || return 1
  arbol_id; NADX=(GOLDEN=golden MACHINE_NUM=1 CUSER=vivecoder); nad_sudo --plan; NADX=()
  [ "$RC" -eq 2 ] && grep -q 'identidad explícita inválida' "$ST/err" && sin_escrituras
}
c_i6() { # la golden o el runner de la instancia ausentes: rc 1 con el nombre, nunca omitidos en silencio
  escenario; arbol_id; contexto t 1 2 vivecoder; rm -rf -- "$ST/sujetos/golden-t"
  nad_sudo --plan
  [ "$RC" -eq 1 ] && grep -q 'la golden esperada golden-t no existe' "$ST/err" && ! grep -q 'Nada que subir' "$ST/out" || return 1
  escenario; arbol_id; contexto t 1 2 vivecoder; rm -rf -- "$ST/sujetos/runner-t"
  nad_sudo --plan
  [ "$RC" -eq 1 ] && grep -q 'el runner esperado runner-t no existe' "$ST/err" && ! grep -q 'Nada que subir' "$ST/out"
}
c_m1a() { # un repositorio ajeno roto (aviso de firma, fallo de update) no aborta Node: el update va acotado a NodeSource
  escenario
  printf 'W: GPG error: https://dl.google.com stable InRelease: NO_PUBKEY 4EB27DB2A3B88B8B\n' > "$ST/sujetos/host/aviso_update_ajeno"
  printf 'W: GPG error: https://download.docker.com noble InRelease: EXPKEYSIG 7EA0A9C3F273FCD8\n' > "$ST/sujetos/vibe-channel-11/aviso_update_ajeno"
  printf 'x' > "$ST/sujetos/runner-t/update_ajeno.fail"
  plan_y_ejecuta
  [ "$RC" -eq 0 ] && todo_subido || return 1
  local u n; n=0
  while IFS= read -r u; do
    n=$((n + 1))
    case "$u" in *'Dir::Etc::sourcelist=/etc/apt/sources.list.d/nodesource.sources'*'Dir::Etc::sourceparts=-'*'APT::Get::List-Cleanup=0'*) ;; *) echo "update sin acotar: $u" >&2; return 1 ;; esac
  done < <(grep '^apt-get|.*|update' "$ST/calls.log")
  [ "$n" -ge 5 ]
}
c_m1c() { # NodeSource solo en sources.list (mezclada con otras): no se puede aislar, el update de ese sujeto sigue completo
  escenario
  local r="$ST/sujetos/host/root"
  rm -f -- "$r/etc/apt/sources.list.d/nodesource.sources"
  printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main\n' > "$r/etc/apt/sources.list"
  plan_y_ejecuta
  [ "$RC" -eq 0 ] && todo_subido || return 1
  ! grep '^apt-get|host|' "$ST/calls.log" | grep -q 'Dir::Etc::sourcelist=' &&
    grep '^apt-get|golden-t|' "$ST/calls.log" | grep -q 'Dir::Etc::sourcelist='
}

# ── Tuberías con salida temprana: el rc 141 (SIGPIPE) no puede convertirse en «vacío» ni en «no está» ─────────────────────
c_p1() { # dpkg/status GRANDE con nodejs EN MEDIO: la golden parada se mide, no sale «no instalado por apt»
  escenario; printf x > "$ST/sujetos/golden-t/status_grande"
  nad --plan
  [ "$RC" -eq 0 ] && grep '^golden-t ' "$ST/out" | grep -q '24.4.0' && ! grep -q 'Node no instalado por apt' "$ST/out"
}
c_p2() { # salida GRANDE de apt-get update con el aviso de NodeSource primero: sigue abortando (rc 1, nada instalado)
  escenario
  printf 'W: Failed to fetch https://deb.nodesource.com/node_24.x/dists/nodistro/InRelease  Temporary failure resolving\n' > "$ST/sujetos/host/aviso_update"
  local i; for ((i = 1; i <= 4000; i++)); do printf 'Hit:%s https://archive.ubuntu.com/ubuntu noble InRelease relleno relleno relleno\n' "$i" >> "$ST/sujetos/host/aviso_update"; done
  plan_y_ejecuta
  [ "$RC" -eq 1 ] && [ -z "$(instalaciones)" ]
}
c_p3() { # estática: ninguna tubería del script tiene un consumidor que pueda salir antes de leerlo todo (grep -q, head, el programa de columnas)
  # «[a]wk» y no la palabra entera: el censo de menciones del paquete no debe contar este patrón como una invocación.
  ! grep -nE '[|] *(grep +-[A-Za-z]*q|head( |$)|[a]wk)' "$SC"
}

run() { # etiqueta función
  if "$2" 2> "$WORK/diag"; then ok "$1"; else bad "$1"; [ ! -s "$WORK/diag" ] || sed 's/^/      /' "$WORK/diag" >&2; [ ! -s "$ST/err" ] || head -n 3 "$ST/err" | sed 's/^/      err: /' >&2; fi
}

echo "== node-al-dia: arranque =="
run "C0 los dobles son lo que corre, el script carga y sus funciones existen" c_arranque
echo "== node-al-dia: N1 plan =="
run "N1-a el plan lista sujetos, versiones y acción, y termina con CONFIRMACION=<12 hex>" c_n1a
run "N1-b el plan no escribe: sin apt-get, sin arrancar ni parar, estado idéntico" c_n1b
run "N1-c el código es determinista y cambia con una versión, un candidato, el fichero de suelos o un canal" c_n1c
run "N1-d lo volátil (sesión viva, caché vieja) se informa pero no entra en el código" c_n1d
run "N1-e el plan dice qué se saltaría y por qué (mayor sin suelo, node fuera de apt, sin repositorio)" c_n1e
echo "== node-al-dia: N2 confirmación =="
run "N2-a --ejecutar sin código: rc 2 y cero llamadas" c_n2a
run "N2-b código con formato inválido (texto, vacío, 13 y 11 caracteres, mayúsculas): rc 2 y cero llamadas" c_n2b
run "N2-c código de un plan viejo: rc 2, ni un apt-get, nada arrancado" c_n2c
run "N2-d sin root: rc 2 antes de leer nada" c_n2d
echo "== node-al-dia: N3 ejecución =="
run "N3-a el host, la golden, los canales y el runner quedan en el parche más reciente de su mayor" c_n3a
run "N3-b el suelo se comprueba y se declara; un node -v por debajo del suelo tras instalar da rc 1" c_n3b
run "N3-c orden golden, canales, runner, host; cada instalación con --only-upgrade y versión exacta" c_n3c
run "N3-d si la lista refrescada ofrece algo más nuevo se instala y se declara plan e instalado" c_n3d
run "N3-e golden parada: se arranca, la guarda corre después, se sube y vuelve a parada" c_n3e
run "N3-f todo apt-get lleva DEBIAN_FRONTEND=noninteractive y el modo de needrestart que solo lista" c_n3f
run "N3-g no se borra nada ni se envían señales" c_n3g
run "N3-h nunca baja ni cambia de mayor: candidato menor o de otra mayor, no se instala" c_n3h
echo "== node-al-dia: N4 sesiones vivas =="
run "N4-a tmux vivo: el canal se salta, rc 3, los demás se suben" c_n4a
run "N4-b claude vivo: ídem" c_n4b
run "N4-c codex bajo node (argv[1]): ídem" c_n4c
run "N4-d proceso con el cwd dentro del motor: ídem" c_n4d
run "N4-e sin falso positivo: vim claude.txt y bash -c con las palabras no cuentan" c_n4e
run "N4-f la sesión sigue viva: ni señales ni parada del canal" c_n4f
run "N4-g sesión que aparece al arrancar un contenedor parado: se salta y vuelve a parado" c_n4g
run "N4-h la guarda es la compartida: el texto de lib-sesiones.sh viaja entero y el script no la duplica" c_n4h
echo "== node-al-dia: N5 suelos =="
run "N5-a node-suelos.tsv ausente: rc 1 sin tocar nada" c_n5a
run "N5-b node-suelos.tsv enlace simbólico: rc 1" c_n5b
run "N5-c node-suelos.tsv sin ningún suelo: rc 1" c_n5c
run "N5-d fila inválida (suelo de otra mayor, metacaracteres, sin tabulador, tercera columna): rc 1" c_n5d
run "N5-e mayor repetida: rc 1" c_n5e
run "N5-f mayor instalada sin suelo: solo ese sujeto se salta con el remedio, rc 3" c_n5f
run "N5-g paridad con el fragmento REAL de 02-golden.sh en una tabla de versiones" c_n5g
echo "== node-al-dia: N6 fuente autenticada =="
run "N6-a fuente sin Signed-By: rc 1 y ninguna instalación en ningún sujeto" c_n6a
run "N6-b fuente marcada como no verificada: rc 1 sin instalar" c_n6b
run "N6-c llavero vacío o ausente: rc 1 sin instalar" c_n6c
run "N6-d apt-get update con NO_PUBKEY o repositorio sin firmar: rc 1 sin instalar" c_n6d
run "N6-e candidatos solo de Ubuntu: el sujeto se salta, rc 3, sin apt-get en él" c_n6e
run "N6-f toda instalación y actualización lleva las opciones de autenticación y ninguna prohibida" c_n6f
run "N6-g el script no usa curl ni el script de instalación de NodeSource ni tuberías a bash" c_n6g
echo "== node-al-dia: N7 todo al día =="
run "N7-a plan con todo al día: nada que subir, sin código, sin escrituras" c_n7a
run "N7-b --ejecutar con todo al día: rc 0, sin apt-get ni arranque" c_n7b
run "N7-c golden parada medida con file pull, sin arrancarla" c_n7c
echo "== node-al-dia: identidad de la instancia (entorno de sudo, sin TC_NO_AUTOLOAD) =="
run "I-a una instancia con contexto.conf: plan y ejecución sin variables de identidad en el entorno" c_i1
run "I-b sin contexto.conf y sin variables: rc 2, dice qué falta y no escribe (nunca golden/vivecoder por defecto)" c_i2
run "I-c identidad explícita incompleta: rc 2; con la golden por defecto y golden-t presente no sale «Nada que subir»" c_i3
run "I-d el entorno contradice a la instancia: rc 2 sin escribir; si coincide, vale" c_i4
run "I-e respuestas inválidas, contexto.conf enlazado o identidad explícita inválida: rc 2" c_i5
run "I-f la golden o el runner de la instancia ausentes: rc 1 con el nombre, nunca en silencio" c_i6
echo "== node-al-dia: apt-get update acotado a NodeSource =="
run "U-a un repositorio ajeno roto (firma o fallo de update) no aborta Node: el update va acotado a la fuente de NodeSource" c_m1a
run "U-b NodeSource solo en sources.list: no se aísla y ese sujeto refresca completo" c_m1c
echo "== node-al-dia: tuberías con salida temprana (SIGPIPE) =="
run "P-a un dpkg/status de más de 300 KiB con nodejs en medio: la golden parada se mide (la versión no depende del rc de la tubería)" c_p1
run "P-b una salida enorme de apt-get update con el aviso de NodeSource primero: sigue abortando, rc 1 y nada instalado" c_p2
run "P-c ninguna tubería del script termina en grep -q, head ni en el programa de columnas" c_p3
echo "== node-al-dia: estáticas y documentación =="
run "S-a cero versiones ni mayores literales en el script" c_sa
run "S-b cero verbos de borrado ni opciones inseguras en el script" c_sb
run "D-a la interfaz literal figura en la referencia 06 y el gotcha 44 en SKILL.md" c_da
run "D-b cero claves de issue en los ficheros nuevos" c_db
run "D-c la orden de node -v del canal es la de la sonda del doctor" c_dc
run "D-d la golden conserva sus anclas de suelo y su instalación" c_dd

# ── Mutantes: una sustitución exacta sobre una copia; ROJO con el mutante y VERDE al revertir ────────────────────────
mutante() { # nombre ancla reemplazo caso…
  local n="$1" a="$2" r="$3" t rest con=0 sin=0 f sc0="$SC" tsv0="$TSV"; shift 3
  t="$(cat "$REAL")"; rest="${t#*"$a"}"
  if [ "$rest" = "$t" ] || [[ "$rest" == *"$a"* ]]; then bad "$n: el ancla no aparece exactamente una vez en node-al-dia.sh"; return; fi
  printf '%s\n' "${t/"$a"/"$r"}" > "$WORK/mut-$n.sh"
  mktree "$WORK/mut/$n" "$WORK/mut-$n.sh"
  SC="$WORK/mut/$n/skills/talent-channels/scripts/node-al-dia.sh"; TSV="$WORK/mut/$n/skills/talent-channels/assets/node-suelos.tsv"
  for f in "$@"; do "$f" > /dev/null 2>&1 || con=$((con + 1)); done
  SC="$sc0"; TSV="$tsv0"
  for f in "$@"; do "$f" > /dev/null 2>&1 || sin=$((sin + 1)); done
  if [ "$con" -gt 0 ] && [ "$sin" -eq 0 ]; then ok "$n: ROJO con el mutante ($con casos) y VERDE al revertir"; else bad "$n: con el mutante fallan $con casos y sin él $sin"; fi
}
echo "== node-al-dia: mutantes =="
mutante M1-sin-confirmacion '[ "$codigo" = "$esperado" ] ||' 'true ||' c_n2c
mutante M2-suelo-hardcodeado "printf '%s' \"\${NAD_SUELO[\$1]-}\"" "printf '%s' \"24.0.0\"" c_sa c_n5g
mutante M3-sesion-viva-ignorada '1) NAD_GMOT="sesión viva: $NAD_VIVAS"; return 1 ;;' '1) return 0 ;;' c_n4a c_n4g
mutante M4-fuente-sin-firma 'NAD_FOUT="$(nad_run "$1" bash -c "$NAD_FIRMA_TXT" _ "${NAD_RAIZ:-/}")"' 'NAD_FOUT=""' c_n6a c_n6c
mutante M5-instala-sin-solo-subir 'install --only-upgrade -y' 'install -y' c_n3c
mutante M6-needrestart-reinicia 'NEEDRESTART_MODE=l' 'NEEDRESTART_MODE=a' c_n3f
mutante M7-cwd-no-cuenta 'sesiones_vivas_en "$1" "/home/$CUSER/motor-paquete"' 'sesiones_vivas_en "$1" ""' c_n4d
mutante M8-sin-filtro-de-origen '[[ $url =~ $re_url ]] || continue' 'true' c_n6e
mutante M9-saltados-con-rc-0 '[ "$nl" -eq 0 ] || rc=3' '[ "$nl" -eq 0 ] || rc=0' c_n4a
mutante M10-no-devuelve-la-energia 'for c in "${NAD_ARR[@]}"; do incus stop "$c" >/dev/null 2>&1; done' 'for c in "${NAD_ARR[@]}"; do : ; done' c_n3e
mutante M11-sin-identidad-de-la-instancia 'GOLDEN="$g"; MACHINE_NUM="$m"; COUNT="$n"; CUSER="$u"' ':' c_i1
mutante M12-golden-ausente-en-silencio 'else nad_fin 1 "ERROR: la golden esperada $GOLDEN no existe en esta máquina (incus list); no se sube nada. Comprueba la identidad de la instancia."; fi' 'fi' c_i6
mutante M13-conflicto-ignorado '[ "${#choque[@]}" -eq 0 ] || nad_fin 2 "ERROR: identidad en conflicto entre el entorno y la instancia: ${choque[*]}. No se ha escrito nada."' ':' c_i4
mutante M14-update-sin-acotar '-o "Dir::Etc::sourcelist=$f" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0' '' c_m1a
mutante M15-parser-sale-al-hallar-nodejs 'then hallada="$v"; fi
        pk=""; st=""; v="" ;;' 'then printf '"'"'%s'"'"' "$v"; return 0; fi
        pk=""; st=""; v="" ;;' c_p1 c_p3
# M17: el programa de columnas se arma en ejecución (la palabra entera no está escrita en este fichero: el censo de menciones
# del paquete la contaría como una invocación). La copia mutada lleva una tubería que acaba en él: P-c tiene que cazarla.
PCOL="$(printf '%s%s' a wk)"
mutante M17-tuberia-que-acaba-en-el-programa-de-columnas 'NAD_TOPE_S=1800' "NAD_TOPE_S=1800; true | $PCOL 1" c_p3
mutante M16-grep-q-tras-tuberia '[ -z "$(printf '"'"'%s\n'"'"' "$1" | grep -iE '"'"'^(W|E):.*nodesource'"'"')" ] || return 1' 'if printf '"'"'%s\n'"'"' "$1" | grep -qiE '"'"'^(W|E):.*nodesource'"'"'; then return 1; fi' c_p2 c_p3

TOTAL=$((PASS + FAIL))
echo "RESULTADO node-al-dia PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL/$TOTAL_ESPERADO"
[ "$FAIL" -eq 0 ] && [ "$TOTAL" -eq "$TOTAL_ESPERADO" ]
