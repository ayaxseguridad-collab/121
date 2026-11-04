<!-- issue-craft:v1 type=contenido-datos variant=none madurez=despachable -->
<!-- Plantilla 09-contenido-datos · variante única: none · operación de contenido/datos en producción SIN PR: el valor entra por escritura controlada, no por código -->
<!-- Defaults del tracker: etiqueta de tipo "contenido-datos" · estimate s/e · prioridad según ventana · calibre gold: 1.5-3k chars — el procedimiento pesado vive en la guía canónica del repo; la issue aporta instancias + salvaguardas -->

# {Publicar/Cargar/Actualizar/Retirar} {qué contenido o datos} ({dónde})

## Contexto y origen

[2-4 frases: qué pieza de contenido/datos entra o cambia, a quién sirve, por qué ahora.]
**Origen**: [link adjunto — petición editorial / decisión con fecha / issue hermana. El detalle de la decisión vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>` + estado actual del destino en producción confirmado
- Arranque verificado (correr ANTES de planificar):
  - `[consulta/comando que muestra el estado actual del destino]` → [salida esperada]

## Anclas de contexto

- `[ruta/de/la/guia-canonica-del-procedimiento]` — el método completo vive AQUÍ; esta issue solo lo instancia (extracto del paso crítico abajo)
  > [3-8 líneas literales]
- [issue hermana previa] — la ejecución anterior del mismo patrón, con su evidencia

## Alcance

### Incluye

- [pieza/registro 1 — lista cerrada de escrituras]

### Fuera de alcance

- ❌ Cambios de código o de esquema → [issue destino]
- ❌ [pieza excluida] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. texto final / asset / fecha de publicación] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [registros/tablas/objetos de almacenamiento de producción que se escriben — NO archivos del repo]

## Invariantes que NO deben cambiar

- [contenido/datos vecinos que quedan INTACTOS] — lo prueba: [consulta de conteo/estado antes y después, misma salida]
- Código y esquema: esta issue NO los toca — cualquier necesidad de código detectada → PARAR y escalar

## Contratos cross-pieza (si va en tren)

- Este tipo NO participa en trenes — SIN PR por contrato (cierre manual con evidencia). Si el
  contenido depende de piezas de otro tipo en el mismo lote, declarar la dependencia en
  "Artefactos tocados", no aquí.

## Linaje

- Patrón que continúa: [issue(s) hermana(s) previa(s) de la misma operación]
- Guía del procedimiento: `[ruta/de/la/guia-canonica]` — si esta issue contradice la guía, MANDA la guía (o se escala; nunca se improvisa)

## Destino (identificadores literales)

Cero ambigüedad: identificadores COMPLETOS, nunca "el registro de X".

| Pieza | Identificador literal (ID/slug/ruta) | Estado esperado tras la operación |
|---|---|---|
| [pieza 1] | `[id-o-slug-completo]` | [publicado/actualizado/retirado] |

## Método (idempotente y reversible)

- Procedimiento canónico de la guía — PROHIBIDA la escritura directa fuera de él (consola/editor manual sobre producción).
- Snapshot previo del estado del destino ANTES de escribir: [consulta/export] + dónde queda guardado.
- Patrón añadir-luego-retirar: lo nuevo entra ANTES de retirar lo viejo; la convivencia se verifica.
- Borrado definitivo DIFERIDO a post-verificación: nada se destruye hasta que la verificación de abajo pase [+ ventana del perfil].
- Idempotencia: re-ejecutar la operación completa NO duplica ni corrompe (verificable ejecutándola dos veces).

### Afirmaciones de terceros (si el contenido las incluye)

- Toda afirmación sobre productos/servicios de terceros lleva fuente oficial + fecha de consulta.
- Lo no verificable se ELIMINA del contenido antes de publicar — nunca se publica "de memoria".

## Verificación post-escritura

- Datos: conteos esperados poblados; URLs/assets referenciados → 200; cada identificador del Destino en su estado esperado.
- Funcional: el CONSUMIDOR del dato funciona con el dato nuevo — [pantalla/flujo/proceso] recorrido de verdad, no asumido.

## Criterios de aceptación / DoD

- [ ] `[consulta post-escritura]` → [conteo/estado esperado] (una por pieza del Destino)
- [ ] `[verificación de URLs/assets referenciados]` → [200/disponible]
- [ ] Prueba funcional del consumidor: [flujo] recorrido con el dato nuevo → [comportamiento esperado]
- [ ] Snapshot previo guardado y localizable; lo retirado sigue recuperable hasta el borrado diferido

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| [cada checkbox] | salida literal de la consulta / captura del consumidor / referencia al snapshot |

## Brief del ejecutor

- Conocimiento previo a cargar: la guía canónica del procedimiento + [docs del dominio del contenido]
- Patrón a REPLICAR: la ejecución de [issue hermana previa] (prohibido inventar procedimiento nuevo)
- Límites duros: NO tocar código/esquema; NO escribir fuera del procedimiento canónico; NO borrar en la misma pasada; NO resolver decisiones no selladas.
- Presupuesto de cambio: [N piezas/registros] exactos del Destino — ni uno más.
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M9 + S5 + O3 + Q2/Q5/Q8 · Matriz: Contenido/datos (`02-verificaciones.md` §6.4) — la idempotencia del write ES Q5
- Revisor de plan: rúbrica canónica §7 — extra del tipo: el plan cita snapshot, orden añadir-luego-retirar y consultas de verificación ANTES de escribir nada
- Revisor de la entrega: evidencia post-escritura completa + idempotencia demostrada + snapshot localizable
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: la verificación post-escritura completa (no hay checks de build: no hay diff de código)
- Régimen de cierre: SIN PR — el ejecutor NO cierra: pasa a revisión con la evidencia → confirma el responsable → cierre manual
- Gate editorial: contenido de cara al usuario final → aprobación editorial APARTE del cierre técnico, ANTES de publicar
- Post-cierre: borrado definitivo de lo retirado SOLO tras la ventana diferida, registrando cuándo y quién
- PARAR y escalar si: el estado real del destino no coincide con el Baseline, o la operación exige un paso destructivo/irreversible no listado

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Lo diferencial del tipo, bien hecho:
  - Destino literal: «actualizar la entrada `guia-bienvenida-2026` (id 8f3a…) del
    catálogo de plantillas» — nunca "la guía de bienvenida".
  - Método: export previo del registro (snapshot con fecha) → alta de la versión nueva
    por el procedimiento canónico → verificación → SOLO entonces se programa el retiro
    de la vieja (borrado diferido).
  - Verificación post-escritura: conteo esperado en el catálogo, URL del asset → 200,
    y el flujo de alta de un usuario NUEVO recorrido con la pieza ya publicada.
  - Cierre: el ejecutor adjunta la evidencia y pasa a revisión; cierra el responsable
    tras confirmar — y el texto de cara al usuario pasó su gate editorial aparte.

  Por qué es gold: idempotente (re-correr no duplica), reversible hasta el final
  (snapshot + borrado diferido) y verificado en el CONSUMIDOR, no solo en el dato.
-->
