# 12 — Re-fix de un PR rebotado (code-only, SIN plan mode)

Flujo abreviado para cuando el trabajo que llega (vía pool del Orquestador) es **fijar los findings
de un PR ya entregado y rebotado** — no un encargo nuevo. No hay diseño que planificar: los findings
SON el scope. Se despacha **directo a código** (sin Fase A / plan mode), conservando el code-gate.

**Modelo del re-fix (modelo-por-fase, TAL-2675)**: al no haber Fase A, **no hay GO de plan** sobre el
que colgar el switch Opus vigente→Sonnet vigente de `references/11-modelo-effort-y-recycle.md` §6 — ese switch está
atado a la transición plan→GO, que este flujo no tiene. El re-fix corre **directo en el modelo de
CODING = `Sonnet vigente` `high`** desde el arranque de este procedimiento manual (NO el `dispatch.sh` de plan
mode del despacho normal — reciclaría el clon a `origin/main` y perdería la rama del PR, ver
precondición arriba). El coordinador fija el modelo/effort sobre el pane con
`model="$(tco_model_for_phase coding)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1`
y `tco_set_effort <carril> <pane> high` (cada uno su propio diálogo modal, confirmado
y verificado — coreografía de ref 11 §6) **antes** de entregar el brief code-only del paso 2. El
fallback de la 5ª ronda (ref 11 §5) aplica igual: el re-fix también acumula rondas de code-gate sobre
su eje, y a la 5ª NO-GO sin converger el coordinador sube el fix a Opus vigente `high` con la misma
coreografía. `dispatch.sh` no cambia — este procedimiento no lo usa.

**Población objetivo (excepción, no la norma)**: bajo la doctrina estándar del Mergeador los
findings code-only se resuelven en SUS canales de refactorización (regla 5 de `talent-merger`) y
NO vuelven a esta estación. Este procedimiento cubre la **EXCEPCIÓN** en que la estación opta por
rebotar con findings code-only (falta de capacidad, ruling del Orquestador, régimen de drenaje) —
ver `talent-merger` ref 05 para la frontera refacto-vs-bounce.

## Precondición: ¿el bounce sigue vivo?

Antes de despachar, verificar contra el estado VIVO del PR:

1. **¿El head cambió desde el bounce?** Si el `headRefOid` actual ya no es el rebotado y los
   findings apuntan a código que ya no existe → el bounce es **stale**: la entrega correcta es un
   **no-op documentado** (comentario en el PR: "bounce stale, head avanzó a `<sha>`"), no un re-fix.
2. **¿Hay findings concretos y legibles?** Un bounce sin findings accionables (p. ej. referencia a
   un review CR-CLI local nunca posteado) se devuelve al Orquestador para que el Mergeador relaye
   los findings VERBATIM en el cuerpo — no se adivina qué fijar.
3. **¿El Mergeador sigue dueño del PR?** Colisión estación↔coordinador: si `isDraft=false` o el
   head avanzó por acción de la estación → **stand-down** (T5, `references/05` §2).

**[C2] Doble regla — re-verificar la premisa ANTES de actuar**: cada uno de los 3 checks arriba
re-verifica una premisa del bounce contra el estado VIVO. Si el estado vivo contradice la premisa
del Orquestador (p. ej. el bounce dice "finding X en archivo Y" pero ese archivo ya no existe en
el head vivo, o el finding fue introducido por un commit POSTERIOR al bounce que el Mergeador ya
incluyó) → **no adivinar**: escalar con citas literales del estado vivo (output de `gh pr view`,
`git log --oneline`, `git diff`) y esperar instrucción. El re-fix SOLO avanza con premisas VIVAS.
Evidencia: PR #1170 (bounce stale por rebase del Mergeador post-bounce) y PR #1217 (findings que
apuntaban a código ya eliminado en un commit posterior al bounce).

## Flujo

1. **Capturar `$EXPECTED_OID` ANTES de tocar el árbol** = el `headRefOid` vivo del PR
   (`gh pr view <N> --json headRefOid`) — es el SHA rebotado que el push del paso 4 ligará al
   lease. **Luego** checkout de la RAMA del PR (no `main`) y **verificar que el árbol obtenido
   coincide con ESE OID**:

   ```bash
   EXPECTED_OID="$(gh pr view <N> --json headRefOid -q .headRefOid)"   # estado vivo, PRIMERO
   git fetch origin <rama>
   git checkout <rama> && git reset --hard "$EXPECTED_OID"             # árbol basado en EXPECTED_OID exacto
   test "$(git rev-parse origin/<rama>)" = "$EXPECTED_OID" || { echo "el remoto avanzó → stand-down/retry"; exit 1; }
   ```

   Capturar el OID **después** del fetch/reset dejaría una carrera: si el Mergeador avanza el PR
   entre el fetch y la captura, el árbol quedaría basado en el OID viejo pero el lease se ligaría
   al nuevo → el push sustituiría el avance del Mergeador. Orden correcto: **OID vivo → fetch →
   reset a ESE OID → assert `origin/<rama> == EXPECTED_OID`**. Cualquier diferencia = retry (re-leer
   el OID) o **stand-down** (es el Mergeador tomando el PR — T5).
2. **Despacho code-only** (sin plan mode). Brief canónico al dev:

   > Lee `gh pr view <N> --comments`. Fija SOLO los findings de severidad major del último bounce
   > — nada más (cero refactors oportunistas). Commit con el fix, working tree limpio, y declara
   > STOP-AUDIT con el sha.

3. **Code-gate normal** (`audit-gate.sh <carril> code …`) sobre el **HEAD definitivo**: el
   auditor valida que el diff fija exactamente los findings y nada más. Loop hasta **GO**.
4. **Entrega — el sentinel va ANTES del push** (el hook pre-push exige `.draft-handoff`
   vigente para el SHA que se empuja; emitirlo después = push rechazado o tentación de
   bypass). Orden estricto:
   1. GO del code-gate sobre el HEAD definitivo (paso 3).
   2. `bash scripts/draft-handoff.sh` sobre working tree LIMPIO → sentinel para ESE SHA.
   3. **RE-VALIDAR la propiedad del PR EN VIVO, inmediatamente antes del push** (la ventana
      checkout→dev→audit→gates es larga: el Mergeador pudo tomar el PR — T5). Leer
      `gh pr view <N> --json headRefOid,isDraft`: si `headRefOid` **≠ el SHA rebotado que
      capturaste al inicio** (`$EXPECTED_OID`) o `isDraft=false` → **STAND-DOWN**, no pushes
      (el PR fue cedido/avanzado por la estación).
   4. `git push --force-with-lease=<rama>:$EXPECTED_OID <remote> HEAD` — el lease se liga
      **explícitamente al SHA rebotado esperado** (el `--force-with-lease` pelado usa el
      remote-tracking ref local, que un `git fetch` intermedio habría movido, anulando la
      protección; y un cambio solo en `isDraft` NO lo captura el lease). Divergencia → el
      push falla (correcto: stand-down).
   5. **Re-estampar el HANDOFF** (bloque machine-readable con el `head_sha` nuevo).
5. **Verificación**: `verify-handoff.sh <pr>` en **poll-hasta-0** (el re-stamp puede tardar en
   reconciliar; el script ya valida `head_sha == headRefOid` en su instantánea) + los checks
   vivos de la regla 13 (re-lectura posterior del head como fence anti-TOCTOU + cruce
   `migration_slots` ↔ ficheros reales; `references/02` §4).
6. Cierre normal del encargo (`references/02` §6): el merge sigue siendo del Mergeador.

## Reglas duras del re-fix

- **SOLO los findings del bounce** — el re-fix no es una ventana para "mejorar" el PR: cada línea
  extra mueve el head auditado y agranda el diff que la estación debe re-validar.
- **Un bounce stale con head sin cambios locales = entrega no-op** — documentar y devolver; no
  fabricar commits vacíos para "cerrar".
- **Nunca plan mode**: si al leer los findings el fix resulta ser de DISEÑO (no code-only), eso es
  un defecto de diseño → bounce-to-pool del Orquestador como encargo nuevo con Fase A completa, no
  un re-fix.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
