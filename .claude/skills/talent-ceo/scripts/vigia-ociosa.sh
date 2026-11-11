#!/usr/bin/env bash
# vigia-ociosa.sh — UN tick: avisa de las máquinas del perfil ociosas durante N minutos (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. Un vigía es un tick que sale con rc 0; el bucle vive en
# `vigias.sh`. Contrato común y razones en `lib-vigias.sh`.
#
# Uso:
#   vigia-ociosa.sh [--maquina <ID>]... [--umbral-nucleo 0.3] [--minutos 30] [--hueco-max 900]
#   vigia-ociosa.sh --validar [--maquina <ID>]...     # solo comprueba la configuración (rc 0 o 2)
#   vigia-ociosa.sh --help
#
# Entorno: TA_PERFIL (perfil de instancia) · TA_BUS_STATE_DIR · TA_PROC_DIR (solo pruebas).
#
# Salida:
#   OCIOSA <máquina> carga5m <c>/<n> < <u> por núcleo durante <m> min
#   OCIOSA-NO-MEDIDO <máquina> …    la máquina no respondió o devolvió algo ilegible
#
# rc: 0 = tick hecho · 2 = PRECONDICIÓN (perfil ausente o inválido, máquina inexistente, ninguna
#     máquina con acceso=local) o la emisión de un evento falló.
#
# ── QUÉ MÁQUINAS, Y CÓMO SE LLEGA ──────────────────────────────────────────────────────────────
# Las filas `maquina` del perfil (o solo las pedidas con --maquina, por su id). La que declara
# `acceso=local` se mide por /proc; las demás por `ssh -- <maquina>` (la columna maquina de la fila),
# como `relay-ceo.sh`. Nunca una lista fija de equipos.
#
# ── ENTEROS, SIN DECIMALES ─────────────────────────────────────────────────────────────────────
# Carga y umbral se pasan a centésimas enteras y se compara `carga_c < umbral_c * núcleos`, que es
# `carga/núcleos < umbral`. La coma decimal vale igual que el punto.
#
# ── LA RACHA SE MIDE EN TIEMPO, NO EN MUESTRAS ─────────────────────────────────────────────────
# Se guarda cuándo empezó la racha de carga baja. Una carga alta (o una máquina que no responde) la
# reinicia. Si entre dos ticks pasó más de --hueco-max segundos nadie midió ese intervalo, así que
# la racha también se reinicia: no se afirma «ociosa durante 30 min» de un rato que no se vio.
# Por TRANSICIÓN: avisa una vez al cumplirse el tiempo y se re-arma cuando la carga vuelve a subir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vigias.sh"

pedidas=(); umbral=0.3; minutos=30; hueco=900; validar=0
while [ $# -gt 0 ]; do
  case "$1" in
    --maquina)       _exige_valor $# "$1"; pedidas+=("${2-}"); shift 2 ;;
    --umbral-nucleo) _exige_valor $# "$1"; umbral="${2-}";     shift 2 ;;
    --minutos)       _exige_valor $# "$1"; minutos="${2-}";    shift 2 ;;
    --hueco-max)     _exige_valor $# "$1"; hueco="${2-}";      shift 2 ;;
    --validar)       validar=1; shift ;;
    --help)          sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigia-ociosa: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
vig_centesimas "$umbral" && [ "$VIG_CENT" -ge 1 ] || vig_precond "--umbral-nucleo debe ser un decimal positivo"
umbral_c="$VIG_CENT"
vig_ent_acotado "$minutos" && [ "$minutos" -ge 1 ] || vig_precond "--minutos debe ser un entero positivo"
vig_ent_acotado "$hueco" && [ "$hueco" -ge 1 ] || vig_precond "--hueco-max debe ser un entero positivo (segundos)"

# Máquinas del perfil: id, destino y si es la local. Un perfil ausente o inválido es rc 2.
filas="$(perfil_rows maquina)"; rc=$?
[ "$rc" -le 1 ] || vig_precond "perfil ausente o inválido"
[ "$rc" -eq 0 ] || vig_precond "el perfil no declara ninguna fila maquina"
ids=(); dests=(); hay_local=0
while IFS= read -r fila; do
  perfil_campos "$fila"
  id="${PERFIL_CAMPOS[1]-}"; maq="${PERFIL_CAMPOS[2]-}"; attrs="${PERFIL_CAMPOS[5]-}"
  printf '%s' "$id" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || vig_precond "id de máquina fuera de [A-Za-z0-9._-]: $id"
  if [ "$(perfil_attr "$attrs" acceso || true)" = local ]; then
    hay_local=1; dest='-local'
  else
    dest="$maq"; { [ -n "$dest" ] && [ "$dest" != '-' ]; } || dest="$id"
    printf '%s' "$dest" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@:-]{0,127}$' || vig_precond "destino de máquina no apto: $dest"
  fi
  ids+=("$id"); dests+=("$dest")
done < <(printf '%s\n' "$filas")
[ "$hay_local" -eq 1 ] || vig_precond "ninguna fila maquina declara acceso=local; no se puede decidir cuál se mide por /proc"
for p in "${pedidas[@]}"; do
  hallada=0
  for id in "${ids[@]}"; do [ "$id" = "$p" ] && hallada=1; done
  [ "$hallada" -eq 1 ] || vig_precond "--maquina $p no existe en el perfil"
done
[ "$validar" -eq 0 ] || exit 0
vig_estado_dir || exit 2

for i in "${!ids[@]}"; do
  id="${ids[$i]}"; dest="${dests[$i]}"
  if [ "${#pedidas[@]}" -gt 0 ]; then
    quiere=0
    for p in "${pedidas[@]}"; do [ "$p" = "$id" ] && quiere=1; done
    [ "$quiere" -eq 1 ] || continue
  fi
  clave="ociosa-$id"; racha="$VIG_DIR/$clave.racha"
  [ ! -L "$racha" ] || vig_precond "la racha es un symlink: $racha"
  ahora="$(vig_epoch)" || vig_precond "no se pudo medir la hora"
  if ! vig_carga_maquina "$dest"; then
    rm -f -- "$racha"
    vig_no_medido "$clave" OCIOSA-NO-MEDIDO "$id no se pudo medir (sin respuesta o lectura ilegible)" || exit 2
    continue
  fi
  vig_medido "$clave" || exit 2
  if [ "$VIG_CARGA_C" -lt $((umbral_c * VIG_NUCLEOS)) ]; then
    desde="$ahora"
    if [ -f "$racha" ]; then
      read -r d0 u0 < "$racha" || true
      if vig_ent_acotado "${d0-}" && vig_ent_acotado "${u0-}" && [ $((ahora - u0)) -ge 0 ] && [ $((ahora - u0)) -le "$hueco" ]; then desde="$d0"; fi
    fi
    printf '%s %s\n' "$desde" "$ahora" > "$racha" || vig_precond "no se pudo escribir la racha"
    min=$(((ahora - desde) / 60))
  else
    rm -f -- "$racha"; min=0
  fi
  vig_avisa_sube "$clave" "$min" "$minutos" OCIOSA \
    "$id carga5m $(vig_formato_cent "$VIG_CARGA_C")/$VIG_NUCLEOS < $(vig_formato_cent "$umbral_c") por núcleo durante $min min" || exit 2
done
exit 0
