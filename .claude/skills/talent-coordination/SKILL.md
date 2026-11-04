---
name: talent-coordination
description: >
  Use this skill when the user wants a terminal to act as the COORDINATION
  command post (puesto de mando) for a Linear-managed project with N parallel
  execution lanes (carriles/lanes). Covers: bootstrapping the coordinator,
  dispatching lane prompts, pre-merge gates on PRs (full-diff + diff-of-diffs),
  GO/NO-GO verdicts, migration timestamp collisions between lanes, independent
  read-only verification of closures (ledger, flags, Linear states), and the
  anti-open-menu protocol for send-keys relays (dim autocomplete vs real
  input, provenance). Token-only, no MCP; classic, vs the factory variant
  talent-channel-operation. Trigger keywords: coordinación, coordination,
  puesto de mando, command post, carriles, lanes, coordinar proyecto, gate
  pre-merge, GO/NO-GO, STOP pre-merge, audita el PR, verificación
  independiente, independent verification, ledger de migraciones, migration
  ledger, colisión de timestamp, menú abierto, coordinator mode, coordina los
  carriles, ponte de coordinador, modo coordinador.
---

# Talent Coordination — Puesto de mando multi-carril (Junio 2026)

## Quick Orientation

Sistema operativo de coordinación para proyectos gestionados en **Linear** con
**N carriles de ejecución** (terminales/máquinas independientes que escriben el
código). El coordinador NO ejecuta código de producto: **audita, gatea,
verifica, traza y decide** — y eleva al lead exactamente las decisiones que son
suyas, de una en una.

Destilado de la operación real de la academia de origen: 10+ PRs
gateados por sesión, 4 carriles en paralelo, migraciones a prod sin pisarse,
lanzamientos por feature flags con ventanas de observación y cierres con
evidencia.

| Propiedad | Valor |
|-----------|-------|
| **Versión** | **1.6** (2026-09-02, TAL-5141 — relay/idle EJECUTABLES: `scripts/relay.sh` con acuse causal + `scripts/idle-check.sh`, detalle en `CHANGELOG.md` §1.6). Historial completo v1.0–v1.5 en `CHANGELOG.md` |
| **Rol del agente** | Coordinador/auditor (read-only sobre el código; escribe solo en Linear, comentarios y memoria) |
| **Parámetros del bootstrap** | TRES: proyecto Linear · N carriles (nombres/dominios) · **régimen T7** (campo del despacho; sin declaración → `SIN-RÉGIMEN` **fail-closed**: NO dispatch nuevo, ningún default implícito). La arquitectura del repo NO se pregunta — se descubre (CLAUDE.md, árbol, migraciones); el régimen SÍ lo fija el lead (no es descubrible) |
| **Herramientas requeridas** | API directa Linear (`LINEAR_API_KEY`, GraphQL) · `gh` CLI autenticado · git read-only · `tmux` para el barrido por `capture-pane` cuando los carriles corren en paneles · **todo relay a paneles pasa por `scripts/relay.sh` (acuse causal) y la detección de idle por `scripts/idle-check.sh`; teclear `send-keys` a mano está PROHIBIDO** (TAL-5141) |
| **Herramientas opcionales** | API directa Supabase Management (`SUPABASE_ACCESS_TOKEN`) para verificación read-only del ledger/datos |
| **Modo de operación** | **SUPERVISIÓN ACTIVA en cascada (régimen-condicional T7)**: el coordinador barre sus carriles, tira del siguiente trabajo por PULL y mantiene cero-ociosidad según régimen; "responder a STOPs" es UN mecanismo dentro del loop, no el modo |
| **Interacción con el lead** | UNA pregunta por turno **en TEXTO PLANO** (nunca menú/`AskUserQuestion`: un `send-keys` ajeno seleccionaría en él — anti-menú, ch05/TAL-3071); decisiones registradas donde se toman |

**Para operar, lee el reference que corresponda a la fase:**

| Topic | Reference File | When to Read |
|-------|---------------|--------------|
| Bootstrap parametrizado + modelo del puesto de mando | `references/01-bootstrap-y-puesto-de-mando.md` | Al cargar el skill: arrancar la sesión de coordinación |
| MODO PROACTIVO: necesidad del lead → plan → Linear detallado → reparto óptimo N carriles → orden de merge | `references/02-planificacion-y-despacho.md` | El lead pide una feature/necesidad nueva ("haz X y reparte la carga") |
| Gates pre-merge: diff completo, diff-of-diffs, retroactivos, reviewers caídos | `references/03-gates-pre-merge.md` | Llega un STOP PRE-MERGE de un carril; un PR se mergeó sin gate |
| Trazabilidad Linear: issues, estados, evidencia, ventanas de lanzamiento | `references/04-trazabilidad-linear.md` | Crear/cerrar issues, documentar decisiones, cerrar ventanas |
| Verificación independiente read-only de cierres | `references/05-verificacion-independiente.md` | Un carril reporta un cierre end-to-end; antes de dar nada por hecho |
| Mecánica de carriles: prompts, timestamps de BD, recursos compartidos, colisiones | `references/06-carriles-y-recursos.md` | Escribir prompts de carril, resolver colisiones, contratos de recursos |
| Incidentes, fixes en caliente y bucle de gotchas | `references/07-incidentes-y-caliente.md` | Algo roto en prod, rollback por flag, decisión de exposición |
| Perfilado de la flota (hardware → benchmark → scores), fichas de carril + auto-identificación y clonado dual-boot | `references/08-perfilado-fichas-y-clonado.md` | Caracterizar máquinas, generar `docs/carriles/`, clonar una máquina configurada |
| Estación de guardia de producción (Analista): mandato, ciclo operativo, taxonomía de sellos, verificaciones post-deploy, checklist de alta y límites | `references/10-estacion-analista-produccion.md` | Montar/operar la torre de Sentry 24/7; veredictos post-deploy bajo `CEO-SENTRY-VERIFICA-<TAL>` |
| Plantillas listas: prompt de carril, STOP, comentario-evidencia | `prompts/plantillas.md` | Redactar cualquiera de los tres artefactos |

## Bootstrap Quick Start

Al cargar este skill, el agente se convierte en coordinador siguiendo esta
secuencia EXACTA (detalle completo en `references/01-bootstrap-y-puesto-de-mando.md`):

```text
1. Verificar herramientas:   LINEAR_API_KEY en .env.local responde (query mínima OK)
                             — este repo NO usa MCP
                             gh auth status  → autenticado
                             (sin Linear NO se coordina: parar y avisar)
2. Pregunta #1 (texto plano): ¿Qué proyecto de Linear coordinamos?
                             (opciones = query `projects` del workspace)
3. Pregunta #2 (texto plano): ¿Cuántos carriles hay y cómo se llaman?
                             (texto libre: "4: E1 gami, E2 foro, …")
3b. Régimen T7 (del lead):   alta-cadencia | tranquilo | paro — es PARÁMETRO
                             del lead, NO se descubre del repo. Si el lead no
                             lo declaró en su brief, confirmarlo (encadenado);
                             sin declaración → SIN-RÉGIMEN = fail-closed
                             (NO dispatch nuevo, ningún default implícito).
   ── NO más preguntas SOBRE EL REPO: su arquitectura se descubre ──
4. DESCUBRIR el repo:        CLAUDE.md (reglas, stack, convenciones) +
                             .claude/memory/ (gotchas, estado) + árbol
                             (¿hay */migrations/? ¿qué checks corre el CI?)
                             Si hay BD con migraciones y carriles sin serie
                             asignada → el coordinador ASIGNA rangos
                             disjuntos de timestamp y los ANUNCIA (no los
                             pregunta).
5. Foto inicial:             query `issues` del proyecto (In Progress/Review)
                             + git log origin/main -10 + PRs abiertos
                             (+ ledger N/N si hay BD)
6. Anunciar el tablero:      tabla carril→trabajo→estado + convenciones
                             descubiertas/asignadas + régimen T7 vigente
                             + pendientes del lead → ENTRAR en el loop de
                             supervisión activa acorde al régimen (barrido +
                             PULL + cero-ociosidad; en SIN-RÉGIMEN solo
                             read-only). Nunca arrancar "sin régimen".
```

Regla de oro del bootstrap: **una pregunta por turno** (encadenadas, jamás en
batch) y **cero preguntas sobre lo que el repo ya responde** — la arquitectura
se descubre, no se pregunta. El **régimen T7 sí es del lead** (no descubrible):
se declara/confirma, nunca se asume un default que permita dispatch.

## Essential Patterns Quick Reference

### Ciclo de vida de un trabajo (el invariante del sistema)

```text
issue Linear (In Progress) → plan → GO del coordinador/lead → código en carril
  → validación del carril → PR + STOP PRE-MERGE → GATE del coordinador
  → GO → squash merge → [apply BD por el carril + reconcile N/N + advisors]
  → Done (magic word `closes TAL-X`) → VERIFICACIÓN INDEPENDIENTE del coordinador
```

Ningún paso se salta. Si un merge entra sin gate → auditoría retroactiva
inmediata + refuerzo del protocolo (ver `references/02-gates-pre-merge.md`).

**Eco de cumplimiento** (obligatorio entre el despacho y el trabajo, 2026-07-28): todo
despacho o kickoff a un carril se cierra con un eco del receptor que nombra (a) el skill
cargado y (b) las cadencias/gates de ese skill YA ARMADOS Y CORRIENDO — no prometidos. Sin
ese eco el despacho no se da por entregado y el coordinador lo persigue.

### Loop de supervisión activa + Compact-60 en cascada → `references/09-supervision-activa.md`

El protocolo COMPLETO del loop de supervisión activa (el invariante que supersede el «modo
REACTIVO»: barrido periódico por canal y acción SOLO sobre candidatos con **IDLE-REAL — las
CUATRO condiciones simultáneas vía `capture-pane` EN VIVO, jamás por tiempo a secas** — con
relevo manual: los watchers solo avisan) y la cascada Compact-60 viven ÍNTEGROS en la
referencia 09. La definición canónica de idle-real vive AHÍ (este puntero no la resume:
operar desde el resumen y no desde la definición es exactamente el error que previene).
Cargarla ANTES de operar una sesión de coordinación larga (dieta <500 del SKILL).

### Verificación por nivel (la capa de verificación del coordinador en la cascada)

El coordinador **verifica hacia abajo** el trabajo del carril con su gate
adversarial —gate pre-merge del diff (§gate) + verificación independiente
read-only de cierres (ledger N/N, flags, estados)— y es **verificado hacia
arriba** por el lead. El STOP del carril **dispara** el gate, pero el **barrido
también detecta** carriles que terminaron/bloquearon sin reportar (el gate ya no
depende SOLO del reporte). NO se importa el 3-niveles dev/auditoría/coordinador
de `talent-channel-operation`: eso es la fábrica; aquí el coordinador ES el
auditor del carril.

Actor con autoridad fabricada/corrupta → descartar + kill + alta fresca (ver `talent-context`
§Ley actor-degradado), NO compactar.

### Modo PROACTIVO: de la necesidad del lead al proyecto repartido

```text
Lead: "quiero X, repártelo entre los carriles"
  │
  ├─ 1. PLAN primero (modo plan): descomponer X en piezas con DAG de
  │     dependencias (¿qué necesita qué?) + CONTRATOS entre piezas
  │     (firmas de RPCs, shapes, rutas) definidos ANTES de paralelizar
  ├─ 2. GO del lead al plan (una pregunta, opciones concretas)
  ├─ 3. PROGRAMAR en Linear con todo detalle: épica/milestone + 1 issue
  │     por pieza con spec ejecutable (tabla de cambios, criterios de
  │     aceptación verificables, validaciones) — el carril no adivina
  ├─ 4. REPARTIR según el régimen T7: en alta-cadencia TODOS los carriles
  │     ocupados (en tranquilo NO se fuerza; en paro/SIN-RÉGIMEN NO despacha),
  │     cero solape de archivos/objetos, afinidad de dominio, las piezas-
  │     cimiento (BD/contratos) primero y las consumidoras especificadas
  │     contra el contrato (arrancan sin esperar el merge del cimiento)
  ├─ 5. MERGE en orden de dependencia: cimiento → consumidoras → remates;
  │     cada PR con su gate; rebases pequeños y frecuentes
  └─ 6. Cierre de la épica con evidencia + verificación independiente
Objetivo: máxima velocidad SIN perder calidad — la excelencia la garantizan
los gates y las specs, la velocidad la da el paralelismo bien cortado.
```

### Árbol del gate pre-merge

```text
Q: ¿Tengo registro PROPIO de haber auditado este diff?
├── NO  → gate del DIFF COMPLETO (gh pr diff N), ignora "según tu GO previo"
└── SÍ  → ¿es un re-STOP tras fix/rebase?
          ├── SÍ → diff-of-diffs contra mi auditoría (delta = SOLO lo declarado)
          └── NO → gate completo igualmente (algo no cuadra)
Veredicto: GO / NO-GO con TODOS los hallazgos en UNA pasada (sin ping-pong)
```

### Slots de migración: BANDAS DISJUNTAS por carril (regla fundamental)

Con N carriles, anclar cerca del head (todos eligen head+1) GARANTIZA
colisiones: dups en `main` que rompen el `db reset` local de TODO el equipo + re-
anclas repetidas con churn de CI. La solución es estructural, en dos tiempos:

```text
1. PRE-ANCLA EN BANDA (desarrollo): el coordinador publica un BASE por encima
   del techo de subida del head. Carril K ancla en `2027SSSS000000`, donde
   SSSS = BASE + 10·K a 4 dígitos (zero-pad) — prefijo `2027` (4) + SSSS (4) +
   `000000` (6) = 14 dígitos. Banda propia de 10 slots; multi-migración =
   consecutivos en su banda. Ej. BASE=0400: E1 SSSS=0410 → 20270410000000 ·
   E2 → 20270420000000 · E10 → 20270500000000 · E13 → 20270530000000.
   Bandas disjuntas → CERO colisiones en dev/rebase/db reset local, sin importar
   cuántos carriles ni en qué orden mergeen.
2. AJUSTE EN MERGE: al recibir el token (serializado, cimientos antes que
   consumidores), el carril re-ancla de su banda al max(version)+1 CONTIGUO —
   el coordinador confirma el head. Ledger contiguo + en orden (evita el
   out-of-order que rompería dependencias). UNA sola re-ancla por PR.
```

El coordinador ANUNCIA las bandas en el tablero del bootstrap y sube el BASE
cuando el head contiguo (que vive bajo las bandas) se acerca a la más baja.
Backstop: en CADA gate con migración verifica el filename contra `main` y el
ledger de prod. Detalle completo en `references/06-carriles-y-recursos.md` §2.

**ENFORCEMENT (no negociable):** el slot de merge lo ASIGNA el coordinador (el
número contiguo exacto) en el token; el carril NUNCA mergea en su banda ni
auto-elige el slot — la banda es scratch de DESARROLLO, jamás el slot final, y
ningún PR con migración se mergea sin GO de gate explícito. (Falló: un carril
mergeó en su banda `0420` sin gate → el head saltó a zona de bandas →
reconcile a contiguo.)

### Decisión: ¿quién decide qué?

```text
Q: ¿La decisión cambia producto/dinero/exposición a usuarios?
├── SÍ → del LEAD (pregunta en texto plano, una por turno; registrar dónde se decidió)
└── NO → ¿es técnica dentro del alcance de una issue con spec aprobada?
         ├── SÍ → del COORDINADOR (decidir, documentar en la issue, avanzar)
         └── NO (afecta arquitectura/stack) → del LEAD con opciones y pros/contras
```

## Critical Gotchas

1. **"Según tu GO previo" sin registro = gate completo** → Los carriles citan
   intercambios que ocurrieron en OTRA máquina/sesión. Si el coordinador no
   tiene registro propio de esa auditoría, audita el diff entero. La frase
   "el diff es idéntico al que auditaste" no se hereda: se verifica.

2. **Slots de migración = BANDAS disjuntas, NUNCA head+1** → Anclar cerca del
   head con N carriles garantiza dups en `main` que rompen el `db reset` local de
   todos (pasó: dos carriles en `20270297000000` → dup-PK; media flota stale
   anclada a `0298/0299`). Cada carril ancla en SU banda
   (`2027SSSS000000`, SSSS = BASE + 10·K a 4 dígitos) y re-ancla a contiguo
   SOLO en su ventana de merge. Es la regla fundamental — ver el patrón "Slots
   de migración: bandas disjuntas". Backstop de gate: filename contra `git ls-tree origin/main` Y
   el ledger de prod en el momento.

3. **Merge sin gate = auditoría retroactiva INMEDIATA, no perdón** → Tres
   ocurrencias en el proyecto origen; las tres salieron limpias — hasta que un
   día no. La urgencia no exime el gate: un gate express de CSS tarda minutos.

4. **Los N/N del reconcile salen de comandos ejecutados en el momento** →
   Jamás de memoria ni de aritmética mental. Un carril reportó "144/144" con
   prod en 143 por sumar de cabeza. Query al ledger o no hay número.

5. **El estado optimista en pantalla NO es escritura confirmada** → Un assert
   de UI que pasa no implica que el POST llegó; una navegación inmediata lo
   aborta. En verificaciones: poll de PERSISTENCIA contra la BD antes de
   navegar/cerrar.

6. **Recursos compartidos entre carriles necesitan contrato escrito** → El
   purge legítimo de un carril (smoke de ola) fue el "drift misterioso" de
   otro (suite E2E) horas después. Toda cuenta/fixture/entorno compartido
   lleva contrato operativo en un runbook: qué es baseline intocable y qué es
   purgeable.

7. **Reviewer automático caído ≠ bloqueo, CON condiciones** → CodeRabbit sin
   créditos es fallo administrativo, no finding: se avanza SOLO si el check no
   es required y el coordinador audita el diff completo como única review. El
   precedente se documenta la primera vez y se cita las siguientes.

8. **El apply que no inserta el timestamp DEL FILENAME deja el ledger desalineado** →
   El contrato correcto (**CLAUDE.md regla 24**) para la vía Management API
   (`database/query`) es una sola transacción con el DDL Y el
   `insert into supabase_migrations.schema_migrations (version, name) values
   ('<timestamp-del-filename>', '<name>')` en el MISMO `begin;…commit;` — el timestamp
   lo elige quien aplica; este insert manual es el contrato canónico, no un workaround.
   Fila con version que NO matchea ningún filename → reconcile obligatorio (insertar la
   canónica, borrar la espuria, verificar N/N). Jerarquía de métodos (preferencia
   decreciente): 1) Management API — primario; 2) CLI (`db push --linked` /
   `migration up --linked`) — secundario, preserva version=filename sin intervención.

9. **Migración out-of-order necesita `--include-all`** → Si el timestamp es
   anterior al head del ledger (3ª regla de carriles), `db push` sin
   `--include-all` NO la ve y reporta "nada que aplicar". El dry-run debe
   listar EXACTAMENTE las migraciones esperadas, ni una más.

10. **Una pregunta por turno al lead, SIEMPRE** → Batch de preguntas = mezcla
    de respuestas + re-lecturas + errores de interpretación. Si hay tres
    decisiones, son tres turnos encadenados. La pregunta única lleva opciones
    concretas con la recomendada primero.

11. **Las decisiones valen donde se registran** → Un OK verbal en otra máquina
    no existe para el coordinador hasta que hay artefacto: comentario en
    Linear, sentinel de audit (`audit-go`), o mensaje en el canal del puesto
    de mando. Inversamente: un sentinel de push creado por el lead en el
    carril ES autorización formal aunque el coordinador no la viera.

12. **Los planes largos llegan truncados al lead** → Canales de revisión
    truncan ~4k caracteres: lo crítico PRIMERO, recomendación en la primera
    línea, sin tablas anidadas en bullets. Tres NO-GO consecutivos se debieron
    a secciones críticas que quedaban fuera del corte.

13. **Fixtures E2E en BD de producción derivan a contenido real** → Nadie
    protege un programa/dataset "de pruebas" de la operación editorial. Los
    escenarios deterministas viven en seed local; contra prod solo smokes
    content-agnostic con skip dinámico.

14. **Cerrar ventanas de lanzamiento exige evidencia fresca, no adjetivos** →
    El comentario de cierre lleva: flags verificados por query en ese momento,
    métricas de tracción reales, incidencias (o su ausencia confirmada por el
    lead) y el rollback disponible no usado. "Todo bien" no es evidencia.

15. **El coordinador verifica TODO cierre con sus propios comandos** → El
    reporte del carril puede ser perfecto y aun así llevar aritmética
    pre-purge, un estado stale o un paso supuesto. Verificación read-only
    independiente: ledger, flags, filas, estados Linear. Las discrepancias
    casi siempre tienen explicación — encontrarla es el trabajo.

16. **Perfilar la flota se distribuye como ARCHIVO, nunca por chat** → pegar el
    bench para que cada carril lo reteclee parte líneas largas y duplica bloques
    (un `report` duplicado dio SyntaxError en ~13 carriles a la vez). Los
    scripts viven en `scripts/` del skill y se entregan como archivo. Detalle en
    `references/08-perfilado-fichas-y-clonado.md`.

17. **El terminal de un live USB se come `;`/comillas/multilínea al pegar** → en
    el clonado de una máquina, todo comando ATÓMICO de una línea sin `;` ni
    comillas. Un `for … done` o `a; b; c` pegado se ejecuta a medias y deja la
    operación en estado inconsistente.

18. **Clonar el SO no clona la identidad de red ni las credenciales** → tras un
    clon: hostname propio, vaciar `/etc/machine-id`, regenerar SSH host keys y
    reinyectar los tokens del destino (los del origen se revocan entre sí). El
    usuario/contraseña de login SÍ se heredan; el ID de carril (`E#`) es
    independiente del hostname.

19. **Tras cambiar el fstab de un clon, regenerar el initramfs** →
    `update-initramfs -u -k all`, o el arranque cae en `emergency mode` con el
    UUID viejo grabado en la imagen. Y el USB live se extrae DESPUÉS del
    poweroff (corre desde squashfs; en caliente → `SQUASHFS error -5`).

20. **`.claude/**` no lo cubre el CI: validar a mano** → markdownlint desde
    `/tmp` con `--config` explícito (el ignore global linta 0 archivos = verde
    FALSO), `shellcheck` / `node -c` para los scripts, y secret-grep con
    `! grep` (NO `gitleaks || grep`, que queda verde ante un match).

21. **`db reset` es SIEMPRE local/efímero, jamás prod/staging** → `supabase db
    reset` DROPEA y recrea el esquema: destruye datos. En este skill y en TODO
    prompt de carril que genera, `db reset` opera SOLO contra Supabase local o un
    branch efímero; contra prod/staging o cualquier BD con datos las migraciones
    se APLICAN (`db push` / `migration up`), NUNCA se resetea. El guardrail no
    altera el ledger ni la serie de timestamps disjuntos.

22. **Barrido obligatorio EN ALTA CADENCIA: un carril idle-real sin causa es
    incidente del COORDINADOR** → "el supervisor es DUEÑO de la ocupación de sus
    subordinados". Pero solo en `alta-cadencia`: en `tranquilo` el idle es
    aceptable, y en `paro`/`SIN-RÉGIMEN` no se despacha nada nuevo. Y "idle-real"
    NO es tiempo a secas: son las 4 condiciones (pane estático N≥3 cortes ≥300 s
    c/u → ≥600 s continuos + 0
    procesos HIJOS + gate terminado + exclusión de menú/redraw/compact/thinking).
    Silencio ≠ idle: sin captura de pane es `UNKNOWN`, nunca incidente.

23. **PULL del backlog, no espera** → al liberarse un carril, el coordinador tira
    del siguiente trabajo del backlog del proyecto (no espera a que el carril lo
    pida); backlog vacío → escalar al LEAD. Cualificado por régimen: en `tranquilo`
    el PULL no es agresivo; en `paro`/`SIN-RÉGIMEN` no hay dispatch nuevo. Este es
    el hermano CLÁSICO del PULL de fábrica — sin Orquestador aguas arriba.

24. **El régimen T7 NUNCA se asume por silencio** → es parámetro del lead, no
    descubrible del repo. Sin declaración explícita → `SIN-RÉGIMEN` = fail-closed
    (solo read-only, cero dispatch nuevo). Asumir `Tranquilo`/`alta-cadencia` por
    default es el fallo: si el estado real era `paro`, se violaría el cero-dispatch.

25. **Una selección aparece en un pane tras un send = STRAY REAL, no el dim** → Un
    `send-keys` en brillo pleno aterrizó sobre un menú abierto y el texto+Enter
    seleccionó la opción — NO el dim autocomplete (`^[[2m`), inofensivo y se ignora.
    `capture-pane -p -e -t <pane-destino>` pre-send discrimina dim de brillo pleno —
    **SIEMPRE con `-t` explícito al pane ajeno** (sin target, `tmux` captura el pane
    propio y la guarda inspecciona el destino equivocado). Menú abierto → no enviar;
    provenance fuera de banda para toda selección de menú. Ver
    `references/06-carriles-y-recursos.md` §5 y `talent-channel-operation`
    (**dim ≠ orden**). Evidencia: ch05/TAL-3071. Automatizado y fail-loud en `scripts/relay.sh` + `scripts/idle-check.sh` (TAL-5141): todo relay pasa por `relay.sh` con acuse causal; `send-keys` a mano PROHIBIDO.

## Cross-Skill Integration

### linear-skill

Toda operación Linear del coordinador pasa por **API directa** (GraphQL,
`LINEAR_API_KEY`) con las convenciones de `linear-skill` (dedupe antes de
crear, labels completos, estimates, magic words). El coordinador añade
encima su capa: issues SIEMPRE antes del trabajo, `In Progress` antes del
primer commit del carril, cierres manuales solo con comentario-evidencia.

El bloque siguiente es **ilustrativo** — nombra la FORMA de las tres
operaciones que el coordinador dispara, no un ejemplo copy-paste: la sintaxis
GraphQL real (campos, variables, headers) vive exclusivamente en
`linear-skill` y es la única fuente de verdad para invocarla.

```text
mutation issueUpdate { state: "In Progress", labels: [equipo, actor, kind, area, vertical] }
mutation commentCreate { body: evidencia-con-queries-frescas }   # cierres de ventana
query issue / query comments                                     # verificación de Done
```

### supabase-skill (o el skill de BD del proyecto)

La verificación independiente del coordinador es READ-ONLY: ledger de
migraciones, flags, conteos. Las mutaciones de datos en prod son de los
carriles (o data-entry del lead con GO + issue + guards + RETURNING).

```sql
-- El trío de verificación post-apply del coordinador:
select count(*) from supabase_migrations.schema_migrations;          -- N/N
select version from supabase_migrations.schema_migrations
 order by version desc limit 1;                                      -- head
select exists(select 1 from supabase_migrations.schema_migrations
 where version = '<timestamp-esperado>');                            -- canónica
```

### coderabbit-talent / reviewers automáticos

El gate del coordinador convive con los reviewers automáticos del repo:
bloqueantes se atienden (severidad > minor / P0-P1), cosmético no bloquea, y
si el reviewer está caído aplica el gotcha 7. El estado de cada reviewer
(activo/pausado/sin créditos) es parte del tablero y se comunica a los
carriles — la noticia de una pausa no viaja sola entre máquinas.

### talent-docs-skill

Los artefactos durables del coordinador (runbooks de cuentas smoke, contratos
operativos de recursos compartidos, postmortems de incidentes) se crean con
`talent-docs-skill` (frontmatter, Diátaxis, markdownlint). La memoria volátil
(gotchas, hitos) va en `.claude/memory/` y viaja en los PRs de los carriles.

### Deslinde con los skills hermanos de coordinación multi-carril

Cuatro skills cubren espacio conceptual solapado (coordinación multi-carril,
gates pre-merge, despacho) con modelos distintos. Este skill es el más
antiguo (TAL-1104, junio 2026); los otros tres nacieron dos semanas después
sobre un modelo Incus/tmux/token-only más maduro. Elegir por el
**modelo de ejecución**, no por el nombre:

```text
¿Terminales/máquinas sueltas, SIN flota Incus, coordinación bare-metal?
  → talent-coordination (ESTE skill) — gate clásico por-PR, sentinel
    .claude/.cr-review-ok (flujo no-draft)

¿Máquina NUEVA que aprovisionar (Incus + Tailscale + golden)?
  → talent-channels — infraestructura, no coordina trabajo

¿Flota Incus/tmux ya montada, despachando encargos a PR draft + HANDOFF?
  → talent-channel-operation (v6.3) — merge-gate mecánico, sentinel
    .claude/.draft-handoff (canal de producción, CR lo consume el Mergeador)

¿Curar un batch de issues cross-milestone y repartir órdenes de trabajo?
  → talent-orchestrator (v2) — capa sobre los coordinadores, solo Linear
```

`talent-channel-operation` es la **variante de FÁBRICA** del MISMO régimen de
supervisión activa en cascada: la **fábrica v2 (ADR-0043)** reparte los roles de
otra forma (`talent-orchestrator` cura encargos y fija el régimen T7;
`talent-channel-operation` es el **rol Coordinador de fábrica** —1ª estación, uno
por repo, canales tmux/Incus— que entrega PR draft + HANDOFF; `talent-merger`
mergea/aplica), mientras que ESTE skill es el puesto de mando **CLÁSICO/LEGACY**
para el flujo **fuera del sistema de canales** (CLAUDE.md regla 10), donde el
coordinador gatea y **el carril mergea/aplica**. **Frontera dura:** este skill NO
ocupa el rol Coordinador de fábrica ni se inserta en la cadena
CEO → Orquestador → Coordinador → Canales; toma de la fábrica el **patrón**
(barrido obligatorio, PULL, compact-60, idle-real canónico N≥3), no los cortes de
rol. **Terminología:** «carril» = «canal» (sinónimo histórico); «encargo»/«bundle»
existen en la fábrica, pero la unidad del flujo clásico sigue siendo la
**issue/pieza**.

Reutilización explícita (simétrica a lo ya escrito desde `talent-channels`):
`talent-channels` reutiliza de este skill `scripts/hw-probe.sh` como asset de
sizing y su procedimiento de clonado dual-boot FS — NO su flujo de despacho.
Este skill, a su vez, NO reutiliza el `merge-gate.sh` mecánico de
`talent-channel-operation` ni la curaduría de batches de `talent-orchestrator`:
opera con su propio ciclo íntegro de **SUPERVISIÓN ACTIVA (régimen-condicional T7) más
planificación PROACTIVA** (`SKILL.md` §Essential Patterns), pensado para
terminales sueltos sin la infraestructura Incus.

Esta subsección es **solo documentación de deslinde** — no implica fusión,
deprecación ni rediseño de ningún skill de la familia.

## Next Steps

Lee el reference según tu momento:

- **¿Acabas de cargar el skill?** → `references/01-bootstrap-y-puesto-de-mando.md`
- **¿El lead pide una feature/necesidad nueva?** → `references/02-planificacion-y-despacho.md`
- **¿Llegó un STOP PRE-MERGE?** → `references/03-gates-pre-merge.md`
- **¿Toca crear/cerrar issues o una ventana de lanzamiento?** → `references/04-trazabilidad-linear.md`
- **¿Un carril reporta un cierre?** → `references/05-verificacion-independiente.md`
- **¿Prompts de carril, colisiones o recursos compartidos?** → `references/06-carriles-y-recursos.md`
- **¿Algo roto en prod o fix en caliente?** → `references/07-incidentes-y-caliente.md`
- **¿Perfilar la flota, generar fichas de carril o clonar una máquina?** → `references/08-perfilado-fichas-y-clonado.md`
- **¿Redactar un prompt, un STOP o un cierre?** → `prompts/plantillas.md`

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
Nunca vuelques el entorno ni ficheros de credenciales; comprueba únicamente nombres y presencia.
