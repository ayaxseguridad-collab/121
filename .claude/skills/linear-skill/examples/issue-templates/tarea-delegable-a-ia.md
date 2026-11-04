# Title (replace this)

[Imperativo + qué + dónde]

---

> **Issue delegada a agente IA**. Marcar con label `actor/ai` y asignar agente como `delegate`. El humano `assignee` revisa el PR.

## Contexto

[Por qué este trabajo. Vínculo con initiative/project si aplica.]

## Tarea

[Descripción clara y acotada. Si es bug, ver bug.md. Si es feature, ver feature.md.]

## Por qué es delegable

- ✅ Scope < 1 día de trabajo
- ✅ Tests existentes en el repo
- ✅ No toca infra crítica (auth/payments/migrations)
- ✅ Sin ambigüedad de producto/UX
- ✅ Repro reproducible (si es bug)
- ✅ Especificación clara de input/output

## Criterios de aceptación

- [ ] Criterio verificable 1
- [ ] Criterio verificable 2
- [ ] Tests existentes pasan
- [ ] Test añadido para el cambio
- [ ] PR vinculado a esta issue con `Closes TAL-X`
- [ ] Branch name: `<prefijo>/tal-x-<slug>` con prefijo válido del flujo (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `hotfix/`)

## Información para el agente

### Archivos relevantes

[Lista de archivos donde está el cambio]

- `src/path/to/file.ts`
- `src/path/to/other.ts`

### Approach sugerido

[Plan de 3-5 pasos claros]

1. ...
2. ...
3. ...

### Tests a añadir

```typescript
test('caso esperado', () => {
  // ...
});

test('edge case 1', () => {
  // ...
});
```

## Out of scope

- ❌ X (otra issue si se necesita)
- ❌ Y (no entra aquí)

## Reviewer

@<humano> — revisará el PR cuando llegue a "In Review"

## Restricciones específicas

- NO modificar X sin discutir
- NO añadir nuevas dependencies
- Mantener estilo del archivo (linting)

---

**Labels obligatorios**: `vertical/<X>`, `kind:<X>`, `actor/ai`
**Delegate**: nombre del agente (Cyrus, Cursor, etc.)
**Assignee**: humano que va a revisar
**Estimate**: 1, 2 o 3 (issues IA mejor pequeñas)

## Después de cerrar

Si la issue se completó sin problemas → great.

Si requirió mucho rework humano → añadir el label `actor:needs-review` (existe POR TEAM: resolver el UUID del team de la issue — ver `duplicates` en `examples/label-taxonomy.json`) y comentar en la issue qué falló (lección para futuras delegations).
