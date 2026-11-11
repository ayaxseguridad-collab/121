#!/usr/bin/env bash
# cortafuegos-supabase.sh — cortafuegos OPCIONAL (desactivado por defecto) de los puertos que publica
# la pila local de Supabase de los gates. Docker los publica en todas las interfaces: quedan abiertos a
# la LAN y a la tailnet. Con Tailscale no basta DOCKER-USER (`ts-forward` acepta antes lo que entra por
# tailscale0), por eso hay además una regla en raw/PREROUTING, que se evalúa antes del DNAT.
#
# Uso: cortafuegos-supabase.sh [--dry-run|apply|remove|status]
#   (sin argumentos) | --dry-run  IMPRIME las reglas y no ejecuta iptables. Es el modo por defecto.
#   apply                         inserta las reglas (idempotente, -C antes de -I). Exige root y se NIEGA si:
#                                 CORTAFUEGOS_SUPABASE no es «si» (rc 3), el host está en
#                                 CORTAFUEGOS_HOSTS_EXCLUIDOS (rc 3), hay RDP (oyente en su puerto o
#                                 gnome-remote-desktop/xrdp activos, rc 3) o algo no se puede medir (rc 4).
#   remove                        DESCUBRE con -S las reglas propias (marca + forma de este script) y las quita,
#                                 aunque la configuración haya cambiado desde el apply. Una línea con la marca y
#                                 otra forma no se toca: se lista y rc 1. Nunca rc 0 con supervivientes. No lee
#                                 la configuración ni se bloquea por RDP. Para cambiar CIDR o puertos: remove y
#                                 luego apply (apply no sustituye reglas, las añade).
#   status                        lista las reglas con la marca (solo lectura, tampoco lee la configuración).
#
# Solo DROP y RETURN acotados a un rango de puertos TCP, nunca la política de ninguna cadena ni los
# puertos de RDP (se rechaza cualquier rango que los incluya). Fail-closed: si no se puede medir, no aplica.
# OJO: corta también a los contenedores de Incus (u otro origen) que no estén en las redes de docker
# permitidas y apunten a la IP del puente del host en esos puertos.
#
# Configuración: entorno > fichero > defecto. Fichero KEY=valor, leído SIN source ni eval, lista blanca
# de claves; por defecto /etc/talent-channels/cortafuegos.conf (CORTAFUEGOS_CONF lo cambia):
#   CORTAFUEGOS_SUPABASE=no|si           (defecto no)
#   CORTAFUEGOS_HOSTS_EXCLUIDOS=a,b      (nombres de host que nunca aplican)
#   CORTAFUEGOS_PUERTOS=54421:54424      (opcional, un puerto N o un rango N:M)
#   CORTAFUEGOS_REDES_DOCKER=<CIDR>      (OBLIGATORIA para apply, sin defecto: UN CIDR IPv4 que cubra los
#                                         puentes de docker del host; sin ella el dry-run imprime el marcador
#                                         <REDES_DOCKER> y apply se niega con rc 3)
# El fichero no puede ser escribible por grupo u otros, ni un enlace; si corre root, tiene que ser de root.
set -u
set -f   # sin expansión de globs en las listas
TAG="tc-supabase-fw"
RDP_PORT=3389
CONF="${CORTAFUEGOS_CONF:-/etc/talent-channels/cortafuegos.conf}"
MOTIVO=""

die() { echo "cortafuegos-supabase: $2" >&2; exit "$1"; }

cargar_conf() {
  [ -e "$CONF" ] || [ -L "$CONF" ] || return 0   # sin fichero: defectos
  [ -f "$CONF" ] && [ ! -L "$CONF" ] || die 4 "$CONF no es un fichero regular (no se admiten enlaces)"
  local modo uid dueno linea k v n=0
  local re='^(CORTAFUEGOS_(SUPABASE|HOSTS_EXCLUIDOS|PUERTOS|REDES_DOCKER))=([A-Za-z0-9._:/, -]*)$'
  modo=$(stat -c %a -- "$CONF" 2>/dev/null) || die 4 "no se pueden leer los permisos de $CONF"
  [[ $modo =~ ^[0-7]{3,4}$ ]] || die 4 "modo ilegible de $CONF"
  (( (8#$modo & 8#022) == 0 )) || die 4 "$CONF es escribible por grupo u otros (modo $modo)"
  uid=$(id -u 2>/dev/null) || die 4 "no se pudo determinar el usuario (id -u)"
  if [ "$uid" = 0 ]; then
    dueno=$(stat -c %u -- "$CONF" 2>/dev/null) || die 4 "no se puede leer el propietario de $CONF"
    [ "$dueno" = 0 ] || die 4 "corre como root y $CONF no es de root (propietario $dueno)"
  fi
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n + 1))
    case "$linea" in '' | \#*) continue ;; esac
    [[ $linea =~ $re ]] || die 4 "$CONF:$n: línea fuera de la lista blanca de claves o con caracteres no permitidos"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[3]}
    [[ -v "C_$k" ]] && die 4 "$CONF:$n: clave repetida $k"
    printf -v "C_$k" '%s' "$v"
  done < "$CONF"
}

resolver() {
  SUPA="${CORTAFUEGOS_SUPABASE-${C_CORTAFUEGOS_SUPABASE-no}}"
  HOSTS="${CORTAFUEGOS_HOSTS_EXCLUIDOS-${C_CORTAFUEGOS_HOSTS_EXCLUIDOS-}}"
  PORTS="${CORTAFUEGOS_PUERTOS-${C_CORTAFUEGOS_PUERTOS-54421:54424}}"
  NETS="${CORTAFUEGOS_REDES_DOCKER-${C_CORTAFUEGOS_REDES_DOCKER-}}"   # sin valor por defecto: la instancia lo declara
  NETS_OK=1; [ -n "$NETS" ] || { NETS_OK=0; NETS="<REDES_DOCKER>"; }
  [[ $HOSTS =~ ^[A-Za-z0-9._,\ -]*$ ]] || die 3 "CORTAFUEGOS_HOSTS_EXCLUIDOS tiene caracteres no permitidos"
  local lo hi o p oct='(0|[1-9][0-9]{0,2})'
  # Decimal puro, SIN ceros a la izquierda: iptables lee 06475 en octal (= el puerto de RDP).
  if [[ $PORTS =~ ^([1-9][0-9]{0,4})(:([1-9][0-9]{0,4}))?$ ]]; then
    lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[3]:-$lo}
  else die 3 "CORTAFUEGOS_PUERTOS='$PORTS' no es un puerto N ni un rango N:M (decimal, sin ceros a la izquierda)"; fi
  { [ "$lo" -ge 1024 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] && [ $((hi - lo)) -lt 64 ]; } \
    || die 3 "CORTAFUEGOS_PUERTOS='$PORTS' fuera de 1024-65535, invertido o de más de 64 puertos"
  { [ "$lo" -gt "$RDP_PORT" ] || [ "$hi" -lt "$RDP_PORT" ]; } \
    || die 3 "CORTAFUEGOS_PUERTOS='$PORTS' incluye el puerto de RDP ($RDP_PORT): se niega"
  PORTS=$lo; [ "$hi" = "$lo" ] || PORTS="$lo:$hi"   # se emite SIEMPRE la forma normalizada
  [ "$NETS_OK" = 1 ] || return 0
  if [[ $NETS =~ ^$oct\.$oct\.$oct\.$oct/([1-9][0-9]?)$ ]]; then   # sin ceros a la izquierda (octal en iptables)
    for o in 1 2 3 4; do [ "${BASH_REMATCH[o]}" -le 255 ] || die 3 "CORTAFUEGOS_REDES_DOCKER='$NETS' tiene un octeto inválido"; done
    p=${BASH_REMATCH[5]}
    { [ "$p" -ge 8 ] && [ "$p" -le 32 ]; } || die 3 "CORTAFUEGOS_REDES_DOCKER='$NETS': el prefijo debe estar entre 8 y 32"
  else die 3 "CORTAFUEGOS_REDES_DOCKER='$NETS' no es UN solo CIDR IPv4 decimal sin ceros a la izquierda"; fi
}

reglas() {  # <binario> <tabla> <cadena> <spec…>, en orden de evaluación dentro de cada cadena
  local c="-m comment --comment $TAG"
  echo "iptables raw PREROUTING -p tcp -m multiport --dports $PORTS ! -i lo ! -s $NETS $c -j DROP"
  echo "iptables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $PORTS -s $NETS $c -j RETURN"
  echo "iptables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $PORTS $c -j DROP"
  echo "iptables filter INPUT -p tcp -m multiport --dports $PORTS ! -i lo ! -s $NETS $c -j DROP"
  echo "ip6tables filter DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $PORTS $c -j DROP"
  echo "ip6tables filter INPUT -p tcp -m multiport --dports $PORTS ! -i lo $c -j DROP"
}

host_excluido() {  # 0 = excluido · 1 = no · 4 = no medido
  local h short e
  h=$(hostname 2>/dev/null) || h=""
  h="${h,,}"; h="${h//[[:space:]]/}"
  [ -n "$h" ] || { MOTIVO="no se pudo leer el nombre del host (hostname)"; return 4; }
  short="${h%%.*}"
  for e in ${HOSTS//,/ }; do
    e="${e,,}"
    if [ "$e" = "$h" ] || [ "$e" = "$short" ]; then MOTIVO="el host '$h' está en CORTAFUEGOS_HOSTS_EXCLUIDOS"; return 0; fi
  done
  return 1
}

detectar_rdp() {  # 0 = sin RDP · 3 = RDP detectado · 4 = no medido. Solo lectura, sin privilegios.
  local out st loc rest primera=1 u s rc
  out=$(ss -ltn 2>/dev/null) && [ -n "$out" ] || { MOTIVO="no se pudieron leer los puertos en escucha (ss)"; return 4; }
  while read -r st _ _ loc rest; do
    if [ "$primera" = 1 ]; then
      primera=0
      [ "$st" = State ] || { MOTIVO="salida de ss sin cabecera: no se puede comprobar RDP"; return 4; }
      continue
    fi
    if [ "$st" = LISTEN ] && [[ $loc == *:$RDP_PORT ]]; then MOTIVO="RDP detectado: algo escucha en el puerto $RDP_PORT"; return 3; fi
  done <<< "$out"
  for u in gnome-remote-desktop xrdp; do
    s=$(systemctl is-active "$u" 2>/dev/null); rc=$?
    case "$s" in
      active | activating | reloading | deactivating) MOTIVO="RDP detectado: $u está $s"; return 3 ;;
      inactive | failed | unknown) { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || { MOTIVO="no se pudo comprobar $u (systemctl rc=$rc)"; return 4; } ;;
      *) MOTIVO="no se pudo comprobar $u (systemctl rc=$rc, salida inesperada)"; return 4 ;;
    esac
  done
  # Complementario: el servicio habitual de GNOME es de usuario. Sin bus de sesión (root, unit) falla de
  # forma normal y se ignora: la señal autoritativa es el oyente de arriba.
  s=$(systemctl --user is-active gnome-remote-desktop 2>/dev/null)
  case "$s" in active | activating | reloading | deactivating) MOTIVO="RDP detectado: gnome-remote-desktop de usuario está $s"; return 3 ;; esac
  return 0
}

guardas() {  # 0 = apply permitido · 3 = negado · 4 = no medido (MOTIVO dice por qué)
  local rc
  if [ "$SUPA" != si ]; then
    MOTIVO="CORTAFUEGOS_SUPABASE vale '$SUPA', no 'si'. Para activarlo: CORTAFUEGOS_SUPABASE=si en $CONF (o exportado)"
    return 3
  fi
  if [ "$NETS_OK" != 1 ]; then
    MOTIVO="falta CORTAFUEGOS_REDES_DOCKER (sin valor por defecto). Léela del host: 'docker network ls' + 'docker network inspect <red>' (campo Subnet) y 'default-address-pools' de /etc/docker/daemon.json; ponla en $CONF como UN CIDR IPv4 que cubra todos los puentes"
    return 3
  fi
  host_excluido; rc=$?
  case "$rc" in 0) return 3 ;; 1) ;; *) return "$rc" ;; esac
  detectar_rdp; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if ! command -v iptables > /dev/null || ! command -v ip6tables > /dev/null; then MOTIVO="faltan iptables o ip6tables"; return 4; fi
  return 0
}

existe() { "$1" -w 5 -t "$2" -C "$3" "${@:4}" > /dev/null 2>&1; }   # 0 existe · 1 ausente · otro = no medido (-w 5: espera acotada al candado)

CADENAS=("iptables raw PREROUTING" "iptables filter DOCKER-USER" "iptables filter INPUT" "ip6tables filter DOCKER-USER" "ip6tables filter INPUT")

# La forma de una regla PROPIA de este script, sin depender del orden en que iptables imprime las opciones:
# TCP, un puerto o rango decimal, la marca y DROP/RETURN; solo caracteres de la lista (se pasa sin comillas a -D).
forma_propia() {
  local s=" $1 " cs='^[A-Za-z0-9 .:/!_-]+$' pt='(--dports|--ctorigdstport) [1-9][0-9]{0,4}(:[1-9][0-9]{0,4})? ' ac=' -j (DROP|RETURN) '
  [[ $1 =~ $cs ]] && [[ $s == *" -p tcp "* && $s == *" -m comment --comment $TAG "* ]] && [[ $s =~ $pt ]] && [[ $s =~ $ac ]]
}

# descubre <binario> <tabla> <cadena>: lee la cadena con -S y deja en OKS las specs propias (en orden de lista)
# y en MALAS las líneas con la marca que no cumplen la forma; IDX guarda el lugar (entre las líneas -A) de cada propia.
# rc 0 medido · 1 cadena ausente (solo si iptables lo dice) · otro = no medido.
descubre() {
  local out r l n=0
  OKS=(); IDX=(); MALAS=()
  out=$(LC_ALL=C "$1" -w 5 -t "$2" -S "$3" 2>&1); r=$?
  [ "$r" = 0 ] || { [ "$r" = 1 ] && [[ $out != *"No chain/target/match by that name"* ]] && r=4; return "$r"; }   # rc 1 con otro texto: no medido
  while IFS= read -r l; do
    [[ $l == "-A $3 "* ]] || continue
    n=$((n + 1))
    [[ $l =~ --comment\ \"?$TAG\"?($|\ ) ]] || continue
    if forma_propia "${l#"-A $3 "}"; then OKS+=("${l#"-A $3 "}"); IDX+=("$n"); else MALAS+=("$l"); fi
  done <<< "$out"
  return 0
}

apply() {
  local rc=0 i r d bin tbl chain spec k ret=-1 drop=-1 j at
  local -A pos=() mala=()
  guardas; rc=$?
  [ "$rc" = 0 ] || die "$rc" "apply NEGADO: $MOTIVO"
  [ "$(id -u 2>/dev/null)" = 0 ] || die 4 "apply NEGADO: exige root (o no se pudo medir el usuario)"
  mapfile -t R < <(reglas)
  for ((i = 0; i < ${#R[@]}; i++)); do   # en orden: en DOCKER-USER el RETURN entra primero y el DROP justo detrás
    read -r bin tbl chain spec <<< "${R[i]}"
    k="$bin/$tbl/$chain"; pos[$k]=$(( ${pos[$k]:-0} + 1 ))
    [ "${mala[$k]:-0}" = 0 ] || continue   # tras un fallo en la cadena no se añade nada más: nunca un DROP sin su RETURN
    "$bin" -w 5 -t "$tbl" -n -L "$chain" > /dev/null 2>&1 || "$bin" -w 5 -t "$tbl" -N "$chain" || { rc=1; mala[$k]=1; continue; }
    # shellcheck disable=SC2086
    existe "$bin" "$tbl" "$chain" $spec; r=$?
    at=${pos[$k]}
    if [ "$r" = 1 ] && [ "$k" = iptables/filter/DOCKER-USER ] && [[ $spec == *" -j DROP" ]]; then   # el DROP va detrás de NUESTRO RETURN aunque haya reglas ajenas delante
      at=0; descubre "$bin" "$tbl" "$chain" && for j in "${!OKS[@]}"; do [[ ${OKS[j]} == *" -j RETURN" ]] && { at=$((IDX[j] + 1)); break; }; done
      [ "$at" -gt 0 ] || { rc=1; mala[$k]=1; continue; }   # sin medir o sin RETURN propio: el DROP NO se inserta a ciegas
    fi
    # shellcheck disable=SC2086
    if [ "$r" = 1 ]; then "$bin" -w 5 -t "$tbl" -I "$chain" "$at" $spec || { rc=1; mala[$k]=1; }; elif [ "$r" != 0 ]; then rc=1; mala[$k]=1; fi
  done
  descubre iptables filter DOCKER-USER; d=$?   # comprobación final del orden RETURN → DROP
  if [ "$d" = 0 ]; then
    for j in "${!OKS[@]}"; do
      case "${OKS[j]}" in *" -j RETURN") [ "$ret" -ge 0 ] || ret=$j ;; *" -j DROP") [ "$drop" -ge 0 ] || drop=$j ;; esac
    done
    if [ "$drop" -ge 0 ] && { [ "$ret" -lt 0 ] || [ "$ret" -gt "$drop" ]; }; then
      echo "cortafuegos-supabase: en DOCKER-USER el DROP queda antes que el RETURN (o sin él): las redes de docker perderían el acceso. Ejecuta 'remove' y vuelve a 'apply'" >&2; rc=1
    fi
  else echo "cortafuegos-supabase: no se pudo comprobar el orden de DOCKER-USER (rc $d)" >&2; rc=1; fi
  [ "$rc" = 0 ] || echo "cortafuegos-supabase: apply incompleto; revisa con 'status' o deshaz con 'remove'" >&2
  return "$rc"
}

# remove DESCUBRE lo propio con -S (no reconstruye las reglas desde la configuración): quita lo que hay aunque
# la configuración haya cambiado. Una línea con la marca y otra forma no se toca: se lista y rc 1. Nunca rc 0
# con supervivientes. No lee cortafuegos.conf.
remove() {
  local rc=0 nomedido=0 tc bin tbl chain d spec l j
  for tc in "${CADENAS[@]}"; do
    read -r bin tbl chain <<< "$tc"
    command -v "$bin" > /dev/null || { echo "cortafuegos-supabase: falta $bin: no se pueden quitar sus reglas" >&2; nomedido=1; continue; }
    for _ in 1 2 3 4; do   # varias pasadas: cubre reglas duplicadas
      descubre "$bin" "$tbl" "$chain"; d=$?
      { [ "$d" = 0 ] && [ "${#OKS[@]}" -gt 0 ]; } || break
      for ((j = ${#OKS[@]} - 1; j >= 0; j--)); do   # al revés: en DOCKER-USER el DROP sale ANTES que el RETURN
        spec=${OKS[j]}
        # shellcheck disable=SC2086
        "$bin" -w 5 -t "$tbl" -D "$chain" $spec || { echo "cortafuegos-supabase: no se pudo borrar en $bin $tbl/$chain: $spec" >&2; rc=1; break; }   # sin seguir: nunca un DROP sin su RETURN
      done
    done
    descubre "$bin" "$tbl" "$chain"; d=$?   # recuento final
    case "$d" in 0) ;; 1) continue ;; *) nomedido=1; continue ;; esac
    if [ $(( ${#OKS[@]} + ${#MALAS[@]} )) -gt 0 ]; then
      echo "cortafuegos-supabase: quedan reglas con la marca $TAG en $bin $tbl/$chain:" >&2
      for l in "${OKS[@]+"${OKS[@]}"}"; do echo "  -A $chain $l" >&2; done
      for l in "${MALAS[@]+"${MALAS[@]}"}"; do echo "  $l (otra forma: no se toca)" >&2; done
      rc=1
    fi
  done
  [ "$nomedido" = 0 ] || return 4
  return "$rc"
}

status() {
  local rc=0 tc bin tbl chain r l n
  for tc in "${CADENAS[@]}"; do
    read -r bin tbl chain <<< "$tc"
    echo "== $bin $tbl/$chain"
    descubre "$bin" "$tbl" "$chain"; r=$?   # el mismo criterio que remove
    if [ "$r" = 1 ]; then echo "(sin reglas $TAG: cadena ausente)"; continue; fi
    if [ "$r" != 0 ]; then echo "(no medido: $bin rc=$r)"; rc=4; continue; fi
    n=0
    for l in "${OKS[@]+"${OKS[@]}"}"; do echo "-A $chain $l"; n=1; done
    for l in "${MALAS[@]+"${MALAS[@]}"}"; do echo "$l (otra forma)"; n=1; done
    [ "$n" = 1 ] || echo "(sin reglas $TAG)"
  done
  return "$rc"
}

dry_run() {
  local rc
  echo "# cortafuegos-supabase --dry-run: reglas que apply insertaría; no se ha ejecutado iptables"
  echo "# puertos $PORTS · redes de docker permitidas $NETS · marca $TAG"
  reglas
  [ "$NETS_OK" = 1 ] || echo "# FALTA CORTAFUEGOS_REDES_DOCKER: fíjala en $CONF con UN CIDR que cubra los puentes de docker ('docker network ls', 'docker network inspect', 'default-address-pools' de daemon.json); sin ella apply se niega"
  echo "# AVISO: también se cortan los contenedores de Incus (u otro origen) fuera de las redes de docker permitidas que apunten a la IP del puente del host en esos puertos."
  guardas; rc=$?
  if [ "$rc" = 0 ]; then echo "# apply: permitido"; else echo "# apply: se negaría (rc $rc): $MOTIVO"; fi
}

modo="${1:-}"
case "$modo" in
  '' | --dry-run | apply | remove | status) [ $# -le 1 ] || modo=uso ;;
  *) modo=uso ;;
esac
[ "$modo" != uso ] || { echo "uso: ${0##*/} [--dry-run|apply|remove|status]" >&2; exit 2; }
case "$modo" in '' | --dry-run | apply) cargar_conf; resolver ;; esac   # remove y status no dependen de la configuración
case "$modo" in
  '' | --dry-run) dry_run ;;
  apply) apply ;;
  remove) remove ;;
  status) status ;;
esac
