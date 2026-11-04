# 01 — Rol y fronteras de la 2ª estación

El marco completo del modelo fábrica vive en el
[ADR-0043](../../../../docs/decisions/0043-fabrica-v2-mergeador-posture-cr.md); esto es la
instanciación operativa del rol.

## Table of Contents

- [1. La fábrica: obra gruesa y acabados](#1-la-fábrica-obra-gruesa-y-acabados)
- [2. Actores y fronteras](#2-actores-y-fronteras)
- [3. Fire-and-forget: el productor no vuelve](#3-fire-and-forget-el-productor-no-vuelve)
- [4. La cola y su prioridad](#4-la-cola-y-su-prioridad)
- [5. Topología de la estación](#5-topología-de-la-estación)

## 1. La fábrica: obra gruesa y acabados

Dos estaciones con una interfaz única (el HANDOFF):

| Estación | Actor | Produce | NO hace |
|---|---|---|---|
| 1ª — producción | coordinador + canales de producción (`talent-channel-operation` v6.3) | PR **DRAFT** + comentario **HANDOFF** validado | CodeRabbit, esperar CI, rebases post-entrega, merge, apply de migraciones |
| 2ª — merge | **Mergeador** + sus canales de refactorización (este skill) | PR **merged** + migración aplicada + advisors + ledger + Done | re-desarrollar el encargo, re-juzgar el diseño aprobado, crear scope |

Razón de ser (ADR-0043): los buckets de CodeRabbit son el cuello dominante; centralizarlos
en un consumidor único que trabaja 24/7 con PRs pre-limpiados devuelve a los canales de
producción el 30-50% de wall-clock que quemaban esperando review/merge.

## 2. Actores y fronteras

| Actor | Frontera con el Mergeador |
|---|---|
| **Canal de producción** | Le entrega el draft+HANDOFF y desaparece. El Mergeador NUNCA le reabre diálogo: lo que falte se refactoriza en canales propios o se rebota al pool. |
| **Coordinador (1ª estación)** | Valida la entrega antes de reciclar el canal (su regla 13 = `verify-handoff.sh` exit 0). Un draft rechazado en intake (PROC-M01) vuelve a su tablero como aviso, no como diálogo con el canal. **La estación ANUNCIA al Orquestador los PRs que toma** — colisión sobre un PR cedido: doctrina T5 (dueño: `talent-channel-operation` ref 05; stand-down del coordinador ante `headRefOid` nuevo / `isDraft=false`). |
| **Orquestador** | Cura los encargos (bundles) y la **prioridad de la cola** del Mergeador; **recibe los bounce-to-pool** (PROC-M16) por la mecánica de su Decisión 6 — issues del bundle a `Backlog` + label `bounced` + comentario, NUNCA issues nuevas (`talent-orchestrator` ref 08). Mantiene la lista viva de superficies sensibles (ref 03). |
| **Lead** | GO explícito en: migraciones destructivas (SIEMPRE) y decisiones de producto/scope que un bounce destape. No participa en merges normales — los gates AND son objetivos. |
| **dev / auditor (canales del Mergeador)** | Equipos de refactorización: el dev implementa el fix del finding, el auditor lo verifica CONTRA los invariantes del HANDOFF (ref 05). Mismo loop adversarial que en producción, en micro-escala. |

**Releer el flock ANTES de actuar sobre CUALQUIER claim — sobre todo post-compact**: el estado de
claims vive en el **flock compartido**; una sesión recién salida de un `/compact` NO debe fiarse de su
memoria del turno. Antes de tomar, ceder o declarar un PR: releer el flock. Dos caras del mismo error,
ambas sangradas en producción: (a) tomar un PR por una directiva errónea cuando una **adjudicación del
CEO ya lo había reasignado** —una adjudicación del CEO **supersede** un pre-claim propio válido—; (b)
declarar un PR «sin claim» y gastar una suite de gates sobre un claim que **ya se había cedido**. Regla
dura: **jamás tomar un PR ni declararlo sin claim sin leer el flock primero.**

### Contrato de formato del flock y anti-doble-intake

**Formato del flock — 12 tokens EXACTOS** (sin emojis adicionales ni variantes; la
narrativa va en post aparte, no en la misma línea del token):

> **El número es parte del contrato, y se actualiza EN EL MISMO CAMBIO que añade o retira una
> fila.** Se corrige aquí porque no se hizo: la ronda 29 añadió `APPLY-ESCALAR-GO` —doceavo token—
> y dejó la cabecera diciendo 11, así que **el documento se contradecía justo en la línea que
> prohíbe las variantes**. Un contrato que no cuenta lo que hay deja de ser un contrato.
>
> **Y qué NO es una variante, dicho para que no se repita la confusión que la ronda 16 corrigió**:
> el `[-> <estación>]` de `APPLY-ESCALAR-GO` es **parte de la gramática declarada de ESE token**
> (dos aridades, 6 u 8 campos, ambas validadas por el parser), no un sufijo colgado sobre un token
> ajeno. Lo que aquella ronda prohibió —y sigue prohibido— fue **sobrecargar `APPLY-RUN`** con un
> sufijo para significar otra cosa: para eso se crea un token nuevo, que es justo lo que se hizo.

| Token | Cuándo |
|---|---|
| `# ✅ M<N> MERGED #<PR>` | El slot se cerró con merge exitoso |
| `# ✅ CEO RESUELTO #<PR>` | El CEO resolvió directamente |
| `# 🔴 BOUNCED #<PR>` | El PR fue rebotado al pool |
| `# CR-RUN [host:<name>]` | La estación inicia una corrida de CR en ese host |
| `# CLAIM #<PR> [<estación>]` | Una estación toma el PR para procesarlo |
| `# SLOT-CLAIM <slot> = #<PR> [<estación>] <ISO8601> <nonce> (<fichero>)` | Una estación reserva un slot de migración antes de pushear el renumber — `[<estación>]`, `<ISO8601>` y el `<nonce>` (UUID único por intento) son OBLIGATORIOS; el `<nonce>` es la identidad de GENERACIÓN inmutable (ronda 27, BLOQUEANTE: `#<PR>`+`<ISO8601>` acreditan FORMA, no unicidad — dos intentos en el mismo tick colisionan; ver §2 abajo "Semilla y generación del takeover") (TAL-5170, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`, §2 abajo) |
| `# APPLY-RUN [<estación>] #<PR> <ISO8601> <nonce>` | La estación arranca PROC-M13 para ese PR — el `<nonce>` (UUID único por intento) es lo que identifica de forma única ESTE intento; `#<PR>`+`<ISO8601>` dan contexto legible pero NO garantizan unicidad (ronda 27, BLOQUEANTE — antes bastaba el par y dos intentos en el mismo segundo colisionaban) (TAL-5170, ronda 14 + ronda 27, §2 abajo) |
| `# APPLY-DONE [<estación>] #<PR> <ISO8601> <nonce>` | PROC-M13 salió con `exit 0` (ledger confirmado, advisors en 0 ERROR) — libera el gate; repite el `<nonce>` EXACTO del `APPLY-RUN` que cierra (ronda 27 — así dos cierres de generaciones distintas NO son la misma línea y `publish_close` no traga el segundo) |
| `# APPLY-FAILED [<estación>] #<PR> <ISO8601> <nonce> <CATEGORIA>` | PROC-M13 salió con cualquier código distinto de 0; repite el `<nonce>` EXACTO del `APPLY-RUN` (ronda 27); `<CATEGORIA>` ∈ `TRANSITORIO`/`ESCALAR` — SOLO estos dos, nunca `DEFECTO` de forma automática (ronda 19: un advisor ERROR puede pertenecer a otro objeto, la investigación de ESCALAR decide si de verdad es DEFECTO, ver §2) — **el gate NO se comporta igual en las dos categorías, y decirlo aplanado contradecía al ejecutable**: `TRANSITORIO` deja el gap recuperable (`ROTO_T`) y un `APPLY-RUN` del MISMO gap lo retoma sin autorización externa; `ESCALAR` deja el gate **BLOQUEADO** (`ROTO_E`) hasta un `APPLY-ESCALAR-GO` explícito del CEO/Orquestador (§2, «Recuperación de un gap ESCALAR»). La recuperación autorizada depende de la categoría publicada, no de releer el `CLASS_FILE`/`$LOG` local de la estación que corrió PROC-M13 |
| `# APPLY-RECOVERS #<PR-fallido> <nonce-fallido> #<PR-nuevo> <nonce-nuevo> [<estación>]` | Declara, con identidad verificada por el `<nonce>` (ronda 27, antes `<ISO8601-fallido>` que no garantizaba unicidad), que el `APPLY-RUN` de `#<PR-nuevo>` que sigue recupera el `APPLY-FAILED` citado (TAL-5170, ronda 16 + ronda 27, §2 abajo) — sobre un gap `ESCALAR` NO basta por sí solo: exige un `APPLY-ESCALAR-GO` previo que cite el MISMO gap (§2, ronda 29) |
| `# APPLY-ESCALAR-GO #<PR-fallido> <nonce-fallido> [<CEO\|Orquestador>] <ISO8601> [-> <estación>]` | El CEO/Orquestador autoriza EXPLÍCITAMENTE que el gap `ESCALAR` identificado por `#<PR-fallido>`+`<nonce-fallido>` pueda recuperarse. El sufijo `-> <estación>` (opcional, estación SIN corchetes) **TRANSFIERE** la recuperación: sin él recupera solo la original, con él solo la nombrada — y **deja de aceptarse la original**, porque una recuperación tiene un dueño y nunca dos. Un sufijo malformado (o a medias) NO autoriza a nadie: se rechaza el token entero (ronda 30). **NUNCA lo publica una estación** — es la acreditación que faltaba: `APPLY-RECOVERS` exigía `<estación>` == la del gap, o sea que **la misma estación cuyo apply dejó el estado remoto incierto se autorizaba a sí misma a reintentar**, y una autorización que se concede el propio interesado no es una autorización (TAL-5170, ronda 29, ruling del CEO) |
| `# SLOT-CLAIM-TAKEOVER <slot> = #<PR> [<estación-nueva>] <ISO8601> <nonce-nuevo> (supersede <estación-anterior> <nonce-anterior>)` | El CEO/Orquestador confirma que la estación titular de un `SLOT-CLAIM`/`SLOT-CLAIM-TAKEOVER` sin terminal murió con el PR aún `OPEN` y autoriza a `<estación-nueva>` a tratar ese slot — Y el `CLAIM #<PR>` vigente de ese PR (drain-disjoint) — como reclamados por ella; `<estación-anterior>` es OBLIGATORIA y forma una cadena de sucesión, y el `<nonce-anterior>` (ronda 27, antes `<ISO8601-anterior>`) fija la GENERACIÓN exacta que se sucede por su identidad ÚNICA, no solo el nombre de estación ni un timestamp que puede repetirse (TAL-5170, hallazgo de revisión externa MAYOR, ronda 24 añade la cita obligatoria, ronda 25 añade generación + transferencia de CLAIM, ronda 27 sustituye el sello temporal por nonce único, §2 abajo) — NUNCA publicado por una estación sola |

**Claim atómico (documental — sin mecanismo de lock/CAS real; ese diseño queda para v1.9,
issue aparte)**. Doctrina, ya vigente en el resto del skill y que el token `CLAIM` formaliza:

- **Append bajo flock**: el token se escribe con `flock` sobre el fichero compartido — nunca
  una escritura directa sin lock, incluso para una sola línea (evita interleaving entre
  estaciones concurrentes).
- **First-claim-wins**: el primer `CLAIM #<PR>` que aparece en el flock es el válido; una
  estación que vea su propio intento de claim precedido por uno ajeno para el MISMO PR cede
  inmediatamente (no hay negociación ni "último gana").
- **Pre-claim-grep obligatorio**: ninguna estación escribe un `CLAIM` sin antes releer el
  flock completo (ver más arriba, "Releer el flock ANTES de actuar") — escribir a ciegas
  rompe first-claim-wins aunque el append esté lockeado, porque la decisión de tomar el PR se
  tomó sobre información stale.
- **Drain-disjoint**: dos estaciones nunca drenan el mismo PR en paralelo — un `CLAIM` vigente
  para `#<PR>` excluye a cualquier otra estación de procesarlo hasta que aparezca su
  `MERGED`/`BOUNCED`/`CEO RESUELTO` correspondiente.
- **Espejo para actores remotos**: un actor sin visibilidad directa del flock compartido opera
  sobre un espejo de solo-lectura con el mismo lag que ya tiene el resto del mecanismo de
  sincronización de esta sección — no se le exige escritura directa al flock, pero sí releer su
  espejo antes de cualquier decisión que dependa de claims ajenos. **Esto es una propiedad de
  TOPOLOGÍA (qué estación tiene o no acceso directo al host del flock, hoy "objetivo pendiente
  de cableado" — ref 08 §2/§5), no de identidad fija**: cualquiera de M1-M5 puede ser la
  remota según el cableado vigente en cada momento, no una estación concreta con carácter
  permanente. **El alcance de esta excepción NO se enumera aquí**: lo fija §2 abajo
  ("Acceso directo al flock canónico"), que es su **FUENTE ÚNICA** — el espejo cubre LEER, y todo
  lo demás exige flock canónico. Esta línea no repite la regla a propósito: repetirla es lo que la
  dejó incompleta y desincronizada tres veces (rondas 24 y 25, y el CR de T05).

**Regla anti-doble-intake**: ANTES de tomar cualquier PR, TODA estación corre
`command grep -E "(CLAIM|BOUNCED) #${pr}([^0-9]|$)" <flock>`. El límite numérico es
OBLIGATORIO: `#12` NO matchea `#123` ni `#120` (el `([^0-9]|$)` lo garantiza).
`command` es necesario para bypasear el wrapper de grep del entorno (ugrep con semántica
divergente). Un PR con estado `BOUNCED` en el flock **NO se re-intakea** — vuelve
exclusivamente vía re-entrega del canal autor con HANDOFF nuevo (ev #1170).

### Apply de migraciones: protocolo SLOT-CLAIM del bus (TAL-5170, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`)

**Ratificado por el CEO tras la ronda 12 de auditoría** (histórico completo de las seis rondas
previas — todas NO-GO, cada una por un motivo técnico o doctrinal distinto, nunca cosmético —
más abajo). **CUALQUIER estación (M1-M5) mergea y aplica a prod PRs con migraciones**: no hay
estación fija, turno rotativo, ni excepción por disponibilidad de una estación concreta.

**El acceso directo al flock canónico es PRECONDICIÓN DEL MECANISMO, no una excepción a esta
regla** (aclaración del CR de T05; la doctrina de arriba **no cambia**). El flock no acota quién
puede fundir: es lo que hace que «cualquiera» sea **seguro** — `SLOT-CLAIM` reparte el número de
slot y `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` serializan la ejecución. **Sin esa serialización,
«cualquiera mergea» sería una carrera; con ella es una doctrina operable.** Una estación sin
escritura directa al flock no es una excepción doctrinal: es una estación que **no puede ejecutar
el procedimiento** —igual que una sin credenciales de prod no puede aplicar—, y por eso §2 abajo le
manda rebotar el PR. **Eso no crea estación fija ni turno**: en cuanto tiene la capacidad, entra sin
más trámite.

**Alcance del espejo, dicho aquí porque ésta es su FUENTE ÚNICA (ronda 31, MAYOR)**: el espejo de
solo-lectura cubre **EXACTAMENTE UNA COSA: LEER**. Un actor que solo tiene espejo **no reserva, no
reclama, no transfiere, no cierra y no publica NADA** en el flock — leer un espejo con lag no
acredita el estado de un recurso que se decide por orden de escritura.

En consecuencia, **sin acceso directo al flock canónico la estación RECHAZA las tres cosas**:

| Acción | Con espejo únicamente |
|---|---|
| **Intake** de un PR | **RECHAZA** — rebota al pool; el pre-claim-grep sobre un espejo con lag no impide el doble intake, que es justo lo que ese grep existe para impedir |
| **Merge** | **RECHAZA** — el acto de merge se serializa por el flock; sin escribirlo no hay serialización, solo la creencia de tenerla |
| **Apply** a producción | **RECHAZA** — `SLOT-CLAIM` y `APPLY-RUN` son escrituras, no lecturas |

**Y en caso de duda NO cae en el espejo**: si no está claro si una acción es lectura o
lectura-y-reserva, se trata como escritura y se exige flock canónico. Fail-closed, porque el error
en la otra dirección es una carrera silenciosa. Reclamar un `CLAIM` **es reservar, no leer**, por
mucho que empiece por una lectura.

Confundir *precondición del mecanismo* con *excepción de la regla* es lo que hizo
parecer que este párrafo y §2 se contradecían.

**Este NO es el mismo mecanismo que el CLAIM/BOUNCED de arriba en su propósito** —protege el
ledger de prod, un recurso distinto del intake de PRs— **pero SÍ es el mismo mecanismo en su
forma**: un token nuevo, `# SLOT-CLAIM <slot> = #<PR> [<estación>] <ISO8601> <nonce> (<fichero>)`, sobre el MISMO flock
compartido, con las MISMAS reglas de "Contrato de formato del flock" de arriba (append bajo
flock, first-claim-wins, pre-claim-grep obligatorio). Es el SEXTO token del flock — se suma a
MERGED/CEO RESUELTO/BOUNCED/CR-RUN/CLAIM sin cambiar ninguno de los cinco existentes.
`APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED`/`APPLY-RECOVERS` (séptimo, octavo, noveno y décimo, punto 4 abajo) protegen un
recurso DISTINTO de `SLOT-CLAIM` — no el número de slot, sino la EJECUCIÓN del apply.

**Protocolo (verbatim de la ratificación en los pasos 1, 2, 6 y 7; los pasos 3, 4 y 5 son la
mecánica de ejecución que la ratificación deja abierta — no doctrina nueva, es aplicar al
`SLOT-CLAIM`/`APPLY-RUN` las mismas reglas que el `CLAIM` de arriba ya usa)**:

1. Antes del push del renumber, la estación renumera contra el tope real — ledger de prod ∪
   `origin/main` ∪ TODOS los PRs abiertos, con enumeración COMPLETA (ver gotcha de `gh pr
   list` abajo) — y publica `# SLOT-CLAIM <slot> = #<PR> [<estación>] <ISO8601> <nonce> (<fichero>)`, UNA
   línea por migración, con la propia estación, el timestamp de publicación y un `<nonce>` único
   por intento (ronda 25 añadió estación+timestamp; ronda 27 añade el `<nonce>` como identidad de
   generación única, ver "Semilla y generación del takeover" abajo).
2. Sin claim publicado no se pushea; un claim ajeno vivo sobre el MISMO slot es colisión →
   renumerar al siguiente libre (mismo first-claim-wins que `CLAIM`).
3. **Confirmación post-append, ANTES del push (corregido tras auditoría — ronda 12,
   BLOQUEANTE)**: el `flock` del append solo serializa la ESCRITURA, no la decisión — dos
   estaciones pueden leer «libre» y escribir su propio claim casi a la vez. Por eso, tras
   publicar, la estación RELEE el flock canónico y **pregunta por la ADMISIÓN, ejecutando**
   `intake_slot <flock> <estación> <slot>` (`apply-gate.sh` — **el `<slot>` es OBLIGATORIO y
   NUMÉRICO** —1-6 dígitos, mismo `TM_RE_SLOT` que valida la ESCRITURA del claim—: CLASE 2 v23/B-01
   RETIRÓ el «modo sin filtro» que antes se activaba pasando el slot vacío, porque era una
   escapatoria que el LLAMADOR controlaba (cualquiera podía pasar `""` y recuperar el recorrido del
   flock entero). Un slot omitido, vacío, sólo-espacios o no-numérico es **rc 3 «LLAMADA MAL
   FORMADA»**, distinto de 0/1, y ningún patrón `if rc -eq 0/1` lo confunde con una decisión; ver
   nota completa en el cableado de abajo): **rc 0 → adelante; rc 1 → cede** —
   aborta el push, renumera al siguiente libre y repite desde el paso 1.

   **Su rc se CAPTURA, NUNCA se invoca DESNUDA** (ronda 33, clase del inventario `set -e` — misma
   forma que el `set +e … publish_close … set -e` de §2 punto 5): `rc_adm=0; intake_slot "$flock"
   "$ESTACION" "$SLOT" || rc_adm=$?`. Esta receta corre bajo `set -euo pipefail`, y ahí una función que
   devuelve `1` llamada como comando suelto **mata el shell en esa misma línea**: el «cede» que la
   línea de arriba promete no se ejecutaría nunca, y el push abortaría por muerte del wrapper en
   vez de por decisión del gate. **No es un borde**: `rc 1` es el caso NORMAL —la estación que
   pregunta cuando la titular es otra—, así que la forma desnuda rompe justo en el camino más
   transitado. Medido en las dos direcciones sobre un flock real con cadena.

   **CABLEADO — de prescripción a receta (ronda 33: tres rutas independientes —yo, la pasada 1 del
   Orquestador, el CR de M2— encontraron el MISMO hueco: `apply-gate.sh` define `intake_slot`, T25
   la mide con siete casos, y NINGUNA receta ejecutable la invocaba)**. *Una guarda que nadie
   invoca no es una guarda a medias: es documentación.* El bloque de abajo es la receta REAL de
   los pasos 1-3 —no otra copia de la regla—, y por la MISMA razón que el `APPLY-RUN` de `ref 02`
   §8: acredita la procedencia ANTES de escribir, porque este bloque TAMBIÉN publica en
   `$FLOCK_FILE`, y un claim sobre un fichero no acreditado tiene el mismo defecto que el CRITICAL
   de la reserva de apply.

   ```bash
   set -euo pipefail
   # Contrato de entrada (el llamador las define): $FLOCK_FILE $TM_FLOCK_CANONICO_TRUSTED $ESTACION
   #   $SLOT $PR $RUN_ISO $NONCE $ARCHIVO. Misma biblioteca única que ref 02 §8 — no una segunda
   # copia: `. "$SKILLROOT/references/apply-gate.sh"` (aquí, sin la ceremonia de ancla por sha256
   # de ref 02: ese refuerzo protege el instante previo a un APPLY a PROD; este bloque coordina un
   # NÚMERO de slot, un recurso de menor coste si se tampering-ea — la MISMA función, cargada una
   # sola vez, sigue siendo la única implementación ejecutable). Este `source` NO fija un locale
   # de bloque (CLASE 1, ronda 37, B-02): un `export LC_ALL=C` al cargar sería una recomendación
   # que este mismo bloque —o cualquier llamador— podría PISAR reasignando `LC_ALL` después. En su
   # lugar, cada comparación que decide titularidad fija `C` en SU PROPIO ámbito DENTRO de las
   # funciones (`local`/`local -x`), así que esta receta no depende de un locale de bloque: sus
   # pasos no hacen comparación sensible al locale por su cuenta —`identidad_slot_valida` es
   # C-scoped, `flock_acreditado` no compara texto localizado, y `intake_slot`/`titular_vigente`
   # fijan C internamente—; ver el porqué en la cabecera de `apply-gate.sh`.
   . "$SKILLROOT/references/apply-gate.sh"

   # LA FORMA SE VALIDA ANTES DE INTERPOLAR (CLASE 1, ronda 34, BLOQUEANTE x2 — CR sobre v19):
   # `claim_line` se construía interpolando ESTACION/SLOT/PR/RUN_ISO/NONCE/ARCHIVO SIN validar
   # ninguno, y `printf` conserva los saltos de línea. Medido: un `$ARCHIVO` con un salto
   # publicaba TRES líneas en el flock, una FORJADA (`# APPLY-RUN […]` que nadie escribió); y
   # `ESTACION=M9` —una estación que no existe— entraba en contrato con rc 0 y ADMITIDA. El
   # remedio YA estaba escrito (ref 02 §8.0, `identidad_canonica`): se INVOCA, no se repite.
   identidad_slot_valida "$ESTACION" "$SLOT" "$PR" "$RUN_ISO" "$NONCE" "$ARCHIVO" \
     || { echo "identidad NO canónica (campo vacío o malformado): ABORTAR — nunca reservar" \
              "un slot con una identidad que después no se puede correlacionar" >&2; exit 2; }

   claim_line="# SLOT-CLAIM $SLOT = #$PR [$ESTACION] $RUN_ISO $NONCE ($ARCHIVO)"

   # LA PROCEDENCIA SE ACREDITA ANTES DE ESCRIBIR (mismo CRITICAL que ref 02 §8, misma cura):
   flock_acreditado \
     || { echo "FLOCK_FILE (${FLOCK_FILE:-<vacio>}) NO acredita ser el flock canónico" \
               "(${TM_FLOCK_CANONICO_TRUSTED:-<sin declarar>}): ABORTAR sin reservar slot" >&2; exit 3; }

   # PASO 1-2: append bajo flock (first-claim-wins — el pre-claim-grep de más arriba ya corrió
   # antes de llegar aquí; esto es la ESCRITURA, no la decisión de intake).
   exec 9>>"$FLOCK_FILE" || exit 3
   flock -x 9            || exit 3
   printf '%s\n' "$claim_line" >&9 || exit 3
   exec 9>&-

   # PASO 3: RELEE y pregunta por la ADMISIÓN — `intake_slot`, NUNCA desnuda bajo `set -e` (misma
   # clase que el punto 5 de abajo: el rc 1, «cede», es el caso NORMAL, no un borde). `$SLOT` SE
   # PASA (CLASE 2, ronda 34, BLOQUEANTE — CR sobre v19): sin él, la receta CONOCE su slot y
   # `intake_slot`/`titular_vigente` resolvían la cadena del FLOCK ENTERO — un claim histórico de
   # OTRO slot decidía la titularidad de ESTE. Falso rechazo y falsa admisión medidos a la vez.
   rc_adm=0
   intake_slot "$FLOCK_FILE" "$ESTACION" "$SLOT" || rc_adm=$?
   if [ "$rc_adm" -eq 0 ]; then
     echo "ADMITIDA: adelante con el push del slot $SLOT"
   else
     echo "CEDE (rc=$rc_adm): abortar el push, renumerar al siguiente libre y repetir desde el paso 1" >&2
     exit 1
   fi
   ```

   **Por qué se resuelve por la CADENA y no por «quién aparece primero» (ronda 29)**: el
   first-claim-wins sigue vigente y no se pierde —`titular_vigente` solo deja que el PRIMER
   `SLOT-CLAIM` abra la cadena, que es exactamente esa regla—, pero leer el orden de aparición
   **a secas** da la respuesta contraria en cuanto hay un relevo legítimo: tras un
   `SLOT-CLAIM-TAKEOVER` válido, **el primero en aparecer es la estación MUERTA**, así que la
   titular NUEVA cedería y la SUPERSEDIDA se creería con derecho a pushear. La admisión la
   decide la titular VIGENTE de la cadena, no la más antigua del fichero.

   Y se invoca la función **en vez de reimplementar la regla aquí**: la cadena tiene UNA sola
   implementación ejecutable (`titular_vigente`, en `apply-gate.sh`), acreditada caso a caso por
   el arnés. Una segunda copia en prosa operativa es la divergencia que la ronda 25 ya pagó.
4. **Lo que `SLOT-CLAIM` garantiza y lo que NO garantiza (corregido tras auditoría — ronda 12,
   BLOQUEANTE; alcance corregido de nuevo ronda 13, BLOQUEANTE)**: garantiza que dos
   migraciones NUNCA comparten número de slot. **No basta como mutex de apply, ni siquiera
   entre slots DISTINTOS** — la ronda 13 encontró que el ejecutor real, PROC-M13 (anexo §4),
   NO aplica "el slot de este PR": calcula el gap COMPLETO `main − ledger` y lo recorre
   entero. Si M1 mergea 100 y arranca PROC-M13, y M2 mergea 101 ANTES de que 100 quede
   registrado en el ledger, el gap que M2 calcula es `{100, 101}` — M2 intentaría aplicar
   TAMBIÉN el 100 que M1 ya está aplicando, sin partición por ownership. La independencia
   semántica entre 100 y 101 no evita esta carrera porque el ejecutor no filtra por "mi PR": la
   procesa entera. **Por eso el gate real no es sobre el NÚMERO de slot — es sobre la EJECUCIÓN
   de PROC-M13 misma**, mediante un token que lleva `#<PR>`, un timestamp ISO-8601 y un
   `<nonce>` (UUID único por intento) — la **identidad** (run_id) de ese intento es el `<nonce>`,
   único e inmutable una vez publicado; `#<PR>`+`<ISO8601>` dan contexto legible pero NO
   garantizan unicidad por sí solos (ronda 27, BLOQUEANTE: el par `(#<PR>, <ISO8601>)` acredita
   FORMA, no unicidad — dos intentos en el mismo tick, o un reloj que retrocede, lo repiten y
   colisionarían con la idempotencia global de `publish_close`)
   (`# APPLY-RUN [<estación>] #<PR> <ISO8601> <nonce>`).

   **Gate-check: quién es el titular (rediseñado tras auditoría — ronda 15, BLOQUEANTE — "más
   reciente gana" de la ronda 14 reintroducía la MISMA carrera bajo otro nombre)**: para saber
   si el gate está libre u ocupado, CUALQUIER lector (antes de adquirir, o simplemente para
   consultar) sigue SIEMPRE estos dos pasos, en este orden:
   1. Localizar el **último cierre válido** del flock — el `APPLY-DONE`/`APPLY-FAILED` más
      reciente (si no hay ninguno, el cierre válido es "el origen", antes de cualquier `RUN`).
   2. Localizar el **PRIMER** `APPLY-RUN` que aparece DESPUÉS de ese cierre — es el **RUN
      activo**, y su run_id es el que importa. Si no hay ninguno, el gate está LIBRE.

   **Correlación por identidad COMPLETA — obligatoria en el paso 1, no opcional (promovido desde
   ref 07 gotcha, ronda 25, BLOQUEANTE — hallazgo de revisión externa; ampliada de tres señas a
   las CUATRO en la ronda 28, CRITICAL — hallazgo de revisión externa)**: "el más reciente" del
   paso 1 NO significa "el último evento de tipo cierre en TODO el log, sin más" — un cierre
   duplicado/tardío de un `run_id` ANTIGUO, publicado por un reintento después de que un `RUN`
   más nuevo ya haya arrancado, aparecería cronológicamente DESPUÉS de ese `RUN` nuevo y
   corrompería el paso 2 (no encontraría ningún `RUN` después de él, aunque el `RUN` nuevo siga
   activo).

   **EL GATE SOLO LO LIBERA QUIEN LO TOMÓ.** El paso 1 exige que el cierre candidato reproduzca,
   por **igualdad exacta**, la **identidad canónica COMPLETA** del `APPLY-RUN` que dice cerrar:
   **todas** sus señas, jamás un subconjunto — hoy son cuatro (el **DUEÑO** `[<estación>]`, la
   **GENERACIÓN** `<nonce>`, `#<PR>` y `<ISO8601>`), y esa cuenta se cita aquí como ILUSTRACIÓN,
   no como definición: si el token gana un campo, manda el ejecutable y no esta frase. Un cierre
   que no acredita la identidad entera **no libera NADA**: cae en el default BLOQUEAR. **Esa
   identidad tiene UNA sola definición y vive en el ejecutable**
   (`ident` en el parser de `ref 02` §8, construido con las MISMAS ERE que el productor); esta
   doctrina la **CITA, no la vuelve a enumerar** — y la razón es el fallo que esta redacción
   cierra: la versión anterior enumeraba a mano `#<PR>` + `<ISO8601>` + `<nonce>` y **OMITÍA la
   estación**, así que un `# APPLY-DONE [M5] …` que repitiera el `<nonce>` de M4 —y el flock es
   legible por toda la flota, el `<nonce>` no es un secreto— **cumplía la letra del texto y
   liberaba el turno de M4 mientras M4 seguía aplicando a producción**. El ejecutable sí lo
   rechazaba (`proc-m13.selftest.sh`, caso «un DONE de OTRA estación no cierra el turno»): texto
   y ejecutable DISCREPABAN, y el permisivo era el texto. Tres de cuatro señas escritas a mano
   al lado de una definición de cuatro son **tres oportunidades de divergir**; por eso aquí no se
   re-enumeran.

   El `<nonce>` sigue siendo la clave que distingue GENERACIONES (ronda 27, BLOQUEANTE:
   `#<PR>`+`<ISO8601>` pueden repetirse entre dos intentos, el `<nonce>` no), pero distinguir la
   generación no es acreditar al dueño: hacen falta las dos cosas. `publish_close()` (abajo)
   cierra el extremo del PRODUCTOR —no publica cierre alguno si su propio `APPLY-RUN` no está en
   el flock (ronda 28)— y hace además este caso irreproducible en la práctica al reintentar de
   forma idempotente bajo el mismo flock; pero esta correlación en el gate-check es la segunda
   capa: cualquier otra fuente futura de cierre duplicado o ajeno (edición manual, bug distinto)
   sigue sin poder liberar un gate ajeno.

   **Cualquier `APPLY-RUN` que aparezca DESPUÉS del RUN activo pero ANTES de su cierre es VOID
   por definición** — ninguna estación lo ejecuta ni lo trata como titular, ni siquiera la que
   lo publicó: es un intento que llegó tarde a una carrera ya resuelta. No hace falta un token
   de cancelación aparte — todos los lectores calculan el MISMO RUN activo con el MISMO
   algoritmo determinista (primero-tras-el-último-cierre, nunca "el más reciente"), así que un
   RUN void queda ignorado por todos, para siempre, sin ambigüedad.

   **Adquisición**:
   0. La adquisición **no se copia de aquí**: la receta EJECUTABLE es `ref 02` §8.0, y su
      validación de identidad es **`identidad_canonica()`** (`ref 02`), acreditada por los casos
      **`uuidgen rc=1`** y **`nonce basura: se valida el VALOR, no el rc`** del arnés
      `proc-m13.selftest.sh`. **Entrada**: `CLASS_FILE`, estación, PR, sello ISO, nonce y HEAD.
      **Salida**: 0 si la identidad es canónica; distinto de 0 ⇒ **abortar sin reservar**.

      **Esta sección NO reproduce el paso 0.** La versión anterior lo transcribía —`RUN_NONCE` de
      `/proc/sys/kernel/random/uuid` con caída a `uuidgen`— **y se dejaba fuera la validación**: un
      operador que copiara esta prosa publicaba en el `APPLY-RUN` un nonce **sin comprobar**, y de
      ese valor cuelga toda la identidad de la serialización. El validador ya existía y ya se usaba
      para los nonces LEÍDOS del bus; quien no validaba era **el texto**. Es el daño concreto de
      reenunciar en vez de citar, cometido justo aquí.
      — el `RUN_NONCE` (UUID único por intento, ronda 27, BLOQUEANTE) se fija AQUÍ una sola vez y
      NO se regenera DENTRO del mismo intento: es la identidad de ESTE turno de extremo a extremo (el
      `APPLY-RUN`, su cierre `APPLY-DONE`/`APPLY-FAILED`, la correlación del gate-check y la
      recuperación `APPLY-RECOVERS` lo repiten EXACTO). Sin él, dos intentos del mismo PR con el
      mismo `<ISO8601>` producen el MISMO literal de cierre y el segundo lo traga el `grep -qxF`
      de `publish_close`, dejando el segundo turno activo pero creyéndose cerrado. Todo esto —
      ANTES de intentar
      publicar `APPLY-RUN` siquiera, no después de ganarlo (corregido ronda 21, MAYOR: crearlo
      DESPUÉS de ganar el gate — como hacía la ronda 20 — deja el token huérfano si `mktemp`
      falla por disco lleno/permisos/inodos/`TMPDIR` inválido, porque en ese punto el wrapper ya
      terminaría bajo `set -e` sin ejecutar PROC-M13 NI publicar ningún cierre, y la flota
      quedaría bloqueada esperando el timeout de 30 minutos en vez de fallar limpio de
      inmediato). Si `mktemp` falla AQUÍ, el wrapper aborta ANTES de publicar nada — no hay
      gate que huérfanar porque nunca se reclamó uno.
   1. Gate-check. Si OCUPADO, esperar (poll) el cierre del run_id activo — no el más reciente,
      el ACTIVO — y repetir el gate-check.
   2. Si LIBRE, publicar `# APPLY-RUN [<estación>] #<PR> <ISO8601> <nonce>` (el `<nonce>` es el `$RUN_NONCE` fijado en el paso 0 — único por intento, ronda 27).
   3. RELEER y repetir el gate-check COMPLETO desde el paso 1 (recalculando desde el último
      cierre, no asumiendo nada). Si el RUN activo resultante es el propio (mismo run_id), GANÓ
      — a partir de aquí la estación está DENTRO del turno reservado, que abarca `gh pr merge`
      → `git pull --rebase` → lectura del runbook → PROC-M13 (SKILL.md §7 y ref 06 §3), no solo
      PROC-M13 (ronda 25, BLOQUEANTE — hallazgo de revisión externa: mover el claim a ANTES del
      merge metió el `gh pr merge` y el pull DENTRO de la reserva; ver "Turno reservado = un
      cierre en TODA vía de salida" abajo). Si NO — incluida la posibilidad de que fuera la MISMA
      estación con un intento anterior, el run_id lo distingue sin ambigüedad — el propio RUN
      quedó VOID: no se ejecuta PROC-M13, se espera el cierre del run_id que sí ganó, y se
      repite **desde el paso 0, con identidad NUEVA** — un RUN que perdió es **VOID PARA
      SIEMPRE**, así que reintentar reusando su `<nonce>` publica una identidad ya descartada y
      la estación no vuelve a adquirir jamás. Perder abre un intento NUEVO, y el nonce es único
      **por INTENTO** (es el mismo motivo por el que el paso 0 lo exige: dos intentos que
      comparten identidad comparten literal de cierre). Es el mismo first-claim-wins que `CLAIM`/`SLOT-CLAIM` ya usan
      (arriba) — "primero" definido por posición en el flock relativa al último cierre, nunca
      por recencia, que es exactamente lo que fallaba en la ronda 14.

   **Cierre: éxito vs fallo, por CÓDIGO DE SALIDA puro — sin clasificar fases (corregido tras
   auditoría — ronda 14, BLOQUEANTE; correlación por run_id reforzada ronda 15, MAYOR;
   simplificado ronda 16, MAYOR)**: verificado contra el ejecutor REAL (anexo §4) — TODO fallo
   de PROC-M13, en CUALQUIER paso (preflight Paso 0/0b, lectura Paso 2, pre-check Paso 1, POST
   Paso 4, confirmación/advisors Paso 5), termina en `exit 1` o `exit 2`; la ÚNICA vía a
   `exit 0` es completar el script entero SIN que ninguno de esos `exit` dispare — lo que
   exige, en particular, `nerr = 0` en AMBOS advisors (Paso 5, anexo línea 464) y sincronía
   confirmada. Por tanto `exit 0` YA SIGNIFICA "ledger completo y advisors limpios", sin
   necesidad de que el wrapper distinga QUÉ paso falló — la ronda 15 intentó clasificar
   preflight/mid-gap/post-apply por separado y el intento de implementarlo (wrapper +
   trap) resultó inviable (ver abajo). La regla se reduce a:
   - `$?` de PROC-M13 es `0` → publica `# APPLY-DONE [<estación>] #<PR> <ISO8601> <nonce>` (mismo
     run_id del RUN, mismo `<nonce>`) — el gate vuelve a quedar LIBRE.
   - `$?` de PROC-M13 es CUALQUIER OTRO valor → publica
     `# APPLY-FAILED [<estación>] #<PR> <ISO8601> <nonce> <CATEGORIA>` (mismo run_id/nonce, más la
     categoría de recuperación — ver clasificación abajo), sin excepción y sin intentar
     adivinar en qué paso ocurrió. La `<CATEGORIA>` se publica en el MISMO acto que el
     cierre, nunca a posteriori (corregido ronda 18, MAYOR — antes vivía solo en `$LOG`
     local a la estación que corrió PROC-M13, ilegible para otra estación o tras un
     reinicio; ahora es parte del token, durable y compartida por el flock).

   **Publicación del cierre — secuencial, sin trap, sin pipe sin proteger, clasificación por
   canal ESTRUCTURADO (corregido tras auditoría — ronda 15, MAYOR; orden corregido ronda 16,
   BLOQUEANTE; mecanismo reescrito ronda 17, BLOQUEANTE; clasificación real y protección
   contra fallo de `tee` cerradas ronda 19, BLOQUEANTE + MAYOR; clasificación movida de "grep
   sobre `$LOG`" a "campo estructurado que PROC-M13 escribe él mismo" ronda 20, BLOQUEANTE)**:
   PROC-M13 (anexo §4) ya instala su propio `trap ... EXIT` para limpiar `$WORKDIR`, y Bash
   solo conserva el ÚLTIMO trap de una señal — la estación NO toca PROC-M13, lo invoca desde
   un wrapper propio. Un trap en el WRAPPER resulta innecesario si la secuencia entre "el hijo
   terminó" y "el cierre se publicó" no tiene ningún comando que pueda fallar de por medio SIN
   capturarse:

   0. `CLASS_FILE`/`PROC_M13_CLASS_FILE` YA existen — se crearon en el paso 0 de "Adquisición"
      (arriba), ANTES de publicar `APPLY-RUN` (ronda 21, MAYOR — ver por qué ahí). Este
      fichero, NO `$LOG`, es de dónde se lee la clase (ver por qué, abajo). Vive FUERA del
      `$WORKDIR` propio de PROC-M13 (que el `trap` de PROC-M13 borra al salir el hijo, antes
      de que el wrapper llegue al paso 5) — si viviera dentro, desaparecería justo cuando el
      wrapper necesita leerlo.
   1. `set +e` — protege TODA la secuencia siguiente, no solo bajo `pipefail`: incluso SIN
      `pipefail`, si `tee` (el ÚLTIMO comando de la tubería) falla por su cuenta — disco
      lleno, permiso — el estado de la tubería YA es el de `tee`, y `set -e` abortaría antes
      del paso 4 igual (verificado ejecutando la secuencia con `tee /dev/full`: sin esta
      protección, el wrapper termina sin publicar nada — ronda 19, BLOQUEANTE).
   2. `bash proc-m13.sh 2>&1 | tee "$LOG"` — corre el hijo, streameando su salida a la vez que
      la guarda en `$LOG` (para diagnóstico HUMANO; ya NO se lee para clasificar, ver abajo).
   3. `rc="${PIPESTATUS[0]}"` — el código de salida REAL de `proc-m13.sh`, no el de `tee` ni
      el de la tubería. **Debe leerse ANTES de reactivar `-e`** (verificado: `set -e` por sí
      solo, como comando suelto, PISA `PIPESTATUS` con `(0)` igual que `|| true` — invertir
      el orden reproduce el mismo bug, ronda 19 MAYOR).
   4. `set -e` — se reactiva SOLO después de leer `PIPESTATUS` en el paso 3.
   5. `publish_close "$rc"` — publica el cierre Y clasifica. **Su rc se CAPTURA con `errexit`
      desactivado SOLO en esta llamada** (ronda 28, MAYOR — hallazgo de revisión externa):
      `set +e; publish_close "$rc"; rc_close=$?; set -e`. El paso 4 reactiva `set -e` antes de
      llegar aquí, así que un `publish_close` que agota sus cinco intentos y devuelve 1 MATABA
      el wrapper en esta misma línea: el paso 6 —la limpieza— no llegaba a ejecutarse nunca y
      cada turno sin cierre dejaba además un `CLASS_FILE` huérfano en el TMPDIR del operador,
      justo en el incidente en el que menos se mira. Las dos funciones, definidas en el wrapper:

      ```bash
      classify_log() {  # $1 = ruta a CLASS_FILE — NUNCA $LOG (ronda 20, BLOQUEANTE)
        local class_file="$1" content
        content="$(cat "$class_file" 2>/dev/null || true)"
        case "$content" in
          TRANSITORIO) echo TRANSITORIO ;;
          *) echo ESCALAR ;;   # vacío, corrupto, ausente (SIGKILL antes de clasificar) → fail-closed
        esac
      }

      # ── flock_acreditado — PROCEDENCIA del flock, no solo su contenido (ronda 32, MAYOR).
      #
      # EL HALLAZGO, en una frase: **la guarda se portaba bien con el flock QUE LE DABAN, y nadie
      # preguntaba quien lo elige**. `FLOCK_FILE` llega del llamador y decide una EXCLUSION MUTUA — eso
      # no es un parametro, es una CREDENCIAL. La probe del auditor publico sobre una ruta local
      # arbitraria presentada como espejo: la exclusion se evade eligiendo otro fichero, sin tocar
      # ninguna de las guardas que si funcionaban.
      #
      # Por que la primera pasada dio cero y la segunda no: sus cuatro fixtures (dueno/otro/vacio/
      # ausente) corrian sobre LA MISMA RUTA. Eso acredita que la guarda distingue TITULARES; no
      # acredita que la ruta sea la canonica. **Un ambito estrecho da un CERO FALSO.**
      #
      # Se compara por FICHERO (`-ef`: mismo dispositivo e inodo), NO por cadena: dos rutas distintas
      # pueden nombrar el mismo fichero (symlink, `..`, montaje) y dos cadenas parecidas pueden nombrar
      # ficheros distintos. Comparar texto seria medir un proxy del recurso, no el recurso.
      #
      # SIN `TM_FLOCK_CANONICO_TRUSTED` DECLARADO -> RECHAZA. No hay defecto que valga: si nadie declaro cual es
      # el flock canonico, no existe procedencia que acreditar, y admitir «lo que me pasen» es
      # exactamente el agujero. Fail-closed de verdad, no fail-closed en el texto. La declaracion vive en
      # el anexo por repo (overlay), que es donde el skill pone lo que depende de la instancia.
      #
      # LIMITE DECLARADO, no disimulado (M-01, ronda 34, MAYOR — CR sobre v19): esta funcion prueba
      # ALGO solo si `FLOCK_FILE` y `TM_FLOCK_CANONICO_TRUSTED` pueden discrepar. Si el MISMO acto de
      # configuracion mueve las DOS variables juntas hacia el mismo fichero equivocado, `-ef` compara
      # el sujeto consigo mismo y da exito — una comprobacion cuya referencia se mueve CON el sujeto
      # no comprueba nada. Esta funcion NO PUEDE verificar eso en tiempo de ejecucion: es una propiedad
      # del DESPLIEGUE (de donde sale cada variable), no del codigo. El sufijo `_TRUSTED` en el nombre
      # es deliberado: marca que su procedencia debe ser de OTRA capa que la que fija `FLOCK_FILE`, para
      # que un refactor futuro no la derive sin querer copiando un patron de nombres parecidos. Doctrina
      # completa y el porque en el anexo por repo, tabla «Flock canonico».
      #
      # CLASE 3 (ronda 35, dos pasadas independientes): el renombrado de arriba NO crea un canal de
      # confianza — es una convencion de nombre, no una garantia de procedencia. El anexo por repo
      # corrigio el titulo de esta doctrina (afirmaba logro donde solo habia intencion) y declara la
      # independencia real de origen NO MEDIDA, no cerrada: ningun script de este skill puede verificarla
      # ni convertirla en medida, porque vive en la capa de aprovisionamiento/despliegue de la flota.
      flock_acreditado() {   # rc 0 = la ruta recibida ES el flock canonico
        [ -n "${TM_FLOCK_CANONICO_TRUSTED:-}" ] || return 1
        [ -n "${FLOCK_FILE:-}" ]        || return 1
        [ "$FLOCK_FILE" -ef "$TM_FLOCK_CANONICO_TRUSTED" ]
      }
      publish_close() {  # $1 = rc de proc-m13.sh
        local rc="$1" tok extra="" n line run_line
        if [ "$rc" = "0" ]; then tok="APPLY-DONE"
        else tok="APPLY-FAILED"; extra=" $(classify_log "$CLASS_FILE")"; fi
        # línea COMPLETA calculada UNA vez — el retry reintenta EXACTAMENTE este literal, no
        # recalcula tok/extra en cada vuelta (ronda 25, BLOQUEANTE — ver por qué abajo). El
        # `$RUN_NONCE` (único por intento, fijado en Adquisición paso 0) va DENTRO de la línea
        # (ronda 27, BLOQUEANTE): así el cierre de dos generaciones distintas del MISMO #PR con
        # el MISMO $RUN_ISO son líneas DISTINTAS, y el `grep -qxF` de abajo solo deduplica un
        # reintento REAL de la MISMA generación (mismo nonce), nunca traga el cierre de otra.
        line="# $tok [$ESTACION] #$PR $RUN_ISO $RUN_NONCE$extra"
        # LA PROCEDENCIA SE ACREDITA ANTES QUE NADA: si la ruta no es la canonica, no hay turno que
        # cerrar ahi y publicar seria escribir en un fichero que no gobierna nada — o peor, hacer creer
        # que se cerro. Va DELANTE del resto de guardas porque las de abajo razonan sobre el CONTENIDO
        # del flock, y el contenido de un fichero equivocado no es evidencia de nada.
        if ! flock_acreditado; then
          _msg="✗ publish_close: FLOCK_FILE (${FLOCK_FILE:-<vacio>}) NO acredita ser el flock canonico (${TM_FLOCK_CANONICO_TRUSTED:-<sin declarar>}) — NO publico: un cierre sobre un fichero que no gobierna la exclusion no cierra nada y hace creer que si. ESCALAR AL CEO/ORQUESTADOR YA"
          echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
          echo "$_msg" >&2
          return 3
        fi
        # EL GATE SOLO LO LIBERA QUIEN LO TOMO (ronda 28, CRITICAL — hallazgo de revision externa).
        # Un cierre acredita DUENO (`[<estacion>]`) y GENERACION (`<nonce>`); publicarlo sin acreditar
        # ninguno de los dos es como se libera —o se atasca— el gate AJENO. Aqui se comprueba lo unico
        # que el productor puede probar POR SI SOLO, y en la unica direccion que es segura: si MI
        # `APPLY-RUN` no esta en el flock, yo no abri este turno y NO publico cierre alguno.
        # LIMITE DECLARADO, no disimulado: la presencia de mi RUN **no** prueba titularidad —puedo ser
        # un perdedor VOID—, y eso lo decide el gate-check del lector correlacionando la identidad
        # COMPLETA (ref 01 §2, parser de ref 02 §8). Por eso la guarda es de AUSENCIA: la ausencia SI
        # prueba «no soy el dueno» —**pero SOLO si la lectura tuvo exito**, precision anyadida en la ronda
        # 30: un flock ilegible no produce una ausencia, produce un NO SABER, y se trata aparte abajo—,
        # y asi ningun turno legitimo puede quedarse sin cerrar por su culpa
        # —que es el fallo caro: un cierre que no se publica atasca la flota hasta el timeout—.
        # HALLAZGO [3] DE REVISION — CERRADO POR CITA, no por cambio (ronda 29). El revisor pidio cerrar
        # exactamente el hueco que las cinco lineas de arriba YA declaran: que la presencia del RUN no
        # prueba titularidad. No se cierra el LIMITE, se cierra el HALLAZGO — el limite estaba declarado,
        # no disimulado, y quien lo resuelve es el gate-check del lector.
        # COSTE de cerrarlo de verdad, para que la decision sea revisable y no un encogimiento de hombros:
        # obligaria a `publish_close` a correlacionar el flock ENTERO bajo lock, es decir a meter el
        # trabajo del parser en el camino que tiene que ser RAPIDO **porque es el que desatasca la flota**.
        # Un cierre que tarda es un cierre que no llega, y un cierre que no llega atasca a todos hasta el
        # timeout: se pagaria disponibilidad de la cola entera por una comprobacion que el lector ya hace.
        # Es ALCANCE, no bug — y si algun dia se toma, va con su propia medida de latencia, no de oficio.
        # El dato viaja por ARGV, igual que en el append: la guarda no reintroduce lo que cierra [7].
        run_line="# APPLY-RUN [$ESTACION] #$PR $RUN_ISO $RUN_NONCE"
        # EL `rc` SE LEE, NO SE NIEGA EN BLOQUE (ronda 30, MAYOR — hallazgo de revision externa). Un
        # `if !` colapsaba TRES desenlaces distintos en uno: `rc 1` = la linea NO esta (lo que se quiere
        # decir), `rc 2` = `grep` NO PUDO LEER el flock, y el fallo del propio `flock`. El comentario de
        # arriba afirma que «la ausencia SI prueba que no soy el dueno» — **y eso solo es cierto si la
        # lectura tuvo exito**. Con el fichero ilegible, una estacion que SI era la duena leia su propio
        # silencio como una medida, no publicaba su cierre, y el gate se quedaba TOMADO.
        # `rc 1` y `rc 2` no son lo mismo: **VOID no es NEGATIVO**. Se distinguen y se responden distinto.
        # `|| _rc=$?` Y NO `_rc=$?` EN LINEA APARTE (ronda 31, CRITICAL — regresion del arreglo de la
        # ronda 30). Este fichero NO pone `set -e`: **lo pone su LLAMADOR**, la receta de ref 02 §8
        # (`set -euo pipefail`). Ahi un `flock` DESNUDO que devuelve != 0 **mata el shell en esa misma
        # linea**: `_rc=$?` no llega a ejecutarse, toda la clasificacion rc1/rc2/rc66 queda como CODIGO
        # MUERTO justo en los casos para los que existe, y —lo caro— **el aviso de escalada NO se emite:
        # el gate se queda TOMADO EN SILENCIO**. Medido:
        #     bash -c 'false; _rc=$?; echo llegue'          -> imprime «llegue»
        #     bash -c 'set -e; false; _rc=$?; echo llegue'  -> NO imprime nada
        # El `||` convierte la orden en una lista, que es la forma que `errexit` NO mata, y `$?` dentro
        # de la rama derecha sigue siendo el de la izquierda.
        # LA LECCION, que es de contexto y no de linea: **una correccion cuya validez depende de un `set`
        # puesto doscientas lineas mas lejos no esta acreditada por leerla a solas.** El contexto es parte
        # del sujeto — la misma clase que el `pipefail` lejano de PR-B.
        _rc=0
        flock "$FLOCK_FILE" bash -c 'grep -qxF -- "$1" "$2"' _ "$run_line" "$FLOCK_FILE" || _rc=$?
        if [ "$_rc" -ge 2 ]; then
          # NO MEDIBLE: no se sabe si el turno es mio. Fail-closed hacia el lado RUIDOSO — no publicar en
          # silencio, porque el fallo caro aqui es un cierre que no llega y atasca la flota hasta el
          # timeout. Se devuelve un rc PROPIO (2) para que el llamador NO lo confunda con «no es mi turno».
          _msg="✗ publish_close: NO SE PUDO LEER $FLOCK_FILE (rc $_rc) — no se si este turno es mio, asi que NO publico a ciegas NI trato el silencio como prueba. El gate puede quedar TOMADO: ESCALAR AL CEO/ORQUESTADOR YA"
          echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
          echo "$_msg" >&2
          return 2
        fi
        if [ "$_rc" -ne 0 ]; then
          _msg="✗ publish_close: NO publico cierre — mi APPLY-RUN ($run_line) no esta en $FLOCK_FILE: este turno no es mio. Un cierre sin dueno acreditado corrompe el gate de otra estacion. ESCALAR AL CEO/ORQUESTADOR YA"
          # `${LOG:-/dev/null}`: bajo `set -u` un `$LOG` sin definir abortaria AQUI y se perderia el
          # aviso por stderr, que es el unico canal que sobrevive si el log esta roto (misma leccion
          # de la ronda 24, aplicada al caso «invocacion sin wrapper»).
          echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
          echo "$_msg" >&2
          return 1
        fi
        for n in 1 2 3 4 5; do
          # check-then-append ATÓMICO bajo el MISMO flock (idempotente frente a resultado
          # AMBIGUO — ronda 25, BLOQUEANTE — hallazgo de revisión externa): si el intento
          # anterior en realidad SÍ escribió la línea pero `flock`/el subshell fue señalado
          # o devolvió ≠0 DESPUÉS de que el `printf` ya fuera visible (TOCTOU real, no solo
          # teórico — un SIGTERM/OOM puede matar el proceso `flock -c ...` tras el `write()`
          # pero antes de que su código de salida llegue al `&&` de la línea de arriba), el
          # reintento NO debe volver a apendizar: reapendizar produciría un segundo `DONE`/
          # `FAILED` con el MISMO run_id (MISMO nonce), publicado DESPUÉS de que otra estación ya
          # viera el primero como "último cierre" y arrancara su propio `APPLY-RUN` — el gate-check
          # de arriba (paso 1: "último cierre válido") leería ese duplicado tardío como el cierre
          # más reciente del flock ENTERO y declararía libre un gate con un RUN ajeno todavía
          # activo, aunque ese RUN sea posterior en el log al duplicado. El `<nonce>` en la línea
          # es lo que hace este `grep -qxF` CORRECTO y no destructivo (ronda 27): deduplica SOLO
          # cuando la generación es la misma (mismo nonce) — el cierre de OTRA generación (otro
          # nonce) del mismo #PR es una línea distinta y SÍ se apendiza. `grep -qxF` (match de
          # línea COMPLETA, sin interpretar regex) contra el propio `$FLOCK_FILE` bajo el MISMO
          # `flock` que protege el `printf` hace el chequeo y el append una sola operación
          # atómica — ningún otro publicador puede intercalarse entre el grep y el printf.
          # EL DATO NO PUEDE VOLVER A SER CODIGO (ronda 28, BLOQUEANTE — hallazgo de revision
          # externa). La forma anterior era `flock … -c "… \"$line\" …"`: el shell EXTERIOR
          # interpolaba `$line` DENTRO de la cadena que el shell INTERIOR vuelve a evaluar, asi que
          # un `$( )`, un backtick o unas comillas en CUALQUIER campo de la identidad —estacion, PR,
          # sello, nonce, categoria— se ejecutaban con el flock YA TOMADO y con el turno abierto.
          # Aqui `-c` recibe un programa FIJO entre comillas simples (sin una sola expansion) y los
          # datos viajan por ARGV: `$1` es la linea y `$2` el fichero. Sanear los campos no es
          # equivalente: el saneado ENUMERA lo que prohibe y siempre deja fuera algo; pasar por argv
          # RETIRA LA CAPACIDAD de ejecutar, que es lo unico que cierra la clase.
          # `rc 2` DEL `grep` NO ES `rc 1` (ronda 33, REAL — el MISMO fichero ya distingue esto 47 líneas
          # más arriba, y aquí no lo hacía). Antes, `grep -qxF … || printf … >> …`: si `grep` fallaba con
          # `rc>=2` (E/S, señal, OOM) —«NO PUDE VERIFICAR» si la línea ya estaba— el `||` disparaba el
          # `printf` iguales que si `grep` hubiera dicho «no está». Con el fichero aún escribible el
          # `printf` prosperaba, el compuesto devolvía 0 y el `&& return 0` de abajo publicaba «cerrado» —
          # convirtiendo un NO SABER en un ÉXITO. El daño exige las DOS cosas a la vez (si el fallo es de
          # permisos, `printf` también falla, el compuesto da `rc 1` y el bucle escala: ahí no hay daño).
          # Ahora `grep` se lee ANTES de decidir: `rc 0` (ya publicada) es éxito sin reescribir —el `<nonce>`
          # ya dedup a la generación—; `rc>=2` sale por `exit 2` SIN TOCAR el fichero, tratado abajo con la
          # MISMA vara de VOID-no-es-NEGATIVO; solo `rc 1` real dispara el `printf`.
          _rc2=0
          flock "$FLOCK_FILE" bash -c '
            grep -qxF -- "$1" "$2"; g=$?
            [ "$g" -eq 0 ] && exit 0
            [ "$g" -ge 2 ] && exit 2
            printf "%s\n" "$1" >> "$2"
          ' _ "$line" "$FLOCK_FILE" || _rc2=$?
          [ "$_rc2" -eq 0 ] && return 0
          sleep "$n"
        done
        # Los 5 reintentos fallaron (IO del flock roto, no contención — flock ya serializa
        # la contención normal): rc de PROC-M13 SE CONOCE pero no se pudo publicar. Escalar
        # YA, no esperar el timeout de ~30 min pensado para estación MUERTA (ref 01 §2 más
        # abajo) — aquí la estación sigue viva y el dato existe, solo el canal de publicación
        # falló. publish_close() corre DESPUÉS de que la tubería `bash proc-m13.sh | tee
        # "$LOG"` ya cerró (ronda 23, MAYOR — hallazgo de revisión externa: el stderr de esta función NUNCA
        # pasó por ese tee, contra lo que decía la nota anterior) — por eso se escribe
        # DIRECTO a `$LOG` con `>>` aparte de stderr, no se asume capturado por nada previo.
        # `|| true` es OBLIGATORIO en la línea del log (ronda 24, MAYOR — hallazgo de revisión
        # externa, reproducido ejecutando el bloque real con LOG=/dev/full): el wrapper ya
        # reactivó `set -e` antes de llamar a `publish_close` (paso 4 de la secuencia arriba),
        # así que un `$LOG` sin espacio/permiso/desmontado hace que ESA línea aborte la función
        # entera bajo `errexit` — el `2>/dev/null` solo silencia el MENSAJE de error, nunca el
        # código de salida que dispara `set -e` — y el aviso por stderr de la línea siguiente,
        # el único canal que sobrevive si `$LOG` está roto, NUNCA llegaría a ejecutarse.
        _msg="✗ publish_close: 5 intentos de escritura al flock fallaron — RUN #$PR $RUN_ISO $RUN_NONCE ($tok$extra) queda SIN CIERRE, ESCALAR AL CEO/ORQUESTADOR YA (no esperar el timeout de 30 min)"
        echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true   # canal durable — best-effort; el || true evita que un fallo aquí mate el aviso de abajo bajo set -e. El `:-/dev/null` es el MISMO default que 52 líneas más arriba: `LOG` se define DENTRO del bloque de reserva de ref 02 §8.0, así que en un camino que no reserva NO existe, y bajo `set -u` esta línea moriría — en el aviso de que el flock falló, que es justo cuando no puede fallar nada más
        echo "$_msg" >&2                             # canal inmediato — visible en la terminal del operador YA, sobrevive aunque $LOG esté roto
        return 1
      }
      ```

   6. `rm -f "$CLASS_FILE"` — limpieza del wrapper, por la MISMA vía en los DOS desenlaces
      (cierre publicado y cierre agotado) y **ANTES** de propagar el fallo, nunca después. En
      ambos casos su contenido ya está consumido —publicado dentro de la línea de cierre, o
      volcado por `publish_close` a `$LOG` y a stderr dentro del aviso de escalado—, así que
      borrarlo no destruye evidencia. Paralelo al `trap` que ya limpia `$WORKDIR` dentro de
      PROC-M13; este fichero es del wrapper, no de PROC-M13, así que su limpieza es
      responsabilidad del wrapper.
      **Por qué aquí NO se añade un `trap … EXIT`**, aun siendo la forma que cubre toda salida:
      la receta de `ref 02` §8 ya registra UN `trap … EXIT` sobre este mismo fichero, con la
      polaridad `CLAIM_GANADO` que decide si es scratch o evidencia — y **dos `trap … EXIT` no
      se suman: el segundo SUSTITUYE al primero**. Añadir uno aquí desarmaría esa protección
      ajena. La captura del rc del paso 5 cubre esta vía sin tocar la del vecino.
   7. Propagar el desenlace del cierre: con `rc_close` ≠ 0 el turno queda **SIN CIERRE** —
      `publish_close` ya avisó por `$LOG` y por stderr— y el wrapper sale con fallo **después**
      de la limpieza del paso 6, jamás antes.

   **Turno reservado = un cierre en TODA vía de salida — `gh pr merge` y el pull están DENTRO
   de la reserva, no solo PROC-M13 (ronda 25, BLOQUEANTE — hallazgo de revisión externa)**: al
   mover la Adquisición a ANTES del merge (SKILL.md §7), el turno reservado ya no empieza en
   PROC-M13 sino en el instante en que se gana el `APPLY-RUN` (paso 3 de "Adquisición" arriba),
   y abarca `gh pr merge` → `git pull --rebase` (ref 06 §3 paso 0) → lectura del runbook (paso
   1) → PROC-M13. El wrapper `set +e`…`publish_close` de arriba deja de ser "el cierre de
   PROC-M13" para ser el cierre del TURNO ENTERO: la disciplina es UNA sección con EXACTAMENTE
   UN cierre en CADA vía de salida, nunca cero. `gh pr merge` NO se clasifica por
   el rc del cliente (ronda 27, BLOQUEANTE — hallazgo de revisión externa): un rc ≠ 0 NO prueba
   que GitHub no aceptara el merge — la respuesta puede perderse DESPUÉS del efecto remoto, y
   `--delete-branch` añade otra operación post-merge que puede fallar con el merge YA hecho.
   Tratar todo rc ≠ 0 como "no mergeado" y liberar es el agujero: el PR con migración queda
   mergeado en `main`, la reserva liberada, y otra estación adquiere el gate y mergea otra
   migración → `main` por delante de prod, justo la propiedad que la reserva pre-merge existe para
   impedir. Por eso, ANTES de cerrar por un `gh pr merge` fallido, la estación RECONCILIA el
   estado AUTORITATIVO del PR (`gh pr view <PR> --json state,mergedAt,mergeCommit`):
   - **`mergedAt` no nulo / `state=MERGED`** → el merge SÍ ocurrió: CONSERVAR el MISMO turno
     (mismo `<nonce>`), NO publicar cierre, continuar a `git pull --rebase` → runbook → PROC-M13.
     "Cliente con error" ≠ "no mergeado" — es CONTINUACIÓN del turno, no una vía de salida.
   - **confirmado no-mergeado** (`state=OPEN` y `mergedAt` nulo — p. ej. rechazo BEHIND o
     `--match-head-commit` que no casa: GitHub dijo NO explícitamente) → escribir `TRANSITORIO`
     en `CLASS_FILE` y `publish_close "$rc_del_merge"` (emite `APPLY-FAILED … TRANSITORIO`, mismo
     run_id/nonce), liberando el gate; recuperación: `update-branch`, re-ganar el gate (APPLY-RUN
     nuevo, `<nonce>` NUEVO) y reintentar.
   - **INDETERMINADO** (no se puede alcanzar GitHub para confirmar, o la respuesta es ambigua) →
     FAIL-CLOSED: NO liberar la reserva, escalar al CEO/Orquestador. "No sé" NO es "no ocurrió":
     liberar sobre incertidumbre reabre exactamente la ventana `main`-por-delante-de-prod.
   Dejar el gate abierto tras un no-mergeado CONFIRMADO lo orfanaría igual que el `mktemp`/pull ya
   cerrados — el timeout de ~30 min es la red de seguridad para una estación MUERTA, JAMÁS la vía
   normal de un fallo confirmado de una estación viva que conoce su `$rc`; pero un merge
   INDETERMINADO SÍ escala en el acto (fail-closed), no se libera ni se deja colgar al timeout. El pull fallido (TRANSITORIO, ref 06 §3 paso 0) y el blocker que revela el
   runbook (ESCALAR) son las otras dos vías de salida de la MISMA sección con el MISMO
   `publish_close`: tres caras del mismo turno reservado, un solo mecanismo de cierre, no tres
   remiendos.

   **Por qué la clase ya NO se lee de `$LOG` (cierra ronda 20, BLOQUEANTE 2)**: la ronda 19
   clasificaba con un `grep -qE` de prefijos sobre `$LOG` — el log COMPLETO, incluyendo
   cualquier cuerpo HTTP remoto que PROC-M13 interpola en sus propios mensajes de error (Paso
   4, anexo línea ~418: `echo "✗ Paso 4 ($TS): HTTP $code — $body..."`). El auditor ejecutó el
   caso adversarial: un cuerpo forjado `{"detail":"✗ ledger: HTTP forged"}` en una respuesta
   HTTP≠200 de Paso 4 hace que el patrón TRANSITORIO de `fetch_ledger` (`✗ ledger: ... HTTP`)
   caiga dentro del log por pura coincidencia textual — el tercero que controla el cuerpo de
   la respuesta HTTP controla la clasificación, sin que el fallo real (Paso 4, SIEMPRE ESCALAR
   por diseño — es la ÚNICA red que muta) tenga nada que ver. Un `^` no basta (C1: el cuerpo
   remoto puede contener saltos de línea, reproduciendo el mismo prefijo al inicio de una
   línea). La corrección NO ancla mejor el regex: elimina el regex. PROC-M13 (anexo §4) ahora
   declara su propia clase en CADA punto de salida ≠0 escribiendo un **literal fijo** —nunca
   una variable interpolada, nunca `$body`/`$resp`/cualquier dato de origen remoto— al fichero
   que indica `PROC_M13_CLASS_FILE`. `$LOG` sigue existiendo para diagnóstico humano (con el
   cuerpo remoto tal cual, sin censurar), pero el wrapper nunca más lo grepea para decidir; el
   canal de clasificación y el canal de contenido no confiable quedan FÍSICAMENTE separados —
   ver la nota de PROC_M13_CLASS_FILE en anexo §4. Verificado con el selftest ampliado
   (`proc-m13.selftest.sh` T21, 12 asserts): los 9 puntos de salida TRANSITORIO clasifican
   TRANSITORIO, los 10 puntos ESCALAR clasifican ESCALAR, un `CLASS_FILE` ausente/vacío/
   corrupto clasifica ESCALAR (fail-closed), y — T21h, la reproducción literal del hallazgo —
   el MISMO cuerpo forjado que en ronda 20 producía `TRANSITORIO` produce ahora `ESCALAR`: el
   log sigue conteniendo el texto forjado (no se censura, sigue siendo diagnóstico humano
   íntegro), pero la clase ya no puede derivarse de él.

   **Muerte no atrapable del wrapper (SIGKILL, pérdida del host) — ningún trap sobrevive esto,
   ninguna secuencia lo hace**: si la estación muere DURANTE la secuencia, el RUN queda
   huérfano — sin cierre, indistinguible de un apply legítimamente largo hasta que expira el
   timeout de abajo. No es una laguna de ESTE diseño: ningún mecanismo en espacio de usuario
   sobrevive un `SIGKILL` del proceso que lo ejecuta. Por eso existe el timeout de recuperación
   (abajo) — que ahora define explícitamente cómo se cierra un RUN huérfano, no solo que hay
   que investigar.

   **Recuperación tras `APPLY-FAILED` — el motivo importa: no todo fallo exige una migración
   nueva (corregido tras auditoría — ronda 17, BLOQUEANTE; categorías corregidas ronda 18, 2×
   BLOQUEANTE; DEFECTO deja de auto-publicarse ronda 19, MAYOR)**: la ronda 16 colapsó la
   recuperación a un único camino — `APPLY-RECOVERS` más una migración nueva — asumiendo que
   CUALQUIER `APPLY-FAILED` revela un defecto de contenido. Es falso: PROC-M13 (anexo §4) sale
   `≠0` tanto por un defecto REAL en una migración como por un fallo puramente operativo que
   nunca dejó la BD en un estado incorrecto (token ausente, Vault, algunas redes) — exigir una
   migración nueva para arreglar un token vencido no tiene sentido, y bloquearía el slot
   indefinidamente esperando un PR que nadie necesita escribir. El wrapper clasifica leyendo
   `CLASS_FILE` (`classify_log` arriba) — el literal fijo que PROC-M13 ESCRIBE ÉL MISMO en
   cada punto de salida, NUNCA un `grep` sobre el texto libre que imprime — y solo devuelve
   DOS valores posibles: **`<CATEGORIA>` publicada por el wrapper es SIEMPRE `TRANSITORIO` o
   `ESCALAR`, nunca `DEFECTO` automáticamente** (corregido ronda 19, MAYOR — ver por qué
   abajo). PROC-M13 corre con `set -euo pipefail` (anexo línea ~197) — un fallo IMPLÍCITO no
   contemplado por ninguno de los `echo "✗ ..."` del script (`mktemp`, `chmod`, `jq`, `sort`,
   una escritura a disco, una señal) también termina el script SIN pasar por ningún `class`
   explícito, dejando `CLASS_FILE` vacío; `classify_log` ya lo cubre por diseño — CUALQUIER
   contenido de `CLASS_FILE` que no sea EXACTAMENTE el literal `TRANSITORIO` cae en `ESCALAR`,
   nunca en un valor sin clasificar:

   | Categoría publicada | Recuperación | Paso (anexo §4) · mensaje literal (prefijo) |
   |---|---|---|
   | **TRANSITORIO** — una LECTURA de solo-consulta falló; ninguna mutación pudo quedar en vuelo | Corregir la causa y publicar un `APPLY-RUN` NORMAL (mismo `#<PR>`, sin `APPLY-RECOVERS`, sin migración nueva) — cualquier estación, no necesariamente la misma | Paso 0 `SUPABASE_ACCESS_TOKEN ausente` · Paso 0b `hard-gate de Vault falló` · `fetch_ledger` (Paso 2/Paso 5, es un SELECT de solo lectura pese al verbo POST) `curl falló`/`HTTP`/`respuesta no es un array JSON` · Paso 5 `git fetch falló` · Paso 5 advisors `curl falló`/`HTTP`/`fuera del contrato` (ronda 20: ahora `class TRANSITORIO` se declara EN el propio sitio de fallo, así que este último caso —antes solo documentado, nunca implementado, el auditor lo señaló como discrepancia doc/código— ya clasifica correctamente) |
   | **ESCALAR** — todo lo demás: no autodiagnosticable, hubo una MUTACIÓN con estado remoto incierto, o `CLASS_FILE` no contiene el literal `TRANSITORIO` (default fail-closed) | Escalar a CEO/Orquestador ANTES de cualquier acción; si hubo mutación en vuelo, obtener la Señal de quiescencia (abajo) antes de decidir. **El gate queda BLOQUEADO**, no se libera: hace falta un `APPLY-ESCALAR-GO` del CEO/Orquestador que cite ESTE gap antes de que se admita ningún `APPLY-RECOVERS` — ver «Recuperación de un gap ESCALAR» abajo | Paso 2 `DIVERGENCIA, ESCALAR al lead` · Paso 0c `ningún archivo local`/`más de un archivo` (drift) · Paso 1 `tiene control de transacción top-level` / `el lexer... falló` (una migración nueva NO desbloquea una pendiente rota — PROC-M13 vuelve a tropezar con la MISMA; ambigüedad del lexer, TAL-3116) · Paso 4 `curl falló (red)` (ÚNICA red que SÍ muta — Señal de quiescencia obligatoria) · Paso 4 `HTTP`/`respuesta no confirma commit` · Paso 5 `DIVERGEN` · Paso 5 advisors `tiene $nerr ERROR` (ver nota DEFECTO abajo) · cualquier salida sin `class` explícito (fallo implícito) |

   **Recuperación de un gap `ESCALAR` — el gate BLOQUEA hasta GO explícito (ruling del CEO,
   ronda 29)**

   Un `APPLY-FAILED … ESCALAR` deja el gate **tomado**. No lo libera el tiempo, ni la propia
   estación, ni un `APPLY-RUN` nuevo: hace falta un token publicado por el CEO/Orquestador,

       # APPLY-ESCALAR-GO #<PR-fallido> <nonce-fallido> [<CEO|Orquestador>] <ISO8601>

   que cite el gap EXACTO por `#<PR>`+`<nonce>`, y **solo entonces** se admite el
   `APPLY-RECOVERS` que lo recupera.

   **Esto NO es «bloquear siempre», y escribirlo mal atascaría la flota**: `TRANSITORIO` sigue
   recuperándose sin autorización externa —cualquier estación publica un `APPLY-RUN` del MISMO
   gap y lo retoma—, y un `APPLY-RUN` **VOID** (el perdedor de una adquisición) no bloquea nada:
   muere la identidad, no el gate. Lo que bloquea es **exclusivamente** `ESCALAR`, que es el caso
   en el que hubo una mutación con estado remoto incierto.

   **Qué agujero cierra, dicho con precisión**: el contrato anterior exigía que el
   `APPLY-RECOVERS` llevara la estación DEL GAP (`$7 == gest`) — es decir, **la misma estación
   cuyo apply dejó el estado remoto incierto se autorizaba a sí misma a reintentar**. La prosa ya
   mandaba escalar al CEO/Orquestador, pero el contrato ejecutable no pedía ninguna acreditación,
   y **el ejecutable es el que se opera**. Una autorización que se concede el propio interesado
   no es una autorización.

   **TRANSFERENCIA — el GO puede cambiar de dueño la recuperación (ruling ronda 30)**. El sufijo
   opcional `-> <estación>` del `APPLY-ESCALAR-GO` hace que la recuperación la ejecute **otra**
   estación:

   - **sin sufijo** → `APPLY-RECOVERS` se acepta **solo de la estación original** (la del gap);
   - **con sufijo** → **solo de la nombrada**, y **deja de aceptarse de la original**. *Una
     recuperación tiene un dueño, nunca dos* — admitir a las dos reabriría, con otro nombre, la
     carrera que todo este gate cierra;
   - **sufijo malformado o a medias** → el token **no autoriza a nadie**: se rechaza entero. Un
     sufijo que no nombra una estación real (`RE_EST` es M1-M5) no es «un GO normal con basura
     detrás», es un GO que no se entiende, y lo que no se entiende no autoriza.

   **PRECONDICIÓN, que es doctrina y no código**: el CEO/Orquestador **solo transfiere después de
   MEDIR que la estación original no vuelve** — sella esa medida y **la publica en el mismo GO**.
   Transferir «por si acaso» convertiría la autorización en un trámite, que es exactamente lo que
   este token existe para no ser.

   **EL COSTE, que va escrito y no en una nota al pie**: una estación que **muera después de
   publicar `ESCALAR`** deja el gate **TOMADO hasta que un humano MIDA y decida** — recuperarlo con
   la misma estación, o transferirlo con el sufijo. No hay recuperación automática por diseño: eso
   es lo que se compra a cambio de no permitir que un estado remoto incierto se reintente sin que
   nadie lo mire. La transferencia **abarata ese coste pero no lo elimina** —sigue exigiendo una
   persona que mida—, y por eso la guardia se planifica igual. *Una doctrina que solo cuenta su
   beneficio no es una doctrina: es una recomendación.*

   **Por qué DEFECTO CONFIRMADO ya no es un valor que el wrapper publique (cierra ronda 19,
   MAYOR)**: la ronda 18 asumía que "advisors tiene N ERROR" identifica sin ambigüedad un
   defecto del PR recién aplicado. Falso — PROC-M13 (anexo línea ~483) cuenta TODOS los
   `ERROR` que devuelve el advisor en ESE momento, sin filtrar por objeto tocado: un `ERROR`
   preexistente o de otro dominio dispararía la misma línea y atribuiría `APPLY-RECOVERS` al
   PR equivocado. Por eso `advisors ... tiene $nerr ERROR` publica **ESCALAR**, igual que
   cualquier otro caso ambiguo — DEFECTO CONFIRMADO se alcanza SOLO durante esa investigación,
   nunca en el cierre automático: quien investiga (CEO/Orquestador, o una estación delegada)
   reconsulta el advisor directamente (`GET /v1/projects/<ref>/advisors/security` y
   `/advisors/performance`, el mismo endpoint que Paso 5).

   **Campo exacto y validación de existencia (cierra ronda 20, MAYOR: la ronda 19 decía
   "extrae el `name`/objeto" sin fijar qué campo, sin validar que exista, y remitía a "una
   búsqueda textual sobre el `.sql`" que el auditor rechazó explícitamente como insuficiente)**:
   el identificador NUNCA es `.name` de primer nivel del lint (ese campo nombra el TIPO de
   regla infringida — `rls_disabled`, `function_search_path_mutable`— no el objeto). El
   identificador del objeto flageado es la terna **`.metadata.schema` + `.metadata.name` +
   `.metadata.type`**, normalizada como `schema.name [type]` en minúsculas. La API de
   Supabase documenta estos tres campos dentro de `.metadata`
   (<https://supabase.com/docs/reference/api/v1-get-security-advisors>), pero el endpoint
   está marcado experimental/deprecado — su forma puede cambiar sin aviso — así que la
   ausencia de CUALQUIERA de los tres es **fail-closed**: ese hallazgo NO puede usarse para
   confirmar DEFECTO (queda como ESCALAR ordinario, nunca se asume la relación). Comando para
   extraer los candidatos, fallando cerrado ante metadata incompleta:
   `curl ... "$API/advisors/$kind" | jq -r '.lints[] | select(.level=="ERROR") | if (.metadata? and .metadata.schema? and .metadata.name? and .metadata.type?) then "\(.metadata.schema).\(.metadata.name) [\(.metadata.type)]" else "METADATA-INCOMPLETA — no confirmable, tratar como ESCALAR" end'`.
   **Lo que sigue siendo un paso HUMANO, deliberadamente (el auditor: "una búsqueda textual
   sobre el SQL no sería suficiente" — un regex sobre `CREATE`/`ALTER` se rompe con
   identificadores citados, DO blocks dinámicos y objetos creados indirectamente)**: quien
   investiga LEE el `.sql` de la migración recién aplicada y confirma a ojo que existe un
   objeto con la MISMA terna `schema.name [type]` (normalizada igual: minúsculas, sin
   comillas). SOLO si al menos un candidato de la lista de arriba coincide EXACTO con un
   objeto que el investigador confirma leyendo el `.sql`, la investigación concluye DEFECTO
   CONFIRMADO y procede con `APPLY-RECOVERS` (protocolo abajo, con una condición extra para
   este caso). Si ningún candidato tiene metadata completa, si ninguno coincide, o si la
   lectura humana no puede confirmar la relación, sigue como ESCALAR ordinario — nunca se
   asume que el `ERROR` pertenece al PR que acaba de aplicar.

   **Señal de quiescencia — del lado que realmente decide, no del reloj del cliente (corregido
   tras auditoría — ronda 19, BLOQUEANTE: la ronda 18 usaba DOS lecturas del ledger separadas
   por el `--max-time` del CLIENTE como prueba de estabilidad, pero el propio contrato ya
   reconoce que ese timeout no cancela ni acota la transacción del lado del SERVIDOR — un
   POST que sigue commitéandose en el servidor tras dos lecturas iguales del cliente sigue
   siendo un interleaving posible; estrechar la ventana no arregla esto, hace falta preguntar
   al servidor, no al reloj. **Cerrado de nuevo ronda 20, BLOQUEANTE**: la propia consulta a
   `pg_locks` de la ronda 19 miraba la tabla equivocada DEMASIADO PRONTO — ver por qué abajo)
   **: antes de fiarse de una lectura del ledger tras un fallo de red en el POST de Paso 4, o
   tras confirmar la muerte de una estación, se consulta DIRECTAMENTE si el servidor tiene una
   transacción viva sobre el recurso que importa — el ledger — reusando el MISMO endpoint
   `database/query` que ya usa `fetch_ledger` (anexo §4):

   ```sql
   select count(*) from pg_locks l
     join pg_class c on l.relation = c.oid
     join pg_namespace n on c.relnamespace = n.oid
   where n.nspname = 'supabase_migrations' and c.relname = 'schema_migrations'
     and l.mode ilike '%exclusive%';
   ```

   **Por qué esta consulta necesitaba un SEGUNDO fix (ronda 20, BLOQUEANTE): el lock debe
   adquirirse AL PRINCIPIO de la transacción, no dejar que aparezca solo**. La ronda 19 razonaba
   "el `insert` al ledger vive en el MISMO `begin;…commit;` que el DDL, así que mientras la
   transacción siga abierta retiene un lock sobre el ledger" — cierto en el desenlace, FALSO en
   el tránsito: PROC-M13 (anexo §4, Paso 3) construye el payload como `begin;` → **todo el DDL
   de la migración** → `insert into schema_migrations` → `commit;` — el INSERT es el ÚLTIMO
   statement antes del commit, así que mientras el DDL (potencialmente largo) sigue corriendo,
   la transacción AÚN no ha tocado `schema_migrations` y no sostiene ningún lock sobre ella.
   Conteo `0` en ese instante NO significa "sin mutación viva": significa "la mutación viva
   todavía no llegó a la tabla que esta consulta observa" — el CEO podría leer `0`, cerrar el
   RUN y autorizar un retry con el POST original TODAVÍA corriendo en el servidor → el mismo
   doble-apply que esta señal existe para impedir. **Fix**: PROC-M13 ahora adquiere el lock
   EXPLÍCITAMENTE, `lock table supabase_migrations.schema_migrations in exclusive mode;`,
   INMEDIATAMENTE después de `begin;` — ANTES del DDL de la migración (anexo §4, Paso 3;
   `ExclusiveLock` cae dentro del mismo `ilike '%exclusive%'` de la consulta de arriba, ningún
   cambio de query hace falta). El lock se sostiene desde ese instante hasta el `commit`/
   `rollback`, cubriendo TODA la ventana de mutación — no solo su último instante — porque un
   lock de tabla en Postgres se retiene desde su adquisición hasta el fin de la transacción,
   sea cual sea el statement que la transacción esté ejecutando en ese momento. **Verificado
   empíricamente contra Postgres real** (contenedor local `supabase_db`, nunca prod): con el
   diseño viejo (DDL sin lock previo, simulado con `pg_sleep`), la consulta de arriba lee `0`
   MIENTRAS la transacción sigue abierta — reproduce el hallazgo. Con el lock explícito
   añadido tras `begin;`, la MISMA consulta lee `>0` (BUSY) durante la misma ventana, y solo
   vuelve a `0` tras el `commit`/cierre de sesión — la mutación criterio exacto que pidió C1:
   "que la prueba falle si el DDL sigue vivo". Regresión estructural cubierta también por
   `proc-m13.selftest.sh` T20 (el payload emitido por PROC-M13 contiene el lock EN ORDEN
   `begin < lock < DDL`).

   Cada transacción de Paso 3 hace `begin; lock table ... in exclusive mode; <revalidación>;
   DDL; insert al ledger; commit;` (ref 06 §3 paso 2) — desde el `lock table` explícito hasta
   el `commit`/`rollback`, retiene un lock exclusivo sobre
   `supabase_migrations.schema_migrations` durante TODA la transacción, DDL incluido. Conteo
   `0` → NINGUNA transacción tiene lock exclusivo sobre el ledger AHORA MISMO — pero eso NO
   demuestra que ninguna esté a punto de pedirlo (ver el porqué exacto abajo); conteo `> 0` →
   hay una transacción viva de verdad (DDL en curso o `insert`/`commit` pendiente): NO se lee
   el ledger como definitivo, se reintenta la consulta de locks cada pocos segundos hasta que
   el conteo llegue a `0`. Si el lock persiste más allá del mismo umbral de 30 minutos del
   timeout de abajo, se trata igual — investigar, nunca forzar un cierre sobre un lock que
   sigue vivo.

   **Por qué "conteo 0" NO basta por sí solo, y qué lo cierra de verdad (ronda 21,
   BLOQUEANTE)**: la ronda 20 afirmaba "conteo 0 → cualquier POST anterior YA se resolvió,
   sin importar qué vio o dejó de ver el cliente" — el auditor confirmó que esa frase sigue
   siendo demasiado fuerte. `pg_locks` solo muestra locks YA SOLICITADOS. Un POST que el
   servidor ACEPTÓ pero que todavía no empezó a ejecutar SQL —o que está entre `begin;` y su
   propio `lock table` por planificación del backend— **no aparece en `pg_locks` todavía**:

   ```text
   POST antiguo:   BEGIN ──── pausa/cola ──────── LOCK ── DDL
   reconciliador:             pg_locks=0 → cierra RUN
   retry:                                     nuevo APPLY-RUN
   ```

   Ninguna sonda EXTERNA puede demostrar una ausencia futura por observación — ni con dos
   lecturas separadas por tiempo (ronda 19), ni con `pg_locks` en un único instante (ronda
   20): ambas miran lo que YA pasó, nunca lo que un peticionario TODAVÍA no ha pedido. El
   cierre no es observar mejor: es hacer que el duplicado se aborte SOLO. Por eso, inmediatamente
   después de adquirir el lock y ANTES del DDL (anexo §4, Paso 3), el payload se revalida
   DENTRO DE LA MISMA TRANSACCIÓN — `do $$ begin if exists (select 1 from
   supabase_migrations.schema_migrations where version = '<TS>') then raise exception ...;
   end if; end $$;` — contra el propio ledger. Postgres serializa el ACCESO al lock: si el
   POST antiguo (retrasado) y un retry nuevo compiten por él, el segundo en obtenerlo espera a
   que el primero haga `commit`/`rollback`. Cuando por fin lo obtiene, este guard comprueba si
   la versión YA quedó aplicada por quien llegó primero — si sí, `raise exception` aborta esa
   transacción ENTERA sin tocar el DDL, sin duplicar nada; si no, continúa normal. Deja de
   importar quién llegó primero al lock: el segundo se cae solo. Verificado empíricamente
   contra Postgres real (contenedor local `supabase_db`, nunca prod): con una versión YA
   presente en el ledger, la transacción aborta ANTES de crear ningún objeto del DDL y el
   conteo de filas para esa versión se queda en 1 (nunca 2); con una versión NUEVA, el guard
   pasa de largo y el DDL+insert+commit corren normal. Cubierto estructuralmente por
   `proc-m13.selftest.sh` T22 (el payload real contiene el guard, en orden `lock < guard <
   DDL`, referenciando la versión exacta del gap).

   **`APPLY-RECOVERS` — identidad verificada, no una coincidencia de fecha (corregido tras
   auditoría — ronda 15, BLOQUEANTE; formato corregido ronda 16, BLOQUEANTE; comandos
   corregidos ronda 17 y 18, MAYOR)**: un **DÉCIMO token**, fijo y separado, publicado ANTES
   del `APPLY-RUN` (que recupera su formato original, sin sufijos): `# APPLY-RECOVERS
   #<PR-fallido> <nonce-fallido> #<PR-nuevo> <nonce-nuevo> [<estación>]` (tabla arriba; ronda 27:
   el `<nonce>` sustituye al `<ISO8601-fallido>` como identidad única del RUN que se recupera). Antes de
   publicarlo, la estación verifica IDENTIDAD CONCRETA:
   1. Obtiene el SHA de merge REAL del PR fallido — el NÚMERO SIN `#` como argumento de shell
      (`#` abre un comentario, `gh` solo recibiría `pr view`; probado):
      `gh pr view <PR-fallido> --json mergeCommit --jq .mergeCommit.oid`.
      **No hay alternativa vía el token `MERGED` del flock** (corregido — su formato,
      `# ✅ M<N> MERGED #<PR>` arriba, NO lleva SHA; citarlo como fuente era un error de la
      ronda 16).
   2. Confirma que el PR nuevo DESCIENDE de ese commit:
      `git merge-base --is-ancestor <sha-fallido> <head-del-PR-nuevo>`.
   3. Confirma que el diff del PR nuevo AÑADE (no solo toca) al menos un fichero en
      `supabase/migrations/` — de nuevo el número SIN `#`, y por `status`, no por presencia en
      la lista de ficheros (`gh pr view --json files` no expone `status`; modificar o borrar
      una migración histórica también aparecería en `.files[].path`, corregido). El endpoint
      REST es PAGINADO — sin `--paginate` una migración en una página posterior a la primera
      queda invisible (corregido ronda 18, MAYOR); y cero coincidencias deja `rc=0` igual —
      "debe imprimir una línea" no bastaba como prosa, ahora es un check que aborta:
      `files="$(gh api --paginate repos/<owner>/<repo>/pulls/<PR-nuevo>/files --jq '.[] | select(.status == "added" and (.filename | startswith("supabase/migrations/"))) | .filename')"; [ -n "$files" ] || exit 1`.
   4. Su propio HANDOFF declara explícitamente que esa migración corrige el fallo de
      `#<PR-fallido>`.
   5. **SOLO si la recuperación viene de un ERROR de advisors** (ronda 19, cierra la nota
      DEFECTO de arriba; campo y validación de existencia fijados ronda 20, MAYOR): además
      confirma que la terna `.metadata.schema` + `.metadata.name` + `.metadata.type` del
      advisor (las TRES presentes, fail-closed si falta alguna) coincide EXACTA, normalizada
      en minúsculas, con un objeto que el investigador confirma leyendo el `.sql` de la
      migración fallida — la investigación descrita en la nota DEFECTO de arriba, repetida
      aquí como condición explícita del gate. La lectura del `.sql` es un paso HUMANO
      deliberado, no un regex automatizado (ver nota DEFECTO — el auditor rechazó
      explícitamente una búsqueda textual como gate suficiente).
      Un `git log --since=<timestamp>` (lo que usaba la ronda 15) NO basta — el timestamp del
      `APPLY-FAILED` es el de INICIO del run, no el del fallo, y cualquier migración AJENA que
      aterrizara durante la corrida pasaría el filtro sin ser el fix real. Sin las condiciones
      aplicables, NO se publica `APPLY-RECOVERS` ni `APPLY-RUN`: se escala al CEO/Orquestador.
      El `APPLY-RUN` que sigue debe tener el MISMO `#<PR-nuevo>` que el `APPLY-RECOVERS` recién
      publicado **y su `RUN_NONCE` DEBE ser EXACTAMENTE el `<nonce-nuevo>` citado** (ronda 29,
      BLOQUEANTE — hallazgo de revisión externa: transportar el nonce NO es vincularlo; sin esta
      igualdad, dos generaciones del mismo `#<PR-nuevo>` quedan indistinguibles y una autorización
      de recuperación puede reutilizarse o atribuirse a la generación EQUIVOCADA, una transición
      que ejecuta migraciones en PROD); y el `<nonce-fallido>` citado DEBE ser EXACTAMENTE el nonce
      del `APPLY-FAILED` recuperado (no basta el `#<PR-fallido>`). El enlace exige AMBAS igualdades
      de nonce, nunca solo la coincidencia de PR. La verificación de SUSTANCIA (¿es realmente el
      fix?) la hacen los gates AND ya existentes de esta estación (ref 02 §7), igual que con
      cualquier otro PR; este gate solo exige la identidad correlacionada por nonce, no reinventa
      el code-audit.

      **Cómo se ACREDITA hoy este enlace, y hasta dónde llega esa acreditación (ronda 30,
      BLOQUEANTE — hallazgo de revisión externa; acta r29-p1 sha256
      `5ba35aecc0e6f052b195ca8cd6abb777ae32982642f8d1543f51eac8987c0ab3`)**: la comprobación de
      las dos igualdades es **HUMANA**, como las condiciones 1-5 de arriba — la estación las
      verifica al publicar, no hay gate ejecutable que las imponga. Lo protege el ratchet, y el
      ratchet tiene un alcance **declarado y menor** que un test: un invariante `MUST` acredita
      que las palabras «DEBE ser EXACTAMENTE» están PRESENTES, no que la oración las AFIRME — un
      mutante que antepone una negación conservando el literal pasaba el validador en verde
      (920/0, rc=0). Contra esa clase concreta hay guardas negativas (`INV-ME-198/202/203`,
      medidas cazando ese mutante), y cubren solo las formulaciones **ACCIDENTALES** conocidas de
      negación/opcionalidad, **no la clase completa**: siempre hay otra forma de negar en prosa.
      Quien acredite este enlace se apoya, por tanto, en un **residuo acotado y declarado**, no en
      una propiedad probada por ejecución. Un gate ejecutable que la impusiera es trabajo
      SEPARADO y NO ENTREGADO aquí — issue de seguimiento TAL-5307 (ver «Límite conocido» abajo).

      **Límite conocido: ciclo de vida de `APPLY-RECOVERS`** (TAL-5296 · acta de revisión
      externa r29-p1, sha256
      `5ba35aecc0e6f052b195ca8cd6abb777ae32982642f8d1543f51eac8987c0ab3`). **Esta sección se
      RETIRA en el mismo cambio que cierre TAL-5296**: mientras el hueco exista es la
      declaración honesta; después sería falsa.

      Lo de arriba ata la GENERACIÓN — el `APPLY-RUN` que recupera es el autorizado y no otro
      del mismo `#<PR>`. Lo que **NO** promete es UNICIDAD. El token transporta `[<estación>]`,
      pero las condiciones del contrato solo comparan PR y nonce, y por tanto el contrato NO
      define: (a) **RESUELTO — CADUCADO por la ronda 30 (CR sobre v18)**: esta lista se escribió
      antes de esa ronda, y la pregunta «¿de qué estación debe ser el `APPLY-RUN` que recupera, y
      qué sería una transferencia válida?» la responde «TRANSFERENCIA» más arriba (sin sufijo →
      solo la original; con sufijo → solo la nombrada) y la impone `ref 02` (`go_dest`, líneas
      ~770-778). Se conserva el hueco de numeración para no renumerar (b)/(c), que siguen
      abiertos; (b) qué ocurre si DOS tokens distintos citan el
      mismo `<nonce-fallido>` autorizando `#<PR-nuevo>`/`<nonce-nuevo>` DIFERENTES —ambos
      satisfacen las dos igualdades y el texto no dice cuál es canónico ni cuál queda VOID—;
      (c) cuándo una autorización se considera CONSUMIDA. El mutex evita la SIMULTANEIDAD, no la
      AMBIGÜEDAD DURABLE. Diseñar el ciclo de vida de una autorización que gobierna migraciones
      en PROD es decisión del lead, no de una estación: **no lo resuelva nadie por su cuenta**.

      **Mientras TAL-5296 siga abierta, el default es ESCALAR ante lo que (b) y (c) dejan sin
      decidir** — más de un `APPLY-RECOVERS` citando el mismo `<nonce-fallido>`, o duda sobre si
      una autorización ya se consumió: ahí la estación **NO ejecuta**, escala al CEO/Orquestador.
      Es el fail-closed ya vigente para todo estado no decidido, no una regla de ciclo de vida
      nueva. **«Autorización de otra estación» YA NO es una de estas caras** (era la (a),
      RESUELTA arriba): tras la ronda 30 esa pregunta tiene respuesta —«TRANSFERENCIA»
      determina de quién es—, así que ver una autorización ajena no es ambigüedad que escalar,
      es un CEDE decidido: la estación que no es la titular (original o transferida) simplemente
      no ejecuta, sin molestar al CEO/Orquestador por un caso que el contrato ya resuelve.

      El lead propuso una regla provisional para acotar el hueco —*un `APPLY-RECOVERS` solo lo
      consume la estación que lo publicó y una sola vez; un segundo publicador del mismo
      `<nonce-fallido>` es BOUNCE*—. **NO está implementada ni en vigor en esta entrega**: se
      escribió con su ratchet y sus tests y se retiró junto con el gate ejecutable, porque la
      auditoría de verificación encontró defectos en ese bloque. Se decide y se implementa en
      TAL-5296. Hasta entonces rige el párrafo anterior: escalar.

   **Timeout de recuperación — investigar, no forzar; y cómo se cierra un RUN huérfano
   (reforzado ronda 14, MAYOR; cierre del huérfano añadido ronda 17, BLOQUEANTE; TOCTOU
   corregido con Señal de quiescencia ronda 19, BLOQUEANTE)**: un RUN activo sin cierre (con su
   run_id exacto) durante más de 30 minutos (el límite documentado por POST es ~2 min, pero un
   gap con muchas migraciones pendientes no tiene cota máxima documentada — 30 min da margen a
   un gap legítimamente largo sin disparar en falso) se trata como posible estación caída — NO
   se ignora en silencio y NO se fuerza un arranque nuevo automáticamente: se escala al
   CEO/Orquestador, que verifica el estado real (p. ej. actividad reciente en el proyecto
   Supabase) ANTES de decidir. El umbral es una señal para investigar, no una autorización
   automática de override — forzar un segundo `APPLY-RUN` sin confirmar que el primero murió
   reintroduce la misma carrera que este gate existe para cerrar.

   Confirmada la muerte, el CEO/Orquestador (nunca una estación por su cuenta) obtiene la
   Señal de quiescencia (arriba, la consulta a `pg_locks`) ANTES de publicar cualquier cierre
   — que la estación esté muerta NO prueba que la transacción del último POST en vuelo haya
   terminado del lado del servidor. Con el lock en `0`: si el gap quedó COMPLETO y ambos
   advisors en 0 ERROR, publica `# APPLY-DONE [<estación-original>] #<PR> <ISO8601> <nonce>` citando el
   run_id EXACTO del RUN huérfano (mismo `#<PR>`, timestamp y `<nonce>`, no uno nuevo) — el apply en
   realidad terminó bien, solo la estación murió antes de reportarlo. Si NO quedó completo,
   publica `# APPLY-FAILED [<estación-original>] #<PR> <ISO8601> <nonce> ESCALAR` con el mismo run_id/nonce
   — categoría ESCALAR SIEMPRE en este camino (nunca TRANSITORIO: sin el `CLASS_FILE` de la
   estación muerta —murió con el proceso, no hay literal que leer— no hay nada que
   clasificar). Si el lock sigue en `> 0`, NO se publica
   ningún cierre todavía — esperar y repetir la consulta. Ningún token nuevo hace falta —
   `APPLY-DONE`/`APPLY-FAILED` ya existen, esto es solo quién los publica y con qué evidencia
   cuando la estación titular no puede.
5. Además del gate de ejecución, una migración que declara dependencia de OTRA del mismo gap
   (`CREATE OR REPLACE` que folia sobre el cuerpo post-apply de un slot anterior, ref 06 §2
   punto 5) verifica CONTRA EL LEDGER — no contra el `MERGED` de la otra PR — que la migración
   de la que depende ya está aplicada antes de foliar sobre su cuerpo: `MERGED` certifica que
   el PR se mergeó, no que PROC-M13/M15 terminó; el ledger es la única fuente que certifica un
   apply completo (ref 06 §1). El gate de `APPLY-RUN` ya impide la carrera de EJECUCIÓN; esta
   verificación adicional cubre la carrera de CONTENIDO (foliar sobre un cuerpo que aún no es
   el vigente) para el caso especialmente sensible de `CREATE OR REPLACE`.
6. El apply a prod es post-merge, por la MISMA estación que mergeó, con advisors, una vez
   adquirido el gate de `APPLY-RUN` — el ledger de prod sigue siendo la verdad (ref 06 §1).
   **Quien mergea, aplica**: no se delega el apply a otra estación ni se difiere para después
   — esto sobrevive intacto de los siete intentos anteriores.
7. Las destructivas siguen exigiendo GO del lead SIEMPRE (ref 06 §4) — CLAUDE.md regla 24 no
   se toca ni se amplía por este cambio.

**Ciclo de vida del `SLOT-CLAIM` (corregido tras auditoría — ronda 12, MAYOR; completado ronda
13, MAYOR; procesado de verdad por `titular_vigente()` desde ronda 35 — antes solo estaba
declarado en esta prosa, el automata no lo ejecutaba, ver "(a) Ejecutable" arriba y
`TM_RE_TERMINAL` en `apply-gate.sh`)**: un claim está VIVO — bloquea a otras estaciones de reutilizar el MISMO número de
slot — desde su publicación hasta que aparece, para ese PR, `MERGED`, `BOUNCED` **o `CEO
RESUELTO`** (los TRES son terminales, igual que ya lo son para `CLAIM` — §"Drain-disjoint"
arriba). Tras `MERGED`, el número de slot queda fijado en los ficheros de migración que ahora
viven en `main`: cualquier estación que recalcule el tope real (ledger ∪ `main` ∪ PRs abiertos)
lo verá ahí directamente, con o sin el claim — el claim ya cumplió su función (cerrar la
ventana entre «calculé el tope» y «hice push del renumber»), no hace falta un token de
liberación aparte. Tras `BOUNCED`/`CEO RESUELTO`, el claim se retira igual que un `CLAIM`
ordinario (mismo mecanismo de arriba) — el slot vuelve a estar libre. **PR cerrado/abandonado
SIN publicar ninguno de los tres** (push falló y la estación desapareció, o el PR se cerró a
mano fuera del flujo del bus): antes de tratar un `SLOT-CLAIM` como vivo indefinidamente, la
estación que lo encuentra corre `gh pr view <PR> --json state,mergedAt` (corregido tras
auditoría — ronda 14, MAYOR: `merged` NO es un campo válido de `gh pr view --json`, el campo
real es `mergedAt`) — si `state=CLOSED` y `mergedAt` es `null` sin token terminal en el flock,
el claim se trata como retirado (equivalente a `BOUNCED`, el PR ya no existe como abierto y no
hay quien publique el token) — nunca se asume vivo solo porque el flock no tiene un terminal
explícito.

**PR sigue ABIERTO pero la estación murió a mitad de camino (TAL-5170, hallazgo de revisión externa MAYOR —
ACEPTADO)**: el caso de arriba cubre `state=CLOSED`; no cubre una estación que reclamó el
slot, publicó `SLOT-CLAIM` y murió (SIGKILL, host caído) ANTES de mergear o cerrar el PR — ahí
`gh pr view` devuelve `state=OPEN`, `mergedAt=null`, y por la regla de arriba el claim se
trataría como vivo INDEFINIDAMENTE, bloqueando ese número de slot sin que nadie lo libere.
Mismo patrón de liveness que `APPLY-RUN` ya usa (arriba, punto 4: ~30 min sin cierre →
escalar al CEO/Orquestador para la Señal de quiescencia real), aplicado aquí: un
`SLOT-CLAIM` sin terminal, con el PR todavía `OPEN`, y sin actividad nueva en el PR
(`updatedAt` — ni commits ni comentarios) durante ~30 min, se escala al CEO/Orquestador —
NUNCA lo retira una estación sola por su cuenta. El CEO/Orquestador confirma que la estación
reclamante está realmente muerta (no solo lenta) y publica el **undécimo token**,
`# SLOT-CLAIM-TAKEOVER <slot> = #<PR> [<estación-nueva>] <ISO8601> <nonce-nuevo> (supersede <estación-anterior> <nonce-anterior>)`
(fijo y separado — NUNCA un sufijo sobre el `SLOT-CLAIM` original: repetir esa forma sería el
mismo error de formato que la ronda 16 ya corrigió sobre `APPLY-RUN`, "contrato de tokens
EXACTOS, sin variantes"). `<estación-anterior>` es OBLIGATORIA (ronda 24, MAYOR — hallazgo de
revisión externa: cita explícitamente a la titular que este takeover reemplaza, mismo patrón
que `APPLY-RECOVERS` cita el `APPLY-FAILED` que recupera — sin esa cita, el token es
inválido/mal formado); el `<nonce-anterior>` es OBLIGATORIO (ronda 27, BLOQUEANTE — sustituye al
`<ISO8601-anterior>` de la ronda 25, que dos tenencias podían repetir en el mismo tick; ver
"Semilla y generación del takeover" abajo). Cualquier
estación trata entonces ese slot — Y el `CLAIM #<PR>` vigente de ese mismo PR, ver abajo — como
reclamados por `<estación-nueva>` — nunca reclamando el mismo slot con un `SLOT-CLAIM` normal
por encima (rompería first-claim-wins: dos claims "normales" para el mismo slot son
indistinguibles de una colisión real). Mientras no llegue el `SLOT-CLAIM-TAKEOVER`, el slot
sigue bloqueado — igual que `APPLY-RUN`, preferir un slot bloqueado de más a una doble
numeración.

**Semilla del takeover — de dónde sale la PRIMERA generación de la cadena (ronda 25,
BLOQUEANTE — hallazgo de revisión externa; ronda 27 fija su identidad al `<nonce>`)**: el propio
`SLOT-CLAIM` original ya lleva `[<estación>]` y su `<nonce>` (arriba — antes el token no llevaba
ni estación ni nonce, y un lector no podía obtener del `SLOT-CLAIM` con qué generación arrancar
la cadena sin inferirlo del `CLAIM #<PR>` por una regla no escrita).
De dónde arranca la cadena lo resuelve **`titular_vigente()`** (ver "Autoridad del takeover"
abajo); este párrafo explica POR QUÉ el token lleva estación y nonce, no CÓMO se recorre.

**Generación — el problema ABA, M1→M2→M1 (ronda 25, BLOQUEANTE — hallazgo de revisión
externa)**: nombrar solo la ESTACIÓN en `<estación-anterior>` no basta cuando la MISMA estación
puede ocupar el slot dos veces en momentos distintos (M1 titular original muere → M2 la sucede
→ M2 muere → un `SLOT-CLAIM-TAKEOVER` tardío/forjado que cita "M1" como `<estación-anterior>`
sería ambiguo: ¿autoriza contra la PRIMERA tenencia de M1 (ya superada, stale) o exige una
NUEVA tenencia de M1 que nunca ocurrió?). Por eso `<estación-anterior>` NUNCA va sola: cada
eslabón de la cadena — el `SLOT-CLAIM` original y cada `SLOT-CLAIM-TAKEOVER` — lleva su propio
`<nonce>` (UUID único por intento), y `<estación-anterior>` en un `SLOT-CLAIM-TAKEOVER` DEBE ir
acompañada de `<nonce-anterior>`: el `<nonce>` EXACTO del token (SLOT-CLAIM o TAKEOVER
previo) que se sucede. El `<nonce-anterior>` es la identidad de
GENERACIÓN inmutable y ÚNICA de ese eslabón — nunca el nombre de estación solo, y nunca un
`<ISO8601>` que dos tenencias pueden repetir en el mismo tick o tras un ajuste del reloj hacia
atrás (ronda 27, BLOQUEANTE: esa repetición era justo la colisión que reabría el ABA). Un
takeover que cita `(M1, <nonce-de-la-primera-tenencia>)` cuando la cadena real ya avanzó a otra
generación cita una generación SUPERADA y es inválido igual que citar una estación que ya no es
la vigente (mismo tratamiento que el párrafo de abajo ya da a una cita stale) — sin importar que
el NOMBRE "M1" vuelva a aparecer más adelante en la cadena tras un tercer takeover legítimo,
porque su `<nonce>` será OTRO.

**Autoridad del takeover — la regla vive en el CÓDIGO (ronda 23 cerró la colisión simultánea;
ronda 24, MAYOR — hallazgo de revisión externa, cerró la sucesión múltiple; ronda 25 añadió
semilla + generación; T05 v7 la hizo EJECUTABLE; T05 v9 fija la FORMA de esta sección)**:

- **(a) Ejecutable**: **`titular_vigente()`**, en `references/apply-gate.sh`. Sus casos: **T25**,
  **T29** (filtro por slot, ronda 34), **T30** (forma de línea unificada con la escritura vía
  `identidad_slot_valida`/`identidad_takeover_valida`, ronda 35), **T31** (los TRES terminales
  del "Ciclo de vida del `SLOT-CLAIM`" de más abajo se procesan de verdad, no solo se declaran —
  CLASE 2, ronda 35: antes de T31 el automata solo conocía `SLOT-CLAIM`/`-TAKEOVER` y un
  `MERGED`/`BOUNCED`/`CEO RESUELTO` real quedaba mudo, dejando gobernar a la cadena vieja incluso
  sobre un slot ya reutilizado) y **T35** (el enlace del takeover con la cadena deja de acreditarse
  SOLO por nonce, CLASE 3 v22, ronda 36) de `references/proc-m13.selftest.sh`.
- **(b) Entrada y salida**: recibe la **ruta del flock**; devuelve **`"<estación> <nonce>"`** de la
  titular vigente, o **cadena vacía** si no hay `SLOT-CLAIM` que abra la cadena. Vacío **no**
  significa «slot libre»: significa «sin cadena», y quien llama decide qué hacer con eso.
- **(c) Qué acredita cada caso** (nombre del caso ↔ garantía):
  `sin takeover` · `UN takeover legítimo` · `DOS encadenados` (mata la ingenuidad de quedarse en el primer relevo) ·
  `cita al ORIGINAL superado` · `dos sobre la MISMA muerte` · `nonce inexistente` (las tres matan
  un resolvedor permisivo) · `tras DOS relevos el CLAIM es del ÚLTIMO` · `PR ajeno` ·
  `estación-anterior ajena` (T35, ronda 36 — ninguna de las dos basta con nonce correcto).

**Y NADA MÁS.** Esta sección **no reenuncia la regla**: hasta T05 v7 vivía aquí como prosa y allí
no vivía en ninguna parte; desde el ruling del CEO **manda el ejecutable** —el oráculo manda sobre
la prosa— y si alguna vez divergen, **se corrige este texto**. Es REENUNCIACIÓN cualquier frase
que reproduzca una **condición** del algoritmo —umbrales, orden de comprobaciones o valores por
defecto—, y la caza un `MUST_NOT` sobre los **tokens** de esas condiciones fuera del ejecutable.
Anclar la prohibición a los tokens y no a una redacción es lo que hace que una **paráfrasis nueva**
tampoco cuele: puede cambiar todas las palabras de alrededor, pero si reproduce la condición, el
token sigue ahí. La cita SUSTITUYE al enunciado, no lo acompaña — y una frase «útil» que además
explique el algoritmo es exactamente la segunda fuente que esto elimina.

El CEO/Orquestador, antes de publicar un takeover, releé la cadena completa y cita el `<nonce>`
que `titular_vigente()` devuelve — mismo principio de "releer antes de actuar" de esta sección.

**Transferencia del `CLAIM` — el `SLOT-CLAIM-TAKEOVER` mueve DOS cosas, no solo el slot (ronda
25, MAYOR — hallazgo de revisión externa)**: el `CLAIM #<PR>` original (arriba, "Drain-disjoint")
excluye a cualquier otra estación de procesar ese PR hasta `MERGED`/`BOUNCED`/`CEO RESUELTO` —
pero la estación titular murió, así que ese `CLAIM` sigue apuntando a una estación muerta salvo
que algo lo mueva. El `SLOT-CLAIM-TAKEOVER` transfiere, en el MISMO acto y sin publicar un
`CLAIM` aparte, TANTO la titularidad del slot COMO el `CLAIM #<PR>` vigente a
`<estación-nueva>` — el CEO/Orquestador ya confirmó la muerte real de la estación (Señal de
quiescencia real, mismo estándar que `APPLY-RUN` huérfano) antes de publicar el token, así que
esa misma confirmación autoriza ambas transferencias de una vez. Cualquier lector que aplique
drain-disjoint debe tratar `<estación-nueva>` como titular del `CLAIM #<PR>` desde el instante
en que el `SLOT-CLAIM-TAKEOVER` aparece en el flock — nunca como una violación de
drain-disjoint, y nunca esperando un `CLAIM` explícito adicional que este protocolo no exige.

**Acceso directo al flock canónico — qué cubre el espejo, y todo lo demás DENEGADO (FUENTE ÚNICA
de esta regla; ronda 12 BLOQUEANTE, invertida a conjunto permitido en la ronda del CR de T05)**:
la excepción de espejo de solo-lectura para actores remotos (arriba, "Contrato de formato del
flock") cubre **EXACTAMENTE UNA COSA: LEER**. Releer el espejo para informarse del estado ajeno
antes de decidir es todo lo que autoriza.

**Cualquier otra cosa exige escritura directa al flock canónico**, y eso incluye —sin que haga
falta enumerarlas— **todas** las operaciones que PUBLICAN un token en el flock y **todas** las
decisiones que se apoyan en la exclusividad de un token propio o ajeno: reservar (`CLAIM`,
`SLOT-CLAIM`), transferir (`SLOT-CLAIM-TAKEOVER`), ejecutar o cerrar un apply (`APPLY-*`), y
cualquier token futuro que se añada al contrato de formato. **Lo no clasificable se DENIEGA**: si
al leer esta regla dudas de si una operación cae dentro del espejo, **no cae** — exige flock.

*Por qué se escribe así y no como lista de excepciones*: esta regla se enunció tres veces como
lista de lo que el espejo NO cubre y las tres se quedó corta o desincronizada — le faltó
`SLOT-CLAIM-TAKEOVER` (ronda 24), sus copias divergieron entre sí (ronda 25, MAYOR de revisión
externa) y le faltaba `CLAIM` (CR de T05). **Una lista negativa es una allowlist incompleta con
otro nombre**: cada token nuevo tiene que acordarse alguien de añadirlo, y el fallo por olvido es
silencioso y del lado inseguro. Enunciada en positivo, un token nuevo nace denegado.

Publicar exige escritura directa porque el ciclo
publicar→releer→confirmar (paso 3) no puede cerrarse contra un espejo con lag: una estación
podría confirmar contra una copia desactualizada y pushear/arrancar PROC-M13 igual sobre una
colisión real. Una estación sin escritura directa al flock canónico NO mergea NI aplica PRs con
migraciones — rebota el PR a una estación que sí tenga acceso directo (ref 07 gotcha).

**Y el corte NO es «con migraciones vs sin»: es LEER vs ESCRIBIR.** La versión anterior dejaba
pasar «el resto de PRs (sin migraciones) se sigue procesando vía el espejo», y eso **anulaba la
propia excepción por el eje equivocado**: `drain-disjoint` opera sobre el `CLAIM #<PR>` —que existe
para **todo** PR, lleve migraciones o no— y **reclamar un `CLAIM` es RESERVAR, no leer**. El espejo
cubre EXACTAMENTE UNA COSA: leer. Una estación sin escritura directa **no puede tomar ni el primer
`CLAIM`**, así que **no hace intake de ningún PR**: rebota. Acotarlo por las migraciones dejaba a
una estación solo-espejo reservando PRs sin migraciones contra una copia con lag — que es
exactamente la colisión que la excepción existe para impedir, con otra ropa.

**Gotcha de enumeración truncada — ya mordió dos veces, `--limit` explícito NO basta
(reforzado tras auditoría — ronda 12, MAYOR; corregido de nuevo ronda 13, MAYOR)**: `gh pr
list` devuelve 30 resultados por defecto. Un `--limit` explícito (p. ej. `--limit 200`) solo
mueve el techo de truncamiento, no lo elimina — no demuestra que 200 sea el total real si hay
más PRs abiertos que eso. Enumeración COMPLETA exige DOS pasos: (1) pedir un `--limit` muy por
encima de cualquier cola plausible (p. ej. 1000); (2) contrastar el recuento devuelto contra un
total AUTORITATIVO independiente — **ÚNICAMENTE** `gh api graphql` con `search(type: ISSUE,
query: "repo:<owner>/<repo> is:pr is:open", first: 1) { issueCount }` (corregido ronda 13: `gh
pr list --search "is:open" ... --jq length` NO sirve de contraste — hereda el mismo default de
30 sin `--limit` propio, no es independiente ni autoritativo). Si no coinciden, NO se declara
enumeración completa: re-correr o escalar, nunca proceder con el recuento sin contrastar. Esto
cubre PRs; por FICHERO dentro de cada PR, `gh pr diff <pr> --name-only` no tiene paginación
conocida, pero ante cualquier duda se contrasta contra `gh pr view <pr> --json files --jq
'.files | length'` (corregido ronda 13: `--jq length` a secas cuenta las CLAVES del objeto de
respuesta, no los elementos del array `files` — hay que apuntar el jq al campo).

**Por qué NO es un mutex por flock local (rondas 5-6)**: un intento previo asumía que dos
estaciones comparten el MISMO filesystem/host de forma VERIFICADA — pero esa co-localización
es HOY exactamente el mismo "OBJETIVO, pendiente de cableado" que la topología M1-M5 completa
(SKILL.md "Según repo": `seal-suite.sh` sigue hardcodeado a `runner`/`/home/runner/repo`, fix
es hijo 6 de TAL-5160). El diseño ratificado no tiene este problema porque reusa el flock
COMPARTIDO ya existente (con espejo para actores remotos, ya documentado arriba), no un mutex
local nuevo.

**Por qué NO es un protocolo async de tokens bilaterales (ronda 8, 2 BLOQUEANTE)**: un segundo
intento reemplazó el flock por tokens CESIÓN/ACEPTACIÓN/DEVOLUCIÓN/RETOMA que cada estación
publicaba y releía por su cuenta ("fencing" por re-lectura) para TRANSFERIR autoridad entre
DOS estaciones designadas. La auditoría demostró que "releer antes de actuar" NO cierra el
TOCTOU: nada impide que la autoridad cambie ENTRE la lectura y el efecto real. El diseño
ratificado no transfiere autoridad entre estaciones — CUALQUIERA la tiene simultáneamente, sin
negociación previa, y el TOCTOU desaparece porque no hay autoridad que capturar: el
`SLOT-CLAIM` no autoriza, solo reserva un slot ya calculado contra el tope real, y una
colisión se resuelve renumerando, no litigando quién tenía razón.

**Por qué NO es un árbitro humano síncrono (ronda 9, 2 BLOQUEANTE)**: un tercer intento
colapsó la decisión a un único CEO/Orquestador que verificaba y comunicaba directamente a cada
estación. Fallaba por lo mismo (verificación puntual no es revocación) y además no era durable
a través de un reinicio de estación. El diseño ratificado no depende de una verificación en
tiempo real de nadie: el flock es la única fuente y sobrevive a cualquier reinicio de
cualquier estación.

**Por qué NO era SOLO M1 (rondas 9-11, lo que este skill llevó escrito hasta `78b05846d`)**:
un cuarto y un quinto intento colapsaron a una sola estación fija como única aplicadora,
primero con una excepción de urgencia vía GO del lead (rechazada — extendía sin autoridad la
EXCEPCIÓN ÚNICA de CLAUDE.md regla 24, reservada a migraciones destructivas), después sin
excepción alguna. La ronda 12 lo tumbó con un HECHO, no una preferencia: verificado el día de
la ratificación, **aplicaron migraciones M1 Y M2**, dos estaciones distintas — "de facto
serializado en una estación" era una inferencia sin verificar, no una observación de lo que la
fábrica hace hoy. Sellar por escrito una estación única fija habría fijado un cuello de
botella que nadie había decidido tener.

**Por qué esto SÍ cierra lo que los siete intentos previos no cerraron**: no depende de que dos
actores autónomos releán el mismo recurso a tiempo (ronda 8), de que compartan un inode con
atomicidad real-time (rondas 5-6), de un árbitro que verifique-y-comunique sin revocación
atómica (ronda 9), de una excepción de urgencia que reintroduce el mismo check-then-act bajo
otro nombre, ni de fijar una estación única que ni siquiera describía lo que la fábrica hace
(rondas 9-11). Depende de un mecanismo que YA EXISTE, YA está probado en producción (colisión
real #2113 vs #2153, resuelta) y no necesita coordinación previa entre estaciones: publicar el
claim y dejar que la colisión, si la hay, se resuelva renumerando — exactamente como el resto
de la cola. La ronda 12 completó la mecánica que la ratificación deja abierta sin añadir
doctrina nueva: confirmación post-append antes de pushear, ciclo de vida del claim, acceso
directo obligatorio al flock canónico (sin la excepción de espejo) y la enumeración COMPLETA
de PRs contrastada contra un total autoritativo. **La ronda 13 corrigió el alcance real de
`SLOT-CLAIM`**: no es un mutex de apply ni siquiera entre slots distintos, porque PROC-M13
aplica el gap COMPLETO `main − ledger`, no solo "el slot de este PR" — la carrera real está en
la EJECUCIÓN de PROC-M13, no en el número de slot, y por eso el gate que la cierra es
`APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` (punto 4 arriba): serializa CUÁNDO corre PROC-M13
fleet-wide, sin fijar QUIÉN lo corre — sigue sin haber una estación con autoridad permanente,
solo una ejecución a la vez. **La ronda 14 cerró el propio gate a medias**: el patrón
publicar→releer por sí solo no elegía ganador — el token ganó `#<PR>` y timestamp (el run_id),
pero la regla de desempate elegida ("el más reciente") resultó ser el error opuesto: un
publicador tardío se veía a sí mismo como el más reciente y arrancaba igual, sin revocar al
que ya estaba corriendo. **La ronda 15 corrigió la regla de desempate en sí**: gana el
PRIMER `APPLY-RUN` tras el último cierre válido — nunca el más reciente — y cualquier RUN
posterior antes de ese cierre es VOID para todos los lectores por definición (mismo algoritmo
determinista para todos, sin necesitar un token de cancelación); los cierres (`APPLY-DONE`/
`APPLY-FAILED`) repiten el run_id EXACTO del RUN que cierran, para que un cierre tardío o
duplicado de un ciclo anterior nunca se confunda con el del RUN activo. El auditor confirmó
que este algoritmo — first-run-tras-el-último-cierre — SÍ cierra la carrera A/B original,
incluso tras reinicio de una estación. **La ronda 16 cerró lo que quedaba de implementación**:
la recuperación pasó de un sufijo sobre `APPLY-RUN` (que violaba el contrato de tokens EXACTOS)
a un token propio, `APPLY-RECOVERS`, con identidad verificada por SHA de merge real y ancestry
— no por coincidencia de fecha; el cierre éxito/fallo se simplificó a código de salida puro
(`exit 0` = `APPLY-DONE`, cualquier otro = `APPLY-FAILED`) tras confirmar contra el ejecutor
real que TODO fallo, en cualquier paso, sale por `exit 1`/`exit 2` y que `exit 0` YA implica
ledger+advisors limpios — la clasificación por fases de la ronda 15 era innecesaria y además
irrealizable con el rc genérico de PROC-M13. **La ronda 17 encontró que ese wrapper con trap
no era ejecutable** (`publish_close` no estaba definida en ningún fichero) **y que "cualquier
`APPLY-FAILED` exige migración nueva" era falso**: el trap se retiró por completo — una
secuencia de tres pasos sin trap (`PIPESTATUS[0]` tras un pipe con `tee`, sin `pipefail`) no
deja ninguna ventana entre "el hijo terminó" y "el cierre se publica"; y la recuperación pasó
a tres categorías (TRANSITORIO/ESCALAR/DEFECTO CONFIRMADO) leídas del prefijo literal del
mensaje. **La ronda 18 encontró que esas tres categorías estaban mal pobladas y mal
propagadas**: un fallo de red en el ÚNICO POST que muta datos (Paso 4) no es TRANSITORIO
seguro, porque el anexo documenta que un timeout de cliente no cancela la transacción del
servidor — pasó a ESCALAR con una Reconciliación de quiescencia (dos lecturas del ledger
separadas por el `--max-time` del script) antes de decidir; el fallo de Paso 1 pasó de
DEFECTO CONFIRMADO a ESCALAR, porque una migración nueva no desbloquea una migración
PENDIENTE y rota que PROC-M13 procesa en orden — DEFECTO CONFIRMADO quedó solo para advisors
sobre un objeto YA aplicado, donde sí hay orden libre; se añadió una categoría por defecto
(ESCALAR) para cualquier fallo implícito de `set -euo pipefail` sin prefijo reconocido; la
categoría se volvió parte del propio token `APPLY-FAILED` (durable y compartida) en vez de
vivir solo en el `$LOG` local de la estación que corrió PROC-M13; el cierre del RUN huérfano
gana la misma Reconciliación de quiescencia, para no publicar un cierre sobre una transacción
remota que la muerte de la estación no prueba haber terminado; y los comandos de identidad de
`APPLY-RECOVERS` ganaron `--paginate` y un check fail-closed explícito en vez de una
descripción en prosa. **La ronda 19 encontró que la implementación de la ronda 18 no
coincidía con lo que describía, y que su propia Reconciliación de quiescencia medía el lado
equivocado**: `publish_close` seguía emitiendo el formato antiguo de cuatro valores —
nunca leía `$LOG` ni calculaba `<CATEGORIA>` — así que todo fallo real habría publicado un
token inválido; se reescribió con `classify_log` (verificado con 9 casos). El fallo de `tee`
seguía sin cerrar el RUN — con `set -e`, `tee` fallando por su cuenta (ej. disco lleno) aborta
el wrapper ANTES de `PIPESTATUS` igual que sin `pipefail`; ahora `set +e`/`set -e` protege
la secuencia COMPLETA, siempre, leyendo `PIPESTATUS` antes de reactivar `-e` (verificado:
reactivar `-e` primero también pisa `PIPESTATUS` con `0`). Dos lecturas del ledger separadas
por el `--max-time` del CLIENTE no prueban nada del SERVIDOR — el propio contrato ya
reconocía que ese timeout no cancela la transacción remota, así que ninguna ventana de
tiempo del cliente, por larga que fuera, cerraba el interleaving; se sustituyó por una Señal
de quiescencia real, una consulta a `pg_locks` sobre el ledger vía el mismo endpoint que
`fetch_ledger` — la pregunta pasó de "¿cuánto esperé?" a "¿sigue el servidor con un lock
exclusivo sobre la tabla?". Y DEFECTO CONFIRMADO dejó de auto-publicarse: PROC-M13 cuenta
TODOS los `ERROR` de advisors sin filtrar por objeto tocado, así que un `ERROR` ajeno habría
disparado `APPLY-RECOVERS` contra el PR equivocado — ahora `advisors ... tiene N ERROR`
publica ESCALAR como cualquier otro caso ambiguo, y DEFECTO CONFIRMADO es una conclusión de
esa investigación (objeto flageado verificado contra el `.sql` aplicado), nunca un valor que
el wrapper decida solo.

**La ronda 20 encontró que dos de los mecanismos de la ronda 19, aunque syntácticamente
correctos, seguían sin responder la pregunta real**: `classify_log` funcionaba —clasificaba
`APPLY-FAILED ... TRANSITORIO`/`ESCALAR` sin reventar— pero LEÍA `$LOG`, y PROC-M13 interpola
el cuerpo HTTP remoto de Paso 4 en su propio mensaje de error; el auditor ejecutó un cuerpo
forjado (`{"detail":"✗ ledger: HTTP forged"}`) y confirmó que el patrón TRANSITORIO de
`fetch_ledger` colaba por coincidencia textual — un tercero controlando la respuesta HTTP
controlaba la clasificación. El fix no ancla mejor el regex (un `^` no basta si el cuerpo
remoto trae saltos de línea): elimina el regex. PROC-M13 ahora declara su propia clase con un
literal fijo —nunca una variable interpolada— en un `CLASS_FILE` estructurado que el wrapper
lee sin tocar el log; el canal de clasificación y el canal de contenido no confiable quedan
físicamente separados. Y la Señal de quiescencia de la ronda 19, aunque corregía el eje
correcto (preguntar al servidor, no al reloj del cliente), seguía preguntando DEMASIADO
TARDE: el `insert` al ledger es el ÚLTIMO statement de la transacción de Paso 3, así que
mientras el DDL de la migración sigue corriendo la transacción aún no toca
`schema_migrations` y la consulta a `pg_locks` lee `0` con la mutación TODAVÍA viva — el
mismo defecto de fondo que el bloqueante 2 de la ronda 19 (medir un objeto que puede estar
quieto mientras la mutación avanza), aplicado esta vez al propio instrumento que se introdujo
para arreglarlo. El fix adquiere el lock EXPLÍCITAMENTE, `lock table ... in exclusive mode;`,
INMEDIATAMENTE tras `begin;` — ANTES de cualquier DDL — así que la señal existe desde el
primer instante de la transacción, no solo en su último. Verificado contra Postgres real
(nunca prod): sin el lock explícito, la consulta lee `0` con una transacción simulada viva;
con él, lee `>0` durante la misma ventana y solo `0` tras el cierre — la mutación exacta que
pidió C1 ("que la prueba falle si el DDL sigue vivo"). La ronda 20 también cerró un MAYOR: la
quinta condición de `APPLY-RECOVERS` decía "extrae el objeto" sin fijar el campo ni validar
su existencia, y remitía a una búsqueda textual sobre el `.sql` que el propio auditor rechazó
como insuficiente — ahora fija la terna exacta (`schema`+`name`+`type` de `.metadata`,
fail-closed si falta alguno) y es honesta en que la lectura del `.sql` sigue siendo un paso
HUMANO deliberado, no un regex automatizado que finja ser un gate.

**La ronda 21 encontró que el arreglo del lock de la ronda 20, aunque correcto en su propio
eje (el lock SÍ cubre toda la transacción una vez adquirido — confirmado por el auditor
contra la documentación oficial de Postgres), dejaba abierto un eje DISTINTO: la ventana
ANTES de adquirirlo**. `pg_locks` solo muestra locks YA SOLICITADOS — un POST que el servidor
aceptó pero que todavía no llegó a su propio `lock table` (por cola, por planificación del
backend, o porque el cliente perdió la conexión sin que el servidor cancelara el trabajo) no
aparece ahí. C1 lo resumió así: llevaba tres rondas intentando demostrar una ausencia FUTURA
por observación, y eso no se puede — ni con dos lecturas separadas por tiempo (ronda 19), ni
con una lectura de `pg_locks` en un instante (ronda 20); ambas miran lo que YA pasó, nunca lo
que alguien TODAVÍA no ha pedido. El cierre no mejora la observación: hace que el duplicado
se aborte SOLO. El fix — una revalidación `do $$ ... if exists (...) then raise exception
...; end $$;` DENTRO DE LA MISMA TRANSACCIÓN, inmediatamente después del lock y antes del
DDL — usa la propia serialización de Postgres sobre el lock: si dos intentos para la MISMA
versión compiten, el segundo en obtenerlo (tras esperar a que el primero haga commit/
rollback) encuentra la versión ya aplicada y se cae solo, sin tocar el DDL. Deja de importar
quién llegó primero. Verificado contra Postgres real, no solo prosa (mismo contenedor local
de la ronda 20, nunca prod): con una versión ya presente, la transacción aborta ANTES de
crear ningún objeto y el conteo de filas para esa versión nunca pasa de 1; con una versión
nueva, el guard no interfiere y el DDL+insert+commit corren normal — exactamente el criterio
de mutación que pidió C1 ("simular el retry que gana el lock después ⇒ debe abortar"). La
ronda 21 también cerró dos MAYORES: el `mktemp` de `CLASS_FILE` se creaba DESPUÉS de ganar
`APPLY-RUN` — si `mktemp` fallaba ahí (disco lleno, permisos, inodos), el wrapper moría bajo
`set -e` sin ejecutar PROC-M13 ni publicar ningún cierre, dejando el gate huérfano hasta el
timeout; se movió a ANTES de intentar publicar `APPLY-RUN` siquiera, así que si falla, nunca
se reclama nada que huérfanar. Y T21h, pese a reproducir el cuerpo forjado correctamente,
solo examinaba lo que PROC-M13 (el productor) escribía en `CLASS_FILE` — nunca invocaba
`classify_log`/`publish_close` (el consumidor); una reversión aislada del CONSUMIDOR a leer
`$LOG` habría pasado en verde. Se añadió T21j, que extrae el fence real de `classify_log`/
`publish_close` de este mismo documento (no una copia mantenida a mano) y los ejecuta
extremo a extremo contra el mismo cuerpo forjado, verificando el token final publicado.

## 3. Fire-and-forget: el productor no vuelve

- El HANDOFF es **todo el contexto disponible**: qué hace, decisiones, invariantes
  sellados, superficies, slots, trampas. Si el HANDOFF no alcanza para operar el PR, la
  entrega es inválida (PROC-M01) — la solución es rechazar, nunca "preguntar al canal".
- Consecuencia de diseño: la calidad del HANDOFF es la métrica de la 1ª estación; un
  handoff pobre = bounce, y los bounces se miden (piloto TAL-2192).
- El Mergeador tampoco re-abre el plan: los invariantes sellados por el code-audit son
  contrato. Si un finding exige romperlos → defecto de DISEÑO → bounce (ref 05).

## 4. La cola y su prioridad

- Fuente: `gh pr list --draft` (+ el tablero del Orquestador si hay órdenes activas).
- Prioridad (la cura el Orquestador; el Mergeador la respeta): **bugs > mes-objetivo >
  resto**; agrupar por hot-file para minimizar reconciles entre PRs que tocan lo mismo.
- **Pipeline de la estación**. **RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`:
  **el batching está DESACTIVADO**, así que **CADA PR corre su suite COMPLETA sobre su propio head**,
  disjunto o no; lo que sigue describe la ventana, no autoriza ahorrarse una suite. La escritura
  sobre `main` sigue **serializada** —no se funden dos
  cosas a la vez—, pero eso **no es lo mismo que un solo PR autorizado por turno**: con varias
  estaciones drenando, los merges se agrupan por **VENTANA** y las piezas verdes sobre el mismo tip
  pueden fundirse **una tras otra** si sus ficheros son **disjuntos** de los ya fundidos en esa
  ventana, **cada una con su suite COMPLETA sobre su propio head**. La exención de suite que esta
  línea prescribía es la RUTA APAGADA del ruling: se deja **registrada** —era lo que la vía
  preveía— y **no es operable**. **La ley de batching y su literal están en `references/10-estaciones-en-paralelo.md`**;
  esta línea decía «UN PR en el slot (serializador único del repo)» y se reconcilia aquí para que
  ref 01 y ref 10 no digan cosas distintas. Mientras tanto, otros PRs avanzan en preparación
  (intake, rebase, CR, refacto) en paralelo.

  **Serialización del ACTO de merge y migraciones (TAL-5170)**: drenaje **paralelo** entre las 5 estaciones (M1-M5, TAL-5170) —
  cada una prepara/refactoriza su propio PR en paralelo (intake, rebase, CR, refacto). **Solo
  el ACTO de merge se serializa, y lo serializa GitHub mismo** (`strict=true`: un merge sobre
  base stale es rechazado por la API — ref 02 §3, no un lock propio de la estación), no la
  estación entera. **Los PRs con migraciones NO son la excepción a "cualquiera mergea"**: la
  Management API de Supabase no tiene equivalente al `strict=true` de GitHub, así que el token
  `SLOT-CLAIM` sobre el mismo flock que ya sirve al resto de la cola evita que dos migraciones
  compartan número de slot; el ACTO de ejecutar PROC-M13 lo serializa un gate DISTINTO,
  `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` sobre el mismo flock, con el run_id (`#<PR>`+
  timestamp+`<nonce>`, único por el `<nonce>` — ronda 27) decidiendo primero-tras-el-último-cierre, nunca "el más reciente" — PROC-M13
  aplica el gap COMPLETO `main − ledger`, no solo "mi slot", así que slots DISTINTOS NO pueden
  aplicar en paralelo sin colisionar (§2 arriba, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`, ronda
  13) — **CUALQUIER estación (M1-M5) mergea Y aplica**, sin estación fija ni turno (nueve
  intentos previos de fijar una estación única, arbitrar un segundo actor, separar merge de
  apply, tratar slots distintos como aplicables en paralelo, publicar/releer sin desempate, o
  desempatar por recencia fallaron auditoría o no describían lo que la fábrica hace — flock
  local, tokens async, árbitro humano, GO-del-lead, merge-ahora/apply-después, SOLO M1,
  mutex-por-slot-sin-gate-de-ejecución, publicar-releer-sin-ganador, más-reciente-gana).

  Quien mergea, aplica: no se delega el apply a otra estación ni se difiere para después (§2
  arriba, "Apply de migraciones: protocolo SLOT-CLAIM del bus"). Una colisión de slot
  (`SLOT-CLAIM` ajeno vivo sobre el mismo slot) se resuelve renumerando al siguiente libre,
  igual que el resto de la cola. Un `APPLY-FAILED` no fija tampoco quién recupera: la
  recuperación sigue el mismo "cualquiera" que el resto del pipeline y nunca vuelve por
  obligación a la estación que falló. Pero el permiso NO es incondicional:
  **Mientras TAL-5296 siga abierta, el default es ESCALAR** (§2, «Límite conocido: ciclo de vida
  de `APPLY-RECOVERS`»). Ante autorización de otra estación, más de un `APPLY-RECOVERS` citando
  el mismo `<nonce-fallido>`, o duda sobre si una autorización ya se consumió, la estación **NO
  ejecuta: escala** al CEO/Orquestador. Sólo fuera de esas tres caras, y con la identidad
  verificada por SHA/ancestría/diff/HANDOFF que exige §2, una estación publica `APPLY-RECOVERS`
  y toma el siguiente `APPLY-RUN`.

  Esta sección es un RESUMEN y se lee ANTES que §2, así que omitir aquí el fail-closed no era un
  matiz de redacción: era la diferencia entre aplicar y no aplicar una migración en PROD. En
  cualquier discrepancia entre este resumen y §2, **manda §2**. Las dos secciones nombran el
  MISMO default y el ratchet lo exige por separado (`INV-ME-270`/`INV-ME-271`): si una se edita
  sola, el paquete falla en vez de volver a divergir en silencio.
- La cola no se drena por FIFO ciego: un PR atascado en el fallback App (CLI no
  disponible) no bloquea el slot — entra otro con CLI limpio ya trazable mientras tanto
  (ref 04, budget-aware). Con CLI disponible nada espera al App: sensible o no, el CLI
  limpio autoriza el merge (ruling ADR-0043).
- **Preaviso de draft (aviso anticipado de drafts entrantes)**: el CEO/Orquestador avisa a la
  estación de un draft en camino ANTES de que aparezca en `gh pr list --draft` — el canal
  productor entrando a gates locales ES la señal de preaviso listo. (Terminología: «preaviso de
  draft», NUNCA «pre-claim» — ese término queda RESERVADO al pre-claim grep del flock, §2/ref 02
  §1, que es otro mecanismo: lock anti-doble-intake, no aviso de cola.) La estación reserva el
  cupo sin esperar el `verify-handoff.sh` (que corre igual al aparecer el draft), eliminando
  la latencia draft→claim. **Contrato de la reserva (nunca un lock ciego)**: (a) es
  **identificable** — se registra con propietario (canal productor + encargo/TAL-N esperado),
  jamás anónima; (b) **expira de forma determinista** — si el draft NO apareció al llegar el
  SIGUIENTE barrido de la estación (o el canal productor murió/se recicló antes de publicar),
  la reserva CAE sola y el cupo vuelve a la cola normal — cero acción manual, cero cupo
  bloqueado indefinidamente; (c) **nunca desplaza trabajo YA disponible**: es prioridad de
  atención sobre capacidad libre, no un bloqueo del slot — con cola viva, el slot sigue
  drenando por PULL y el preaviso solo ordena qué se mira primero cuando el draft aterrice.
  Es la dirección INVERSA del anuncio del coordinador al Orquestador ya documentado (§2, "La
  estación ANUNCIA los PRs que toma"): análogo simétrico de la regla dura 11 (cero ociosidad)
  — la cola se pre-carga por PULL anticipado, el slot nunca descubre trabajo tarde.
  Cross-ref: la elasticidad bajo run largo en ref 08 §7.

## 5. Topología de la estación

- El Mergeador es un **coordinador** (agente principal en foreground) con N canales
  propios (contenedores Incus + tmux, pane dev + pane auditor) que aprovisiona
  `talent-channels` con el **perfil Mergeador**: `CODERABBIT_API_KEY` (CLI), `gh` con
  permisos de merge, `SUPABASE_ACCESS_TOKEN` (apply + advisors), acceso al ledger.
- Los canales de PRODUCCIÓN no llevan `CODERABBIT_API_KEY` (perfil producción) — la
  separación de credenciales ES la separación de estaciones.
- Mecánica tmux/relay/recycle: idéntica doctrina que `talent-channel-operation`
  (`references/03-mecanica-tmux-incus.md` de aquel skill) — no se duplica aquí.
