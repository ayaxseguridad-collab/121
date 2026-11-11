#!/usr/bin/env bash
# vigia-recursos.sh — UN tick: inodos, disco y topes de carpeta de la máquina local (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. Un vigía es un tick que sale con rc 0; el bucle vive en
# `vigias.sh`. Contrato común y razones en `lib-vigias.sh`.
#
# Uso:
#   vigia-recursos.sh --modo inodos [--ruta R] [--umbral 85]
#   vigia-recursos.sh --modo disco  [--ruta R] [--umbral N]...          (por defecto 90, 95 y 97)
#   vigia-recursos.sh --modo carpeta [--carpeta RUTA[=GB]]... [--timeout-du 900]
#   vigia-recursos.sh --help
#
# Entorno: TA_BUS_STATE_DIR.
#
# Salida:
#   INODOS <ruta> al <n> % (umbral <u> %)
#   DISCO <ruta> al <n> % (<g> GB libres) umbral <u> %
#   CARPETA <ruta> = <n> GB > tope <m> GB
#   …-NO-MEDIDO <ruta> …            la medida falló (df/du sin respuesta, sin salida legible o tiempo agotado)
#   CARPETA-SIN-TOPE …              carpeta sin tope declarado, o ninguna carpeta declarada (una vez)
#
# rc: 0 = tick hecho · 2 = PRECONDICIÓN (modo, umbral o carpeta mal formados) o la emisión de un
#     evento falló.
#
# ── POR TRANSICIÓN, CON UMBRALES MÚLTIPLES ─────────────────────────────────────────────────────
# Cada umbral es su propia transición: avisa al CRUZARLO hacia arriba, calla mientras siga arriba y
# el descenso no avisa. Si en un tick se cruzan varios umbrales, sale UNA línea con el más alto. Sin
# estado previo se parte de «bajo»: un recurso que ya está en rojo avisa en el primer tick.
#
# ── LOS TOPES SON DATO, NUNCA CÓDIGO ───────────────────────────────────────────────────────────
# Qué carpetas vigilar y cuántos GB se declara con `--carpeta RUTA=GB` (el último «=» separa). El
# paquete no trae ninguna ruta ni ningún tope. `du` se mide con `timeout` (--timeout-du, 900 s): si
# se agota, o falla sin haber visto ya más que el tope, es `CARPETA-NO-MEDIDO` y NUNCA calma. Una
# suma parcial que ya supera el tope sí avisa: es una cota inferior y basta.
# No mide carpetas ni inodos de máquinas remotas.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vigias.sh"

modo=''; ruta=''; umbrales=(); carpetas=(); tdu=900
while [ $# -gt 0 ]; do
  case "$1" in
    --modo)       _exige_valor $# "$1"; modo="${2-}";           shift 2 ;;
    --ruta)       _exige_valor $# "$1"; ruta="${2-}";           shift 2 ;;
    --umbral)     _exige_valor $# "$1"; umbrales+=("${2-}");    shift 2 ;;
    --carpeta)    _exige_valor $# "$1"; carpetas+=("${2-}");    shift 2 ;;
    --timeout-du) _exige_valor $# "$1"; tdu="${2-}";            shift 2 ;;
    --help)       sed -n '2,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigia-recursos: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
vig_ent_acotado "$tdu" && [ "$tdu" -ge 1 ] || vig_precond "--timeout-du debe ser un entero positivo (segundos)"
for u in "${umbrales[@]}"; do
  vig_ent_acotado "$u" && [ "$u" -ge 1 ] && [ "$u" -le 100 ] || vig_precond "--umbral debe ser un entero de 1 a 100: $u"
done
case "$modo" in
  inodos) [ -n "$ruta" ] || ruta=/tmp
          [ "${#umbrales[@]}" -le 1 ] || vig_precond "inodos admite un solo --umbral"
          [ "${#umbrales[@]}" -eq 1 ] || umbrales=(85) ;;
  disco)  [ -n "$ruta" ] || ruta=/
          [ "${#umbrales[@]}" -gt 0 ] || umbrales=(90 95 97) ;;
  carpeta) for c in "${carpetas[@]}"; do
             vig_valida_carpeta "$c" || vig_precond "--carpeta debe ser RUTA_ABSOLUTA[=GB] con GB entero: $c"
           done ;;
  *) vig_precond "--modo debe ser inodos, disco o carpeta" ;;
esac
if [ "$modo" != carpeta ]; then
  [[ "$ruta" == /* && "$ruta" != *[[:cntrl:]]* ]] || vig_precond "--ruta debe ser absoluta y sin caracteres de control"
fi
vig_estado_dir || exit 2

# ── inodos y disco: UNA lectura de df, y el valor se acepta solo si son dígitos ────────────────
if [ "$modo" = inodos ]; then
  clave="inodos-$(vig_hash "$ruta")"
  out="$(df --output=ipcent -- "$ruta" 2>/dev/null)"; rc=$?
  u="$(printf '%s' "${out##*$'\n'}" | tr -dc 0-9)"
  if [ "$rc" -ne 0 ] || ! vig_ent_acotado "$u"; then
    vig_no_medido "$clave" INODOS-NO-MEDIDO "$ruta sin dato de inodos (df sin respuesta o el sistema de ficheros no los cuenta)" || exit 2
    exit 0
  fi
  vig_medido "$clave" || exit 2
  vig_avisa_sube "$clave" "$u" "${umbrales[0]}" INODOS "$ruta al $u % (umbral ${umbrales[0]} %)" || exit 2
  exit 0
fi

if [ "$modo" = disco ]; then
  clave="disco-$(vig_hash "$ruta")"
  out="$(df -k --output=pcent,avail -- "$ruta" 2>/dev/null)"; rc=$?
  ultima="${out##*$'\n'}"
  u="${ultima%%\%*}"; u="$(printf '%s' "$u" | tr -dc 0-9)"
  libre="${ultima#*%}"; libre="$(printf '%s' "$libre" | tr -dc 0-9)"
  if [ "$rc" -ne 0 ] || ! vig_ent_acotado "$u" || ! vig_ent_acotado "$libre"; then
    vig_no_medido "$clave" DISCO-NO-MEDIDO "$ruta sin dato de disco (df sin respuesta o salida ilegible)" || exit 2
    exit 0
  fi
  vig_medido "$clave" || exit 2
  # Un solo ciclo para todos los umbrales: se decide cada uno, se emite UNA línea con el más alto y
  # solo si salió se confirman los estados (ver `vig_decide` en lib-vigias.sh).
  vig_ciclo_ini; mayor=''
  for t in "${umbrales[@]}"; do
    vig_decide "$clave-$t" "$u" "$t"; rc=$?
    case "$rc" in
      10) if [ -z "$mayor" ] || [ "$t" -gt "$mayor" ]; then mayor="$t"; fi ;;
      0|11) : ;;
      *) vig_descarta; exit 2 ;;
    esac
  done
  if [ -n "$mayor" ]; then
    vig_evento DISCO "$ruta al $u % ($((libre / 1048576)) GB libres) umbral $mayor %" || { vig_descarta; exit 2; }
  fi
  vig_confirma || exit 2
  exit 0
fi

# ── carpeta: du con tiempo máximo; sin tope declarado se dice, no se calla ─────────────────────
if [ "${#carpetas[@]}" -eq 0 ]; then
  vig_avisa_sube sintope-global 1 1 CARPETA-SIN-TOPE "no se declaró ninguna carpeta: usa --carpeta RUTA=GB" || exit 2
  exit 0
fi
for c in "${carpetas[@]}"; do
  vig_valida_carpeta "$c"
  r="$VIG_RUTA"; tope="$VIG_TOPE"; h="$(vig_hash "$r")"
  if [ -z "$tope" ]; then
    vig_avisa_sube "sintope-$h" 1 1 CARPETA-SIN-TOPE "$r sin tope declarado (usa --carpeta RUTA=GB)" || exit 2
    continue
  fi
  out="$(timeout "$tdu" du -xs --block-size=1G -- "$r" 2>/dev/null)"; rc=$?
  g="${out%%$'\t'*}"
  if ! vig_ent_acotado "$g" || { [ "$rc" -ne 0 ] && [ "$g" -le "$tope" ]; }; then
    vig_no_medido "carpeta-$h" CARPETA-NO-MEDIDO "$r (du sin terminar en $tdu s o con error)" || exit 2
    continue
  fi
  vig_medido "carpeta-$h" || exit 2
  sobre=0; [ "$g" -gt "$tope" ] && sobre=1
  vig_avisa_sube "carpeta-$h" "$sobre" 1 CARPETA "$r = $g GB > tope $tope GB" || exit 2
done
exit 0
