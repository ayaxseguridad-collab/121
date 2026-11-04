# Anexo por repo — <NOMBRE_DEL_REPO>

> Completar TODOS los campos antes de usar el verificador `verify-repo-parity.sh`.
> Guardar en el repo TA como `docs/reference/onboarding-anexo-<slug>.md`.
> NO committear en el repo destino.

---

## §1 — Identidad

| Campo | Valor |
|-------|-------|
| `repo_slug` | `<owner/repo>` |
| `nombre_legible` | `<Nombre legible del proyecto>` |
| `linear_workspace` | `<workspace-slug>` |
| `linear_team_key` | `<KEY>` (p. ej. `TAL`, `ENG`, `CRM`) |
| `linear_team_id` | `<uuid>` |
| `initiative_id` | `<uuid>` |

**Verificación rápida de la key**:
```bash
TF_LINEAR_TEAM_KEY=<KEY> bash verify-repo-parity.sh <REPO_DIR>
```

---

## §2 — Gates locales

Lista de gate-ids activos para este repo (copiar solo los que EXISTEN):

```
typecheck      npm run typecheck
lint           npm run lint
build          npm run build
unit           npm run test:unit
# Añadir / quitar según el repo:
# i18n         npm run i18n:check
# flags        npm run flags:check
# tenant       npm run tenant:check
# db-guards    scripts/ci/run-db-guards-local.sh
```

Motor de gates: `talent-factory/scripts/run-local-gates.sh`
Archivo de registro de shards: `scripts/ci/e2e-shards.json` (si aplica)

---

## §3 — Protocolo de migraciones

- **¿Tiene Supabase?**: Sí / No
- **Supabase prod ref**: `<ref>` (o n/a)
- **Método de apply**: Management API / `supabase db push --linked`
- **Quién aplica**: Mergeador (default) / <otro>
- **`migration_slots`**: n/a (sin Supabase) / N (número de slots típico)

---

## §4 — Superficies con path-patterns (solo excepciones al default)

| Superficie | Path pattern | Acción extra |
|------------|-------------|--------------|
| `auth` | `src/lib/supabase/**` | GO lead en destructivas |
| _Añadir / quitar según el repo_ | | |

---

## §5 — Actor post-merge

- **Deploy automático**: Sí / No (`<plataforma>`)
- **Actor de migraciones**: `talent-merger`
- **Notificación al lead**: `<canal>` / siempre / solo errores

---

## §6 — Lista de autoridades de receipts

Archivo: `.claude/skills/talent-repo-onboarding/assets/receipt-authorities.txt`
(uno por línea, enteros `user.id` de GitHub)

```
# Autoridades para <owner/repo>
# Formato: user.id (entero de GitHub), una por línea
# Default: VACÍO → fail-closed (todo receipt rechazado)

# Ejemplo:
# 12345678
```

Para verificar el `user.id` de un usuario de GitHub:
```bash
gh api users/<login> --jq '.id'
```

---

## Notas operativas

- Fecha de onboarding: `AAAA-MM-DD`
- Lead responsable: `<@handle>`
- Último ensayo E2E completado: `AAAA-MM-DD` / Pendiente
- Primer encargo de producción: `<KEY>-N` / Pendiente
