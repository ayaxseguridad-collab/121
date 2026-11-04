<!-- issue-craft:v1 type=refactor variant=none madurez=despachable -->
<!-- Plantilla 05-refactor · variantes: none (único token admitido para este tipo) -->
<!-- Defaults del tracker: etiqueta de tipo "refactor" · estimate 2-5 (umbrella coordinadora: sin estimate) · prioridad según ventana · calibre gold: 4-14k chars -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué zona del código duele, a quién frena hoy y qué habilita ordenarla.]
**Origen**: [link adjunto — hallazgo de revisión / auditoría / decisión con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[suite existente que cubre la zona]` → [verde, N tests]
  - `[comando que mide el estado actual — duplicación/tamaño/tiempo]` → [cifra actual]

## Anclas de contexto

- `[ruta/al/modulo-a-reestructurar:L1-L2]` — [qué es y por qué duele] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/al/patron-destino]` — la forma canónica a la que converge el código

## Alcance

### Incluye

- [unidad de código a reestructurar — lista cerrada]
- [tests de caracterización que fijan su comportamiento actual]

### Fuera de alcance

- ❌ [cualquier cambio de comportamiento observable] → [issue destino]
- ❌ [zona vecina que también duele] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. patrón destino, frontera del módulo] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [paths que se reestructuran]
- [paths de los specs de caracterización nuevos]

## Invariantes que NO deben cambiar

- [flujo vecino que queda INTACTO] — lo prueba: [suite/spec concreta]
- [decisión ya integrada que se respeta] — referencia: [PR/commit]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Motivación con evidencia

- Qué duele HOY, medido: `[comando reproducible]` → [cifra — duplicación, tamaño, tiempo, densidad de defectos de la zona]
- Coste de no actuar: [qué trabajo encarece o qué clase de defecto facilita esta forma del código]

## Invariantes preservadas (nombradas una a una)

Contrato de comportamiento del código refactorizado — sección DISTINTA de "Invariantes que NO deben cambiar": aquella protege a los vecinos; esta enumera lo que el código MOVIDO debe seguir haciendo exactamente igual.

| # | Invariante preservada | La fija |
|---|---|---|
| P1 | [firmas/interfaz pública sin cambios: nombres, parámetros, retornos] | [test de caracterización] |
| P2 | [semántica de acceso/permisos idéntica, incluidas las denegaciones] | [test negativo] |
| P3 | [semántica de errores/reintentos idéntica: mismos fallos, mismo orden de efectos] | [test del camino de fallo] |
| P4 | [idempotencia de operaciones repetibles] | [test que ejecuta dos veces] |

## Caracterización previa — GATE BLOQUEANTE

- Tests que fijan el comportamiento ACTUAL (el observado, incluso el feo): [casos → paths de specs]
- Escritos y VERDES antes de la primera extracción — bloquean todo el resto del trabajo.
- `[comando de la suite de caracterización]` → verde sobre el código SIN tocar (evidencia pegada al arrancar)
- PROHIBIDO modificarlos durante el refactor: si un test de caracterización "estorba", la premisa está rota — PARAR y escalar.

## Plan de extracción

- Paso 1: [movimiento pequeño y verificable] → verificación: [comando + caracterización verde]
- Paso 2: [siguiente movimiento] → verificación: [ídem]
- Paso N: [limpieza final — borrar lo que quedó sin consumidores] → verificación: [ídem]
- Si el plan excede el presupuesto del brief: convertir en umbrella + sub-issues (una por paso). PROHIBIDA la PR monolítica.

## Métrica antes/después

- Métrica que motiva el refactor: [líneas duplicadas / tamaño del módulo / complejidad / tiempo de build]
- `[comando de medición]` → ANTES: [cifra] · DESPUÉS (objetivo): [cifra]
- Ambas cifras se producen en esta issue, sobre el MISMO entorno/build — nunca cifras históricas ni de otra máquina.

## Riesgo de regresión y su red

- Riesgo principal: [qué puede romperse al mover — import implícito, orden de efectos, estado compartido]
- Red que lo detecta: caracterización previa + [suites existentes nombradas]
- Señal de aborto: [condición que obliga a parar y replantear — p. ej. un paso exige cambiar comportamiento]

## Criterios de aceptación / DoD

- [ ] Suite de caracterización VERDE antes de la primera extracción (evidencia con commit y fecha)
- [ ] La MISMA suite, sin un solo edit, VERDE sobre el commit final (diff de los specs de caracterización: vacío)
- [ ] `[comando de métrica]` ANTES y DESPUÉS del mismo build, pegados — la métrica declarada BAJA
- [ ] Cero cambio de comportamiento observable: [suites existentes nombradas] verdes
- [ ] Diff acotado a "Artefactos tocados" (verificado sobre la PR)

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Caracterización antes/después | salidas literales de la suite en ambos momentos, misma suite sin edits |
| Métrica antes/después | salida literal del comando en ambos momentos, mismo entorno/build |
| [resto de checkboxes] | salida literal sobre el commit final / run de checks |

## Brief del ejecutor

- Conocimiento previo a cargar: [guías del repo según artefactos tocados]
- Patrón a REPLICAR: `[ruta/al/patron-destino]` (prohibido inventar estructura nueva)
- Orden obligatorio: caracterización verde PRIMERO; después extraer en pasos pequeños. Nunca "mover todo y ver qué pasa".
- Límites duros: NO cambiar comportamiento observable; NO tocar [X]; NO añadir dependencias; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M + S + O7 + Q8 · Matrices: según superficie tocada
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: la caracterización existe como gate BLOQUEANTE antes de cualquier extracción; el plan es una secuencia de pasos pequeños verificables, no un big-bang
- Revisor de código: 5 dimensiones §8 — extra del tipo: S1 aplicado al RESULTADO (el refactor debe REDUCIR la métrica declarada, no mover el problema de sitio); caracterización idéntica antes/después
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR); si es umbrella: cierra al fusionar la última sub-issue — (si esta pieza va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09; nunca PR individual)
- Post-fusión: [pasos si aplican]
- PARAR y escalar si: [la caracterización exige un edit / la métrica no baja / un paso requiere cambiar comportamiento]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Caracterización previa (lo diferencial del tipo): 14 tests fijan el comportamiento
  ACTUAL de una consulta duplicada en tres pantallas (mismos filtros, mismo orden,
  mismas denegaciones de acceso) — verdes sobre el código sin tocar ANTES del
  primer movimiento, y sin un solo edit hasta el final.
  Métrica antes/después (mismo build): líneas duplicadas del dominio 412 → 96;
  la suite afectada pasa de 41 s a 39 s (sin regresión de tiempo).
  Plan de extracción: 4 pasos, cada uno con la caracterización en verde; el último
  borra las tres copias ya sin consumidores. Umbrella con una sub-issue por paso.

  Por qué es gold: la caracterización convierte "no cambia el comportamiento" en un
  comando repetible, y la métrica del MISMO build prueba que el refactor REDUCE
  (S1 al resultado), no que movió el problema de sitio.
-->
