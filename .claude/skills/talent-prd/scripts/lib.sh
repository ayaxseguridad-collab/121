#!/usr/bin/env bash
# shellcheck disable=SC2034  # las PRD_* se rellenan aqui y las consumen los llamadores que sourcean
# lib.sh — utilidades compartidas de talent-prd. Se carga con `source`, no se ejecuta suelta.
#
# Contrato: bash + coreutils + grep/awk/sed. Cero red, cero dependencias del repo
# de origen. Todas las funciones soportan rutas CON espacios (comillas siempre).

# morir <mensaje> — error de precondicion (uso, fichero ausente): rc 2 en el llamador
morir() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# pr_leer_cabecera <prd.md> — parsea la primera linea machine-readable.
# Exporta PRD_ESTADO PRD_VERSION PRD_SUPERSEDES PRD_APPETITE. rc 1 si falta o esta malformada.
pr_leer_cabecera() {
  local f="$1" linea
  PRD_ESTADO=""; PRD_VERSION=""; PRD_SUPERSEDES=""; PRD_APPETITE=""
  linea="$(head -n 1 "$f")" || return 1
  # el formato es exacto a proposito: una cabecera "casi bien" es una cabecera rota
  if ! printf '%s' "$linea" | grep -Eq '^<!-- prd: estado=(DRAFT|APPROVED) version=[^ ]+ supersedes=[^ ]+ appetite=(lite|estandar|completo) -->$'; then
    return 1
  fi
  PRD_ESTADO="$(printf '%s' "$linea" | sed -E 's/.* estado=([^ ]+).*/\1/')"
  PRD_VERSION="$(printf '%s' "$linea" | sed -E 's/.* version=([^ ]+).*/\1/')"
  PRD_SUPERSEDES="$(printf '%s' "$linea" | sed -E 's/.* supersedes=([^ ]+).*/\1/')"
  PRD_APPETITE="$(printf '%s' "$linea" | sed -E 's/.* appetite=([^ ]+) .*/\1/')"
  return 0
}

# pr_sin_fences <fichero.md> — imprime el markdown SIN los bloques de codigo
# cercados (```): un heading o un criterio dentro de un ejemplo no es contenido
# del documento y no debe satisfacer (ni romper) ninguna comprobacion.
pr_sin_fences() { awk '/^[[:space:]]*```/{dentro=!dentro; next} !dentro' "$1"; }

# pr_listar_h2 <prd.md> — imprime todos los H2 reales (fuera de fences)
pr_listar_h2() { pr_sin_fences "$1" | grep -E '^## ' || true; }

# pr_seccion <prd.md> <titulo-exacto> — imprime el cuerpo de la seccion '## N. <titulo>'
# (desde el heading exclusive hasta el siguiente '## ' real o EOF). Vacio si no existe.
pr_seccion() {
  local f="$1" titulo="$2"
  pr_sin_fences "$f" | awk -v t="$titulo" '
    /^## /{
      if (dentro) exit
      if ($0 ~ ("^## [0-9]+\\. " t "$")) { dentro=1; next }
    }
    dentro { print }
  '
}

# pr_tiene_seccion <prd.md> <titulo-exacto> — rc 0 si existe '## N. <titulo>' real.
# grep SIN -q a proposito: -q corta al primer match y bajo pipefail el SIGPIPE del
# productor daria falso-rojo (clase anti-SIGPIPE); >/dev/null consume todo el flujo.
pr_tiene_seccion() { pr_sin_fences "$1" | grep -E "^## [0-9]+\. $2\$" >/dev/null; }

# pr_rango_nivel <lite|estandar|completo|L|E|C> — imprime 1, 2 o 3
pr_rango_nivel() {
  case "$1" in
    lite|L) echo 1 ;;
    estandar|E) echo 2 ;;
    completo|C) echo 3 ;;
    *) return 1 ;;
  esac
}

# pr_superset — la tabla canonica de 27 secciones: 'nivel<TAB>nombre' por linea.
# Misma tabla que references/03-documento-y-plantillas.md seccion 2 — si cambia
# una, cambia la otra (lo vigila una invariante).
pr_superset() {
  cat <<'TABLA'
L	Resumen y pitch
L	Problema y persona
L	Wedge
L	Alcance del appetite
L	Historias de usuario
L	Criterios de aceptacion
L	No-gos
L	Fases walking-skeleton
L	Riesgos y premisas
E	Landscape
E	Interrogatorio sellado
E	Alternativas A B C
E	Metricas de exito
E	Flujo principal
E	Requisitos no funcionales
E	Dependencias y limites
E	Decisiones clasificadas
E	Plan de validacion
C	Casos de uso formales
C	Diagrama actores-modulos
C	Modelo de entidades
C	Version 10-estrellas
C	Estados y errores
C	Seguridad y privacidad
C	Operacion y despliegue
C	Presupuesto y costes
C	Glosario
TABLA
}
