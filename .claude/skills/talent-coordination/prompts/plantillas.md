# Plantillas del Puesto de Mando

Cinco artefactos con formato fijo. Los `<placeholders>` se rellenan; las
cláusulas en MAYÚSCULAS no se negocian.

## Table of Contents

1. [Prompt de carril](#1-prompt-de-carril)
2. [STOP pre-merge (lo que el carril debe traer)](#2-stop-pre-merge-lo-que-el-carril-debe-traer)
3. [Comentario-evidencia de cierre](#3-comentario-evidencia-de-cierre)
4. [Brief de alta: Analista de Producción](#4-brief-de-alta-analista-de-producción)
5. [Sello de escalado y de re-acreditación](#5-sello-de-escalado-y-de-re-acreditación)

---

## 1. Prompt de carril

> **Campo OBLIGATORIO de despacho `[A1 fail-closed]`**: el prompt lleva
> `régimen: <alta-cadencia|tranquilo|paro>` (el régimen T7 vigente que fijó el
> lead). **Sin régimen declarado NO se despacha** — no hay default implícito; el
> coordinador queda en `SIN-RÉGIMEN` (solo read-only) hasta que el lead lo declare.

```markdown
**<CARRIL> — <ISSUE-ID>: <título imperativo de la pieza>**  ·  régimen: <alta-cadencia|tranquilo|paro>

Lee <ISSUE-ID> en Linear (spec completa: <qué contiene en 1 línea>). Ya está
In Progress. <Contexto de urgencia/bloqueo si aplica: "bloquea la ola X",
"vivo en prod para N usuarios">.

1. `git checkout main && git pull --rebase origin main` → rama
   `<prefijo>/<issue-id>-<slug>`.
2. Carga skills: <skills del dominio> (+ <skills de review del repo> antes
   del push).
3. <PUNTO CALIENTE 1 — el riesgo principal que el coordinador ya ve>
4. <PUNTO CALIENTE 2..4 — contratos a respetar, gotchas aplicables, qué NO
   tocar ("CERO cambios de mecánica"), referencias a patrones del repo>
   [Si hay migración:] **Timestamp de TU carril (<serie>), siguiente a tu
   último y post-head si aplica la 3ª regla — re-lista migraciones + git
   fetch JUSTO antes de crearla. `db reset` SIEMPRE (solo local/efímero —
   nunca prod/staging). Regenera types si
   cambia el schema.**
5. Validación: <comandos exactos> + <specs en verde> + <capturas
   desktop/mobile si hay UI>.
6. **STOP PRE-MERGE REAL — se ESPERA el GO**: PR (base `main`, body
   `closes <ISSUE-ID>`) con <evidencia esperada> → diff aquí → mi GO →
   squash. <Refuerzos vigentes: "lo de #NNN no se repite" / "reviewer X
   está pausado, no lo esperes">.
7. [Si hay BD:] Post-merge en el MISMO turno: apply (<método y flags,
   p. ej. `db push --linked --include-all` si out-of-order>) + reconcile
   N/N con comandos en vivo + advisors → reporte aquí.
   [Si no:] Sin migraciones → sin apply; reporta el merge y cierro
   verificación.
```

Regla de la orden accionable: cada instrucción del prompt (y todo GO/dictamen
suelto) lleva **verbo + canal/carril destino + deadline + prueba de hecho
verificable**. «Adjudica ch44 YA y confirma "ch44 Opus vigente xhigh OK"» se ejecuta y
se acusa; «procesa tus menús» no —sin destino, plazo ni prueba se pierde—.

## 2. STOP pre-merge (lo que el carril debe traer)

El coordinador exige este contenido; si falta, lo pide antes de gatear:

```markdown
STOP PRE-MERGE — PR #<N> listo, espero tu GO

- PR: <url> · rama <rama> · HEAD <sha> · body con `closes <ISSUE-ID>`
- Diff: <nº archivos, +X/−Y> — <resumen honesto de QUÉ cambia, incluido lo
  que se desvía de la spec y POR QUÉ>
- Checks CI: <estado real por check, incluidos los rojos con su causa>
- Sentinel de push (TAL-1518): <ruta clásica no-draft — `.claude/.cr-review-ok`
  vigente para el HEAD, `scripts/cr-review.sh` limpio (o deferred con
  PR+label `cr-review`) / ruta canal de producción — `.claude/.draft-handoff`
  (lo consume el hook pre-push como exención one-shot del gate CR; el propio
  CodeRabbit lo corre después, exclusivamente, el Mergeador sobre el PR
  draft + HANDOFF)>
- Reviews automáticas: <estado por reviewer: hallazgos atendidos con commit,
  o fail administrativo citando el precedente>
- Validación: <typecheck/lint/build> · <specs con resultados numéricos
  "7/7", jamás "ok"> · <capturas si hay UI> · [BD, local:] db reset = <N> ·
  dry-run del apply listará EXACTAMENTE <migraciones>
- Notas de entorno/transparencia: <todo lo raro que pasó: retries, applies
  fallidos, datos pre-existentes, accesos caídos — la transparencia aquí
  es lo que hace rápido el gate>
- Plan post-GO: <secuencia exacta que ejecutará al recibir el GO>

NO mergeo nada sin tu GO explícito.
```

Regla de oro del STOP: números, no adjetivos. "Specs en verde" no existe;
"30/30 local + 18 verdes y 2 skips contra prod" sí.

Vigilancia del carril: si `watch-carril.sh` devuelve rc 3 (**agente en reposo sin el estado
esperado**), LEE inmediatamente el recorte con su última respuesta. Responde su pregunta por
la vía del skill, reenvía la instrucción de reanudar con texto verificado desde reposo o
sella el bloqueo en el bus si no puedes resolverlo. Nunca vuelvas a esperar sin más.
Tras aprobar, interrumpir y cambiar modelo/esfuerzo, el paso de relevar el GO se ejecuta
con `relay.sh <carril> audit2dev-resume <informe>`: informe primero, orden explícita de
continuar después. La entrega del informe por sí sola no acredita que esté implementando.

## 3. Comentario-evidencia de cierre

Para ventanas de lanzamiento, épicas y cierres manuales en Linear:

```markdown
## Cierre de <ventana/épica> — <nombre> ✅ (<fecha>, <orden del lead /
   fin de ventana>)

**Lanzamiento/alcance:** <qué quedó vivo, desde cuándo, para quiénes —
con los ids/PRs de las piezas>.

**Evidencia verificada al cierre (comandos ejecutados AHORA):**
- <flag/estado>: <valor por query> ✓
- <métrica de tracción>: <número fresco> (<lectura: qué significa>)
- <invariante>: <verificación> ✓
- Incidencias: <ninguna (confirmación del lead) / listado con su issue>

**Rollback disponible (no usado):** <la llave/mecanismo, tiempo de efecto>.
<Si cierre anticipado:> Cierre anticipado por orden del lead con <X>h de
observación.

<Estado declarado: "Vertical estable — pasa a operación normal" /
"Épica completa — tabla pieza→PR→prod">
```

La prueba del comentario: cada número tiene un comando detrás ejecutado al
escribirlo. Si un dato viene del reporte de un carril, se RE-verifica o se
cita como "según reporte de <carril>" — nunca se disfraza de verificado.

## 4. Brief de alta: Analista de Producción

Plantilla para montar la estación Analista de Producción (torre de observabilidad
24/7 sobre Sentry — doctrina completa en
`references/10-estacion-analista-produccion.md`). Deriva del brief probado el
23-ago-2026 (alta real, sello `SENTRY-ANALISTA-ALTA-OK @02:04Z`).

```markdown
**ANALISTA DE PRODUCCIÓN — alta de estación**

Identidad: torre de coordinación, `Sonnet vigente` + `high` (regla 0
del registro del usuario; CEO usa Opus vigente y los demás roles Sonnet vigente). Mandato: SOLO lees, triajeas y
sellas — NO codeas, NO mergeas, NO despachas trabajo a carriles.

1. Credencial de pozo PROPIA (nunca compartida con otro puesto): token del vendor
   de observabilidad vía `railway variables --service <svc> --json` → header-file
   0600 (`Authorization: Bearer …`) + fichero meta aparte (org/proyecto). **REGLA
   DURA: el token JAMÁS se imprime** en pantalla, logs ni sellos — ningún sello
   de la taxonomía lleva el valor del token ni un fragmento reconocible.
2. Resuelve `$TICK_LOG` con `mktemp "$HOME/.analista-produccion/tick.XXXXXX.log"`
   — creación ATÓMICA e INCONDICIONAL de un fichero único y vacío en CADA
   invocación. NUNCA un fallback `${VAR:-...}` (reutiliza el valor si la variable ya
   quedó definida de una alta previa en la MISMA sesión, reabriendo la
   carrera) ni un path fijo/compartido (`$$`+timestamp puede colisionar entre
   ejecuciones del mismo shell dentro del mismo segundo): un ticker anterior
   sobrevive por `disown`, y si el alta se repite mientras sigue vivo, un log
   reutilizado o compartido sería una CARRERA entre escritores. Arranca el
   **ticker INFINITO** en
   BACKGROUND REAL (con `&` + `disown`, capturando `$TICKER_PID`), con el
   bucle emitiendo `TICK` por `tee` ANTES del `sleep` (primer eco inmediato,
   no a los 5 min) — visible en el pane para el monitor externo Y duplicado al
   log — NUNCA redirigido solo al log: eso deja el pane sin estímulo visible y
   el monitor externo vería staleness con el bucle vivo. VERIFICA con ESPERA
   ACOTADA (segundos) + ASERCIÓN FAIL-CLOSED tras el timeout: la espera sola
   NO decide nada (agotarla sin TICK termina con normalidad) — es
   `grep -q 'TICK' "$TICK_LOG"` Y `ps -p "$TICKER_PID"`, ambas con `exit 1` si
   fallan, las que **abortan el alta** si no hay TICK fresco. Sin el `&` el
   bucle ocupa el foreground y bloquea la estación; sin la aserción posterior
   al bucle, la verificación podría APARENTAR éxito sin ningún TICK. Re-armado
   SIEMPRE en cada eco. El despertador **one-shot queda PROHIBIDO** (murió en
   silencio dos veces la primera noche: mudez de 50 min y de 3h24m — nunca lo
   repitas).
3. Ciclo en cada tick: query (unresolved 24h) → triage (frecuencia contra tu
   **cursor propio**, grupos nuevos/escalados) → sellos (taxonomía abajo). Fija
   el cursor en el primer barrido; avanza en cada barrido siguiente — nunca
   re-triagees grupos ya vistos.
4. Taxonomía de sellos — conjunto CERRADO, cero ruido fuera de él:
   `SENTRY-ANALISTA-ALTA-OK` (alta, one-shot) · `SENTRY-URGENTE-*` (dinero/caída
   → CEO al instante) · `SENTRY-CONSULTA-*` (hallazgo importante → CEO+analista
   deciden JUNTOS issue+pase a producción) · `SENTRY-HEARTBEAT` (cada 4h) ·
   `SENTRY-VERIFICA-<TAL>-OK|CONSULTA` (bajo orden `CEO-SENTRY-VERIFICA-<TAL>`).
5. Verificaciones post-deploy: al recibir `CEO-SENTRY-VERIFICA-<TAL>`, produce un
   veredicto con **NÚMEROS, nunca adjetivos** (ejemplo real: "0 eventos nuevos en
   3h30m" — nunca "parece resuelto").
6. **«No paro jamás»**: auto-verifica el mecanismo del ticker en CADA tick antes
   de reportar. Nunca eres tu propio único vigilante — el CEO arma un monitor
   externo de staleness del pane (>20 min sin cambios = alerta); confírmalo
   armado antes de dar el alta por terminada.
7. <Contexto en-vuelo específico de esta alta: hallazgos ya conocidos, issues
   Linear relacionadas, enmiendas del lead vigentes a la fecha>.

Al completar 1-6: sella `SENTRY-ANALISTA-ALTA-OK` y reporta al CEO.
```

---

## 5. Sello de escalado y de re-acreditación

Dos sellos de formato fijo (se SELLAN con `bus-sellar.sh`, bajo la identidad del propio actor; escribirlos en
el pane no cuenta). Las cláusulas en MAYÚSCULAS no se negocian.

```text
# Escalado: ANTES de esperar una decisión de la capa superior
bash $S/bus-sellar.sh --rol <ROL> --marcador ESCALA-<ROL>-<ref> \
  --nota "BLOQUEO-AUTORIDAD · espera:<rol que decide> · <qué se decide> · default: <qué se hará si nadie responde>"
# El ruling se acusa con:   ACK-<ROL>-<ref>

# Re-acreditación: tras un /clear, un reinicio o una sesión nueva (NO ACREDITADO hasta aquí)
bash $S/reacreditar.sh --rol <ROL> --iniciar          # emite ACRED-<ROL>-<nonce>
bash $S/bus-sellar.sh --rol <ROL> --marcador ACRED-<ROL>-<nonce> --nota "acreditado tras <motivo>"
bash $S/reacreditar.sh --rol <ROL> --verificar        # rc 0 solo con ese sello posterior al cebado
```

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
