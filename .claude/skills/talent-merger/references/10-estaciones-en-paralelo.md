# 10 · Estaciones en paralelo: ventana de merge, batching por disjunción y suite nocturna

La fábrica opera **N estaciones de merge en paralelo** que drenan a la vez, pero `main` se toca de
forma **serializada**. Esta referencia fija cómo se reparte ese turno.

> **Autoridad de esta sección**: **`CEO-LEY-BATCHING-20:18`** — ley del lead por terminal (2026-09-04
> 20:18 CDMX, literal *«si, autoriza el batching con la suite nocturna»*), **ratificada por el CEO con
> poderes delegados del lead; el log de terminal es la prueba**.
>
> **Cada MUST de abajo va acompañado de su FRAGMENTO LITERAL de la ley**, no de un resumen. La razón es
> operativa, no de estilo: un resumen es una inferencia de quien resume, y **en cuanto se escribe en un
> fichero de doctrina deja de parecerlo**. Lo que aquí no lleva fragmento literal **no es la ley**: va
> marcado como *lectura del canal*, sin voz normativa.

**Procedencia verificable**: los fragmentos se transcribieron desde el **literal de la línea del bus**,
no desde un relevo. **Puntero inmutable**: commit `6d5118e260` (rama de origen de esta sección) —
`git show 6d5118e260:.claude/skills/talent-merger/references/10-estaciones-en-paralelo.md` reproduce
el texto exacto que se contrastó contra el bus. **Límite declarado**: el artefacto fuente
(`ley-batching-LITERAL.txt`, 2043 bytes) vivía solo en el contenedor del canal que redactó esta
sección y nunca se versionó junto con ella — su hash completo no es reconstruible desde este repo;
el `sha256 c7721a08f7ba9f84…` que citaba la versión anterior estaba truncado a 16 hex Y sin puntero
inmutable, así que no era contrastable pese a prometerlo. Si se necesita re-verificar contra el bus
de nuevo, el artefacto fuente debe commitearse junto con su hash completo la próxima vez.

**Estado de partida declarado por la ley**: *«Congelación de merges LEVANTADA con efecto inmediato: la
primera estación que postee verde abre la primera ventana.»*

---

## §0 · HUECO DECLARADO — lo que la ley EXIGE y este paquete NO define · LÉASE ANTES DE OPERAR

> **GUARD — EL BATCHING ESTÁ DESACTIVADO (fail-closed).** Ruling
> `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. Mientras los cuatro contratos
> de la tabla de abajo **no existan**, el camino de batching **no se opera**: no se sella un merge
> con `batching: disjunto de [...]`, y **la ruta `gh pr merge` tampoco se usa para agrupar**. Esto
> **no es un aviso**: es una puerta cerrada. La reapertura exige que los cuatro contratos existan y
> se puedan citar, no que alguien los dé por supuestos.
>
> **Y la distinción que evita el malentendido: LA VENTANA PARALELA NO ES BATCHING.** Cada unidad
> funde **con su propia suite completa sobre su propio head**; lo único paralelo es **el reloj**.
> La ventana sigue operativa. El batching —agrupar varias unidades bajo una sola evidencia— es otra
> cosa, y es la que queda apagada. *Una evidencia que no se puede auditar no autoriza un merge.*


**No es un defecto de la transcripción: el literal presupone estas cosas y aquí no constan.** Va
primero, y no enterrado junto a la cláusula que lo sufre, porque **quien opere la ventana necesita
saberlo ANTES de usarla, no al llegar al párrafo correspondiente**.

| Lo que la ley exige | Cláusula | Qué falta exactamente |
|---|---|---|
| el sello `M*-MERGED` **«con las cuatro cosas»** | cl. 3 (§4) | **cuáles son las cuatro.** No hay lista, contrato ni ejemplo completo, ni aquí ni en `talent-channel-operation` |
| **«un ancestro aceptado por el agregador #50»**, y re-medir **«los gates afectados (regla de #50)»** | cl. 1 (§1) | **qué es #50 y cuál es su regla.** `#50` aparece **sólo** en esa cita: sin procedimiento, autoridad ni puntero |
| la nocturna con **«37 gates, procedencia, runners a cota 4»** | cl. 4 (§5) | **cuáles son los 37 gates, de dónde sale la procedencia y qué es «cota 4».** `references/08-gates-locales.md` sólo aporta una medición histórica de **23** gates, que **no** verifica los 37 |
| identificar la pieza culpable **«por bisección entre los merges de la ventana»** | cl. 4 (§5) | **el procedimiento.** La acción está nombrada; no hay herramienta, criterio de corte ni fuente |

**Consecuencia operativa, dicha sin adornos.** Sin las dos primeras, el Mergeador **no puede construir
el sello ni auditar el de otro**, ni decidir si un ancestro entra ni qué gates son «los afectados».
Sin la tercera, **no puede comprobar que la nocturna satisface la salvaguarda** — y la nocturna es la
única red que caza el riesgo que el batching acepta a propósito. Sin la cuarta, el incidente se
resuelve a ojo. En conjunto: **la evidencia de batching no es auditable hoy**, y un gate que no se
puede comprobar degenera en criterio ad-hoc, que es justo lo contrario de para lo que se legisló.

**No se rellenan por deducción.** Se podría adivinar qué cuatro campos son, qué hace #50 o cuáles son
los 37 gates —el número 23 de la ref 08 invita a ello, y por eso se dice expresamente que **no
equivale**—, pero **inferir una ley es fabricarla**: quedaría escrito con voz normativa algo que el
legislador no dijo, y el siguiente relevo lo heredaría como literal.

**Dueño: quien emitió la ley (CEO / coordinación). Bloqueante: definir las cuatro filas de la tabla.**

**Qué NO dice esta sección, y por qué importa.** Una versión anterior de este párrafo terminaba en
*«hasta entonces, la vía de batching **se opera** sabiendo que su sello no es auditable»*. **Esa frase
se retira**: no está en el literal, tenía **voz normativa**, y **autorizaba exactamente lo que este
bloque existe para señalar** — mientras `SKILL.md` decía «no usar la ventana antes de resolverlo», la
§0 decía «se opera». Dos superficies de la misma entrega mandando cosas contrarias, y la permisiva
ganando por ser la que está junto al detalle.

**Esta sección no autoriza ni prohíbe: constata.** Lo que gobierna ya está escrito y no lo inventa
esta referencia — **los gates de la estación son `fail-closed`** (`SKILL.md`, fila «Gates AND del
merge» del Quick Orientation y **§6 del checklist, «Gates AND del merge»**;
`references/02-protocolo-por-pr.md` **§7, «Gates AND del merge (comandos por gate)»** — *«Los CUATRO
gates, verificables por API, fail-closed»* y *«ambiguo = FAIL → diagnosticar (Playbook), jamás
"probar a mergear"»*), y la regla de esa doctrina es que **una
señal que no se puede verificar no aprueba**: *«ambigua = FAIL (fail-closed) — el AND no se
negocia»* (`SKILL.md`, checklist «Gates AND del merge» — cita por frase, no por línea: ver §10 sobre
por qué un ancla numérica en un fichero que se edita en la misma entrega no es fiable). Aplicado aquí
sin añadir nada: **mientras el sello no sea construible ni
auditable, no hay evidencia de batching que pueda pasar un gate.** Levantar el bloqueante es del
dueño de la ley, no de quien opera ni de esta referencia.

---

## §1 · La ventana de merge

> **RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. El
> literal de abajo se transcribe **sin tocar una coma**, y es justo el que el ruling apaga: mientras
> la puerta esté cerrada **ninguna pieza se funde por haber medido disjunción**, y **CADA PR corre su
> suite COMPLETA sobre su propio head**. La **ventana** sigue viva —lo único paralelo es el reloj—;
> **ahorrarse la suite, no**.

**MUST** — cl. 1:

> *«Ventana: cuando una estación postea verde y anuncia «ventana abierta @\<tip\>», durante los
> siguientes 15 min cualquier otra pieza VERDE medida sobre ESE MISMO tip (o sobre un ancestro aceptado
> por el agregador #50) **puede fundirse a continuación SIN repetir suites** si el conjunto de ficheros
> de su diff es DISJUNTO del conjunto de ficheros **ya fundidos en la ventana**…»*

*Lectura del canal (no es la ley)*: las dos condiciones se leen como necesarias a la vez —**mismo
tip** (o ancestro aceptado por #50) **y** disjunción—, de modo que una pieza verde sobre otro tip no
entraría aunque fuese disjunta, ni una sobre el tip correcto si intersecta.

*Lectura del canal (no es la ley)*: **RUTA APAGADA (fail-closed)** — ruling
`CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`: lo que sigue explica QUÉ ahorraba
el literal, y ese ahorro **hoy no está disponible**. **El literal dice «SIN repetir suites»; no
declara para qué se legisló.** Este canal lo señala porque es lo que la ventana ahorra en la práctica, y un relevo que lo
omita deja el mecanismo sin explicación operativa — pero **la intención del legislador no consta en el
literal y aquí no se le atribuye**.

**MUST** — cl. 1, caso de intersección:

> *«Si hay intersección → esa pieza espera y **re-mide los gates afectados** (regla de #50).»*

*Lectura del canal (no es la ley)*: el literal dice **«los gates afectados»**, no «todos» — se lee como
re-medición acotada por la regla del agregador #50.

> **⚠ HUECO (§0)**: **qué es #50 y cuál es su regla NO consta en ningún sitio.** Ni el ancestro
> aceptable ni «los gates afectados» son decidibles con lo que hay. Ver §0.

## §2 · Cómo se mide la disjunción — y por qué se pega al sello

> **RUTA APAGADA — ESTE MÉTODO NO SE OPERA HOY (fail-closed).** Ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`.
> Medir la disjunción es el método **del batching**, y el batching está DESACTIVADO: **ninguna pieza
> se funde por haber medido intersección vacía**. Lo que rige mientras tanto: **cada unidad funde con
> su propia suite COMPLETA sobre su propio head**. Lo de abajo se conserva como transcripción de la
> ley y como contrato a cumplir *si* se reabre la puerta (§0), **no como una vía disponible**.

**MUST** — cl. 1, método:

> *«…(medido con `git diff --name-only` de cada squash, cruzado por API, y **pegado en el sello:
> intersección vacía**).»*

*Lectura del canal (no es la ley)*: que se pegue al sello convierte «comprobé que eran disjuntos» en
algo que otro puede volver a comprobar. Un spot-check que no deja su conjunto por escrito no es
evidencia, es memoria — y la memoria del que mergea no es auditable después de un incidente.

*Lectura del canal (no es la ley)*: esta medición se lee como de la misma familia que el Gate 3 de la
estación (`references/02-protocolo-por-pr.md`, «Gate 3 — Spot-check de disjunción / hot-files» — cita
por frase, no por línea, mismo motivo que §10), aplicada aquí **entre piezas de la misma ventana** en
vez de contra lo ya mergeado desde el branch-point. **El literal no establece esa relación**: la
señala este canal.

## §3 · Orden de entrada

**MUST** — cl. 2:

> *«Orden dentro de la ventana: el que abrió la ventana, luego por antigüedad de cola.»*

*Lectura del canal (no es la ley)*: el literal fija sólo esos dos criterios, así que no gobiernan el
orden ni el tamaño, ni la urgencia percibida, ni la insistencia.

## §4 · Qué lleva cada merge de una ventana

> **RUTA APAGADA — LA LÍNEA `batching: disjunto de [...]` NO SE EMITE (fail-closed).** Ruling
> `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. El sello de un merge de ventana **no lleva** esa línea
> mientras la puerta esté cerrada, y **no se usa `gh pr merge` para agrupar**. Un sello que la
> llevara estaría afirmando una evidencia que hoy **no es auditable** (§0). Lo que sí sigue en pie:
> **una unidad, su suite completa sobre su head, y el apply de migración en el mismo turno.**

**MUST** — cl. 3:

> *«Cada merge de la ventana lleva su sello **M\*-MERGED** con las cuatro cosas + la línea «batching:
> disjunto de [#a, #b]» y el apply de migración en el mismo turno **(estación con credencial)**.»*

*Lectura del canal (no es la ley)*: tres cosas del literal se pierden en cualquier resumen — el sello
tiene **nombre** (`M*-MERGED`), la línea de batching es **literal**, y el apply lo hace **una estación
con credencial**, que este canal lee como «no cualquiera que tenga el turno». Coherente con
`references/06-migraciones-y-slots.md`: el apply es gate de Done. **Ojo**: el literal no distingue el
caso sin migraciones (lee «el apply... en el mismo turno» sin condición) — `SKILL.md` y
`references/02-protocolo-por-pr.md` §8 sí lo condicionan («sin migraciones → verificar Done y liberar
el slot, sin apply»); esta lectura del canal asume que el literal describe el caso CON migraciones
(el único en que hay algo que aplicar), no que contradiga a la prosa operativa del skill.

> **⚠ HUECO (§0)**: **cuáles son «las cuatro cosas» NO consta.** El sello no se puede construir ni
> auditar tal como la ley lo exige. Ver §0.

## §5 · La salvaguarda: suite nocturna completa

**MUST** — cl. 4:

> *«SALVAGUARDA: SUITE NOCTURNA COMPLETA **sobre el tip de main** cada día a las **03:00 CDMX**
> (**37 gates, procedencia, runners a cota 4**), **lanzada por la estación que esté libre (por defecto
> M1)** y **sellada como `NOCTURNA-<fecha>-<sha>`**; un rojo main-borne en la nocturna **ABRE INCIDENTE
> en el primer turno de la mañana**: la pieza culpable se identifica **por bisección entre los merges de
> la ventana** y **se revierte o se arregla antes del siguiente merge**; hasta cerrarlo, **batching
> suspendido**.»*

*Lectura del canal (no es la ley)*: el literal fija **alcance** (el tip de main), **tamaño** (37 gates
con procedencia y runners a cota 4), **dueño** (la estación libre, por defecto M1) y **sello propio**.
Este canal señala que un relevo que deje sólo la hora convierte una salvaguarda medible en una
costumbre — pero eso es lectura, no texto de la ley.

> **⚠ HUECO (§0)**: **cuáles son los 37 gates, su procedencia y qué es «cota 4» NO consta**; la ref 08
> sólo tiene una medición histórica de **23**, que NO equivale. Y **la bisección no tiene
> procedimiento**. La salvaguarda no es comprobable hoy. Ver §0.

*Lectura del canal (no es la ley)*: el batching acepta un riesgo explícito —N piezas verdes por
separado, disjuntas en ficheros, pueden romper juntas por una interacción que ningún gate por-pieza
ve— y la nocturna es la red que lo caza. Por eso la suspensión no es proporcional al susto: mientras no
se sepa qué merge lo rompió, meter más piezas **añade candidatos a la bisección**.

## §6 · Exclusiones — van solos y con suite propia

**MUST** — cl. 5:

> *«Excluidos del batching (van solos y con suite propia): migraciones destructivas, money-path SEV, PR
> que toquen `TF_INPUTS_UNIVERSAL` (`package*.json`, lock, `.nvmrc`, `tsconfig`, `next.config`).»*

*Lectura del canal (no es la ley)*: el tercero es el que menos se ve venir. Esos ficheros **no
intersectan con nadie por nombre** y aun así cambian el suelo bajo el que se midieron todas las demás
piezas de la ventana. La disjunción de ficheros no los detecta — por eso están excluidos **por nombre y
no por medición**.

## §7 · Relación con los trenes padre

> **RUTA APAGADA (fail-closed).** Ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. Con el batching
> desactivado la comparación de abajo **no ofrece una alternativa operativa**: hoy la vía es el
> **tren padre** (`references/09-trenes.md`) o **la pieza sola con su suite completa**. La
> **ventana** paralela sigue viva —lo único paralelo es el reloj—; **agrupar evidencia, no**.

**MUST** — cl. 6:

> *«Los trenes padre siguen siendo la vía preferente: batching = varios padres/piezas verdes en una
> ventana.»*

*Lectura del canal (no es la ley)*: cuando un lote es cohesivo (mismo dominio/proyecto), la vía es el
tren padre de `references/09-trenes.md` — 1 CodeRabbit + 1 suite + 1 squash. El batching es para piezas
que **no forman lote**: verdes independientes que sólo comparten el turno.

---

> # ⟦ CABECERA ADJUDICADA — §8 a §11 ⟧
>
> **§8-§11 son LECTURA OPERATIVA del autor, no la ley. La ley son las seis cláusulas autenticadas de
> `CEO-LEY-BATCHING-20:18` (fuente: `ley-batching-LITERAL.txt`, 2043 bytes, sha `c7721a08f7ba9f84`).
> Nada de esta sección crea criterio ni autoridad; ante discrepancia manda el literal.**
>
> *(Texto de la cabecera fijado por adjudicación de coordinación, reproducido literal.)*

*Nota del canal (no toca el literal de arriba)*: el hash de esa cita hereda la misma limitación
declarada en la sección «Procedencia verificable» al inicio de este fichero — truncado, sin
artefacto fuente versionado, no contrastable hoy. Se deja el literal intacto porque es cita
adjudicada, no prosa propia de esta sección.

## §8 · Doctrina previa que esta sección presupone (no es la ley de batching)

*Lectura del canal (no es la ley)*: esta sección **no sustituye** la mecánica de claims; la presupone.
Cada punto obliga **por la fuente citada a su lado**, no por esta referencia:

- **First-claim-wins** — `references/01-rol-y-fronteras.md` (viñeta «First-claim-wins» — cita por
  frase, no por línea, mismo motivo que §10) **establece** que el primer `CLAIM #<PR>` del flock es
  el válido y que quien vea un claim ajeno precedente para el MISMO PR cede sin negociación.
- **Drain-disjoint** — misma fuente, viñeta «Drain-disjoint» — **establece** que dos estaciones nunca
  drenan el mismo PR en paralelo.
- **Escritura serializada** — `references/01-rol-y-fronteras.md` §Pipeline de la estación **establece**
  que la escritura sobre `main` es serializada: no se funden dos cosas a la vez.
  **Ojo con lo que NO dice**: esa serialización es de la ESCRITURA, no «un solo PR autorizado por
  turno». Una versión anterior de esta línea le atribuía a ref 01 el «serializador único del repo
  para el slot de merge» — ref 01 **ya no dice eso**, y atribuirle una prohibición que ha dejado de
  tener es peor que no citarla: quien fuera a comprobarlo encontraría otra cosa.
- **Fase quieta** — `references/08-gates-locales.md` (§*«Fase QUIETA — `unit` no solapa el pico e2e»*)
  **establece** que `unit` no solapa el pico e2e.
  *Lectura del canal*: se parece a la nocturna en no medir bajo contención, pero **esa relación la
  establece este canal**, no la ley ni ref 08.

## §9 · Estación sin visibilidad directa del bus (medición + deducción del canal)

`references/01-rol-y-fronteras.md` §2 («Acceso directo al flock canónico», **FUENTE ÚNICA** — cita
por frase, no por línea, mismo motivo que §10) **establece** que el espejo de solo-lectura cubre
**EXACTAMENTE UNA COSA: LEER**, y que **sin acceso directo al flock canónico la estación RECHAZA
intake, merge y apply**. **La obligación es de esa fuente, no de esta referencia.**

**CORRECCIÓN DE ESTA REFERENCIA (ronda 32, MAYOR — hallazgo de la 2.ª pasada)**: hasta aquí este §9
describía la fuente como si **no exigiera** escritura directa al flock y cerraba diciendo que *quien
opere por espejo decide con su propio criterio y su propia autoridad*. **Las dos cosas dejaron de
ser ciertas** —la primera describía una versión anterior de la fuente; la segunda nunca fue suya, era
lectura de este canal— y juntas dejaban **operativa por escrito la ruta que la fuente cierra**: una
estación con espejo retrasado podía no ver un `CLAIM` ya publicado y seguir el intake «con autoridad
propia». **Dos estaciones reclamando el mismo PR.**

> **Doctrina que se contradice a sí misma no es doctrina: es una ruta de evasión con formato de
> documento.** Cerrar la puerta en un fichero y dejar escrita la contraria en otro **no cierra nada**
> — el que opera lee el que tiene delante.

*Lectura del canal (no es la ley, y NO VINCULA)*: a este canal le parece que, sin lectura del flock, la
intersección vacía que se pegaría al sello **quedaría supuesta y no medida**, porque no habría forma de
contrastar contra piezas que no se ven. **Es una observación, no un gate — y NO una autorización**:
quien solo tiene espejo **no decide**, rechaza y rebota, según la fuente. Esta referencia no regula el
caso y **tampoco lo habilita**; si alguien quiere una excepción, hace falta un sello que hoy no existe.

## §10 · Lanzadores y supervivencia de procesos — estado medido (no es la ley)

Hechos **medidos** y ya escritos en otros ficheros, sin añadir mecanismo nuevo. La columna «Qué dice la
fuente» es **estilo indirecto**: la instrucción es de la fuente citada, **no de esta referencia**.

| Situación | Qué dice la fuente | Fuente |
|---|---|---|
| Shell en background durante un `/compact` | que **sobrevive**, y que al volver **se re-pollean** los pendientes en vez de relanzarlos | `SKILL.md`, §Gotchas — *«Los shells en background sobreviven al `/compact`»* |
| Wakeups / watchers ante un **relanzamiento** | que **NO sobreviven**, y que **se rearman a mano** | `talent-orchestrator/scripts/torre-resume.sh:89` |

> **Por qué esa fila cita una frase y no un número de línea**: `SKILL.md` se edita en la misma entrega
> que esta referencia, y un ancla numérica se desplaza sin avisar — una cita que apunta tres líneas más
> arriba parece válida y no lo es. El ancla textual sobrevive a la edición.

*Lectura del canal (no es la ley)*: de esos dos hechos este canal **deduce** que los 15 minutos corren
en tiempo de reloj y no en tiempo de agente; que un relanzamiento no pausaría la ventana y se llevaría
por delante cualquier watcher que la vigilara; y que a quien la abrió le convendría re-medir el tip y
el estado de la cola antes de dar por abierta su ventana. **La ley no regula el relanzamiento**: esto
es deducción, no obligación.

---

## §11 · Hallazgo del canal — texto caducado en otro skill (no es la ley)

*Hallazgo declarado por este canal, con dueño; no es texto de la ley*:
`talent-channel-operation/references/05-multicarril-merge-order.md:44-46` afirma **«Sin ventanas de
merge (v6.0)»**.

Este canal lo declara **CADUCADO** por `CEO-LEY-BATCHING-20:18`, por ser posterior y de igual
autoridad, y contradictorio con la práctica vigente. **Esa valoración de precedencia es del canal**: la
ley no se pronuncia sobre otros skills.

*Decisión de alcance de este canal*: la corrección **no se ha hecho aquí**, porque el texto vive en otro
skill y su dueño es **coordinación**. El hallazgo se deja escrito para que quien encuentre los dos
textos **sepa que existe la discrepancia** en lugar de resolverla por el que tenga más a mano.
