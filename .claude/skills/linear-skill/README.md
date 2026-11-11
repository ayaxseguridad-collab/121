# Linear Skill — Talent Engine

Skill de Claude Code para gestión de Linear en el equipo Talent Engine de Talent Network.

## Qué hace

Automatiza y estandariza la operación del equipo de desarrollo en Linear: triage, planning, ejecución, retro y delegación a agentes IA. Implementa **The Linear Method** adaptado al contexto de un equipo pequeño (2-3 humanos + agentes IA) que mantiene 5 plataformas digitales.

Capacidades principales:

- Crear/buscar/actualizar issues con dedupe automático
- Crear projects con milestones siguiendo el Linear Method
- Triage estructurado del backlog
- Delegación segura a agentes IA (Cyrus, Cursor, Codex)
- Cycle planning semanal y retro
- Generación de reportes y project updates
- Operaciones batch con paginación y rate limit
- Verificación de webhooks de Linear (HMAC + anti-replay)
- Subida de attachments via signed URL
- Customer Needs vinculados a issues

## Instalación

### Prerequisito: Claude Code instalado

Si aún no lo tienes:

- macOS/Linux: <https://claude.com/code>
- Verifica con: `claude --version`

### Paso 1 — Descomprimir el skill

```bash
# Donde sea que descomprimas (ejemplo: ~/.claude/skills/)
mkdir -p ~/.claude/skills
cd ~/.claude/skills
unzip /ruta/a/linear-skill.zip
```

Esto crea `~/.claude/skills/linear-skill/` con todo el contenido.

### Paso 2 — Configurar el token de Linear (token-only, NO MCP)

Este repositorio opera Linear por la **API GraphQL directa** con un **token por carril**, nunca por
el servidor MCP.

1. Pon `LINEAR_API_KEY=<tu token>` en `.env.local` (gitignored — nunca en el repo, nunca tecleado en la shell).
   La clave se busca por este orden: `LINEAR_API_KEY` ya exportada; si `TA_OPERATION_ENV` está definida
   y no vacía, el fichero al que apunta y SOLO ese (así la reciben las sesiones de rol de una
   instalación; si falta o no trae la clave es un error con la ruta, no se mira la raíz del repo); si
   no, `.env.local` en la raíz del repo.
2. Preferido: usa el cliente `scripts/linear-client.ts` (resuelve el token como arriba y no lo expone). Para una
   verificación rápida por `curl`, **el token NUNCA va en argv** (sería visible en `/proc/pid/cmdline`):
   se resuelve la clave como arriba, se carga sin ejecutar el archivo y se pasa a curl
   por un **archivo `--config` 0600** (misma postura argv-hygiene que `scripts/cr-review.sh` del repo,
   regla 18). La verificación **falla ante error HTTP y ante `errors` de GraphQL**:

   ```bash
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   if [ -z "${LINEAR_API_KEY:-}" ]; then
     if [ -n "${TA_OPERATION_ENV:-}" ]; then ENV_FILE="$TA_OPERATION_ENV"; ENV_DE="la variable TA_OPERATION_ENV"
     else ENV_FILE="$REPO_ROOT/.env.local"; ENV_DE="la raíz del repo"; fi
     [ -f "$ENV_FILE" ] || { echo "FALTA el fichero de LINEAR_API_KEY: $ENV_FILE (lo indica $ENV_DE) — parar y avisar al lead" >&2; return 1 2>/dev/null || exit 1; }
     LINEAR_API_KEY=$(grep -E '^LINEAR_API_KEY=.+' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
     [ -n "$LINEAR_API_KEY" ] || { echo "FALTA LINEAR_API_KEY en $ENV_FILE (lo indica $ENV_DE) — parar y avisar al lead" >&2; return 1 2>/dev/null || exit 1; }
   fi
   cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
   printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"   # printf es builtin → el token NO entra en argv
   resp=$(curl -sS --fail-with-body --config "$cfg" -H "Content-Type: application/json" \
     -d '{"query":"{ viewer { id name } }"}' https://api.linear.app/graphql) \
     || { echo "error HTTP: $resp" >&2; return 1 2>/dev/null || exit 1; }
   printf '%s' "$resp" | grep -q '"errors"' && { echo "GraphQL errors: $resp" >&2; return 1 2>/dev/null || exit 1; }
   printf '%s\n' "$resp"
   ```

No añadas `.mcp.json` ni `claude mcp add`: la operación es 100 % por token + GraphQL directo.

### Paso 3 — Personalizar solo lo que es tuyo

Desde v1.4 el config **ya no trae placeholders**: `team`, `workflowStates`, `initiatives` y
`projects` vienen con ids verificados en vivo contra el workspace, y `labels` es la autoridad de
taxonomia del skill. Personalizar lo gobernado no es adaptarlo, es **romper la paridad** que
`check-taxonomy-parity.sh` comprueba.

Edita `~/.claude/skills/linear-skill/examples/talent-engine-config.json` **solo** en:

- `agents.*.userId` — los usuarios de agente son propios de cada workspace.
- Overrides tuyos que anadas de forma deliberada.

**El bloque `labels` no se toca.** Si operas contra OTRO workspace, no edites a mano: regenera el
config contra el tuyo y vuelve a pasar el gate de paridad.

Forma rápida de obtenerlos:

1. Crea una Personal API key en Linear (Settings → Security & access → Personal API keys)
2. Ejecuta:

```bash
# El cliente resuelve la clave solo: LINEAR_API_KEY exportada > fichero de TA_OPERATION_ENV >
# .env.local de la raíz del repo (no la teclees en la shell: quedaría en el historial). Se ejecuta
# desde el repo, por ruta absoluta, para que la raíz del repo sea la del proyecto.
bash <raíz-del-repo>/scripts/tsx.sh ~/.claude/skills/linear-skill/scripts/linear-client.ts --action whoami
```

Esto imprime tu workspace info. Luego ejecuta queries puntuales contra GraphQL para obtener los UUIDs específicos. Las queries están listadas dentro del JSON en el campo `queries_to_fill_uuids`.

### Paso 4 (opcional) — Instalar dependencias para los scripts

```bash
cd ~/.claude/skills/linear-skill
npm init -y
npm install -D tsx@4 typescript@6 @types/node@24
```

Los scripts complementan las llamadas GraphQL directas; son especialmente útiles para batch jobs y webhooks.

## Uso básico

Una vez instalado, en cualquier sesión de Claude Code puedes pedir:

```text
"Crea una issue para implementar OAuth en el login de Talent Land Online"
"Lista mis issues del cycle actual"
"Planifiquemos el cycle de esta semana"
"Cierra el cycle y genera retro"
"Delega TAL-42 a Cyrus"
"Cuántos bugs nuevos hay esta semana"
"Genera el weekly report"
```

Claude Code activará el skill automáticamente cuando detecte que el contexto es Linear.

## Estructura del skill

```text
linear-skill/
├── SKILL.md                # entry point (siempre cargado)
├── README.md               # este archivo
├── references/             # documentación bajo demanda
│   ├── 01-data-model.md
│   ├── 02-mcp-tools.md          # (DEPRECADO) puntero a 03
│   ├── 03-graphql-cheatsheet.md
│   ├── 04-rate-limits.md
│   ├── 05-webhooks.md
│   ├── 06-agents-sdk.md
│   └── 07-linear-method.md
├── workflows/              # playbooks paso a paso
│   ├── 01-crear-project.md
│   ├── 02-triage-y-delegar.md
│   ├── 03-cycle-planning.md
│   ├── 04-cycle-review.md
│   ├── 05-bug-handling.md
│   └── 06-feedback-a-issue.md
├── prompts/                # plantillas listas para usar
│   ├── crear-issue.md
│   ├── buscar-y-deduplicar.md
│   ├── batch-update.md
│   ├── weekly-report.md
│   ├── issue-template-feature.md
│   └── issue-template-bug.md
├── scripts/                # código TypeScript ejecutable
│   ├── linear-client.ts
│   ├── verify-webhook.ts
│   ├── batch-issues.ts
│   └── upload-attachment.ts
└── examples/               # configuración del workspace
    ├── talent-engine-config.json
    ├── label-taxonomy.json
    ├── agent-guidance.md
    ├── claude-md-template.md
    └── issue-templates/
        ├── feature.md
        ├── bug.md
        └── tarea-delegable-a-ia.md
```

## Cómo cargar referencias bajo demanda

El skill usa **progressive disclosure**: el SKILL.md siempre está en contexto (es corto), las referencias se cargan solo cuando hacen falta. La tabla en SKILL.md ("Cuándo cargar qué referencia") guía esto.

Si quieres que Claude Code lea una referencia específica de antemano, puedes pedirlo:

```text
"Lee references/05-webhooks.md, vamos a configurar un webhook"
```

## Configuración recomendada de Linear (pre-skill)

Idealmente el workspace ya tiene:

- ✅ Cycles habilitados (1 semana)
- ✅ Triage habilitado en el team
- ✅ Estimates en escala Fibonacci (1, 2, 3, 5, 8)
- ✅ Workflow states: Triage → Backlog → Todo → In Progress → In Review → Done/Canceled
- ✅ Initiatives habilitadas
- ✅ Agent guidance configurado (pegar `examples/agent-guidance.md`)
- ⚠️ Labels de la taxonomía (ver `examples/label-taxonomy.json`) — **algunas pueden faltar**

Si hay configuración faltante, el skill puede ayudarte a crearla:

```text
"Configura los labels que faltan según la taxonomía del skill"
```

## Solución de problemas

### El token de Linear no responde

```bash
# Cargar el token (extracción segura, exige valor NO vacío) y probarlo SIN exponerlo en argv.
# Orden: LINEAR_API_KEY exportada > fichero de TA_OPERATION_ENV (solo ese) > .env.local de la raíz del repo
REPO_ROOT="$(git rev-parse --show-toplevel)"
if [ -z "${LINEAR_API_KEY:-}" ]; then
  if [ -n "${TA_OPERATION_ENV:-}" ]; then ENV_FILE="$TA_OPERATION_ENV"; ENV_DE="la variable TA_OPERATION_ENV"
  else ENV_FILE="$REPO_ROOT/.env.local"; ENV_DE="la raíz del repo"; fi
  [ -f "$ENV_FILE" ] || { echo "FALTA el fichero de LINEAR_API_KEY: $ENV_FILE (lo indica $ENV_DE)" >&2; return 1 2>/dev/null || exit 1; }
  LINEAR_API_KEY=$(grep -E '^LINEAR_API_KEY=.+' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
  [ -n "$LINEAR_API_KEY" ] || { echo "FALTA o vacío LINEAR_API_KEY en $ENV_FILE (lo indica $ENV_DE)" >&2; return 1 2>/dev/null || exit 1; }
fi
cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"
resp=$(curl -sS --fail-with-body --config "$cfg" -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id name } }"}' https://api.linear.app/graphql) \
  || { echo "error HTTP: $resp" >&2; return 1 2>/dev/null || exit 1; }
# Token invalido/no autenticado ya cae en 401 y lo atrapa --fail-with-body arriba (verificado
# empiricamente). Pero HTTP 200 tampoco basta: Linear puede devolver 200 con `errors` para fallos
# a nivel de campo (p.ej. falta de permiso sobre un recurso puntual) — de ahi este segundo check.
printf '%s' "$resp" | grep -q '"errors"' && { echo "GraphQL errors: $resp" >&2; return 1 2>/dev/null || exit 1; }
printf '%s\n' "$resp"
```

Nota: `^LINEAR_API_KEY=.+` exige que la línea tenga valor — un `LINEAR_API_KEY=` vacío NO pasa. El token va por `--config` file (no en argv). Si falta o devuelve error de auth, PARAR y avisar al lead — no fabricar issues sin trazabilidad.

### Errores de "tool not found" al pedir cosas de Linear

Este skill NO usa MCP: las operaciones van por GraphQL directo (ver `references/03-graphql-cheatsheet.md`) o los scripts en `scripts/`. No hay tools MCP que conectar.

### Errores de "RATELIMITED"

Estás haciendo demasiadas operaciones. Espera 1 minuto y reintenta. Si es batch, usa `scripts/batch-issues.ts` que tiene throttling correcto.

### El skill no se activa cuando hablo de Linear

Puede que el SKILL.md no esté siendo cargado. Verifica:

```bash
ls ~/.claude/skills/linear-skill/SKILL.md
```

Si existe, puede que Claude Code esté en modo donde no auto-detecta skills. Forzar con:

```text
"Usa el skill linear-skill: <tu petición>"
```

## Actualizar el skill

**OJO — el bloque `labels` de `examples/talent-engine-config.json` está GOBERNADO** (es la
proyección de la autoridad `label-taxonomy.json` + recibo, validada por
`scripts/check-taxonomy-parity.sh`): NUNCA restaures el config completo desde una copia
anterior — repondrías taxonomía muerta, placeholders y selectores inexistentes. Lo único
que se conserva es tu personalización no gobernada (UUIDs de `team`, `initiatives`,
`workflowStates` y `agents.*.userId`), re-aplicada sobre el config NUEVO.

Secuencia ÚNICA (el backup va ANTES de borrar nada):

```bash
cd ~/.claude/skills/
cp linear-skill/examples/talent-engine-config.json /tmp/config-anterior.json  # 1) backup PRIMERO (solo referencia)
rm -rf linear-skill/                                                          # 2) recién ahora se borra
unzip /ruta/a/linear-skill-nuevo.zip                                          # 3) versión nueva
# 4) desde v1.4 el config trae team/estados/initiatives/projects verificados en vivo (2026-09-05):
#    re-aplica A MANO (o con jq) solo lo que hayas personalizado (agents.*.userId u overrides propios)
#    desde /tmp/config-anterior.json — el bloque labels NO se toca
bash linear-skill/scripts/check-taxonomy-parity.sh                            # 5) rc 0 OBLIGATORIO
```

## Filosofía

Este skill hace cumplir 4 reglas no negociables:

1. **Una issue, un dueño, un estado claro**
2. **Dedupe siempre antes de crear**
3. **Trabajo de IA marcado y revisado por humano**
4. **Sin ruido en el sistema**

Si alguna de estas reglas te molesta, probablemente estés intentando un anti-patrón. El Linear Method existe por motivos. Ver `references/07-linear-method.md`.

## Versiones

| Versión | Fecha | Cambios |
|---|---|---|
| v1.0 | 2026-05-04 | Versión inicial. SKILL completo con 7 referencias, 6 workflows, 6 prompts, 4 scripts, 5 ejemplos. |
| v1.1 | 2026-07-17 | TAL-2005 — taxonomía `type/*` → `kind:*` corregida en SKILL.md/prosa/ejemplos (16 archivos). |
| v1.2 | 2026-07-18 | TAL-2007 — cumplimiento estructural Gold Standard: Quick Start, tabla de versiones (`@linear/sdk` 88.2.0), diagramas ASCII (SKILL.md + 5 references), Cross-Skill Integration (nextjs-web + coderabbit-talent), CircuitBreaker + CLI `--action`/`--help` + shebang + tipos `enum`/`type` en los 4 scripts, webhooks Next.js App Router, frontmatter `name`/YAML corregido. |
| v1.3 | 2026-07-24 | TAL-3366 — saneamiento contra Linear vivo: `label-taxonomy.json` como autoridad única de nombres/grupos (recibo sanitizado + gate `check-taxonomy-parity.sh`, paridad verificable con la API), `talent-engine-config.json` como proyección de UUIDs fail-closed (duplicados → id null + sites por team), ramas de examples/workflows alineadas al contrato del SKILL.md, guard de `--concurrency` previo a credenciales, limpieza del whitespace heredado del fundador y 59 ratchets nuevos en `invariants.tsv` (INV-LS-009..067, incluido el ciclo correctivo M1-M6 del review). |
| v1.4 | 2026-09-05 | TAL-5432 — corte 5-sep-2026 contra Linear vivo (investigación TAL-5428, 20 veredictos): `issueAddLabel`/`issueRemoveLabel` y `addedLabelIds`/`removedLabelIds` (el gotcha «no existe addLabel» era falso), `issueBatchUpdate`/`issueBatchCreate` (≤50; el «no hay batch» era falso), `IssueRelationType` con `similar`, plantillas nativas (`templateCreate`, `teamId` UUID), tabla de errores `RATELIMITED`/`INPUT_ERROR`/`INVALID_INPUT` con `first` ≤250 y cap 10.000, `WorkflowState.type` como String de 7 literales (`duplicate`), contexto real del team (cycles OFF, estimación como convención, 10 initiatives, 9 estados), webhooks al enum vivo de 22 recursos (`IssueSLA set/highRisk/breached`, sin `Team`, `webhookRotateSecret`, 6 IPs, payload real de `AgentSessionEvent`), Loops y capa de agentes al día, SDK 93.0.1 sin pin literal, recibo de 108 labels y `talent-engine-config.json` sin placeholders, scripts con clasificación de errores y batch real, secciones Troubleshooting y Fuera de alcance, contenido de uso libre marcado, ZIP con raíz `linear-skill/` y ratchets nuevos (INV-LS-068+). |

## Contribuir

Este skill es miembro del paquete de fábrica: el canónico vive en el repo motor `talent-factory`
(`skills/linear-skill`) y se propaga a los repos de producto con `scripts/paquete/sync-package.sh`.
Las mejoras se hacen PRIMERO en el canónico; la vía de espejo —corregir en el producto y subirlo al
motor con su issue de sincronización inversa— es la que la fábrica usa hoy para la doctrina, y va
igualmente por revisión. Nunca se editan copias sueltas. **La regla vigente de propagación y su
estado viven en `scripts/paquete/PAQUETE.md`; aquí no se re-enuncia.**

**`sync-package.sh --apply` está VETADO mientras haya divergencia declarada** (portador `TAL-5757`):
es destructivo en las dos direcciones y borra sin avisar lo que el otro lado acaba de arreglar. La
propagación va por bundle o por el espejo, con revisión de por medio. Para compartir una mejora:

1. Edita los archivos en el canónico del motor (o abre la issue de espejo) y pasa `validate-package.sh`
2. Comprueba la paridad con `sync-package.sh --check` y **adjunta su salida**, declarando el par de
   árboles comparados por sha; con divergencia se declara la lista y su portador, nunca un verde
3. Re-empaqueta con `linear-skill/` como ÚNICA raíz del ZIP (así `unzip` dentro de `.claude/skills/` deja `linear-skill/SKILL.md` en su sitio; TAL-3429):
   `cd ~/.claude/skills && zip -r "$HOME/linear-skill-v1.4.zip" linear-skill/ && unzip -Z1 "$HOME/linear-skill-v1.4.zip" | grep -v '^linear-skill/' | grep -c . # → 0 (unzip -Z1 lista solo nombres, sin cabeceras ni totales)`
4. Compártelo con el equipo

## Licencia

Uso interno Talent Network / Talent Engine.
