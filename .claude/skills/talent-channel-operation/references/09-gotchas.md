# 09 — Índice de diagnóstico (gotchas)

Primer lugar donde mirar ante un síntoma raro en un carril: las tablas mapean síntoma → causa →
acción. **La doctrina NO vive aquí** — vive en el ref dueño de cada fila; este índice solo apunta.

## Table of Contents

- [1. Cómo usar este índice](#1-cómo-usar-este-índice)
- [2. Relay y panes (ref 03)](#2-relay-y-panes-ref-03)
- [3. Auditoría y veredictos (refs 02/04)](#3-auditoría-y-veredictos-refs-0204)
- [4. Entrega draft y PR (v6.0)](#4-entrega-draft-y-pr-v60)
- [5. Modelo, effort y sesión (ref 11)](#5-modelo-effort-y-sesión-ref-11)
- [6. Multi-canal y cola (ref 05)](#6-multi-canal-y-cola-ref-05)
- [7. CI y stack (anexos)](#7-ci-y-stack-anexos)
- [8. Infra del host y flota](#8-infra-del-host-y-flota)
- [9. Gotchas vigentes no tabulares](#9-gotchas-vigentes-no-tabulares)
- [10. Arranque en frío](#10-arranque-en-frío)

## 1. Cómo usar este índice

Buscar el síntoma, saltar al ref dueño (columna Ref) y ejecutar el PROC o helper indicado.
Leyenda: `NN` = `references/NN-*.md` · anexo-TA = el anexo adjudicado (`TCO_ANEXO_FILE`) ·
anexo-BC = `references/anexo-bootcamp-cripto.md` · SKILL = `SKILL.md`.

## 2. Relay y panes (ref 03)

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Paste/relay queda en el composer sin enviarse; pane mudo | La entrega no está confirmada | Escalar conservando el input; `tco_send_submit` rechaza Enter sin propiedad acreditada (§2) | 03 |
| Comando del coordinador bloqueado por el host | Hook PreToolUse: tokens git+push en un compound (incluso dentro de una RUTA) | **PROC-01** (Write para relevos, send atómico, fraseo sin literales) | 03 |
| "Press up to edit queued messages" (cola duplicada) | Reintento ciego de un relay que SÍ había entrado | **PROC-11** (verificar con `Up`, limpiar; una orden de publicación/entrega duplicada NUNCA queda) | 03 |
| Input del pane bloqueado por diálogo de encuesta (transcript `y/n/d`) | El diálogo captura el input | Declinar con `n` (`tco_pane_heal survey`) (§5) | 03 |
| Input del pane bloqueado por encuesta de RATING ("How would you rate…") | La encuesta captura el input e intercepta relays | `tco_pane_anomaly` → `survey-rating`; `tco_pane_heal survey-rating` descarta con `0` (§5) | 03 |
| Relay `lee <ruta>` DUPLICADO en la cola tras reintento | Re-tipeo a ciegas del relay | Dedupe `tco_input_pending_from`: eco pendiente o ambiguo ⇒ rc 2 y escalada sin re-submit ni borrado (§13) | 03 |
| `Enter` del relay se pierde en un TUI ocupado | Enter en la MISMA llamada que el texto | Enter separado real (`_tco_send_text_submit`: texto → sleep → submit) (§13) | 03 |
| Carril idle sin trabajar; ¿parado o parqueado? | Distinguir relay perdido de hand-back real | `tco_carril_parked` (NO-busy + informe REAL + debounce ×2); sin informe ⇒ re-nudge (§13) | 03 |
| Auditor con "Update available!" bloquea el rol | Auto-update de codex intercepta el priming | `tco_codex_update_prompt_from` + `tco_codex_skip_update_and_trust` (Escape/trust) + recargar rol; el loop de ACK de `dispatch.sh` lo salta (§13) | 03 |
| Texto gris (dim `[2m`) tipo "GO/aprobar" en el composer | Sugerencia de **autocomplete** — NO es orden, NO se ejecuta sola, desaparece al escribir | Diagnóstico obligatorio con `tmux capture-pane -p -e`: el gris se ignora; el texto real pendiente o una cola duplicada exige escalada conservando el input (§5) | 03 |
| Prompt "Update available!" del CLI del auditor bloquea el priming de rol ("CLI auditoría no LISTO 90s") | Auto-update del CLI (codex) interrumpe el arranque | Skip (opción 2) + recargar el rol a mano; fix de raíz = deshabilitar auto-update en el golden (`talent-channels`) | 03 |
| Dev implementando sin plan aprobado tras un NO-GO | La opción 4 del diálogo de plan lo sacó de plan mode | **PROC-17** (verificar `plan mode on` ANTES de relevar) | 03 |
| Entrega a un pane muere en silencio ("permission denied" invisible) | `incus file push` NO sobrescribe destinos pre-creados | No pre-crear; vía vigente `tco_relay_file` (**PROC-00** §3) | 03 |
| Carril con un solo pane; gates enviando al vacío | El pane del auditor MURIÓ (crash del CLI) | **PROC-02** (rebuild + rol confirmado antes de re-lanzar) | 03 |
| Un "GO/procede sobre `<sha>`" se dispara en el momento equivocado | Mensaje dejado ENCOLADO en el input del dev | Compositor vacío obligatorio antes de cada relevo; input pendiente ⇒ escalar sin borrar ni enviar; backstop = regla 13 + intake del Mergeador (`headSha==auditedSha`) (§3) | 03 |
| `incus` falla en la sesión del coordinador (máquina recién aprovisionada) | Grupo `incus-admin` inactivo hasta re-login | **PROC-00** §1 (re-login; workaround `sudo`) | 03 |
| Primer dispatch ve el carril OCUPADO sin trabajo real | Sesión idle post-login muestra "bypass permissions" | **PROC-00** §5 (`--force-reset` consciente, tras verificar; [TAL-2276] auto-resetea git pre-preflight tras el gate BD-sync) | 03 |
| Carril marcado "despachado" pero el pane no arrancó el issue | Se confió en la **task list del harness** (no evidencia de pane); bypass no auto-aceptado en builds viejas (2.1.110) o sesión zombi | "Despachado" = **captura del pane dev con `TAL-N` + `plan mode`**; en 2.1.110 enviar **`Down`+`Enter`** para aceptar el bypass y verificar; `tmux kill-server` antes de relanzar (gate de salud post-dispatch) | 02 |
| [Anti-menú] Pane destino con menú abierto (ExitPlanMode, /model, AskUserQuestion); `send-keys` elige opción en silencio | `send-keys` enviado sin verificar el estado previo del pane | `tco_cap_pane` ANTES de cualquier relay/send-keys a pane ajeno; si menú detectado → resolver primero, luego enviar (§2 / §7) | 03/04 |

## 3. Auditoría y veredictos (refs 02/04)

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| INVALID pero el auditor SÍ emitió veredicto | El parser del gate murió; el JSON quedó en el pane | **PROC-03**: `audit-gate.sh --parse-only <carril>` | 04 |
| Veredictos viejos/contradictorios en el scrollback | Bloques de rondas previas o de otra corrida (recycle/compact) | Nonce `run_id`+`artifact_sha`: solo cuenta el bloque MÁS RECIENTE que lo porta | 04 |
| GO de auditoría que no ata la entrega (regla 13 / intake del Mergeador lo rebotan) | `artifact_sha` no es un commit real (se auditó working tree) | Doctrina commit-antes-de-auditar [B10] (§3): el sha declarado = head futuro del PR | 02 |
| STOP-AUDIT no detectado o informe recortado a ojo | Headers variables entre rondas; la frase conversacional del dev no ancla | `relay.sh extract-stop-audit <carril> <outfile>` (§3) | 02 |
| Se auditó un STOP-AUDIT viejo (r1) habiendo un informe más reciente (r3) | Modo de fallo HISTÓRICO del extractor (header fuerte ganaba siempre) — corregido: hoy `tco_extract_stop_audit` ancla el ÚLTIMO marcador (`max()` por línea) y exige pane idle | Verificar versión de `lib.sh` del checkout del coordinador (gotcha §9.1); con lib vigente, el síntoma indica scrollback recortado — re-pedir emisión | 02 |
| Canal en STOP-AUDIT recibe un `continuemos` y se auto-entrega SIN code-gate | Nudge genérico consumido como GO de entrega | GO-FREEZE (ref 02 §3): verificar el estado del pane ANTES de nudgear; entre GO y entrega solo mensajes explícitos | 02 §3 |
| Gate relanzado sale `INVALID` en cadena en el mismo canal | Un `audit-gate.sh <carril>` STALE de una corrida previa sigue vivo e interfiere el pane del auditor | Matar el proc stale **por PID** (`pgrep`+`kill`, excluir self) ANTES de relanzar — nunca `pkill -9` del patrón (§6) | 04 |
| **[TAL-5172]** GO citado FUERA de `verify-handoff.sh` (texto relayado/pegado en un mensaje) resulta ser de OTRO PR | Sha válido pero no verificado contra el PR CITADO — un veredicto "limpio" no prueba pertenencia al PR que se está cerrando | `gh pr view <N> --json headRefOid` de ESE número específico, nunca "algún PR con ese sha"; backstop `git merge-base --is-ancestor <sha> origin/<rama-del-PR>`. Ver regla nombrada en ref 04 | 04 |

## 4. Entrega draft y PR (v6.0)

Los síntomas de **CodeRabbit / merge** (App muda tras rebase, spending cap, flip de
APPROVED, labels REST, ramas con mayúsculas) son ahora del **Mergeador** → skill
`talent-merger` (`references/07-gotchas.md`, PROC-M04/M05/M07). Aquí quedan los de la
entrega:

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Push del canal bloqueado por el hook pre-push | Sentinel `.claude/.draft-handoff` ausente o de un SHA viejo | El dev re-corre `bash scripts/draft-handoff.sh` (gates locales verdes) para el SHA vigente | 02 §4 |
| `draft-handoff.sh` falla en gates locales | typecheck/lint/build en rojo o working tree sucio (cuando el build no está omitido por `TA_DRAFT_SKIP_BUILD=1`, TAL-2820 — flotas débiles) | Corregir ANTES de entregar — la entrega draft no espera CI, por eso los gates locales son obligatorios | 02 §4 |
| `verify-handoff.sh` != 0 en el cierre | HANDOFF ausente/stale/incompleto, closes faltante, PR no-draft | Regla 13: el dev corrige y se re-valida ANTES de reciclar | 02 §4/§6 |
| Draft rebotado por el Mergeador (PROC-M01) | Handoff pobre que pasó la regla 13 | Incidente del coordinador: revisar por qué la validación no lo cazó; el trabajo vuelve vía pool | 02 §6 |
| `draft-handoff.sh` bloquea en el PRIMER despacho de un canal por `?? .claude/tf-manifest.conf` (árbol sucio) | La copia del manifiesto la puso el despacho y el clon no la ignoraba (TAL-8040) | `dispatch.sh` la excluye en `.git/info/exclude` y muere en `[TFM-HYGIENE]` si no queda ignorada; un clon con la copia TRACKED se destrackea a mano (`git rm --cached`) | 02 |
| `core.hooksPath` del canal ≠ `.githooks` (p. ej. `githooks`): pre-push inactivo sin error | Valor mal escrito; el bootstrap solo avisaba (TAL-8040) | `dispatch.sh` lo corrige (`[HOOKSPATH] previo -> .githooks`) si `.githooks/pre-push` es ejecutable; si no, avisa con la causa — restaurar ese hook | 02 |
| Encargo de re-fix de un PR rebotado con findings | Findings del Mergeador sobre un PR ya entregado | Flujo abreviado code-only SIN plan mode (bounce stale + head sin cambios = entrega no-op) | 12 |
| El canal se atasca pidiendo auth de **CR-CLI** durante una entrega draft | Residuo del flujo viejo: el canal cree que debe correr CodeRabbit | El canal NUNCA corre CR en la entrega (Fábrica v2). **Respuesta estándar del coordinador: redirigir a `scripts/draft-handoff.sh`** (draft-handoff no requiere CR y los canales de producción ya no tienen key). El flujo channel-runs-CR del runbook es SOLO para trabajo no-canal | 02 §4 |
| [Bounce-caduca] Re-fix recibido con findings pero el head del PR ya avanzó (rebase o commit del Mergeador post-bounce) | El bounce es stale: los findings apuntan a código que ya no existe en el head vivo | Precondición de re-fix: re-verificar `headRefOid` en VIVO antes de actuar; si difiere del SHA rebotado = no-op documentado (doble regla C2) | 12 |

## 5. Modelo, effort y sesión (ref 11)

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Panel colgado sin producir output | Modelo AGOTADO en la cuenta (el alias del contenedor no pasa `--model`) | Verificar/forzar modelo (`tco_ensure_model`); tras recycle → **PROC-08** | 11 |
| Coding lentísimo ("Mulling" de minutos en pasos triviales) | Effort `xhigh` residual del plan o de un resume | Re-fijar `/effort high` (Regla 0) (§6) | 11 |
| Dev iterando rondas sin converger sobre el mismo residuo | Loop sobre residuos o límite real de capacidad | **PROC-10** (recycle fresco → subir modelo + template → escalar). **Umbral formal (TAL-2675), SOLO el fallback de modelo**: 5ª ronda NO-GO de code-gate sobre el mismo eje → `model="$(tco_model_for_phase fallback)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1` (picker interactivo, nunca `/model` con argumento inline a mano) para ESE fix (contador no se reinicia); el circuit-breaker de PARK sigue siendo criterio CUALITATIVO del coordinador, sin umbral ni cambio | 11 |
| Sesión reciclada retiene contexto del issue anterior | El relaunch hizo RESUME + auto-compact en vez de fresh | **PROC-08** (placeholder de sesión fresca; re-fijar modelo Y effort) | 11 |
| Respuestas lentas y pérdida de hilo con sesión larga | Contexto degradado (>600k tokens) | Sesión fresca: recycle hard + re-dispatch (§6) | 11 |
| Carril arrancó sobre `main` viejo (decenas de commits stale) | Golden viejo + reciclaje sin pull | Freshness del reciclaje: `dispatch.sh` verifica `HEAD == origin/main` (ref 02 §1) | 02 |
| Pane dev parado tras un 529 de Anthropic ("not your usage limit") | Error server-side transitorio (NO rate-limit de cuenta) | **Esperar ~5 min → relevar "continuemos"** (no reiniciar, no re-fijar modelo). El pane del auditor (codex/.1) es inmune a los 529 → las auditorías no se atascan por esto (§ 529 de ref 11) | 11 |
| Pane con `Not logged in` (Claude) o `refresh token revoked` (Codex) | **Muro 1 — auth caída** (cascada de rotación del refresh token) | **Propagar** credencial válida (Claude: `refresh-claude-auth.sh`; Codex: `auth-move.sh move`, nunca fan-out) + "continuemos". Sesión YA atascada logged-out → **RESTART** (no re-lee la cred fresca — T1). NO esperar (no es límite) (§7b, los 4 muros) | 11 |
| Pane con `usage limit · resets <hora>` (mismo día) | **Muro 2 — cap de 5h** | **Esperar** al reset + "continuemos". NO escalar/cambiar cuenta. Los audits de Codex sobreviven → precorrer gates, retener relevos (§7b) | 11 |
| Pane con `weekly limit · resets <día>` | **Muro 3 — cap semanal** | **PARK** (el trabajo local queda a salvo) o escalar a otra cuenta por pozos (reset 7d más cercano — continuidad sin desperdicio); NUNCA esperar días, nudgear `continuemos` ni re-autenticar la misma. Convertir el día con `date` (§7b) | 11 |
| Pane con `429` / `temporarily limiting` | **Muro 4 — sobrecarga transitoria** de la cuenta (N sesiones simultáneas) | **RESTART** de la sesión (relee el disco) + re-despacho **escalonado 2-en-2** (§7c). NO relanzar N canales de golpe | 11 |
| El watchdog marca IDLE-CRÍTICO sobre un canal | El watchdog mide la barra de input, NO el estado real (puede estar en `ExitPlanMode` o en cola FIFO del build-lock = SANO) | Verificar EN VIVO (HEAD+diff sin cambio, sin `flock`/gate, sin STOP-AUDIT, no en menú) ANTES de reciclar; causa-raíz sistémica en reparación → retener recycles (§3) | 11 |
| Cascada de revocación de Codex (varios auditores caen a la vez) | El refresh de Codex es single-use rotativo; un fan-out/COPY re-arma la cascada | Recovery **MOVE** un-login-un-lugar: `codex` como ROOT primero (mata crash 243), confirmar donante VIVO (`codex exec 'PONG'`), `auth-move.sh move`, relaunch escalonado 30-60 s — NUNCA fan-out (§7/§7b) | 11 |
| `dispatch.sh --force-reset` aborta con "N no está en main" tras una ENTREGA | El preflight corre ANTES del recycle y exige el canal ya en `main`; bajo Fábrica v2 el canal se queda en la rama entregada (no cierra el issue) | Workaround manual: `git checkout -f main && git fetch && git reset --hard origin/main && git clean -fd` ANTES de re-despachar. Fix de tooling (recycle-to-main antes del preflight) = follow-up (issue a crear por el Orquestador) | 02 §1 |
| [Build-colgado] `draft-handoff.sh` (o el canal) con build sin output durante >5 min; proceso existe pero mudo | Build colgado: utime+stime de `/proc/<pid>/stat` no avanzan (PID no usa CPU) | Leer `/proc/<pid>/stat` ×2 con ~8 s; si los ticks no suben → colgado: matar + reintentar una vez en frío. 2ª vez el mismo build cuelga → `TA_DRAFT_SKIP_BUILD=1` formal (PROC-10 §build) | 11 §5 |

## 6. Multi-canal y cola (ref 05)

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Dev dice "rebaseado" pero origin no cambia | Rebase local sin publicar | **PROC-18** (`rev-parse` vs origin; publicación con `--force-with-lease`) | 05 |
| `git diff origin/main..HEAD` muestra borrados falsos | Rama BEHIND: ese diff miente | `git show` para el diff real del commit (**PROC-18**) | 05 |
| Lock que no se libera tras un crash del coordinador | Stale-lock | Recuperación por PID muerto / TTL (`TCO_LOCK_TTL`); no borrar a mano | 05 |
| Diálogo de confirmación bloquea el push en SILENCIO (pane "idle" que nunca publica) | Menú del CLI pendiente (checklist R6/settings/guard-push) | Barrer por MENÚS, no solo idle; clasificar antes de confirmar | 05 §2 |

(Los síntomas de merges serializados, ventanas con coordinador paralelo e índice compartido
**salieron de esta estación** en v6.0 —el tooling compartido `scripts/merge-gate.sh` permanece
aquí, ver `SKILL.md`—. La **equivalencia B9** — GO válido tras rebase
estrictamente mecánico — está definida inline en ref 02 §3 y la ejerce la estación.)

## 7. CI y stack (anexos)

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Checks de CI del PR rojos (db-guards, shards e2e) | (v6.0) El canal NO los espera — los diagnostica el Mergeador | `talent-merger` ref 02 §9 (**PROC-M19**) | talent-merger |
| Colisión de timestamps de migración | (v6.0) Los slots del canal son provisionales | El Mergeador renumera contra el ledger real (**PROC-M14**); el canal solo los declara en el HANDOFF | talent-merger |
| Migración destructiva en el encargo | Clasificación del anexo §4 | Declararla en el HANDOFF (`destructive: true`); el GO del lead lo gestiona el Mergeador | anexo-TA |

### 7bis. Code-gates de money-path [TAL-5172]

El auditor de planes que tocan **money-path** (cobro, pagos, comisiones, wallet — SKILL.md regla
dura 4: estos NO los aprueba el auditor pane1, suben al coordinador/lead) razona con esta vara
extra, tomada de incidentes reales (citas a `.claude/memory/gotchas.md` del repo TA):

- **Casts sobre `jsonb` LIBRE sin shape validado por el writer**: un cast directo
  (`(col->>'x')::tipo`) en un read-path de alto tráfico revienta TODA la lectura si UNA fila trae
  un valor malformado — el fix no es solo el cast, es preguntar si el WRITER valida el shape antes
  de insertar (TAL-1226, `gotchas.md:1503`).
- **Error transitorio de BD ≠ resultado terminal**: un `count ?? 0` (u otro fallback silencioso)
  sobre una query que puede fallar transitoriamente convierte "no pude leer" en "el valor es cero"
  — en un handler que puede suspender/downgradear sobre ese cero, dispara una acción terminal falsa
  (gotcha del webhook Stripe, `gotchas.md:360`).
- **FK `ON DELETE` (CASCADE/SET NULL) dispara UPDATE/DELETE que un guard "blanket" de inmutabilidad
  puede bloquear indebidamente**: antes de añadir un `BEFORE UPDATE/DELETE` de inmutabilidad a una
  tabla money-path, mapear qué cascadas entrantes disparan esos eventos — un guard ciego puede
  bloquear un borrado de usuario (GDPR) o una purga legítima (`gotchas.md:726-728`).
- **`db-guards` completo, no parcial, ante cualquier regresión de constraint**: el wrapper
  (`scripts/ci/run-db-guards-local.sh`) es dueño de su stack Supabase efímero; un gate rojo en un
  fixture no relacionado con el cambio en curso puede ser drift real de `main` (no ruido) — no
  descartar sin verificar primero contra `main` limpio (patrón de varios incidentes en
  `gotchas.md` §2026-08).
- **`CREATE OR REPLACE FUNCTION` sobre el cuerpo de un RPC money-path vivo**: cambia la función
  ATÓMICAMENTE pero no reinicia conexiones en vuelo con el plan viejo cacheado — verificar el
  comportamiento post-replace con una invocación real, no solo con el `\df`.

**Carril LIGERO para diffs docs/tests-only**: existe un carve-out diseñado para saltar gates
pesados de `local-gates` cuando el diff es 100% `.md` bajo `docs/`/`.claude/skills/`
(`TF_CARVEOUT_DOCS_ONLY`, `docs/runbooks/local-gates.md` §Carve-out docs-only) — **hoy APAGADO**
(`0`, TAL-3439): el gate corre siempre, el carve-out es teórico hasta su reactivación. No asumir
que un diff docs-only salta gates hoy; verificar el valor vigente de `TF_CARVEOUT_DOCS_ONLY` antes
de razonar sobre qué corrió.

## 8. Infra del host y flota

| Síntoma | Causa probable | Acción / PROC | Ref |
|---|---|---|---|
| Auditores mueren en cadena; `user@` falla en los contenedores | Límite inotify per-uid del HOST agotado (EMFILE) | sysctl persistente (`fs.inotify.max_user_instances` y afines) | skill `talent-channels` |
| Auditor con "refresh token was already used" | Auth clonada del golden: el refresh token es de un solo uso | Login fresco / login por carril (linajes independientes) | skill `talent-channels` |
| Carril parado ≥20 min en un diálogo/confirmación | Send dado por hecho SIN verificar el efecto | Watch activo + verificar el efecto de cada send; revisita ≤5 min (invariante 11) | SKILL |
| Host inalcanzable / ahogado; la flota entera parece caída | Puede ser **RED/D-state** (thrashing), no un reboot real | **Diagnosticar RED/D-state ANTES de asumir caída** (`uptime` + `runnable/total` del loadavg — ver nota abajo); el recovery DIFIERE (drenar vs re-despachar) | skill `talent-channels` |
| Pico de saturación (CPU/IO/red) cuando varios canales compilan a la vez | Builds pesados concurrentes en el mismo host | **Build-lock por máquina**: `flock` sobre un fichero de un **dir del host bind-mounteado en cada canal** (mismo inode → serializa entre contenedores; un path local de cada contenedor Incus NO cruza namespaces, y un lock creado por root debe quedar world-readable/`O_RDWR` para que el uid unprivileged del contenedor lo abra). 1 build/host a la vez (sin FIFO real — `flock` despierta un waiter arbitrario); los devs codean en paralelo. Distinto de la serialización de gates pesados en runners del motor `local-gates` (`talent-merger` `references/08-gates-locales.md` §5 — otro propósito: aislar corridas de gate, no builds de canal). Detalle completo del mecanismo en skill `talent-channels` §Build-lock | skill `talent-channels` |
| `ping` OK (<1 ms) pero ssh hace timeout + tailscale en `relay`; parece host caído | NIC onboard **Realtek r8169** ahogado bajo carga (bug ASPM), NO la máquina | **NO reiniciar a ciegas**: escalera completa de fixes (IP estática ethernet + Wi-Fi OFF → desactivar ASPM del r8169 → dongle USB-ethernet) en skill `talent-channels` | skill `talent-channels` |

**RED/D-state — diagnóstico antes de asumir caída**: un host que no responde o va ahogado NO es
necesariamente un reboot ("crash" ≠ reinicio real). Distinguir con dos sondas, en orden:

1. **`uptime` ANTES de asumir reboot**: si el uptime es alto, el host NUNCA se reinició — lo que
   parece "caída" es saturación (thrashing), no arranque en frío.
2. **`runnable/total` del loadavg** (`/proc/loadavg`): load alto con **~1 runnable** = **D-state**
   (procesos bloqueados en I/O ininterrumpible o **RED estrangulada**), **NO** saturación de CPU.
   Un load de 40 con 1 runnable es espera, no cómputo — matar procesos no lo cura.

El recovery **DIFIERE según la sonda**: RED estrangulada / D-state por I/O → **drenar** (dejar que
la cola de I/O o la red se despeje), NO re-despachar más carga encima; reboot real → **re-despachar**
la flota. Protocolo de rescate ejecutable cuando es thrashing: **pausar todo salvo 1 canal** (drenar
los pares en vuelo, con el checkpoint-commit de arriba protegiendo su trabajo) → esperar a **load <
4** → **matar la causa raíz** → **re-despacho gradual 2 → 4**, verificando que el load se mantiene
sano en cada escalón. Procedimiento 4+4 completo: skill `talent-channels`.

**[TAL-5172] Pool de flota `fleet-slot-1..4`** (`/tmp/host-gate-slots/fleet-slot-{1..4}.lock`,
bind-mount idmapped en los contenedores — exclusión real cross-coordinador, capacidad exacta 4):
uso `flock -n /tmp/host-gate-slots/fleet-slot-N.lock -c "<comando>"` (el comando corre DENTRO del
flock; el slot se libera al terminar, sin reserva por adelantado). Tres trampas verificadas:

1. **Trampa del inode, no del nombre** [corregido — la redacción anterior atribuía el fallo a
   que la ruta no existiera; MEDIDO y es falso, ver oráculo abajo]: `flock` excluye por **INODE**,
   no por el nombre que el llamador pretende usar. Que la ruta no exista de antemano NO es el
   problema — `flock` la crea y, si los DOS procesos apuntan a la MISMA ruta, ambos abren el
   MISMO inode y la exclusión es real, se haya creado el fichero antes o no. El problema real es
   que dos partes deriven RUTAS DISTINTAS para lo que debía ser el mismo slot: cada ruta abre un
   inode distinto, `flock` nunca las ve en conflicto, y el segundo proceso "toma" un lock que no
   compite con nada. La consecuencia se mantiene tal cual estaba escrita y es lo importante para
   el operador: el nombre debe ser EXACTAMENTE `fleet-slot-1.lock`..`fleet-slot-4.lock` bajo
   `/tmp/host-gate-slots/`; cualquier typo (`fleet-slot-01`, ruta relativa, espacio de más) da un
   lock que nadie más comparte y el canal cree tener exclusión cuando no tiene ninguna — solo que
   la causa es la DIVERGENCIA de ruta entre las partes, no la inexistencia del fichero en sí.

   **Oráculo ejecutable** (cualquiera lo re-mide sin fiarse de esta prosa; `rc` de `flock -n`
   sin tubería — 0 = tomó el lock, 1 = rechazado). **NUNCA contra `/tmp/host-gate-slots` —
   es el pool VIVO de la flota real, con slots que otros canales tienen tomados ahora mismo**;
   copiar-pegar el bloque de abajo tal cual, sobre un directorio temporal propio, es justo lo
   que lo hace seguro de re-medir:

   ```bash
   D="$(mktemp -d)"  # NUNCA /tmp/host-gate-slots — ver aviso arriba
   # CASO A — MISMA ruta inexistente, dos procesos: la exclusión SÍ funciona.
   ( flock -n "$D/fleet-slot-1.lock" -c "sleep 3" ) &
   sleep 0.5
   flock -n "$D/fleet-slot-1.lock" -c "echo tomado"; echo "rc=$? (rc_esperado=1, RECHAZADO)"
   wait
   # CASO B — rutas DISTINTAS para el "mismo" slot (el typo real): la exclusión se PIERDE.
   # (directorio nuevo — no se borra nada del caso A, ver trampa 2 abajo sobre por qué NUNCA
   # se borra un fichero de slot)
   D2="$(mktemp -d)"
   ( flock -n "$D2/fleet-slot-1.lock" -c "sleep 3" ) &
   sleep 0.5
   flock -n "$D2/fleet-slot-01.lock" -c "echo tomado"; echo "rc=$? (rc_esperado=0, TOMA — exclusión NULA)"
   wait
   rm -rf "$D" "$D2"  # limpieza del temporal DE PRUEBA, jamás del pool real
   ```

2. **Trampa del borrado con titular vivo — un `rm` "de limpieza" anula la exclusión**: borrar o
   reemplazar el FICHERO del lock mientras alguien lo tiene tomado no libera nada — el titular
   sigue poseyendo su FD sobre el inode viejo (ahora huérfano, sin nombre), y el siguiente que
   pida esa ruta abre/crea un inode NUEVO bajo el mismo nombre. Dos coordinadores acaban creyendo
   los dos que son dueños del slot 1. Medido, aislado, sin tocar el pool real:

   ```bash
   D="$(mktemp -d)"
   ( flock -n "$D/fleet-slot-1.lock" -c "sleep 4" ) &
   sleep 0.5
   flock -n "$D/fleet-slot-1.lock" -c "echo tomado"; echo "rc=$? (rc_esperado=1, RECHAZADO — titular vivo)"
   rm -f "$D/fleet-slot-1.lock"    # "limpieza" — esto es el incidente, no higiene
   sleep 0.2
   flock -n "$D/fleet-slot-1.lock" -c "echo tomado"; echo "rc=$? (rc_esperado=0, TOMA — exclusión PERDIDA pese a que el titular original sigue vivo)"
   wait
   rm -rf "$D"
   ```

   **Regla operativa que se deriva y que hoy no estaba escrita en ningún sitio**: los ficheros
   de `/tmp/host-gate-slots/fleet-slot-{1..4}.lock` **NO SE BORRAN NUNCA**, ni para "limpiar" un
   host que se ve con ficheros viejos. Un `rm` de mantenimiento sobre ese directorio **es un
   incidente de exclusión**, no higiene — mata la garantía para quien lo tenga tomado en ese
   instante sin que ese proceso se entere.

   **Ratchet — una sola función deriva la ruta, nunca se compone en el sitio de llamada**: hoy
   este pool es un patrón MANUAL (`flock -n /tmp/host-gate-slots/fleet-slot-N.lock -c "<comando>"`
   tecleado por el operador/coordinador; no hay wrapper `.sh` en el skill que lo emita — barrido
   confirmado, cero referencias fuera de esta doc y sus punteros en `SKILL.md` /
   `references/05-multicarril-merge-order.md`). Mientras siga siendo manual, la fuente única es
   ESTA LÍNEA — `/tmp/host-gate-slots/fleet-slot-N.lock` con `N` en `1..4`, copiada literal, nunca
   retipeada — y **no se añade un test que vigile código que no existe** (sería cobertura
   inventada, no real). El día que esto se codifique (wrapper `.sh` o función en `lib.sh`), esa
   función pasa a ser la ÚNICA que compone la ruta — ningún sitio de llamada la construye a mano
   — y ENTONCES corresponde un test que la ejercite con los tres casos de arriba.
3. **Antipatrón histórico — namespace de filesystem no cruza Incus**: un `flock` sobre un path
   DENTRO del propio contenedor (sin bind-mount) no serializa nada entre contenedores — cada canal
   ve y bloquea solo su propio fichero. Causó incidentes pasados de saturación por builds
   concurrentes pese a "tener un lock" — no reintroducir; el bind-mount idmapped es lo que hace el
   inode compartido entre contenedores.

Bonus de C1: `limits.memory` bajo (6 GiB) causa GC thrash, builds de ~25 min e `incus exec`
colgado; valor correcto = 12 GiB. Si un canal no responde: `incus config show <canal> | grep
limits` ANTES de asumir carga del host.

## 9. Gotchas vigentes no tabulares

Canónicos AQUÍ (no tienen ref dueño mejor):

1. **⚠️ `git checkout main` en el checkout del COORDINADOR reintroduce bugs del skill sin
   merge.** Incidente real (2026-07-02): tras mergear un PR de un carril, el coordinador
   sincronizó `main` en SU propio checkout — el mismo desde el que corren los scripts del
   skill — y el siguiente `audit-gate.sh` corrió con `lib.sh` VIEJO: un bug ya resuelto en la
   rama de fixes volvió a fallar en silencio. **Regla dura**: el checkout del coordinador que
   ejecuta los scripts NUNCA queda en `main` mientras haya fixes del propio skill sin mergear.
   Si hay que sincronizar `main` (post-merge), hacerlo y LUEGO volver/rebasar la rama de
   trabajo (`git checkout <rama-fixes> && git rebase main`) ANTES de correr cualquier
   `audit-gate`/`dispatch`/`merge-gate` — o, mejor, fusionar esa rama de fixes cuanto antes.
2. **Kill host-side SIEMPRE por PID y por EJECUTABLE, nunca `pkill -f`/`pgrep -f` sobre la línea de
   comandos.** El patrón aparece en la propia línea de comandos del `pkill` → puede matar el shell que lo
   lanza (visto: `exit 144`), y sobre el argv completo alcanza `~/.codex`, `tail -f codex.log` o el lector de
   stdout (SIGPIPE → rc 141 tras `DONE`, TAL-8042). El reciclaje casa el **nombre del ejecutable**
   (`TCO_AGENT_PROC_PAT` = ERE anclada, p. ej. `claude|codex`; ref 11 §3). Cualquier kill en el host:
   `pgrep -u <usuario>` + filtro por `/proc` + `kill` por PID excluyendo ancestros, grupo y sesión.
3. **`/compact` remoto es frágil con shell/turno activo (F1 2026-07-14).** Vía tmux NO prende si
   el agente tiene un shell de background corriendo o está mid-turno: se ENCOLA como mensaje
   fantasma ("Press up to edit") y el dropdown de slash-commands confunde el envío. FIX fiable:
   el agente se AUTO-compacta en punto limpio (idle, sin shell), habiendo escrito antes su
   COMPACT-READY (texto de regreso) al log; primera acción post-compact = **paso-0** (doctrina
   canónica en `talent-context` ref 03) — leer el tail del log + re-armar el monitor (no
   sobrevive al compact) son parte de ESE paso-0, no un sustituto suyo. **Umbral 60 %** (protocolo
   del lead; doctrina canónica en `talent-context`,
   supersede el >70 % que decía antes esta nota) — ni antes por pánico (los agentes tienden a
   auto-diagnosticarse "crítico" al ~43 %, hay margen real), ni tan tarde como el >70 % que dejaba
   gates a medias por contexto/RL.
4. **El coordinador relanza su `monitor.sh` tras CADA compact/reinicio.** Un monitor muerto =
   coordinador que se para ~25 min en cada hueco (no despierta con los STOP-AUDIT de sus
   canales) y canales esperando plan-gate con el menú arriba. Síntoma desde fuera: narrativa
   "N/N productivos" con panes de canal quietos en ExitPlanMode.

## 10. Arranque en frío

«Arranque en frío» → ver **PROC-00** en `references/03-mecanica-tmux-incus.md`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
