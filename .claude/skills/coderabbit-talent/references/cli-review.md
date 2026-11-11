# CLI de CodeRabbit (`coderabbit`)

> `last_verified: 2026-09-22`

Referencia del binario `coderabbit` (CLI de pago, incluido en el seat desde 2026): versiones,
distribución, autenticación, flags vigentes/retiradas, comandos, y el contrato JSON `--agent`. Esta
referencia cubre el **binario en sí**; el uso de ese binario como **gate obligatorio pre-push de este
repo** vive en `references/gate-cli-del-repo.md` — no dupliques contenido entre ambas.

## Tabla de contenidos

1. [Versión estable y pin de la flota](#1-versión-estable-y-pin-de-la-flota)
2. [Distribución e integridad](#2-distribución-e-integridad)
3. [Autenticación](#3-autenticación)
4. [Flags vigentes vs retiradas](#4-flags-vigentes-vs-retiradas)
5. [Comandos disponibles (verificados en vivo, 0.8.0)](#5-comandos-disponibles-verificados-en-vivo-080)
6. [El contrato JSON `--agent`](#6-el-contrato-json---agent)
7. [Detección de rama base](#7-detección-de-rama-base)
8. [Cuota del CLI por plan](#8-cuota-del-cli-por-plan)
9. [Ruta C: plugin nativo de Claude Code](#9-ruta-c-plugin-nativo-de-claude-code)
10. [Ruido y silencio: qué es normal](#10-ruido-y-silencio-qué-es-normal)
11. [Gotchas y referencias cruzadas](#11-gotchas-y-referencias-cruzadas)

## 1. Versión estable y pin de la flota

```text
  ¿qué versión de la CLI estoy usando?
     │
     ├─ estable publicada por el vendor ─▶ curl https://cli.coderabbit.ai/releases/latest/VERSION
     │                                      (0.8.0, 2026-09-22 — re-verificar el día que lo necesites)
     └─ la que realmente instala el gate ─▶ CR_CLI_VERSION en
                                             talent-channels/scripts/02-golden.sh (hoy 0.6.5)
```

**Nunca cites el pin del golden por número de línea** — el fichero se reordena entre auditorías; cita
la variable `CR_CLI_VERSION` de `talent-channels/scripts/02-golden.sh`. Verificado en vivo 2026-09-22:
`releases/latest/VERSION` devuelve `0.8.0`; el zip `coderabbit-linux-x64.zip` de esa release tiene sha256
`e60aa408266c3e2350aae890b239ab8d1c12b3f607f4475e1c2ddd4529af1d71` (`SHA256SUMS`, last-modified 22-sep
12:58 GMT) y contiene solo el binario `coderabbit`; el golden sigue fijando `CR_CLI_VERSION="0.6.5"`. El
host puede llevar una versión más nueva que el golden sin que eso implique que el gate del repo la use —
el gate solo confía en lo que el golden instala. Entre 0.7.6 y 0.8.0 el vendor publicó también 0.7.7
(2026-09-15) y 0.7.8 (2026-09-16) — ver §4 y §6 para lo que cambió.

**ABC-5477 (flag de alcance por versión) se fundió el 2026-09-07 (PR #2290)** — `scripts/cr-review.sh`
ya NO hardcodea `--type`; `cr_scope_flag()` lee `coderabbit --version` en vivo y elige `--committed`
(≥0.7.0) o `--type committed` (<0.7.0), fail-closed si la versión no parsea. Subir el pin del golden
desde `0.6.5` es una decisión aparte (ABC-5480, Todo) — este skill NO decide ni ejecuta esa subida.

## 2. Distribución e integridad

- Zips por plataforma: `https://cli.coderabbit.ai/releases/<version>/coderabbit-<os>-<arch>.zip`
  (`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `windows-x64`).
- **`SHA256SUMS` oficial por versión** — novedad del vendor (existe desde algún punto entre 0.7.1 y
  0.7.5; NO existe para 0.6.4/0.6.5/0.6.9/0.7.0/0.7.1, que devuelven 404). Verificado en vivo
  2026-09-22: `releases/latest/SHA256SUMS` (0.8.0) responde 200 y el sha256 local del zip descargado
  coincide con la línea publicada; el manifiesto también cubre `install.sh`/`install.ps1` y el instalador
  Jamf.
- Esto **no reemplaza** el patrón de checksum pineado a mano del golden (`talent-channels/scripts/
  02-golden.sh`) — sigue siendo la defensa correcta contra "descargar la última versión en el momento
  exacto en que está comprometida en tránsito" — pero sirve como verificación cruzada adicional al
  fijar una versión nueva: comparar el hash capturado a mano contra el `SHA256SUMS` publicado.
- No hay firma criptográfica (`.sig`/`.asc`) para Linux/macOS — solo checksums de integridad. Windows sí
  tiene Authenticode signing desde 0.7.5.
- No existe un paquete `@coderabbitai/cli` en npm (404 en el registro, verificado) — solo la
  distribución por zip de `cli.coderabbit.ai`.
- **CLI v0.7.8 (2026-09-16)**: el instalador Unix (`install.sh`) ahora pinea cada descarga a UNA release
  y rechaza zips cuyo checksum no coincida (fuente: changelog oficial, consultado 2026-09-22). El propio
  `install.sh` crea un alias corto `cr` en `~/.local/bin/cr` (verificado hoy con `curl … | grep -nE
  '\bcr\b'`: comentario "Alias: ~/.local/bin/cr", "Tip: Use 'cr' as a short alias for 'coderabbit'") —
  el changelog usa `cr update`/`cr review` en sus ejemplos asumiendo ese alias instalado.

## 3. Autenticación

- El CLI **no lee `CODERABBIT_API_KEY` del entorno** durante `review`/`auth status` — usa la sesión
  persistida en `~/.coderabbit/auth.json` (`{"type":"api_key","apiKey":"...","region":"..."}`).
  Verificado en vivo: la env var no está exportada en este shell y `coderabbit auth status --agent`
  igualmente reporta `authenticated: true` leyendo del fichero.
- Autenticar una vez con `coderabbit auth login` (interactivo, navegador; `--agent` emite JSON para
  login OAuth guiado por agente; `--no-browser` si abres la URL a mano; `--region us|eu` para
  multi-región — flags verificadas en `auth login --help` de 0.8.0, 2026-09-22). **Nunca** usar
  `--api-key <key>`: la clave quedaría en argv (`ps`, `/proc/<pid>/cmdline`) y en el historial de
  shell. En entornos sin navegador (estaciones, CI) la vía es escribir `~/.coderabbit/auth.json`
  de forma atómica con permisos `0600` a partir del secreto ya en disco/escrow (nunca por argv),
  que es la receta que aplica el runbook de la estación (`talent-merger` ref 04).
- Debe ser una **Agentic API key**, no una key de usuario normal — si falla con un mensaje sobre
  "user API keys are not supported", generar una Agentic API key.
- `coderabbit doctor` reporta el estado de auth con un chequeo legible por humano; para scripts, usar
  `coderabbit auth status --agent` y comprobar el campo `authenticated: true` (NUNCA confiar solo en el
  exit code: sale `rc=0` tanto autenticado como `signed out`, medido en 0.6.5 y aplicable como
  precaución general).
- **CLI v0.7.8 (2026-09-16)**: el login de agente ahora explica cómo usar una API key o un navegador
  accesible cuando el login automático por navegador no está disponible (changelog oficial, consultado
  2026-09-22) — mensaje de guía, no un flag ni comportamiento nuevos que verificar por separado.

```bash
coderabbit auth status --agent
# {"type":"status","phase":"auth","status":"authenticated","authenticated":true,"authType":"api_key","region":"us"}
```

## 4. Flags vigentes vs retiradas

Verificado en vivo el 2026-09-22 con `coderabbit review --help` sobre el binario **0.8.0** (dump completo
en `hechos-vivos-2026-09-22/cli-0.8.0-help/review.txt`) — este es el método correcto para confirmar
flags, nunca memoria de una versión anterior.

| Flag | Estado | Notas |
|---|---|---|
| `--committed` | ✅ vigente | "Review only committed changes" |
| `--uncommitted` | ✅ vigente | "Review uncommitted Git changes" (texto del `--help` cambió de redacción en 0.8.0, mismo comportamiento) |
| `--include-untracked` | ✅ vigente | Suma archivos aún no añadidos a Git |
| `--agent` | ✅ vigente | Emite hallazgos estructurados (NDJSON) para workflows de agente |
| `--base <branch>` | ✅ vigente | Rama base de comparación |
| `--base-commit <commit>` | ✅ vigente | Commit base en la rama actual |
| `--dir <path>` | ✅ vigente | Revisa solo cambios de git dentro de ese directorio |
| `--deep [focus]` | 🆕 **nueva en 0.8.0** | "Use the full pull request review policy" — pasar texto a `focus` "requires early access". NO es un rename de `--light`: política de review distinta, no un nivel "más ligero" |
| `--remote <owner/repo>` | 🆕 **nueva en 0.8.0** (changelog la fecha en CLI v0.7.7, 2026-09-15) | Revisa un repo de GitHub instalado SIN checkout local; exige `--base` + `--source-branch` y corre fuera de cualquier git checkout |
| `--source-branch <ref>` | 🆕 **nueva, acompaña a `--remote`** | Rama/ref origen a revisar con `--remote` |
| `--show-prompts` | ✅ vigente | Imprime los prompts de IA de la última review, sin iniciar una nueva |
| `--use-credits` | ✅ vigente | Consentimiento explícito para gastar el add-on usage-based |
| `--usage` | ✅ vigente | Alias de `coderabbit usage`: muestra reviews incluidas + consumo del periodo, en vez de revisar |
| `--region us\|eu` | ✅ vigente | Región para auth inline |
| `--api-key <key>` | ✅ vigente | Existe en `review` y `auth login`; preferir `auth.json` — nunca en argv (ver §3) |
| `-c, --config <files...>` | ✅ vigente | Instrucciones adicionales (p. ej. CLAUDE.md) |
| `--light` | ❌ **retirada, ya no aparece en el `--help` de 0.8.0** | Diff `0.7.6 → 0.8.0` verificado hoy contra ambos dumps. No hay flag de reemplazo directo por nombre — la política "más ligera" no tiene equivalente 1:1; `--deep` es una política DISTINTA (arriba), no su sustituta |
| `--type <all\|committed\|uncommitted>` | ❌ **retirada en 0.7.0** (2026-07-22) | Reemplazada por `--committed`/`--uncommitted`/`--include-untracked`. **El repo ya no la usa** (ABC-5477, resuelto 2026-09-07) — ver §5 de `gate-cli-del-repo.md` |
| `--plain` | ❌ retirada | El modo plano es el default sin flag |
| `--fast` | ❌ retirada | — |
| `--interactive` | ❌ retirada | — |
| `--cwd` | ❌ retirada | Sustituida por `--dir` |
| `--prompt-only` | ❌ retirada | Sustituida por `--show-prompts` |
| `--no-color` | nunca existió como flag de `review` | Solo `NO_COLOR` como env var del **instalador**, sin relación con el review |

**Comportamiento crítico, histórico (`--type`, verificado por última vez en vivo el 2026-09-05, sin
cambios de fondo observados hoy)**: pasar una flag desconocida a `coderabbit review` **no aborta el
comando ni imprime error** — se ignora en silencio y el review corre con el alcance por defecto (todos
los cambios trackeados). `coderabbit config validate`, en cambio, sí valida sus flags y falla con
`unknown option '--type'`. Esta asimetría motivó ABC-5477 (§1), ya resuelto en este repo.

**`review findings --clear` (nueva en CLI v0.7.7, 2026-09-15)**: dismisses los findings almacenados para
el scope actual (directorio de review + rama actual + rama base) sin tocar findings guardados bajo otro
scope — ver §5.

## 5. Comandos disponibles (verificados en vivo, 0.8.0)

Árbol completo del binario (dump íntegro en `hechos-vivos-2026-09-22/cli-0.8.0-help/root.txt` y un
`.txt` por subcomando en esa misma carpeta):

```text
coderabbit
├── auth        login | logout | status | org
├── review      [--agent|--deep [focus]|--show-prompts|--committed|--uncommitted|--include-untracked|
│                 --base|--base-commit|--dir|--remote <owner/repo>|--source-branch <ref>|--api-key|
│                 --usage|--region|--use-credits]
│   └── findings   [--dir] [--clear]   # hallazgos de la última review local, sin gastar cuota
├── pullrequest <number-or-url>   [--show-prompts|--show-threads|--agent]  # lee una review del App
├── stats       [--rebuild]
├── usage       [--agent]          # gasto/consumo del periodo de facturación
├── update
├── config      [--agent|--profile <p>|--generate|--detailed]   # ⚠️ ver aviso abajo — MUTA por defecto
├── doctor                         # chequeo de instalación + auth + red
├── skills      [--agent|--confirm <plan-hash>]   # instala/actualiza skills del vendor (con preview)
└── handoff     --summary <path|-> [--plan <path>]   # ⚠️ crea una tarea en CodeRabbit Cloud
```

> ⚠️ **`coderabbit config` a secas es EQUIVALENTE a `coderabbit config --generate`** desde 0.8.0 — "Create
> or configure repository settings through a guided flow", **CREA o MODIFICA `.coderabbit.yaml`**. Ya no
> es un comando de solo-inspección. `config validate <fichero>` (más abajo) sigue siendo la forma de
> verificar SIN mutar, aunque el `--help` de 0.8.0 ya no la liste explícitamente (verificado hoy: sigue
> funcionando, "valid against the current CodeRabbit schema"). **JAMÁS** correr `config` a secas ni con
> `--generate`/`--agent`/`--detailed` desde este skill (regla dura del refresco 2026-09-22).
>
> ⚠️ **`coderabbit handoff`** (nuevo en 0.8.0) crea una tarea nueva en CodeRabbit Cloud a partir de un
> resumen de sesión + plan opcional — dispara trabajo remoto. **JAMÁS** ejecutarlo desde este skill; no
> confundir con `scripts/draft-handoff.sh` de este repo (mecanismo propio, sin relación con este comando
> del vendor).

| Comando | Qué hace | Gasta cuota de review |
|---|---|---|
| `coderabbit review` | Review completo del working tree | Sí |
| `coderabbit review findings [--dir]` | Muestra findings de la última review local | No — lectura de caché |
| `coderabbit review findings --clear` (0.7.7) | Descarta findings guardados para el scope actual (dir+rama+base) | No |
| `coderabbit review --show-prompts` | Imprime prompts de IA de la última review | No |
| `coderabbit pullrequest <n> [--show-prompts\|--show-threads] [--agent]` | Lee el resultado de un PR ya revisado por el App (`--show-threads`: JSON de los hilos inline) | No — solo lectura remota |
| `coderabbit config validate [file]` | Valida `.coderabbit.yaml`/`.yml` contra el schema oficial | No |
| `coderabbit doctor` | Chequeo de instalación/auth/red | No |
| `coderabbit auth status [--agent]` | Estado de autenticación (JSON con `--agent`) | No |
| `coderabbit stats [--rebuild]` | Estadísticas de reviews históricas | No |
| `coderabbit usage [--agent]` | Gasto/consumo del periodo de facturación (equivalente a `review --usage`) | No |
| `coderabbit skills [--agent] [--confirm <hash>]` | Instala/actualiza skills verificadas del vendor, con preview de aprobación para agentes | No, pero MUTA ficheros de skills — no correrlo sin pedirlo el lead |

`coderabbit feedback "<mensaje>"` sigue sin aparecer en el `--help` del binario instalado — reconfirmado
hoy contra `root.txt` de 0.8.0 (no listado como comando). No se afirma su existencia sin verificación
directa — confirmar con `coderabbit --help` antes de depender de él.

## 6. El contrato JSON `--agent`

El modo `--agent` emite NDJSON (un objeto JSON por línea) con estos tipos de evento:

- `finding` — `severity` (`critical|major|minor|trivial|info|none`), `fileName`,
  `codegenInstructions`, `suggestions`, `comment`.
- `complete` — `status: "review_completed"` / `"review_skipped"` (+ `findings: 0`, `message: "No
  changes detected"` cuando no hay cambios).
- `review_context`, `status`, `heartbeat`, `error`.

El schema **no tuvo drift** entre 0.6.5 y 0.7.6 — la 0.7.6 solo añadió campos **aditivos** (`category`,
`CWE`, `reachability`, `exploitability` en findings de seguridad; `candidates`/`candidatesNote` en el
evento `error` de scope-demasiado-grande), documentados explícitamente por el vendor como
no-rompientes: *"These fields do not change the existing error contract, so integrations do not need
to handle them."* Fuente: <https://docs.coderabbit.ai/cli/reference>, changelog «CLI v0.7.6»
(2026-09-04), consultado 2026-09-05. El filtro compartido de este repo
(`scripts/lib/cr-finding-normalize.jq`) declara soporte explícito a los schemas 0.6.4 y 0.6.5 y no
necesita cambios para consumir 0.7.6.

**Cambios posteriores relevantes al contrato (0.7.7/0.7.8), verificados hoy solo contra el TEXTO del
changelog oficial — NO contra un `--agent` real (correrlo gasta cuota, prohibido en este refresco)**:

- **CLI v0.7.7 (2026-09-15)**: reviews fallidos/incompletos salen con **exit code 1** pero preservan los
  findings ya recibidos y el último checkpoint exitoso — un consumidor que trate `rc≠0` como "sin
  findings" pierde datos reales. Cambiar la rama base de comparación resetea el contexto guardado;
  los checkpoints de versiones CLI anteriores se resetean una vez al actualizar el binario. Reviews
  `--committed`-only leen contenido de fichero y config auto-descubierta **del snapshot de Git**, no del
  working tree.
- **CLI v0.7.8 (2026-09-16)**: findings **"unverified"** quedan visibles para inspección, sin prompt de
  fix de IA, y se **cuentan aparte** de los findings normales — el nombre exacto del campo/flag en el
  NDJSON (¿`verified: false`? ¿`status: "unverified"`?) **NO está confirmado**, solo la descripción en
  prosa del changelog; verificar contra un run real antes de depender del nombre del campo. Los findings
  además pueden traer atribución **"Security Review"** cuando fueron analizados por esa función,
  "including in agent output" (texto literal del vendor) — mismo caveat: el campo JSON exacto no está
  confirmado hoy.
- **0.8.0 (2026-09-22)**: sin entrada de changelog publicada al momento de esta verificación — no se
  documenta contenido del contrato para 0.8.0 más allá de lo observable en `--help` (§4-5); no inventar.

Impacto potencial en `scripts/cr-review.sh` (del repo, no tocado aquí): el parser de paridad (§8 de
`gate-cli-del-repo.md`) cuenta bloqueantes por `severity` — si el CLI real empieza a emitir findings
`unverified` contados aparte, el parser podría ignorarlos o sumarlos según cómo los serialice el binario
instalado; riesgo a verificar en la próxima corrida real contra el pin vigente (`0.6.5`, anterior a
0.7.8), no una afirmación de que ya ocurre.

## 7. Detección de rama base

Cuando no se pasa `--base` explícito, un patrón robusto adoptado de la práctica de la comunidad para
resolver la rama base de comparación:

```bash
BASE="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null \
        || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##' \
        || echo main)"
coderabbit review --agent --base "origin/${BASE}" --committed
```

Orden de intento: `@{upstream}` de la rama actual → `origin/HEAD` simbólico del remoto → `main` como
último recurso. El gate real de este repo (`scripts/cr-review.sh`) usa `origin/main` fijo — este
patrón es para uso manual/ad-hoc en repos sin ese supuesto.

## 8. Cuota del CLI por plan

Las reviews de la CLI consumen del **mismo bucket por-developer-por-org** que las del App/IDE — no hay
un contador separado por superficie. La tabla completa de cuotas por plan (Essentials/Team/Advanced/
Enterprise) vive en `references/rate-limits.md`; no se duplica aquí.

## 9. Ruta C: plugin nativo de Claude Code

Existe un plugin oficial de CodeRabbit para Claude Code (`/plugin install coderabbit`, comando
`/coderabbit:review`) desde 2026-02, para uso **interactivo manual** — un humano (o Claude Code en modo
conversación) pide una review sin pasar por la CLI directamente. Fuente:
<https://docs.coderabbit.ai/cli/claude-code-integration> (consultado 2026-09-05), que dice
explícitamente: *"Claude Code users: Claude Code now supports CodeRabbit through a native plugin ...
using `/coderabbit:review` instead of the CLI commands shown below."*

**No sustituye el gate `cr-review.sh`** de este repo: el gate necesita el JSON `--agent` crudo,
persistido con su propio contrato de artefactos (`.claude/.cr-review-*`), para emitir sentinels
deterministas — el plugin no expone ese contrato. Úsalo únicamente como Ruta C (uso ad-hoc, solo si el
lead lo pide) — ver `SKILL.md` «Contexto crítico: integración y plan».

## 10. Ruido y silencio: qué es normal

- Silencio de 2-3 minutos durante una review es normal (CodeRabbit se posiciona como "Slow AI"). Los
  logs locales viven en `~/.coderabbit/logs/` si necesitas diagnosticar más allá de eso.
- El evento `error` con mensaje de rate-limit **no tiene un string literal publicado oficialmente** —
  el heurístico razonable es `test("rate limit"; "i")` sobre `.message` (variable `ratelimit` en
  `scripts/cr-review.sh`, verificado hoy con `grep -n 'rate limit' scripts/cr-review.sh` → línea 870 en
  el head actual, 2026-09-22), sin garantía de contrato público del vendor. Si ocurre un rate-limit
  real, vale la pena capturar el string exacto desde el `.jsonl` crudo persistido para confirmarlo
  empíricamente.

## 11. Gotchas y referencias cruzadas

1. **Verifica flags con el `--help` del binario instalado, nunca con memoria de una versión anterior**
   — máxima adoptada tras confirmar el comportamiento silencioso de `--type` (§4).
2. **Nunca `coderabbit auth login --api-key <valor>` en un comando que quede en shell history/`ps`** —
   usar el flujo interactivo o variables de entorno consumidas por el propio comando, nunca argv literal.
3. **El exit code de `auth status` no es un guard fiable** — comprobar el campo `authenticated` del
   JSON, no el `rc` (§3).
4. **`coderabbit feedback` no está confirmado en 0.8.0** (§5) — no fabricar su uso sin verificar antes.
5. **`coderabbit config` a secas MUTA config desde 0.8.0** (§5) — nunca correrlo por costumbre de "solo
   inspeccionar"; usar `config validate <fichero>` para leer sin escribir.
6. **`--light` desapareció en 0.8.0 sin reemplazo 1:1** (§4) — `--deep` es una política distinta (full PR
   review), no un rename; no sustituir uno por otro sin leer qué hace cada uno.
7. **`exit 1` de `review` desde 0.7.7 no significa "sin findings"** (§6) — preserva findings recibidos y
   el último checkpoint; un parser que descarte la salida completa en `rc≠0` pierde datos reales.

**Referencias relacionadas:**

- Para el contrato de artefactos del gate pre-push (`.claude/.cr-review-*`) → `references/gate-cli-del-repo.md`
- Para cuotas y Fair Usage → `references/rate-limits.md`
- Para diagnosticar fallos del CLI → `references/troubleshooting.md`
