<!-- issue-craft:v1 type=db-ops variant=none madurez=despachable -->
<!-- Plantilla 03-db-ops · variantes: solo none (operación pura de base de datos: migración de esquema, backfill, índices, hardening, limpieza) -->
<!-- Defaults del tracker: etiqueta de tipo "db-ops" · estimate 1-5 · prioridad según riesgo · calibre gold: 4-14k chars · operación destructiva/irreversible → GO explícito del responsable ANTES de despachar -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué operación de datos es, por qué ahora, qué valor entrega.]
**Origen**: [link adjunto — hallazgo de validaciones del motor / medición / auditoría, con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>` + registro de migraciones al día contra la rama principal
- Arranque verificado (correr ANTES de planificar):
  - `[consulta/comando de estado]` → [salida esperada que confirma el punto de partida]

## Anclas de contexto

- `[ruta/a/la/migracion-o-funcion-relevante:L1-L2]` — [qué es] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/a/la/migracion-patron]` — el ejemplo canónico a REPLICAR (naming, estructura, permisos)

## Alcance

### Incluye

- [operación 1 — lista cerrada: qué objetos de datos se crean/alteran/pueblan]

### Fuera de alcance

- ❌ [objeto/tabla vecina que "también lo necesitaría"] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. estrategia de backfill por lotes, tamaño de lote] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [archivos de migración nuevos, funciones/consultas tocadas, datos afectados (tablas + volumen)]

## Invariantes que NO deben cambiar

- [contrato de lectura/escritura que los consumidores actuales asumen] — lo prueba: [test de BD concreto]
- [política de acceso vigente que la operación NO relaja] — referencia: [migración/PR]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Qué pasa y a quién le duele

- [el problema de datos en una frase: lentitud medida, hueco de integridad, permiso excesivo, volumen muerto]
- [quién lo sufre hoy y en qué operación concreta lo nota]

## Evidencia medida (entorno real)

- Consulta literal corrida en el entorno real:
  - `[consulta exacta]` → [salida real pegada: filas, tiempo, plan de ejecución]
- Fecha de la medición y tamaño de los datos al medir: [fecha · N filas]

## Verificación en 5 minutos

- Comandos copy-paste para REVALIDAR el claim ANTES de tocar nada (el ejecutor los corre al arrancar):
  - `[comando 1]` → [salida esperada]
  - `[comando 2]` → [salida esperada]
- Si la salida ya no confirma el claim: PARAR — la premisa caducó; escalar antes de ejecutar.

## Qué NO tocar y por qué

- [objeto que PARECE parte del problema pero no lo es] — [por qué es falso positivo, con dato]
- [optimización tentadora fuera del alcance] — [por qué no va aquí]

## Reversibilidad

- [cómo se revierte: contra-migración / restauración desde snapshot / patrón añadir-luego-retirar]
- Si NO es reversible (borrado, truncado, alteración de tipo con pérdida): GO explícito del responsable ANTES de despachar, documentado en la issue con fecha y quién lo dio.

## Contraargumento más fuerte

- [steelman honesto: la mejor razón para NO hacer esta operación, con números]
- [por qué aun así procede — refutación también con números]

## No-duplicado

- [issue/operación vecina revisada] — [por qué esta NO la repite ni la pisa]

## Criterios de aceptación / DoD

- [ ] `[consulta post-aplicación 1]` → [salida esperada que demuestra el efecto — una por objeto del alcance]
- [ ] `[consulta post-aplicación 2 — p. ej. conteo / plan de ejecución nuevo]` → [salida esperada]
- [ ] Validaciones del motor sin hallazgos nuevos tras aplicar
- [ ] Registro de migraciones al día; reconstrucción desde cero reproducible

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Consultas post-aplicación | salida literal de cada consulta sobre el entorno ya aplicado |
| Validaciones del motor | reporte sin hallazgos nuevos, con fecha |
| [resto de checkboxes] | salida literal sobre el commit final / captura / run de checks |

## Brief del ejecutor

- Conocimiento previo a cargar: [guía de migraciones del repo + perfil del repo]
- Patrón a REPLICAR: `[migración ejemplo]` (prohibido inventar estructura nueva)
- Límites duros: NO tocar lo listado en "Qué NO tocar"; NO añadir dependencias; NO resolver decisiones no selladas; numeración/slot de la migración verificada contra la fuente de verdad viva JUSTO antes de crear.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M10 + S + O + Q2/Q5/Q6/Q8 · Matrices: DB completa (test negativo de acceso incluido)
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: orden de aplicación y reversión declarados; la "Verificación en 5 minutos" corrida antes de planificar
- Revisor de código: 5 dimensiones §8 — extra del tipo: aceptación como consultas post-aplicación con salida esperada; idempotencia verificada ejecutando la operación dos veces
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: [PR + revisión + fusión (default) | cierre manual con evidencia si la operación no pasa por PR | cierre vía PR padre si esta pieza va en tren, ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09]
- Post-fusión: aplicar al entorno real + validaciones del motor + registro de migraciones confirmado, en el MISMO turno
- PARAR y escalar si: [la "Verificación en 5 minutos" ya no confirma el claim / la operación exige un paso destructivo sin GO previo]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Evidencia medida: consulta de listado con filtro por estado → 1.4 s en el entorno real
  (plan de ejecución pegado: recorrido secuencial sobre 2.1M filas; fecha de medición).
  Verificación en 5 min: dos comandos copy-paste (conteo + plan) que cualquiera corre para
  revalidar ANTES de tocar nada; si ya no aparece el recorrido secuencial, PARAR.
  Qué NO tocar: la tabla hermana con una consulta parecida — sus 14k filas no justifican
  índice (falso positivo cerrado con número).
  Contraargumento más fuerte: el índice penaliza escrituras — refutado: ratio medido
  lectura/escritura 400:1, pegado en la issue.
  DoD: consulta post-aplicación muestra uso del índice + validaciones del motor sin
  hallazgos nuevos + registro de migraciones al día.

  Por qué es gold: el claim se revalida en minutos, el falso positivo queda cerrado con
  dato y la aceptación son consultas con salida esperada, no prosa.
-->
