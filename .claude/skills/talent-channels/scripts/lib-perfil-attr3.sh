#!/usr/bin/env bash
# lib-perfil-attr3.sh — envoltura de TRES valores sobre `perfil_attr` (talent-ceo/scripts/lib-perfil.sh,
# MIEMBRO AJENO), lectura de atributos para el reparto.
#
# [PASO0-CH82-b2.md, 2026-09-21] Esta primitiva vivió una ronda en `talent-ceo/scripts/lib-perfil.sh`
# y se reubica AQUÍ, dentro de `talent-channels`, porque el miembro ajeno tiene su propia rama
# tocando `lib-perfil.sh` por el mismo eje — dos ramas modificando el mismo fichero ajeno chocan en
# la integración. `perfil_attr` (dos valores: rc 0 + valor · rc 1) NO se toca: sigue siendo la
# interfaz ESTABLE del miembro ajeno, que la sigue usando libremente porque es SU primitiva.
#
# Requiere que `perfil_attr` YA esté cargada en el entorno (sourcear `lib-perfil.sh` ANTES que este
# fichero). No la sourcea por sí misma para no asumir la ruta del miembro ajeno: cada consumidor ya
# resuelve esa ruta con su propio localizador (`rp_lib_perfil` / `rr_lib_perfil`).
#
#   rc 0 = VALOR — la clave existe en la cadena de atributos y su valor NO es la cadena vacía.
#          Imprime el valor por stdout.
#   rc 1 = AUSENTE — `perfil_attr` buscó y la clave no aparece. No imprime nada.
#   rc 2 = NO MEDIDO — cualquiera de: clave no pasada (precondición del propio llamador, verificable
#          desde este lado sin ayuda de `perfil_attr`) · cadena de atributos vacía o sin un solo
#          `=` (malformada: no puede contener ningún par clave=valor válido) · clave encontrada con
#          valor vacío (`clave=;` o `clave=` al final) · cualquier rc de `perfil_attr` distinto de
#          0 y 1. No imprime nada.
#
# ── LÍMITE CONOCIDO — declarado, no disimulado ────────────────────────────────────────────────
# `perfil_attr` tal como está definida HOY en el miembro ajeno solo devuelve rc 0 o rc 1: no existe
# un tercer código que distinga, DENTRO de una cadena de atributos NO vacía, "la clave no aparece
# entre las que sí están" (caso normal, AUSENTE) de "algo dentro del awk de `perfil_attr` falló de
# forma anómala" (debería ser NO MEDIDO, no AUSENTE). Esta envoltura NO PUEDE cerrar esa distinción
# desde `talent-channels`: requeriría cambiar `perfil_attr` misma, que es el miembro ajeno y está
# fuera de este alcance. Por eso, cuando `perfil_attr` devuelve rc 1, esta función devuelve rc 1
# (AUSENTE) sin más — es fiel al contrato de su dependencia, no finge medir lo que no puede medir
# desde aquí. Cierra esta distinción la issue de la capa de arriba (unificación de `perfil_attr`),
# no esta pieza.
#
# Verificado contra el perfil real (`manifiestos/manifiesto-ejemplo.perfil.tsv`, censo 2026-09-21): NINGUNA
# fila de ningún tipo tiene hoy la columna de atributos genuinamente vacía, así que tratar "cadena
# vacía" como NO MEDIDO (en vez de dejarla caer al AUSENTE que producía la envoltura anterior) no
# cambia el comportamiento de ningún sitio real hoy — es un endurecimiento defensivo para un estado
# que no ocurre todavía en producción, no una regresión medida.
perfil_attr3() {
  local atrs="${1-}" clave="${2-}" valor rc
  [ -n "$clave" ] || return 2
  case "$atrs" in
    *'='*) : ;;
    *) return 2 ;;
  esac
  valor="$(perfil_attr "$atrs" "$clave")"; rc=$?
  case "$rc" in
    0) [ -n "$valor" ] || return 2
       printf '%s\n' "$valor"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
