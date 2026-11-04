# Paso-0 Post-Relevo — Complete Reference

Cubre el checklist canónico de reanudación tras un compact: qué verificar, en qué orden, antes de
cualquier otra acción. El agente recién compactado es el **menos fiable** para autoevaluarse.

## Table of Contents

1. [Por qué existe un paso-0](#1-por-qué-existe-un-paso-0)
2. [El checklist canónico (en orden)](#2-el-checklist-canónico-en-orden)
3. [Loops: adoptar vivos, re-armar muertos](#3-loops-adoptar-vivos-re-armar-muertos)
4. [Fuentes de estado a releer](#4-fuentes-de-estado-a-releer)
5. [Bancos numerados b\<N\> como instancia del fichero de regreso](#5-bancos-numerados-bn-como-instancia-del-fichero-de-regreso)
6. [Gotchas & Cross-References](#6-gotchas--cross-references)

---

## 1. Por qué existe un paso-0

Un `/compact` comprime la conversación: el **proceso** de la sesión sobrevive, pero su **memoria**
de qué estaba haciendo, qué loops tenía armados y qué estado había verificado se resume de forma
imperfecta. Reanudar "a ojo" pierde estado en silencio. El paso-0 es un checklist FIJO que se
ejecuta como **primer acto** al volver, ANTES de cualquier relay, edición o despacho.

```text
volver del /compact ──► PASO-0 (fijo, en orden) ──► recién entonces, trabajo normal
                         └─ nunca "me siento bien, sigo" ─┘
```

---

## 2. El checklist canónico (en orden)

Adaptado del checklist post-resume de la Torre (`talent-orchestrator` `scripts/torre-resume.sh`),
generalizado a standalone:

```text
1. IDENTIDAD (flota): "¿quién eres y cuál es tu último encargo?" — si el contexto es de OTRO actor,
   cerrar y re-resumir con el UUID/estado correcto. (Standalone: confirma que el regreso leído es el
   tuyo y de esta tarea.)
2. RE-VERIFICAR MODELO Y EFFORT. Fuente observable única que da AMBOS valores EFECTIVOS a la vez:
   la BARRA DE ESTADO del CLI (el mismo indicador del que el ctx-watcher lee `ctx:%`, ref 04).
   NO usar `/model` sola (solo cubre el modelo) ni un fichero de settings (da el default guardado,
   con ruta específica de máquina; la barra da el valor ACTIVO y es agnóstica de máquina).
   Comando concreto (bajo tmux) — extrae los dos en una salida:

       tmux capture-pane -p | grep -oE '[A-Za-z0-9.]+ [0-9.]+ \| effort:[a-z]+' | tail -1
       # → familia y versión visible del registro | effort:xhigh

   Sin tmux, leer ese mismo segmento `<modelo> | effort:<nivel>` de la barra en pantalla.
   Comparar AMBOS contra lo que declara la orden/asignación vigente del nivel superior (fichero de
   regreso o última instrucción). Si cualquiera difiere: corregir (`/model <id>`, `/effort
   <nivel>` — son ajustes INDEPENDIENTES: MEDIDO POR EL COORDINADOR 2026-09-02 que un cambio de
   modelo NO arrastra el effort, por eso se comprueban los DOS) y RE-CAPTURAR la barra tras
   corregir. El paso-0 no cierra hasta que la salida del comando muestra los DOS valores esperados.
3. RELEER el fichero de regreso completo (la fuente de verdad del estado).
4. LOOPS: verificar la lista de loops armados — adoptar los vivos SIN duplicar, re-armar los muertos
   (§3). Los procesos bg vivos se RE-POLLEAN (no se relanzan); los wakeups/watchers NO sobreviven.
5. PURGAR el TaskList stale del harness (reconciliar contra la fuente real: issue/orden/repo).
6. RELEER las fuentes de estado del propio repo/bus (§4).
7. RETOMAR exactamente desde "Estado en-vuelo".
```

**El paso-0 reconstruye el estado; NO acredita al actor.** Tras un `/clear`, un reinicio o una sesión nueva
(no solo tras un `/compact`), un actor persistente queda **NO ACREDITADO hasta re-acreditar**: sello nuevo
`ACRED-<ROL>-<nonce>` en el bus, posterior a un cebado (`talent-ceo` `reacreditar.sh`, ref 07). `/clear` está
prohibido en actores persistentes. Hasta acreditar, el actor no continúa el pipeline.

**En flota, el nivel superior verifica este paso-0**; nunca se delega al recién compactado (gotcha 9
del SKILL.md). En standalone, el checklist explícito sustituye esa verificación externa.

---

## 3. Loops: adoptar vivos, re-armar muertos

La distinción clave tras un compact:

| Cosa | ¿Sobrevive al `/compact`? | Acción en el paso-0 |
|---|---|---|
| Shell/proceso lanzado en background | **SÍ** (sigue corriendo) | **re-pollear** estado/resultado; NO relanzar (duplica) |
| Wakeup / monitor programado | **NO** | **re-armar** |
| La MEMORIA de qué loops tenías | **NO** (se comprime) | por eso el regreso los **lista** (id + propósito) |

```text
para cada loop del regreso:
   ¿su proceso sigue vivo?  ── sí ──► ADOPTAR (re-pollear); jamás lanzar otro igual (duplicaría)
                            ── no ──► RE-ARMAR (nuevo wakeup/watcher con el mismo propósito)
```

Relanzar "porque se perdió" un gate que en realidad sigue vivo en bg es el error inverso: crea dos
procesos compitiendo. Por eso primero se comprueba si vive (re-pollear), y solo se re-arma lo muerto.

---

## 4. Fuentes de estado a releer

Qué releer depende del modo:

- **Standalone** — las fuentes del **propio repo**: `git status` / `git log --oneline -5`, el estado
  de tests o build en curso, el issue/tarea, cualquier TODO o nota de la sesión. El fichero de
  regreso apunta a ellas.
- **Flota** — además del regreso, el **bus canónico** (p. ej. `tail` del flock / registro de la
  flota) para reconciliar lo que pasó mientras compactabas, y el estado en Linear.

```bash
# Standalone — reconstrucción mínima del estado del repo tras volver:
git status --porcelain
git log --oneline -5
git rev-parse HEAD          # ¿coincide con el sha del regreso?
```

---

## 5. Bancos numerados b\<N\> como instancia del fichero de regreso

Cuando un mismo día produce **varios regresos secuenciales** (compacts repetidos sin cerrar la
jornada), un único fichero de regreso reescrito en sitio pierde el rastro de qué se sabía en cada
punto intermedio. La práctica observada en flota resuelve esto con un **banco numerado**: cada
regreso se escribe como una instancia NUEVA, nunca sobre la anterior.

```text
<prefijo>-<fecha>-b<N>.md         # p. ej. ceo-regreso-2026-09-05-b7.md
   │        │       └─ contador secuencial del día (b1, b2, … bN); nunca se reescribe uno ya emitido
   │        └─ fecha del día en curso (ancla temporal, no de la sesión)
   └─ prefijo del rol/actor que lo emite (identidad del regreso, coherente con §2 paso 1)
```

**Elegir N es una reserva EXCLUSIVA, no "leer el máximo y sumar uno".** Comprobar cuál es el
`b<N>` más alto y escribir directamente en `b<N+1>` deja un hueco entre la comprobación y la
creación: si dos escritores (dos relevos, o el mismo actor duplicado) hacen esa comprobación casi
a la vez, los dos pueden decidir el mismo N y uno pisa al otro. La reserva correcta es
**temporal + FIN + rename atómico**: el contenido completo (marcador `FIN-REGRESO-…` incluido) se
escribe primero en un fichero temporal fuera del nombre final (p. ej.
`<prefijo>-<fecha>-b<N>.md.tmp-<algo>`), y solo al terminar se hace un `rename` al nombre final
`b<N>.md` — el `rename` es la operación que el sistema de ficheros sí hace indivisible, a
diferencia de "comprobar si existe y luego crear". Si el `rename` falla porque el destino ya
existe (otro escritor reservó ese N primero), se reintenta con `N+1`; nunca se sobrescribe un
banco que otro ya reservó.

El banco cierra con un **marcador literal** al final del fichero (`FIN-REGRESO-…`) que señala
"este banco está completo y sellado" — un banco sin ese marcador se trata como **escritura a
medias** (crash o corte a mitad de vuelco) y el paso-0 debe tratarlo como si no existiera, cayendo
al banco `b<N-1>` anterior que sí cierre con el marcador.

```text
paso-0 al reanudar CON bancos numerados:
   localizar el banco MÁS ALTO (<prefijo>-<fecha>-b<N>.md, N máximo del día)
      ¿cierra con el marcador FIN-REGRESO-…?
         sí ──► es el regreso vigente; releerlo completo (§2 paso 2)
         no ──► escritura a medias; caer a b<N-1> y repetir el chequeo
```

**Por qué numerado y no sobrescrito**: un fichero de regreso único reescrito borra el rastro de
qué loops/estado existían ANTES del corte que forzó el nuevo regreso — si el corte fue a medias
(crash), esa versión previa es exactamente la que hace falta para no perder estado. El banco
numerado hace el historial de regresos del día auditable con `ls <prefijo>-<fecha>-b*.md`.

**Los crons/wakeups no viajan dentro del banco — se inspeccionan por ID ESTABLE y se reutilizan,
nunca se re-crean a ciegas.** Igual que los wakeups de §3 no sobreviven al `/compact` de una
sesión, los crons (o watchers equivalentes) de la ronda anterior tampoco sobreviven al relevo
entre bancos — pero "no sobrevive el fichero que los describe" no es lo mismo que "hay que
recrearlos incondicionalmente". El paso-0 al adoptar un banco numerado debe **consultar el entorno
por la identidad estable** del cron/watcher (una variable de entorno u otro identificador propio
del proceso — el `argv` **no sirve**: varias instancias legítimas pueden compartir `argv`
IDÉNTICO, con la identidad viviendo en una variable de entorno; una comprobación por `pgrep -f`
no puede distinguirlas — o lee varias y dice "duplicado" falsamente, o no encuentra la suya y
lanza una cuarta) y **reutilizar la que ya existe si la identidad coincide**, creando solo si la
comprobación confirma que falta de verdad. Aplica el mismo principio de §3 (adoptar lo vivo,
re-armar lo muerto) a nivel de banco: un proceso en background que el banco declara vivo se
re-pollea; un cron/watcher que el banco declara armado se **verifica por su identidad estable y se
reutiliza si sigue vivo** — idempotente, nunca una re-creación incondicional que asuma muerto lo
que no se comprobó.

---

## 6. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Reanudar sin paso-0 ("me siento bien")** → El recién compactado es el menos fiable; checklist
   fijo, siempre.
2. **Relanzar un loop que seguía vivo en bg** → Duplica procesos; primero re-pollear, solo re-armar
   lo muerto.
3. **No re-armar los wakeups** → No sobreviven al compact; sin re-armar, la sesión se queda "ciega"
   (no despierta con los eventos que esperaba).
4. **Fiarse del TaskList del harness** → Puede quedar stale; reconciliar contra la fuente real.
5. **Delegar la verificación del paso-0 al propio recién compactado (flota)** → La verifica el nivel
   superior.
6. **Adoptar un banco `b<N>` sin comprobar su marcador de cierre** → un banco sin `FIN-REGRESO-…`
   es una escritura a medias; tratarlo como vigente pierde exactamente el estado que el banco
   anterior sí tenía completo. Caer a `b<N-1>` (§5).
7. **Asumir que los crons de la ronda anterior siguen programados tras adoptar un banco, O
   recrearlos a ciegas por no viajar dentro del fichero** → ambos extremos son el mismo error; se
   verifican por identidad ESTABLE (nunca `argv`, que puede repetirse entre instancias legítimas)
   y se reutilizan si siguen vivos, creando solo si la comprobación confirma que faltan (§5).

**Related reference files:**

- Para el contenido del fichero de regreso (que alimenta el paso-0) → `references/02-protocolo-de-relevo.md`
- Para la vigilancia que rearmar tras volver → `references/04-ctx-watcher.md`
- Para la jerarquía que verifica el paso-0 → `references/05-modo-flota.md`
- Para el patrón de bancos numerados `b<N>` → §5 de este mismo fichero
