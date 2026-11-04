# Prompt — Issue template para Features

Plantilla específica para issues de tipo Feature. Usar al crear cualquier issue con `kind:feat`.

## Estructura

```markdown
## Contexto

[1-2 párrafos: ¿por qué esta feature? ¿qué problema resuelve?
¿quién la usará? ¿conexión con la initiative parent?]

## Comportamiento esperado

[Descripción precisa de lo que el usuario debe poder hacer/ver
después de completar esta issue. Como user story si aplica.]

Como [tipo de usuario]
quiero [acción]
para [beneficio]

## Criterios de aceptación

- [ ] Criterio medible 1
- [ ] Criterio medible 2
- [ ] Criterio medible 3
- [ ] Tests añadidos para el happy path
- [ ] Tests añadidos para edge cases identificados

## Diseño / mockup

[Link a Figma, screenshot, o descripción visual si aplica]

## Implementación sugerida

[High-level. NO escribir código aquí — solo dirección.]
- Endpoint: `POST /api/...`
- Componente: `<NewComponent>`
- DB: nueva columna en `users.preferences`

## Out of scope

[Lo que explícitamente NO entra en esta issue. Importante para no scope-creep.]
- ❌ X (será otra issue)
- ❌ Y (decidiremos después)

## Dependencias

[Si depende de otra issue, link. Si depende de algo externo, mencionar.]
- Bloqueada por TAL-99 (necesitamos auth nueva primero)
- Requiere acceso a API X (pendiente credenciales)

## Notas técnicas

[Solo si hay decisiones arquitectónicas, gotchas conocidos, refs a docs internos]

## Recursos

[Links a specs, decision records, customer requests relacionadas]
- [Customer request original](link)
- [Spec en Notion](link)
```

## Checklist de calidad antes de crear

Antes de meter el issue, verifica:

- [ ] **Title** es imperativo, claro y específico (no "Feature X" sino "Implementar X en Y")
- [ ] **Contexto** responde al "por qué" no solo al "qué"
- [ ] **Criterios de aceptación** son verificables (checkbox-able)
- [ ] **Out of scope** está poblado (al menos "ninguno por ahora")
- [ ] **Estimate** es ≤ 5 (si más, descomponer)
- [ ] **Vertical label** está puesto
- [ ] **Kind label** = `kind:feat`
- [ ] **Priority** está puesta (no None)
- [ ] **Project** asignado si aplica
- [ ] **Milestone** asignado si el project tiene milestones

## Ejemplos de buenas features

### Ejemplo 1 — Backend feature

```markdown
# Title
Añadir endpoint de estadísticas agregadas para Talent Land Online

## Contexto

Equipo de Media necesita ver estadísticas agregadas de visualizaciones
del catálogo (no por video individual) para reportes ejecutivos.
Actualmente tienen que consultarlo video por video, lo cual no escala.

Este endpoint los habilita y descarga al equipo de Media de pedir
queries ad-hoc al equipo Talent Engine.

## Comportamiento esperado

Como administrador de Talent Land Online
quiero un endpoint `/api/v1/stats/aggregated` que reciba un rango de fechas
para obtener métricas agregadas (views totales, watch time, completion rate).

## Criterios de aceptación

- [ ] Endpoint responde 200 con JSON `{ views, watch_time_seconds, completion_rate }`
- [ ] Acepta query params `from` y `to` (ISO dates), default últimos 30 días
- [ ] Acepta `group_by=day|week|month`
- [ ] Auth: requiere admin role
- [ ] Test integration cubriendo ranges válidos e inválidos
- [ ] Test cubriendo casos sin datos (devolver zeros)
- [ ] Documentación en Postman / OpenAPI actualizada

## Implementación sugerida

- Reutilizar el modelo `ViewEvent` existente
- Aggregations vía SQL `GROUP BY` (no calcular en memoria)
- Cache de 5 min en Redis para queries identicas

## Out of scope

- ❌ Stats por usuario individual (privacidad — otra issue + decisión legal)
- ❌ Export CSV (TAL-XXX si lo necesitan después)
- ❌ Realtime (este endpoint es batch; realtime será otra issue)

## Dependencias

- Auth role admin existe ya (TAL-50, Done)

## Recursos

- [Solicitud original de Media en Slack](link)
```

### Ejemplo 2 — Frontend feature

```markdown
# Title
Agregar filtro por vertical en dashboard de Bootcamp

## Contexto

El dashboard del bootcamp.cripto actualmente muestra todos los
participantes mezclados. Coordinadores quieren filtrar por vertical
(crypto, web3, ai) para sus reportes específicos.

## Comportamiento esperado

Como coordinador del bootcamp
quiero seleccionar un vertical en el dashboard
para ver solo los participantes y métricas de ese vertical.

## Criterios de aceptación

- [ ] Dropdown de filtro arriba del dashboard, con opciones:
      Todos / Crypto / Web3 / AI / DevOps
- [ ] Al cambiar selección, todas las visualizaciones (charts, tablas)
      se actualizan
- [ ] Selección persiste en URL (`?vertical=crypto`) para shareable links
- [ ] "Todos" muestra el comportamiento actual
- [ ] Loading state visible durante el cambio
- [ ] Mobile-friendly

## Diseño / mockup

[Link a Figma frame "Dashboard - filtro vertical"]

## Implementación sugerida

- Component `<VerticalFilter>` reutilizable
- Estado en URL via Next.js searchParams (no en local state)
- Backend: el endpoint ya soporta `?vertical=` (TAL-78)

## Out of scope

- ❌ Filtros combinados (vertical + cohort) — TAL-XXX si se necesita
- ❌ Salvar preferencia del usuario — otra issue

## Dependencias

- TAL-78 backend support, Done
- Diseño en Figma confirmado

## Recursos

- [Figma](link)
- [TAL-78 backend implementation](link)
```

## Plantilla minimalista

Para features muy pequeñas (estimate 1-2), versión reducida:

```markdown
## Qué
[1 frase sobre qué hace la feature]

## Por qué
[1 frase sobre por qué importa]

## Criterios
- [ ] Cosa 1
- [ ] Cosa 2
- [ ] Test

## Notas
[Si hay alguna]
```

## Anti-patrones

❌ **Description = title repetido**: si la description no añade nada al title, no la metas.

❌ **Criterios vagos**: "que funcione bien" no es verificable. "Endpoint responde 200 con shape X" sí.

❌ **Mezclar features en una issue**: si hay "Y, Z, y W" → tres issues o sub-issues.

❌ **Implementación detallada con pseudocódigo**: no en la issue, en el PR. La issue dice qué, no cómo en detalle.

❌ **Falta de "out of scope"**: invita scope-creep durante development.

❌ **Sin dependency tracking**: si depende de otra issue, mencionarlo evita arrancar bloqueado.

❌ **Customer-driven sin link al customer need**: si vino de feedback, vincularlo via Customer Need.
