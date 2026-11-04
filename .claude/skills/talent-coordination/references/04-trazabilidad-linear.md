# Trazabilidad en Linear — Complete Reference

## Table of Contents

1. [Reglas duras](#1-reglas-duras)
2. [Ciclo de estados](#2-ciclo-de-estados)
3. [Comentarios que valen: decisiones y evidencia](#3-comentarios-que-valen-decisiones-y-evidencia)
4. [Ventanas de lanzamiento (olas por flags)](#4-ventanas-de-lanzamiento-olas-por-flags)
5. [Cierre de épicas y captura de deuda](#5-cierre-de-epicas-y-captura-de-deuda)
6. [Gotchas & Cross-References](#6-gotchas--cross-references)

---

## 1. Reglas duras

- **Issue ANTES de tocar código** — sin excepciones, incluido el hotfix (30
  segundos de issue no frenan nada). Lectura/preguntas no son "trabajo".
- **Dedupe antes de crear** (query `issues` vía API directa); milestones se
  LISTAN antes de crear uno nuevo.
- **Toda issue de despacho lleva**: labels completos (equipo + actor + kind +
  area + vertical según taxonomía del workspace), estimate, project (+
  milestone si aplica — pasarlos JUNTOS en la misma mutación), y relaciones
  (`blocks`) cuando una pieza bloquea otra.
- **Los nombres de estado fallan en silencio** si no matchean exactamente los
  del team — verificar la taxonomía real una vez y reutilizarla.
- **Labels en update REEMPLAZAN**: para añadir una, mandar el array COMPLETO
  (leer las actuales primero).

## 2. Ciclo de estados

```text
Backlog ──(despacho)──► In Progress ──(PR abierto)──► In Review
   ▲                                                      │
   │ (captura de deuda:                     (merge con magic word
   │  nace en Backlog,                        `closes/fixes TAL-X`)
   │  espera GO del lead)                                 ▼
   └──────────────────────────────────────────────────── Done
                                                          ▲
                       (cierres manuales SOLO con comentario-evidencia)
```

- `closes TAL-X` en el body del PR = cierre automático al merge (la vía
  preferida; trazado completo In Progress → In Review → Done).
- Trabajos multi-paso con acción externa post-merge → `Refs TAL-X` y cierre
  manual con evidencia cuando la acción externa termine.
- Si el repo exige BD sync (apply post-merge): la issue NO está "realmente
  cerrada" hasta que el coordinador verifica el apply — aunque el magic word
  la haya movido a Done (verificación → `05-verificacion-independiente.md`).

## 3. Comentarios que valen: decisiones y evidencia

Comentar SOLO decisiones y evidencia (nada de trivialidades). Dos tipos:

**Comentario de decisión** (al tomarla, donde sea que se tomó):

```markdown
**Decisión del lead (2026-06-12):** en tablet cede el badge PRO (no la racha).
Motivo: presupuesto del header a 1024px (732px útiles vs 1060px de maxes).
```

Este comentario es lo que permite NO re-preguntar después: decisión
registrada = decisión sellada (un gate posterior la cita en vez de re-abrirla).

**Comentario-evidencia** (cierres): ver plantilla en `../prompts/plantillas.md`.
La regla: cada número del comentario salió de un comando ejecutado al
escribirlo; los adjetivos no son evidencia.

## 4. Ventanas de lanzamiento (olas por flags)

Patrón para features detrás de feature flags (global × por-unidad):

```text
Issue de OLA con checklist:
1. Pre-flight (flags OFF verificados + dependencias mergeadas + deploy vivo)
2. Llave global ON (admin-dark: gates abiertos, nada visible)
3. Llave por-unidad ON ← LA GIRA EL LEAD (el coordinador se la pide explícita)
4. Smoke post-encendido (cuenta controlada + proyección de afectados reales)
5. OBSERVACIÓN 24h (la ventana) — tracción medida, incidencias escuchadas
6. Cierre de ventana: comentario-evidencia + Done
Rollback documentado en la issue: llave por-unidad OFF (segundos)
```

- Encender = LANZAMIENTO (usuarios reales lo ven), jamás QA.
- El lead puede ordenar cierre anticipado de la ventana → se cierra,
  documentando "cierre anticipado por orden del lead con Xh de observación".
- Incidencia visual durante la ventana → decisión de EXPOSICIÓN del lead
  (ON mientras se arregla / OFF hasta el fix) — ver `07-incidentes-y-caliente.md`.

## 5. Cierre de épicas y captura de deuda

**Épicas**: se cierran a mano (no hay magic word que las cierre) con
comentario-evidencia: tabla pieza→issue→PR→estado en prod + verificación del
lead si la hubo (citarla textual: «todo ok»).

**Deuda**: todo hallazgo no bloqueante con acción futura definida se CAPTURA
como issue en Backlog en el momento (contexto completo, criterios, y si es
destructiva: "NO ejecutar sin GO explícito del lead" en negrita). Deuda no
capturada = deuda perdida. Lo ya gestionado por otra vía NO se duplica
(un follow-up que repite un pendiente del lead se contesta, no se re-captura).

## 6. Gotchas & Cross-References

1. **El magic word solo funciona si la integración GitHub↔Linear está viva**
   → Verificar el Done real con la query `issue` post-merge, no asumirlo.

2. **Issues "por si acaso" ensucian** → Se captura deuda real con acción
   definida; las ideas vagas van a la conversación con el lead, no al Backlog.

3. **El comentario de cierre de ventana incluye lo que NO pasó** → "Rollback
   disponible (no usado)" y "cero incidencias (confirmación del lead)" son
   datos, no relleno.

4. **Citas textuales del lead en las specs** → La necesidad original entre
   comillas en el Contexto de la épica elimina discusiones de interpretación.

Cross-references: anatomía completa de la issue de despacho →
`02-planificacion-y-despacho.md` §5 · plantillas → `../prompts/plantillas.md`.
