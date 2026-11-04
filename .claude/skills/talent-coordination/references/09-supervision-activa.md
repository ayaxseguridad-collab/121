# 09 — Loop de supervisión activa y Compact-60 en cascada

> Movido íntegro desde SKILL.md (dieta <500 líneas del validador, paquete v1 · TAL-3348/3349).
> Doctrina VIGENTE sin cambios de contenido.

### Loop de supervisión activa (el invariante nuevo — supersede el "modo REACTIVO")

El coordinador NO espera pasivo a que los carriles reporten: **barre** sus
carriles en cadencia (observar) y **actúa** sobre el idle real (nudge / re-PULL /
escalar). "El supervisor es DUEÑO de la ocupación de sus subordinados": un carril
parado sin causa **en régimen de alta-cadencia** es incidente del coordinador, no
del carril. Coherente con la cascada de fábrica (`talent-orchestrator` ref 09,
`talent-channel-operation` Regla 12) — este es el hermano **clásico** del mismo
patrón, fuera del sistema de canales.

**Régimen-condicional (T7 — lo declara el LEAD en el flujo clásico):**

```text
alta-cadencia → cero-idle, barrido agresivo, PULL continuo; idle-real = incidente
tranquilo     → idle ACEPTABLE, sin presión de cola
paro          → NINGÚN dispatch nuevo (salvo re-fixes de PRs rebotados en vuelo)
SIN-RÉGIMEN   → fail-closed y NORMALIZACIÓN: cae aquí TODO lo que no sea exactamente
                uno de los tres valores de arriba — ausencia de declaración, cadena
                vacía, o valor NO reconocido (typo/externo, p. ej. `alta cadencia`
                sin guion, `rápido`, `null`). NO dispatch nuevo, ningún default
                implícito, solo read-only; se sale SOLO por declaración explícita del
                lead de uno de los tres valores válidos
```

**Barrido en DOS pasos (observar ≠ actuar):**

```text
(1) OBSERVAR  barrido periódico read-only que LEE estado y emite candidatos;
              NO ejecuta el nudge (el sweep no actúa, solo detecta).
(2) ACTUAR    sobre candidatos con IDLE-REAL, el coordinador aplica el paso propio
              (nudge por el canal / re-PULL / escalar), verificando el efecto.
```

**IDLE-REAL — definición canónica (= watcher/gate-muerto, vía `capture-pane`):**
un carril es idle-real SOLO con las SEIS condiciones a la vez (nunca por tiempo a
secas). Lo hacen cumplir SCRIPTS del skill — `scripts/idle-check.sh` (clasifica el
pane y expone `--relay-ready` e IDLE-REAL) y `scripts/relay.sh` (entrega con acuse
causal): **todo relay pasa por `relay.sh`; teclear `send-keys` a mano está
PROHIBIDO** (agujero del composer-sin-enviar, TAL-5141):

```text
1. Pane ESTÁTICO — CONTINUIDAD MUESTREADA en dos escalas (solo se detectan cambios
   OBSERVADOS, no se promete captar un "cambió y volvió" invisible): (a) MICRO —
   N≥3 capturas EN VIVO idénticas a ~2 s en la MISMA pasada (caza redraw/spinner/
   thinking que un snapshot pierde); (b) MACRO — hash del pane sin cambio observado
   durante ≥300 s (ventana de 5 min, NO 600 s), persistido con escritura ATÓMICA +
   lock; cualquier cambio observado RESETEA la ventana.
2. 0 procesos HIJOS de trabajo vivos: se recorre el ÁRBOL COMPLETO de descendientes
   del TUI (no solo los hijos directos del pane) y se excluye SOLO el proceso
   RESIDENTE conocido (el CLI del canal esperando input) — un build/gate cuelga del TUI,
   no del pane; contarlo mal daría idle FALSO con trabajo vivo.
3. Gate/watcher TERMINADO sin acción posterior (un gate e2e/build tarda 40-60 min
   → pane quieto con gate vivo NO está idle).
4. Excluidos los falsos positivos VISUALES, mirando SOLO la región de estado ACTUAL
   por sus bordes CORNER (nunca el scrollback): TUI-redraw, compact en curso y
   RAZONAMIENTO ACTIVO (spinner + "✻ Thinking…", "Cogitated for Ns", "Crunched for
   Ns", "· Determining… thinking with high effort") — el thinking va 2-9 min con 0
   hijos y pane cuasi-estático: NUNCA es idle.
5. Composer VACÍO — sin `composer-con-texto-sin-enviar`: texto de usuario real en la
   caja (por CONTENIDO, no por el glifo ❯) o cola `Press up to edit queued messages`
   es un estado BLOQUEADO accionable (orden sin enviar), no ocio.
6. Sin MENÚ-ABIERTO — firmas COMPUESTAS (`Enter to select` / `Would you like to
   proceed?` / `❯ N.` numerado); un menú/diálogo esperando decisión está bloqueado,
   no idle. `shift+tab` es footer NORMAL y `Press up` es cola: NO son firmas de menú.
```

Sin captura de pane / sin visibilidad de procesos hijos → estado `UNKNOWN`: el
idle-real queda **indeterminado** y NO se declara (fail-safe). Las señales
git/gh/Linear/ledger son **complementarias de progreso** (detectan trabajo vivo),
no el determinante del idle-real. Alineado con `orchestrator/SKILL.md:117-121`.

**PULL, no espera:** al liberarse un carril, el coordinador **tira del siguiente
trabajo del backlog del proyecto** (no espera que el carril lo pida); backlog
vacío → **escalar al LEAD** (en el clásico no hay Orquestador aguas arriba). En
`tranquilo` el PULL no es agresivo; en `paro`/`SIN-RÉGIMEN` no hay dispatch nuevo.

### Supervisor de flota (barrido de estados bloqueados)

Eje **SEPARADO** del idle-real de arriba: el barrido de flota detecta **estados BLOQUEADOS**
accionables (no "quieto sin novedad", sino "atascado necesitando un humano/coordinador"), sin
alterar la definición canónica de idle-real de las SEIS condiciones. Barrido de **5 min** (300 s)
sobre TODOS los panes dev del coordinador — `scripts/idle-check.sh <canal>` los clasifica —,
buscando:

- **`composer-con-texto-sin-enviar`** (rc 11): texto de usuario real en la caja o cola `Press up to
  edit queued messages` — la orden quedó SIN enviar; el falso "cero idle" de TAL-5141. Es la anomalía
  específica y accionable: **gana a busy** (el pane puede estar ocupado y aun así tener texto pendiente).
- **`menu-abierto`** (rc 10): AskUserQuestion / diálogo con firmas COMPUESTAS esperando decisión.
- **Diálogo de permisos** vivo sin resolver (el CLI espera aprobación y nadie responde).
- **Manual-mode** encendido sin que el operador esté presente (el agente quedó en modo manual y no
  avanza solo).
- **Login-muerto** (sesión expulsada / re-auth pendiente, el pane no puede progresar sin acción
  externa).
- **Parches locales sin publicar** (TAL-5204, origen: dos parches locales sin committear —
  `TF_RUNNER_USER`/`TF_RUNNER_REPO` en `seal-suite.sh`, único mecanismo que hoy permite a M1/M2
  arrancar suites en runners `vivecoder`, y un perfil entero en `channel-profiles.sh` — llevaban
  tiempo invisibles y uno casi se citó como canónico con un valor equivocado). El barrido EJECUTA
  `scripts/inventario-parches-locales.sh` sobre el repo de producto y `~/talent-factory` de cada
  host alcanzable: NO basta con mirar si el working tree está sucio — un `stash`, una rama sin
  upstream, una rama con upstream `[gone]`, o commits locales por delante del upstream conocido
  pueden existir con el working tree completamente limpio. Seis categorías cubiertas: dirty tree,
  stashes, ramas sin upstream, ramas con upstream ausente localmente, commits adelantados del
  upstream local, y worktrees secundarios (declarados, no analizados en profundidad). **Regla**:
  *parche local que desatasca = patch guardado en `briefs/` + issue el mismo día*. El inventario
  DECLARA, nunca revierte — hay parches vivos a propósito (revertir el de `seal-suite.sh` a ciegas
  tumbaría M1/M2 en el acto); cada hallazgo se triagea a mano: patch a `briefs/`, issue con dueño,
  y decisión explícita de si permanece aplicado o se revierte.

**Excluido explícito: ExitPlanMode.** Un menú de plan abierto es un estado LEGÍTIMO de espera de
decisión del lead/coordinador, no un bloqueo a nudgear — tratarlo como bloqueado invitaría a
enviar teclas contra un diálogo modal (ver `talent-context` gotcha 3). El supervisor de flota lo
deja en paz; el idle-real (arriba) ya lo trata como "siempre sucio" para efectos de compactar, no
de nudgear.

En producción, este barrido cazó **3 canales congelados la primera noche** (caso ch04: 1h parado
en estado URGENTE sin que nadie lo notara hasta el barrido). Orden del lead / sellos del bus
22-23-ago-2026.

### Compact-60 en cascada

El coordinador aplica compact-60 a **su propio** contexto (al 60 %, y solo en su
checkpoint limpio: fichero de regreso escrito FUERA de la sesión y VERIFICADO —
nunca "copiar fuera→`/compact`→pegar" a secas, ese resumen omite el gate — →
`/compact` → al volver, **paso-0 como primer acto**); a él lo vigila el **lead**.
Hacia los carriles: **donde tiene captura de pane** (barra `ctx:`) vigila su
contexto; **donde no** (máquina remota sin visibilidad) degrada a
**auto-gestionado por el carril** (self-watch + fichero de regreso verificado +
paso-0) y el coordinador solo lo **recuerda en el prompt**. No se simula
visibilidad de pane/`ctx:` que el puesto clásico no tiene. Doctrina canónica en
`talent-context`.

### Cadencia de supervisión escalonada de la capa superior (ítem 9, guardia 15-16 jul)

Cuando hay una capa por ENCIMA del coordinador (CEO/orquestador supervisando puestos de mando),
el régimen que funcionó en producción es ESCALONADO — dos relojes distintos, no uno:

- **Cortes de 120 s a los coordinadores** (la capa superior barre a sus supervisados directos con
  cadencia corta: leer su estado, cosechar sus reportes, adjudicar lo listo).
- **Auditoría directa de 360 s dentro de los canales** (salto de nivel: la capa superior mira los
  panes REALES cada 6 min — no solo lo que el coordinador reporta — para cazar divergencias
  censo↔realidad).
- **Re-censo con deadline tras cada orden de capacidad**: toda orden que cambia la carga
  (despacho, pausa, reciclaje) programa su verificación con plazo; no se da por ejecutada sin
  re-censar. Los barridos TERMINAN EN ACCIÓN (adjudicar/nudge/escalar), nunca en observación.

Es una cadencia DISTINTA del heartbeat de 300 s del propio coordinador sobre sus carriles (ver
`05-verificacion-independiente.md` y el gotcha 2 abajo): el heartbeat es el reloj de ESTE puesto;
el 120/360 es el reloj de la capa que lo supervisa. En la fábrica multi-canal el detalle vive en
`talent-orchestrator` (Torre); aquí aplica cuando el puesto clásico tiene supervisor.

### Gate: verificación superseded + rulings anti-stale

Dos disciplinas hermanas, ambas antes de dar por cerrado o vigente algo: verificar superseded cruzando Linear + git log de consolidaciones antes de cerrar, y verificar "YA VIVO" con git log + git grep antes de citarlo.

**Verificación superseded** — antes de declarar un issue/PR "superseded" o "ya cubierto por otro
merge", cruzar **Linear + git log de consolidaciones**: un `diff-vs-main` en cero NO prueba
superseded (puede ser que el diff aún no se generó, o que el contenido converge por casualidad
textual). La prueba es la consolidación real: el commit/PR que efectivamente absorbió el cambio,
citado por SHA. Caso: TAL-4735 (encargo del lead con verificación anti-stale aplicada).

**Rulings anti-stale** — antes de citar "mecanismo YA VIVO" (una función, un flag, un símbolo que
se asume ya en producción), verificar en el árbol REAL, no en memoria/entrenamiento:

```bash
git log --since=hoy --oneline                # ¿hay actividad reciente que pudo cambiarlo?
git grep -n '<símbolo>' -- <alcance>          # ¿el símbolo sigue vivo, con ese nombre, ahí?
```

Ambos comandos ANTES de afirmar que un mecanismo "ya está" — una afirmación "YA VIVO" sin esta
verificación es exactamente el patrón que produjo una refutación errónea en TREN-2.

### Gotchas del régimen de supervisión (reconciliación guardia 15-16 jul, TAL-3394)

Índice compacto — el detalle vive en el ref dueño de cada uno:

1. **El censo de actividad se mide por ARTEFACTOS, nunca por apariencia de pantalla** → una
   pantalla quieta puede ser un carril adjudicando por detrás (label persistente ≠ atasco); la
   sonda útil es credencial no-blanca + turno activo produciendo artefactos (mtime de
   relays/veredictos, avance del SHA). Ver `05-verificacion-independiente.md` §"Censo por artefacto".
2. **Barrido persistente OBLIGATORIO cada 300 s, re-armado SIEMPRE, cosecha en el MISMO turno**
   → los watchers de evento complementan el heartbeat, nunca lo sustituyen — sin el timer detrás,
   un cierre sin watcher se queda horas sin verificar. Prohibido cerrar un turno prometiendo
   cosechar en la próxima pasada. Ver `05-verificacion-independiente.md`.
3. **Auditar el PROPIO censo antes de escalar un atasco o reclamar una pérdida** → verificar
   contra artefactos/rama-origen ANTES de reportar "carril atascado" o "draft perdido": el falso
   positivo suele ser del observador. Ver `05-verificacion-independiente.md` §5.
4. **Toda orden lleva verbo + canal/carril destino + deadline + prueba de hecho verificable** →
   «adjudica ch44 YA y confirma "ch44 Opus vigente xhigh OK"» se ejecuta y se acusa; «procesa tus menús»
   no. Ver `06-carriles-y-recursos.md` §1 y `prompts/plantillas.md`.
5. **El fallo silencioso es el único imperdonable — escalar a tiempo** → un atasco, blocker o gap
   que no se escala mientras aún se puede corregir es peor que equivocarse. Ver
   `01-bootstrap-y-puesto-de-mando.md` §4 ("Responsabilidad ante el lead").
6. **HOST-GUARD: rutas absolutas / `command -v` y hostname-assert antes de tocar infra o PATH
   compartido** → un binario shimmeado responde "instalado" sin serlo — censo verde FALSO. Ver
   `08-perfilado-fichas-y-clonado.md` §8.
7. **Todo actor de fábrica tiene lado de lectura del bus/entrada, no solo escritura** (regla dura
   16, 2026-07-28) → el coordinador que solo publica (heartbeat, tablero) y nunca escucha el bus
   ni su propia entrada de órdenes es una ventana ciega estructural. Lado de lectura obligatorio
   con **cursor persistido fuera del proceso**, **latido explícito** y **cobertura amplia por
   defecto**. **Dos canales**, no uno: el bus de coordinación **y** la entrada propia del agente
   — con `send-keys` detached, un Enter que no aterriza deja la orden escrita y sin someter, y el
   agente no se entera de que existe. Doble salvaguarda: emisor manda el Enter en llamada
   SEPARADA y verifica el EFECTO (composer vacío); receptor vigila su propia entrada con anclaje
   estructural (nunca al pane entero — regla 17) y guarda de plausibilidad anti-NBSP. El
   muestreo por ticks REDUCE el riesgo, no lo elimina: un evento efímero puede desaparecer entre
   dos ticks — no se declara el canal "cubierto" por tener vigilante.
8. **Un detector cuyo patrón puede aparecer en el contenido que analiza se envenena solo**
   (regla dura 17, 2026-07-28) → `pgrep`/guards/watchers que buscan su propio patrón dentro de
   contenido donde ese patrón aparece legítimamente se disparan consigo mismos (un `pgrep` que
   matchea su propio waiter, un guard que matchea su payload, un watcher que suprime prosa ajena
   que lo cita). Exigir, donde la disyunción sea imposible, las DOS salvaguardas: **guarda de
   plausibilidad** (descartar el propio invocador antes de decidir) y **anclaje estructural, no
   textual** (una marca que solo el emisor legítimo puede producir). Familia completa con las
   reglas de evidencia por clave exacta y por efecto — ver `talent-merger` `references/07-gotchas.md`
   §6-7 para el desarrollo íntegro con evidencia medida.

Dos doctrinas encajan de forma parcial en este skill por no tener flota Incus: la
responsabilidad-única-del-CEO ante el lead vive de forma nativa en la fábrica multi-canal
(`talent-orchestrator`/`talent-merger`); aquí el gotcha 5 recoge su analogía directa (coordinador
→ lead, sin capa intermedia). El HOST-GUARD (gotcha 6) protege aquí clonado bare-metal y
perfilado, no contenedores Incus — su versión "contenedor" vive en `talent-channels`/
`talent-channel-operation`/`talent-orchestrator`.

### Escalada al lead (canal único, insistencia, cero-parados)

Extiende (no sustituye) la doctrina de escalado ya nativa de este puesto: "backlog vacío →
escalar al LEAD" (más arriba, sección Loop) y la "Responsabilidad ante el lead" de
`01-bootstrap-y-puesto-de-mando.md` §4. En el flujo **clásico** (este skill opera SIN capa CEO —
ver frontera dura en `SKILL.md`), el coordinador reporta DIRECTO al lead, sin intermediario: por
eso el canal único de escalada es el **terminal del LEAD**, no un CEO.

**Canal único, con insistencia hasta respuesta:** ante un blocker o gap real, el coordinador
escala por el terminal del lead y **insiste** (no un único mensaje sin seguimiento) hasta obtener
respuesta — el fallo silencioso sigue siendo el único imperdonable (gotcha 5). Orden del lead
22-ago-2026.

**"Cero-parados" CUALIFICADO por régimen T7** (no incondicional): mientras se espera respuesta del
lead, el default es **no quedarse parado** — pero esto rige SOLO bajo `alta-cadencia` (régimen
nativo de la sección Loop, arriba: cero-idle, barrido agresivo). En `tranquilo` el idle es
aceptable sin presión de cola; en `paro`/`SIN-RÉGIMEN` está PROHIBIDO iniciar dispatch nuevo
mientras se escala (fail-closed ya vigente) — "cero-parados" nunca autoriza saltarse esa
prohibición.

### Escalado obligatorio al bus y re-acreditación (cuando la instalación tiene bus)

Si la instalación corre el bus de la fábrica (`talent-ceo` refs 02 y 07), el canal único de escalada de
arriba **no basta por sí solo**: un coordinador que espera una decisión en un menú de su pane sin sellar nada
deja a la capa superior CIEGA (que solo lee sellos). Por eso:

- **Escalado obligatorio al bus.** Todo bloqueo que requiera autoridad superior se sella en el bus ANTES de
  esperar: marcador `ESCALA-<ROL>-<ref>`, nota `BLOQUEO-AUTORIDAD · espera:<rol> · decisión · default`
  (plantilla en `prompts/plantillas.md` §5). El ruling llega acusado con `ACK-<ROL>-<ref>`; sin acuse, el
  bloqueo no está resuelto. Esto se SUMA al aviso por el terminal, no lo sustituye.
- **Prohibido `/clear` en actores persistentes.** Tras un `/clear`, un reinicio o una sesión nueva el actor
  queda **NO ACREDITADO** hasta re-acreditar (`talent-ceo` `reacreditar.sh`: sello `ACRED-<ROL>-<nonce>`
  posterior a un cebado). Un «SELLO …» escrito en el pane NO es un sello: sellar es ejecutar `bus-sellar.sh`.
- La detección es mecánica: `torre-sweep.sh` marca `menu-abierto` y el doctor del CEO lo cruza con el último
  sello del rol (`FALLA bloqueo-sin-escalar` pasados `TA_ESCALADO_MIN` minutos).

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
