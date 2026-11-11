---
name: talent-medidor
description: >-
  Medidor de uso de tokens de la fábrica: recolector incremental del HOST que lee los transcripts
  de Claude y los rollouts de Codex, los reduce a su UNIDAD CONTABLE (una fila por respuesta, no
  por registro) y los guarda en un almacén SQLite con rollups de 5 minutos, 1 hora y 1 día,
  enriquecidos por parte del perfil de instancia, fase, origen del turno y coste de lista. Usar al
  instalar, operar o auditar la medición de consumo: correr un tick, hacer la primera carga,
  reconciliar la cifra con una segunda implementación, leer el estado de salud o cambiar la tabla
  de precios o la normalización por proveedor. Triggers (ES/EN): "medidor de tokens", "consumo
  por parte", "recolector de uso", "rollup de tokens", "reconciliar uso", "coste por modelo",
  "token usage collector", "usage rollups", "cost per model", "usage reconciliation".
  Stdlib puro (python3 + sqlite3), sin red, sin MCP. Repo-agnóstico.
---

# Talent Medidor — cuánto consume cada parte de la fábrica (Septiembre 2026)

El medidor responde una pregunta: **cuántos tokens gastó cada parte, con qué modelo, en qué
fase y a qué coste**. Lee lo que los propios clientes ya escriben en disco, no llama a ninguna
API y no guarda ni una palabra de las conversaciones.

## Quick Orientation

**La idea que hay que entender antes que ninguna otra**: la unidad contable es la **RESPUESTA**,
no la línea del fichero. Un transcript de Claude repite la misma respuesta en varias líneas con
el mismo `usage` (medido: hasta 5 copias idénticas); sumar por línea multiplica el gasto por el
número de copias. Una respuesta de 754 tokens de salida repetida 5 veces **no son 3.770**.

| Proveedor | Unidad | Uso | Control (nunca uso) |
|---|---|---|---|
| Claude | `message.id` (último `usage` por `timestamp`) | `message.usage` | — |
| Codex | `payload.response_id` | `payload.usage` | `turn_token_usage` del turno |

| Pieza | Fichero | Qué hace |
|---|---|---|
| Extractor Claude | `scripts/extractor.py` | lee desde un offset, colapsa por respuesta, allowlist de claves |
| Extractor Codex | `scripts/extractor_codex.py` | uso por respuesta, muestras de cuota, `turn_context` vigente |
| Recolector | `scripts/recolector.py` | descubre fuentes, cursores, upsert, rollups, enriquecimiento |
| Esquema | `scripts/esquema.sql` | tablas e índices (F2 y F3 lo consumen congelado por sha) |
| Reconciliación | `scripts/reconciliar.sh` | `jq` independiente contra la DB, `DIFERENCIA=0` |
| Perfil | `scripts/lib-medidor.sh` | `source` de `lib-perfil.sh` de talent-ceo; solo huellas de `cwd` |
| Unidades | `scripts/instalar-unidades.sh` | timer de usuario de 5 minutos |
| Precios | `config/precios.tsv` | precio de lista con `desde_fecha` |
| Normalización | `config/normalizacion.tsv` | fórmula de `in_total` por proveedor |

## Quick Start

```bash
# Un tick sobre el host (crea ~/.local/state/talent-medidor/medidor.db con permisos 0700)
python3 skills/talent-medidor/scripts/recolector.py --tick

# La PRIMERA carga de un historial grande: fuera del timer y bajo nice -n 19 (se relanza solo)
python3 skills/talent-medidor/scripts/recolector.py --bootstrap

# Estado de salud: por fuente ultima_ts, cursores, contadores de rechazo y de coste NO MEDIDO
python3 skills/talent-medidor/scripts/recolector.py --salud

# La cifra publicada contra una segunda implementación (jq), por sesión
bash skills/talent-medidor/scripts/reconciliar.sh      # rc 0 y DIFERENCIA=0

# El timer persistente (unidades de usuario; --sin-activar escribe sin llamar a systemctl)
bash skills/talent-medidor/scripts/instalar-unidades.sh --solo recolector

# La suite hermética (sin red ni systemd; todo en un temporal)
bash skills/talent-medidor/tests/run-tests.sh           # == N ok, 0 FAIL (esperados: N casos) ==
```

Las raíces y la DB se pueden redirigir con `TALENT_MEDIDOR_CLAUDE_DIR`, `TALENT_MEDIDOR_CODEX_DIR`,
`TALENT_MEDIDOR_DB`, `TALENT_MEDIDOR_PRECIOS` y `TALENT_MEDIDOR_NORMALIZACION`; el perfil, con
`TA_PERFIL` (la precedencia la decide `lib-perfil.sh`, no este skill).

## Essential Patterns Quick Reference

### Orden de persistencia: el cursor va DESPUÉS del COMMIT

```text
extraer desde el cursor ─▶ insertar el lote ─▶ COMMIT ─▶ cursor (su propia transacción)
                                              │
                         muerte aquí ─────────┘  el tick siguiente re-extrae desde el cursor
                                                 viejo y ON CONFLICT DO UPDATE absorbe el
                                                 duplicado: 0 pérdidas, 0 duplicados
```

Al revés —cursor primero— una muerte entre los dos COMMIT pierde el lote para siempre.

### Cursor por (inode, offset)

- Mismo inode y offset ≤ tamaño: se sigue desde el offset.
- Otro inode (rotación) o tamaño menor que el offset (truncado): se lee desde 0.
- La última línea sin `\n` **no se consume**: puede estar a medio escribir.

### Rollups recalculados, nunca delta

Cada bucket de 5m/1h/1d tocado por el lote se **borra y se recalcula** desde `usage_raw`. Una
respuesta que llega en dos pasadas (primero con 100 tokens, luego con 754) deja el rollup en 754,
no en 854. Si una unidad cambia de `timestamp` entre pasadas, se recalculan el bucket viejo y el
nuevo.

### Enriquecimiento

| Campo | Regla | Si no se puede decidir |
|---|---|---|
| `fase` | `plan` solo con `permissionMode=plan` del usuario vigente; `coordinacion` solo si el rol de la parte es `coordinador` | `NO MEDIDO` |
| `origen_turno` | `cron` si la cadena `parentUuid` llega a un `scheduled_task_fire`; `manual` si llega a una raíz de usuario | `NO MEDIDO` (la cadena se corta) |
| `part_id`, `rol`, `pane_kind` | cruce de la huella del `cwd` del registro con el atributo `cwd=` de una fila del perfil | `NO MEDIDO` (también con perfil ausente o inválido: rc 2 de `lib-perfil.sh`) |
| `cost_usd` | fila de `precios.tsv` del modelo con la mayor `desde_fecha` ≤ fecha de la unidad | `NULL` + `cost_estado='NO MEDIDO'`, **nunca 0** |

El DAG `parentUuid` se **persiste** entre ticks: un fire leído en el tick anterior sigue
encadenando los turnos que llegan después.

### Normalización por proveedor

`in_total` sale de `config/normalizacion.tsv`, no del código:

- **Claude**: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` (disjuntos).
- **Codex**: `input_tokens`, que **ya incluye** `cached_input_tokens` (23.172 con 11.008 cacheados
  es `in_total = 23.172`, nunca 34.180).
- `thinking_tokens` y `reasoning_output_tokens` van aparte, nunca dentro de `in_total`.

## Critical Gotchas

1. **Nunca se suma por línea.** La unidad es la respuesta. `reconciliar.sh` existe para que la cifra
   publicada nunca dependa de un solo lector: si alguien suma por línea, sale `DIFERENCIA>0`.
2. **El acumulado del turno de Codex no es uso.** `turn_token_usage` solo alimenta
   `control_turnos_codex` (Σ de las respuestas == acumulado de la última, `coincide=1`).
   `thread_token_usage` no se lee.
3. **`token_count` no es una fila de uso.** Es una muestra de cuota (`window_minutes`, `resets_at`)
   y va a `cuota_muestras`.
4. **Datos de personas: se decide por allowlist y por forma.** Solo salen numéricos, enumerados
   cerrados, identificadores opacos con forma validada (sin prefijos de credencial), `model` con
   forma de modelo y el `cwd` **como sha256**. `content`, `text`, `tool_use`, `requestId`, rutas en
   claro y descripciones de subagente no salen nunca. Un registro con un identificador o un modelo
   de forma inválida se **rechaza entero** y se cuenta (`rechazadas_forma`).
5. **Lo que la forma no puede ver.** Un nombre de persona dentro de un valor con forma válida (un
   `model` o un `sessionId` inventados) pasa. La señal es `modelo_fuera_de_catalogo` en `--salud`.
6. **El origen `cron` es acumulado.** La cadena de un fire sigue a todos los turnos que cuelgan de
   él, así que un turno manual posterior en la misma cadena hereda `cron`. Por eso la regla de crons
   de F4 nace inactiva hasta que se mida si discrimina.
7. **Un precio que falta no es 0.** `precios.tsv` nace **sin filas**: los valores iniciales los pone el
   CEO con la página oficial del proveedor y su fecha. Hasta entonces todo coste es `NO MEDIDO`.
8. **La primera carga no va por el timer.** `--bootstrap` se relanza bajo `nice -n 19`; el timer solo
   hace ticks incrementales.
9. **Las fuentes se abren en solo lectura.** El medidor nunca mueve, trunca ni reescribe un
   transcript o un rollout.

## Cross-Skill Integration

### talent-ceo — el perfil de instancia

El perfil (TSV de 6 columnas, contrato V1-V9) se lee **solo** con `talent-ceo/scripts/lib-perfil.sh`,
cargado con `source` desde `lib-medidor.sh`. Para que una parte se atribuya, su fila declara el
atributo `cwd=` (y opcionalmente `rol=` y `pane_kind=`):

```text
torre	<id>	<maquina>	-	<sesion>	rol=coordinador;cwd=<ruta-de-trabajo>;pane_kind=<tipo>
```

### talent-context — el paso-0

El medidor no sustituye a la vigía de cuota: mide lo gastado, no lo que queda. La cuota viva sigue
siendo del lector de cuotas (fuera de alcance de F1).

## Next Steps

- **¿Vas a interpretar una cifra?** → `references/00-fuentes.md` (esquema medido de cada fuente)
- **¿Vas a instalarlo en una instancia concreta?** → `references/instalacion.md`
- **¿Vas a cambiar el esquema?** → es contrato de F2/F3: cambia `esquema.sql` con su issue propia
- **¿Vas a rellenar precios?** → `config/precios.tsv`, una fila por modelo y fecha, con la URL oficial

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (13): coderabbit-talent · linear-skill · talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-docs-skill · talent-issue-craft · talent-medidor · talent-merger · talent-orchestrator · talent-pm · talent-sentry-guard. El paquete viaja JUNTO.
Manifiesto: `scripts/paquete/package.manifest`.
Validación: `scripts/paquete/validate-package.sh` e `invariants.tsv`.
Doctrina y ratchet: `scripts/paquete/PAQUETE.md`.
