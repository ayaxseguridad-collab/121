# Manifiesto de gates — <NOMBRE_DEL_REPO>

> Tabla canónica de gates locales para este repo.
> Consumida por `talent-factory/scripts/run-local-gates.sh`.
> Copiar al repo destino como `scripts/ci/gate-manifest.md` o equivalente.

---

## Gates activos

| gate-id | Comando | Bloqueante | Notas |
|---------|---------|------------|-------|
| `typecheck` | `npm run typecheck` | Sí | tsc --noEmit |
| `lint` | `npm run lint` | Sí | ESLint flat config |
| `build` | `npm run build` | Sí | next build; opt-in skip con `TA_DRAFT_SKIP_BUILD=1` en flotas débiles |
| `unit` | `npm run test:unit` | Sí | Vitest; gate `unit` de local-gates |
| `i18n` | `npm run i18n:check` | Sí (si aplica) | paridad de claves es/en/pt-BR |
| `flags` | `npm run flags:check` | Sí (si aplica) | consistencia de feature flags |
| `tenant` | `npm run tenant:check` | Sí (si aplica) | ratchet anti-hardcodeo de marca |
| `db-guards` | `scripts/ci/run-db-guards-local.sh` | Sí (si hay Supabase) | Supabase efímero + pgTAP |
| `integration` | `scripts/ci/run-integration-local.sh` | Condicional | según política del repo |
| `e2e-<familia>` | `scripts/ci/run-e2e-shard-local.sh <familia> <shard>` | Condicional | según registro e2e-shards.json |

**Instrucción de uso**: eliminar las filas que NO existan en este repo. No inventar gate-ids.

---

## Registro de shards E2E (si aplica)

Archivo `scripts/ci/e2e-shards.json` del repo:

```json
{
  "shards": [
    { "familia": "ola3", "shard": "1/3", "bloqueante": true },
    { "familia": "ola3", "shard": "2/3", "bloqueante": true },
    { "familia": "ola3", "shard": "3/3", "bloqueante": true }
  ]
}
```

Política: anti-reducción (nunca quitar un shard de una familia bloqueante sin GO del lead).

---

## Flujo de posteo del status `local-gates`

**Vía canónica** (ÚNICO método, no break-glass):
```bash
talent-factory/scripts/post-local-gates.sh <run_group> <owner/repo> <pr>
```

**Break-glass trazado** (solo si el motor no está disponible, anotar motivo + SHA + quién):
```bash
gh api repos/<owner/repo>/statuses/<sha> \
  -f state=success \
  -f context=local-gates \
  -f description="break-glass: <motivo>" \
  -f target_url="<url_evidencia>"
```

Anti-self-report: JAMÁS postear `local-gates=success` sin haber corrido los gates de verdad
sobre ESE head exacto. Cada push nuevo re-corre y re-postea.
