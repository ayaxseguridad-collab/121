<!-- issue-craft:v1 type=docs-adr variant=none madurez=despachable -->
<!-- Plantilla 07-docs-adr · variantes: none (único token admitido para este tipo) -->
<!-- Defaults del tracker: etiqueta de tipo "docs-adr" · estimate 1-3 · prioridad según ventana · calibre gold: 5-11k chars -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué doc/registro de decisión miente o falta, a quién desorienta (quien siga sus pasos hoy, falla), qué corrige.]
**Origen**: [link adjunto — PR que cambió el comportamiento / hallazgo / decisión con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `grep -rn "[frase obsoleta]" [rutas del alcance]` → [N ocurrencias — exactamente las que este trabajo corrige]
  - `[validador de docs del repo sobre los archivos a tocar]` → [estado actual]

## Anclas de contexto

- `[ruta/al/doc-desactualizado:L1-L2]` — el texto que hoy miente (extracto mínimo abajo)
  > [3-8 líneas literales del doc]
- `[ruta/al/doc-o-registro-patron]` — el formato canónico del repo a REPLICAR

## Alcance

### Incluye

- [doc(s) a corregir/crear — lista cerrada de archivos]
- [si aplica: registro de decisión NUEVO que supersede a uno aceptado]

### Fuera de alcance

- ❌ [cambio de código/config que el careo revele deseable] → [issue destino]
- ❌ [docs vecinos con la misma frase, fuera de esta pasada] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. alcance de la corrección, doc destino] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [paths de documentación EXCLUSIVAMENTE — este tipo no toca código, config ni datos]

## Invariantes que NO deben cambiar

- Decisiones aceptadas en registros existentes: INMUTABLES — referencia: [registro(s) que esta issue roza]
- [doc vecino que cita la misma zona y debe quedar coherente] — lo prueba: [búsqueda de coherencia post-cambio]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Doc contra código real

| El doc dice (snippet literal) | El código/comando real dice | Fuente |
|---|---|---|
| "[frase desactualizada, citada tal cual]" | `[path:líneas]` o `[comando]` → [salida] | [ancla de arriba] |

Cada corrección del alcance nace de un careo de esta tabla — nunca de memoria ni de otro doc (un doc no es fuente de verdad de otro doc).

## Régimen de cierre

- Cierre normal (default): la corrección entra completa → PR + fusión con magic word de cierre.
- Referencia-sin-cierre + cierre diferido: si una parte depende de un hecho externo ([decisión pendiente / publicación de terceros]), la PR REFERENCIA esta issue SIN cerrarla y el cierre queda diferido a [trigger verificable] con dueño [quién]. El cierre parcial esperado se declara AQUÍ — no se descubre en la revisión.
- Si esta pieza va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09; nunca PR individual.

## Guardrails

- Decisiones aceptadas = INMUTABLES: cambiar una NO es editarla — es crear un documento nuevo que la supersede, con enlace cruzado en ambos sentidos.
- No inventar estados: lo no confirmado se escribe como "pendiente de verificación", nunca como hecho.
- FRONTERA DE EVIDENCIA (anti-paradoja de autorreferencia): el doc contiene SOLO evidencia
  nacida ANTES de su commit final. Exigir que contenga su propio SHA, el veredicto sobre ese
  SHA o la salida de gates que corren sobre ese commit crea un contrato INSATISFACIBLE
  (incorporarlos produce un SHA nuevo que invalida la evidencia). Lo post-commit vive en
  STOP-AUDIT/HANDOFF/body del PR, y el doc lo declara "pendiente de verificación" + puntero.
- Recurso numerado (registro de decisiones, índice secuencial): verificar el siguiente número LIBRE contra la fuente de verdad viva JUSTO antes de crear el archivo — no al planificar (dos autores en paralelo colisionan).
- Vendor-claims: toda afirmación sobre producto/versión/API de terceros lleva fuente oficial + fecha de verificación; lo no verificable SE ELIMINA del doc — no se deja "por si acaso".

## Criterios de aceptación / DoD

- [ ] `grep -rn "[frase obsoleta]" [rutas del alcance]` → 0
- [ ] El diff toca SOLO documentación (verificado sobre la PR: lista de archivos, cero código/config)
- [ ] Validador de docs del repo → verde sobre los archivos tocados
- [ ] [Si crea registro numerado] número verificado libre contra la fuente de verdad viva justo antes del commit
- [ ] [Si hay vendor-claims] cada afirmación con fuente oficial + fecha; cero afirmaciones sin fuente en el diff

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Frase obsoleta → 0 | salida literal de la búsqueda sobre el commit final |
| Diff docs-only | lista de archivos del diff de la PR |
| [resto de checkboxes] | salida literal sobre el commit final / run del validador |

## Brief del ejecutor

- Conocimiento previo a cargar: [guía de docs del repo + formato del registro de decisiones]
- Patrón a REPLICAR: `[ruta/al/doc-o-registro-patron]` (prohibido inventar estructura nueva)
- Límites duros: NO tocar código/config; NO editar decisiones aceptadas (superseder, nunca reescribir); NO afirmar lo no verificado; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M10 + S5 + Q8 · Matrices: — (diff solo-documentación no activa matrices de superficie)
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el careo doc-vs-código cubre TODAS las frases a corregir; el régimen de cierre elegido está justificado
- Revisor de código: 5 dimensiones §8 — extra del tipo: aceptación por búsqueda (frase obsoleta → 0) + diff docs-only verificado archivo a archivo + inmutabilidad de decisiones respetada
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo — al menos el validador de docs]
- Régimen de cierre: el declarado en "Régimen de cierre" (default: PR + revisión + fusión con magic word)
- Post-fusión: [pasos si aplican — p. ej. avisar a quienes consumen el doc corregido]
- PARAR y escalar si: [el careo revela que el CÓDIGO es lo que está mal (eso es un fix, no un doc) / el número reservado ya está tomado]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Doc contra código real (lo diferencial del tipo): la guía de despliegue afirmaba
  "los checks corren en el pipeline alojado" cuando el gate vigente es un script
  local — careo: snippet literal de la guía JUNTO al comando actual y su salida.
  DoD por búsqueda: frase obsoleta en las rutas del alcance → 0; el diff lista
  SOLO archivos de documentación; validador de docs del repo verde.
  Guardrails: la decisión aceptada previa NO se editó — se creó un registro nuevo
  que la supersede con enlace cruzado; el número se verificó libre contra el
  índice vivo JUSTO antes de crear el archivo.

  Por qué es gold: cada corrección nace de un careo verificable, el cierre es un
  comando (búsqueda → 0) y las decisiones históricas quedan intactas e inmutables.
-->
