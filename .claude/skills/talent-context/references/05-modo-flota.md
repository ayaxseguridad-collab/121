# Modo FLOTA — Complete Reference

Extensión para fábricas multi-agente (tmux, N agentes): jerarquía de backup, el flock como bus
canónico, y el puntero re-inyectable. Todo lo de standalone sigue vigente; esto AÑADE la capa de
supervisión. Si operas una sola sesión, NO necesitas este archivo.

## Table of Contents

1. [Cuándo aplica el modo flota](#1-cuándo-aplica-el-modo-flota)
2. [La jerarquía de backup en cascada](#2-la-jerarquía-de-backup-en-cascada)
3. [El puntero re-inyectable (por qué la pérdida es benigna)](#3-el-puntero-re-inyectable-por-qué-la-pérdida-es-benigna)
4. [El flock como bus canónico](#4-el-flock-como-bus-canónico)
5. [La verificación NUNCA se delega](#5-la-verificación-nunca-se-delega)
6. [Gotchas & Cross-References](#6-gotchas--cross-references)

---

## 1. Cuándo aplica el modo flota

Aplica cuando hay **varios agentes tmux** supervisados en niveles: canales de trabajo, coordinadores
que los vigilan, una estación de orquestación/CEO por encima, y el lead humano. Implementación
ejecutable de referencia: `talent-orchestrator` `scripts/torre-*` (la "Torre de Control").

```text
lead (humano)
  └─ CEO / orquestador ── vigila ──► coordinadores + estación de merge
                                        └─ vigilan ──► canales (dev + auditor)
```

Cada nivel aplica compact-60 a los de abajo **y a sí mismo** (auto-vigilancia con el ctx-watcher).

---

## 2. La jerarquía de backup en cascada

La vigilancia es en **cascada**: cada nivel vigila el ctx% de los de abajo y releva su compact-60;
a su vez es vigilado por el de arriba.

```text
canal ◄── coordinador ◄── CEO/orquestador ◄── lead
  │            │                 │
  │  (el coordinador pide el     │  (si el coordinador cae/compacta mal, el CEO re-inyecta su puntero;
  │   handoff, /compact, puntero) │   si el CEO cae, el lead. El estado vive en el regreso escrito, no
  └──────────────────────────────┘   en la cola de mensajes.)
```

El backup existe porque la **cola post-compact es probabilística**: a veces el puntero de regreso se
pierde (caso M4). El nivel superior es la red de seguridad que lo vuelve a inyectar.

**Instancia concreta a la fecha de esta redacción — NO fuente de verdad del conteo actual**: a
2026-08-29 (decisión del lead), la "estación de merge" de §1 eran **5 estaciones**: M1 y M2 en el
HOST, M3, M4 y M5 remotas. Este número puede cambiar sin que este skill se actualice — verificar
contra el registro de flota vigente (`talent-orchestrator`, o el runbook de estaciones del
Mergeador) antes de asumirlo. El punto no es fijar el conteo, es que la cascada es real: cada
estación aplica compact-60 a sí misma y la vigila el CEO/orquestador. Al reanudar, **ningún nivel
se reporta "parado"**: siempre hay una tarea concreta en curso.

---

## 3. El puntero re-inyectable (por qué la pérdida es benigna)

Diseño clave: **el puntero no lleva estado**. Es una línea del tipo `lee <ruta> y retoma`. El estado
completo vive en el **fichero de regreso escrito FUERA de la sesión** (ref 02). Por eso perder el
puntero es un **fallo benigno**: el backup re-inyecta **la MISMA línea** y la sesión retoma igual.

```text
regreso.md (estado completo, FUERA de la sesión, persistente)
      ▲
      │ "lee regreso.md y retoma"   ← puntero SIN estado
      │        │
   sesión ◄────┘ (si se pierde en la cola post-compact → el nivel superior re-inyecta la MISMA línea)
```

Validado end-to-end (M4, 2026-07-17): puntero perdido → watchdog → re-inyección ≤5 min → **cero
estado perdido**. Corolario de diseño: nunca metas estado en el puntero; si el puntero bastara para
reconstruir, no haría falta el regreso — y entonces perderlo NO sería benigno.

---

## 4. El flock como bus canónico

En flota, el **flock** (fichero de reclamaciones/registro compartido) es el bus donde se escribe lo
DURABLE (decisiones, claims, cross-flota). El paso-0 de un actor de flota incluye releer el **tail**
del flock para reconciliar lo que pasó mientras compactaba.

```text
paso-0 en flota = paso-0 standalone (ref 03) + releer el tail del bus canónico (flock) + estado en Linear
```

Lo efímero se queda en el pane; lo durable va al bus. Un relevo no debe perder una decisión que ya
estaba escrita en el bus: por eso se relee, no se reconstruye de memoria.

---

## 5. La verificación NUNCA se delega

El agente **recién compactado** es el menos fiable para juzgar si retomó bien (su memoria acaba de
comprimirse). Por eso en flota **el nivel superior verifica el paso-0** del inferior; jamás se le
pide al recién compactado que se autoevalúe y dé el visto bueno.

```text
canal compacta ──► ejecuta su paso-0 ──► el COORDINADOR verifica (identidad, loops, estado)
                                          └─ no "canal, ¿estás bien?" → el canal diría que sí ─┘
```

Esto es simétrico hacia arriba: al coordinador lo verifica el CEO; al CEO, el lead.

---

## 6. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Meter estado en el puntero** → El puntero no lleva estado (así perderlo es benigno); el estado
   vive en el regreso escrito.
2. **No re-inyectar tras una pérdida** → La cola post-compact es probabilística; el nivel superior
   DEBE re-inyectar la misma línea si el puntero no llegó.
3. **Delegar la verificación del paso-0 al recién compactado** → La hace el nivel superior, siempre.
4. **Olvidar releer el flock en el paso-0** → Se pierde lo durable que otros escribieron durante el
   compact.
5. **Vigilar solo a los de abajo y no a uno mismo** → Cada nivel también se auto-vigila (ctx-watcher).

**Related reference files:**
- Para el fichero de regreso (variante flota con nonce) → `references/02-protocolo-de-relevo.md`
- Para el paso-0 base → `references/03-paso-0-post-relevo.md`
- Para el ctx-watcher (5.º monitor) → `references/04-ctx-watcher.md`
- Implementación ejecutable de referencia → `talent-orchestrator` `scripts/torre-*` + `references/09-torre-de-control.md`
