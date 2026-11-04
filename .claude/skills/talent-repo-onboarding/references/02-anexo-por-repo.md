# Referencia 02 — Anexo por repo

> **Fuente de verdad**: el estado REAL del repo destino y la API de GitHub AL EJECUTAR.
> Si la config viva diverge del PUT canónico → PARAR y escalar al lead (verdad > foto).

El **Anexo por repo** es el único artefacto variable por destino: todo lo demás (capas B,
C, D) es idéntico o equivalente al repo TA. El Anexo sirve de ficha de identidad que el
verificador, la estación de merge y los coordinadores consumen para no hard-codear valores.

Plantilla en `assets/plantilla-anexo-por-repo.md`.

---

## Estructura canónica del Anexo

### §1 — Identidad

| Campo | Descripción |
|-------|-------------|
| `repo_slug` | `owner/repo` exacto de GitHub |
| `nombre_legible` | Nombre humano del proyecto |
| `linear_workspace` | Workspace de Linear (slug URL) |
| `linear_team_key` | Key del equipo Linear (p. ej. `ABC`, `ENG`, `CRM`) |
| `linear_team_id` | UUID interno del team en Linear |
| `initiative_id` | UUID de la initiative en `Producto Ejemplo` |

La `linear_team_key` gobierna el matcher `TF_LINEAR_TEAM_KEY` del verificador y el template
PR (campo `Closes <KEY>-N`). Un key incorrecto produce falsos negativos en el magic-word
y falsos positivos en checks cruzados.

### §2 — Gates locales

Lista de gates que el motor `run-local-gates.sh` ejecuta para ESE repo:

```
typecheck      npm run typecheck
lint           npm run lint
build          npm run build (TA_DRAFT_SKIP_BUILD=1 opt-in en flotas débiles)
unit           npm run test:unit
i18n           npm run i18n:check        (si aplica)
flags          npm run flags:check       (si aplica)
tenant         npm run tenant:check      (si aplica)
db-guards      scripts/ci/run-db-guards-local.sh  (si hay Supabase)
```

Cada gate tiene un `gate-id` estable que registra el manifiesto de gates del repo
(`assets/plantilla-manifiesto-gates.md`).

### §3 — Protocolo de migraciones

Indica si el repo tiene Supabase y la cadena de apply:

- **Supabase prod ref** (p. ej. `abcdefghijklmnopqrst`)
- **Método de apply** (Management API vs `supabase db push --linked`)
- **Slots en HANDOFF** (`migration_slots: N` o `migration_slots: n/a`)
- **Quién aplica** (Mergeador o canal — por defecto Mergeador)

Sin Supabase: `migration_slots: n/a` en todos los HANDOFFs; omitir esta sección.

### §4 — Superficies con path-patterns

Tabla `superficie → path_pattern → acción extra` para el verificador de la estación de
merge (solo las que divergen del default):

| Superficie | Path pattern | Acción extra |
|------------|-------------|--------------|
| `auth` | `src/lib/supabase/**` | GO lead en destructivas |
| `commerce` | `src/app/**/comercio/**` | GO lead en destructivas |
| `migrations` | `supabase/migrations/**` | Renumerar slots + apply post-merge |
| `llm` | `src/lib/llm/**` | Cost tracking review |

Suficiente con listar las excepciones; el default (ningunea → review normal) aplica al
resto.

### §5 — Actor post-merge

Quién ejecuta acciones después de que el Mergeador cierra el PR:

- **Deploy automático**: sí/no (Railway source-native, etc.)
- **Actor de migraciones**: `talent-merger` (default)
- **Notificación al lead**: canales (Slack/DM) y umbral (siempre vs solo errores)

### §6 — Lista de autoridades de receipts

CSV de `user.id` de GitHub autorizados para firmar atestaciones en ESTE repo.
Default: vacío → todo receipt rechazado (fail-closed). El verificador lo consume
vía `TRO_RECEIPT_AUTHORITIES` o el archivo `assets/receipt-authorities.txt`.

Formato: un `user.id` (entero) por línea en `assets/receipt-authorities.txt`,
comentarios con `#`.

---

## Dónde vive el Anexo

El Anexo se guarda en el **repo TA** (no en el repo destino) bajo:

```
docs/reference/onboarding-anexo-<slug>.md
```

Donde `slug` es el nombre del repo sin el owner (p. ej. `onboarding-anexo-crm-sistema.md`).
No se committea en el repo destino para evitar que quede desactualizado sin control.

El verificador consume el Anexo a través de variables de entorno y del archivo
`assets/receipt-authorities.txt` del propio skill (copiado al repo destino si aplica).

---

## Anti-patrones documentados

| Error | Consecuencia | Corrección |
|-------|-------------|------------|
| `linear_team_key` incorrecto | Magic-word false-negative / falso verde cruzado | Verificar key en Linear UI → team settings |
| Listar gates de otro repo | Motor local-gates falla con gate inexistente | Copiar solo los gate-ids que existen en el repo |
| Lista de autoridades vacía en prod | Todo receipt rechazado (exit 3 permanente) | Añadir los `user.id` de los firmantes autorizados |
| Slots de migración incorrectos | Mergeador falla al renumerar | Recontar con `supabase migration list` antes de abrir el PR |
