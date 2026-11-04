#!/usr/bin/env bash
# check-total-esperado-derivado.sh — TAL-5172, rebote v8 (CR de M2 sobre v7, hallazgo [2]: C2 NO
# reprodujo el "TOTAL_ESPERADO desfasado (594)" citado por M2 — 594 no aparece en ningún sitio
# vivo del paquete de skills, y INV-CO-014 ya está en 615 con validate-package.sh en PASS. Lectura
# de C2: M2 revisó una versión anterior a este arreglo (b6280b12) y el hallazgo original ya se
# cerró. NO se toca ningún número por este hallazgo — el entregable es el ORÁCULO que impide que
# el desfase vuelva a pasar, no un cambio de valor.
#
# Clase, en una línea (encargo v8 de C2): TODO TOTAL ESPERADO SE DERIVA, NO SE ESCRIBE. El ratchet
# de TOTAL_ESPERADO es de DOS CAPAS (lección de esta misma sesión, ver invariants.tsv INV-CO-014):
# `tests/run-tests.sh` (el número REAL, el que la suite gatea) e `invariants.tsv` (el número
# DECLARADO, el que validate-package.sh exige). Las dos capas se mueven juntas en el MISMO commit
# — pero "mueven juntas" es disciplina humana, no garantía. Este check es la garantía: compara,
# para cada fila MUST de invariants.tsv con forma `TOTAL_ESPERADO=<N>`, el <N> declarado contra el
# `TOTAL_ESPERADO=<N>` REAL del fichero que esa fila señala, y falla ruidoso si no coinciden.
#
# EL GATE REAL es su propia corrección como detector:
#   bash check-total-esperado-derivado.sh --self-test
# control POSITIVO SINTÉTICO: invariants.tsv declara 614 y el fichero real dice 615 -> DEBE
# cazarse. control NEGATIVO: ambos en 615 -> cero.
#
# Uso:
#   bash check-total-esperado-derivado.sh --self-test           # verifica el propio detector (el gate real)
#   bash check-total-esperado-derivado.sh [--root <dir-del-skill>]  # comparación real, exit 0/1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- El detector, aislado en una función. Stdout: una línea "DESFASE ..." por cada fila MUST
#     TOTAL_ESPERADO cuyo valor declarado no coincide con el valor real del fichero señalado.
#     Nunca falla por sí misma (fail-closed lo decide el llamador). ---
# <dir-del-skill> debe contener invariants.tsv en su raíz; las rutas de la 2ª columna del tsv son
# relativas a esa misma raíz (mismo contrato que consume validate-package.sh).
#
# [v9, CR de M2 sobre v8, medido y confirmado por C2] Dos bugs reales, uno grave y uno latente:
#
# GRAVE (fail-open real, medido): la versión anterior partía las filas con `IFS=$'\t' read`. El
# tabulador es "IFS whitespace" en bash SIEMPRE, sin importar qué se ponga en IFS: dos tabs
# seguidos se COLAPSAN en un solo separador (verificado: `IFS=$'\t' read -r a b c d e <<< "A␉B␉␉
# C␉D"` da a=A b=B c=C d=D — el campo vacío desaparece y todo lo posterior se corre una posición).
# Una fila con un campo vacío accidental (dos tabs seguidos, en CUALQUIER posición) desplaza
# `must_col`/`value_col`: `must_col` deja de valer "MUST", la fila se descarta por el guard
# silenciosamente, y el TOTAL_ESPERADO real de esa fila NUNCA se compara — el check imprime "OK"
# sobre una fila que nunca miró (reproducido: fila con file vacío ("id⟨tab⟩⟨tab⟩MUST⟨tab⟩
# TOTAL_ESPERADO=614⟨tab⟩nota") + fichero real en 615 → esta función daba "OK" en vez de DESFASE).
#
# LATENTE (mecanismo real, no dispara hoy — los 16 invariants.tsv del árbol terminan en \n,
# verificado uno a uno): `read` sin `|| [ -n "$var" ]` descarta la ÚLTIMA línea de un fichero que
# no termine en salto de línea (la línea queda en el buffer pero `read` devuelve 1 antes de que el
# `while` la procese).
#
# Fix de las DOS con el MISMO mecanismo que ya se usó y se acreditó hoy mismo en
# `tco_control_verdict` (lib.sh): traducir los tabs reales a 0x01 (`tr '\t' '\001'`) ANTES de
# partir. 0x01 NO es "IFS whitespace" (solo espacio/tab/salto de línea lo son en bash SIEMPRE) —
# verificado: `IFS=$'\001' read -r a b c d e <<< "A␁B␁␁C␁D"` da a=A b=B c=[] d=C e=D, el campo
# vacío se PRESERVA en su posición real, sin importar dónde caiga el doble-tab en la fila. Y
# `|| [ -n "${id:-}" ]` cierra la mitad latente. (No se copia el "precedente" que cita el CR —
# `tco_control_verdict` recibe dos hashes por argumento, no tiene bucle TSV alguno; ese precedente
# no existe tal cual, pero el MECANISMO tr+0x01 sí es el mismo que ya se validó ahí, y por eso se
# reutiliza aquí como fix propio, no como copia ciega de una función que no aplica.)
_total_esperado_derivado_scan() { # <dir-del-skill>
  local root="$1"
  local tsv="$root/invariants.tsv"
  [ -f "$tsv" ] || return 0
  local id file must_col value_col rest declared real_line real
  while IFS=$'\001' read -r id file must_col value_col rest || [ -n "${id:-}" ]; do
    [ -n "${id:-}" ] || continue
    case "$id" in \#*) continue ;; esac
    [ "$must_col" = "MUST" ] || continue
    case "$value_col" in
      TOTAL_ESPERADO=*)
        declared="${value_col#TOTAL_ESPERADO=}"
        [ -f "$root/$file" ] || { echo "DESFASE $id: fichero declarado '$file' no existe bajo $root"; continue; }
        real_line="$(grep -m1 -E '^TOTAL_ESPERADO=[0-9]+' "$root/$file" || true)"
        if [ -z "$real_line" ]; then
          echo "DESFASE $id: '$file' no define TOTAL_ESPERADO real (nada que derivar)"
          continue
        fi
        real="${real_line#TOTAL_ESPERADO=}"
        if [ "$declared" != "$real" ]; then
          echo "DESFASE $id: invariants.tsv declara TOTAL_ESPERADO=$declared, $file declara TOTAL_ESPERADO=$real"
        fi
        ;;
    esac
  done < <(tr '\t' '\001' < "$tsv")
}

# --- --self-test: control positivo + control negativo sobre el MISMO _total_esperado_derivado_scan. ---
_self_test() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # CONTROL POSITIVO — invariants.tsv declara 614, el fichero real dice 615. DEBE cazarse.
  mkdir -p "$tmp/pos/tests"
  printf 'INV-X-001\ttests/run-tests.sh\tMUST\tTOTAL_ESPERADO=614\tnota\n' > "$tmp/pos/invariants.tsv"
  printf 'TOTAL_ESPERADO=615\n' > "$tmp/pos/tests/run-tests.sh"

  # CONTROL NEGATIVO — ambos en 615. NO debe cazarse.
  mkdir -p "$tmp/neg/tests"
  printf 'INV-X-001\ttests/run-tests.sh\tMUST\tTOTAL_ESPERADO=615\tnota\n' > "$tmp/neg/invariants.tsv"
  printf 'TOTAL_ESPERADO=615\n' > "$tmp/neg/tests/run-tests.sh"

  # CONTROL POSITIVO [columna desplazada] — doble-tab (campo 'file' vacío) delante de un valor
  # QUE NO COINCIDE con el real. Sin el fix de v9, esto se saltaba en silencio (must_col dejaba de
  # valer "MUST") y NO se cazaba. DEBE cazarse tras el fix.
  mkdir -p "$tmp/pos-shift/tests"
  printf 'INV-X-001\t\tMUST\tTOTAL_ESPERADO=614\tnota\n' > "$tmp/pos-shift/invariants.tsv"
  printf 'TOTAL_ESPERADO=615\n' > "$tmp/pos-shift/tests/run-tests.sh"

  # CONTROL NEGATIVO [sin salto de línea final] — la ÚLTIMA línea del tsv, sin \n de cierre,
  # declara el valor CORRECTO. Sin el fix `|| [ -n "$id" ]`, `read` la descartaría igual (aquí no
  # importaría porque coincide), así que el control real es que el POSITIVO gemelo (mismo tsv sin
  # \n final, valor INCORRECTO) SÍ se cace — confirma que la línea sin salto se procesa de verdad.
  mkdir -p "$tmp/pos-noeol/tests"
  printf 'INV-X-001\ttests/run-tests.sh\tMUST\tTOTAL_ESPERADO=614' > "$tmp/pos-noeol/invariants.tsv"   # SIN \n final, adrede
  printf 'TOTAL_ESPERADO=615\n' > "$tmp/pos-noeol/tests/run-tests.sh"

  local pos_hits neg_hits pos_shift_hits pos_noeol_hits
  pos_hits="$(_total_esperado_derivado_scan "$tmp/pos" | wc -l | tr -d ' ')"
  neg_hits="$(_total_esperado_derivado_scan "$tmp/neg" | wc -l | tr -d ' ')"
  pos_shift_hits="$(_total_esperado_derivado_scan "$tmp/pos-shift" | wc -l | tr -d ' ')"
  pos_noeol_hits="$(_total_esperado_derivado_scan "$tmp/pos-noeol" | wc -l | tr -d ' ')"

  local fail=0
  if [ "$pos_hits" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO no se cazó (0 desfases; se esperaba >=1) — el detector nunca dispara, es decoración." >&2
    fail=1
  else
    echo "self-test positivo: OK ($pos_hits desfase(s) cazado(s), esperado >=1)"
  fi
  if [ "$neg_hits" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO cazó $neg_hits desfase(s) sobre valores coincidentes (esperado 0) — el detector dispara siempre, es decoración." >&2
    fail=1
  else
    echo "self-test negativo: OK (0 desfases sobre valores coincidentes, como se esperaba)"
  fi
  if [ "$pos_shift_hits" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO [columna desplazada] no se cazó — el doble-tab sigue desplazando must_col en silencio (fail-open real, TAL-5172 v9)." >&2
    fail=1
  else
    echo "self-test positivo [columna desplazada]: OK ($pos_shift_hits desfase(s) cazado(s) pese al doble-tab, esperado >=1)"
  fi
  if [ "$pos_noeol_hits" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO [sin salto de línea final] no se cazó — la última línea del tsv se está descartando (TAL-5172 v9)." >&2
    fail=1
  else
    echo "self-test positivo [sin salto de línea final]: OK ($pos_noeol_hits desfase(s) cazado(s) en la última línea sin \\n, esperado >=1)"
  fi
  return "$fail"
}

mode=check
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) mode=self-test ;;
    --root) root="${2:?--root requiere argumento}"; shift ;;
    *) echo "argumento no reconocido: $1 (uso: --self-test | --root <dir-del-skill>)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$mode" = "self-test" ]; then
  _self_test
  exit $?
fi

[ -n "$root" ] || root="$(cd "$HERE/.." && pwd)"   # default: este skill
[ -d "$root" ] || { echo "no existe el directorio: $root" >&2; exit 2; }

out="$(_total_esperado_derivado_scan "$root")"
if [ -n "$out" ]; then
  echo "$out" >&2
  echo "DESFASE(S) DETECTADO(S): el ratchet TOTAL_ESPERADO de dos capas NO cuadra." >&2
  exit 1
fi
echo "OK: invariants.tsv y el/los fichero(s) de tests coinciden en TOTAL_ESPERADO (dos capas sincronizadas)."
exit 0
