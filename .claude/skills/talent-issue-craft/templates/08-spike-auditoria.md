<!-- issue-craft:v1 type=spike-auditoria variant=none madurez=despachable -->
<!-- Plantilla 08-spike-auditoria · variante única: none · barrido de investigación/auditoría DIFF-CERO: produce hallazgos e issues de remediación, nunca fixes -->
<!-- Defaults del tracker: etiqueta de tipo "spike-auditoria" · estimate 3-5 · prioridad según ventana · calibre gold: 4-5k chars -->

# {Auditar/Investigar} {qué superficie o pregunta} ({dónde})

## Contexto y origen

[2-4 frases: qué incertidumbre o riesgo motiva el barrido, quién consumirá los hallazgos, qué fase o decisión desbloquea.]
**Origen**: [link adjunto — incidente / hallazgo de revisión / decisión con fecha. El detalle de la decisión vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[comando que demuestra el estado actual de la superficie]` → [salida esperada]
  - `[comando de estado limpio del árbol]` → [vacío — contra esto se mide la frontera diff-cero]

## Anclas de contexto

- `[ruta/del/area-a-auditar]` — [qué es] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/de/reporte-de-spike-previo]` — el formato de entregable a REPLICAR, si existe

## Alcance

### Incluye

- Responder las preguntas numeradas del barrido con evidencia (path:línea o salida de comando)
- Crear las issues de remediación de los hallazgos, agrupadas por vehículo
- Entregar el reporte en el formato prescrito

### Fuera de alcance

- ❌ Corregir CUALQUIER hallazgo → issues hijas creadas por esta misma issue
- ❌ [superficie vecina excluida] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| Umbral de severidad que amerita issue hija | [p. ej. 🔴 siempre; 🟡 solo si cabe en un vehículo ya abierto] | [persona] | [fecha] |
| Regla de agrupación de hallazgos | por VEHÍCULO de implementación: mismos archivos = misma issue | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|
| Prioridad de remediación de las hijas | [responsable] | al leer el reporte | No | las hijas nacen sin prioridad final |

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- ÚNICAMENTE el reporte ([comentario del tracker | `ruta/del/reporte.md` si el perfil aloja reportes en el árbol]) + issues nuevas en el tracker
- Código/config/datos: NADA — ver Frontera DIFF-CERO

## Invariantes que NO deben cambiar

- TODO el árbol de trabajo (el barrido es de solo lectura) — lo prueba: `[comando de estado del árbol]` → vacío al entregar
- Entornos reales intocados: si el barrido ejecuta algo, SOLO lecturas idempotentes [contra el entorno que el perfil permita]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Baseline: lo que YA se sabe

Anti-falsos-positivos: lo listado aquí NO se re-descubre ni se reporta como hallazgo.

### Confirmado que funciona (NO re-implementar ni re-auditar)

- [pieza ya verificada] — evidencia: [issue/PR/reporte previo con fecha]

### Lo que NO es hallazgo (deliberado)

- [comportamiento que parece defecto pero es decisión registrada] — registrado en: [link a la decisión]

## Preguntas a responder / alcance del barrido

Inventario DINÁMICO por comando — nunca conteos fijos: `[comando find/grep que enumera las unidades a auditar]` → ≈N unidades al planificar; re-correr al arrancar y auditar la lista VIVA.

1. [Pregunta 1 — cerrada y verificable sobre CADA unidad del inventario]
2. [Pregunta 2]
3. [Pregunta 3 — cada respuesta con evidencia path:línea o salida de comando]

## Frontera DIFF-CERO

Esta issue produce hallazgos y CREA issues de remediación; NO se corrige nada aquí — el único diff permitido es el reporte. Un fix "rápido de paso" invalida la entrega: rompe la trazabilidad hallazgo→issue y mezcla revisión con cambio.

## Formato del entregable (prescrito)

- Resumen ejecutivo: ≤5 líneas.
- Tabla de hallazgos, una fila por hallazgo:

| # | Severidad | Ubicación | Hallazgo | Issue creada |
|---|---|---|---|---|
| [n] | [🔴/🟡] | [path:líneas] | [1 línea] | [link — o "descartado: razón"] |

- Cada issue hija usa la plantilla de SU tipo y es AUTOSUFICIENTE (baseline, anclas y DoD propios — nunca "ver el reporte").
- Anti-atomización: agrupar por VEHÍCULO de implementación — mismos archivos = misma issue; nunca una issue por hallazgo.

## Criterios de aceptación / DoD

- [ ] Las [N] preguntas del barrido respondidas con evidencia (path:línea o salida de comando por respuesta)
- [ ] Diff-cero verificado literalmente: `[comando de estado del árbol]` → [vacío / solo el reporte]
- [ ] La fase siguiente puede configurarse SIN decisiones nuevas: cada hallazgo accionable tiene issue hija o descarte razonado en el reporte
- [ ] Cada issue hija pasa el gate de despachabilidad de su plantilla (o nace `placeholder` si es de horizonte lejano)

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Preguntas respondidas | reporte con citas verificables por respuesta |
| Diff-cero | salida literal del comando de estado al momento de entregar |
| Issues hijas | links + marcador de tipo válido en cada una |

## Brief del ejecutor

- Conocimiento previo a cargar: [guías del repo sobre la superficie auditada + reporte de spike previo si existe]
- Patrón a REPLICAR: [formato del reporte previo] (prohibido inventar formato nuevo)
- Límites duros: NO corregir hallazgos; NO tocar código/config/datos; NO resolver decisiones no selladas.
- Presupuesto de cambio: 0 archivos de código — cualquier diff fuera del reporte es violación de frontera.
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: S5 sobre el reporte (responder lo preguntado, no ampliar el barrido) · M/S/O/Q aplican a las issues HIJAS, no a esta
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan lista el inventario por comando y el orden del barrido
- Revisor del entregable: formato prescrito completo + frontera diff-cero verificada + hijas despachables
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [el de estado limpio del árbol — no hay build: no hay diff de código]
- Régimen de cierre: cierre manual con evidencia (reporte entregado + issues hijas enlazadas) — o PR solo-reporte si el perfil aloja reportes en el árbol, o cierre vía PR padre si esta pieza va en tren (ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09)
- Post-cierre: la priorización de las issues hijas queda con [responsable] (decisión diferida, no bloquea)
- PARAR y escalar si: el barrido revela un riesgo activo urgente/explotable — se escala AL MOMENTO, sin esperar al reporte completo

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Lo diferencial del tipo, bien hecho:
  - Baseline "lo que YA se sabe": «el endpoint de salud sin límite de tasa es decisión
    registrada (link)» — el auditor no lo re-reporta: cero falsos positivos.
  - Inventario dinámico: «grep -rln "publica: true" rutas/ → ≈9 al planificar, verificar
    en vivo» — si aparece una décima unidad, entra sola al barrido.
  - Frontera: el ejecutor tentado de arreglar "esa validación de una línea" la reporta
    como hallazgo con issue hija; el diff de la entrega queda en cero.
  - Entregable: 9 hallazgos → 3 issues agrupadas por archivo (vehículo), cada una
    autosuficiente y despachable sin leer el reporte.

  Por qué es gold: la fase siguiente se configura SIN decisiones nuevas ni re-descubrir
  nada; el conocimiento queda en issues ejecutables, no en prosa suelta.
-->
