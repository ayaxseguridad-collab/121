#!/usr/bin/env bash
# caducidad.sh — Gates cuyo recibo CADUCA por el avance de main entre dos commits (solo lectura).
#
# Uso:
#   caducidad.sh [--repo DIR] [--manifest M] [--formato texto|tsv] <sha_viejo> <sha_nuevo>
#   caducidad.sh --help
#
# Mide, con el mapa de insumos del motor (scripts/lib/insumos-por-gate.sh), qué gates del manifiesto
# deben re-correrse porque `git diff --name-only <viejo> <nuevo>` toca alguno de sus insumos. Reglas:
#   · un insumo UNIVERSAL tocado => caducan TODOS;
#   · un gate SIN entrada en el mapa NO se conserva jamás: aparece como SIN-MAPA(caduca) y en CADUCAN;
#   · un gate declarado en TF_ALWAYS_RERUN caduca siempre;
#   · las exclusiones (TF_NOT_INPUTS_*) solo descuentan rutas que casan con un patrón declarado.
# La familia `e2e` (que el manifiesto no declara por shard) se mide aparte si el mapa tiene su entrada.
#
# Parámetros: --repo > CAD_REPO > atributo `clon` de la fila estacion del perfil (TF_ESTACION);
# --manifest > TF_MANIFEST. Sin valor => rc 2 nombrando la variable. Entorno opcional: LG_INSUMOS_CONF
# (mapa alternativo), TF_MOTOR_PIN (motor pinado).
#
# Salida texto:
#   avance <viejo> -> <nuevo>: N ficheros
#   UNIVERSAL tocado -> CADUCAN TODOS        (solo si aplica)
#   CADUCAN: <gates> (+ carveout_check siempre)
#   CONSERVAN: <gates>
#   SIN-MAPA(caduca): <gates>                (solo si hay)
# Salida tsv: una fila por gate `<gate><TAB>CADUCA|CONSERVA|SIN-MAPA(caduca)<TAB><motivo>`.
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0 = medido
#   2 = uso o precondición: repo sin definir o no git, sha malformado o AUSENTE del repo (el mensaje
#       nombra el repo y el sha), manifiesto sin definir/ilegible o sin TF_GATE_IDS, sin mapa de insumos, sin jq
set -uo pipefail
set -f
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-estacion.sh
. "$HERE/lib-estacion.sh" || exit 2
# shellcheck source=cad-lib.sh
. "$HERE/cad-lib.sh" || exit 2

uso() { echo "uso: caducidad.sh [--repo DIR] [--manifest M] [--formato texto|tsv] <sha_viejo> <sha_nuevo>  (--help)" >&2; exit 2; }

repo_arg=''; man_arg=''; formato=texto; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h) est_ayuda "${BASH_SOURCE[0]}"; exit 0 ;;
    --repo) [ $# -ge 2 ] || uso; repo_arg="$2"; shift 2 ;;
    --manifest) [ $# -ge 2 ] || uso; man_arg="$2"; shift 2 ;;
    --formato) [ $# -ge 2 ] || uso; formato="$2"; shift 2 ;;
    --) shift; pos+=("$@"); break ;;
    -*) uso ;;
    *) pos+=("$1"); shift ;;
  esac
done
[ "${#pos[@]}" -eq 2 ] || uso
case "$formato" in texto | tsv) ;; *) uso ;; esac
old="${pos[0]}"; new="${pos[1]}"

repo="$(est_param "$repo_arg" CAD_REPO clon)" || repo=''
est_exige 'CAD_REPO (--repo)' "$repo" || exit 2
[ -d "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "caducidad.sh: PRECOND: $repo no es un repo git" >&2; exit 2; }
for s in "$old" "$new"; do
  est_sha_ok "$s" || { echo "caducidad.sh: PRECOND: sha malformado: $s" >&2; exit 2; }
  git -C "$repo" cat-file -e "$s^{commit}" 2>/dev/null || { echo "caducidad.sh: PRECOND: el repo $repo no contiene el sha $s" >&2; exit 2; }
done
man="$(est_param "$man_arg" TF_MANIFEST '')" || man=''
est_exige 'TF_MANIFEST (--manifest)' "$man" || exit 2
[ -f "$man" ] && [ -r "$man" ] || { echo "caducidad.sh: PRECOND: manifiesto ilegible: $man" >&2; exit 2; }
gates="$(cad_gates_de_manifiesto "$man")" || { echo "caducidad.sh: PRECOND: el manifiesto $man no declara TF_GATE_IDS" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "caducidad.sh: PRECOND: falta jq" >&2; exit 2; }
cad_cargar || exit 2

est_tmp_crear || exit 2
trap est_tmp_limpiar EXIT
rutas="$EST_TMP/rutas"
git -C "$repo" diff --name-only "$old" "$new" > "$rutas" || { echo "caducidad.sh: PRECOND: git diff falló en $repo" >&2; exit 2; }
n="$(grep -c . "$rutas" || true)"
uni=0; cad_universal "$rutas" && uni=1
# La familia e2e comparte insumos y no se declara por shard: se mide si el mapa la conoce.
if insumos_de_gate e2e >/dev/null 2>&1; then
  case " $gates " in *" e2e "*) ;; *) gates="$gates e2e" ;; esac
fi

cad=''; cons=''; sinmapa=''; filas=''
for g in $gates; do
  mot="$(cad_gate_caduca "$g" "$rutas")"; rc=$?
  case "$rc" in
    0) est=CADUCA; cad="$cad $g" ;;
    3) est='SIN-MAPA(caduca)'; mot=sin-mapa; cad="$cad $g"; sinmapa="$sinmapa $g" ;;
    4) est=CADUCA; mot=siempre-re-corre; cad="$cad $g" ;;
    1) if [ "$uni" = 1 ]; then est=CADUCA; mot=universal; cad="$cad $g"; else est=CONSERVA; mot=-; cons="$cons $g"; fi ;;
    *) est=CADUCA; mot=error-de-medicion; cad="$cad $g" ;; # fail-closed: lo no medible no se conserva
  esac
  filas="$filas$g"$'\t'"$est"$'\t'"$mot"$'\n'
done

if [ "$formato" = tsv ]; then
  printf '%s' "$filas"
else
  echo "avance $old -> $new: $n ficheros"
  [ "$uni" = 0 ] || echo "UNIVERSAL tocado -> CADUCAN TODOS"
  echo "CADUCAN:$cad (+ carveout_check siempre)"
  echo "CONSERVAN:$cons"
  [ -z "$sinmapa" ] || echo "SIN-MAPA(caduca):$sinmapa"
fi
exit 0
