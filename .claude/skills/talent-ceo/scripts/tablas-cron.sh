#!/usr/bin/env bash
# tablas-cron.sh — Minutos de las tablas periódicas, LEÍDOS DEL PERFIL (talent-ceo, ref 03).
#
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   tablas-cron.sh --minutos <id-de-cron>     # p.ej. tabla-mergeadores
#   tablas-cron.sh --crontab <id-de-cron> --comando <CMD>
#   tablas-cron.sh --help
#
# rc: 0 = emitido · 1 = no hay fila `cron` con ese id, o no declara `minutos`
#     2 = PRECONDICIÓN: sin perfil, perfil inválido, argumentos ausentes.
#
# ── POR QUÉ LOS MINUTOS NO ESTÁN AQUÍ DENTRO ───────────────────────────────────────────────────
# Hardcodear `06,21,36,51` convertiría la cadencia de UNA instancia en una constante del skill, y
# el skill viaja a instancias que no son ésta. Los minutos son TOPOLOGÍA: viven en el perfil, en el
# atributo `minutos` de la fila `cron` correspondiente. Sin fila `cron` no se inventa una cadencia
# por defecto: se falla (rc 1) — una cadencia inventada colocaría trabajo real a una hora que nadie
# decidió.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

# ── Validacion del campo de minutos por GRAMATICA, no por charset ──────────────────────────────
# Una guarda de charset (`*[!0-9,*/-]*`) solo mira QUE caracteres aparecen, no COMO se combinan:
# deja pasar `,,` (item vacio), `60` (fuera de rango), `5-`, `/2` y `*/0`. Cron rechaza esas
# cadenas —o peor, las interpreta corridas— y el fallo aparece en la maquina, no aqui.
# Gramatica aceptada:  campo := item ("," item)*
#                      item  := ("*" | n | n "-" m) [ "/" paso ]
#                      0 <= n <= m <= 59 · 1 <= paso <= 59
# `_num_acotado <cadena>` — dígitos Y de longitud representable. La gramática de abajo comprueba el
# RANGO con `$((10#$x))`, y esa comprobación es inútil sobre un número que no cabe: `10#…616` con
# veinte dígitos DESBORDA el entero de 64 bits de bash y da un valor cualquiera — medido,
# `minutos=18446744073709551616` salía con **rc 0** y se emitía tal cual a la crontab, y
# `*/18446744073709551617` igual, pese a que el paso permitido es 1..59. Es la misma lección que ya
# está escrita arriba (charset != gramática) con una dimensión más: **la MAGNITUD**. 18 dígitos
# entran siempre en 64 bits, así que a partir de aquí el `10#` es seguro. El tope va generoso a
# propósito para no rechazar un `007` legítimo, que cron acepta.
_num_acotado() { case "${1-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 18 ]; }

_cron_minutos_valido() {
  local campo="${1-}" item paso n m glob_ya_off=0
  [ -n "$campo" ] || return 1
  case "$campo" in ,*|*,|*,,*) return 1 ;; esac        # items vacios al principio, final o en medio
  # `set -f` ANTES del split: sin el, `set -- $campo` somete el campo a EXPANSION DE RUTAS y un
  # `*` legitimo (todos los minutos) se convierte en la lista de ficheros del directorio actual.
  # Es decir: la validacion dependeria del cwd. Se restaura solo si no estaba ya activo.
  case $- in *f*) glob_ya_off=1 ;; esac
  set -f
  # La coma NO es IFS-whitespace, asi que aqui el shell NO colapsa separadores: `a,,b` da tres
  # campos y el vacio del medio se conserva. Por eso este split es correcto y el `IFS=$'\t'` de
  # otros sitios no lo era — y por eso, ademas, el `case` de arriba puede rechazar el item vacio
  # en vez de no llegar a verlo nunca. Medido junto al resto en `perfil_campos` (`lib-perfil.sh`).
  local IFS=,
  # shellcheck disable=SC2086  # el split por comas es deliberado: es la gramatica del campo
  set -- $campo
  [ "$glob_ya_off" -eq 1 ] || set +f
  [ "$#" -ge 1 ] || return 1
  for item in "$@"; do
    case "$item" in
      */*/*) return 1 ;;                               # doble barra: `1/2/3`
      */*)
        paso="${item##*/}"; item="${item%%/*}"
        _num_acotado "$paso" || return 1
        [ "$((10#$paso))" -ge 1 ] && [ "$((10#$paso))" -le 59 ] || return 1 ;;
    esac
    case "$item" in
      '*') : ;;
      *-*-*) return 1 ;;                                # `1-2-3`
      *-*)
        n="${item%%-*}"; m="${item##*-}"
        _num_acotado "$n" || return 1
        _num_acotado "$m" || return 1
        [ "$((10#$n))" -le 59 ] && [ "$((10#$m))" -le 59 ] || return 1
        [ "$((10#$n))" -le "$((10#$m))" ] || return 1 ;;
      *)
        _num_acotado "$item" || return 1
        [ "$((10#$item))" -le 59 ] || return 1 ;;
    esac
  done
  return 0
}

id=''; comando=''; modo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --minutos) _exige_valor $# "$1"; modo='minutos'; id="${2-}";      shift 2 ;;
    --crontab) _exige_valor $# "$1"; modo='crontab'; id="${2-}";      shift 2 ;;
    --comando) _exige_valor $# "$1"; comando="${2-}";               shift 2 ;;
    --help)     sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "tablas-cron: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$modo" ] && [ -n "$id" ] || { echo "tablas-cron: PRECOND: falta --minutos|--crontab <id>" >&2; exit 2; }

fila="$(perfil_row1 cron "$id")"; rc=$?
case "$rc" in
  0) : ;;
  1) echo "tablas-cron: no hay fila cron con id \"$id\" en el perfil" >&2; exit 1 ;;
  *) echo "tablas-cron: PRECOND: sin perfil válido" >&2; exit 2 ;;
esac

# `cut -f6` es correcto con celdas vacias: delimita por cada tabulador y no colapsa. El patron que
# SI se come los vacios es `IFS=$'\t' read` (el tabulador es IFS-whitespace); medido en
# `perfil_campos`, `lib-perfil.sh`. Dicho aqui para que no se "arregle" por parecerse a aquel.
atrs="$(printf '%s' "$fila" | cut -f6)"
minutos="$(perfil_attr "$atrs" minutos)" || {
  echo "tablas-cron: la fila cron \"$id\" no declara el atributo \"minutos\"" >&2; exit 1; }
# `minutos=` (clave presente, valor vacio) pasa V7 y perfil_attr devuelve rc 0 con cadena vacia.
# Emitirlo generaria " * * * * <cmd>": una linea de crontab SIN campo de minutos, que cron
# rechaza o —peor— interpreta corrida. Se falla aqui, donde aun se puede decir por que.
[ -n "$minutos" ] || {
  echo "tablas-cron: la fila cron \"$id\" declara \"minutos\" VACIO; no se genera una cadencia sin minutos" >&2; exit 1; }
_cron_minutos_valido "$minutos" || {
  echo "tablas-cron: \"minutos\" de \"$id\" no es un campo de minutos valido para cron: $minutos" >&2
  echo "tablas-cron: gramatica: item[,item...] donde item = */n | N | N-M [/paso], 0<=N<=M<=59, 1<=paso<=59" >&2
  exit 1; }

case "$modo" in
  minutos) printf '%s\n' "$minutos"; exit 0 ;;
  crontab)
    [ -n "$comando" ] || { echo "tablas-cron: PRECOND: --crontab exige --comando" >&2; exit 2; }
    # Una entrada de crontab es UNA LINEA. Un salto dentro de `--comando` no "rompe el formato":
    # inyecta una ENTRADA NUEVA con su propia cadencia, que cron ejecutara sin que nadie la haya
    # declarado. Es el mismo campo libre con separador que el `--nota` del bus, aqui con peor
    # desenlace porque el resultado se ejecuta. Se rechaza por CLASE de control, no enumerando.
    # El `%` de crontab. OJO CON EL MOTIVO: no es un problema de `printf` —`$comando` viaja como
    # ARGUMENTO, no como cadena de formato, asi que `printf` NO interpreta sus `%`—. El problema
    # esta en la GRAMATICA DE CRONTAB: alli `%` es especial, se traduce a salto de linea y lo que
    # sigue al primero se pasa al comando como STDIN. Un `%` sin escapar produce una entrada que
    # NO ejecuta lo declarado. Se arregla por la razon correcta o el proximo lo "arregla" mirando
    # al printf y lo deja igual de roto.
    # Se RECHAZA en vez de escapar: escapar cambiaria en silencio lo que alguien pidio ejecutar.
    # Quien quiera un `%` literal escribe `\%`, que es lo que crontab espera, y pasa tal cual.
    # La PARIDAD de barras importa, y borrar pares `\%` de izquierda a derecha la ignoraba: en
    # `\\%` la primera barra escapa a la SEGUNDA, asi que el `%` queda SUELTO y crontab lo traduce
    # igual — pero el borrado se llevaba el `\%` final y daba la cadena por limpia. Un `%` esta
    # escapado solo si le precede un numero IMPAR de barras. Se cuenta.
    _pct_suelto() {   # rc 0 si hay algun % sin escapar
      local t="${1-}" i c n_bs=0
      for (( i = 0; i < ${#t}; i++ )); do
        c="${t:i:1}"
        case "$c" in
          '\') n_bs=$((n_bs + 1)) ;;
          '%')  [ $((n_bs % 2)) -eq 0 ] && return 0; n_bs=0 ;;
          *)    n_bs=0 ;;
        esac
      done
      return 1
    }
    if _pct_suelto "$comando"; then
      echo "tablas-cron: PRECOND: --comando lleva un '%' SIN escapar; en crontab '%' se traduce a salto de linea" >&2
      echo "tablas-cron: y lo que sigue al primero se pasa como stdin. Para un % literal, escribe \\%" >&2
      exit 2
    fi
    # `[[:cntrl:]]` es C0 y DEL; los C1 (0x80-0x9F) se cuelan, y ahi vive el CSI de 8 bits. No se
    # filtran por rango —esos bytes son CONTINUACION de caracteres legitimos en UTF-8— sino
    # rechazando lo que NO ES UTF-8 VALIDO, que es la unica condicion bajo la que uno esta suelto.
    # Sin `iconv` la comprobacion no se puede hacer, y antes eso era saltarsela: medido con un PATH
    # sin `iconv`, un `--comando` con el C1 crudo `0x9b 2J` salia con rc 0 y el byte iba LITERAL a la
    # linea de crontab, que se EJECUTA. Se falla cerrado: no se emite una entrada que no se ha podido
    # validar.
    command -v iconv >/dev/null 2>&1 || {
      # «PRECOND: falta X» es frase CONTRACTUAL aqui: la suite la parsea para deducir obligatorios
      # ([r8-16]). Usarla convertia `--comando` en obligatorio de TODO ejemplo de este script y ponia
      # rojos los tres `--minutos` de la doc, que son correctos. Medido al correr la suite.
      echo "tablas-cron: PRECOND: no hay \`iconv\` en el PATH; no se puede validar --comando y NO se emite a ciegas" >&2
      exit 2; }
    printf '%s' "$comando" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || {
      echo "tablas-cron: PRECOND: --comando no es UTF-8 valido; una entrada de crontab es texto legible" >&2
      exit 2; }
    # «UTF-8 valido» NO implica «sin controles»: U+009B (CSI) se codifica `c2 9b` y pasa el filtro.
    # Se rechaza la banda de codepoints U+0080..U+009F, que no aparece en texto legible.
    # SIN TUBERIA, y el motivo es `set -uo pipefail` de la linea 20. Con `pipefail`, el estado de una
    # tuberia es el del ULTIMO comando que fallo — y cuando `grep -q` encuentra la senal sale de
    # inmediato y CIERRA el descriptor, con lo que `printf` recibe SIGPIPE y termina en 141. La
    # tuberia entera devuelve 141, el `if` NO dispara y el control C1 pasa: **fail-open silencioso, y
    # cuanto MAS grande la entrada, mas probable**. Medido en aislado: con 200 KB por delante, el `if`
    # no entra aunque la senal este ahi.
    # Un `case` con glob no tiene tuberia ni proceso que matar, asi que no hay estado que interpretar.
    # `LC_ALL=C` para las DOS guardas: `[[:cntrl:]]` no significa lo mismo en cada localizacion
    # —bajo C es C0 mas DEL, por bytes; bajo una UTF-8 incluye ademas U+0080..U+009F—, y una guarda
    # cuyo alcance depende de la maquina del que la corre no esta cerrada, esta abierta a ratos.
    # Aqui el C1 lo caza la guarda de arriba en cualquier localizacion (medido en las cuatro
    # instaladas), asi que la fijacion NO cambia el veredicto de ninguna entrada que sepa nombrar:
    # es determinismo, y se declara como tal en vez de acompanarse de un caso que no distinguiria
    # nada. La que SI cambia de diagnostico con la localizacion es la gemela de `bus-sellar.sh`,
    # donde la clase va ANTES que la guarda especifica; alli el caso muerde.
    # Se restaura despues: el resto del script no tiene por que correr en C.
    _lc_previo="${LC_ALL-__SIN_LC_ALL__}"
    LC_ALL=C
    case "$comando" in
      *$'\xc2'[$'\x80'-$'\x9f']*)
        echo "tablas-cron: PRECOND: --comando contiene un control C1 (U+0080..U+009F) aunque este bien codificado" >&2
        exit 2 ;;
    esac
    case "$comando" in
      *[[:cntrl:]]*)
        echo "tablas-cron: PRECOND: --comando contiene un caracter de CONTROL; una entrada de crontab es UNA LINEA" >&2
        echo "tablas-cron: un salto de linea aqui no deforma la linea: anade una entrada que nadie declaro" >&2
        exit 2 ;;
    esac
    if [ "$_lc_previo" = "__SIN_LC_ALL__" ]; then unset LC_ALL; else LC_ALL="$_lc_previo"; fi
    printf '%s * * * * %s\n' "$minutos" "$comando"; exit 0 ;;
esac
