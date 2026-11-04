# Mecánica de Carriles y Recursos Compartidos — Complete Reference

> **Terminología**: «carril» = «canal» (sinónimo histórico; la fábrica v2 usa
> «canal»). En el flujo clásico la unidad de trabajo sigue siendo la **issue/
> pieza** — «encargo»/«bundle» son vocabulario de la fábrica (`talent-orchestrator`),
> no de este puesto clásico.

## Table of Contents

1. [El prompt de carril](#1-el-prompt-de-carril)
2. [Slots de migración: bandas disjuntas por carril](#2-slots-de-migracion-bandas-disjuntas-por-carril-regla-fundamental)
3. [Colisiones: prevención y backstop de gate](#3-colisiones-prevencion-bandas-y-backstop-de-gate)
4. [Recursos compartidos entre carriles](#4-recursos-compartidos-entre-carriles)
5. [Propagación de noticias entre carriles](#5-propagacion-de-noticias-entre-carriles)
6. [Credenciales por máquina](#6-credenciales-por-maquina)
7. [Gotchas & Cross-References](#7-gotchas--cross-references)

---

## 1. El prompt de carril

El prompt es el ÚNICO canal del coordinador hacia el carril: autocontenido,
numerado, con la issue como fuente de la spec (el prompt no la duplica — la
señala y añade los puntos calientes). Plantilla completa en
`../prompts/plantillas.md`. Esqueleto:

```text
**EX — TAL-NNNN: <título imperativo>**
Lee TAL-NNNN en Linear (spec completa). Ya está In Progress.
1. git checkout main && git pull --rebase → rama <prefijo>/tal-nnnn-<slug>
2. Skills a cargar: <los del dominio tocado>
3. <2-4 PUNTOS CALIENTES específicos de esta pieza — los riesgos que el
   coordinador ya ve: triggers guard, contratos, gotchas aplicables>
4. Validación: <comandos y specs concretos + capturas si hay UI>
5. STOP PRE-MERGE REAL — se ESPERA el GO: PR (base main, body `closes TAL-NNNN`)
   → diff aquí → GO → squash. <refuerzos vigentes si los hay>
6. Post-merge en el MISMO turno (si hay BD): apply + reconcile N/N con
   comandos en vivo + advisors → reporte aquí.
```

Reglas: rama por prefijos válidos del repo · el carril valida ANTES del STOP
(no se gatea trabajo sin validar) · todo refuerzo de protocolo vigente
(merges sin gate previos, reviewers pausados) viaja DENTRO del prompt.

Regla de la ORDEN accionable: toda instrucción a un carril —el prompt entero o
un dictamen suelto— lleva **verbo + canal/carril destino + deadline + prueba de
hecho verificable**. «Adjudica ch44 YA y confirma "ch44 Opus vigente xhigh OK"» es una
orden: se ejecuta y se acusa con una prueba concreta. «Procesa tus menús» NO lo
es —sin destino, sin plazo y sin prueba se queda sin ejecutar y sin acuse—. El
coordinador ejecuta la lista de órdenes concretas que recibe, no su propia
agenda.

## 2. Slots de migración: bandas disjuntas por carril (REGLA FUNDAMENTAL)

Con N carriles paralelos sobre una BD compartida, que cada carril elija "el
siguiente slot libre" cerca del head GARANTIZA colisiones: dups en `main` que
rompen el `db reset` local de TODO el equipo y re-anclas repetidas con churn de CI.
La solución es estructural, en dos tiempos:

```text
1. PRE-ANCLA EN BANDA (durante el desarrollo)
   El coordinador publica un BASE por encima del techo de subida del head
   (el ledger contiguo vive BAJO las bandas). Carril K ancla SIEMPRE en su
   banda propia de 10 slots. El slot es `2027SSSS000000` (14 dígitos):
   prefijo `2027` (4) + SSSS (4) + `000000` (6), con SSSS = BASE + 10·K
   a 4 dígitos (zero-pad). Multi-migración = SSSS consecutivos en la banda.
   Ejemplo (BASE=0400):
       E1  SSSS=0410 → 20270410000000 .. 20270419000000
       E2  SSSS=0420 → 20270420000000 .. 20270429000000
       E10 SSSS=0500 → 20270500000000 .. 20270509000000
       E13 SSSS=0530 → 20270530000000 .. 20270539000000
   Bandas disjuntas ⇒ COLISIÓN IMPOSIBLE en dev / rebase / db reset local, sin
   importar cuántos carriles ni en qué orden mergeen. El carril desarrolla
   y rebasa sin pisar a nadie y sin re-anclar por culpa de otro.

2. AJUSTE EN LA VENTANA DE MERGE (el "y luego se ajusta")
   Al recibir el token de merge (serializado por el coordinador, cimientos
   antes que consumidores), el carril re-ancla sus migraciones de su banda al
   max(version)+1 CONTIGUO — el coordinador confirma el head en el momento.
   Esto mantiene el ledger contiguo y EN ORDEN de dependencia (evita el
   out-of-order que rompería "foro depende de ranking"). Es UNA sola re-ancla
   por PR, en su merge — no las repetidas que sufre el esquema head+1.
```

Mantenimiento del BASE: el coordinador lo sube (p. ej. 0400 → 0800) cuando el
head contiguo se acerca a la banda más baja; lo anuncia y los carriles re-
basan sus bandas. Apply out-of-order (timestamp < head, caso raro):
`db push --linked --include-all` — sin el flag el push NO ve la migración.

## 3. Colisiones: prevención (bandas) y backstop de gate

Las bandas disjuntas (§2) ELIMINAN la colisión por diseño: mientras cada
carril se quede en su banda, dos carriles NO pueden chocar de slot. El fallo
clásico — dos carriles eligiendo "el siguiente libre" la misma noche (pasó
dos veces en 24h; y un dup-`20270297000000` que rompió el `db reset` local de toda
la flota) — desaparece si las bandas se respetan.

El coordinador, ÚNICO que ve todos los carriles, mantiene un backstop en CADA
gate con migración:

```text
DETECCIÓN (backstop, SIEMPRE que haya migración):
  git ls-tree -r origin/main --name-only -- <dir-migraciones> | grep <slot>
  select count(*) from <ledger> where version = '<slot>';
  select version,count(*) from <ledger> group by 1 having count(*)>1;  -- dups
  → cero dups; el slot de merge = max(version)+1 contiguo

RESOLUCIÓN si un carril llega fuera de banda o el slot ya está tomado (NO-GO):
  1. git fetch && git rebase origin/main          (trae lo ya mergeado)
  2. git mv <slot-malo>.sql <banda-propia | max+1>.sql   (re-listar AHORA)
  3. Actualizar referencias al filename viejo (¡mensajes de error de specs!)
  4. db reset local/efímero (nunca prod/staging; debe dar el nuevo N) + re-validación corta
  5. Re-STOP con diff-of-diffs (el delta = solo el rename; SQL byte a byte)
```

Drift de bookkeeping aparte: si el apply inserta una version autogenerada en
vez del timestamp DEL FILENAME (contrato correcto: DDL + `insert into
supabase_migrations.schema_migrations (version, name)` con el timestamp del
archivo, ambos en la MISMA tx `begin;…commit;`) → reconciliar la fila a su
slot canónico (borrar la espuria + insertar la canónica, sin re-correr DDL).
Jerarquía de métodos (regla 24, **preferencia decreciente**): Management
API es la vía primaria (exige el insert manual descrito arriba); el CLI
(`db push --linked`) es el método secundario, que además preserva
version=filename sin intervención manual. Ver SKILL.md gotcha 8.

## 4. Recursos compartidos entre carriles

Cuentas smoke, fixtures, entornos, datos de prueba en prod: TODO recurso que
toque más de un carril lleva **contrato operativo escrito** (runbook):

```text
Contrato mínimo de un recurso compartido:
- Identidad: qué es, dónde vive, credenciales (vía env/escrow, jamás repo)
- BASELINE intocable: qué estado debe existir SIEMPRE (p. ej. "2 enrollments
  gifted_permanent") — quien lo encuentre roto lo restaura igual y avisa
- PURGEABLE: qué puede crear/borrar cada flujo (p. ej. "actividad del smoke
  sí; enrollments baseline NO")
- Consumidores: qué specs/flujos lo usan (para evaluar impacto de cambios)
```

Caso real que motiva la regla: el purge legítimo de un smoke de ola (carril A,
autorizado) borró el enrollment que la suite E2E de otro carril (B) asumía —
B lo vivió como "drift misterioso" y quemó tiempo diagnosticando. Sin
contrato, cada carril hace lo correcto Y se pisan.

Fixtures en BD de prod: NO crear nuevos (derivan a contenido real con la
operación editorial). Escenarios deterministas → seed local; contra prod solo
smokes content-agnostic con skip dinámico.

## 5. Propagación de noticias entre carriles

Los carriles no se leen entre sí. El coordinador propaga, en el siguiente
contacto con cada carril (prompt, GO, dictamen):

- Estado de reviewers automáticos (pausado/sin créditos/reactivado) — un
  carril esperando la review de un reviewer pausado pierde una hora.
- Precedentes nuevos (decisiones del lead que aplican a todos).
- Refuerzos de protocolo (un carril se saltó el gate → todos reciben el
  recordatorio en su siguiente prompt).
- Cambios de contrato de piezas en vuelo (el cimiento cambió una firma →
  los consumidores se enteran POR el coordinador, no por el conflicto).

### Anti-menú-abierto: discriminador dim/autocomplete vs input real

Coherente con la doctrina YA VIGENTE del skill hermano
`talent-channel-operation` (`SKILL.md:339-342` gotcha 10 ·
`references/03-mecanica-tmux-incus.md` §5 L115-135): **dim ≠ orden**. Se
cross-referencia, no se contradice; NO se edita ese skill.

**Discriminador previo (imprescindible).** Antes de reaccionar a CUALQUIER
texto inesperado en un pane, capturar con códigos ANSI **con target
explícito**: `tmux capture-pane -p -e -t <pane-destino>` — SIN `-t`, `tmux`
captura el pane ACTUAL (típicamente el del propio coordinador), no el pane
ajeno que va a recibir el `send-keys`; la guarda inspeccionaría el pane
equivocado y podría declarar "seguro" un destino que en realidad tiene el
menú abierto — reproduciendo exactamente la selección fabricada que la
guarda intenta impedir. `<pane-destino>` es el identificador del pane ajeno
(p. ej. `v:.0` del carril), nunca el pane propio del coordinador. Preferible
un helper que EXIJA y VALIDE el target (no un `-t` opcional que se pueda
omitir por descuido).

- **Gris/dim (`^[[2m`)** = sugerencia de autocomplete del CLI → NUNCA
  autorización, NO se ejecuta solo, desaparece al escribir → se **IGNORA**.
  NO es una «selección fabricada» ni incidente de seguridad; no se
  "neutraliza" el pane por gris (nada de `Escape`/`Ctrl-U` a lo loco).
- **Brillo pleno** realmente tecleado/**encolado** = input **REAL** → eso SÍ
  puede submitear.

El riesgo del menú **NO es el dim**: es un `send-keys` **STRAY REAL**
(brillo pleno) que aterriza sobre un menú abierto. Con eso claro, tres
prongs:

1. **Guarda de salida (`capture-pane -p -e -t <pane-destino>` pre-`send-keys`)**:
   antes de CUALQUIER `send-keys` a un pane ajeno (nudge / GO / dictamen /
   re-PULL), capturar con **el mismo target** al que se le va a mandar el
   `send-keys` (nunca el pane propio) y verificar que NO hay **menú
   interactivo abierto** (AskUserQuestion / aprobación-de-plan / selector).
   Con un menú abierto, un texto+Enter **real** SELECCIONA la opción
   resaltada → fabrica una «decisión» que nadie tomó. Con menú abierto →
   **no enviar**: esperar a un prompt neutro o escalar fuera de banda.
   Reutilizar las firmas de menú-vivo ya definidas en `SKILL.md:163-165`
   (IDLE-REAL, exclusión #4): «Enter to select / shift+tab / Press up» +
   aprobación-de-plan / selector numerado. Referenciarlas, **no** duplicar
   una lista divergente.
2. **Guarda propia (sin menús mientras te operan por relay)**: si el propio
   puesto de mando es destino de `send-keys` de una capa superior, **no**
   abrir `AskUserQuestion`/menús para decidir — un `send-keys` **stray
   real** (brillo pleno, no el dim) puede seleccionar en TU menú abierto.
   Escala por canal fuera de banda que NO sea menú (terminal/flock/texto),
   **fail-closed**. **Ruling del lead (TAL-5141): el coordinador pregunta
   SIEMPRE en TEXTO PLANO** (una pregunta por turno), nunca abriendo
   menú/`AskUserQuestion` — ni en bootstrap ni en decisiones del lead —,
   precisamente porque un menú abierto en su propio pane es seleccionable
   por un `send-keys` ajeno bajo relay (`SKILL.md:43`).
3. **Provenance (entrada)**: ninguna **selección de menú** en un pane
   compartido tiene provenance suficiente sin verificación **fuera de
   banda** (flock/terminal) ANTES de relayarse como ruling; **fail-closed
   ante duda**. «ruling del lead» ≠ «opción seleccionada en un pane».
   Evidencia: **ch05/TAL-3071** — un `send-keys` real cayó sobre un
   `AskUserQuestion` ajeno; la selección fantasma se relayó como «RULING
   LEAD» y el lead lo desmintió («yo no he sido»).
   La verificación fuera de banda DEBE confirmar los **tres sub-checks**
   antes de relayar; si cualquiera falla, falta o es ambiguo → **fail-closed**
   (no se relaya, se escala por el canal fuera de banda):
   - **(a) Identidad del lead**: el ruling procede del lead por un canal
     autenticado (flock/terminal), no de una opción aparecida en un pane
     compartido. «pane» ≠ «lead».
   - **(b) Correlación solicitud↔respuesta**: la respuesta corresponde a una
     pregunta concreta que TÚ formulaste y sigue pendiente; una selección sin
     solicitud correlacionada es fantasma → se descarta.
   - **(c) Frescura**: la confirmación es reciente y de un solo uso; una
     confirmación reutilizada, antigua o de una ronda anterior NO autoriza.

Nota de complementariedad (verificada, cero solape): esta captura es
**pre-send** (seguridad del relay); la `capture-pane` de
supervisión-activa (TAL-2767) es **pre-idle** (observación). Mismo tool,
momentos distintos — no se toca la sección de supervisión-activa.

## 6. Credenciales por máquina

N máquinas autenticando la MISMA cuenta con OAuth se revocan los tokens entre
sí (síntoma: "token murió a mitad de comprobación", keyrings inválidos,
re-logins constantes del lead).

```text
Solución: 1 token independiente POR MÁQUINA (no por org, no compartido):
- PAT fine-grained (1 org) o classic (multi-org). Dos contratos de scopes,
  NO intercambiables entre sí (`workflow` y `gist` son permisos DISTINTOS,
  ninguno cubre al otro):
  - Scopes de la flota (runbook `docs/runbooks/mcp-fallbacks.md`, `GITHUB_TOKEN`):
    `repo, workflow, read:org` — `workflow` habilita tocar ficheros de
    GitHub Actions; solo hace falta si la máquina los edita.
  - Mínimo documentado por `gh` para el fallback `--with-token` con PAT
    classic (`gh auth login --help`, verificado 2026-07-18): `repo, read:org,
    gist` — `gist` es requisito del propio flujo de login por stdin, no lo
    sustituye `workflow`.
  La condición es la misma en las dos vías, no absoluta por vía: sumar
  `workflow` SI Y SOLO SI esa máquina/carril necesita editar
  `.github/workflows/**` — también aplica al fallback (una máquina que
  autentica por `--with-token` y edita workflows SÍ necesita `workflow`
  sobre su base `repo, read:org, gist`). Sumarlo sin esa necesidad, en
  cualquiera de las dos vías, amplía el blast radius sin motivo.
- Preferente (token-only, NADA en disco): exportar el PAT como GH_TOKEN en el
  entorno del proceso (desde escrow/.env.local gitignored, nunca commit); `gh`
  lo honra sin escribirlo en `hosts.yml`. Es el patrón token-only de la flota.
- Fallback `gh auth login --with-token` (stdin: NO queda en argv ni historial)
  + `gh auth setup-git`: OJO, PERSISTE el PAT EN CLARO en `~/.config/gh/hosts.yml`
  si no hay keyring del SO (Secret Service / pass). Úsalo SOLO con disco cifrado
  (LUKS/FileVault) Y keyring activo; sin ambos el token queda recuperable por
  quien acceda al disco → limita a máquina efímera de un solo uso y revoca al
  terminar.
- Los tokens NUNCA viajan por los chats de los agentes (quedan en transcripts)
- Revocación quirúrgica: máquina comprometida = su token fuera, el resto sigue
```

## 7. Gotchas & Cross-References

1. **El prompt dice el QUÉ caliente, la issue dice el TODO** → Duplicar la
   spec en el prompt garantiza divergencia. Prompt = puntero + riesgos +
   protocolo.

2. **El rename de migración arrastra strings** → Mensajes de error de specs y
   comentarios citan el filename viejo; el fix del rename los incluye (pasó:
   un spec quedó citando un timestamp dos renames atrás).

3. **El espacio post-head se quema rápido** → En noches de multi-merge,
   recordar a cada carril con migración post-head que re-liste EN EL MOMENTO
   del rename, no cuando empezó.

4. **El carril que reutiliza una cuenta compartida verifica su estado
   PRIMERO** → "Verifica por SQL que no arrastra señales" antes del smoke;
   un estado sucio invalida el assert más limpio.

5. **`gh` con keyring roto en Linux** → sin keyring, `--with-token` escribe el
   PAT EN CLARO en `hosts.yml`: desatasca el login sin instalar nada, pero deja
   el token recuperable en disco. Solo aceptable con disco cifrado; si no,
   preferir `GH_TOKEN` por entorno (no toca disco) o arreglar el keyring en vez
   de persistir el token en claro (ver §6).

Cross-references: detección en gate → `03-gates-pre-merge.md` §4 · contratos
de piezas → `02-planificacion-y-despacho.md` §3 · plantillas →
`../prompts/plantillas.md`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
