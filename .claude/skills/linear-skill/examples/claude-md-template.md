# CLAUDE.md — Talent Engine

Este archivo configura el comportamiento de Claude Code (incluido cuando se ejecuta vía Cyrus para Linear). Pegar como `~/.cyrus/CLAUDE.md` para configuración global de Cyrus, o como `CLAUDE.md` en la raíz de un repo específico para configuración por repo.

## Sobre el equipo

Trabajo para **Talent Engine**, equipo de desarrollo de Talent Network. Mantenemos plataformas para Talent Land MX, Talent Land Online, Academia Ejemplo, Bootcamp Cripto y Talent Media.

Equipo pequeño (2-3 humanos + agentes IA). Velocidad e higiene del código importan en igual medida.

## Idioma

Comunicación: **español**. Términos técnicos en inglés cuando sean estándar (commit, branch, PR, deploy, etc.).

## Convenciones del workspace

### Linear

- **Team**: TAL
- **Cycles**: 1 semana, lunes-domingo
- **Labels obligatorios**: vertical/* en toda issue
- **Branch names**: `{prefijo}/tal-{n}-{slug}` con prefijo válido del flujo (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `hotfix/`), en minúsculas
- **Magic words**: `fixes`, `closes`, `resolves` para auto-cierre

### Git

- Branches descriptivas en kebab-case
- Commits en presente: `Add OAuth validation` (no `Added` ni `Adds`)
- PRs vinculadas a issue con `Closes TAL-X`
- NO push directo a `main` o branches protegidas

### Stack común (referencia, ajustar por repo)

- Frontend típico: TypeScript + React/Next.js + Tailwind
- Backend típico: TypeScript + Node + Postgres
- Infra: GCP (Cloud Run, GCS, Cloud SQL)
- Auth: depende del producto (algunos OAuth, otros email magic link)

Cuando entres en un repo, **lee el README** y el `package.json` para confirmar stack real antes de asumir.

## Cómo trabajo

### Antes de tocar código

1. Lee la issue de Linear COMPLETA (description + comments)
2. Lee el README del repo si no lo conozco
3. Identifica los archivos relevantes
4. Si algo es ambiguo, NO inventes — pide clarificación en un comment de la issue

### Implementando

1. Branch nueva: `{prefijo}/tal-{n}-{slug}` (prefijo según el tipo de trabajo)
2. Tests primero (al menos para bugs)
3. Implementación mínima que pasa los tests
4. Iterar

### Antes de abrir PR

- [ ] Tests pasan localmente (no solo CI)
- [ ] Linter limpio (sin disable hacks)
- [ ] Type checker limpio (sin `as any` injustificado)
- [ ] Diff razonable (no archivos no relacionados)
- [ ] Commit messages claros

### PR description

```markdown
## Cambios
- Bullet con cambios técnicos

## Por qué
1-2 líneas vinculando a la issue

## Cómo testeé
- Tests añadidos
- Manual si aplica

## Riesgos
- Si los hay; si no, "ninguno"

Closes TAL-X
```

## Restricciones

### NO modificar sin permiso explícito

- `.env`, `.env.example` (modificar example sí, env no)
- Migraciones de DB: las migraciones son agent-managed con gates y advisors (regla 24 del repo); dentro del sistema de canales las aplica el Mergeador tras el merge; las destructivas exigen GO explícito del lead
- `package-lock.json` / `yarn.lock` salvo cuando es esperado por la issue
- Secrets, credenciales, certificates
- Configuración de deploy (`vercel.json`, `cloudbuild.yaml`, etc.) salvo issue específica
- Archivos en `infra/` o `terraform/` salvo issue específica

### Errores que evito siempre

- Commitear secrets (incluso de ejemplo)
- Hacer un PR enorme cuando podría ser 3 PRs pequeños
- Resolver bugs sin escribir test que los reproduce
- Hacer "drive-by refactors" no relacionados con la issue
- Ignorar warnings del linter "porque no son míos"
- Cambiar dependencias mayores sin discutir
- Hacer cambios breaking de API sin discutir

## Cuando estoy bloqueado

Si no puedo avanzar:

1. Documento qué intenté y por qué falló
2. Comento en la issue de Linear con lo aprendido
3. NO abro PR a medio camino con stub

Mejor pausar y comunicar que entregar algo a medias.

## Cuando termino

PR abierta y vinculada. Comentario final en la issue:

```text
PR abierta: https://github.com/.../pull/N

Resumen:
- Cambios principales
- Tests añadidos
- @humano-revisor para review

Para verificar manualmente:
1. Pasos
```

NO cierro la issue. Eso lo hace la automation al merge.

## Estilo de código

### Generales

- Funciones pequeñas
- Nombres descriptivos sobre cortos: `fetchUserPreferences()` > `fetchUP()`
- Comentarios explicando "por qué", no "qué"
- Early returns sobre nesting profundo
- Cobertura de tipos completa en TypeScript

### Errors

- NUNCA tragarse errores con `try { ... } catch {}` vacío
- Errors deben tener mensajes accionables
- Logs estructurados (key=value), no strings concatenados

### Tests

- Un test = un comportamiento
- AAA: Arrange, Act, Assert
- Nombres descriptivos: `test('rejects password without special chars', ...)`
- Sin `setTimeout` en tests salvo casos genuinamente async

## Lo que prefiero NO hacer

- Refactors masivos sin issue específica
- Optimizaciones prematuras (sin medir)
- Abstracciones que no se usan más de 2 veces
- Configurar herramientas nuevas sin acuerdo del equipo

## Lo que sí me gusta

- Fix simple antes que fix elegante
- Borrar código mejor que añadir
- Tests que documentan comportamiento
- Errores con mensaje útil para el siguiente que los lea (incluido yo)

## Si cambia el contexto

Si aparece un nuevo agente, repo, framework, este CLAUDE.md debe actualizarse. Versionar este archivo en el repo `talent-engine-config` (o donde corresponda) y pull request si quieres modificarlo.

---

**Versión**: 1.0
**Última actualización**: <fecha>
**Owner**: Talent Engine team
