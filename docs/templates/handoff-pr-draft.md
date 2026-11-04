---
title: "Template: HANDOFF — comentario del PR draft (canal de producción → Mergeador)"
created: 2026-07-07
updated: 2026-07-07
author: raulmartin
status: active
---

# Template: HANDOFF — comentario del PR draft

> **Filosofía**: el HANDOFF es la interfaz entre las dos estaciones de la fábrica
> ([ADR-0043](../decisions/0043-fabrica-v2-mergeador-posture-cr.md)). El canal de
> producción entrega el PR en DRAFT con este comentario y se olvida; el Mergeador trabaja
> SOLO con lo que el HANDOFF declara (invariantes, superficies, slots). Un HANDOFF pobre =
> rechazo del draft (bounce). Este template es la **única enumeración canónica** de las
> secciones y del bloque machine-readable: los skills (`talent-merger`,
> `talent-channel-operation`) y `scripts/verify-handoff.sh` verifican CONTRA este archivo,
> no re-listan campos.

## Quién lo usa y cuándo

1. **Canal de producción (dev)**: pega el comentario en el PR recién creado en DRAFT
   (`gh pr create --draft`), con TODAS las secciones y el bloque machine-readable al final.
2. **Coordinador**: valida la entrega corriendo `bash scripts/verify-handoff.sh <pr>`
   (exit 0 = entrega válida) antes de dar el encargo por cerrado y reciclar el canal.
3. **Mergeador**: re-verifica en el intake (mismo script) y trabaja contra los invariantes
   declarados; si el HANDOFF falta o el bloque no valida → rechaza el draft.

## Plantilla

Reemplazar `<PLACEHOLDERS>`. Ninguna sección es opcional: si no aplica, escribir
explícitamente `N/A` y por qué (una línea). El bloque machine-readable va SIEMPRE al final
del comentario.

````markdown
## HANDOFF · <TITULO_CORTO_DEL_ENCARGO>

### Qué hace

<RESUMEN_DE_2_5_LINEAS_DEL_CAMBIO_Y_SU_PORQUE_DE_NEGOCIO>

Issues del encargo: `closes <TAL-XXXX>`<, `closes <TAL-YYYY>`…>

### Decisiones y porqués

- <DECISION_1_Y_RACIONAL_CORTO>
- <DECISION_2_Y_RACIONAL_CORTO>

### Invariantes sellados por el code-audit

<LISTA_VERIFICABLE_DE_INVARIANTES_QUE_EL_AUDITOR_SELLO_EN_EL_GO. El equipo de
refactorización del Mergeador re-audita cualquier fix CONTRA estos invariantes: si un
refactor los rompe, no es un fix válido.>

- <INVARIANTE_1_COMPROBABLE>
- <INVARIANTE_2_COMPROBABLE>

### Superficies tocadas y clasificación

- Superficies sensibles tocadas: <NINGUNA | LISTA_SEGUN_ALLOWLIST_DEL_BLOQUE>
- Justificación de la clasificación: <UNA_LINEA — regla fail-closed: en duda, sensible>

### Migraciones

- Slots incluidos: <NINGUNO | LISTA_DE_TIMESTAMPS_14_DIGITOS>
- ¿Destructiva (DROP/ALTER irreversible/DELETE batch)?: <NO | SI_Y_POR_QUE — exige GO del lead>
- Nota de renumeración: el slot declarado es el del branch; el Mergeador renumera contra
  el ledger real de prod antes del merge.

### Archivos calientes

<LISTA_DE_PATHS_COMPARTIDOS_O_DE_ALTO_SOLAPE tocados (p. ej. next.config.ts, proxy.ts,
messages/*.json, globals.css) — el Mergeador los usa para el spot-check de disjunción.>

### Verificación local ejecutada

```bash
<COMANDOS_CORRIDOS_Y_RESULTADO: npm run typecheck · npm run lint · npm run build ·
tests relevantes (specs concretos) · verificación UI si aplica>
```

### Scope ledger (AC/NG)

<!-- Paquete v1 (préstamo m2): una línea de EVIDENCIA por cada AC-N de la issue (comando/salida),
     una línea de PRESERVACIÓN por cada NG-N («no se tocó; lo prueba: …»), y el cierre literal.
     Si el cierre no fuera cierto: PARAR y enmendar la issue ANTES de entregar. -->
- AC-1: <evidencia — comando y salida que lo demuestra>
- NG-1: <preservación — qué NO cambió y qué lo prueba>
- Otros cambios de comportamiento: ninguno

### Qué NO tocar / trampas

- <TRAMPA_O_ACOPLAMIENTO_NO_OBVIO_1>
- <QUE_NO_REFACTORIZAR_Y_POR_QUE>

### Bloque machine-readable

```json
{
  "schema_version": 1,
  "issues": ["<TAL-XXXX>", "<TAL-YYYY>"],
  "head_sha": "<SHA_COMPLETO_DEL_HEAD_DEL_PR>",
  "branch": "<NOMBRE_EXACTO_DE_LA_RAMA>",
  "sensitive": <true|false>,
  "surfaces": [<VACIO_O_TOKENS_DEL_ALLOWLIST>],
  "migration_slots": [<VACIO_O_TIMESTAMPS_14_DIGITOS_COMO_STRINGS>],
  "destructive": <true|false>
}
```
````

## Contrato del bloque machine-readable (schema_version 1)

`scripts/verify-handoff.sh` valida **fail-closed** (cualquier incumplimiento = entrega
inválida):

| Campo | Tipo | Regla |
|---|---|---|
| `schema_version` | number | Exactamente `1`. |
| `issues` | string[] | NO vacío; cada elemento matchea `^TAL-[0-9]+$`; por CADA issue existe un `closes TAL-N` en el body del PR. |
| `head_sha` | string | 40 hex; igual a `headRefOid` del PR en el momento de la verificación (un HANDOFF stale tras un push nuevo NO valida: re-emitir el bloque). |
| `branch` | string | Igual a `headRefName` del PR; minúsculas con prefijo válido (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `hotfix/`). |
| `sensitive` | boolean | `true` ⟺ `surfaces` no vacío. |
| `surfaces` | string[] | Subconjunto del allowlist exacto: `commerce` · `auth-rls` · `migraciones` · `llm-costes` · `seguridad` · `credenciales`. |
| `migration_slots` | string[] | Cada elemento matchea `^[0-9]{14}$` (prefijo timestamp de `supabase/migrations/`); si NO vacío ⇒ `"migraciones"` ∈ `surfaces`. |
| `destructive` | boolean | Si `true` ⇒ `migration_slots` no vacío; el merge exige GO explícito del lead. |

El allowlist de `surfaces` mapea 1:1 a la lista de superficies sensibles del ADR-0043
(path-patterns operativos en `talent-merger`, `references/03-superficies-sensibles.md`).

## Señal opcional `category` (schema_version 2 · TAL-3857)

Bajo `schema_version 2`, el bloque admite un campo **opcional** `category` — una señal
**no-sensible DESACOPLADA** del allowlist de `surfaces` (dictamen del PM, TAL-3811):

| Campo | Tipo | Regla |
|---|---|---|
| `category` | string (opcional) | Si está presente, EXACTAMENTE `"ops"` (fail-closed ante cualquier otro valor). Marca los encargos **ops/tooling no-product** (gates del push, hooks de gobernanza, scripts de verificación) para el ruteo del Mergeador. Ausente = comportamiento actual sin cambios. |

**Para que la señal surta efecto, el bloque debe declarar `"schema_version": 2`.** Bajo
`schema_version 1` (coexistencia deprecada, TAL-2825) `verify-handoff.sh` **ignora** `category`:
un encargo ops/tooling emite el bloque machine-readable en v2 con `"category": "ops"` (no basta
con añadir el campo al ejemplo v1 de arriba).

**Cuándo usar `category: "ops"` vs `surfaces: []`:**

- **Encargo ops/tooling** (no toca ninguna superficie sensible): `surfaces: []` sigue siendo
  lo CORRECTO **y** además `category: "ops"`, para que el Mergeador no pierda la señal de
  "qué se tocó" (que `surfaces: []` a secas no le da).
- **Encargo de producto sin superficie sensible declarable**: `surfaces: []` y **omitir**
  `category` (no es un encargo ops).
- **NUNCA** se añade `ops`/`tooling` a `TF_SENSITIVE_SURFACES`: esa lista es solo de
  superficies SENSIBLES (dispara el escrutinio extra Ruta A/B del Mergeador); una señal
  no-sensible viaja por `category`, jamás por el gate de superficies.

**Cabeceras canónicas (también validadas)**: además del bloque, `verify-handoff.sh` exige
en el MISMO comentario el título `## HANDOFF …` y las 9 cabeceras `###` de la plantilla
tal cual aparecen arriba (`### Qué hace` … `### Bloque machine-readable`). Un comentario
JSON-only **no es entrega**: los invariantes, decisiones y trampas son el contexto con el
que el Mergeador opera el PR. Renombrar una cabecera aquí exige actualizar el script en el
MISMO PR (ver Review process).

## Review process

1. Cambios a este template van por PR + review del lead (no hot-edit).
2. Cualquier cambio del bloque machine-readable actualiza `scripts/verify-handoff.sh` en
   el MISMO PR (el schema y su validador no pueden divergir).
3. Si un skill necesita un campo nuevo, se propone aquí primero; los skills solo
   referencian este archivo.
