#!/usr/bin/env bash
# verificar-prd.sh — conformidad MECANICA de un artefacto PRD. SOLO LECTURA por contrato.
#
#   uso: verificar-prd.sh <dir-producto> [--codigo <dir-repo>]
#
# El dir-producto contiene prd.md y, opcionalmente, wayfinder/ y backlog.md.
# Comprueba FORMA (cabecera, numeracion, pass/fail, wayfinder, backlog, as-is);
# el contenido lo juzga la review adversarial (references/04), no este script.
# Con --codigo, verifica que TODO lo citado entre backticks en la seccion 'As-is
# del codigo' existe como ruta bajo ese repo (modo brownfield, references/02
# seccion 3): en esa seccion los backticks son SOLO para rutas, por convencion.
#
# Salida: '  OK    <check>' / '  FALLO <check> — <motivo>' / '  OMIT  <check>'.
# rc: 0 = todo OK · 1 = algun FALLO · 2 = precondicion (uso, dir ausente).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DIR="${1:-}"; CODIGO=""
[ $# -ge 1 ] || { morir "uso: verificar-prd.sh <dir-producto> [--codigo <dir-repo>]"; exit 2; }
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --codigo) CODIGO="${2:-}"; [ -n "$CODIGO" ] || { morir "--codigo exige un directorio"; exit 2; }; shift 2 ;;
    *) morir "argumento desconocido: $1"; exit 2 ;;
  esac
done
[ -d "$DIR" ] || { morir "dir-producto no existe: $DIR"; exit 2; }
[ -z "$CODIGO" ] || [ -d "$CODIGO" ] || { morir "--codigo no existe: $CODIGO"; exit 2; }

PASA=0; FALLA=0
ok()   { printf '  OK    %s\n' "$*"; PASA=$((PASA+1)); }
mal()  { printf '  FALLO %s\n' "$*"; FALLA=$((FALLA+1)); }
omit() { printf '  OMIT  %s\n' "$*"; }

PRD="$DIR/prd.md"
echo "==== verificar-prd: $DIR ===="

# --- 1. prd.md y cabecera -------------------------------------------------------------
if [ ! -f "$PRD" ]; then
  mal "prd.md — ausente en $DIR"
  echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
  exit 1
fi
ok "prd.md presente"

if pr_leer_cabecera "$PRD"; then
  ok "cabecera machine-readable valida (estado=$PRD_ESTADO version=$PRD_VERSION appetite=$PRD_APPETITE)"
else
  mal "cabecera — la linea 1 no cumple '<!-- prd: estado=DRAFT|APPROVED version=X supersedes=X appetite=lite|estandar|completo -->'"
fi

# --- 2. secciones direccionables: H2 numerados y consecutivos -------------------------
sin_numero="$(pr_listar_h2 "$PRD" | grep -Ev '^## [0-9]+\. ' || true)"
if [ -n "$sin_numero" ]; then
  mal "numeracion — H2 sin numerar: $(printf '%s' "$sin_numero" | head -n 1)"
else
  numeros="$(pr_listar_h2 "$PRD" | sed -E 's/^## ([0-9]+)\..*/\1/')"
  if [ -z "$numeros" ]; then
    mal "numeracion — el documento no tiene ninguna seccion '## N. Titulo'"
  else
    esperado=1; problema=""
    while IFS= read -r n; do
      [ "$n" -eq "$esperado" ] || { problema="se esperaba §$esperado y aparece §$n"; break; }
      esperado=$((esperado+1))
    done <<< "$numeros"
    if [ -n "$problema" ]; then mal "numeracion — no consecutiva: $problema"
    else ok "numeracion consecutiva §1..§$((esperado-1))"; fi
  fi
fi

# --- 3. criterios pass/fail (fuera de bloques de codigo, como los H2) -----------------
if pr_sin_fences "$PRD" | grep -E '^- PASA si:' >/dev/null && pr_sin_fences "$PRD" | grep -E '^- FALLA si:' >/dev/null; then
  ok "criterios pass/fail presentes (PASA/FALLA)"
else
  mal "criterios — falta al menos un par '- PASA si:' / '- FALLA si:' (los ejemplos en fences no cuentan)"
fi

# --- 4. wayfinder (si existe) ---------------------------------------------------------
WF="$DIR/wayfinder"
if [ ! -d "$WF" ]; then
  omit "wayfinder/ no existe (opcional)"
else
  IDX="$WF/INDICE.md"
  if [ ! -f "$IDX" ]; then
    mal "wayfinder — falta INDICE.md"
  else
    wf_mal=0
    while IFS= read -r ficha; do
      base="$(basename "$ficha")"
      [ "$base" = "INDICE.md" ] && continue
      # el frontmatter es el bloque REAL entre el '---' de la linea 1 y el siguiente '---':
      # claves sueltas por el cuerpo no cuentan, y la ficha sin delimitadores es invalida
      if [ "$(head -n 1 "$ficha")" != "---" ]; then
        mal "wayfinder — $base: sin frontmatter (la linea 1 no es '---')"; wf_mal=1; continue
      fi
      # sin '---' de CIERRE el "frontmatter" seria el cuerpo entero: tambien invalida
      if ! tail -n +2 "$ficha" | grep -E '^---$' >/dev/null; then
        mal "wayfinder — $base: frontmatter sin '---' de cierre"; wf_mal=1; continue
      fi
      fm="$(awk 'NR==1{next} /^---$/{exit} {print}' "$ficha")"
      slug="$(printf '%s\n' "$fm" | grep -E '^decision:' | head -n 1 | sed -E 's/^decision:[[:space:]]*//')"
      tipo="$(printf '%s\n' "$fm" | grep -E '^tipo:' | head -n 1 | sed -E 's/^tipo:[[:space:]]*//')"
      estado="$(printf '%s\n' "$fm" | grep -E '^estado:' | head -n 1 | sed -E 's/^estado:[[:space:]]*//')"
      bloqueos="$(printf '%s\n' "$fm" | grep -E '^bloqueos:' | head -n 1 | sed -E 's/^bloqueos:[[:space:]]*//')"
      [ "$slug" = "${base%.md}" ] || { mal "wayfinder — $base: decision '$slug' no coincide con el nombre del fichero"; wf_mal=1; }
      case "$tipo" in research|grilling|prototype|task) : ;; *) mal "wayfinder — $base: tipo invalido '$tipo'"; wf_mal=1 ;; esac
      case "$estado" in abierta|en-curso|resuelta) : ;; *) mal "wayfinder — $base: estado invalido '$estado'"; wf_mal=1 ;; esac
      # bloqueos es una lista YAML de flujo: [] vacia o [slug-a, slug-b] — un escalar como '-' no parsea
      printf '%s' "$bloqueos" | grep -Eq '^\[[^][]*\]$' \
        || { mal "wayfinder — $base: bloqueos debe ser lista YAML ('[]' o '[slug, slug]'), no '$bloqueos'"; wf_mal=1; }
      grep -Fq "($base)" "$IDX" || { mal "wayfinder — ficha sin entrada en el indice: $base"; wf_mal=1; }
    done < <(find "$WF" -maxdepth 1 -name '*.md' -type f | sort)
    # direccion contraria: toda entrada del indice tiene su ficha
    while IFS= read -r enlace; do
      # el indice solo enlaza fichas planas del propio wayfinder: un '/' (p.ej.
      # ../externo.md) escaparia del directorio y se rechaza sin resolverlo
      case "$enlace" in
        */*) mal "wayfinder — el indice enlaza fuera del directorio: $enlace"; wf_mal=1; continue ;;
      esac
      # un symlink pasaria el -f apuntando fuera del wayfinder: se rechaza antes
      if [ -L "$WF/$enlace" ]; then
        mal "wayfinder — el indice apunta a un symlink: $enlace"; wf_mal=1; continue
      fi
      [ -f "$WF/$enlace" ] || { mal "wayfinder — el indice apunta a una ficha ausente: $enlace"; wf_mal=1; }
    done < <(grep -oE '\]\([^)]+\.md\)' "$IDX" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')
    [ "$wf_mal" -eq 0 ] && ok "wayfinder consistente (fichas validas, indice bidireccional)"
  fi
fi

# --- 5. backlog (si existe) -----------------------------------------------------------
BL="$DIR/backlog.md"
if [ ! -f "$BL" ]; then
  omit "backlog.md no existe (opcional)"
else
  if ! head -n 1 "$BL" | grep -Eq '^<!-- backlog:'; then
    mal "backlog — la linea 1 no es la cabecera '<!-- backlog: ... -->'"
  fi
  # mismo filtrado de fences que el prd: un '## B1' de ejemplo en un bloque de
  # codigo no es una issue (ni satisface ni rompe la validacion)
  bloques="$(pr_sin_fences "$BL" | grep -cE '^## B[0-9]+ ·')" || bloques=0
  if [ "$bloques" -eq 0 ]; then
    mal "backlog — sin bloques '## B<n> · titulo'"
  else
    faltas="$(pr_sin_fences "$BL" | awk '
      /^## B[0-9]+ ·/ { if (nb) revisa(); nb=$0; c=0; d=0; s=0; next }
      /^Contexto:/ { c=1 } /^DoD:/ { d=1 } /Surfaced by §[0-9]+/ { s=1 }
      END { if (nb) revisa() }
      function revisa() {
        if (!c) print nb ": falta Contexto:"
        if (!d) print nb ": falta DoD:"
        if (!s) print nb ": falta Surfaced by §N"
      }')"
    if [ -n "$faltas" ]; then
      mal "backlog — $(printf '%s' "$faltas" | head -n 1)"
    else
      ok "backlog conforme ($bloques issues con Contexto/DoD/Surfaced by)"
    fi
  fi
fi

# --- 6. as-is contra el codigo (solo con --codigo) ------------------------------------
if [ -z "$CODIGO" ]; then
  omit "as-is contra codigo (pasa --codigo <repo> en modo brownfield)"
else
  cuerpo="$(pr_seccion "$PRD" "As-is del codigo")"
  if [ -z "$cuerpo" ]; then
    omit "as-is — el PRD no tiene seccion 'As-is del codigo'"
  else
    asis_mal=0; citas=0
    while IFS= read -r ruta; do
      citas=$((citas+1))
      # un componente .. escaparia del repo pasado en --codigo: se rechaza, no se resuelve
      if printf '%s' "$ruta" | grep -Eq '(^|/)\.\.(/|$)'; then
        mal "as-is — ruta con componente .. prohibida: $ruta"; asis_mal=1; continue
      fi
      [ -e "$CODIGO/$ruta" ] || { mal "as-is — ruta citada inexistente en el repo: $ruta"; asis_mal=1; }
    done < <(printf '%s\n' "$cuerpo" | grep -oE '`[^`]+`' | sed 's/`//g' | sort -u)
    if [ "$citas" -eq 0 ]; then
      mal "as-is — la seccion no cita ninguna ruta entre backticks (un as-is sin rutas no es extraccion)"
    elif [ "$asis_mal" -eq 0 ]; then
      ok "as-is — las $citas rutas citadas existen en el repo"
    fi
  fi
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
