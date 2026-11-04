# Protocolo de Relevo — Complete Reference

Cubre los 3 pasos del relevo (regreso → `/compact` → puntero), la plantilla del fichero de regreso
(standalone y flota), y el envío scriptado (no automático) del `/compact` bajo tmux.

## Table of Contents

1. [Los 3 pasos (invariante: nada antes del regreso)](#1-los-3-pasos-invariante-nada-antes-del-regreso)
2. [El fichero de regreso: contenido y ubicación](#2-el-fichero-de-regreso-contenido-y-ubicación)
3. [Plantilla — variante STANDALONE](#3-plantilla--variante-standalone)
4. [Plantilla — variante FLOTA (nonce anti-stale)](#4-plantilla--variante-flota-nonce-anti-stale)
5. [Envío scriptado del `/compact` bajo tmux](#5-envío-scriptado-del-compact-bajo-tmux-nunca-lo-dispara-el-ctx-watcher)
6. [Relevo forzado por credencial](#6-relevo-forzado-por-credencial)
7. [Gotchas & Cross-References](#7-gotchas--cross-references)

---

## 1. Los 3 pasos (invariante: nada antes del regreso)

```text
① ESCRIBIR el regreso FUERA de la sesión + VERIFICAR el Write
      │   (estado autocontenido: tarea al volver, en-vuelo, próximos pasos, IDs/refs, loops, paso-0)
      ▼
② /compact   ← SOLO en checkpoint limpio, SIN menú abierto (ref 01 §4)
      │
      ▼
③ PEGAR el puntero al regreso ("lee <ruta> y retoma EXACTAMENTE") → luego paso-0 (ref 03)
```

**Invariante duro:** el paso ② **nunca** ocurre sin el paso ① completado y verificado. Si el Write
del regreso falla en silencio y compactas igual, pierdes el estado — y la cola post-compact es
probabilística (puede que el puntero ni llegue). Por eso ① incluye una verificación explícita
(`test -s`, re-lectura, o `wc -l`) antes de tocar ② .

---

## 2. El fichero de regreso: contenido y ubicación

**Contenido** (autocontenido — quien lo lea al volver no tiene tu contexto):

1. **Tarea inmediata al volver** (UNA, explícita).
2. Estado verificado en-vuelo (todo número sale de un comando de esta sesión, no de memoria).
3. Próximos pasos.
4. IDs/refs: rama, PR, issue, sha.
5. **Loops armados** (id + propósito) — para re-armar los muertos en el paso-0.
6. Convenciones vivas / hechos cerrados (no reabrir).
7. **Paso-0 embebido** (el checklist de reanudación, ref 03).

**Ubicación — FUERA del repo, NUNCA committeada:**

| Modo | Ubicación | Permisos |
|---|---|---|
| Standalone | `~/regreso.md` o el scratchpad de la sesión | usuario |
| Flota | escrow fuera del árbol, p. ej. `~/.config/<fábrica>/handoffs/<actor>.<ts>.md` | `0600` (`umask 177`) |

Nunca en `.git` ni en un path versionado: es estado de trabajo efímero, committearlo es ruido y
posible fuga.

---

## 3. Plantilla — variante STANDALONE

```bash
# Escribe (temporal 0600 + rename atómico) y VERIFICA antes de compactar (sesión sola, sin
# flock ni jerarquía). mktemp junto al destino: el rename es atómico en el MISMO filesystem.
REGRESO="$HOME/regreso.md"
TMP="$(mktemp "${REGRESO}.XXXXXX")" || { echo "FALLO al crear temporal — NO compactar"; exit 1; }
if ! cat > "$TMP" <<'EOF'
# Regreso — <título de la tarea>

TAREA INMEDIATA AL VOLVER: <una, explícita>

Estado en-vuelo:
- <lo que está a medio hacer, con hechos verificados por comando>

Próximos pasos:
1. <...>
2. <...>

IDs/refs: rama <...> · PR <...> · issue <...> · sha <git rev-parse HEAD>

Loops armados (re-armar los MUERTOS en el paso-0; los procesos bg vivos se re-pollean, no se relanzan):
- <id>: <propósito>

PASO-0 (primer acto al volver):
1. Verifica los loops: adopta los vivos SIN duplicar, re-arma los muertos.
2. Relee las fuentes de estado del PROPIO repo (git status, tests, TODO, issue).
3. Retoma EXACTAMENTE desde "Estado en-vuelo".
REGRESO-FIN
EOF
then
  echo "FALLO al escribir el temporal — NO compactar"; rm -f "$TMP"; exit 1
fi
# marcador ANTES del rename (no basta "no vacío": un cat truncado a mitad también deja algo no-vacío)
tail -1 "$TMP" | grep -qF 'REGRESO-FIN' || { echo "FALLO — temporal truncado (sin marcador) — NO compactar"; rm -f "$TMP"; exit 1; }
if ! mv -f "$TMP" "$REGRESO"; then
  echo "FALLO al mover a destino ('$REGRESO' previo SIN TOCAR; temporal en $TMP) — NO compactar"; exit 1
fi
tail -1 "$REGRESO" | grep -qF 'REGRESO-FIN' && echo "regreso OK ($(wc -l < "$REGRESO") líneas)" \
  || { echo "FALLO — regreso no verificado tras mv — NO compactar"; exit 1; }
```

---

## 4. Plantilla — variante FLOTA (nonce anti-stale)

En flota, el regreso se pide al pane y el actor lo **escribe en un fichero** (Write, dir 0700; el
viewport del TUI en pantalla alternada pierde los handoffs largos), con la pantalla como respaldo.
Para no confundir un handoff viejo con el actual, se delimita con un **nonce único por ejecución**, se
exige un `mtime` no anterior a la petición y se extrae SOLO el último bloque con ese nonce exacto
(implementación de referencia: `talent-orchestrator` `scripts/torre-compact.sh` + `lib-torre.sh`
`torc_torre_read_handoff_file` / `torc_torre_collect_handoff` / `torc_torre_extract_handoff`).

```text
HANDOFF-INICIO torre_hf_<epoch>_<rand>
<... el regreso completo: estado, en-vuelo, próximos pasos, IDs/refs, loops ...>
HANDOFF-FIN torre_hf_<epoch>_<rand>
```

Reglas de la extracción anti-stale:
- Solo matchea el bloque cuyo **nonce coincide EXACTO** (bloques viejos del scrollback nunca).
- Si el último `INICIO <nonce>` quedó **abierto** (truncado, sin `FIN`) → fail-closed (rc 4):
  **jamás** caer a un bloque previo "completo" (sería un handoff stale).
- El bloque se guarda FUERA de la sesión (`umask 177`) **antes** del `/compact`.

---

## 5. Envío scriptado del `/compact` bajo tmux (nunca lo dispara el ctx-watcher)

**El ctx-watcher (`scripts/ctx-watch.sh`) NUNCA envía `/compact`** — es puramente de lectura
(`capture-pane` + parseo, fail-closed); no toca `send-keys` en ningún punto de su código (ref 04).
Lo que sigue es una conveniencia OPCIONAL para automatizar el TECLEO, no la decisión: bajo tmux, y
solo DESPUÉS de que el paso ① (regreso escrito FUERA y VERIFICADO) ya se completó, la propia sesión
o un supervisor que releva a un subordinado (p. ej. el patrón `talent-orchestrator` `scripts/torre-*`)
puede scriptar el envío de `/compact` + el puntero al pane, SIEMPRE en checkpoint limpio. La
coreografía mínima:

```text
1. enviar '/compact' + Enter          (send-keys; SOLO en checkpoint limpio, sin menú abierto)
2. sleep ~2s                          (deja que el prompt de compactación aparezca)
3. enviar la línea-puntero SIN Enter   (queda en el composer; el paste-block puede requerir
                                        un Enter extra manual — verificar el eco, no submit a ciegas)
```

```bash
# Ilustrativo STANDALONE (envío verificado real: ver talent-orchestrator scripts/torre-*). '=' fija sesión exacta.
S="=mi-sesion:"
R="$HOME/regreso.md"   # la MISMA ruta EXACTA donde el paso de extracción escribió el regreso (fuera del repo) — reusar la variable, no re-teclear un literal que pueda divergir
tmux send-keys -t "$S" -l -- "/compact"; tmux send-keys -t "$S" C-m      # 1) /compact + Enter
sleep 2                                                                   # 2) esperar el prompt
tmux send-keys -t "$S" -l -- "lee $R y retoma EXACTAMENTE"               # 3) puntero SIN Enter
# Verifica el eco en el composer ANTES del Enter final (evita submit a ciegas sobre pane ocupado).
```

**Sin tmux** no hay envío scriptado posible: el protocolo degrada a "regreso escrito + pedir el
`/compact` al humano en el checkpoint" (ver `references/04-ctx-watcher.md` §sin-tmux). Sigue valiendo
el 80 %: **nunca compactar sin un regreso escrito**.

### Torres del HOST — SOLO `--resume <uuid>`, `--continue` PROHIBIDO

**EXCLUSIVO de torres del HOST**: el cwd de una torre del HOST es **compartido con el CEO** (no
aislado como un canal en contenedor). El comportamiento de `--continue` está verificado con
`claude --help` (literal: «Continue the most recent conversation in the current directory»): retoma
la conversación MÁS RECIENTE de ESE cwd — que en un cwd compartido puede ser la del CEO y no la de
la torre —, la engancha y la duplica (4 duplicados MEDIDOS el 1-sep en 1 hora, uno tecleando relays
dentro de los composers de M1/M2/M4, con M2 muerto tras el enganche; incidente observado). **Los
canales en contenedor (cwd aislado) NO están afectados — mantienen su coreografía actual.**

Procedimiento, EN ESTE ORDEN — **el check del uuid va ANTES del kill** (el orden es el contrato;
invertirlo pierde la torre sin poder recuperarla):

1. Leer `~/.config/talent-channels/env/<torre>.session` y validar que el uuid es legible y no
   vacío.
2. **Solo si el paso 1 tuvo éxito**: matar el PID viejo de la torre.
3. Relanzar con `claude --resume <uuid>` (el uuid del paso 1). `claude --help` verifica que
   `--resume` toma la conversación por session ID («Resume a conversation by session ID»), así
   relanzas la sesión CONCRETA de la torre y no la más reciente del cwd. `--continue` **PROHIBIDO**
   aquí, sin excepción.
4. Tras relanzar, verificar: CLI vivo + contenido (el pane muestra la sesión esperada) + modelo y
   effort (ver ref 03 §2 paso 2, misma captura de barra).

---

## 6. Relevo forzado por credencial

**Procedimiento sellado (lead 2026-09-01), aplicado con éxito en los incidentes de esa fecha**:
cuando el token de un CLI compartido rota su refresh, el CLI puede mostrar `Login expired` → `Not
logged in`. En esos incidentes (OBSERVACIÓN del incidente) un retry inmediato NO resolvió el
síntoma; lo que sí funcionó fue `kill` del PID + relanzar con `--resume <session-uuid>`.

**Parte VERIFICADA por comando**: `claude --help` → `--resume [value]` = «Resume a conversation by
session ID». Es decir, `--resume` apunta a la conversación por su session ID (no toma «la más
reciente» del cwd — eso es `--continue`, arriba).

**Parte OBSERVACIÓN NO VERIFICADA — misma familia que el gotcha 13 de `SKILL.md`**: NO está
acreditado por ninguna captura/fixture/contrato de CLI que (a) al hacer `--resume` se RESTAURE el
contexto de esa sesión (es el comportamiento esperado del verbo «resume», pero el literal de
`--help` no lo dice), ni (b) que la recuperación de auth ocurra porque el proceso nuevo relee la
credencial fresca de disco donde el retry no lo hace, ni (c) que el contexto restaurado sea
byte-completo frente a un auto-compact. El PROCEDIMIENTO es sellado y funcionó; su EXPLICACIÓN
mecanicista queda sin verificar. Para sellarla como doctrina dura: reproducir la rotación de token
desde una máquina con acceso a forzarla y observar el comportamiento — no asumirlo de este doc.

No confundir con el relevo ordinario (§1-§5): este es NO planeado, disparado por auth externa, no
por cruzar el 60 % de contexto.

---

## 7. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Compactar sin verificar el Write del regreso** → Escribe a un temporal + rename atómico,
   **gateando el exit code de `cat` Y de `mv`** (sin gate: un `cat >` que falla a mitad deja un
   truncado-NO-vacío que `test -s` no detecta; y si `mv` falla con un regreso PREVIO ya en
   destino, `test -s` validaría ese fichero VIEJO como si fuera el nuevo). Marcador final
   validado ANTES del rename, no solo "no vacío"; limpia el temporal en cualquier fallo.
2. **Submit a ciegas del puntero** → Sobre un pane ocupado se **encola** y duplica; verifica el eco.
   El paste-block a veces necesita un Enter extra.
3. **Caer a un handoff viejo del scrollback** → En flota, extracción por nonce exacto; truncado =
   fail-closed, no un bloque previo.
4. **Committear el fichero de regreso** → Vive FUERA del repo, nunca versionado.
5. **`/compact` con un menú abierto** → Modal; Escape primero (ref 01 §4).

**Related reference files:**
- Para decidir el checkpoint limpio → `references/01-doctrina-y-checkpoint-limpio.md`
- Para el paso-0 tras volver → `references/03-paso-0-post-relevo.md`
- Para la vigilancia que dispara el relevo → `references/04-ctx-watcher.md`
- Para la jerarquía de backup del puntero → `references/05-modo-flota.md`
