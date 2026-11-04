# ctx-watcher — Complete Reference

Cubre la receta del ctx-watcher: vigilar el propio ctx% por `capture-pane` cada ~300 s y emitir un
evento al cruzar el 60 %. Incluye la variante bajo tmux y la degradación sin tmux.

## Table of Contents

1. [Qué es y qué NO es](#1-qué-es-y-qué-no-es)
2. [La receta bajo tmux](#2-la-receta-bajo-tmux)
3. [Parseo del ctx% (fail-closed)](#3-parseo-del-ctx-fail-closed)
4. [Sin tmux: degradación documentada](#4-sin-tmux-degradación-documentada)
5. [Uso del script empaquetado](#5-uso-del-script-empaquetado)
6. [Gotchas & Cross-References](#6-gotchas--cross-references)

---

## 1. Qué es y qué NO es

El ctx-watcher es un vigilante **read-only** del propio contexto: captura la barra de estado del
pane, parsea `ctx: NN%`, y **avisa** cuando cruza el umbral (60 %). No compacta por su cuenta —
dispara el evento; el relevo lo ejecuta la sesión en su checkpoint limpio (ref 02).

```text
┌───────────────┐   cada ~300s   ┌──────────────┐   ctx ≥ 60%   ┌──────────────────┐
│ capture-pane  │ ─────────────► │ parse ctx: NN%│ ────────────► │ EVENTO: compacta │
│ (propio pane) │  (solo lectura)│ (fail-closed) │   ctx < 60%   │ en checkpoint     │
└───────────────┘                └──────────────┘ ──────────────► └── (sigue) ───────┘
                                    ctx ILEGIBLE ─► UNKNOWN: inspección manual
```

En flota es el **5.º monitor** (junto a los de panes, Linear y límites de cuenta); en standalone es
el único vigilante, opcional pero recomendado. Es el equivalente standalone del "watchdog externo
Fase 3" que en la Torre aún es futuro: hoy la cadencia la ponen los wakeups.

---

## 2. La receta bajo tmux

Bajo tmux, la sesión corre en un pane con nombre conocido; el watcher lo captura periódicamente.
Modelo de referencia validado: `talent-orchestrator` `scripts/torre-sweep.sh` (sweep read-only) +
`torre-compact.sh check` (gate por ctx%). `scripts/ctx-watch.sh` lo generaliza a un solo pane
propio, sin dependencias de fábrica.

```bash
# Un tick del watcher (solo lectura): captura el pane y evalúa el umbral.
PANE="=mi-sesion:"      # '=' fija la sesión EXACTA (sin match parcial)
cap="$(tmux capture-pane -t "$PANE" -p -J)"     # -J reúne soft-wraps; -p a stdout
if pct="$(printf '%s\n' "$cap" | tc_ctx_pct)"; then
  [ "$pct" -ge 60 ] && echo "COMPACT-60 REQUERIDO (ctx ${pct}%)"
else
  echo "ctx UNKNOWN — fail-closed: inspección manual"
fi
```

La cadencia recomendada es **~300 s** (5 min): suficiente para reaccionar antes del límite duro sin
capturar en bucle. No hay proceso persistente que "morir" si se hace por tick/wakeup — cada tick es
autocontenido.

---

## 3. Parseo del ctx% (fail-closed)

El parseo es una función **pura** (stdin = captura), testeable sin tmux (`tests/run-tests.sh`):

```bash
# scripts/lib.sh — tc_ctx_pct: último 'ctx: NN%' de la captura; sin match -> rc 1 (UNKNOWN)
printf 'algo\nctx: 42%%  ·  branch main\n' | tc_ctx_pct   # => 42
printf 'ctx: 5%% luego ctx: 88%%\n'        | tc_ctx_pct   # => 88  (último match: la barra vive abajo)
printf 'pane sin barra\n'                   | tc_ctx_pct   # => (vacío) rc 1  UNKNOWN
```

**Nunca asumir 0 ni 100** ante ilegible: el rc 1 obliga a inspección manual. Asumir 0 haría que el
watcher no dispare nunca; asumir 100 lo haría disparar siempre. Fail-closed = pedir ojos humanos.

---

## 4. Sin tmux: degradación documentada

Si la sesión NO corre bajo tmux, no hay forma de capturar el propio pane por tick automático. En
NINGÚN caso el ctx-watcher auto-encola el `/compact` — bajo tmux o sin él, solo AVISA; el `/compact`
lo ejecuta siempre la sesión (o su supervisor) en el checkpoint limpio. El protocolo degrada así:

```text
CON tmux:   ctx-watcher captura (tick automático) ─► evento AL CRUZAR 60% ─► la sesión escribe el
            regreso FUERA + lo verifica ─► /compact en su checkpoint limpio (ref 02 §5)
SIN tmux:   autoevaluación periódica del propio uso ─► al cruzar ~60%: ESCRIBIR el regreso y
            AVISAR EXPLÍCITAMENTE al humano ("cruzo el 60%, regreso escrito en <ruta>, pide /compact")
```

La degradación conserva el **80 % del valor**: lo único que se pierde sin tmux es el tick de
captura automático — el `/compact` NUNCA fue automático en ninguno de los dos casos. Lo esencial es
**nunca compactar sin un regreso escrito y verificado**, con o sin tmux.

---

## 5. Uso del script empaquetado

```bash
# Un tick contra el propio pane (imprime resumen; rc: 0 OK, 2 requiere compact, 3 UNKNOWN):
bash scripts/ctx-watch.sh --pane "=mi-sesion:"

# Umbral configurable (default 60) y modo prueba (lee de stdin en vez de tmux, para tests):
bash scripts/ctx-watch.sh --pane "=s:" --threshold 60
printf 'ctx: 72%%\n' | bash scripts/ctx-watch.sh --stdin      # => rc 2
```

El script NO compacta: reporta. Encadenarlo a un wakeup/cron cada ~300 s es responsabilidad del
operador o del harness (en flota, del nivel superior).

---

## 6. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Asumir un valor ante ctx ilegible** → fail-closed: rc 1 / UNKNOWN → inspección manual, jamás 0
   ni 100.
2. **Match parcial de sesión** → usar `=nombre:` (con `=`) para fijar la sesión exacta; sin `=`,
   `tmux -t nombre` puede matchear otra.
3. **Que el watcher compacte solo** → solo AVISA; el relevo lo ejecuta la sesión en checkpoint
   limpio (nunca mid-fix).
4. **Persistir un proceso watcher que muere en el compact** → mejor por tick/wakeup autocontenido;
   y re-armarlo en el paso-0 (ref 03).
5. **Creer que sin tmux no hay protocolo** → degrada a "regreso escrito + aviso al humano", que es
   el 80 %.

**Related reference files:**
- Para el parseo puro y su test → `scripts/lib.sh` + `tests/run-tests.sh`
- Para qué hacer cuando dispara el evento → `references/02-protocolo-de-relevo.md`
- Para re-armar el watcher tras volver → `references/03-paso-0-post-relevo.md`
- Para el 5.º monitor en flota → `references/05-modo-flota.md`
