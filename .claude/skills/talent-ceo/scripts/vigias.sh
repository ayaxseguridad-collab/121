#!/usr/bin/env bash
# vigias.sh — Multiplexor de los vigías del mando: los ejecuta en bucle y emite sus eventos (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. UNA sola salida para un solo Monitor: la línea de cada evento
# ya lleva su clase, así que no se le añade prefijo. Contrato de línea y razones en `lib-vigias.sh`.
#
# Uso:
#   vigias.sh [--una-vez] [--lista] [--sin <vigía>]... [--cada-<vigía> <segundos>]...
#             [--lector <ID>] [--excluir-rol <ROL>]... [--carpeta RUTA[=GB]]... [--maquina <ID>]...
#   vigias.sh --help
#
# Vigías (periodo por defecto): bus-pedidos 15 · bus-rojos 15 · silencio 60 · ociosa 300 · inodos 120 ·
# disco 120 · carpeta 1800. `--cada-bus` fija los dos del bus; los demás, `--cada-<vigía>`. `--sin`
# desactiva uno. `--lector` es la base de los cursores (`<base>-pedidos`, `<base>-rojos`; por defecto
# `vigias`). `--excluir-rol` va a los dos del bus y al silencio; `--carpeta`, a carpeta;
# `--maquina`, a ociosa.
#
# Entorno: TA_BUS (OBLIGATORIA) · TA_PERFIL · TA_BUS_STATE_DIR.
#
# Salida: `VIGIAS-ARMADOS …` al arrancar, los eventos de los vigías, `VIGIAS-PARADOS rc=<n>` al salir y
# `VIGIA-FALLO <vigía> …` (una vez por transición) si un tick termina con rc distinto de 0: un vigía
# que cae no se lee como calma.
#
# rc: 0 = --una-vez sin fallos, o --lista · 1 = --una-vez con algún tick fallido · 2 = PRECONDICIÓN
#     (perfil ausente o inválido, vigía mal configurado): se valida TODO antes de armar nada, así que
#     no hay tick parcial · 143/130/129 = cortado por TERM/INT/HUP.
#
# ── SOLO TERMINA A SUS PROPIOS HIJOS ───────────────────────────────────────────────────────────
# Cada tick se lanza en segundo plano y su PID se REGISTRA. Al salir, a cada PID registrado se le
# verifica que sigue vivo, que es hijo directo de este proceso y que ejecuta un vigía de este
# directorio; solo entonces se le envía TERM. Nunca se señala un grupo, un padre ni un patrón. Un
# proceso de otro dueño que comparta grupo no se toca. Límite: un tick que esté dentro de una
# herramienta externa larga (`du`) deja a esa herramienta terminar sola por su propio tiempo máximo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vigias.sh"

NOMBRES=(bus-pedidos bus-rojos silencio ociosa inodos disco carpeta)
declare -A CADA=([bus-pedidos]=15 [bus-rojos]=15 [silencio]=60 [ociosa]=300 [inodos]=120 [disco]=120 [carpeta]=1800)
declare -A SIN=()
una_vez=0; lista=0; lector=vigias; excl=(); carp=(); maq=()
while [ $# -gt 0 ]; do
  case "$1" in
    --una-vez)     una_vez=1; shift ;;
    --lista)       lista=1; shift ;;
    --sin)         _exige_valor $# "$1"; SIN["${2-}"]=1;           shift 2 ;;
    --cada-bus)    _exige_valor $# "$1"; CADA[bus-pedidos]="${2-}"; CADA[bus-rojos]="${2-}"; shift 2 ;;
    --cada-silencio|--cada-ociosa|--cada-inodos|--cada-disco|--cada-carpeta)
                   _exige_valor $# "$1"; CADA["${1#--cada-}"]="${2-}"; shift 2 ;;
    --lector)      _exige_valor $# "$1"; lector="${2-}";           shift 2 ;;
    --excluir-rol) _exige_valor $# "$1"; excl+=("${2-}");          shift 2 ;;
    --carpeta)     _exige_valor $# "$1"; carp+=("${2-}");          shift 2 ;;
    --maquina)     _exige_valor $# "$1"; maq+=("${2-}");           shift 2 ;;
    --help)        sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigias: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

# ── Validar TODO antes de armar nada (fail-closed, sin tick parcial) ───────────────────────────
for n in "${!SIN[@]}"; do
  ok=0; for m in "${NOMBRES[@]}"; do [ "$m" = "$n" ] && ok=1; done
  [ "$ok" -eq 1 ] || vig_precond "--sin $n: no es un vigía (${NOMBRES[*]})"
done
ACTIVOS=()
for n in "${NOMBRES[@]}"; do
  p="${CADA[$n]}"
  vig_ent_acotado "$p" && [ "$p" -ge 1 ] && [ "$p" -le 86400 ] || vig_precond "periodo de $n debe ser un entero de 1 a 86400 s: $p"
  [ -n "${SIN[$n]-}" ] || ACTIVOS+=("$n")
done
if [ "$lista" -eq 1 ]; then
  for n in "${ACTIVOS[@]}"; do printf '%s\t%s\n' "$n" "${CADA[$n]}"; done
  exit 0
fi
[ "${#ACTIVOS[@]}" -gt 0 ] || vig_precond "no queda ningún vigía activo"
bus_valida_id "$lector-pedidos" || exit 2
bus_valida_id "$lector-rojos" || exit 2
for r in "${excl[@]}"; do bus_valida_id "$r" || exit 2; done
for c in "${carp[@]}"; do vig_valida_carpeta "$c" || vig_precond "--carpeta debe ser RUTA_ABSOLUTA[=GB] con GB entero: $c"; done
perfil_validate >/dev/null || vig_precond "perfil de instancia ausente o inválido (lib-perfil.sh --check)"
[ -n "${TA_BUS-}" ] || vig_precond "TA_BUS no definida"
vig_estado_dir || exit 2
OCIOSA_ARGS=(); for m in "${maq[@]}"; do OCIOSA_ARGS+=(--maquina "$m"); done
for n in "${ACTIVOS[@]}"; do
  [ "$n" = ociosa ] && { bash "$HERE/vigia-ociosa.sh" --validar "${OCIOSA_ARGS[@]}" || exit 2; }
done

# ARGV del tick de un vigía.
argv_de() {
  local r c
  case "$1" in
    bus-pedidos) ARGV=(bash "$HERE/vigia-bus.sh" --modo pedidos --lector "$lector-pedidos")
                 for r in "${excl[@]}"; do ARGV+=(--excluir-rol "$r"); done ;;
    bus-rojos)   ARGV=(bash "$HERE/vigia-bus.sh" --modo rojos --lector "$lector-rojos")
                 for r in "${excl[@]}"; do ARGV+=(--excluir-rol "$r"); done ;;
    silencio)    ARGV=(bash "$HERE/vigia-silencio.sh")
                 for r in "${excl[@]}"; do ARGV+=(--excluir-rol "$r"); done ;;
    ociosa)      ARGV=(bash "$HERE/vigia-ociosa.sh" --hueco-max $((CADA[ociosa] * 3)) "${OCIOSA_ARGS[@]}") ;;
    inodos)      ARGV=(bash "$HERE/vigia-recursos.sh" --modo inodos) ;;
    disco)       ARGV=(bash "$HERE/vigia-recursos.sh" --modo disco) ;;
    carpeta)     ARGV=(bash "$HERE/vigia-recursos.sh" --modo carpeta)
                 for c in "${carp[@]}"; do ARGV+=(--carpeta "$c"); done ;;
  esac
}

# Un tick que termina con rc != 0 es un evento (una vez por transición); uno que vuelve a ir bien re-arma.
cuenta_fin() {
  local n="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    vig_avisa_sube "fallo-$n" 1 1 VIGIA-FALLO "$n terminó con rc $rc"
  else
    vig_sinaviso "fallo-$n" 0 1
  fi
}

esta_vivo() {
  local st
  [ -r "/proc/$1/status" ] || return 1
  st="$(grep -m1 '^State:' "/proc/$1/status" 2>/dev/null)"
  case "$st" in ''|*Z*) return 1 ;; esac
  return 0
}
# Hijo directo de ESTE proceso y ejecutando un vigía de este directorio.
es_hijo_mio() {
  local pp args
  pp="$(ps -o ppid= -p "$1" 2>/dev/null)"; pp="${pp//[[:space:]]/}"
  [ "$pp" = "$$" ] || return 1
  args="$(ps -o args= -p "$1" 2>/dev/null)"
  case "$args" in *"$HERE/vigia"*) return 0 ;; esac
  return 1
}

declare -A PID=() PROX=()
armado=0
parar() {
  local rc=$? n p
  trap - EXIT
  for n in "${!PID[@]}"; do
    p="${PID[$n]}"
    if esta_vivo "$p" && es_hijo_mio "$p"; then kill -TERM "$p" 2>/dev/null; fi
  done
  for n in "${!PID[@]}"; do wait "${PID[$n]}" 2>/dev/null; done
  [ "$armado" -eq 0 ] || vig_evento VIGIAS-PARADOS "rc=$rc"
  exit "$rc"
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap parar EXIT

resumen=''; for n in "${ACTIVOS[@]}"; do resumen="$resumen $n/${CADA[$n]}s"; done
vig_evento VIGIAS-ARMADOS "n=${#ACTIVOS[@]}$resumen" || exit 2
armado=1

if [ "$una_vez" -eq 1 ]; then
  fallos=0
  for n in "${ACTIVOS[@]}"; do
    argv_de "$n"
    "${ARGV[@]}"; rc=$?
    cuenta_fin "$n" "$rc" || true
    [ "$rc" -eq 0 ] || { fallos=1; echo "vigias: $n terminó con rc $rc" >&2; }
  done
  exit "$fallos"
fi

for n in "${ACTIVOS[@]}"; do PROX[$n]=0; done
while :; do
  for n in "${ACTIVOS[@]}"; do
    if [ -n "${PID[$n]-}" ]; then
      if esta_vivo "${PID[$n]}" && es_hijo_mio "${PID[$n]}"; then continue; fi
      wait "${PID[$n]}"; rc=$?
      unset 'PID[$n]'
      cuenta_fin "$n" "$rc" || true
    fi
    if [ "$SECONDS" -ge "${PROX[$n]}" ]; then
      argv_de "$n"
      "${ARGV[@]}" &
      PID[$n]=$!
      PROX[$n]=$((SECONDS + CADA[$n]))
    fi
  done
  sleep 1
done
