<!-- issue-craft:v1 type=chore variant=none madurez=despachable -->
<!-- Plantilla 04-chore · variantes: none | doc-vivo (si el artefacto es doctrina que otros ejecutarán — guías operativas, playbooks: variant=doc-vivo y completar el Bloque doc-vivo) -->
<!-- Defaults del tracker: etiqueta de tipo "chore" · estimate 1-5 · prioridad según ventana · calibre gold: 4-11k chars (doc-vivo: hasta 30k si el inventario lo exige) -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué mantenimiento/infraestructura es, por qué ahora, qué destraba.]
**Origen**: [link adjunto — deuda registrada / cambio de entorno / decisión con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[comando que muestra el estado actual del artefacto]` → [salida esperada]

## Anclas de contexto

- `[ruta/al/artefacto:L1-L2]` — [qué es] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/al/ejemplo-analogo]` — el patrón canónico a REPLICAR si existe

## Alcance

### Incluye

- [cambio 1 — lista cerrada]

### Fuera de alcance

- ❌ [limpieza vecina tentadora] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. versión objetivo, política elegida] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [configs, scripts, docs, pipelines que se modifican]

## Invariantes que NO deben cambiar

- [comportamiento operativo que sigue IGUAL tras el chore] — lo prueba: [check/suite concreta]
- [decisión ya integrada que se respeta] — referencia: [PR/commit]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Evidencia

- `[path:línea @ commit]` — extracto literal del estado actual que motiva el cambio:
  > [2-6 líneas del artefacto tal como está HOY]
- [si hay más de un foco: repetir el par path:línea + extracto por cada uno]

## Beneficio razonado

- [números, no "es mejor práctica": minutos ahorrados por corrida, fallos/mes que desaparecen, pasos manuales eliminados, tamaño reducido]
- [qué se puede hacer después que hoy no se puede]

## Cambios por archivo

| Archivo | Cambio concreto |
|---|---|
| `[ruta 1]` | [qué se cambia exactamente] |
| `[ruta 2]` | [qué se cambia exactamente] |

## Qué se conserva (guardas)

- [comportamiento/config que NO se toca aunque quede al lado del diff] — [por qué]
- [compatibilidad que se mantiene: formato, contrato, versión mínima soportada]

### Bloque doc-vivo (SOLO variant=doc-vivo — si no aplica, eliminar esta subsección)

- Inventario del estado actual con cifras EXACTAS: [N archivos, N secciones, N claims factuales, fechas]
- Tabla de deriva — re-verificar contra fuente oficial AL EJECUTAR, no confiar en esta foto:

| Declarado | Vigente | Fuente | Impacto |
|---|---|---|---|
| [lo que el doc dice hoy] | [lo que es verdad hoy] | [URL oficial + fecha de consulta] | [qué rompe si no se corrige] |

- Cambios por archivo con línea y texto propuesto (no "actualizar sección": el texto NUEVO va aquí)
- Qué NO tocar: [secciones/claims que siguen vigentes — listados uno a uno]
- FUENTES DE VERDAD: cada claim factual lleva URL oficial + fecha; lo no verificable SE ELIMINA del doc, no se parafrasea.
- El DoD se escribe como espejo 1:1 de "Cambios por archivo" y cierra con el checkbox literal de guardas (abajo).

## Criterios de aceptación / DoD

- [ ] `[comando]` → [salida esperada que demuestra el cambio — cobertura 1:1 con "Cambios por archivo"]
- [ ] `[check del repo que protege las guardas]` → verde sobre el commit final
- [ ] [Si variant=doc-vivo] DoD espejo 1:1: un checkbox por fila de "Cambios por archivo", verificable por grep del texto nuevo
- [ ] Nada de "Qué NO tocar" fue modificado (cierre obligatorio del espejo doc-vivo; en variant=none aplica a "Qué se conserva")

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| [cada checkbox] | salida literal sobre el commit final / captura / run de checks |
| [Si doc-vivo] fuentes de verdad | URL oficial + fecha de consulta por cada claim corregido |

## Brief del ejecutor

- Conocimiento previo a cargar: [guías del repo según artefactos tocados]
- Patrón a REPLICAR: `[ruta]` (prohibido inventar estructura nueva)
- Límites duros: NO tocar lo listado en guardas; NO añadir dependencias ni config sin dueño (aquí nace la config zombi); NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M + S (S3/S4 reforzados: cada flag/dependencia nueva con dueño y aprobación previa) + O como señal + Q1/Q8 · Matrices: según superficie tocada
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el beneficio está razonado con números y las guardas son verificables
- Revisor de código: 5 dimensiones §8 — extra del tipo: diff-scope literal contra la tabla "Cambios por archivo"
- Variante `doc-vivo`: inventario con cifras exactas + tabla Declarado|Vigente|Fuente|Impacto re-verificada contra fuente oficial AL EJECUTAR + cambios por archivo con línea y texto propuesto + "Qué NO tocar" respetado + DoD espejo 1:1 + fuentes de verdad con URL oficial y fecha por claim (lo no verificable se elimina)
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR) — (si esta pieza
  va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y
  `talent-merger` ref 09; nunca PR individual)
- Post-fusión: [pasos si aplican — p. ej. regenerar artefactos derivados, avisar a quien opera el doc]
- PARAR y escalar si: [una fuente oficial contradice el claim de la issue / una guarda resulta imposible de conservar]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Chore none: el pipeline de checks repetía una instalación completa por paso — evidencia:
  path:línea @ commit del paso duplicado; beneficio razonado: 4 corridas/día × 3 min = 12
  min/día recuperados (número, no "es mejor práctica"); cambios por archivo: tabla de 2
  configs con el cambio exacto; guardas: la caché NO altera qué versión se instala
  (archivo de bloqueo intacto, con check de paridad en el DoD).
  Doc-vivo: guía operativa con 9 claims; tabla Declarado|Vigente|Fuente|Impacto con 3 filas
  derivadas (menú renombrado, límite cambiado, paso eliminado), cada Vigente con URL oficial
  + fecha; DoD espejo 1:1 por archivo, cerrando con el checkbox de "Qué NO tocar" intacto.

  Por qué es gold: beneficio en números, diff acotado por tabla, guardas verificables y —
  en doc-vivo — cero claims sin fuente fechada.
-->
