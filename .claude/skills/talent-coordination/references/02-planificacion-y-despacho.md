# Planificación y Despacho (Modo Proactivo) — Complete Reference

El corazón del sistema: cuando el lead pide una necesidad ("quiero X",
"haz el milestone Y con todo lo necesario y reparte la carga"), el coordinador
la convierte en un plan, lo programa en Linear con todo detalle y lo despacha
aprovechando los carriles disponibles **según el régimen T7 vigente** (ocupación
forzada solo en `alta-cadencia`; en `tranquilo` sin forzar; en `paro`/`SIN-RÉGIMEN`
sin dispatch nuevo) — con un orden de merge que integra el trabajo sin fricción. **Objetivo: máxima velocidad de consecución sin
perder un gramo de calidad ni excelencia.** La velocidad la da el paralelismo
bien cortado; la excelencia la garantizan las specs ejecutables y los gates.

## Table of Contents

1. [El pipeline completo](#1-el-pipeline-completo)
2. [Fase A — Investigar antes de planear](#2-fase-a--investigar-antes-de-planear)
3. [Fase B — Descomponer: DAG y contratos](#3-fase-b--descomponer-dag-y-contratos)
4. [Fase C — GO del lead al plan](#4-fase-c--go-del-lead-al-plan)
5. [Fase D — Programar en Linear con todo detalle](#5-fase-d--programar-en-linear-con-todo-detalle)
6. [Fase E — Reparto óptimo entre N carriles](#6-fase-e--reparto-optimo-entre-n-carriles)
7. [Fase F — Orden de merge e integración](#7-fase-f--orden-de-merge-e-integracion)
8. [Caso real completo: un milestone en un día](#8-caso-real-completo-un-milestone-en-un-dia)
9. [Gotchas & Cross-References](#9-gotchas--cross-references)

---

## 1. El pipeline completo

```text
NECESIDAD DEL LEAD
  │
  ▼
A. INVESTIGAR (verificar la realidad: código, BD, Linear — nada de memoria)
  ▼
B. DESCOMPONER (piezas + DAG de dependencias + CONTRATOS entre piezas)
  ▼
C. GO DEL LEAD (plan compacto, una pregunta, opciones con recomendada)
  ▼
D. PROGRAMAR EN LINEAR (épica/milestone + 1 issue por pieza con spec ejecutable)
  ▼
E. DESPACHAR (prompts simultáneos SEGÚN el régimen T7: todos los carriles en
   alta-cadencia; sin forzar en tranquilo; NINGÚN dispatch en paro/SIN-RÉGIMEN)
  ▼
F. INTEGRAR (gates en orden de dependencia → merges → applies → Done)
  ▼
CIERRE DE ÉPICA con evidencia + verificación independiente
```

Tiempo objetivo de A→C: minutos, no horas. La investigación es paralela
(subagentes read-only + queries), el plan es compacto (<4k chars para el
canal del lead) y la pregunta del GO lleva la recomendación primero.

---

## 2. Fase A — Investigar antes de planear

NUNCA especificar de memoria. Antes de descomponer:

```text
- Código:   ¿qué existe ya? (Explore read-only: componentes, queries, RPCs,
            rutas, patrones del repo que las piezas deben seguir)
- BD:       shapes reales (information_schema), datos vivos (counts),
            reglas/flags existentes — las columnas se verifican, no se asumen
- Linear:   dedupe (¿hay issues previas?), milestones existentes ANTES de
            crear uno nuevo
- Memoria:  gotchas.md — ¿esta necesidad pisa algún error conocido?
```

Toda afirmación del plan que provenga de la investigación cita su fuente
("verificado en prod ahora", "shape real de X"). Lo no verificado se marca
como supuesto del carril a validar.

---

## 3. Fase B — Descomponer: DAG y contratos

### Cortar las piezas

Criterios de corte, en orden de prioridad:

1. **Cero solape de archivos/objetos** entre piezas que correrán en paralelo
   (dos carriles tocando el mismo archivo = conflicto seguro de rebase).
2. **Capas naturales**: BD/RPCs (cimiento) · página/feature (consumidor) ·
   integraciones transversales (nav, enlaces, cards) · remates (layout, polish).
3. **Tamaño de carril**: cada pieza cabe en una issue de estimate ≤5; si no,
   sub-issues.

### El DAG de dependencias

```text
        ┌──────────────┐
        │  PIEZA BD/RPC │  (cimiento: contratos de datos)
        └──────┬───────┘
       ┌───────┼────────┐
┌──────▼───┐ ┌─▼──────┐ ┌▼─────────┐
│ Página X │ │ Nav/UI │ │ Enlaces  │   (consumidoras: paralelas entre sí)
└──────┬───┘ └────────┘ └──────────┘
┌──────▼───────┐
│ Remate/polish│   (depende de ver la página real)
└──────────────┘
```

### Contratos ANTES de paralelizar (la clave de la velocidad)

Las piezas consumidoras NO esperan al merge del cimiento: se especifican
contra su **CONTRATO** publicado en la issue del cimiento:

```text
Contrato de un RPC (en la issue, antes de escribir SQL):
  list_leaderboard_page(p_program uuid, p_limit int = 50, p_offset int = 0,
                        p_locale text = 'es')
  → TABLE(rank bigint, user_id uuid, display_name text, avatar_url text,
          total_points int, level_position int, level_label text,
          total_count bigint)
  Semántica: rank() de competición sobre el dominio COMPLETO antes de paginar;
  total_count como window function en cada fila.
```

Con el contrato fijado, el carril de la página construye tipos y UI en
paralelo; si el cimiento necesita cambiar el contrato, AVISA al coordinador y
el coordinador propaga a los consumidores (cambio de contrato sin propagar =
integración rota).

---

## 4. Fase C — GO del lead al plan

El plan que ve el lead es COMPACTO (los canales truncan ~4k chars):

```text
1ª línea:   recomendación + coste/beneficio en una frase
Bloque 1:   las piezas y quién hace cada una (tabla corta)
Bloque 2:   decisiones que SON del lead (si las hay) — irán de una en una
Bloque 3:   qué cae fuera del alcance (explícito)
```

UNA pregunta en TEXTO PLANO: GO al plan completo / GO con ajustes / alternativa.
Si el lead responde "GO con ajustes" sin especificar: preguntar QUÉ ajustes
(turno aparte), nunca adivinar.

---

## 5. Fase D — Programar en Linear con todo detalle

Una épica (o milestone) + una issue por pieza. **La issue ES la spec**: el
carril debe poder ejecutar sin volver a preguntar. Anatomía de la issue de
despacho:

```markdown
## Contexto            ← la necesidad del lead (cita textual si la hubo) +
                          qué verificó el coordinador (estado real)
## Contrato/Spec       ← tablas de cambios EXACTOS: firmas, shapes, copys
                          aprobados, rutas; lo decidido NO se re-decide en
                          el carril
## Cambios             ← lista numerada por archivo/área, con los patrones
                          del repo a seguir citados (p. ej. "patrón impl
                          DEFINER + wrapper INVOKER + ACLs explícitas")
## Decisiones tomadas  ← defaults aprobados (por quién y cuándo) para que
                          el carril no los reabra
## Validación          ← comandos/specs concretos que el carril debe pasar
## Criterios de        ← verificables con comandos (no adjetivos):
   aceptación             "1 asiento exacto en el ledger, re-click sin duplicar"
```

Metadatos: estado `In Progress` al despachar · labels completos (equipo +
actor + kind + area + vertical) · estimate · milestone (pasando project y
milestone JUNTOS en la misma mutación) · relaciones (`blocks` si una pieza
bloquea una ola/lanzamiento).

---

## 6. Fase E — Reparto óptimo entre N carriles

```text
Algoritmo de asignación (SUBORDINADO al régimen T7: el forzado de ocupación solo
aplica en `alta-cadencia`; en `tranquilo` un carril libre es aceptable y no se
fuerza; en `paro`/`SIN-RÉGIMEN` NO se despacha nada nuevo):
1. Piezas-cimiento → el carril con afinidad de dominio (conoce los patrones)
2. Resto de piezas → en `alta-cadencia`, maximizar carriles OCUPADOS (un carril
   libre es tiempo perdido SOLO bajo ese régimen; si hay más carriles que piezas,
   buscar deuda/bugs para los libres)
3. Verificar CERO solape de archivos y de objetos de BD entre asignaciones
4. Si hay BD: timestamps por carril ya garantizan no-colisión de filenames
   (la colisión llega igual con POST-HEAD compartido — ver 06-carriles)
5. Despachar los prompts ADMITIDOS por el régimen en el mismo turno (todos en
   `alta-cadencia`; ninguno bajo `paro`/`SIN-RÉGIMEN` — arrancan a la vez)
```

El prompt de cada carril (plantilla en `../prompts/plantillas.md`) incluye:
issue, rama sugerida, skills a cargar, los 2-4 puntos calientes de SU pieza,
validaciones, y el STOP pre-merge como cláusula innegociable.

Cargas asimétricas: las piezas no tardan lo mismo. El coordinador **tira por PULL**
del siguiente trabajo del backlog conforme los carriles se liberan (remates,
polish, deuda del Backlog) — no espera a que el carril lo pida. Esto es
**cero-ociosidad régimen-condicional**, NO permanente: en `alta-cadencia` el PULL
es continuo y un carril libre es tiempo perdido; en `tranquilo` el idle es
aceptable (sin presión de cola); en `paro`/`SIN-RÉGIMEN` no hay dispatch nuevo. No
está atado a "una épica abierta": el barrido + PULL es el loop base del puesto
(ver SKILL.md §"Loop de supervisión activa"). Backlog vacío → escalar al LEAD.

---

## 7. Fase F — Orden de merge e integración

```text
Regla: se mergea en ORDEN DE DEPENDENCIA, no de llegada.
  cimiento (BD/RPCs) ──gate──► merge ──► apply prod ──► contratos VIVOS
       │
  consumidoras (pueden llegar al gate antes — esperan el merge del cimiento;
       │         su gate se hace igual para no perder tiempo)
       ▼
  remates/polish (rebase corto sobre todo lo anterior)
```

- Cada PR lleva su gate individual (ver `03-gates-pre-merge.md`).
- Los rebases son pequeños y frecuentes: en cuanto mergea una pieza, los
  carriles con PRs abiertos rebasen — el coordinador lo recuerda en cada GO.
- Conflictos previsibles (dos piezas tocando `gotchas.md`/memoria): se
  resuelven combinando, nunca pisando.
- Si una consumidora revela que el contrato del cimiento quedó corto: issue
  de delta (no parche silencioso), mismo ciclo en miniatura.

Al cerrar la última pieza: cierre de la épica con comentario-evidencia
(tabla pieza→PR→estado en prod) + verificación independiente del coordinador.

---

## 8. Caso real completo: un milestone en un día

Pedido del lead (textual): *"no hay una sección ranking con todo el ranking
completo y la tabla de cómo se suman los puntos? … haz el milestone Ranking
con todo lo necesario y reparte la carga entre los 4 carriles"*.

```text
A. Investigar: dominio del ranking ya endurecido (students+enrollment activo),
   RPCs existentes insuficientes (top-N sin paginación), economía de puntos real.
B. Piezas + DAG:
   P1 RPCs (paginado+total_count, reglas públicas, niveles)   → cimiento
   P2 página /ranking (lista + reglas + escalera)             → consume P1
   P3 nav + card del dashboard                                → paralela
   P4 enlace desde el rail del foro                           → paralela
   Contratos de P1 publicados en su issue ANTES de SQL.
C. GO del lead al plan (una pregunta).
D. Épica + 4 issues con spec ejecutable, labels y estimates.
E. Despacho simultáneo: E1→P1, E3→P2, E4→P3, E2→P4 (afinidades).
F. Merges en orden P1→P2→P3→P4, gate por PR, apply de P1 a prod,
   feedback visual del lead sobre P2 → pieza 5 de remate (layout 2 columnas)
   despachada y mergeada el mismo día.
Resultado (día en `alta-cadencia`): épica Done con evidencia y "todo ok" del lead
en <24h, cero regresiones, todos los carriles ocupados todo el día.
```

---

## 9. Gotchas & Cross-References

1. **Paralelizar sin contratos = retrabajo seguro** → Si la página se escribe
   "contra lo que probablemente devuelva el RPC", la integración falla. El
   contrato se publica primero y es ley hasta que el coordinador propague un
   cambio.

2. **El plan largo se trunca: lo crítico primero** → Recomendación en la
   primera línea; piezas en tabla corta; nada importante después del carácter
   ~4000.

3. **"Repartir" no es "dividir en N partes iguales"** → Es cortar por capas y
   archivos sin solape, con afinidad de dominio. Tres piezas bien cortadas
   para 4 carriles + 1 carril a deuda gana a 4 piezas que se pisan.

4. **Las decisiones del lead van en la spec, fechadas** → "Decisión del lead
   (fecha): X" dentro de la issue. El carril que re-abre una decisión cerrada
   pierde tiempo de todos.

5. **El milestone se busca antes de crearse** → `list_milestones` primero;
   milestones duplicados rompen la agregación del proyecto.

6. **Issue sin criterios verificables = gate imposible** → Si el criterio es
   "que funcione bien", el gate no tiene contra qué auditar. Cada criterio es
   un comando o un assert.

7. **Despachar y desaparecer no es coordinar** → Tras el despacho, el
   coordinador entra en **supervisión activa** (régimen-condicional): barrido de
   carriles, gates en orden, **re-PULL** de liberados, propagación de cambios de
   contrato. No es "reactivo": no espera a que le reporten para actuar.

Cross-references: plantilla del prompt → `../prompts/plantillas.md` · gates →
`03-gates-pre-merge.md` · colisiones/timestamps → `06-carriles-y-recursos.md`.
