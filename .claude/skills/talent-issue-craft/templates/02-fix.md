<!-- issue-craft:v1 type=fix variant=none madurez=despachable -->
<!-- Plantilla 02-fix · variantes: none | seguridad | sev1 | seguridad+sev1 (cada variante activa su batería en Rúbricas) -->
<!-- Defaults del tracker: etiqueta de tipo "fix" · estimate 1-4 · prioridad según impacto · calibre gold: 7-11k chars (sev1: forma compacta, 1-2.5k) -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué defecto se corrige, a quién le duele hoy, qué valor entrega cerrarlo.]
**Origen**: [link adjunto — reporte de usuario / hallazgo de revisión / alerta de monitoreo, con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[comando que reproduce el estado actual]` → [salida que evidencia el defecto HOY]

## Anclas de contexto

- `[ruta/al/codigo-defectuoso:L1-L2]` — [dónde vive el defecto] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/al/patron-correcto]` — el ejemplo canónico que SÍ hace lo correcto

## Alcance

### Incluye

- [corregir la clase COMPLETA del defecto según inventario — lista cerrada]

### Fuera de alcance

- ❌ [mejora vecina detectada de paso] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. estrategia de corrección, ventana de despliegue] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [paths que el fix modifica — el diff no sale de esta lista]

## Invariantes que NO deben cambiar

- [comportamiento correcto vecino al defecto que queda INTACTO] — lo prueba: [suite/spec concreta]
- [decisión ya integrada que el fix respeta] — referencia: [PR/commit]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Síntoma

- **Esperado**: [comportamiento correcto, en una frase verificable]
- **Observado**: [comportamiento real LITERAL — mensaje de error / salida / captura, con fecha; en sev1: timestamp exacto]

## Evidencia reproducible

- Pasos mínimos desde estado limpio: [1..N, deterministas]
- `[comando de reproducción]` → [salida literal que muestra el defecto]

## Causa raíz (probada, no hipotética)

- [mecánica exacta: qué línea/condición produce el síntoma y por qué]
- Prueba: [experimento que la confirma — alterar la condición cambia el síntoma de forma predecible]

## Impacto y coste de no actuar

- [a quién afecta, con qué frecuencia, qué degrada — números si existen]
- [qué empeora si se pospone: corrupción de datos, bloqueo de flujo, erosión de confianza]

## Inventario de la clase del defecto

- `[comando que enumera TODAS las instancias de la clase]` → [listado literal + conteo]
- Regla de CIERRE-POR-CLASE: la clase se cubre al 100% en esta issue, o cada instancia excluida se deslinda explícitamente a [issue destino] — nunca "arreglé solo la que vi".

## Fix propuesto y alternativas

- Fix propuesto: [cambio mínimo que elimina la causa raíz]
- Alternativas consideradas: [opción B → por qué no] · [no hacer nada → por qué no]

## Reversión y observabilidad

- Reversión: [cómo se deshace — revert del commit / flag / restauración de config]
- Observabilidad: [log/métrica/alerta que delataría una reincidencia sin re-desplegar]

## Dedupe

- [issue vecina 1] — [por qué NO es lo mismo — revisadas una a una]
- [issue vecina 2] — [por qué NO es lo mismo]

## Criterios de aceptación / DoD

- [ ] Criterio por mutación: re-aplicar la condición del defecto → `[check/test]` en ROJO; revertirla → VERDE (ambas salidas se adjuntan como evidencia)
- [ ] Clase cubierta según inventario: `[comando del inventario]` → 0 instancias sin corregir (o deslinde explícito en "Fuera de alcance")
- [ ] Suites de las invariantes nombradas → verdes sobre el commit final
- [ ] [Si variant=seguridad] Test negativo del exploit en la suite (el vector cerrado queda vigilado por un check permanente)
- [ ] [Si variant=sev1] Smokes en 3 capas: local simulado / local normal / producción post-despliegue, con salidas pegadas

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Mutación | ambas salidas literales: check en rojo con el defecto re-aplicado, verde tras revertir |
| [resto de checkboxes] | salida literal sobre el commit final / captura / run de checks |

## Brief del ejecutor

- Conocimiento previo a cargar: [guías del repo según artefactos tocados]
- Patrón a REPLICAR: `[ruta]` (prohibido inventar estructura nueva)
- Límites duros: fix MÍNIMO — no "aprovechar para mejorar" (eso va a issue aparte); NO tocar [X]; NO añadir dependencias; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M + S (S5 reforzado: el fix no generaliza por su cuenta) + O1/O8 + Q · Matrices: según superficie tocada
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan ataca la causa raíz PROBADA (no el síntoma) y cubre el inventario completo de la clase
- Revisor de código: 5 dimensiones §8 — extra del tipo: criterio por mutación con ambas salidas pegadas
- Variante `seguridad` (trigger: superficie sensible — autenticación, permisos, pagos, credenciales, datos personales): cadena de exploit completa (quién puede explotarlo / vector / carga de ejemplo), severidad razonada con mitigantes, test negativo, referencia a debilidad estándar; se revisa TODA la cadena afectada, no solo el diff
- Variante `sev1` (producción degradada o caída): forma compacta — síntoma literal con timestamp, forense del origen (commit/cambio que lo introdujo), fix mínimo con radio de impacto declarado, smokes en 3 capas (local simulado / local normal / producción post-despliegue); lo sistémico se deslinda a follow-up, nunca dentro del fix
- Variante `seguridad+sev1` (incidente urgente DE seguridad): UNIÓN de ambas baterías — la forma compacta de sev1 se permite en la prosa, pero NINGÚN duro de seguridad se omite
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR) — (si esta pieza
  va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y
  `talent-merger` ref 09; nunca PR individual)
- Post-fusión: [verificar que el síntoma no reaparece en el entorno afectado / pasos si aplican]
- PARAR y escalar si: [la causa raíz resulta distinta a la probada / el inventario de la clase crece más allá del presupuesto]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Síntoma: Esperado — el listado pagina de 20 en 20 sin repetir; Observado — la página 2
  devuelve los mismos 20 elementos (salida del cliente HTTP pegada, con fecha).
  Causa raíz probada: el parámetro de desplazamiento se descarta al componer la consulta
  (path:línea citado); forzarlo a mano cambia el síntoma de forma predecible → confirmado.
  Inventario de la clase: búsqueda del mismo constructor de paginación → 3 listados con el
  patrón defectuoso; los 3 entran al alcance (cierre-por-clase, cero deslindes).
  DoD por mutación: fixture que re-aplica la condición → spec de paginación en ROJO;
  revertida → VERDE; ambas salidas adjuntas en la entrega.

  Por qué es gold: ataca la causa probada (no parchea el síntoma), cubre la clase completa
  con inventario por comando y demuestra que su red de detección no es decorativa.
-->
