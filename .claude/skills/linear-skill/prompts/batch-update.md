# Prompt — Operaciones en lote (batch update)

Plantilla para operaciones que afectan a varias issues a la vez. Linear no tiene mutation `bulk*` — hay que iterar. Este prompt explica cómo hacerlo bien sin chocar con rate limits ni perder datos. **Todo por la API GraphQL directa** (token-only, `LINEAR_API_KEY`); ver `references/03-graphql-cheatsheet.md`.

## Cuándo usar

- "Mueve todas las issues con label X al cycle Y"
- "Cambia la prioridad de las issues abiertas del project Z a high"
- "Añade label `actor/ai` a todas las issues delegadas a Cyrus en este cycle"
- "Archiva las issues canceladas de hace más de 1 mes"
- "Asigna todas las issues sin owner del backlog a @persona"

## Antes de empezar

Para cualquier batch operation, siempre:

```text
1. Confirmar al humano qué se va a tocar (count + sample)
2. Pedir confirmación explícita
3. Ejecutar con throttling
4. Reportar resultados (éxito y errores)
```

**Si la operación afecta a > 20 issues**: usar el script `scripts/batch-issues.ts` (paginación + rate limit) en lugar de mutations GraphQL sueltas (latencia, contexto consumido).

## Patrón base

### Paso 1 — Listar y verificar

Query `issues(filter: {...})` con los filtros que el humano pidió (ver `buscar-y-deduplicar.md` §B) y `first: 100` (máximo por página). Si hay más, paginar con `after: <endCursor>` o pedir filtros más estrictos.

### Paso 2 — Mostrar muestra al humano

```text
Voy a actualizar 23 issues con tu cambio:

Sample (primeras 5):
- TAL-87 "Implementar export PDF"
- TAL-91 "Migrar payments a v2"
- TAL-95 "Refactor cliente HTTP"
- TAL-103 "Configurar CI matrix"
- TAL-110 "Agregar logs estructurados"
... (18 más)

Cambio: añadir label `actor/ai`

¿Procedo? (yes / no / show all)
```

Esperar confirmación.

### Paso 3 — Ejecutar con throttling

Para cada issue, una mutation `issueUpdate` (por `id`, el UUID — no el identificador `TAL-X`):

```graphql
mutation Update($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success }
}
```

Con throttle:

```text
Ritmo seguro: 5 requests/segundo, espera 200ms entre cada lote.
Para 23 issues: ~5 segundos total.
```

### Paso 4 — Reportar

```text
✅ Actualizadas 22/23 issues.
   - 22 exitosas
   - 1 error: TAL-95 (issue archivada, ya no se puede modificar)

¿Quieres que reintente o lo dejamos así?
```

## Patrones específicos

### Patrón 1 — Cambiar labels en lote

**Para añadir o quitar labels NO se lee y se reenvía el array completo.** Linear expone rutas
nativas incrementales, verificadas contra el schema vivo; el literal GraphQL vive en
`references/03-graphql-cheatsheet.md` y aquí no se duplica:

- **`issueAddLabel` / `issueRemoveLabel`** — una label a la vez, sin tocar las demás.
- **`IssueUpdateInput.addedLabelIds` / `.removedLabelIds`** — varias de golpe dentro de un
  `issueUpdate` normal, útil cuando ya estás actualizando otros campos en la misma mutación.

**`labelIds` sigue siendo REEMPLAZO TOTAL** del set —enviarlo parcial BORRA las labels omitidas—, así
que se usa **solo** cuando ya tienes el set final calculado (p. ej. al crear la issue), nunca como
forma de añadir o quitar.

**Por qué importa justo en un batch**: el patrón leer-el-estado-y-reenviar-el-array-completo tiene
una carrera real —entre tu lectura (`issue(id:)`) y tu escritura (`issueUpdate`), si otro actor
(humano, agente, automation) toca las labels de esa issue, tu escritura **pisa** su cambio—, y en un
lote esa ventana se abre una vez por issue. Las rutas incrementales la cierran de raíz y además
ahorran una request por issue.

```text
for id in issue_ids:
    # añadir:  mutation issueUpdate(id: $id, input: { addedLabelIds: [<uuid>] })
    # quitar:  mutation issueUpdate(id: $id, input: { removedLabelIds: [<uuid>] })
    # una a una: issueAddLabel(id: $id, labelId: $labelId) / issueRemoveLabel(id: $id, labelId: $labelId)
```

Para batches grandes la vía preferida sigue siendo `scripts/batch-issues.ts`, que ya emite los campos
nativos (`addedLabelIds`/`removedLabelIds`) y nunca un `labelIds` completo.

### Patrón 2 — Mover de cycle

```text
for id in issue_ids:
    # mutation issueUpdate(id: $id, input: { cycleId: "<targetCycleId>" })
```

Caso común: "mueve incompletas del cycle pasado al actual". Pero **Linear lo hace automáticamente al cerrar el cycle** — no deberías necesitar hacerlo manual.

Caso real: "mueve estas 5 issues del cycle 12 al cycle 14" (saltarse el 13 por vacaciones): iterar `issueUpdate(id, { cycleId: "<cycle-14-id>" })` sobre los 5 UUIDs.

### Patrón 3 — Reasignar owner

Cuando alguien sale de vacaciones:

```text
# query issues(filter: { assignee: { id: { eq: "<persona-uuid>" } },
#                        state: { type: { in: ["unstarted","started"] } } }, first: 50)
for issue in nodes:
    # mutation issueUpdate(id: issue.id, input: { assigneeId: "<cubrir-uuid>" })
    # mutation commentCreate(input: { issueId: issue.id,
    #   body: "Reasignada a @cubrir mientras @persona está fuera. Original owner: @persona" })
```

### Patrón 4 — Subir prioridad

Cuando un Customer Need agrupa muchas issues y se decide promover:

```text
# query issues(filter: { priority: { eq: 4 }, labels: { name: { eq: "vertical/media" } } }, first: 50)
for issue in nodes:
    if tiene_customer_needs(issue):   # comprobar vía el campo `needs` del issue (Issue.needs, no customerNeeds)
        # mutation issueUpdate(id: issue.id, input: { priority: 2 })   # low → high
```

### Patrón 5 — Archivar

Para limpieza:

```text
# query issues(filter: { state: { type: { in: ["completed","canceled"] } },
#                        completedAt: { lt: "<threshold ISO>" } }, first: 100)
# Linear normalmente las archiva auto. Solo manual si necesario:
for issue in nodes:
    # mutation issueArchive(id: issue.id) { success }
```

## Operaciones destructivas

Estas operaciones requieren **doble confirmación**:

- `issueDelete` (rara vez la respuesta correcta — preferir Cancel)
- Borrar labels que están en uso (`issueLabelDelete`)
- Archivar/eliminar projects activos (`projectDelete` — `projectArchive` quedó deprecada en favor de `projectDelete`)
- Borrar comments (`commentDelete`)

Antes de ejecutar:

```text
⚠️ Vas a borrar 12 comments de prueba en TAL-150.
Esta acción es IRREVERSIBLE.

Sample:
- "test test"
- "asdfasdf"
- "deleteme"

Confirma escribiendo "borrar comments" para proceder.
```

Solo proceder si el humano escribe la frase exacta. Si dice "yes" o "ok", no es suficiente.

## Cómo usar el script `batch-issues.ts`

Para batches > 20 issues, conviene usar el script en lugar de mutations GraphQL sueltas:

```bash
# Ver el script completo en scripts/batch-issues.ts. Flags que APLICA: --filter (obligatorio),
# --set-priority, --set-cycle, --add-labels, --remove-labels, --concurrency, --dry-run.
# state/assignee en lote NO los cubre el script (iterar issueUpdate a mano por issue).
ts-node scripts/batch-issues.ts \
  --filter '{"team":{"key":{"eq":"TAL"}},"labels":{"name":{"eq":"vertical/media"}}}' \
  --set-priority 2 \
  --dry-run
```

Con `--dry-run` solo muestra lo que haría. Sin él, ejecuta.

El script hace:

1. Paginación automática (no se pierde nada >50)
2. Throttling correcto
3. Retry on rate limit
4. Logging detallado
5. Diff antes de cada update

## Anti-patrones de batch

❌ **Ejecutar sin confirmar al humano**: si te equivocas con el filtro, tocas decenas de issues incorrectas.

❌ **Sin throttling**: rate limit y posible bloqueo temporal del API.

❌ **Sin dry-run para >20 issues**: ejecutar a ciegas es peligroso.

❌ **Usar `labelIds` para añadir o quitar**: es reemplazo total —pierdes las labels que no envíes— y encima abre la carrera del read-then-write. Para add/remove van `addedLabelIds`/`removedLabelIds` o `issueAddLabel`/`issueRemoveLabel`.

❌ **No reportar errores**: si 5 de 50 fallan y no avisas, hay inconsistencia silenciosa.

❌ **Ejecutar batch en horario de cycle activo**: las modificaciones masivas a issues "in progress" desorientan al equipo. Hacerlo viernes tarde / lunes muy temprano.

❌ **Olvidar comentar en cada issue por qué cambió**: para cambios significativos, breve comment ayuda al owner a no preguntarse "qué pasó".
