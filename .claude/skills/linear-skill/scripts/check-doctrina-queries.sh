#!/usr/bin/env bash
# ORACULO DE LA 5.a RONDA (estacion de merge, TAL-5398). Dos clases sobre las consultas que la
# doctrina ENSENA a copiar. Aqui no se arregla nada: se fija lo que el arreglo tiene que producir.
#
# [4] DEDUPE QUE FALLA ABIERTO. La receta de dedupe previa al trabajo tiene que (a) atar el valor
#     por VARIABLE —una consulta con el filtro sin valor no se puede ejecutar tal cual— y (b) decir
#     que si la respuesta trae `errors` se ABORTA. Sin (b), una consulta que falla devuelve vacio y
#     eso se lee como «no hay duplicados»: se crea la issue igual. Es la clase de la noche —un cero
#     por no haber mirado se lee como uno bueno— en la regla 21, que siguen todos los agentes.
#
# [5] VENTANA APLICADA A LA CONSULTA EQUIVOCADA. La VARIANTE SIN CYCLES sustituye el filtro de cycle
#     por una ventana temporal. Si esa ventana es `completedAt` y se aplica a TODAS las consultas,
#     la de issues ABIERTAS —que por definicion no tienen `completedAt`— sale SIEMPRE VACIA, y un
#     informe vacio no se distingue de una semana sin trabajo abierto.
#
# LIMITE DECLARADO, y es grande: estos dos sujetos son PROSA, no codigo. Lo que se puede acreditar
# es que la doctrina DICE lo correcto, no que alguien la cumpla al ejecutarla. Un oraculo de texto
# acredita MENCION; la conformidad solo la acredita ejecutar. Por eso cada caso lleva su control
# negativo: sin el, «el fichero contiene la palabra» pasaria por «la regla esta bien escrita».
#
# Uso:  bash check-doctrina-queries.sh [raiz-del-repo]
# rc 0 = verde · rc 1 = rojo
set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="${1:-$(cd "$AQUI/../../../.." && pwd)}"
SKILL="$AQUI/.."
verdes=0; rojos=0
ok()  { verdes=$((verdes+1)); printf '  ok    %s\n' "$1"; }
bad() { rojos=$((rojos+1));  printf '  ROJO  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (obtuvo=$2 esperaba=$3)"; fi; }

# ── UN CERO POR NO HABER Y UN CERO POR NO PODER LEER SON EL MISMO NUMERO Y DESENLACES OPUESTOS.
# Hallazgo de la 2.a pasada independiente sobre ESTE fichero (TAL-5398): con `CLAUDE.md` a permisos
# 000 el oraculo descubria 2 sujetos en vez de 3 y concluia «10 verdes / 0 rojos, rc 0». La causa no
# era contar: era `2>/dev/null` + `|| true` + `${x:-0}`, que convertian un ERROR en un cero legitimo.
# Es exactamente la clase que este oraculo persigue en otros — ausencia de hallazgos confundida con
# lectura completa de un universo valido — y estaba dentro del instrumento.
#
# rc de grep: 0 = casa · 1 = no casa (vacio LEGITIMO) · >=2 = ERROR. El error no se normaliza.
cuenta() {  # $@ = argumentos de `grep -c`. Imprime el numero, o NO-MEDIDO con su motivo.
  local out rc err
  err="$(mktemp)"; out="$(grep -c "$@" 2>"$err")"; rc=$?
  if [ "$rc" -ge 2 ]; then
    printf 'NO-MEDIDO(%s)' "$(tr -d '\n' < "$err" | cut -c1-60)"; rm -f "$err"; return 0
  fi
  rm -f "$err"; printf '%s' "${out:-0}"
}
# Traduce un conteo a si/no SIN tragarse un NO-MEDIDO: `[ NO-MEDIDO -gt 0 ]` seria un error de
# sintaxis silenciado, o sea, otra vez el mismo fallo.
si_no() { case "$1" in NO-MEDIDO*) printf '%s' "$1" ;; *) [ "$1" -gt 0 ] && printf 'si' || printf 'no' ;; esac; }

# --- [4] dedupe -------------------------------------------------------------------------------
# Las recetas de dedupe se buscan por su predicado, no por el fichero: si manana aparece en otro
# sitio, tiene que cumplir lo mismo. Se listan los ficheros de doctrina que la llevan.
# EL UNIVERSO SE DECLARA Y SE COMPRUEBA LEGIBLE ANTES DE BUSCAR. Descubrir menos sujetos de los que
# hay es el fallo que este mismo oraculo caza en otros: aqui el universo candidato es explicito y
# cada pieza tiene que poder LEERSE, o se declara NO MEDIDO y enrojece.
_cands=("$RAIZ/CLAUDE.md"); for _p in "$SKILL/prompts"/*.md; do [ -e "$_p" ] && _cands+=("$_p"); done
_ileg=0
for _c in "${_cands[@]}"; do
  [ -e "$_c" ] || { bad "NO SE PUEDE MEDIR: falta del universo declarado: ${_c#"$RAIZ"/}"; _ileg=$((_ileg+1)); continue; }
  [ -r "$_c" ] || { bad "NO SE PUEDE MEDIR: no es legible: ${_c#"$RAIZ"/}"; _ileg=$((_ileg+1)); }
done
# El descubrimiento se hace con el rc DELANTE, no dentro de una sustitucion de proceso cuyo estado
# el shell no mira. stderr se conserva: el motivo del fallo es parte de la medida.
_lst="$(mktemp)"; _derr="$(mktemp)"
grep -rl 'containsIgnoreCase' "${_cands[@]}" > "$_lst" 2>"$_derr"; _rcd=$?
if [ "$_rcd" -ge 2 ]; then
  bad "NO SE PUEDE MEDIR: el descubrimiento fallo (rc $_rcd): $(head -1 "$_derr")"
fi
mapfile -t _sujetos < <(LC_ALL=C sort -u "$_lst")
rm -f "$_lst" "$_derr"
printf '  (universo declarado: %d · ilegibles: %d · sujetos con receta de dedupe: %d)\n' \
       "${#_cands[@]}" "$_ileg" "${#_sujetos[@]}"
[ "${#_sujetos[@]}" -gt 0 ] || bad "no se encontro NINGUN sujeto con receta de dedupe (el oraculo no puede medir nada)"

# ── SUJETO OBLIGATORIO: la regla 21 de CLAUDE.md ───────────────────────────────────────────────
# DESCUBRIR POR PATRON HACE QUE EL SUJETO DESAPAREZCA JUSTO CUANDO SE CORRIGE. Si manana alguien
# reescribe la receta sin el literal `containsIgnoreCase`, `CLAUDE.md` sale del conjunto, sus tres
# comprobaciones se van con el y este oraculo sigue diciendo «0 rojos» — con un sujeto MENOS y sin
# que nadie lo note. Es la misma clase que este fichero persigue: un universo que encoge en
# silencio se lee como un universo limpio.
#
# La regla 21 es NORMATIVA y la siguen todos los agentes, asi que no es un sujeto cualquiera: se
# declara OBLIGATORIO. Que salga del conjunto es un HALLAZGO, no una reduccion del alcance.
sujeto_obligatorio() {  # $1 = ruta obligatoria · $2.. = sujetos descubiertos ; imprime si|no
  local obl="$1"; shift
  local x; for x in "$@"; do [ "$x" = "$obl" ] && { printf 'si'; return 0; }; done
  printf 'no'
}
_OBL="$RAIZ/CLAUDE.md"
_presente="$(sujeto_obligatorio "$_OBL" ${_sujetos[@]+"${_sujetos[@]}"})"
chk "[4-obligatorio] la regla 21 de CLAUDE.md esta ENTRE los sujetos medidos" "$_presente" "si"
if [ "$_presente" = "no" ]; then
  # Entra igualmente: sus tres asertos tienen que CORRER y enrojecer, no desaparecer.
  _sujetos+=("$_OBL")
fi
# CONTROL: si el sujeto obligatorio NO estuviera en el conjunto, el oraculo tiene que DETECTARLO.
# Sin este control, el aserto de arriba podria estar verde por una comparacion que nunca falla.
chk "[4-obligatorio-control] quitarla del universo se DETECTA (no pasa en silencio)" \
    "$(sujeto_obligatorio "$_OBL" "$SKILL/prompts/crear-issue.md")" "no"
# ANCLA que sobrevive a una reescritura de la sintaxis de la consulta: la regla 21 tiene que seguir
# teniendo una linea de pre-trabajo con receta de dedupe, se escriba como se escriba la query.
chk "[4-ancla] la regla 21 sigue prescribiendo un dedupe PREVIO al trabajo" \
    "$(si_no "$(cuenta -iE '^[[:space:]]*-[[:space:]]*Pre-trabajo:.*dedupe' "$_OBL")")" "si"

for f in "${_sujetos[@]}"; do
  n="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; n="${n#"$RAIZ"/}"
  # (a) el valor va atado por variable: `containsIgnoreCase: $algo` o `containsIgnoreCase: "..."`.
  #     Un `containsIgnoreCase }` desnudo es una consulta que no se puede ejecutar.
  atado="$(cuenta 'containsIgnoreCase[[:space:]]*:[[:space:]]*[$"]' "$f")"
  suelto="$(cuenta 'containsIgnoreCase[[:space:]]*[}]' "$f")"
  chk "[4a] $n: el valor del dedupe va ATADO (variable o literal)" "$(si_no "$atado")" "si"
  chk "[4b] $n: no queda ningun containsIgnoreCase DESNUDO"        "$suelto" "0"
  # (c) el fallo de la consulta aborta, en vez de leerse como «no hay duplicados»
  aborta="$(cuenta -iE 'abortar si.*errors|si.*errors.*abortar|errors.*(no se crea|abortar|parar)' "$f")"
  chk "[4c] $n: dice que si la respuesta trae errors se ABORTA"    "$(si_no "$aborta")" "si"
done

# CONTROL NEGATIVO de [4]: sobre una copia con la clausula quitada, [4c] TIENE que enrojecer. Sin
# esto, un `grep` que casara siempre daria verde y nadie lo sabria.
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
printf 'dedupe con `containsIgnoreCase: $q`; abortar si la respuesta trae errors.\n' > "$_t/bueno.md"
printf 'dedupe con `containsIgnoreCase: $q`.\n'                                     > "$_t/malo.md"
_cb="$(cuenta -iE 'abortar si.*errors' "$_t/bueno.md")"
_cm="$(cuenta -iE 'abortar si.*errors' "$_t/malo.md")"
chk "[4-control] el predicado distingue el texto con clausula del que no la tiene" \
    "$([ "$_cb" = "1" ] && [ "$_cm" = "0" ] && echo si || echo no)" "si"
# CONTROL DEL CONTROL (el hallazgo de la 2.a pasada, vuelto instrumento fijo): el propio medidor
# tiene que SABER DECIR que no puede medir. Sin esto, la reparacion de arriba no esta protegida y
# el siguiente refactor la reabre.
# EL SUJETO ILEGIBLE NO PUEDE DEPENDER DE LOS PERMISOS DEL QUE CORRE. La primera version usaba
# `chmod 000`, que **root ignora**: en un contenedor que corre como root el fichero se lee igual, el
# medidor devuelve un numero y este control salia ROJO por el ENTORNO, no por un defecto. Un control
# que falla segun quien lo ejecute no acredita nada. Se usa una ruta INEXISTENTE, que da rc 2 para
# root y para cualquiera.
_cx="$(cuenta -c 'x' "$_t/no-existe-jamas.md")"
chk "[4-control-2] el medidor dice NO-MEDIDO ante un sujeto que no puede leer (no un cero)" \
    "$(case "$_cx" in NO-MEDIDO*) echo si;; *) echo "no($_cx)";; esac)" "si"
# CONTROL DEL CONTROL: sobre un fichero que SI existe y es legible, el mismo medidor da un numero.
# Sin esto, un medidor que dijera NO-MEDIDO siempre pasaria el aserto de arriba.
printf 'x\n' > "$_t/legible.md"
chk "[4-control-3] y sobre un sujeto legible SI devuelve un numero" \
    "$(case "$(cuenta -c 'x' "$_t/legible.md")" in NO-MEDIDO*) echo "no";; *) echo si;; esac)" "si"

# --- [5] ventana de la variante sin cycles ----------------------------------------------------
WR="$SKILL/prompts/weekly-report.md"
if [ -f "$WR" ]; then
  # La variante NO puede mandar sustituir el filtro en TODAS las queries por una ventana de
  # `completedAt`: la de abiertas no tiene ese campo.
  todas="$(cuenta -E 'sustituir en TODAS las queries.*completedAt|en TODAS las queries de abajo' "$WR")"
  distingue="$(cuenta -iE 'completedAt.*(solo|unicamente).*completad|abiertas.*(updatedAt|createdAt)|(updatedAt|createdAt).*abiertas' "$WR")"
  chk "[5a] weekly-report: la variante DISTINGUE la ventana de completadas de la de abiertas" \
      "$(si_no "$distingue")" "si"
  chk "[5b] weekly-report: no aplica una ventana unica a TODAS las queries" "$todas" "0"
  # CONTROL POSITIVO: el fichero SI habla de completadas — si no, [5a] podria estar verde por vacio.
  chk "[5-control] el sujeto habla de issues completadas (no esta midiendo un fichero vacio)" \
      "$(si_no "$(cuenta -i 'completad' "$WR")")" "si"
else
  bad "[5] no existe $WR — el oraculo no puede medir"
fi

printf '  --- ambito: %d verde(s), %d rojo(s) ---\n' "$verdes" "$rojos"
[ "$rojos" -eq 0 ]
