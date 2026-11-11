# 00 — Fuentes reales de uso y cuota (F0)

## Resumen ejecutivo

Diez preguntas medidas sobre sesiones y rollouts reales de este canal (SIN contenido
conversacional). Ocho respondidas con evidencia ejecutable; dos NO MEDIDAS por falta de acceso a
contenedor (dueño C1). Cada recibo `~/f0-medidor-pN.txt` lleva DENTRO la cabeza del motor
(`60d301e018238af2676fa9aa5c429c2a020ebfd6`, re-anclada el 2026-09-22T20:3xZ al moverse `main`
desde `4bbf4cc17`), el comando EJECUTABLE tal cual (scripts en `~/f0-medidor-cmd/`, con su
sha256), el fichero objetivo, el rc, la hora y el sha256 de la salida. El cero de PII y el conteo
de `perTurnEffort` se aceptan porque antes se demostró con un cebo que ambos detectores enrojecen
(`~/f0-medidor-b2-pii.txt`, `~/f0-medidor-b2-perturn.txt`, scratch en `~/f0-medidor-cebos/`). Las 9 fixtures
sintéticas (no 7: una es un directorio con 3 ficheros) quedan en `docs/medidor/fixtures/`, medidas
con `find -type f` (nunca un glob por extensión, que se come el `.meta.json`).

## Tabla de hallazgos

| # | Severidad | Ubicación | Hallazgo | Issue creada |
|---|---|---|---|---|
| 1 | — | ver P1 | dedupe por `message.id`, no por "fila con usage no nulo" — TODAS las filas duplicadas llevan el mismo `usage` idéntico | cerrada, sin hija |
| 2 | — | ver P2 | invariantes de contadores se sostienen, 0 violaciones, sobre las respuestas únicas del recibo P2 (denominador vivo en el recibo) | cerrada, sin hija |
| 3 | 🟡 | `81d6e079…jsonl`, `d09f2874…jsonl` | `perTurnEffort` es OPCIONAL y ANULABLE: ausente en `d09f2874` (0 de 16.351, fichero cerrado) y PRESENTE en `81d6e079` desde el relanzamiento del 22-sep (recibo M2 a las 20:38:08Z: 74 `medium` + 39 con valor `null`, sobre 6.046 `assistant`). La afirmación anterior «NUNCA aparece» queda SUPERADA por la medida viva. `effort` vive siempre a nivel superior, nunca dentro de `message.*` | F1 — el extractor trata `perTurnEffort` como opcional y anulable, nunca como requerido |
| 4 | — | ver P4 | `sessionId` de subagente == madre en 5/5 casos; `isSidechain:true` en 100% de sus filas; `model` puede diferir de la madre si el spawn ocurrió bajo otro modelo (recibo P4: la madre registra 5 modelos distintos más `<synthetic>` en su vida —crece porque es la sesión activa—; los 5 subagentes heredaron el vigente en su ventana de spawn) | cerrada, sin hija |
| 5 | — | ver P5 | `compact_boundary` NO cambia de fichero ni de `sessionId` — 13 eventos, 1 solo fichero, mismo `sessionId` en los 13 | cerrada, sin hija |
| 6 | — | ver P6 | `scheduled_task_fire` SÍ permite encadenar por `parentUuid` desde el fire hasta turnos derivados: 3 fires, 268 / 270 / 258 registros encadenados (cadena acumulada, ventana de 400 líneas, `p6.py`). La cifra anterior (109) NO es reproducible: su comando no se conservó (era una descripción, no un script) y se retira | cerrada, sin hija |
| 7 | — | ver P7 | Σ `usage` de las respuestas de un turno == `turn_token_usage` de la última, en 56/56 turnos multi-respuesta; `cached_input_tokens ≤ input_tokens` y `reasoning_output_tokens ≤ output_tokens` en 1.265/1.265 registros | cerrada, sin hija |
| 8 | — | ver P8 | `rate_limits.primary.window_minutes=10080` y `resets_at` con forma epoch en 1.268/1.268 eventos `token_count`; frecuencia ≈1 por respuesta | cerrada, sin hija |
| 9 | 🟡 | `lector_cuotas.py`, `pozos-lectores.map` | **NO MEDIDO** — sin `incus` en PATH y sin `pozos-lectores.map` localizable desde este canal; no se puede invocar el lector real ni entrar a un contenedor | dueño **C1**, disparador: acceso a un pozo lector (incus) desde este canal, o que C1 corra `lector_cuotas.py read` en el contenedor y me relaye la salida por fichero |
| 10a | — | `tmux list-panes` en este canal | es ESTADO VIVO, no estructura: a las 12:06Z el pane `0.1` corría `node` (el CLI de Codex); a las 20:37Z corre `bash` (recibo P10). El pane `0.0` corre `claude` en ambas. La premisa dev/auditor-mismo-CLI no se puede dar por hecha: se mide en cada corrida | descartado: la premisa de "mismo CLI en dos panes" no aplica en canales que mezclan proveedores; el hecho medido queda documentado aquí |
| 10b | 🟡 | comparación de estructura bajo contenedor | **NO MEDIDO** — mismo motivo que P9, sin acceso a contenedor desde este canal | dueño **C1**, mismo disparador que #9 |

## Campos por fuente

### Claude — `~/.claude/projects/<slug>/<sessionId>.jsonl`

| Campo | Tipo | Dónde vive | Ejemplo SINTÉTICO |
|---|---|---|---|
| `type` | enum | nivel superior | `"assistant"` / `"user"` / `"system"` |
| `uuid` / `parentUuid` | string | nivel superior | `"fx-uuid-0001"` |
| `sessionId` | string | nivel superior | `"fx-session-0001"` |
| `isSidechain` | bool | nivel superior | `true` (subagente) / ausente=false |
| `effort` | enum | nivel superior (NUNCA `message.*`) | `"high"` / `"xhigh"` |
| `perTurnEffort` | enum o `null` | nivel superior — **opcional y anulable**, ver hallazgo #3 | `"medium"` / `null` / ausente |
| `permissionMode` | enum | dentro de `type=user` | `"bypassPermissions"` / `"auto"` |
| `message.id` | string | `message.*` | `"msg_fx0001duplicado"` |
| `message.model` | string | `message.*` | `"claude-fx-modelo-a"` |
| `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}` | int | `message.usage.*` | ver fixture 1/2 |
| `message.usage.output_tokens_details.thinking_tokens` | int | `message.usage.*` | `10` |
| `message.usage.cache_creation.{ephemeral_5m_input_tokens,ephemeral_1h_input_tokens}` | int | `message.usage.*` | ver fixture 2 |
| `subtype=compact_boundary` | — | `type=system` | no cambia fichero/sessionId (P5) |
| `subtype=scheduled_task_fire` | — | `type=system`, trae `parentUuid` encadenable (P6) | ver fixture 4 |

### Subagentes — `<sessionId>/subagents/agent-<agentId>.jsonl` + `.meta.json`

`sessionId` == madre (5/5 medido) · `isSidechain:true` siempre · `.meta.json.agentType` presente
siempre · `model` puede diferir si la madre cambió de modelo entre el spawn y otro punto de su vida
(P4).

### Codex — `~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl`

| Campo | Tipo | Dónde vive | Ejemplo SINTÉTICO |
|---|---|---|---|
| `type=token_usage_record` | — | nivel superior del registro | ver fixture 5 |
| `payload.{thread_id,turn_id,session_id,root_turn_id,response_id}` | string | `payload.*` | `"fx-turn-0001"` |
| `payload.usage.{input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,reasoning_output_tokens,total_tokens}` | int | `payload.usage.*` | por respuesta — POR RESPUESTA, no acumulado |
| `payload.turn_token_usage.*` | int | `payload.*` | acumulado POR TURNO — Σ respuestas == último valor (P7, 56/56) |
| `payload.thread_token_usage.*` | int | `payload.*` | acumulado POR HILO completo |
| `type=event_msg`, `payload.type=token_count` | — | nivel superior | ver fixture 6 |
| `payload.rate_limits.primary.{used_percent,window_minutes,resets_at}` | — | `payload.rate_limits.primary.*` | `window_minutes` SIEMPRE `10080` (1.268/1.268), `resets_at` SIEMPRE epoch |

## Reglas de unidad contable y normalización, por proveedor

**Claude**: la unidad contable es `message.id`, NUNCA el `uuid` de la línea — un mismo `message.id`
puede repetirse en 2-4 líneas con `usage` IDÉNTICO (medido: hasta 4 duplicados exactos en la
muestra), y sumar por línea multiplica el gasto real por el número de duplicados. Tras deduplicar
por `message.id`: `input_tokens`, `cache_creation_input_tokens` y `cache_read_input_tokens` son tres
contadores estructuralmente separados (nunca se suman entre sí para "el total de entrada");
`ephemeral_5m_input_tokens + ephemeral_1h_input_tokens == cache_creation_input_tokens` sin excepción
medida (recibo P2: 0 violaciones sobre todas las respuestas únicas); `thinking_tokens ≤ output_tokens`
sin excepción medida (recibo P2: 0 violaciones sobre las que traen el campo).

**Codex**: la unidad contable de "cuánto costó ESTA respuesta" es `payload.usage` de cada
`token_usage_record`; `turn_token_usage` es la vista acumulada del turno (Σ de los `usage` de sus
respuestas — 56/56 turnos verificados) y `thread_token_usage` la del hilo completo. Nunca leer
`thread_token_usage` como "esta respuesta". `cached_input_tokens ⊆ input_tokens` y
`reasoning_output_tokens ⊆ output_tokens` sin excepción medida (1.265/1.265).

**Cuota (ambos proveedores)**: NO vive en los transcripts/rollouts propios — la única fuente viva
verificada es `lector_cuotas.py read` contra los endpoints OAuth, y NO MEDIDO desde este canal por
falta de contenedor (hallazgo #9/#10b).

## Fixtures — ruta y resultado esperado

*(Nota de discrepancia de la issue, sin corregirla: la tabla "Evidencias de cierre" de la issue pide
`ls -la tests/fixtures/`; el entregable real de F0 vive en `docs/medidor/fixtures/`, que es la ruta
que manda el resto de la propia issue. Uso esta última.)*

| Fixture | Resultado esperado |
|---|---|
| `claude-respuesta-5-registros.jsonl` | 5 líneas, mismo `message.id`; tras deduplicar por `message.id` → **1 unidad, 754 tokens de salida** (nunca 3.770 = 754×5) |
| `claude-cache-5m-1h.jsonl` | `ephemeral_5m_input_tokens(0) + ephemeral_1h_input_tokens(100) == cache_creation_input_tokens(100)` |
| `claude-subagente/` (madre + `subagents/agent-fx0001.jsonl` + `.meta.json`) | `sessionId` del subagente == `sessionId` de la madre (`fx-session-0003`); `isSidechain:true`; `.meta.json.agentType="Explore"` |
| `claude-cron-y-manual.jsonl` | el `fire` (`scheduled_task_fire`) encadena por `parentUuid` con `fx-u-0001` → `fx-a-0001`; la fila final `fx-manual-0001` tiene `parentUuid:null` — turno manual, ROMPE la cadena |
| `codex-turno-3-respuestas.jsonl` | 3 respuestas del mismo `turn_id`; Σ `usage.input_tokens` (1000+2000+500=3500) == `turn_token_usage.input_tokens` de la última fila (3500); mismo patrón en `output_tokens` (50+80+20=150) |
| `codex-token-count.jsonl` | `total_token_usage`/`last_token_usage` en CERO (0 uso real); 1 muestra de `rate_limits.primary` con `window_minutes=10080` |
| `trampa-contenido.jsonl` | lleva las claves `content`, `text`, `tool_use` con valor `"TRAMPA-SINTETICA"` — DEBE existir para que F1 pruebe que su extractor las descarta. Medido: `grep -c '"content"'` → **1** (líneas) vs `grep -o '"content"' \| wc -l` → **2** (apariciones) — el criterio del DoD usa la segunda forma a propósito (corrección de C1, TRAMO 4.2) |

## Comandos ejecutados (procedencia)

Cabeza del motor en TODOS los recibos: `60d301e018238af2676fa9aa5c429c2a020ebfd6`. Cada recibo
contiene su propia línea `comando ejecutable:`, que se copia y se ejecuta tal cual; el sha256 de
cada script va en el recibo (`huella del script:`).

| Pregunta | Comando ejecutable (objetivos en el recibo) | Recibo |
|---|---|---|
| P1 | `python3 -B ~/f0-medidor-cmd/p1.py` sobre 4 sesiones | `~/f0-medidor-p1.txt` |
| P2 | `python3 -B ~/f0-medidor-cmd/p2.py` sobre 2 sesiones | `~/f0-medidor-p2.txt` |
| P3 | `python3 -B ~/f0-medidor-cmd/p3.py` sobre 2 sesiones | `~/f0-medidor-p3.txt` |
| P4 | `python3 -B ~/f0-medidor-cmd/p4.py` sobre la madre (descubre sus subagentes) | `~/f0-medidor-p4.txt` |
| P5 | `python3 -B ~/f0-medidor-cmd/p5.py` + `find` del `sessionId` | `~/f0-medidor-p5.txt` |
| P6 | `python3 -B ~/f0-medidor-cmd/p6.py` sobre `d09f2874` | `~/f0-medidor-p6.txt` |
| P7 | `python3 -B ~/f0-medidor-cmd/p7.py` sobre el rollout | `~/f0-medidor-p7.txt` |
| P8 | `python3 -B ~/f0-medidor-cmd/p8.py` sobre el rollout | `~/f0-medidor-p8.txt` |
| P9/P10b | `command -v incus` + `find` de `pozos-lectores.map` — NO MEDIDO | `~/f0-medidor-p9.txt` |
| P10a | `tmux list-panes -a -F …` (formato literal en el recibo) | `~/f0-medidor-p10.txt` |
| M1 | `bash ~/f0-medidor-cmd/m1.sh` — las tres clases sobre `find docs/medidor -type f` | `~/f0-medidor-m1.txt` |
| M2 | inventario `find … -name '*.jsonl' \| wc -l` + `p3.py` | `~/f0-medidor-m2.txt` |
| B2a | `bash ~/f0-medidor-cmd/b2-pii.sh` — cebo del detector de clase 1 | `~/f0-medidor-b2-pii.txt` |
| B2b | `bash ~/f0-medidor-cmd/b2-perturn.sh` — cebo del contador de `perTurnEffort` | `~/f0-medidor-b2-perturn.txt` |

**Muestra histórica frente a censo vivo.** `81d6e079` es la sesión PROPIA y ACTIVA de este canal:
cada turno le añade registros, así que su denominador crece entre dos lecturas y ninguna cifra suya
es estable. El 22.162 (registros `assistant` combinados) es una MUESTRA HISTÓRICA de la mañana del
22-sep, anterior a los recibos con procedencia: su hora exacta no quedó en ningún recibo y no se
usa como cifra principal. El censo vivo es el del recibo M2, con su hora: 6.046 + 16.351 = 22.397 a
las 2026-09-22T20:38:08Z. `d09f2874` y el rollout de Codex están cerrados (sin escritura desde el
12-sep y el 20-sep): sus cifras sí son estables y son las que se re-ejecutan para comparar.
