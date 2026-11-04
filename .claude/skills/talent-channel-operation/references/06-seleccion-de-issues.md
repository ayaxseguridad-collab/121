# 06 — Selección de issues

`select-issues.sh` lee un milestone (o lista explícita) de Linear, aplica el criterio y ordena
la cola que el **coordinador** revisa antes de despachar (a mano, de uno en uno).

## Table of Contents

- [1. Principio: selección ≠ arranque](#1-principio-selección--arranque)
- [2. Fuente de entrada de reportes: SOLO Linear](#2-fuente-de-entrada-de-reportes-solo-linear)
- [3. Criterio de selección](#3-criterio-de-selección)
- [4. Orden de la cola](#4-orden-de-la-cola)
- [5. Carga de contexto](#5-carga-de-contexto)

## 1. Principio: selección ≠ arranque

Seleccionar y ordenar la cola **no** arranca trabajo. Un issue solo entra a un carril cuando:

1. Está en la cola ordenada, **y**
2. Pasa el **gate pre-issue [B4]** (`preflight-issue.sh`: working tree limpio +
   `main` al día), **y**
3. Hay un carril de desarrollo libre dentro del cap `TCO_MAX_ACTIVE`.

Si el gate pre-issue falla (p. ej. carril con working tree sucio o desactualizado), el issue
**no arranca** y se escala — no se arregla en caliente.

## 2. Fuente de entrada de reportes: SOLO Linear

Los reportes de usuarios entran **exclusivamente por Linear** (decisión del lead, 2026-07-02):

- La selección consulta **solo Linear**. Ningún panel de bugs del backend es fuente de trabajo
  ni evidencia de cierre — el detalle del panel que NO se usa en este repo está en
  `anexo-bootcamp-cripto.md` §4.
- Los bugs que llegan por canales externos (WhatsApp, email, soporte) entran por el inbox de
  triage mensual antes de moverse al proyecto destino (gestión obligatoria vía Linear — en Academia Ejemplo: regla 21 del CLAUDE.md).
- Si durante una corrida aparece señal de bug fuera de Linear, el coordinador la presenta al
  lead; solo con su autorización se crea el issue (ref 07: los carriles nunca crean issues).

## 3. Criterio de selección

- **Initiative + project**: issues del milestone/lista que pertenezcan a la **initiative del
  repo** (gestión obligatoria vía Linear — en Academia Ejemplo: regla 21 del CLAUDE.md). Issues fuera de la initiative no entran.
- **Estado**: candidatos que el coordinador puede mover a "In Progress"
  (`TCO_LINEAR_INPROGRESS_STATE`) al despachar.
- **Independencia**: priorizar issues sin dependencias bloqueantes entre sí, para poder
  paralelizar carriles sin colisiones de merge.
- **Tamaño**: issues que se subdividan en **>3 sub-tareas** deberían venir ya descompuestos en
  sub-issues (gestión Linear — en Academia Ejemplo: regla 21 del CLAUDE.md — + guía Linear operativa del repo); preferir piezas mergeables de forma
  autónoma.
- **Sin cambio irreversible esperado** en cola autónoma: si un issue presume un cambio de
  producción irreversible (borrado de datos, un paso post-merge que puede romper producción —
  según el **anexo del repo**), marcar para **escalado** (no se mergea solo).

## 4. Orden de la cola

- Dependencias primero (un issue base antes que el que lo consume).
- Dentro del mismo nivel, ordenar por prioridad Linear y luego por menor superficie de cambio
  (menos probabilidad de conflicto en merges serializados).

## 5. Carga de contexto

El despacho (`dispatch.sh`) inyecta al equipo de desarrollo el contexto del issue obtenido vía
`linear-skill` (token directo, NO MCP): título, descripción, criterios de aceptación, labels
`vertical/*`. El coordinador no fabrica scope: solo lo que está en el issue.
