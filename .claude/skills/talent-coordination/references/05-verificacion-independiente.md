# Verificación Independiente — Complete Reference

## Table of Contents

1. [El principio](#1-el-principio)
2. [Qué se verifica en cada cierre](#2-que-se-verifica-en-cada-cierre)
3. [El trío de BD: ledger, head, canónica](#3-el-trio-de-bd-ledger-head-canonica)
4. [Verificación de datos y flags](#4-verificacion-de-datos-y-flags)
5. [Discrepancias: casi siempre tienen explicación](#5-discrepancias-casi-siempre-tienen-explicacion)
6. [Barrido persistente y cosecha-en-el-mismo-turno](#barrido-persistente-y-cosecha-en-el-mismo-turno)
7. [Gotchas & Cross-References](#7-gotchas--cross-references)

---

## 1. El principio

**Ningún cierre se confirma sin verificación read-only del coordinador con sus
propios comandos.** No por desconfianza: el reporte del carril puede ser
impecable y aun así llevar aritmética pre-purge, un estado stale o un paso
supuesto. La verificación independiente es la última línea del sistema de
calidad — y la más barata (segundos de queries).

```text
Carril reporta cierre (o el BARRIDO lo detecta) ──► coordinador ejecuta SU verificación ──►
├── cuadra → "cierre CONFIRMADO con verificación independiente" + tabla
└── no cuadra → investigar la discrepancia ANTES de confirmar (ver §5)
```

Esta es la **verificación por nivel** del coordinador en la cascada: verifica
hacia abajo el trabajo del carril y es verificado hacia arriba por el lead. El
reporte la dispara, pero el barrido también la inicia sobre cierres que el carril
no anunció.

Read-only SIEMPRE: el coordinador no "arregla" lo que encuentra — lo reporta
y el fix va por el ciclo normal (issue/carril).

### Censo por artefacto, no por apariencia

El mismo principio rige el CENSO de actividad de la flota: si un carril está
vivo o atascado se mide por sus **artefactos** (mtime de los relays/veredictos
en el scratchpad, avance del SHA, filas nuevas en el ledger), NUNCA por lo que
aparenta una pantalla. Un **label de tarea persistente** (un gate largo, un
build en curso) NO es un atasco; una pantalla quieta puede ser un carril
adjudicando por detrás. La sonda de vida útil es objetiva: **credencial
no-blanca + turno activo** produciendo artefactos, no "se ve parado". La
mecánica concreta de inspección de panes/procesos vive en
`talent-channel-operation` / `talent-orchestrator`; aquí queda el principio —
**artefacto > apariencia**, igual que un cierre se confirma por query y no por
adjetivo.

## 2. Qué se verifica en cada cierre

| Cierre de… | Verificación del coordinador |
|------------|------------------------------|
| PR mergeado | `gh pr view N --json state,mergeCommit` → MERGED + sha |
| Issue Done | query `issue` (API directa) → estado real + trazado de stateHistory |
| Migración aplicada | El trío de BD (§3) + spot-checks semánticos (el CHECK nuevo existe, el RPC tiene la firma, los revokes siguen cerrados) |
| Lanzamiento/flag | Query del flag efectivo (global y por-unidad) en ese momento |
| Smoke con purge | Conteos 0/0/0 de TODAS las tablas que el smoke tocó + lo que debía quedar intacto, intacto |
| Ventana cerrada | Métricas de tracción frescas (filas, eventos, dismissals) |

## 3. El trío de BD: ledger, head, canónica

Tras cualquier apply a prod (adaptar nombres al stack del proyecto):

```sql
select count(*) from supabase_migrations.schema_migrations;            -- = nº archivos en main
select version from supabase_migrations.schema_migrations
 order by version desc limit 1;                                        -- head esperado
select exists(select 1 from supabase_migrations.schema_migrations
 where version = '<timestamp-del-filename>');                          -- la canónica está
select not exists(select 1 from supabase_migrations.schema_migrations
 where version = '<timestamp-autogenerado-sospechoso>');               -- la fantasma NO está
```

El conteo de archivos sale de `git ls-tree -r origin/main --name-only --
supabase/migrations/ | wc -l` — ambos lados de la igualdad se ejecutan, no se
recuerdan.

Spot-checks semánticos (ejemplos reales): `pg_get_constraintdef` del CHECK
reemplazado · `pg_proc` para firmas de RPCs · `relacl` de tablas con revokes
("la migración de grants no reabrió `question_messages`") · advisors de
seguridad como doble check barato.

## 4. Verificación de datos y flags

```sql
-- Flags (lanzamientos): efectivo = global AND por-unidad, AMBOS por query
select feature_flags->>'enable_x' from site_settings limit 1;
select x_enabled from programs where slug = '<unidad>';

-- Purge de smoke: todo lo tocado a cero, lo baseline intacto
select count(*) from tabla_tocada where user_id = '<smoke>';
select count(*) from enrollments where user_id = '<smoke>'
   and program_id = '<baseline-que-debe-seguir>';   -- = 1

-- Tracción de ventana: números frescos para el comentario-evidencia
select count(*), count(*) filter (where dismissed) from user_onboarding;
```

Shapes ANTES que queries: si una columna se asume y no existe, la query falla
— `information_schema.columns` primero cuando haya duda (dos fallos de
columna inventada en una misma sesión enseñaron esto).

## 5. Discrepancias: casi siempre tienen explicación

Encontrar un número distinto al del carril NO es (normalmente) un error del
carril — es información:

| Discrepancia real vivida | Explicación |
|--------------------------|-------------|
| Carril: "9 filas de onboarding" · Coordinador: 8 | El 9 del carril incluía la fila del propio smoke, purgada después — aritmética pre-purge, correcta en su momento |
| Carril: "144/144" · Prod: 143 | Aritmética mental → regla: los N/N salen de comandos en el momento |
| "Enrollment del smoke desapareció" | Purge legítimo de OTRO carril horas antes — recurso compartido sin contrato |
| Ledger con version que no matchea filename | El apply insertó una version autogenerada en vez del timestamp del filename — reconcile pendiente |
| Coordinador: "carril atascado, 2 h sin moverse" · Real: adjudicando por detrás | Censo hecho por apariencia de pantalla; el mtime de sus relays/veredictos SÍ avanzaba — falso positivo del observador, no atasco del carril |
| Coordinador: "draft perdido, no está el PR" · Real: entregado con otro nombre de rama | El PR existía con `closes TAL-N`; la búsqueda fue por nombre de rama, no por la magic word — la entrega estaba, el censo no |

Protocolo: investigar hasta tener LA explicación (no "más o menos cuadra"),
documentarla en la confirmación, y si revela una regla nueva → gotcha. Antes de
ESCALAR un "atasco" o reclamar una "pérdida", auditar el propio censo: contra
artefactos (mtime de relays/veredictos, avance del SHA) para un supuesto atasco,
y contra `closes TAL-N` —jamás el nombre de rama— para un draft/PR que "falta".
El falso positivo suele ser del observador, no del carril.

## Barrido persistente y cosecha-en-el-mismo-turno

La verificación independiente (§1-5) es trabajo que LLEGA por reportes de carril;
que llegue no basta — hay que COSECHARLO sin que envejezca. Todo coordinador
opera con un **timer persistente de barrido cada 300 s**, **RE-ARMADO al
completar CADA pasada**, SIEMPRE (regla ratificada por el lead 2026-07-16). Los
watchers de evento (un carril que reporta, un STOP que entra) **COMPLEMENTAN** el
heartbeat; **NUNCA lo sustituyen** — sin el timer detrás, un cierre que no
dispara watcher se queda sin verificar durante horas.

Cada disparo del barrido = **UNA PASADA COMPLETA**, sin diferir nada a la
siguiente:

1. **Cosechar TODOS los veredictos/reportes pendientes** de los carriles — cero
   cierres sin verificar y cero STOPs sin gate al cerrar la pasada.
2. **Adjudicación EN LOTE**: ningún STOP/plan/cierre listo envejece sin dictamen
   — el GO/NO-GO y la confirmación de cada verificación se despachan para todos
   los carriles que lo tengan listo en la misma pasada, no de uno en uno a lo
   largo de varias.
3. **Gates pendientes en background con task-id** como prueba objetiva de que
   corren; un gate que consume el turno entero deja al resto de la flota sin
   barrer.
4. **Actualizar el status file vivo** (tablero por carril: fase/SHAs/veredictos/
   pendientes/ledger N/N) en CADA pasada — es la fuente que sobrevive a un
   compact/reinicio del coordinador y de la que sale el handoff
   (`01-bootstrap-y-puesto-de-mando.md` §6).

**PROHIBIDO cerrar un turno prometiendo "cosecho en la próxima pasada"**: la
cosecha va SIEMPRE en el MISMO turno que la detecta. El barrido no es un
recordatorio de trabajo futuro, es la ejecución del trabajo ya listo.

La mecánica concreta de gates, task-id de background y paneo vive en
`talent-channel-operation` (ref 04, sección homónima, y ref 03) — aquí queda el
PRINCIPIO, que rige igual aunque el puesto de mando sea read-only sobre
Linear/gh/git y sin panes ni tmux.

## 7. Gotchas & Cross-References

1. **Verificar también lo que debe seguir igual** → El purge correcto borra lo
   suyo Y respeta lo ajeno; ambos lados se comprueban.

2. **El doble check de advisors es gratis — y obligatorio** → Tras applies
   con DDL, el endpoint Management API `advisors/security` (junto con
   `advisors/performance`) es el check post-migración **mandado por
   CLAUDE.md regla 19**, no un extra opcional: confirma en segundos que no
   quedó RLS abierta.

3. **La verificación se publica en tabla** → "Punto | Mi comando (ahora) |
   Reporte del carril" — el lead ve de un vistazo que cuadra y dónde.

4. **stateHistory cuenta la verdad del flujo** → Un Done con trazado
   In Progress → In Review → Done valida que el ciclo se siguió; un Done
   directo desde Backlog es una bandera a mirar.

Cross-references: qué exigir en el reporte del carril →
`../prompts/plantillas.md` · el trío post-apply en el ciclo →
`03-gates-pre-merge.md` §7.
