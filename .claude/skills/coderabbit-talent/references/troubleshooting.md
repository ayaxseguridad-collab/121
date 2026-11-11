# Troubleshooting

> `last_verified: 2026-09-22` (refresco parcial ABC-5478 — solo §3 y §6 re-verificados hoy; el resto
> conserva su fecha de verificación original citada inline por hecho)

Errores comunes con CodeRabbit (App + CLI) en este repo y cómo resolverlos. Reescrita contra el estado
de septiembre 2026: vocabulario de planes Essentials/Team/Advanced/Enterprise, CLI 0.7.x, y el gate
CR-CLI real del repo (`scripts/cr-review.sh`).

## Tabla de contenidos

1. [Diagrama: dónde mirar primero](#1-diagrama-dónde-mirar-primero)
2. ["No review appeared on my PR"](#2-no-review-appeared-on-my-pr)
3. ["El push se bloquea sin razón aparente" (gate CR-CLI / draft / auditoría)](#3-el-push-se-bloquea-sin-razón-aparente-gate-cr-cli--draft--auditoría)
4. ["Rate limit exceeded — el bot pide esperar"](#4-rate-limit-exceeded--el-bot-pide-esperar)
5. ["El status CodeRabbit quedó en FAILURE" — no es un veredicto](#5-el-status-coderabbit-quedó-en-failure--no-es-un-veredicto)
6. ["unknown option '--type'" (manual/ad-hoc) — en este repo ya está RESUELTO](#6-unknown-option---type-manualad-hoc--en-este-repo-ya-está-resuelto)
7. ["Review skipped — Auto reviews are limited based on label configuration"](#7-review-skipped--auto-reviews-are-limited-based-on-label-configuration)
8. ["El CLI queda en silencio 2-3 minutos" — no es un cuelgue](#8-el-cli-queda-en-silencio-2-3-minutos--no-es-un-cuelgue)
9. ["CR y el CLI dan hallazgos distintos sobre el mismo diff"](#9-cr-y-el-cli-dan-hallazgos-distintos-sobre-el-mismo-diff)
10. [El CR-CLI no converge (findings que aparecen y desaparecen)](#10-el-cr-cli-no-converge-findings-que-aparecen-y-desaparecen)
11. ["Por qué mi refill de reviews es más lento de lo esperado"](#11-por-qué-mi-refill-de-reviews-es-más-lento-de-lo-esperado)
12. ["CR comenta lo mismo que ya arreglé"](#12-cr-comenta-lo-mismo-que-ya-arreglé)
13. ["Language es-ES pero el review está en inglés"](#13-language-es-es-pero-el-review-está-en-inglés)
14. ["CR no aprende — repite sugerencias ya rechazadas"](#14-cr-no-aprende--repite-sugerencias-ya-rechazadas)
15. [`docstrings` marca falsos positivos en archivos de test](#15-docstrings-marca-falsos-positivos-en-archivos-de-test)
16. [`code_guidelines` no gobierna el código que esperabas](#16-code_guidelines-no-gobierna-el-código-que-esperabas)
17. [`chat.integrations.linear` crea issues fuera del flujo de Linear](#17-chatintegrationslinear-crea-issues-fuera-del-flujo-de-linear)
18. [`enable_prompt_for_ai_agents: false` mata el comando `resolve` del skill](#18-enable_prompt_for_ai_agents-false-mata-el-comando-resolve-del-skill)
19. ["Rate limit al hacer muchas queries GraphQL"](#19-rate-limit-al-hacer-muchas-queries-graphql)
20. ["CR comentó un secret, ¿qué hago?"](#20-cr-comentó-un-secret-qué-hago)
21. ["CR bloquea merge pero no veo qué hay que arreglar"](#21-cr-bloquea-merge-pero-no-veo-qué-hay-que-arreglar)
22. ["Quiero desinstalar CR de un repo temporalmente"](#22-quiero-desinstalar-cr-de-un-repo-temporalmente)
23. ["Cómo sé qué plan tiene esta organización?"](#23-cómo-sé-qué-plan-tiene-esta-organización)
24. [Postura de seguridad del vendor](#24-postura-de-seguridad-del-vendor)
25. ["Claude Code no encuentra esta skill"](#25-claude-code-no-encuentra-esta-skill)
26. [Recursos adicionales](#26-recursos-adicionales)

## 1. Diagrama: dónde mirar primero

```text
  algo falla con CodeRabbit
     │
     ├─ ¿el push se rechaza? ──────────────────────▶ §3 (gate CR-CLI / sentinel)
     ├─ ¿no aparece review en el PR? ───────────────▶ §2 / §7 (Review skipped)
     ├─ ¿"Rate limit exceeded" o check en FAILURE? ─▶ §4 / §5 (FAILURE ≠ veredicto)
     ├─ ¿flags del CLI que ya no existen? ──────────▶ §6 (--type retirada)
     ├─ ¿findings que van y vienen entre corridas? ─▶ §10 (no converge)
     └─ ¿CLI y App discrepan sobre el mismo diff? ──▶ §9 (comportamiento reportado, no bug puntual)
```

## 2. "No review appeared on my PR"

Causas en orden de probabilidad:

### 2.1 El PR está en draft

CR ignora drafts por default (`reviews.auto_review.drafts: false` es el default oficial). Opciones:

- Marcar el PR como "Ready for review".
- O habilitar review de drafts en `.coderabbit.yaml`:

  ```yaml
  reviews:
    auto_review:
      drafts: true
  ```

En este repo, el `.coderabbit.yaml` vivo usa exactamente `drafts: false` a propósito (Modelo CR 2.0,
ABC-1502): el PR draft de un canal NO debe disparar el App — el consumo de CR es exclusivo del
Mergeador. No cambiar este default sin decisión del dueño de esa config.

### 2.2 El target branch no está en `base_branches`

Si tu `.coderabbit.yaml` restringe `reviews.auto_review.base_branches` y tu PR apunta a una rama fuera
de esa lista, CR no revisa. Añadir la rama a la lista.

### 2.3 `path_filters` excluye todos los archivos cambiados

Verifica que los paths del PR no estén completamente excluidos por el YAML. Forzar un review manual
para ver el comportamiento (solo si tienes autorización para gastar cuota — ver Cross-Skill de
`SKILL.md`):

```bash
gh pr comment <PR> --body "@coderabbitai review"
```

Si CR responde "No files to review" o similar, el problema es `path_filters`.

### 2.4 Rate limit del plan alcanzado

Ver §4 y §5 — el bot puede haber dejado un status `FAILURE` que no es un veredicto de review.

### 2.5 Título del PR matching `ignore_title_keywords`

Si configuraste `reviews.auto_review.ignore_title_keywords: ["WIP", "DO NOT MERGE"]` y tu PR tiene esa
palabra en el título, CR lo skipea. Renombrar o remover keyword.

### 2.6 Webhook failure entre GitHub y CR

- GitHub repo → Settings → Webhooks → buscar el de `coderabbitai`.
- Ver "Recent Deliveries". Si hay 5xx consistentes, es downtime de CR (ver §24 y
  <https://status.coderabbit.ai> — CodeRabbit confirmó un "major outage" el 2026-09-01 vía su cuenta
  oficial en r/coderabbit, fuente comunitaria consultada 2026-09-05).

## 3. "El push se bloquea sin razón aparente" (gate CR-CLI / draft / auditoría)

**Síntoma:** `git push` se rechaza con un mensaje del hook `.githooks/pre-push`, aunque el código
compila y no tocaste nada de CodeRabbit.

**Causa:** el gate CLI obligatorio pre-push del repo (ABC-1518) exige un **sentinel válido para el OID
exacto** que empujas, atado además a la **rama de destino** en la ruta draft (función `draft_valid_for()`
de `.githooks/pre-push`, verificado con `grep -n 'draft_valid_for()' .githooks/pre-push` 2026-09-22 —
valida OID+ref, no solo OID) — y no hay ninguno vigente:

- Ruta clásica (fuera del sistema de canales): falta o está caduco `.claude/.cr-review-ok` (SHA, sin
  rama).
- Ruta draft (sistema de canales / Fábrica v2): falta `.claude/.draft-handoff` para ese OID+rama.
- **Gate 1 de auditoría (ABC-5574, solo alcanza a la ruta clásica)**: si `.claude/.audit-go` existe pero
  está corrupto, o coincide en SHA con tu push pero fue emitido para OTRA rama (`audit_disputed_for()`),
  el push se BLOQUEA aunque tu `.cr-review-ok` propio sea válido — mensaje explícito de "DISPUTA" en la
  salida del hook.

Cada commit nuevo invalida el sentinel del SHA anterior — hay que re-generarlo.

**Solución:**

- Fuera de canales: `bash scripts/cr-review.sh` (del repo, NO de este skill) y volver a empujar.
- En un canal: `bash scripts/draft-handoff.sh` y empujar la rama draft.
- Si el bloqueo es por disputa de `.audit-go`: empujar a la rama que el GO autorizó, o pedir/emitir un
  GO nuevo para tu rama con `bash scripts/audit-go.sh` (del repo) desde ahí.
- Si el CLI no está disponible, pedir waiver al coordinador — **no** auto-certificar que el gate pasó
  (doctrina "no self-report gates"; el sentinel de archivo es la única evidencia válida).
- Salida consciente de emergencia (queda en el reflog): `git push --no-verify`.

Detalle completo del contrato de artefactos: `references/gate-cli-del-repo.md`. Mecanismo narrado:
`docs/runbooks/coderabbit-cli-pre-pr.md`.

## 4. "Rate limit exceeded — el bot pide esperar"

El bot postea/edita un comentario `> [!WARNING] Rate limit exceeded` con la espera exacta. Claves:

1. **El review bloqueado NO se reintenta solo.** Tras la espera, re-disparar con `@coderabbitai review`
   o empujar un commit nuevo.
2. **Ver cuota sin gastarla**: `@coderabbitai rate limit` (el walkthrough de cada review también la
   muestra).
3. **Si las esperas se alargan más de lo normal**: es la Fair Usage Policy espaciando el refill por
   actividad sostenida de tu identidad. Reducir actividad lo restaura con el tiempo.
4. **Reducir consumo**: batching de pushes, `auto_pause_after_reviewed_commits` bajo, `ignore_usernames`
   para bots de deps, drafts/WIP. Playbook completo: `references/rate-limits.md`.

## 5. "El status CodeRabbit quedó en FAILURE" — no es un veredicto

**Síntoma:** el check `CodeRabbit` en el PR muestra `state: FAILURE` (o el texto "Review limit
reached" / "Next review available in: N minutes"), y un merge-gate fail-closed que exige ese status en
verde bloquea el merge aunque el código esté correcto.

**Causa:** al agotar la cuota de reviews, CodeRabbit publica su commit-status con `state: failure` —
NO un status neutral. Un caso documentado en la comunidad (issue pública, jul-2026, 18 comentarios)
describe exactamente este patrón: `mergeStateStatus` degrada a `UNSTABLE` y el gate reintenta en cada
push hasta que la ventana de rate-limit libera cupo — el gate no queda deadlockeado para siempre, pero
sí falla en cada intento mientras dura la ventana. Fuente:
<https://github.com/devantler-tech/.github/issues/101> (creada 2026-07-14, consultado 2026-09-05).

**Tratamiento correcto**: si `merge-gate.sh`, el agregador de `local-gates` o cualquier check que lee el
status `CodeRabbit` lo ve en `FAILURE` con texto de rate-limit, **NO tratarlo como review reprobada** —
es infraestructura de cuota, no un veredicto de código. Reintentar tras la ventana indicada en vez de
escalar como bug funcional. El check dedicado «Review rate limited» de CodeRabbit está diseñado para
**pasar por diseño** precisamente para no bloquear merges en ramas protegidas
(<https://docs.coderabbit.ai/management/rate-limits>, consultado 2026-09-05) — la contradicción de arriba
es con el status genérico `CodeRabbit`, no con ese check específico.

## 6. "unknown option '--type'" (manual/ad-hoc) — en este repo ya está RESUELTO

**Síntoma:** invocaste `coderabbit review --type committed` a mano (patrón heredado de la CLI 0.6.x) y en
vez de un error viste que el review cubrió también cambios sin commitear, o `coderabbit config validate
--type committed` falló con `error: unknown option '--type'`.

**Causa:** la CLI retiró `--type` en la versión **0.7.0** (2026-07-22). Desde entonces el alcance por
defecto de `coderabbit review` es **todos los cambios trackeados** (comprometidos + staged +
sin-stagear); las flags nuevas para acotar son `--committed`, `--uncommitted`, `--include-untracked`.
Verificado en vivo el 2026-09-22 contra el binario **0.8.0**: `coderabbit review --help` no lista
`--type` en ninguna forma, y `coderabbit config validate` SÍ valida flags (falla con `unknown option`),
pero `coderabbit review` **las ignora en silencio** — no aborta, amplía el alcance sin avisar. Mismo
comportamiento que el verificado el 2026-09-05 contra 0.7.6, sin cambios.

**Este repo YA NO usa `--type` hardcodeada — RESUELTO (ABC-5477, PR #2290, fundida 2026-09-07)**:
`scripts/cr-review.sh` resuelve la flag de alcance en vivo con la función `cr_scope_flag()` (lee
`coderabbit --version` y elige `--committed` si ≥0.7.0 o `--type committed` si <0.7.0; fail-closed si la
versión no parsea como `N.N.N`), verificado con `grep -n 'cr_scope_flag' scripts/cr-review.sh`
2026-09-22. El golden de canales sigue pineando la CLI en **0.6.5** (`CR_CLI_VERSION` en
`talent-channels/scripts/02-golden.sh`, verificado hoy) — subir ese pin es ABC-5480 (Todo), sin relación
ya con este riesgo porque `cr_scope_flag()` se adapta a cualquier versión. Detalle:
`references/gate-cli-del-repo.md` §5.

## 7. "Review skipped — Auto reviews are limited based on label configuration"

Es el mensaje **normal** del App cuando `reviews.auto_review.enabled: false` y el review depende de un
label (`labels: [...]`) para dispararse — el modelo «CR 2.0» que usa este repo (opt-in por label
`cr-review`, aplicado solo por el Mergeador en su ruta de fallback). No es un error: verificado en 8
PRs mergeados el mismo día en este repo, el App responde siempre con ese bloque + checkbox
"🔍 Trigger review" + un bloque "⚙️ Run configuration" (Path, Review profile, Plan, Run ID) — la
autorización real de esos PRs vino siempre del CLI, posteada manualmente por el Mergeador.

## 8. "El CLI queda en silencio 2-3 minutos" — no es un cuelgue

Es normal en PRs grandes; CodeRabbit se posiciona deliberadamente como "Slow AI". Si necesitas
diagnosticar, los logs locales del CLI viven en `~/.coderabbit/logs/`. Si consistentemente pasan más de
10-15 minutos en diffs pequeños, revisar `~/.coderabbit/logs/` antes de asumir que el proceso murió.

## 9. "CR y el CLI dan hallazgos distintos sobre el mismo diff"

**No es un bug puntual — es un comportamiento reportado por la comunidad.** Un usuario documentó que el
review del CLI (invocado localmente) y el review remoto del App dieron resultados distintos sobre el
mismo diff; otros usuarios atribuyeron la causa a routing/harness distintos entre ambos productos.
Fuente: hilo comunitario, 2026-07-10 (consultado 2026-09-05).

**Impacto operativo en este repo**: la política «el CLI limpio corrido por el Mergeador AUTORIZA el
merge en cualquier superficie» (CLAUDE.md regla 16, ADR-0043) es una **decisión de producto de la
fábrica** (cuidado extra + clasificación de superficies sensibles), NO una garantía técnica de
CodeRabbit de que CLI y App sean matemáticamente equivalentes. Por eso las superficies sensibles
(auth/RLS, migraciones, money-path) siguen bajo cuidado operativo reforzado aunque el CLI ya haya
aprobado — ver `talent-merger` ref 03 «superficies sensibles».

## 10. El CR-CLI no converge (findings que aparecen y desaparecen)

**Síntoma:** corridas sucesivas del CLI sobre el MISMO commit dan conjuntos de findings distintos (p.
ej. 3→1→3→2→1), o un finding se reformula con redacción distinta cada vez y `--accept-debt` nunca lo
captura.

**Causa:** el CR-CLI **no es determinista** — comportamiento medido repetidamente en la casa (13
corridas en un solo skill nuevo el 2026-09-05; caso con 7 rondas de reformulación del mismo finding).
La huella de known-debt (ABC-2272) hashea texto: si el CLI reformula el mismo finding, el fingerprint
no coincide y la deuda no lo captura.

**Tratamiento**: tope de corridas por encargo (no reintentar indefinidamente), checklist de seguridad
de los ejemplos ANTES de la primera corrida, triage real + waiver explícito del lead cuando el
fingerprint no converge — nunca «una corrida más» como respuesta por defecto. Detalle del mecanismo
(`--list-findings`, `--accept-debt`, binding tree+base+fp) en `references/gate-cli-del-repo.md`.

## 11. "Por qué mi refill de reviews es más lento de lo esperado"

**Causa:** el throttling escalonado de Fair Usage (ventana rolling de 7 días) reduce las reviews/hora
disponibles a medida que sube el volumen acumulado del developer en esos 7 días. No es un bug: es la
política de Fair Usage espaciando reviews de una identidad de alto volumen.

**Solución:** consultar la tabla escalonada en `references/rate-limits.md`; espaciar los pushes
(batching > goteo) y/o `@coderabbitai pause` si te acercas al escalón superior. `@coderabbitai rate
limit` muestra la cuota sin consumir review.

## 12. "CR comenta lo mismo que ya arreglé"

### 12.1 No disparaste re-review después de tu push

Forzar: `gh pr comment <PR> --body "@coderabbitai review"`.

### 12.2 El fix no está en el diff que CR ve

Verifica con `gh pr diff <PR> | grep -A2 "archivo_que_fijaste"`.

### 12.3 El thread no se resolvió

Aunque fixeaste, si el thread sigue "abierto" CR puede re-comentar. Resuelve con
`bash scripts/resolve_thread.sh <thread_id>`.

## 13. "Language es-ES pero el review está en inglés"

CR respeta `language: es-ES` pero puede dejar nombres de APIs/funciones/errores en inglés (correcto).
Si TODO el review está en inglés, verifica que `.coderabbit.yaml` está en la raíz del repo y que la
rama del PR lo trae. Debug: `gh pr comment <PR> --body "@coderabbitai configuration"`.

## 14. "CR no aprende — repite sugerencias ya rechazadas"

El learning del knowledge base requiere: `knowledge_base` sin `opt_out` (default activo), threads
resueltos **con razonamiento** (challenge con `@coderabbitai <razón>`), tiempo (el learning se
actualiza en background), y un plan de pago. Después de 2-4 semanas de uso activo, si sigue repitiendo:
usar más `@coderabbitai` replies explícitos con razones, o `reviews.instructions`/`path_instructions`
explícitas — más confiable que esperar que el KB aprenda.

## 15. `docstrings` marca falsos positivos en archivos de test

**Síntoma:** el check `pre_merge_checks.docstrings` (modo `warning`/`error`, `threshold` default 80)
cuenta callbacks `test(...)`/`beforeEach`/`afterEach` de un archivo de test como "funciones sin
JSDoc", generando cobertura 0-50% en PRs que solo añaden tests.

**Causa:** `pre_merge_checks.docstrings` solo acepta `mode` y `threshold` — no tiene `path_filters`
propio. El `path_filters` de nivel superior excluye el path de TODO el review (seguridad incluida), lo
cual es demasiado agresivo si solo se quiere silenciar `docstrings` en `tests/**`. Fuente: caso
comunitario documentado + schema oficial (consultado 2026-09-05).

**Mitigación**: `mode: off` global + `path_instructions` de contenido para el check equivalente, o
aceptar el ruido en tests y usar `instructions:` negativas para que el reviewer conversacional lo
ignore — el pre-merge check gate seguirá viendo el falso positivo hasta que el vendor añada
path-scoping propio.

## 16. `code_guidelines` no gobierna el código que esperabas

CodeRabbit auto-detecta `**/CLAUDE.md`, `**/AGENTS.md`, `.github/copilot-instructions.md`,
`**/.cursorrules`, `**/GEMINI.md`, entre otros, **sin configuración**. El scoping es **por
directorio**: una guía aplica solo a su propio directorio y subdirectorios, salvo que se use la forma
objeto `{files, applyTo}` para mapearla a otros paths. Si `knowledge_base.code_guidelines.filePatterns`
lista strings planos como `"docs/decisions/**"`, esa guía queda scopeada a `docs/decisions/**` —
**no** a `src/**` ni a `supabase/**`, que es donde vive el código de producto. La forma correcta:

```yaml
knowledge_base:
  code_guidelines:
    filePatterns:
      - files: "docs/decisions/**/*.md"
        applyTo: "src/**,supabase/**"
```

Fuente: <https://docs.coderabbit.ai/knowledge-base/code-guidelines> (consultado 2026-09-05), que
advierte explícitamente: *"A common mistake is adding guideline file names ... to path_instructions"*.

## 17. `chat.integrations.linear` crea issues fuera del flujo de Linear

Pedirle a `@coderabbitai` en el chat de un PR "Add this to Linear" crea una issue real usando el
contexto de la discusión — si `chat.integrations.linear.usage` está en `auto` (default) en un repo
privado, equivale a habilitado. Esa issue **no pasa** por `talent-issue-craft`/`linear-skill`
(proyecto correcto de la initiative, labels `vertical/*`, etc. — CLAUDE.md regla 21). Si no se desea
ese atajo, fijar explícitamente `chat.integrations.linear.usage: disabled` en `.coderabbit.yaml`.
Fuente: <https://docs.coderabbit.ai/issues/creation> (consultado 2026-09-05).

## 18. `enable_prompt_for_ai_agents: false` mata el comando `resolve` del skill

`reviews.enable_prompt_for_ai_agents` (default `true`) controla si CodeRabbit incluye el bloque
"🤖 Prompt for AI Agents" en los comentarios inline. El paso `resolve` de este skill depende
enteramente de que ese bloque exista para saber qué prompt usar en el fix. **Nunca** poner
`enable_prompt_for_ai_agents: false` en este repo. Fuente: schema v2 (consultado 2026-09-05).

## 19. "Rate limit al hacer muchas queries GraphQL"

GitHub GraphQL tiene 5000 puntos/hora (confirmado en vivo 2026-09-05). Para un repo típico:
`fetch_cr_comments.sh` ~10-50 puntos por llamada; `resolve_thread.sh` ~1 punto; `cr_metrics.sh` (20
PRs) ~200-500 puntos.

```bash
gh api rate_limit --jq '.resources.graphql'
sleep 60   # si te encuentras con rate limit
```

Para loops grandes (bulk resolve), añadir `sleep 0.5` entre llamadas.

## 20. "CR comentó un secret, ¿qué hago?"

1. El secret ya está expuesto en el historial de Git (y CR lo leyó al revisarlo).
2. Revocar el secret inmediatamente.
3. Rotar en producción.
4. Limpiar el historial (`git filter-repo`/BFG) si aplica.
5. Para el futuro: a `.gitignore` SOLO lo que nunca deba versionarse (`.env`, credenciales locales). Los
   ficheros que SÍ se versionan se quedan DENTRO de `reviews.path_filters` y del alcance de los
   scanners de secretos (`gitleaks`/`trufflehog`): excluirlos del review no protege nada, solo ciega
   al bot ante la próxima fuga.

**No solo borres el commit** — el secret ya está en el webhook que CR recibió y en el historial remoto.

## 21. "CR bloquea merge pero no veo qué hay que arreglar"

Verificar con `gh pr checks <PR>`. Si el check de CodeRabbit está failing: click en "Details" para la
UI de CR, o revisar los review comments no resueltos. Para destrabar temporalmente (emergencia): admin
override en GitHub, o bajar `pre_merge_checks.<check>.mode` de `error` a `warning` temporalmente.

## 22. "Quiero desinstalar CR de un repo temporalmente"

Opciones de menor a mayor destructividad:

1. **Pausar** (preserva config): `gh pr comment <any_pr> --body "@coderabbitai pause"`.
2. **Deshabilitar `auto_review`** (manual-only): `reviews.auto_review.enabled: false`. Puedes seguir
   invocando con `@coderabbitai review`.
3. **Remover repo del app**: GitHub → Settings → Applications → CodeRabbit → Configure → uncheck repo.
4. **Desinstalar app completamente**: GitHub → Settings → Applications → CodeRabbit → Uninstall.

## 23. "Cómo sé qué plan tiene esta organización?"

1. **Mapping del equipo** (fuente primaria): `bash scripts/detect_plan.sh` — resuelve org→plan.
2. **En un PR activo**: `@coderabbitai rate limit` muestra tu cuota real (barato, ya se publica solo).
3. **Dashboard**: `app.coderabbit.ai/settings/subscription` (requiere rol Admin/Billing Admin) o el
   dashboard Review Usage (Analytics, publicado 2026-09-01).

NO existe API pública de CodeRabbit para consultar el plan (`metrics/reviews`/`organizations` son
Enterprise-only). Ningún plan tiene reviews ilimitados. El mapping estático de `detect_plan.sh` es una
verificación puntual — re-confirmar con `@coderabbitai rate limit` antes de presupuestar una ola grande.
Detalle: `references/rate-limits.md`.

## 24. Postura de seguridad del vendor

CodeRabbit sufrió una vulnerabilidad RCE histórica en su infraestructura (dic-2024 → ene-2025,
divulgada públicamente el 2025-08-19): un `.rubocop.yml` malicioso permitía ejecución de Ruby arbitrario
en el pipeline de análisis, filtrando tokens/secretos y dando acceso de lectura/escritura a ~1 millón
de repos conectados. CodeRabbit remedió en horas de la divulgación responsable (deshabilitó Rubocop,
rotó credenciales) y cerró el vector el 30 de enero de 2025. Fuente:
<https://research.kudelskisecurity.com/2025/08/19/how-we-exploited-coderabbit-from-a-simple-pr-to-rce-and-write-access-on-1m-repositories/>
(publicado 2025-08-19, consultado 2026-09-05).

Es un incidente histórico, parcheado, sobre un vector Ruby/Rubocop que no aplica al stack Next.js/TS de
este repo — no es un blocker operativo hoy. Se documenta como contexto de por qué el CLI local (que no
depende del backend de review para el gate pre-push) es la ruta preferida sobre el App en superficies
sensibles — refuerza, no contradice, la arquitectura CLI-primero que ya opera este repo.

## 25. "Claude Code no encuentra esta skill"

Verificar que `SKILL.md` está en el directorio correcto:

```bash
ls ~/.claude/skills/coderabbit-talent/SKILL.md   # user-level
ls .claude/skills/coderabbit-talent/SKILL.md     # project-level
```

## 26. Recursos adicionales

- CR docs: <https://docs.coderabbit.ai>
- Status page: <https://status.coderabbit.ai>
- Discord community: <https://discord.gg/coderabbit>
- Doctrina de estación (Mergeador) para el manejo fino del rate limit/spending cap:
  `talent-merger/references/04-coderabbit-cli-y-app.md`
