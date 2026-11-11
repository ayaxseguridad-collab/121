#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # las aserciones de chk son texto que se evalúa a propósito con eval
# Prueba con dobles de scripts/cortafuegos-supabase.sh (contrato C1-C7 de la issue 9562, las redes de docker
# obligatorias y las correcciones de la ronda 2). Sin root y sin tocar jamás el cortafuegos real: cada
# ejecución del script va con `env -i PATH=<dir de dobles>`, así que los iptables, ip6tables, ss, systemctl,
# hostname, id y stat reales NO están en el PATH. Los mutantes apuntan a una copia con CORTAFUEGOS_SCRIPT.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CORTAFUEGOS_SCRIPT:-$HERE/../scripts/cortafuegos-supabase.sh}"
# UN solo directorio de dobles y UN solo directorio de estado para todos los casos (pocos inodos). La prueba NO
# borra nada: el directorio queda en $TMPDIR para quien lo inspeccione. Los modos de fallo se apagan vaciando
# el fichero (> sin contenido), nunca borrándolo.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cortafuegos-prueba.XXXXXX")"
BIN="$WORK/bin"; ST="$WORK/estado"; mkdir -p "$BIN" "$ST"
for n in iptables ip6tables ss systemctl hostname id stat; do cp "$HERE/fake-cortafuegos.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done
for n in bash grep cat mv touch; do ln -s "$(command -v "$n")" "$BIN/$n"; done
REAL_ID="$(command -v id)"; REAL_STAT="$(command -v stat)"
P=54421:54424; T=tc-supabase-fw; N=192.0.2.0/24
RS="-p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $P -s $N -m comment --comment $T -j RETURN"
DS="-p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $P -m comment --comment $T -j DROP"
FLAGS="iptables.noperm ip6tables.noperm iptables.fail-ins ip6tables.fail-ins iptables.fail-c ip6tables.fail-c iptables.fail-del ip6tables.fail-del ss.rc ss.empty systemctl.system.fail systemctl.user.fail systemctl.system.gnome-remote-desktop systemctl.system.xrdp systemctl.user.gnome-remote-desktop hostname.fail id.fail uid stat.owner iptables.fail-n iptables.fail-s iptables.extra-s iptables.skip-del"
pass=0; fail=0
chk() {
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2
    [ ! -s "$ST/err" ] || head -n 3 "$ST/err" | sed 's/^/    err: /' >&2   # diagnóstico: último error del script
  fi
}

newcase() {
  local f
  for f in $FLAGS iptables.rules ip6tables.rules calls.log out err; do : > "$ST/$f"; done
  printf 'alfa.red.example\n' > "$ST/hostname"; printf 0 > "$ST/uid"; printf 0 > "$ST/stat.owner"   # por defecto se simula ser root (apply lo exige)
  printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 128 [::]:22 [::]:*\n' > "$ST/ss.out"
  printf 'filter|DOCKER-USER\n' > "$ST/iptables.chains"; printf 'filter|DOCKER-USER\n' > "$ST/ip6tables.chains"
  ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf" "CORTAFUEGOS_SUPABASE=si" "CORTAFUEGOS_REDES_DOCKER=$N")
}
on() { printf 1 > "$ST/$1"; }
fw() {
  env -i PATH="$BIN" FW_STATE="$ST" FW_REAL_ID="$REAL_ID" FW_REAL_STAT="$REAL_STAT" "${ENVX[@]}" bash "$SCRIPT" "$@" > "$ST/out" 2> "$ST/err"
  RC=$?; cat "$ST/out" "$ST/err" "$ST/calls.log" >> "$WORK/todo.log"
}
cambios() { grep -cE ' (-I|-D|-N|-A|-P|-F|-X|-R|-Z)( |$)' "$ST/calls.log" || true; }
nreg() { if [ -f "$ST/$1.rules" ]; then grep -c . "$ST/$1.rules" || true; else echo 0; fi; }
marca() { grep -c -- "$T" "$ST/iptables.rules" "$ST/ip6tables.rules" | grep -v ':0$' | grep -c . || true; }   # ficheros con reglas con la marca
quita() { mv "$BIN/$1" "$BIN/$1.off"; }
pon() { mv "$BIN/$1.off" "$BIN/$1"; }
exp_rules() {
  printf '%s\n' \
    "iptables raw PREROUTING -p tcp -m multiport --dports ${2:-$P} ! -i lo ! -s $1 -m comment --comment $T -j DROP" \
    "iptables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport ${2:-$P} -s $1 -m comment --comment $T -j RETURN" \
    "iptables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport ${2:-$P} -m comment --comment $T -j DROP" \
    "iptables filter INPUT -p tcp -m multiport --dports ${2:-$P} ! -i lo ! -s $1 -m comment --comment $T -j DROP" \
    "ip6tables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport ${2:-$P} -m comment --comment $T -j DROP" \
    "ip6tables filter INPUT -p tcp -m multiport --dports ${2:-$P} ! -i lo -m comment --comment $T -j DROP"
}
sinc() { grep -v '^#' "$ST/out"; }
negado() { [ "$RC" = "$1" ] && [ "$(cambios)" = 0 ]; }   # rc exacto y cero llamadas de cambio
conf() { printf '%b' "$1" > "$ST/f.conf"; chmod "${2:-600}" "$ST/f.conf"; ENVX=("CORTAFUEGOS_CONF=$ST/f.conf"); }
du_lineas() { grep '^filter|DOCKER-USER|' "$ST/iptables.rules"; }

# C0 — los dobles son lo que se ejecuta
newcase
chk 'C0 el PATH de la prueba resuelve a los dobles y no hay nft' \
  '[ "$(env -i PATH="$BIN" bash -c "command -v iptables ip6tables ss systemctl hostname" | grep -c "^$BIN/")" = 5 ] && ! env -i PATH="$BIN" bash -c "command -v nft" >/dev/null'
chk 'C0 el script no lleva rutas absolutas a iptables, ip6tables, systemctl ni ss' \
  '[ -f "$SCRIPT" ] && ! grep -qE "/(usr/)?s?bin/(iptables|ip6tables|systemctl|ss)" "$SCRIPT"'

# C1 — dry-run
newcase; fw
chk 'C1a sin argumentos: rc 0 y las 6 reglas exactas' '[ "$RC" = 0 ] && [ "$(sinc)" = "$(exp_rules "$N")" ]'
chk 'C1a ninguna llamada a iptables ni ip6tables' '! grep -qE "^(iptables|ip6tables) " "$ST/calls.log"'
chk 'C1c el aviso de Incus sale siempre' 'grep -q "^# AVISO.*Incus" "$ST/out"'
newcase; ENVX+=(CORTAFUEGOS_SUPABASE=no); printf 'LISTEN 0 128 0.0.0.0:3389 0.0.0.0:*\n' >> "$ST/ss.out"; fw --dry-run
chk 'C1b --dry-run funciona con la clave en no y con RDP, y avisa de que apply se negaría' \
  '[ "$RC" = 0 ] && [ "$(sinc)" = "$(exp_rules "$N")" ] && grep -q "^# apply: se negaría" "$ST/out"'
newcase; fw apply extra
chk 'C1d argumentos de más: uso, rc 2, cero cambios' 'negado 2'
newcase; fw borra
chk 'C1d modo desconocido: rc 2' '[ "$RC" = 2 ]'

# Redes de docker: obligatorias, sin valor por defecto
newcase; ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf" "CORTAFUEGOS_SUPABASE=si"); fw
chk 'R1 sin la clave: dry-run rc 0, 6 reglas con el marcador y la explicación' \
  '[ "$RC" = 0 ] && [ "$(sinc)" = "$(exp_rules "<REDES_DOCKER>")" ] && grep -q "^# FALTA CORTAFUEGOS_REDES_DOCKER.*docker network inspect" "$ST/out"'
fw apply
chk 'R2 sin la clave: apply rc 3, cero cambios y explica docker network ls y default-address-pools' \
  'negado 3 && grep -q "docker network ls" "$ST/err" && grep -q "default-address-pools" "$ST/err"'
newcase; ENVX+=(CORTAFUEGOS_REDES_DOCKER=); fw apply
chk 'R3 clave vacía = ausente: apply rc 3, cero cambios' 'negado 3'
for v in 0.0.0.0/0 "$N,198.51.100.0/24" basura 192.0.2.0/33 192.0.2.300/24 192.0.2.0/7 00.0.0.0/8 192.0.2.0/024 192.0.2.00/24 192.00.2.0/24; do
  newcase; ENVX+=("CORTAFUEGOS_REDES_DOCKER=$v"); fw apply; r1=$RC; c1=$(cambios); fw
  chk "C6c redes inválidas '$v' (también con ceros a la izquierda, octales en iptables): apply y dry-run rc 3, cero cambios" '[ "$r1" = 3 ] && [ "$c1" = 0 ] && [ "$RC" = 3 ]'
done
newcase; ENVX+=(CORTAFUEGOS_REDES_DOCKER=203.0.113.0/24); fw
chk 'R4 con otro CIDR válido (un 0 a secas vale como octeto) las 6 reglas exactas llevan ese CIDR' '[ "$RC" = 0 ] && [ "$(sinc)" = "$(exp_rules 203.0.113.0/24)" ]'

# C2 — apply, idempotencia y orden en DOCKER-USER
newcase; fw apply
chk 'C2a apply: rc 0, 4 reglas v4 y 2 v6, y los dobles fueron los que se ejecutaron' \
  '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ] && [ "$(nreg ip6tables)" = 2 ] && grep -q "^iptables " "$ST/calls.log" && grep -q "^ip6tables " "$ST/calls.log" && grep -q "^ss " "$ST/calls.log" && grep -q "^systemctl " "$ST/calls.log" && grep -q "^hostname" "$ST/calls.log"'
chk 'C2a en DOCKER-USER el RETURN queda antes que el DROP' '[ "$(du_lineas | head -1)" = "filter|DOCKER-USER|$RS" ] && [ "$(du_lineas | tail -1)" = "filter|DOCKER-USER|$DS" ]'
: > "$ST/calls.log"; fw apply
chk 'C2b segundo apply: rc 0, sigue habiendo 6 reglas y ninguna inserción' \
  '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ] && [ "$(nreg ip6tables)" = 2 ] && [ "$(cambios)" = 0 ]'
newcase; : > "$ST/ip6tables.chains"; fw apply
chk 'C2c cadena ausente: se crea con -N y luego se inserta' \
  '[ "$RC" = 0 ] && grep -q "^ip6tables -w 5 -t filter -N DOCKER-USER" "$ST/calls.log" && [ "$(nreg ip6tables)" = 2 ]'
newcase; printf '*' > "$ST/iptables.fail-ins"; fw apply
chk 'C2d fallan todas las inserciones: rc 1 y el mensaje cita remove' '[ "$RC" = 1 ] && grep -q "remove" "$ST/err"'
newcase; printf 'filter|DOCKER-USER|%s\n' "$RS" > "$ST/iptables.rules"; fw apply
chk 'm1 DOCKER-USER con solo el RETURN: el DROP entra detrás (RETURN → DROP), rc 0' \
  '[ "$RC" = 0 ] && [ "$(du_lineas | head -1)" = "filter|DOCKER-USER|$RS" ] && [ "$(du_lineas | tail -1)" = "filter|DOCKER-USER|$DS" ]'
newcase; printf 'filter|DOCKER-USER|%s\n' "$DS" > "$ST/iptables.rules"; fw apply
chk 'm1 DOCKER-USER con solo el DROP: el RETURN entra delante, rc 0' '[ "$RC" = 0 ] && [ "$(du_lineas | head -1)" = "filter|DOCKER-USER|$RS" ]'
newcase; printf 'RETURN' > "$ST/iptables.fail-ins"; fw apply
chk 'm1 falla solo el -I del RETURN: rc 1 y NUNCA queda un DROP sin su RETURN en DOCKER-USER' '[ "$RC" = 1 ] && ! du_lineas | grep -q -- "-j DROP"'
newcase; printf -- '-j DROP' > "$ST/iptables.fail-ins"; fw apply
chk 'm1 falla solo el -I del DROP: rc 1 y queda solo el RETURN' '[ "$RC" = 1 ] && du_lineas | grep -q -- "-j RETURN" && ! du_lineas | grep -q -- "-j DROP"'
newcase; printf 'filter|DOCKER-USER|%s\nfilter|DOCKER-USER|%s\n' "$DS" "$RS" > "$ST/iptables.rules"; fw apply
chk 'm1 orden previo DROP → RETURN: apply lo detecta, rc 1 y avisa' '[ "$RC" = 1 ] && grep -q "DROP queda antes que el RETURN" "$ST/err"'
newcase; on iptables.fail-c; fw apply
chk 'M-C un -C no medido durante apply: rc ≠ 0 y nada se inserta a ciegas' '[ "$RC" != 0 ] && [ "$(nreg iptables)" = 0 ]'

# C3 — RDP
for ln in 'LISTEN 0 128 0.0.0.0:3389 0.0.0.0:*' 'LISTEN 0 128 [::]:3389 [::]:*' 'LISTEN 0 128 *:3389 *:*' 'LISTEN 0 128 127.0.0.1:3389 0.0.0.0:*' 'LISTEN 0 128 [::1]:3389 [::]:*' 'LISTEN 0 128 [fe80::1%lo]:3389 [::]:*' 'LISTEN 0 128 192.0.2.5%eth0:3389 0.0.0.0:*'; do
  newcase; printf '%s\n' "$ln" >> "$ST/ss.out"; fw apply
  chk "C3a/b oyente en el puerto de RDP ($ln): rc 3, cero cambios" 'negado 3 && grep -q "RDP" "$ST/err"'
done
for ln in 'LISTEN 0 128 0.0.0.0:33890 0.0.0.0:*' 'LISTEN 0 128 0.0.0.0:13389 0.0.0.0:*'; do
  newcase; printf '%s\n' "$ln" >> "$ST/ss.out"; fw apply
  chk "C3a un oyente que NO es de RDP ($ln) no niega: rc 0" '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ]'
done
for u in system.gnome-remote-desktop system.xrdp user.gnome-remote-desktop; do
  newcase; printf active > "$ST/systemctl.$u"; fw apply
  chk "C3c servicio activo ($u): rc 3, cero cambios" 'negado 3'
done
newcase; printf activating > "$ST/systemctl.system.xrdp"; fw apply
chk 'C3d servicio activating: rc 3, cero cambios' 'negado 3'
newcase; quita ss; fw apply; pon ss
chk 'C3d ss ausente: rc 4, cero cambios' 'negado 4'
newcase; printf 1 > "$ST/ss.rc"; fw apply
chk 'C3d ss con rc 1: rc 4, cero cambios' 'negado 4'
newcase; on ss.empty; fw apply
chk 'C3d ss con salida vacía: rc 4, cero cambios' 'negado 4'
newcase; quita systemctl; fw apply; pon systemctl
chk 'C3d systemctl ausente: rc 4, cero cambios' 'negado 4'
newcase; on systemctl.system.fail; fw apply
chk 'C3d systemctl falla en el ámbito sistema: rc 4, cero cambios' 'negado 4'
newcase; quita ip6tables; fw apply; pon ip6tables
chk 'C3g ip6tables ausente con iptables presente: rc 4 y CERO cambios (ni el v4)' 'negado 4'
newcase; on systemctl.user.fail; fw apply
chk 'C3e systemctl --user sin bus no bloquea: rc 0' '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ]'
newcase; fw apply; printf 'LISTEN 0 128 0.0.0.0:3389 0.0.0.0:*\n' >> "$ST/ss.out"; fw status; rs=$RC; fw remove
chk 'C3f con RDP presente, status y remove no se bloquean' '[ "$rs" = 0 ] && [ "$RC" = 0 ] && [ "$(nreg iptables)" = 0 ]'

# C4 — hosts excluidos
printf 'Alfa.Red.Example\n' > "$WORK/h"
for lst in alfa alfa.red.example 'beta, ALFA' 'beta gamma alfa' 'beta,alfa.red.example'; do
  newcase; cp "$WORK/h" "$ST/hostname"; ENVX+=("CORTAFUEGOS_HOSTS_EXCLUIDOS=$lst"); fw apply
  chk "C4a host excluido (lista '$lst'): rc 3, cero cambios" 'negado 3 && grep -q "EXCLUIDOS" "$ST/err"'
done
newcase; ENVX+=("CORTAFUEGOS_HOSTS_EXCLUIDOS=alf,fa,red,alfa2,beta,red.example"); fw apply
chk 'C4b sin coincidencias parciales: apply rc 0' '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ]'
newcase; on hostname.fail; fw apply
chk 'C4c hostname falla: rc 4, cero cambios' 'negado 4'
newcase; : > "$ST/hostname"; fw apply
chk 'C4c hostname vacío: rc 4, cero cambios' 'negado 4'

# C5 — clave de activación y fichero de configuración
newcase; ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf" "CORTAFUEGOS_REDES_DOCKER=$N"); fw apply
chk 'C5a sin la clave (defecto): rc 3, cero cambios y explica cómo activarlo' 'negado 3 && grep -q "CORTAFUEGOS_SUPABASE=si" "$ST/err"'
for v in no basura ''; do
  newcase; ENVX+=("CORTAFUEGOS_SUPABASE=$v"); fw apply
  chk "C5b clave '$v': rc 3, cero cambios" 'negado 3'
done
newcase; conf "# perfil\nCORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\nCORTAFUEGOS_HOSTS_EXCLUIDOS=beta\n"; fw apply
chk 'C5c la clave por fichero: rc 0' '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ]'
newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n"; ENVX+=(CORTAFUEGOS_SUPABASE=no); fw apply
chk 'C5c el entorno gana al fichero' 'negado 3'
for fila in 'CORTAFUEGOS_SUPABASE=si\nOTRA=1\n' 'CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_OTRA=1\n' 'CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_SUPABASE=no\n' 'CORTAFUEGOS_SUPABASE=$(id)\n' 'CORTAFUEGOS_SUPABASE=si;x\n'; do
  newcase; conf "$fila"; fw apply
  chk "C5d fichero inválido ($fila): rc 4, cero cambios" 'negado 4'
done
for m in 660 664 646 622; do
  newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n" "$m"; fw apply
  chk "C5d fichero con modo $m (escribible por grupo u otros): rc 4, cero cambios" 'negado 4'
done
# Nota (mutante H de la revisión): la rama del enlace simbólico es redundante con la del modo, porque stat -c %a
# sobre un enlace da el modo del propio enlace (777) y ya se rechaza como «escribible»; aquí solo se exige el rc 4.
newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n"; ln -s "$ST/f.conf" "$ST/enlace.conf"; ENVX=("CORTAFUEGOS_CONF=$ST/enlace.conf"); fw apply
chk 'C5d el fichero como enlace simbólico: rc 4, cero cambios' 'negado 4'
newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n"; printf 0 > "$ST/uid"; printf 1000 > "$ST/stat.owner"; fw apply
chk 'C5d corre como root y el fichero no es de root: rc 4, cero cambios' 'negado 4 && grep -q "no es de root" "$ST/err"'
newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n"; printf 0 > "$ST/uid"; printf 0 > "$ST/stat.owner"; fw apply
chk 'C5d corre como root y el fichero es de root: rc 0' '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ]'
newcase; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n"; on id.fail; fw apply
chk 'C5d id -u falla: rc 4, cero cambios (no se supone ningún usuario)' 'negado 4 && grep -q "id -u" "$ST/err"'

# C6 — nunca RDP ni política, solo reglas acotadas, números decimales sin ceros a la izquierda
for pt in 3389 3380:3400 54421:54424,3389 0:65535 22 54424:54421 54421:54500 abc 06475 06475:06475 0054421 054421:054424 54421:054424.0; do
  newcase; ENVX+=("CORTAFUEGOS_PUERTOS=$pt"); fw apply; r1=$RC; c1=$(cambios); fw
  chk "C6b puertos '$pt': apply y dry-run rc 3, cero cambios" '[ "$r1" = 3 ] && [ "$c1" = 0 ] && [ "$RC" = 3 ]'
done
newcase; ENVX+=(CORTAFUEGOS_PUERTOS=60000); fw
chk 'C6b un puerto único válido se acepta' '[ "$RC" = 0 ] && sinc | grep -q -- "--dports 60000 "'
newcase; ENVX+=(CORTAFUEGOS_PUERTOS=54421:54421); fw
chk 'C6b N:N se emite normalizado como N' '[ "$RC" = 0 ] && [ "$(sinc)" = "$(exp_rules "$N" 54421)" ]'
newcase; : > "$WORK/todo.log"; fw; fw apply; fw status; fw remove; ENVX+=(CORTAFUEGOS_SUPABASE=no); fw apply
re1="(--dports|--ctorigdstport) $P "; re2='-j (DROP|RETURN)$'; acotadas=1; nlin=0
while IFS= read -r l; do
  nlin=$((nlin + 1))
  [[ $l == *"-p tcp"* && $l =~ $re1 && $l == *"--comment $T "* && $l =~ $re2 ]] || acotadas=0
done < <(grep -hE -- ' -I |^(iptables|ip6tables) (raw|filter) ' "$WORK/todo.log")
chk 'C6a toda inserción e impresión de regla está acotada: tcp, el rango declarado, la marca y solo DROP o RETURN' '[ "$acotadas" = 1 ] && [ "$nlin" -ge 12 ]'
sed "s|$WORK||g" "$WORK/todo.log" > "$WORK/todo.sinruta"   # sin la ruta temporal, que puede traer «3389»; a fichero, sin tubería (pipefail)
chk 'C6a en ningún modo aparece el puerto de RDP, una política ni PROHIBIDA' \
  '[ -s "$WORK/todo.sinruta" ] && ! grep -qE "3389|PROHIBIDA| -[PFXZR]( |$)" "$WORK/todo.sinruta"'
newcase; env -i PATH="$BIN" FW_STATE="$ST" iptables -w -t filter -P INPUT DROP; rc6=$?
chk 'C6d el doble rechaza y anota cualquier -P (el control de C6a no es ciego)' '[ "$rc6" = 99 ] && grep -q PROHIBIDA "$ST/calls.log"'

# C7 y M2 — status y remove: descubren lo propio, sin depender de la configuración
newcase; fw apply; printf 'filter|INPUT|-p tcp --dport 80 -m comment --comment otra -j ACCEPT\n' >> "$ST/iptables.rules"; : > "$ST/calls.log"; fw status
chk 'C7c status lista las 6 reglas con la marca y no cambia nada' \
  '[ "$RC" = 0 ] && [ "$(grep -c -- "--comment $T" "$ST/out")" = 6 ] && [ "$(cambios)" = 0 ]'
fw remove; r1=$RC; fw remove
chk 'C7a/b remove: 0 reglas con la marca, la ajena intacta, y es idempotente' \
  '[ "$r1" = 0 ] && [ "$RC" = 0 ] && [ "$(marca)" = 0 ] && grep -q "otra" "$ST/iptables.rules"'
fw status
chk 'C7c status sin reglas lo dice' '[ "$RC" = 0 ] && grep -q "(sin reglas $T)" "$ST/out"'
newcase; fw apply; on iptables.noperm; on ip6tables.noperm; fw status; rs=$RC; cp "$ST/out" "$ST/status.out"; fw remove
chk 'C7d/e sin privilegios status y remove dan rc 4 (no medido), no un falso vacío' \
  '[ "$rs" = 4 ] && grep -q "no medido" "$ST/status.out" && [ "$RC" = 4 ]'
newcase; fw apply; ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf" CORTAFUEGOS_SUPABASE=si CORTAFUEGOS_REDES_DOCKER=203.0.113.0/24); fw apply; c7=$(nreg iptables)
fw remove
chk 'M2 remove tras cambiar el CIDR (el apply nuevo se SUMA: 7 reglas v4): 0 reglas con la marca, rc 0' '[ "$c7" = 7 ] && [ "$RC" = 0 ] && [ "$(marca)" = 0 ]'
newcase; fw apply; ENVX+=(CORTAFUEGOS_PUERTOS=54430:54433); fw remove
chk 'M2 remove tras cambiar los puertos: 0 reglas con la marca, rc 0' '[ "$RC" = 0 ] && [ "$(marca)" = 0 ]'
newcase; fw apply; ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf"); fw remove
chk 'M2 remove SIN la clave de redes: 0 reglas con la marca, rc 0, y ninguna llamada menciona el marcador' '[ "$RC" = 0 ] && [ "$(marca)" = 0 ] && ! grep -q "REDES_DOCKER" "$ST/calls.log"'
ENVX=("CORTAFUEGOS_CONF=$ST/nada.conf" CORTAFUEGOS_SUPABASE=si CORTAFUEGOS_REDES_DOCKER=203.0.113.0/24); fw apply
chk 'M2 apply con otro CIDR tras remove: solo las 6 nuevas' \
  '[ "$RC" = 0 ] && [ "$(nreg iptables)" = 4 ] && [ "$(nreg ip6tables)" = 2 ] && ! grep -q "192.0.2.0" "$ST/iptables.rules" && grep -q "203.0.113.0" "$ST/iptables.rules"'
newcase; fw apply; printf 'filter|INPUT|-p udp --dport 80 -m comment --comment %s -j ACCEPT\n' "$T" >> "$ST/iptables.rules"; fw remove
chk 'M2 regla con la marca y otra forma: no se toca, se lista en stderr y rc 1; las propias se quitan' \
  '[ "$RC" = 1 ] && grep -q "otra forma" "$ST/err" && [ "$(grep -c -- "-p udp" "$ST/iptables.rules")" = 1 ] && [ "$(nreg iptables)" = 1 ] && [ "$(nreg ip6tables)" = 0 ]'
newcase; fw apply; conf "CORTAFUEGOS_SUPABASE=si\nCORTAFUEGOS_REDES_DOCKER=$N\n" 666; fw remove; r1=$RC; fw status
chk 'm8 remove y status no dependen de cortafuegos.conf (aunque sea inseguro): rc 0' '[ "$r1" = 0 ] && [ "$RC" = 0 ] && [ "$(marca)" = 0 ]'
newcase; fw apply; printf '*' > "$ST/iptables.fail-del"; fw remove
chk 'M2 un -D que falla: rc 1, lo dice y lista las supervivientes' \
  '[ "$RC" = 1 ] && grep -q "no se pudo borrar" "$ST/err" && grep -q "quedan reglas con la marca" "$ST/err" && [ "$(nreg iptables)" = 4 ]'

# Issue 9680: orden de remove, criterio de «lo propio» (una regla ajena que incumple SOLO una condición), ramas
# sin caso, status con el criterio de remove, root en apply y -w con segundos.
M="-m comment --comment $T"
newcase; fw apply; printf -- '-j DROP' > "$ST/iptables.fail-del"; fw remove
chk '2a remove con el -D del DROP fallando: rc 1 y NUNCA un DROP sin su RETURN en DOCKER-USER (los dos intactos)' \
  '[ "$RC" = 1 ] && grep -q "no se pudo borrar" "$ST/err" && [ "$(du_lineas | grep -c -- "-j RETURN")" = 1 ] && [ "$(du_lineas | grep -c -- "-j DROP")" = 1 ]'
ajena() {  # <nombre> <rc esperado> <spec>
  local aj_rc=$2 aj_spec=$3
  newcase; fw apply; printf 'filter|INPUT|%s\n' "$aj_spec" >> "$ST/iptables.rules"; fw remove
  chk "2b $1: remove rc $aj_rc, la ajena queda y las 6 propias se quitan" '[ "$RC" = "$aj_rc" ] && grep -qxF "filter|INPUT|$aj_spec" "$ST/iptables.rules" && [ "$(nreg iptables)" = 1 ] && [ "$(nreg ip6tables)" = 0 ]'
}
ajena Ma-marca-exacta 0 "-p tcp -m multiport --dports $P $M-otro -j DROP"
ajena Mb-tcp 1 "-p udp -m multiport --dports $P $M -j DROP"
ajena Mc-accion 1 "-p tcp -m multiport --dports $P $M -j ACCEPT"
ajena Md-caracteres 1 "-p tcp -m multiport --dports $P ! -s 192.0.2.0/24,198.51.100.0/24 $M -j DROP"
ajena Mh-puerto 1 "-p tcp --dport 80 $M -j DROP"
ajena Mi-comentario 1 "-p tcp -m multiport --dports $P --comment $T -j DROP"
newcase; fw apply; printf 1 > "$ST/iptables.skip-del"; fw remove
chk '2b Me un -D que no borra la primera vez: las pasadas siguientes lo quitan (rc 0, 0 reglas)' '[ "$RC" = 0 ] && [ "$(marca)" = 0 ]'
newcase; fw apply; printf -- '-A FORWARD -p tcp -m multiport --dports %s %s -j DROP\n' "$P" "$M" > "$ST/iptables.extra-s"; fw remove
chk '2b Mf una línea del -S que no empieza por -A <cadena> no es propia: remove rc 0 y no la lista' '[ "$RC" = 0 ] && [ "$(marca)" = 0 ] && ! grep -q FORWARD "$ST/err"'
newcase; : > "$ST/iptables.chains"; on iptables.fail-n; fw apply
chk '2c Mu el -N falla: rc 1, UN solo -N de DOCKER-USER (la cadena queda marcada) y nada insertado en ella' \
  '[ "$RC" = 1 ] && [ "$(grep -c "^iptables -w 5 -t filter -N DOCKER-USER" "$ST/calls.log")" = 1 ] && [ -z "$(du_lineas)" ]'
newcase; fw apply; printf 4 > "$ST/iptables.fail-s"; fw apply   # reglas ya puestas: solo falla el -S FINAL
chk '2c Mt el -S final de DOCKER-USER no se mide: apply rc 1 y lo dice' '[ "$RC" = 1 ] && grep -q "no se pudo comprobar el orden de DOCKER-USER" "$ST/err"'
newcase; fw apply; printf 'filter|INPUT|-p tcp -m multiport --dports %s %s-otro -j DROP\n' "$P" "$M" >> "$ST/iptables.rules"; fw status
chk 'n1 status usa el criterio de remove: lista las 6 propias y NO la ajena con la marca como prefijo' \
  '[ "$RC" = 0 ] && [ "$(grep -c -- "--comment $T " "$ST/out")" = 6 ] && ! grep -q otro "$ST/out"'
newcase; printf 'filter|DOCKER-USER|-j FOO\nfilter|DOCKER-USER|%s\n' "$RS" > "$ST/iptables.rules"; fw apply
chk 'n3 DOCKER-USER = [FOO, RETURN propio]: el DROP entra DETRÁS del RETURN (FOO, RETURN, DROP), rc 0' \
  '[ "$RC" = 0 ] && [ "$(du_lineas | sed -n 2p)" = "filter|DOCKER-USER|$RS" ] && [ "$(du_lineas | sed -n 3p)" = "filter|DOCKER-USER|$DS" ]'
newcase; printf 'filter|DOCKER-USER|-j FOO\nfilter|DOCKER-USER|%s\n' "$RS" > "$ST/iptables.rules"; printf 4 > "$ST/iptables.fail-s"; fw apply
chk 'H1 el -S auxiliar falla con DOCKER-USER = [FOO, RETURN propio]: rc 1 y NINGÚN DROP en DOCKER-USER' '[ "$RC" = 1 ] && ! du_lineas | grep -q -- "-j DROP"'
newcase; fw apply; printf 1 > "$ST/iptables.fail-s"; fw remove; r1=$RC; fw status
chk 'n4 un rc 1 de -S SIN «No chain/target/match by that name» no es cadena ausente: remove y status dan rc 4' \
  '[ "$r1" = 4 ] && [ "$RC" = 4 ] && grep -q "no medido" "$ST/out"'
newcase; printf 1000 > "$ST/uid"; fw apply
chk 'n5 apply sin root: rc 4 y cero cambios' 'negado 4 && grep -q "exige root" "$ST/err"'
newcase; fw apply; printf 1000 > "$ST/uid"; fw --dry-run; rd=$RC; fw status; rs=$RC; fw remove
chk 'n5 con uid distinto de 0, dry-run, status y remove siguen funcionando (no exigen root)' '[ "$rd" = 0 ] && [ "$rs" = 0 ] && [ "$RC" = 0 ] && [ "$(marca)" = 0 ]'
newcase; fw apply; fw status; fw remove
chk 'NIT toda llamada a iptables/ip6tables lleva -w con segundos (espera acotada al candado)' \
  '[ "$(grep -cE "^ip6?tables " "$ST/calls.log")" -gt 20 ] && ! grep -E "^ip6?tables " "$ST/calls.log" | grep -qvE "^ip6?tables -w [0-9]+ -t "'

printf 'RESULTADO cortafuegos PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
