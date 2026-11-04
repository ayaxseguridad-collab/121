# Referencia 03 — Verificación, ensayo y receipts

> **Fuente de verdad**: el estado REAL del repo destino y la API de GitHub AL EJECUTAR.

---

## Definition of Ready (DoR) — 8 puntos

Checklist ejecutable que certifica que un repo recién montado está listo para recibir
encargos de producción. Cada punto tiene un verificador canónico.

| # | Punto | Verificador |
|---|-------|-------------|
| 1 | Branch protection `main` (A2 — 12 valores) | `bash verify-repo-parity.sh` bloque A2 |
| 2 | Repo settings (A2b — 4 valores) | `bash verify-repo-parity.sh` bloque A2b |
| 3 | Scripts IDÉNTICOS (B — 10 artefactos) | `bash verify-repo-parity.sh` bloque 1 IDENTICO |
| 4 | Artefactos EQUIVALENTES (C — 8 artefactos) | `bash verify-repo-parity.sh` bloque 1 EQUIVALENTE |
| 5 | Entorno (D — hookspath + skill + perfil) | `bash verify-repo-parity.sh` bloque 1 ENTORNO |
| 6 | Magic word con KEY del equipo Linear | `bash verify-repo-parity.sh` bloque 4 |
| 7 | Gates locales verdes (primer ciclo) | `bash scripts/draft-handoff.sh` en PR de prueba |
| 8 | Receipts de los 7 checks MANUAL válidos | `bash verify-repo-parity.sh` bloque 5 exit 0 |

El DoR es BLOQUEANTE: ningún encargo de producción puede despacharse a un repo con puntos
pendientes. Los puntos 1-6 son duros (exit 1 si fallan). Los puntos 7-8 son manuales
(exit 3 mientras no haya receipts válidos).

---

## Ensayo general E2E

El ensayo E2E es la validación integral del ciclo completo antes de activar el canal de
producción. Protege la ventana de entrega: un fallo en producción cuesta más que el
tiempo del ensayo.

**Pasos del ensayo:**

1. **Crear issue de prueba** en Linear (tipo `chore`, estimate 1, clave del team correcto).
2. **Crear rama** `chore/ensayo-e2e-setup` con un cambio trivial (p. ej. comentario en
   `CLAUDE.md`).
3. **Correr gates locales** (`draft-handoff.sh`) → sentinel `.claude/.draft-handoff` emitido.
4. **Push + PR draft** con `closes <KEY>-N` en el body.
5. **Comentario HANDOFF** (plantilla `docs/templates/handoff-pr-draft.md`) en el PR.
6. **`bash scripts/verify-handoff.sh <pr>`** → exit 0.
7. **CodeRabbit** (Mergeador): `bash scripts/cr-review.sh` limpio o App + label `cr-review`.
8. **Merge squash** → issue a Done (magic word activa Linear).
9. **Deploy** (Railway/CI): verificar smoke en staging/prod si aplica.
10. **Receipts E2E**: completar el check `ensayo-e2e` con su receipt + atestación.

Si cualquier paso falla: PARAR, diagnosticar, corregir antes de activar producción.

---

## Entrega de artefactos fuera de git — sha256 fail-closed (TAL-3318)

Parte del montaje viaja fuera del repo destino y fuera de todo control de versiones compartido:
el manifiesto del motor (`manifiestos/<proyecto>.conf`), bundles de scripts, paquetes de skills
para la flota. Para esos artefactos no hay hash de git que dé paridad — el protocolo es:

1. **El emisor declara** el `sha256sum` de CADA artefacto junto con la entrega (misma
   línea/mensaje; nunca «te lo dejé por ahí»).
2. **El receptor verifica POST-instalación** (`sha256sum -c` o comparación del digest) ANTES de
   usar el artefacto, y registra el hash verificado en la evidencia del montaje.
3. **Fail-closed**: hash ausente, no verificado o discrepante → el artefacto NO está entregado;
   el paso queda en HOLD y se re-pide la entrega. Un artefacto «declarado entregado» sin hash
   verificable no existe (lección del arranque CRM 2026-07-22: horas de HOLD por un «paquete v3»
   citado que nunca se materializó — el canónico real era otra versión, recuperada y re-hasheada).

**Validador del manifiesto del motor** (ruta EXACTA — G12 del SKILL.md): el manifiesto `TF_*` de
la fábrica se valida con `.claude/skills/talent-channels/scripts/validate-manifest.sh` del repo
TA. Vive en el skill `talent-channels`, NO en `talent-factory/scripts/` (esa ruta no existe).
Rc 0 = válido; rc≠0 = inválido (token `ABORT:*`).

---

## Límites honestos del verificador (qué es MANUAL y por qué)

Los 7 checks MANUAL no pueden ser duros porque requieren evidencia fuera del repo:

| check_id | Por qué es MANUAL |
|----------|-------------------|
| `linear-integration` | Requiere PR en Linear con el issue cerrado por magic word — no verificable en local sin acceso a la API de Linear |
| `cr-app-instalada` | Requiere que la GitHub App de CodeRabbit esté instalada y haya revisado un PR real |
| `cr-app-draft-silencio` | Requiere verificar que la App NO genera reviews en PRs draft (`drafts: false`) |
| `push-sentinel-block` | Requiere que el hook `pre-push` haya bloqueado un push sin sentinel en el repo destino |
| `audit-issue-maquina-limpia` | Requiere correr `audit-go.sh` en una máquina limpia del equipo del repo |
| `ensayo-e2e` | Requiere el ciclo completo descrito arriba |
| `accesos-y-deploy` | Requiere verificar accesos reales y que el deploy llega a producción |

El verificador emite exit 3 (MANUAL-PENDING) hasta que se provean receipts válidos.
**Esto es correcto**: un exit 3 honesto es mejor que un exit 0 falso.

---

## Contrato de receipts

### Esquema de nivel superior (10 campos)

```json
{
  "receipt_version": "1",
  "check_id":        "<uno de los 7 check_id>",
  "repo":            "owner/repo",
  "branch":          "main",
  "sha_probado":     "<sha del commit HEAD cuando se realizó el check>",
  "sha_canonico":    "<sha de origin/main del repo TA al momento>",
  "actor":           "<login GitHub del firmante>",
  "issued_at":       "2026-01-15T10:00:00Z",
  "expires_at":      "2026-01-22T10:00:00Z",
  "evidencia":       { ... }
}
```

**TTL**: `expires_at - issued_at` debe ser exactamente `604800` segundos (7 días).
**Reloj**: `issued_at > now + 300 s` → rechazo (reloj del sistema adelantado).
**Expirado**: `expires_at < now` → rechazo.

### Forma de `evidencia` por check_id (sellada)

| check_id | Campos de evidencia |
|----------|---------------------|
| `linear-integration` | `pr_url`, `issue_id`, `attest_comment_id` |
| `cr-app-instalada` | `pr_url`, `review_id`, `attest_comment_id` |
| `cr-app-draft-silencio` | `pr_url`, `attest_comment_id` |
| `push-sentinel-block` | `commit_sha`, `branch`, `attest_comment_id` |
| `audit-issue-maquina-limpia` | `issue_id`, `salida_sha256`, `attest_comment_id` |
| `ensayo-e2e` | `pr_url`, `status_context`, `issue_id`, `attest_comment_id` |
| `accesos-y-deploy` | `smoke_urls_codes`, `anexo_ref`, `attest_comment_id` |

`attest_comment_id` es un **sub-campo sellado de `evidencia`** presente en TODOS los
check_ids. El verificador lo extrae con `jq -r '.evidencia.attest_comment_id'`.

### Atestación y binding anti-reutilización

La atestación es un **comentario de issue/PR de GitHub del repo destino**. El verificador
lo relee con `gh api repos/<repo>/issues/comments/<attest_comment_id>`.

La **primera línea exacta** del body del comentario debe ser:

```
attest v1 check_id=<id> repo=<owner/repo> branch=<branch> sha_probado=<sha> sha_canonico=<sha> actor=<user.id> evidencia_sha256=<sha256(jq -S -c .evidencia)>
```

- `actor` en el binding = `.user.id` (entero) releído por la API — NUNCA el campo `actor`
  del receipt (que es el login, no el ID).
- `evidencia_sha256` = `sha256(jq -S -c '.evidencia' receipt.json)` (canonicalización jq).
- Comparación literal campo a campo. Cualquier desajuste → rechazo (exit 3).
- Un comentario de autor autorizado escrito para OTRO check/repo/SHA → rechazo.

**Lista de autoridades**: el verificador consume `TRO_RECEIPT_AUTHORITIES` (CSV de
enteros `user.id`) o `assets/receipt-authorities.txt`. Default vacío → fail-closed.

### Protocolo de emisión de atestación (bootstrap circular)

`attest_comment_id` vive dentro de `evidencia`, que a su vez se hashea en el binding
del comentario. Protocolo para romper la dependencia circular:

1. Postear un comentario **placeholder** en el issue/PR → obtener el `id` del comentario.
2. Construir `evidencia` completa incluyendo el `attest_comment_id` real (el id obtenido).
3. Calcular `evidencia_sha256 = sha256(jq -S -c '.evidencia' receipt.json)`.
4. Editar el comentario con el body final que contiene la línea `attest v1 ...` completa.
5. Emitir el receipt JSON con la `evidencia` final.

El verificador relee el comentario con `gh api` (o stub en `TRO_ATTEST_DIR`), valida el
binding exacto y el `user.id` contra la lista de autoridades.

### Readback inyectable para fixtures/tests

En tests, el fetch de la API de GitHub vive detrás de la función `attest_readback`:

- **Producción**: `gh api repos/<repo>/issues/comments/<comment_id>`
- **Tests**: si `TRO_ATTEST_DIR` está definido, se sirve `$TRO_ATTEST_DIR/<comment_id>.json`
  con exactamente el shape `{user:{id,login}, body}` de `gh api`.

El stub SOLO reemplaza la llamada de red. Toda la validación (binding, evidencia_sha256,
autoridad, TTL, reloj) corre idéntica. Un fixture no puede fabricar un verde: el
comentario stub debe contener el binding EXACTO con un `user.id` autorizado.

---

## Exit codes del verificador

| Exit | Significado |
|------|-------------|
| `0` | Todos los checks DUROS pasan + CERO checks MANUAL pendientes |
| `1` | FAIL — algún artefacto IDÉNTICO/EQUIVALENTE/ENTORNO no pasa |
| `2` | ERROR — manifiesto inválido/duplicado, dep faltante, API caída, receipt no parseable |
| `3` | MANUAL-PENDING — los duros pasan, pero quedan checks MANUAL sin receipt válido |
