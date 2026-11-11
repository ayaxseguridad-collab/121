#!/usr/bin/env bash
# Doble multinombre para la prueba de node-al-dia.sh: se copia como incus, apt-get, apt-cache, dpkg-query, node, su,
# stat, systemctl, id, find y getent en un directorio que es el ÚNICO PATH de la prueba. Todo su estado vive en $NAD_STATE y
# cada llamada se anota en $NAD_STATE/calls.log con el formato  binario|sujeto|argumentos  (las de apt-get llevan además
# el entorno relevante). El sujeto es el contenedor en el que corre la orden ($SUJETO, que `incus exec` fija) o «host».
#
# Estado por sujeto en $NAD_STATE/sujetos/<nombre>/ (los contenedores tienen fichero «energia»; el host no):
#   energia (RUNNING|STOPPED) · dpkg (versión de apt de nodejs, sin salto de línea; ausente = no instalado) ·
#   node_v (X.Y.Z que imprime node -v) · madison (salida de apt-cache madison) · candidato_tras_update (sustituye a
#   madison tras apt-get update) · aviso_update (texto que apt-get update imprime por stderr; es de NodeSource y sale
#   siempre) · update.fail (idem, rc 100) · aviso_update_ajeno y update_ajeno.fail (de OTRO repositorio: solo salen si
#   el update no se limitó con -o Dir::Etc::sourcelist=…) · status_grande (no vacío: `incus file pull` entrega un
#   dpkg/status de más de 300 KiB con nodejs en medio y muere por SIGPIPE si el lector deja de leer) ·
#   install.fail · node_v_tras_install (node -v tras instalar, en lugar del upstream) · stamp (época de la caché de apt) ·
#   deb_anterior (no vacío: find halla el .deb) · root/ (raíz sintética para la comprobación de la fuente) ·
#   proc/<pid>/{comm,cmdline,cwd} (/proc sintético) · proc_tras_start/ (se copia a proc/ al arrancar).
# Globales: uid (lo que imprime `id -u`), incus.fail-list, incus.fail-start. Un fichero NO VACÍO enciende el modo.
# apt-get install acepta SOLO nodejs=<versión> presente en madison y rechaza (rc 100) las opciones prohibidas.
# `incus exec <c> -- bash -c <texto>` ejecuta el texto REAL: en la guarda de sesiones cambia /proc por el árbol
# sintético del sujeto (y guarda el texto recibido en guarda-recibida-<c>); en la comprobación de fuente usa siempre root/ del sujeto.
# Para el host, la prueba fija NAD_RAIZ=<estado>/sujetos/host/root.
set -u
N="${0##*/}"; S="${NAD_STATE:?}"
SUJ="${SUJETO:-host}"; D="$S/sujetos/$SUJ"
log() { printf '%s|%s|%s\n' "$N" "$SUJ" "$*" >> "$S/calls.log"; }
fl() { [ -s "$S/$1" ]; }
sl() { [ -s "$D/$1" ]; }
case "$N" in
  incus)
    sub="${1:-}"
    case "$sub" in
      list)
        log "$*"
        ! fl incus.fail-list || exit 1
        modo="${5:-}"
        for d in "$S"/sujetos/*/; do
          n="${d%/}"; n="${n##*/}"
          [ "$n" != host ] || continue
          if [ "$modo" = ns ]; then printf '%s,%s\n' "$n" "$(cat "$d/energia")"; else printf '%s\n' "$n"; fi
        done ;;
      start)
        log "$*"
        ! fl incus.fail-start || exit 1
        n="${2:?}"
        printf RUNNING > "$S/sujetos/$n/energia"
        if [ -d "$S/sujetos/$n/proc_tras_start" ]; then
          mkdir -p "$S/sujetos/$n/proc"; cp -r "$S/sujetos/$n/proc_tras_start/." "$S/sujetos/$n/proc/"
        fi ;;
      stop)
        log "$*"
        printf STOPPED > "$S/sujetos/${2:?}/energia" ;;
      file)
        log "$*"
        [ "${2:-}" = pull ] || exit 2
        n="${3%%/*}"; p="${3#*/}"
        [ "$p" = var/lib/dpkg/status ] || exit 1
        printf 'Package: bash\nStatus: install ok installed\nVersion: 5.2\n\n'
        if [ -s "$S/sujetos/$n/status_grande" ]; then
          # dpkg/status GRANDE (mas de 300 KiB) con nodejs EN MEDIO y miles de estrofas detras: si el lector deja de leer al
          # hallar nodejs, este proceso muere por SIGPIPE (rc 141), como el `incus file pull` real.
          for ((i = 1; i <= 1500; i++)); do
            printf 'Package: relleno%s\nStatus: install ok installed\nVersion: 1.%s\nDescription: relleno de la prueba para pasar de 64 KiB\n\n' "$i" "$i"
          done
          if [ -s "$S/sujetos/$n/dpkg" ]; then
            printf 'Package: nodejs\nStatus: install ok installed\nVersion: %s\n\n' "$(cat "$S/sujetos/$n/dpkg")"
          fi
          for ((i = 1501; i <= 3000; i++)); do
            printf 'Package: relleno%s\nStatus: install ok installed\nVersion: 1.%s\nDescription: relleno de la prueba para pasar de 64 KiB\n\n' "$i" "$i"
          done
          exit 0
        fi
        if [ -s "$S/sujetos/$n/dpkg" ]; then
          printf 'Package: nodejs\nStatus: install ok installed\nVersion: %s\n\n' "$(cat "$S/sujetos/$n/dpkg")"
        fi ;;
      exec)
        c="${2:?}"; [ "${3:-}" = -- ] || exit 2
        shift 3
        [ "$(cat "$S/sujetos/$c/energia")" = RUNNING ] || { echo "Error: Instance is not running" >&2; exit 1; }
        if [ "${1:-}" = bash ] && [ "${2:-}" = -c ]; then
          txt="${3:-}"; arg="${5:-}"
          case "$txt" in
            *"sesiones_vivas /proc"*)
              log "exec $c bash -c <guarda de sesiones> $arg"
              printf '%s' "$txt" > "$S/guarda-recibida-$c"
              pre="${txt%sesiones_vivas /proc *}"
              SUJETO="$c" exec bash -c "${pre}sesiones_vivas $S/sujetos/$c/proc \"\$1\"" _ "$arg" ;;
            *NAD_FIRMA*)
              log "exec $c bash -c <comprobación de fuente> $arg"
              SUJETO="$c" exec bash -c "$txt" _ "$S/sujetos/$c/root" ;;
            *NAD_FUENTE*)
              log "exec $c bash -c <fuentes de NodeSource> $arg"
              SUJETO="$c" exec bash -c "$txt" _ "$S/sujetos/$c/root" ;;
          esac
        fi
        log "exec $c $*"
        SUJETO="$c" exec "$@" ;;
      *) log "$*"; exit 2 ;;
    esac ;;
  apt-get)
    printf 'apt-get|%s|DEBIAN_FRONTEND=%s|NEEDRESTART_MODE=%s|%s\n' "$SUJ" "${DEBIAN_FRONTEND:-}" "${NEEDRESTART_MODE:-}" "$*" >> "$S/calls.log"
    verbo=""
    for a in "$@"; do case "$a" in update|install) verbo="$a" ;; esac; done
    case "$verbo" in
      update)
        # aviso_update y update.fail son de la fuente de NodeSource: salen siempre. aviso_update_ajeno y update_ajeno.fail
        # son de OTRO repositorio: solo salen si el update NO se limitó a un fichero de fuentes (Dir::Etc::sourcelist=).
        acotado=0
        for a in "$@"; do case "$a" in Dir::Etc::sourcelist=*) acotado=1 ;; esac; done
        if [ "$acotado" = 0 ]; then
          ! sl aviso_update_ajeno || cat "$D/aviso_update_ajeno" >&2
          ! sl update_ajeno.fail || exit 100
        fi
        ! sl aviso_update || cat "$D/aviso_update" >&2
        ! sl update.fail || exit 100
        ! sl candidato_tras_update || cp "$D/candidato_tras_update" "$D/madison"
        exit 0 ;;
      install)
        ver=""
        for a in "$@"; do
          case "$a" in
            --allow-unauthenticated | --force-yes | *AllowUnauthenticated=true* | *trusted*) echo "E: opción prohibida: $a" >&2; exit 100 ;;
            nodejs=*) ver="${a#nodejs=}" ;;
          esac
        done
        { [ -n "$ver" ] && grep -qF " $ver " "$D/madison" 2>/dev/null; } || { echo "E: Version '$ver' for 'nodejs' was not found" >&2; exit 100; }
        ! sl install.fail || exit 100
        printf '%s' "$ver" > "$D/dpkg"
        if sl node_v_tras_install; then cp "$D/node_v_tras_install" "$D/node_v"; else printf '%s' "${ver%%-*}" > "$D/node_v"; fi
        exit 0 ;;
      *) exit 2 ;;
    esac ;;
  apt-cache)
    log "$*"
    [ "${1:-}" = madison ] || exit 2
    if [ -f "$D/madison" ]; then cat "$D/madison"; fi ;;
  dpkg-query)
    log "$*"
    sl dpkg || { echo "dpkg-query: no se han encontrado paquetes que casen con nodejs" >&2; exit 1; }
    cat "$D/dpkg" ;;
  node)
    log "$*"
    [ "${1:-}" = -v ] || exit 2
    sl node_v || exit 127
    printf 'v%s\n' "$(cat "$D/node_v")" ;;
  su)
    log "$*"
    exec sh -c "${4:?}" ;;
  stat)
    log "$*"
    sl stamp || exit 1
    cat "$D/stamp"; echo ;;
  getent)
    [ "${1:-}" = passwd ] || exit 2
    printf '%s:x:1000:1000:operador:%s:/bin/sh\n' "${2:-}" "${NAD_HOME:?}" ;;
  systemctl)
    echo running ;;
  id)
    if fl uid; then cat "$S/uid"; else echo 0; fi ;;
  find)
    log "$*"
    ! sl deb_anterior || echo /var/cache/apt/archives/nodejs_anterior.deb ;;
  *) echo "doble desconocido: $N" >&2; exit 2 ;;
esac
