# Bloque de reglas de fábrica (para CLAUDE.md / AGENTS.md del repo destino)

<!-- derivado-de CLAUDE.md@b3243f428 — 2026-09-02 (TAL-5158, añade Variante TREN) -->
<!-- Clase EQUIVALENTE: adaptar las reglas del repo TA a las particularidades del repo
     destino. NO copiar verbatim: cada repo tiene sus propios gates, team-key, canales y
     superficies. Conservar la estructura de reglas y la cabecera de procedencia. -->

---

## Instrucciones de adaptación

1. **Cabecera de procedencia**: mantener el comentario `derivado-de path@SHA` con el SHA
   del commit del repo TA del que se extrajo este bloque. Actualizar al re-copiar.
2. **Gates locales**: ajustar al manifiesto de gates del repo destino (ver
   `assets/plantilla-manifiesto-gates.md`). No incluir gates que no existan.
3. **Linear team key**: reemplazar `TAL` por la key del equipo del repo destino.
4. **Superficies sensibles**: ajustar la lista a las superficies reales del repo destino.
5. **migration_slots**: `n/a` si el repo no tiene Supabase.

---

## Bloque base (copiar y adaptar en CLAUDE.md / AGENTS.md del repo destino)

````markdown
<!-- derivado-de CLAUDE.md@<SHA_ACTUAL> — <FECHA> -->

## Reglas de Fábrica

### Flujo obligatorio: rama → PR DRAFT → HANDOFF → merge

Todo cambio entra por rama y PR **draft** hacia `main`. Flujo:

1. Crear rama con prefijo válido (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `hotfix/`).
2. Commits + gates locales verdes:
   ```bash
   npm run typecheck && npm run lint && npm run build && npm run test:unit
   ```
3. `bash scripts/draft-handoff.sh` → sentinel `.claude/.draft-handoff` emitido.
4. Push + `gh pr create --draft` con `closes <KEY>-N` en el body.
5. Comentario HANDOFF en el PR (plantilla `docs/templates/handoff-pr-draft.md`).
6. `bash scripts/verify-handoff.sh <pr>` == 0.

El **Mergeador** (`talent-merger`) corre CodeRabbit y ejecuta el squash-merge.

### Variante TREN (lotes cohesivos)

Si el cambio es parte de un **lote cohesivo** (2+ encargos del mismo dominio/proyecto,
producidos en paralelo), aplica por defecto la variante TREN en vez del flujo draft
individual de arriba:

1. Cada pieza corre sus gates locales verdes y su propio ciclo adversarial, y **entrega
   RAMA** (sin PR propio, sin HANDOFF propio).
2. El Mergeador arma UN PR padre que integra las N ramas: **1 CodeRabbit + 1 suite + 1
   squash** para todas las piezas.
3. El PR padre cierra las N issues con `closes <KEY>-N` por cada una; los PRs individuales
   previos (si existían) quedan «superseded por padre #N».

Dos categorías distintas limitan qué entra a un tren — no se mezclan:

- **Exclusiones absolutas** (nunca en tren, sin importar tamaño): migración/operación
  destructiva (GO del lead), money-path SEV urgente (decisión CEO/lead), dominios sin
  relación.
- **Cota de tamaño** (regla de PARTICIÓN, no de exclusión): un lote que sí califica por
  dominio pero excede 60 ficheros o 5 piezas se parte en sub-trenes que cumplan ambos
  límites cada uno; sin partición válida, las piezas que no quepan vuelven al flujo
  individual draft+HANDOFF por encargo.

Mecánica completa: `talent-merger` ref 09.

### Gate requerido: `local-gates`

Branch protection de `main` exige el commit-status **`local-gates`**.
Motor: `talent-factory/scripts/run-local-gates.sh`.
Posteo canónico: `talent-factory/scripts/post-local-gates.sh <run_group> <owner/repo> <pr>`.
Anti-self-report: JAMÁS postear success sin haber corrido los gates sobre ESE head.

### Magic word

Cada issue de Linear asociada al repo usa la key `<KEY>`.
Gramática del template PR: `Closes <KEY>-N` (literal).
Gramática de PR body / receipts: `command grep -iE "(closes|fixes|resolves)[[:space:]]+<KEY>-[0-9]+"`.

### Hooks activos

| Hook | Evento | Propósito |
|------|--------|-----------|
| `check-skill.sh` | PreToolUse (Edit/Write) | Recordar skill según path editado |
| `check-push-audit.sh` | PreToolUse (Bash `git push*`) | Bloquear push sin sentinel `.claude/.audit-go` |

`core.hooksPath = .githooks` (activar con `bash scripts/setup-githooks.sh`).

### CodeRabbit — solo bloqueantes

Solo se atienden comentarios de severidad superior a minor: bugs, seguridad, OWASP,
contratos rotos, concurrencia, auth, fallos operacionales, breaking changes.
El Mergeador es el único consumidor de CR (App + CLI).

### Sentinels y copia del manifiesto (ignorados en .gitignore)

- `.claude/.cr-review-ok` — review CR-CLI limpio
- `.claude/.draft-handoff` — entrega draft validada
- `.claude/.audit-go` — audit pre-push aprobado
- `.claude/tf-manifest.conf` — copia local del manifiesto de la fábrica (la provisiona el despacho; no versionable)
- `.claude/.motor-go` — sentinel de empuje del motor
- `.claude/.cr-review-*` — resto de artefactos del review CR-CLI

El verificador de paridad exige LOS SEIS como líneas literales de `.gitignore` (sin comentar; git
debe IGNORARLOS de verdad, así que una negación `!patrón` posterior falla; `.claude/.cr-review-ok` vale
también cubierto por `.claude/.cr-review-*`). Bloque listo para pegar:

```gitignore
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
```
````
