#!/usr/bin/env bash
# Doble multinombre para la prueba de cortafuegos-supabase.sh: se copia como iptables, ip6tables, ss,
# systemctl, hostname, id y stat en un directorio que es el ÚNICO PATH de la prueba. Todo su estado vive
# en $FW_STATE; cada llamada se anota en $FW_STATE/calls.log. Los iptables aceptan SOLO -n -L, -N, -C,
# -I, -D y -S (con -w opcional, con o sin segundos); cualquier otra operación (política, vaciado, borrado de cadena…)
# devuelve 99 y anota PROHIBIDA. Modos de fallo: un fichero de estado NO VACÍO enciende el modo y uno vacío lo apaga (así la
# prueba reutiliza un solo directorio sin borrar nada): <binario>.noperm (rc 4), <binario>.fail-c (el -C
# da rc 4), <binario>.fail-del y <binario>.fail-ins (el -D / el -I da rc 1: «*» todos, otro texto solo los que lo
# contienen), <binario>.skip-del (N: los N primeros -D dan rc 0 sin borrar), <binario>.fail-n (el -N da rc 1),
# <binario>.fail-s (el -S da ese rc con otro texto que «cadena ausente»), <binario>.extra-s (líneas que -S
# imprime tras las reglas), ss.rc, ss.empty, hostname.fail, id.fail, systemctl.<ámbito>.fail; uid y
# stat.owner simulan ser root; systemctl.<ámbito>.<unidad> fija el estado de una unidad.
set -u
N="${0##*/}"; S="${FW_STATE:?}"
printf '%s %s\n' "$N" "$*" >> "$S/calls.log"
fl() { [ -s "$S/$1" ]; }
case "$N" in
  iptables | ip6tables)
    ! fl "$N.noperm" || { echo "Permission denied (you must be root)" >&2; exit 4; }
    if [ "${1:-}" = -w ]; then shift; case "${1:-}" in '' | *[!0-9]*) ;; *) shift ;; esac; fi   # -w acepta SOLO un número exacto
    [ "${1:-}" = -t ] || exit 2
    T="$2"; shift 2; op="${1:-}"; shift
    R="$S/$N.rules"; C="$S/$N.chains"; touch "$R" "$C"
    cadena_ok() { case "$1" in INPUT | FORWARD | OUTPUT | PREROUTING | POSTROUTING) return 0 ;; esac; grep -qxF "$T|$1" "$C"; }
    case "$op" in
      -n) cadena_ok "$2" ;;
      -N) ! fl "$N.fail-n" || exit 1
          echo "$T|$1" >> "$C" ;;
      -C) ! fl "$N.fail-c" || exit 4
          ch="$1"; shift; grep -qxF "$T|$ch|$*" "$R" ;;
      -I)
        ch="$1"; pos="$2"; shift 2
        if fl "$N.fail-ins"; then pat="$(cat "$S/$N.fail-ins")"; if [ "$pat" = '*' ] || [[ "$*" == *"$pat"* ]]; then exit 1; fi; fi
        # inserta antes de la n-ésima regla de esa cadena (o al final), sin tocar el resto
        p="$T|$ch|"; new="$p$*"; c=0; d=0; : > "$R.n"
        while IFS= read -r l || [ -n "$l" ]; do
          if [[ $l == "$p"* ]]; then c=$((c + 1)); if [ "$c" = "$pos" ] && [ "$d" = 0 ]; then echo "$new" >> "$R.n"; d=1; fi; fi
          echo "$l" >> "$R.n"
        done < "$R"
        [ "$d" = 1 ] || echo "$new" >> "$R.n"
        mv "$R.n" "$R" ;;
      -D)
        if fl "$N.fail-del"; then pat="$(cat "$S/$N.fail-del")"; if [ "$pat" = '*' ] || [[ "$*" == *"$pat"* ]]; then exit 1; fi; fi
        if fl "$N.skip-del"; then k="$(cat "$S/$N.skip-del")"; if [ "$k" -gt 0 ]; then echo $((k - 1)) > "$S/$N.skip-del"; exit 0; fi; fi
        ch="$1"; shift; x="$T|$ch|$*"; d=0; : > "$R.n"
        while IFS= read -r l || [ -n "$l" ]; do
          if [ "$l" = "$x" ] && [ "$d" = 0 ]; then d=1; continue; fi
          echo "$l" >> "$R.n"
        done < "$R"
        mv "$R.n" "$R" ;;
      -S)
        ! fl "$N.fail-s" || { echo "iptables: Resource temporarily unavailable." >&2; exit "$(cat "$S/$N.fail-s")"; }
        cadena_ok "$1" || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
        echo "-P $1 ACCEPT"; p="$T|$1|"
        while IFS= read -r l || [ -n "$l" ]; do [[ $l == "$p"* ]] && echo "-A $1 ${l#"$p"}"; done < "$R"
        ! fl "$N.extra-s" || cat "$S/$N.extra-s"
        exit 0 ;;
      *) echo PROHIBIDA >> "$S/calls.log"; exit 99 ;;
    esac ;;
  ss)
    ! fl ss.rc || exit "$(cat "$S/ss.rc")"
    ! fl ss.empty || exit 0
    echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
    cat "$S/ss.out" 2>/dev/null ;;
  systemctl)
    sc=system; [ "${1:-}" != --user ] || { sc=user; shift; }
    [ "${1:-}" = is-active ] || exit 2
    ! fl "systemctl.$sc.fail" || { echo "Failed to connect to bus" >&2; exit 1; }
    st=inactive; ! fl "systemctl.$sc.$2" || st="$(cat "$S/systemctl.$sc.$2")"
    echo "$st"; [ "$st" = active ] || exit 3 ;;
  hostname)
    ! fl hostname.fail || exit 1
    cat "$S/hostname" ;;
  id)
    ! fl id.fail || exit 1
    if fl uid; then cat "$S/uid"; else exec "${FW_REAL_ID:?}" "$@"; fi ;;
  stat)
    if fl stat.owner && [ "${2:-}" = %u ]; then cat "$S/stat.owner"; else exec "${FW_REAL_STAT:?}" "$@"; fi ;;
  *) echo "doble desconocido: $N" >&2; exit 2 ;;
esac
