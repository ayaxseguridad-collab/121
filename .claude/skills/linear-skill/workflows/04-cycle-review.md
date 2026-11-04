# Workflow — Cycle Review y Retro (viernes)

> **Alcance**: contenido de uso libre para cualquier equipo que instale este skill. La fábrica de Talent Engine NO lo usa hoy (cycles desactivados en el team TAL; el trabajo se despacha por batches/encargos con `talent-orchestrator` y las issues se redactan con `talent-issue-craft`). Verificado 2026-09-05.

Cierre disciplinado del cycle. Para 2-3 personas, debe ser **15-20 min**. El objetivo es generar un Project Update / Initiative Update con datos reales y dejar el cycle de la semana siguiente listo para empezar el lunes.

## Cuándo ejecutar

- Viernes por la tarde, antes de cerrar la semana
- O si se delega a Claude: el humano dice "cerremos el cycle"

## Paso 1 — Snapshot del cycle

```text
query($after: String) { issues(filter: { team: { key: { eq: "TAL" } }, cycle: { isActive: { eq: true } } }, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title state { name type } estimate } } }
# paginar con after hasta hasNextPage=false
```

Categorizar:

```text
Por estado:
- Done: ✅ entregadas
- In Review: ⏳ pendientes de merge
- In Progress: 🟡 trabajándose pero no entregadas
- Todo: 🔴 ni se empezaron
- Canceled: ⚫ canceladas durante la semana
```

Calcular:

```text
Velocity:
- Estimate planificado al inicio de cycle: X puntos (lo viste el lunes)
- Estimate completado (Done + In Review que se mergeará): Y puntos
- Ratio: Y/X
```

## Paso 2 — Análisis cualitativo

Para cada categoría, breve análisis:

**Done**: ¿hubo highlights notables? PR especialmente impactantes, bugs críticos resueltos, etc.

**In Review**: ¿van a merge hoy o pasan a la próxima? Si lleva días en In Review, identificar bloqueo.

**In Progress no terminadas**: ¿por qué no terminó?

- Subestimada → lección aprendida
- Bloqueada por dependencia externa → registrar
- Cambió scope a mitad → ¿bien hecho o mal hecho?
- Distracción → identificar honestamente

**Todo no empezadas**: peor categoría. ¿Por qué?

- Mal priorizadas → revisión de criterios
- Demasiada carga → revisar capacidad
- Algo más urgente entró → registrar como "interrupción"

## Paso 3 — Auditoría de trabajo IA

Especial revisión de issues con `actor/ai`:

```text
query($after: String) { issues(filter: { team: { key: { eq: "TAL" } }, cycle: { isActive: { eq: true } }, labels: { name: { eq: "actor/ai" } } }, first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title state { name } } } }
```

Para cada una:

| Estado | Significado |
|---|---|
| ✅ Mergeada sin cambios mayores | IA performó bien |
| ⚠️ Mergeada con muchos cambios humanos | IA produjo borrador útil |
| ❌ No mergeada / abandonada | IA falló; ¿por qué? |

Si una issue fue abandonada o tuvo muchos cambios:

1. Comentario en la issue: "Lección: <qué falló>"
2. Considerar añadir `actor:needs-review` post-mortem (label por team: resolver el UUID del team de la issue)
3. Incorporar en Agent Guidance de Linear si es patrón

## Paso 4 — Decidir destino de incompletas

Para cada issue NO completada:

```text
Decisión:
A) Volver a meter en próximo cycle → no hacer nada (Linear lo hace auto)
B) Volver al backlog (no urgente) → mutation issueUpdate(id, input: { cycleId: null, stateId: "<Backlog uuid>" })
C) Cancelar (ya no aplica) → mutation issueUpdate(id, input: { stateId: "<Canceled uuid>" }) + commentCreate con razón
D) Dividir (era muy grande) → crear sub-issues, original Canceled
```

**Regla**: si una issue ha rebotado **3 cycles seguidos**, decidir A no es opción. O priorizar de verdad o cancelar.

## Paso 5 — Generar Project Updates de la semana

Para cada Project activo del cycle, escribir un Project Update.

Plantilla:

```markdown
## Esta semana (Cycle W<N>)

### Entregado
- [TAL-X] <título> — <link al PR>
- [TAL-Y] <título> — <link al PR>

### En review
- [TAL-Z] <título> (esperando review de @persona)

### Próxima semana
- [Top 3 prioridades del próximo cycle]

### Bloqueos
- [Ninguno] / [Lista de bloqueos con owner para resolver]

### Health
[onTrack/atRisk/offTrack — solo si cambia respecto a semana pasada]
```

Crear el update:

```graphql
mutation CrearProjectUpdate {
  projectUpdateCreate(input: {
    projectId: "<uuid>",
    body: "<markdown anterior>",
    health: onTrack   # enum: onTrack | atRisk | offTrack (sin comillas)
  }) { success projectUpdate { id url } }
}
```

## Paso 6 — Generar Initiative Updates (si toca)

Las Initiatives están configuradas para weekly viernes. Si una initiative tuvo movimiento esta semana:

```graphql
mutation CrearInitiativeUpdate {
  initiativeUpdateCreate(input: {
    initiativeId: "<uuid>",
    body: "<markdown>",
    health: onTrack   # enum: onTrack | atRisk | offTrack (sin comillas)
  }) { success initiativeUpdate { id } }
}
```

Plantilla más alta nivel:

```markdown
## Cycle W<N> en <Nombre Initiative>

### Projects activos
- <Project A>: <% progreso>, milestone M2 en curso
- <Project B>: <% progreso>, M1 completado esta semana

### Hitos de la semana
- [Si hay] M1 de <Project> completado

### Riesgos
- [Si hay]

### Próxima semana
- [Top de la initiative]
```

## Paso 7 — Retro corto (escrito, no meeting)

Como Document en el workspace o en el primer Project del cycle:

```markdown
# Cycle W<N> — Retro

## Métricas
- Planificado: X puntos
- Completado: Y puntos
- Ratio: Y/X
- Issues IA: A planificadas / B completadas
- Issues humanas: C planificadas / D completadas

## Lo que salió bien
- ...

## Lo que mejoraría
- ...

## Acciones para próximo cycle
- [ ] Acción 1 con owner
- [ ] Acción 2 con owner
```

NO meeting. NO hangout. Document compartido. Cada persona reacciona con emoji o comenta.

## Paso 8 — Limpieza del cycle

```text
1. Issues completadas: Linear las archiva auto en N días (configurable)
2. Issues canceladas: idem
3. Cycle queda como histórico, accesible desde Cycles del team
```

Si quieres, archivar manualmente issues "Done" del cycle:

```text
query($after: String) { issues(filter: { team: { key: { eq: "TAL" } }, cycle: { id: { eq: "<currentCycleId>" } }, state: { type: { eq: "completed" } } }, first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { id identifier } } }
→ por cada una, mutation issueArchive(id: <uuid>) { success }
```

Linear normalmente lo hace automáticamente. No es crítico.

## Paso 9 — Confirmar al humano

Resumen final:

```text
✅ Cycle W<N> cerrado.

Métricas:
- Velocidad: 14/16 puntos (87.5%)
- Issues completadas: 11
- Issues rebotando: 3 (van al W<N+1>)

Project Updates publicados:
- Talent Land Online — Proyecto Auth v2: onTrack
- Talent Media — Dashboard v1: atRisk (M1 retrasado)

Iniciative Updates publicados:
- Talent Land Online 2026: onTrack
- Talent Media 2026: atRisk (1 project en riesgo)

Retro: <link al document>

Próximo cycle empieza lunes <fecha>.
```

## Anti-patrones del cycle review

❌ **Cerrar el cycle sin Project Updates**: el ritmo de updates es la mitad del valor de Linear.

❌ **Health "onTrack" siempre**: si todo es siempre onTrack, el sistema no aporta señal. Sé honesto.

❌ **Retro de 1 hora con todo el equipo**: 15-20 min escrito y reactivo. Si necesitas conversación, hazla aparte.

❌ **No medir velocidad cycle a cycle**: pierde la oportunidad de saber tu capacidad real.

❌ **Cancelar issues sin razón documentada**: comment explicando por qué se canceló. Lo agradecerás dentro de 6 meses.

❌ **Dejar issues en Triage**: si una issue lleva 1 semana en Triage, aplicar workflow 02 (triage-y-delegar) o cancelar.

## Variantes

### Si el cycle fue catastrófico (velocidad < 50%)

Retro más profundo:

1. ¿Qué evento externo hubo? (pánico, cliente, P0)
2. ¿Hubo issues mal estimadas? Listar las que tomaron 2x del estimate.
3. ¿Hubo interrupciones? ¿Cuántas y por qué?
4. ¿Cambia algo del próximo cycle? (capacidad reducida, foco distinto)

### Si el cycle fue muy bueno (velocidad > 110%)

Quizá subestimaste. No celebrar todavía:

1. Revisar que las issues completadas eran de la calidad esperada (no rushed)
2. Considerar subir capacidad nominal del próximo cycle
3. ¿Hubo trabajo no planificado que se entregó? Reconocerlo, pero pregunta si era prioridad real

### Si el equipo crece a mitad de quarter

Recalcular capacidad y hablar de retros más estructuradas.
