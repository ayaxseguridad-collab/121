# Bootstrap y Puesto de Mando — Complete Reference

## Table of Contents

1. [Pre-flight de herramientas](#1-pre-flight-de-herramientas)
2. [Los parámetros del bootstrap](#2-los-parámetros-del-bootstrap)
3. [Auto-descubrimiento del repo y foto inicial](#3-auto-descubrimiento-del-repo-y-foto-inicial)
4. [El modelo del puesto de mando](#4-el-modelo-del-puesto-de-mando)
5. [Qué hace y qué NO hace el coordinador](#5-que-hace-y-que-no-hace-el-coordinador)
6. [Handoffs entre sesiones](#6-handoffs-entre-sesiones)
7. [Gotchas & Cross-References](#7-gotchas--cross-references)

---

## 1. Pre-flight de herramientas

Antes de preguntar nada al lead, verificar el equipamiento. Sin Linear NO hay
coordinación trazable — parar y avisar, jamás fabricar issues de memoria. **Este
repo NO usa MCP**: Linear/BD se operan por **API directa con un token por carril**
(ver `docs/runbooks/mcp-fallbacks.md`).

La verificación de Linear usa el **procedimiento canónico y seguro** de
`linear-skill` (`SKILL.md` §"Autenticación por token") — **no** un `curl -H` que
exponga el token en `argv`; sí el patrón `--config` 0600 de `linear-skill`: el
token vive en `.env.local` (no en una var exportada), se pasa por un archivo
`--config` 0600 (con `printf` builtin → **el token NUNCA entra en `argv`/`/proc`**,
regla 18; el único `-H` del comando es `Content-Type`, sin secreto), y la
verificación **falla ante error HTTP y ante `errors` de GraphQL** (un HTTP 200 con
`errors` NO es "OK"). Vía preferida: el cliente
`.claude/skills/linear-skill/scripts/linear-client.ts` (localiza `.env.local`,
carga la key sin exponerla).

```bash
# Patrón canónico de linear-skill (SKILL.md §Autenticación por token): carga el
# valor (no solo verifica la línea), NUNCA en argv (--config 0600), y falla
# ante HTTP no-2xx o ante un array `errors` de GraphQL — un curl -s pelado
# puede presentar un 401 o un error de GraphQL como si fuera una query en verde.
REPO_ROOT="$(git rev-parse --show-toplevel)"
ENV_FILE="${TA_OPERATION_ENV:-$REPO_ROOT/.env.local}"
LINEAR_API_KEY=$(grep -E '^LINEAR_API_KEY=.+' "$ENV_FILE" | head -1 | cut -d= -f2-)
[ -n "$LINEAR_API_KEY" ] || { echo "FALTA LINEAR_API_KEY en .env.local — parar y avisar al lead"; exit 1; }
cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"
resp=$(curl -sS --fail-with-body --config "$cfg" -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id name } }"}' https://api.linear.app/graphql) \
  || { echo "error HTTP: $resp" >&2; exit 1; }
printf '%s' "$resp" | grep -q '"errors"' && { echo "GraphQL errors: $resp" >&2; exit 1; }
gh auth status              # gh autenticado (gates de PRs)
git remote -v               # repo con remoto (lectura de main/PRs)
# Opcional según proyecto:
grep -q '^SUPABASE_ACCESS_TOKEN=' "$ENV_FILE" && echo "token de BD presente"
```

| Falta | Acción |
|-------|--------|
| `LINEAR_API_KEY` | PARAR. Sin Linear NO hay coordinación trazable — avisar al lead antes de seguir (regla 21) |
| `gh` | PARAR para gates; se puede arrancar el bootstrap mientras el lead hace `gh auth login` |
| `SUPABASE_ACCESS_TOKEN` | Continuar; la verificación de ledger/datos quedará delegada en carriles hasta tenerlo |

Si un token da `401`/expira a mitad de sesión: pedir al lead recargarlo desde
el escrow/`.env.local` del carril correspondiente y REINTENTAR la operación
— no improvisar por otra vía ni fabricar el dato de memoria.

---

## 2. Los parámetros del bootstrap

UNA pregunta por turno, encadenadas. Cada una en TEXTO PLANO (nunca menú/`AskUserQuestion`, seleccionable
por un `send-keys` ajeno bajo relay — ch05/TAL-3071), con opciones reales (no inventadas). **No se pregunta la ARQUITECTURA del repo** (BD,
migraciones, CI, convenciones): es un HECHO que se descubre leyendo el repo —
preguntarla al lead es un error de diseño ("estamos en un repositorio; ese repo
tendrá la arquitectura que sea que tiene").

Pero hay **tres parámetros**, no dos: proyecto Linear · N carriles · **régimen
T7**. El régimen **NO es arquitectura ni es descubrible** — es una decisión
operativa que solo el lead conoce, así que es un **parámetro legítimo del lead**,
distinto de la pregunta prohibida. Se declara/confirma (encadenado, si el lead no
lo puso en su brief); **sin declaración explícita → `SIN-RÉGIMEN` = fail-closed**
(NO dispatch nuevo, ningún default implícito — jamás asumir `Tranquilo`). Ver §4.

### Pregunta 1 — Proyecto de Linear

Primero query `projects` (API directa Linear, filtrando por la initiative del repo si CLAUDE.md la
fija). Las opciones de la pregunta = los projects reales.

```text
Pregunta (texto plano): "¿Qué proyecto de Linear coordinamos en esta sesión?"
opciones: [proyectos del workspace/initiative, el más activo primero]
```

### Pregunta 2 — Carriles

Texto libre (la opción "Other" siempre existe; ofrecer 2-4 configuraciones
típicas como atajo).

```text
Pregunta (texto plano): "¿Cuántos carriles de ejecución hay y cómo los identifico?"
opciones de atajo: "4 carriles (E1..E4)", "2 carriles", "1 carril + yo ejecuto"
→ La respuesta debe fijar: nombre de cada carril + dominio/afinidad si la hay
  (p. ej. "E1 gamificación, E2 foro, E3 embajadores, E4 recursos/comms").
```

Con la respuesta, registrar el mapa carril→dominio. Si Linear tiene labels de
equipo (p. ej. `Equipo 1 · Gamificación`), mapear carril→label.

### Parámetro 3 — Régimen T7 (del lead; NO se descubre)

```text
Pregunta (texto plano): "¿En qué régimen operamos? alta-cadencia / tranquilo / paro"
  alta-cadencia → cero-idle, barrido agresivo, PULL continuo (idle-real=incidente)
  tranquilo     → idle aceptable, sin presión de cola
  paro          → ningún dispatch nuevo (salvo re-fixes de PRs rebotados)
```

Si el lead ya lo fijó en su brief, solo confirmarlo (encadenado, no un turno de
más). **`SIN-RÉGIMEN` = fail-closed y NORMALIZACIÓN**: normaliza a este estado TODO
lo que no sea exactamente `alta-cadencia`, `tranquilo` o `paro` — ausencia de
declaración, cadena vacía, o **valor no reconocido** (typo/externo, p. ej. `alta
cadencia` sin guion o `rápido`). El coordinador puede seguir con trabajo read-only
(barrido, gates de PRs abiertos, verificación) pero **NO despacha trabajo nuevo**
ni asume ningún default; se sale del bloqueo SOLO cuando el lead declara uno de los
tres valores válidos. Nunca asumir `tranquilo` por silencio ni por un valor ambiguo
(si el estado real era `paro`, se violaría el cero-dispatch).

---

## 3. Auto-descubrimiento del repo y foto inicial

Tras las dos preguntas, SIN preguntar más — el repo responde el resto:

```bash
# Memoria y reglas del proyecto (si existen — CLAUDE.md manda):
cat CLAUDE.md                      # reglas absolutas, stack, errores críticos
cat .claude/memory/MEMORY.md       # estado acumulado
cat .claude/memory/gotchas.md      # errores recientes a no repetir

# Arquitectura por inspección (no por pregunta):
ls supabase/migrations/ db/migrations/ migrations/ 2>/dev/null  # ¿hay BD?
ls .github/workflows/                                            # ¿qué CI corre?
cat .claude/settings.json 2>/dev/null                            # hooks del repo
```

**Si hay BD con migraciones**: el coordinador ASIGNA series de timestamp
disjuntas por carril (si CLAUDE.md/memoria no las fijan ya) y las ANUNCIA en
el tablero inicial — no las pregunta. Reglas que las acompañan: (a) cada
carril nombra solo en su serie; (b) re-listar migraciones + git fetch JUSTO
antes de crear una; (c) 3ª regla: si el objeto tocado nació en una migración
posterior al rango propio, la migración va POST-HEAD del ledger; (d) db reset
SIEMPRE tras escribirla — SOLO contra Supabase LOCAL/efímero (el CLI o un
branch de prueba): `db reset` DROPEA y recrea el esquema, así que NUNCA se
corre contra prod/staging ni contra ninguna BD con datos reales (ahí las
migraciones se APLICAN, no se resetea). Ejemplo real (4 carriles): E1=`2026-08xx`,
E2=`2026-09xx`, E3=`2026-10xx`, E4=`2026-11xx` — la serie es convención de
NACIMIENTO; el orden real lo arbitra el ledger.

```text
# Foto inicial (read-only):
query issues { project, state: In Progress + In Review }   # trabajo en vuelo
git fetch && git log origin/main --oneline -10             # últimos merges
gh pr list --state open                                    # PRs esperando gate
# Si hay BD: ledger N/N vs archivos de migración en main (gap = BLOCKER)
```

Cerrar el bootstrap anunciando el tablero:

```text
| Carril | Trabajo | Estado |
|--------|---------|--------|
| E1     | TAL-X   | 🔄 en curso / ⏸️ esperando / ✅ libre |
...
Régimen T7 vigente: [alta-cadencia | tranquilo | paro | SIN-RÉGIMEN=fail-closed]
Pendientes del lead: [decisiones/insumos que solo él puede dar]
→ ENTRO en el loop de supervisión activa acorde al régimen: ARMO el barrido
  persistente (timer 300 s re-armado en cada pasada; cosecha completa +
  status file vivo por disparo — ver `05-verificacion-independiente.md`),
  barro los carriles, tiro del siguiente trabajo por PULL y mantengo
  cero-ociosidad según el régimen.
  (En SIN-RÉGIMEN: solo read-only hasta que declares el régimen.)
```

---

## 4. El modelo del puesto de mando

```text
                       ┌─────────────┐
        necesidades →  │    LEAD     │ ← decisiones de producto/dinero/exposición
                       └──────┬──────┘
                              │ (texto plano: 1 pregunta por turno)
                       ┌──────▼──────┐
   Linear (trazas) ←── │ COORDINADOR │ ──→ verificación read-only (git/gh/BD)
                       └──────┬──────┘   ──→ BARRIDO periódico (capture-pane+proceso;
            ┌───────────┬─────┴─────┬────────  git/gh/Linear complementarias) → candidatos
        prompts/PULL  gates GO/NO-GO  precedentes  cierres con evidencia
            │           ▲                            
      ┌─────▼─┐   ┌─────┴─┐   ┌───────┐   ┌───────┐
      │  E1   │   │  E2   │   │  E3   │   │  EN   │   (N carriles)
      └───────┘   └───────┘   └───────┘   └───────┘
       código+PRs+STOPs+applies+reportes (los carriles EJECUTAN)
```

**Supervisión activa régimen-condicional (T7)**, no reactivo-puro: el coordinador
**barre** los carriles (observar) y **actúa** sobre el idle-real (nudge/re-PULL/
escalar), en vez de solo esperar reportes. "Responder a STOPs" es UN mecanismo
dentro del loop, no el modo. La cadencia depende del régimen:

- **alta-cadencia**: cero-idle, barrido agresivo, PULL continuo (idle-real=incidente).
- **tranquilo**: idle aceptable, sin presión de cola.
- **paro / SIN-RÉGIMEN**: sin dispatch nuevo (fail-closed si no hay régimen declarado).
- **PROACTIVO** (cuando el lead pide una feature): plan → Linear detallado →
  reparto óptimo → secuencia de merges. Ver `02-planificacion-y-despacho.md`.

El barrido detecta idle-real por las 4 condiciones canónicas (pane estático:
N≥3 cortes ≥300 s c/u → ≥600 s continuos + 0 procesos HIJOS + gate terminado +
exclusión de menú/redraw/compact/thinking); sin captura de pane → `UNKNOWN`, nunca
incidente. Ver SKILL.md §"Loop de supervisión activa".

Reglas de comunicación:

- **Respuesta individual a TODO carril que reporta (no negociable).** Cada
  carril que envía un status/STOP recibe respuesta DIRIGIDA (📋 CANAL EX) con su
  estado y siguiente paso concretos — necesite decisión o solo «hold para tu
  token». JAMÁS agrupar carriles que reportan en un bloque colectivo «sin
  acción»: borra su next-step individual y se lee como falta de respeto. La
  compresión por volumen no exime el acuse individual; acusa lo específico que
  reportó (su SHA/banda/validación), no un genérico.
- Los carriles NO se ven entre sí: toda noticia transversal (un reviewer
  pausado, un precedente nuevo, una regla de recurso compartido) la propaga el
  coordinador en el siguiente prompt/gate de cada carril.
- Lo que un carril cite como "me dijiste/aprobaste" se verifica contra el
  registro propio; sin registro → se re-hace (gate completo, decisión
  re-confirmada). Excepción: artefactos físicos del lead (sentinel de audit,
  comentario en Linear) valen como autorización aunque el coordinador no la
  presenciara.

**Responsabilidad ante el lead (doctrina de escalado).** En la fábrica
multi-canal (`talent-orchestrator`/`talent-merger`) el CEO es el ÚNICO
responsable ante el lead: TODO fallo de la fábrica —de cualquier coordinador o
canal— es del CEO, y de ahí baja la obligación hasta cada coordinador de
**pedir ayuda a tiempo**. Este skill opera SIN esa capa CEO/fábrica
(terminales sueltos, ver Deslinde en `SKILL.md`) — el coordinador reporta
DIRECTO al lead, sin intermediario — pero la doctrina es la misma: el fallo
imperdonable no es equivocarse, es el **fallo silencioso**: un atasco, un
blocker o un gap que no se escala hacia arriba mientras aún se puede
corregir. Tragarse un problema (aquí, ante el lead directamente) es la falla
que este principio prohíbe.

---

## 5. Qué hace y qué NO hace el coordinador

| HACE | NO HACE |
|------|---------|
| Auditar diffs/SQL en gates pre-merge | Escribir código de producto |
| Crear/actualizar issues con spec ejecutable | Mergear (mergea el carril tras el GO) |
| Verificación read-only (ledger, flags, estados) | Aplicar migraciones a prod (las aplica el carril) |
| Redactar prompts de carril y plantillas | Mutar datos de prod (salvo data-entry del LEAD con GO+issue+guards) |
| Cerrar ventanas/épicas con comentario-evidencia | Push/PR sin el flujo del repo (audit stop si existe) |
| Mantener memoria (gotchas, hitos) | Decidir producto/stack/dinero (eso es del lead) |
| Capturar deuda como issues en Backlog | Ejecutar operaciones destructivas (NO-GO hasta GO explícito del lead) |
| Escalar a tiempo todo blocker/atasco/gap (el fallo silencioso es el imperdonable) | Tragarse un problema sin escalarlo hacia el lead |

El reparto exacto ejecutor/coordinador puede variar por proyecto (p. ej. sin
carriles de BD, el coordinador podría aplicar migraciones) — fijarlo en el
bootstrap y no moverlo en silencio.

---

## 6. Handoffs entre sesiones

> El **fichero de regreso** y su protocolo (umbral 60 %, checkpoint limpio, paso-0, backup
> jerárquico) son doctrina canónica de **`talent-context`**. Esta lista es la instancia del puesto
> de mando; no duplicar allí el detalle.

El contexto se agota; el puesto de mando sobrevive por escrito. Antes de un
compact/cambio de sesión, generar un handoff con:

1. Rol + **régimen T7 vigente** (alta-cadencia/tranquilo/paro/SIN-RÉGIMEN) +
   parámetros del bootstrap (proyecto, carriles, prefijos).
2. ⚡ TAREA INMEDIATA AL REGRESO (una, explícita).
3. Estado verificado: tablero de carriles, ledger N/N, flags, ventanas
   abiertas con fechas.
4. Hechos cerrados de la sesión (no reabrir).
5. Convenciones vivas (las reglas que no se rompen).
6. Accesos (repo, proyecto BD, project Linear, ids de milestones).
7. Loops armados (id + propósito) — la MEMORIA de qué monitores/wakeups
   tenía el puesto de mando se comprime en el compact aunque el proceso
   sobreviva; sin este campo la reanudación puede seguir con supervisión
   stale (campo operativo obligatorio de `talent-context`, no opcional).
8. PASO-0 embebido: puntero explícito a que el primer acto al volver es el
   checklist canónico de `talent-context` ref 03 (identidad, releer regreso,
   loops, purgar TaskList, releer estado, retomar) — nunca "me siento bien,
   sigo".

La regla del handoff: TODO número que el handoff afirme debe haber salido de
un comando de esa sesión — el handoff hereda la disciplina de los N/N.

---

## 7. Gotchas & Cross-References

1. **No preguntar lo que se puede listar NI lo que se puede leer** → Las
   opciones de la pregunta 1 salen de la query `projects`, no de la imaginación.
   Y la arquitectura del repo (BD, migraciones, CI, hooks) se descubre
   inspeccionando el repo — preguntársela al lead es trasladarle trabajo que
   el coordinador tiene delante (feedback textual del lead: "¿me pregunta A MÍ
   sobre BDs?").

2. **El bootstrap no se repite a mitad de sesión** → Si el lead cambia de
   proyecto/carriles, es un re-bootstrap explícito (anunciarlo), no un deslizamiento.

3. **Sin token válido no se coordina "de memoria"** → La tentación de "ya
   conozco los ids" produce issues fantasma y estados desincronizados. Sin
   `LINEAR_API_KEY` respondiendo, parar. (Este repo NO usa MCP.)

4. **El tablero se anuncia, no se asume** → Cada vez que cambia (cierre, nuevo
   reparto), el coordinador publica la tabla actualizada, **con el régimen T7
   vigente**. El lead nunca debe preguntar dos veces "¿cómo están los carriles?"
   sin respuesta inmediata.

5. **El barrido no espera al reporte** → El coordinador no queda pasivo entre
   STOPs: barre los carriles en cadencia (según régimen) y detecta el idle-real
   SOLO con la definición canónica (`capture-pane` + procesos hijos; sin esa
   visibilidad el estado es `UNKNOWN` y NO se declara). Las señales git-gh-Linear
   son **complementarias** de progreso, no determinantes del idle-real (ver
   `SKILL.md` §IDLE-REAL). Un carril terminado o bloqueado que no reportó lo caza
   el barrido, no un golpe de suerte.

Cross-references: modo proactivo → `02-planificacion-y-despacho.md` · gates →
`03-gates-pre-merge.md` · plantillas de prompts → `../prompts/plantillas.md`.
