# `.coderabbit.yaml` — Referencia completa (schema v2)

`last_verified: 2026-09-22`

Fuente canónica: schema v2 vivo en <https://coderabbit.ai/integrations/schema.v2.json> (301 →
`https://www.coderabbit.ai/integrations/schema.v2.json`, verificado 2026-09-22)
(78 531 bytes, sha256 `2f553ce56643d111b29d1fe2ec70ce2377a5e06972752140dee6b2ab93b6055f`, verificado
2026-09-22 con `curl -L | sha256sum`; snapshot previo 2026-09-05: 77 437 bytes, sha256
`8c34e033182463bd4f2a823b144077cb21cc327927fb82ce49791bdae2b9da13`) y
<https://docs.coderabbit.ai/reference/configuration> ("Last updated: September 16, 2026",
verificado 2026-09-22; era "September 3, 2026" el 2026-09-05). Toda propiedad, tipo, enum y default
de este documento se comprobó contra ese JSON con `jq`/`python3`, no de memoria — el comando exacto
está en cada sección para poder re-verificar. El 2026-09-22 se re-diffeó punto por punto todo el
schema (top-level, `reviews.*`, `reviews.tools.*`, `pre_merge_checks`, `finishing_touches`,
`slop_detection`, `post_merge_actions`, `chat`, `knowledge_base`, `code_generation`,
`issue_enrichment`) contra el snapshot del 2026-09-05; el único cambio real encontrado es
`reviews.tools["ast-grep"]`, documentado en §6 y §13. Donde la fecha de una fuente sigue en
`2026-09-05` es porque esa cita concreta apunta a una página de docs (no al JSON del schema) que no
se volvió a fetchear hoy.

Para autocompletado en el editor, la primera línea del `.coderabbit.yaml` del repo debe ser:

```yaml
# yaml-language-server: $schema=https://coderabbit.ai/integrations/schema.v2.json
```

## Tabla de contenidos

1. [Panorama del schema v2](#1-panorama-del-schema-v2)
2. [Campos top-level sueltos](#2-campos-top-level-sueltos)
3. [`reviews` — comportamiento general](#3-reviews--comportamiento-general)
4. [`reviews.auto_review`](#4-reviewsauto_review)
5. [`reviews.path_filters` y `reviews.path_instructions`](#5-reviewspath_filters-y-reviewspath_instructions)
6. [`reviews.tools` — catálogo de 59 herramientas](#6-reviewstools--catálogo-de-59-herramientas)
7. [`reviews.pre_merge_checks`](#7-reviewspre_merge_checks)
8. [`reviews.finishing_touches` y `reviews.labeling_instructions`](#8-reviewsfinishing_touches-y-reviewslabeling_instructions)
9. [`reviews.slop_detection` y `reviews.post_merge_actions`](#9-reviewsslop_detection-y-reviewspost_merge_actions)
10. [`chat`](#10-chat)
11. [`knowledge_base`](#11-knowledge_base)
12. [`code_generation` e `issue_enrichment`](#12-code_generation-e-issue_enrichment)
13. [Errores comunes](#13-errores-comunes)
14. [Validación y alcance fuera de este documento](#14-validación-y-alcance-fuera-de-este-documento)
15. [Alternativa: `.coderabbit.config.ts`](#15-alternativa-coderabbitconfigts)

## 1. Panorama del schema v2

El schema tiene exactamente **10 propiedades top-level** (verificado `jq '.properties | keys'`,
2026-09-05; re-verificado sin cambios 2026-09-22): `chat`, `code_generation`, `early_access`,
`enable_free_tier`, `inheritance`, `issue_enrichment`, `knowledge_base`, `language`, `reviews`,
`tone_instructions`.

```text
.coderabbit.yaml (schema v2, 10 top-level)
│
├─ language, tone_instructions ─────── idioma y tono de los comentarios
├─ early_access, enable_free_tier ──── flags de producto
├─ inheritance ──────────────────────── hereda config de nivel organización
│
├─ reviews ──────────────────────────── el 80% de la superficie de config
│   ├─ profile, auto_review, path_filters/path_instructions
│   ├─ tools.*            (59 linters/scanners en sandbox)
│   ├─ pre_merge_checks   (gates antes de mergear)
│   ├─ finishing_touches  (autofix, unit tests, simplify, fix-ci, recipes)
│   ├─ labeling_instructions, slop_detection, post_merge_actions
│   └─ review_progress / commit_status / fail_commit_status / enable_prompt_for_ai_agents
│
├─ chat ─────────────────────────────── comportamiento del bot en comentarios
│   └─ integrations.{jira,linear}.usage
│
├─ knowledge_base ───────────────────── aprendizaje persistente + contexto externo
│   ├─ automatic_linking_mode, linked_repositories[]
│   ├─ learnings.{scope,approval_delay}
│   ├─ issues (GH/GL) · jira{usage,project_keys} · linear{usage,team_keys}
│   ├─ code_guidelines.filePatterns (string | {files, applyTo})
│   ├─ web_search, mcp, opt_out, pull_requests
│
├─ code_generation ──────────────────── docstrings/unit_tests: idioma + path_instructions
└─ issue_enrichment ─────────────────── auto_enrich, planning, labeling (issues GH/GL)
```

Verificado también: enum de `reviews.profile` = `quiet | chill | assertive` (default `chill`),
sin cambios desde la verificación anterior (2026-07-11). `jq '.properties.reviews.properties.profile'`.

## 2. Campos top-level sueltos

```yaml
language: es              # ISO 639-1 (+ región opcional: es-ES, es-MX, pt-BR...). Default en-US.
                           # Enum completo verificado: ~100 códigos (incluye es, es-ES, es-AR, pt-BR).

tone_instructions: |       # STRING, máx 250 caracteres (`maxLength: 250` en el schema).
  Sé directo y conciso. Evita cortesías.

early_access: false        # BOOLEAN. Activa features beta. Default false.

enable_free_tier: true     # BOOLEAN. Default true. Permite que colaboradores sin seat de pago
                           # reciban una review de summary (comportamiento del tier Free).

inheritance: false         # BOOLEAN. Default false. Hereda config de nivel organización y la
                           # fusiona con este YAML de repo. "Inheritance only propagates upward
                           # if enabled at each level" (cita literal del schema).
```

Fuente: `jq '.properties.language, .properties.tone_instructions, .properties.early_access,
.properties.enable_free_tier, .properties.inheritance' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22).

## 3. `reviews` — comportamiento general

```yaml
reviews:
  profile: chill                      # quiet | chill | assertive (default chill)

  request_changes_workflow: false     # BOOLEAN. true → bloquea merge hasta resolver cada thread.

  review_progress: true               # BOOLEAN, default true (NUEVA desde la verificación 2026-06).
                                       # "Publish the canonical user-facing review status and
                                       # progress updates (GitHub progress reports/check runs today)."

  commit_status: true                 # BOOLEAN, default true. PERO: "This setting is only used
                                       # when review_progress is disabled" (cita literal del schema).
  fail_commit_status: false           # BOOLEAN, default false. Misma condición que arriba: solo
                                       # aplica al mirror legacy cuando review_progress: false;
                                       # si review_progress está activo, aplica a los progress
                                       # reports en su lugar.

  enable_prompt_for_ai_agents: true   # BOOLEAN, default true. Incluye el bloque
                                       # "🤖 Prompt for AI Agents" en comentarios inline.
                                       # ⚠️ NUNCA ponerlo en false en un repo que use agentes para
                                       # triage: el comando `resolve` de este skill depende de que
                                       # ese bloque exista para dar instrucciones accionables.

  abort_on_close: true                # BOOLEAN, default true. Aborta el review en curso si el
                                       # PR se cierra o mergea antes de que termine.
```

**Gotcha vivo de la casa** (`.coderabbit.yaml:28-29` del repo): el yaml de producción configura
`commit_status: true` y `fail_commit_status: true` sin tocar `review_progress` (que queda en su
default `true`). Según el texto literal del schema, esas dos líneas son hoy **no-op** — el efecto
real lo produce el check nativo de "progress reports" de `review_progress`, no el commit-status
legacy. No es un fallo de este skill corregirlo (vive en `.coderabbit.yaml`, fuera de alcance de
esta issue — ver issue hermana de higiene del yaml vivo), pero cualquier agente que lea el yaml
debe saber que esas dos claves, tal como están hoy, no bloquean nada por sí solas.

Fuente: `jq '.properties.reviews.properties.review_progress, .properties.reviews.properties.commit_status,
.properties.reviews.properties.fail_commit_status, .properties.reviews.properties.enable_prompt_for_ai_agents,
.properties.reviews.properties.abort_on_close' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22).

## 4. `reviews.auto_review`

```yaml
reviews:
  auto_review:
    enabled: true                        # BOOLEAN, default true. Si false, CR no revisa solo.
    auto_incremental_review: true        # BOOLEAN, default true. Re-revisa en cada push.
    auto_pause_after_reviewed_commits: 5 # INTEGER, default 5 (min 0). Pausa los incrementales
                                          # tras N commits REVISADOS desde la última pausa; 0 los
                                          # desactiva del todo. Mitigación oficial de Fair Usage
                                          # en ramas calientes — ver references/rate-limits.md.
    ignore_title_keywords: []            # array de strings, case-insensitive. Ej: ["WIP"].
    labels: []                           # array de strings; "!label" niega. Con enabled:false,
                                          # solo un match POSITIVO dispara review (negativos solos
                                          # no opt-in por sí mismos).
    drafts: false                        # BOOLEAN, default false. Si true, también revisa drafts.
    base_branches: []                    # array de regex; branches ADICIONALES a la default.
    ignore_usernames: []                 # array de strings, match exacto (no email, no wildcard).
                                          # Práctica estándar: ["dependabot[bot]"].
    description_keyword: ""              # STRING. Con enabled:false, dispara review si esta
                                          # palabra aparece en la DESCRIPCIÓN del PR.
```

Fuente: `jq '.properties.reviews.properties.auto_review' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22); sin cambios
respecto a la verificación de 2026-07-11 (default de `auto_pause_after_reviewed_commits` sigue en 5).

## 5. `reviews.path_filters` y `reviews.path_instructions`

Sintaxis glob para incluir/excluir archivos del review (`path_filters`) e instrucciones por
subdirectorio (`path_instructions`, array de `{path, instructions}`). Sin cambios de schema desde
2026-06; ver ejemplos completos en el `.coderabbit.yaml` vivo del repo (`path_filters:` y
`path_instructions:` de la raíz) — no repetidos aquí para no duplicar config de producto.

```text
"path/to/**"    → incluye
"!path/to/**"   → excluye
Orden importa: excludes posteriores sobre-escriben includes previos.
```

## 6. `reviews.tools` — catálogo de 59 herramientas

El schema define **exactamente 59 tools** bajo `reviews.tools.*`
(`jq '.properties.reviews.properties.tools.properties | keys | length'` → `59`, 2026-09-05;
re-verificado 2026-09-22: sigue en 59, mismos 59 nombres, cero altas/bajas). Cada una expone
`enabled` (boolean, default `true`; **desde 2026-09-22 ya sin excepción**: `ast-grep` ganó su
propio `enabled` — ver nota abajo) más sub-propiedades específicas de configuración (paths de
reglas, umbrales, versión de config).
Varias claves de tool que circulan en YAMLs copiados de otras fuentes (linters de Python, de
Kubernetes o de .NET con nombres que no coinciden con ninguna de las 59 de aquí) **no existen** en
este schema y quedan inertes si se pegan — la lista exacta de esas claves inválidas vive en §13
«Errores comunes», con su alternativa real dentro de las 59.

Tabla generada con:

```bash
jq -r '.properties.reviews.properties.tools.properties
  | to_entries[]
  | {key, enabled_default: .value.properties.enabled.default, desc: .value.description}
  | [.key, (.enabled_default|tostring), .desc] | @tsv' schema.v2.json
```

| Tool (clave) | `enabled` default | Descripción (resumen) |
|---|---|---|
| `actionlint` | true | actionlint is a static checker for GitHub Actions workflow files. |
| `ast-grep` | true (desde 2026-09-22; ver nota) | Busca patrones en el AST del código (v0.45.3) |
| `biome` | true | Biome is a fast formatter, linter, and analyzer for web projects. |
| `blinter` | true | Blinter is a linter for Windows batch files that provides comprehensive static analysis... |
| `brakeman` | true | Brakeman is a static analysis security vulnerability scanner for Ruby on Rails applicat... |
| `buf` | true | Buf offers linting for Protobuf files. |
| `checkmake` | true | checkmake is a linter for Makefiles. |
| `checkov` | true | Checkov is a static code analysis tool for infrastructure-as-code files. |
| `circleci` | true | CircleCI tool is a static checker for CircleCI config files. |
| `clang` | true | Configuration for Clang to perform static analysis on C and C++ code |
| `clippy` | true | Clippy is a collection of lints to catch common mistakes and improve your Rust code. |
| `cppcheck` | true | Cppcheck is a static code analysis tool for the C and C++ programming languages. |
| `detekt` | true | Detekt is a static code analysis tool for Kotlin files. |
| `dotenvLint` | true | dotenv-linter is a tool for checking and fixing .env files for problems and best practices |
| `emberTemplateLint` | true | ember-template-lint is a linter for Handlebars template files that checks for common is... |
| `eslint` | true | ESLint is a static code analysis tool for JavaScript files. (sub-clave `e18e.enabled`: default `true` — ver nota abajo) |
| `fbinfer` | true | Configuration for Infer to find bugs in Java and C/C++ code |
| `flake8` | true | Flake8 is a Python linter that wraps PyFlakes, pycodestyle and Ned Batchelder's McCabe ... |
| `fortitudeLint` | true | Fortitude is a Fortran linter that checks for code quality and style issues. |
| `github-checks` | true | GitHub Checks integration configuration. (solo tiene `enabled`; ver §13) |
| `gitleaks` | true | Betterleaks is a secret scanner (an improved version of Gitleaks) — ver nota abajo. |
| `golangci-lint` | true | golangci-lint is a fast linters runner for Go. |
| `hadolint` | true | Hadolint is a Dockerfile linter. |
| `htmlhint` | true | HTMLHint is a static code analysis tool for HTML files. |
| `languagetool` | true | LanguageTool is a style and grammar checker for 30+ languages. |
| `luacheck` | true | Configuration for Lua code linting to ensure code quality |
| `markdownlint` | true | markdownlint-cli2 is a static analysis tool to enforce standards and consistency for Ma... |
| `oasdiff` | true | oasdiff detects breaking changes between OpenAPI specifications. |
| `opengrep` | true | OpenGrep is a high-performance static code analysis engine, compatible with Semgrep con... |
| `osvScanner` | true | OSV Scanner is a tool for vulnerability package scanning. |
| `oxc` | true | Oxlint is a JavaScript/TypeScript linter for OXC written in Rust. |
| `phpcs` | true | PHP CodeSniffer is a PHP linter and coding standard checker. |
| `phpmd` | true | PHPMD is a tool to find potential problems in PHP code. |
| `phpstan` | true | PHPStan is a tool to analyze PHP code. |
| `pmd` | true | PMD is an extensible multilanguage static code analyzer |
| `presidio` | true | Microsoft Presidio Analyzer 2.2.364 detects sensitive identifiers (payment cards, SSN, ... |
| `prismaLint` | true | Configuration for Prisma Schema linting to ensure schema file quality |
| `psscriptanalyzer` | true | PSScriptAnalyzer is a static code checker for PowerShell scripts and modules. |
| `pylint` | true | Pylint is a Python static code analysis tool. |
| `reactDoctor` | true | React Doctor scans React codebases for security, performance, correctness, and accessib... |
| `regal` | true | Regal is a linter and language server for Rego. |
| `rubocop` | true | RuboCop is a Ruby static code analyzer (linter) and code formatter. |
| `ruff` | true | Ruff is a Python linter and code formatter. |
| `semgrep` | true | Semgrep is a static analysis tool designed to scan code for security vulnerabilities an... |
| `shellcheck` | true | ShellCheck is a static analysis tool that finds bugs in your shell scripts. |
| `shopifyThemeCheck` | true | Configuration for Shopify Theme Check to ensure theme quality and best practices |
| `skillspector` | true | SkillSpector is a security scanner for AI agent skills that detects vulnerabilities, ma... |
| `smartyLint` | true | smarty-lint is a linter for Smarty 3 template files that checks for common issues such ... |
| `sqlfluff` | true | SQLFluff is an open source, dialect-flexible and configurable SQL linter. |
| `squawk` | true | Configuration for Squawk to lint Postgres migrations and SQL for safe schema changes |
| `stylelint` | true | Stylelint is a linter for stylesheets (CSS, SCSS, Sass, Less, SugarSS, Stylus) that hel... |
| `swiftlint` | true | SwiftLint integration configuration object. |
| `tflint` | true | TFLint is a Terraform linter for finding potential errors and enforcing best practices. |
| `trivy` | true | Trivy is a comprehensive security scanner that detects misconfigurations and secrets in... |
| `trufflehog` | true | TruffleHog is a secret scanner with verification capabilities that can detect and verif... |
| `vale` | true | Vale lints prose using the repository's checked-in style rules. |
| `verilator` | true | Verilator statically analyzes Verilog and SystemVerilog source files. |
| `yamllint` | true | YAMLlint is a linter for YAML files. |
| `zizmor` | true | zizmor is a static security analyzer for GitHub Actions workflow files. |

Notas obligatorias (no repetir el error del skill v2):

- **`gitleaks` = Betterleaks desde 2026-03-19.** La clave de config (`reviews.tools.gitleaks`) no
  cambió; el producto mostrado en la UI y en la doc oficial se llama "Betterleaks" (página dedicada
  `docs.coderabbit.ai/tools/betterleaks.md`, no `/tools/gitleaks.md`). Buscar "gitleaks" en la doc
  actual no da resultados — buscar "Betterleaks".
- **CAMBIO 2026-09-22: `ast-grep` ahora SÍ tiene `enabled` propio** (boolean, default `true`) —
  hasta el snapshot del schema del 2026-09-05 el objeto solo exponía `rule_dirs`, `util_dirs`,
  `essential_rules` (boolean, default `true`) y `packages`, sin booleano para apagar la tool
  entera. Hoy `{ast-grep: {enabled: false}}` sí tiene efecto documentado; `essential_rules: false`
  sigue existiendo aparte para reducir solo el paquete de reglas esenciales sin apagar `ast-grep`
  del todo. Versión reportada en la descripción del schema: `v0.45.3` (era `v0.45.2` el
  2026-09-05).
- **`github-checks` solo tiene `enabled`.** No hay ninguna otra sub-clave en el schema; la clave de
  duración/espera que a veces se copia de otras integraciones no existe aquí — ver §13.
- **Tools activas por default sin aparecer nunca en un YAML** (silenciosas): `zizmor`, `presidio`,
  `reactDoctor`, `vale` y `eslint.e18e` (sub-clave anidada de `eslint`, no una tool de nivel
  superior: `@e18e/eslint-plugin`, checks de modernización/deps con reemplazo nativo, default
  `enabled: true`). Si el repo no las quiere, hay que desactivarlas explícitamente — no basta con
  no mencionarlas.

Fuente de las notas: `jq '.properties.reviews.properties.tools.properties["ast-grep"],
.properties.reviews.properties.tools.properties.eslint.properties.e18e' schema.v2.json`
(2026-09-05; re-verificado 2026-09-22 — `ast-grep` cambió, `eslint.e18e` sin cambios).

## 7. `reviews.pre_merge_checks`

```yaml
reviews:
  pre_merge_checks:
    override_requested_reviewers_only: false   # BOOLEAN, default false. Si true, SOLO los
                                                # reviewers solicitados (no el autor) pueden
                                                # ignorar/override un check en error.
    docstrings:
      mode: warning        # off | warning | error (default warning)
      threshold: 80        # NUMBER 0-100, default 80. % mínimo de cobertura de docstrings.
    title:
      mode: warning
      requirements: "Conventional Commits: feat|fix|chore|docs|refactor|test|ci(scope): desc"
    description:
      mode: warning         # Sin sub-propiedad adicional más allá de `mode`.
    issue_assessment:
      mode: warning         # Evalúa si el PR resuelve el issue enlazado.
    custom_checks:
      - name: "no-console-log"
        mode: warning
        instructions: "Fail if src/** contains console.log outside of scripts/."
```

Todos los objetos de `pre_merge_checks.*` usan la **misma forma**: `mode: off|warning|error`
(nunca un booleano directo — `docstrings: true` es sintaxis inválida). `custom_checks` acepta hasta
50 entradas por el `maxItems` del schema, pero el **techo real por plan es menor**: Team (ex Pro+)
10, Advanced/Enterprise 20 — ver `references/rate-limits.md`.

Comandos manuales relacionados (documentados en `references/commands.md`):
`@coderabbitai run pre-merge checks`, `@coderabbitai evaluate custom pre-merge check --name <n>
--instructions <texto> [--mode <error|warning>]`, `@coderabbitai ignore pre-merge checks`.

**Gotcha con fuente comunitaria**: `pre_merge_checks.docstrings` no tiene `path_filters` propio —
el `threshold` se calcula sobre TODOS los archivos del diff que el schema considera código
documentable, incluidos ficheros de test. Un caso reportado (issue pública de terceros, 2026,
cerrada; ver `hechos-vivos.md` para el patrón general de falsos positivos de `docstrings`) muestra
0.00%–50.00% de cobertura en PRs que solo añaden tests, porque los callbacks `test(...)` /
`beforeEach` / `afterEach` cuentan como "funciones sin JSDoc". No hay forma de excluir solo
`tests/**` de ESTE check sin sacar ese path de todo el review (el `path_filters` de nivel superior
afecta a seguridad y bugs también). Mitigación: `mode: warning` en vez de `error` para el check
global, o aceptar el ruido en tests.

Fuente: `jq '.properties.reviews.properties.pre_merge_checks' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22, incluido `override_requested_reviewers_only` del changelog del 10-sep).

## 8. `reviews.finishing_touches` y `reviews.labeling_instructions`

```yaml
reviews:
  finishing_touches:
    docstrings: {enabled: true}             # Trigger: checkbox 📝 o `@coderabbitai generate docstrings`
    unit_tests: {enabled: true}             # Genera tests para los cambios del PR
    simplify: {enabled: false}              # Trigger: checkbox ✨ Simplify code (default false)
    autofix: {enabled: true}                # Trigger: checkboxes 🪄 o `@coderabbitai autofix`
    fix_ci: {enabled: true}                 # Requiere plan Team+. GitHub/Azure DevOps.
    resolve_merge_conflict: {enabled: true} # Requiere plan Team+. GitHub/GitLab.
    custom:                                 # máx 20 (maxItems del schema); trigger por nombre
      - name: "cleanup stale imports"
        instructions: "Remove unused imports across changed files; keep side-effect imports."
        # Se dispara con: @coderabbitai run cleanup stale imports

  labeling_instructions:
    - label: "db-migration"
      instructions: "Apply when the PR adds files under supabase/migrations/."
```

`finishing_touches.fix_ci` y `.resolve_merge_conflict` declaran explícitamente en su descripción
del schema "requires a Team plan" — confirmar disponibilidad si el repo alguna vez baja de Team.
`finishing_touches.custom[]` usa `{enabled, name (≤100), instructions (≤10000)}`; se dispara con
`@coderabbitai run <name>` (ver `references/commands.md`).

Fuente: `jq '.properties.reviews.properties.finishing_touches, .properties.reviews.properties.labeling_instructions' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22).

## 9. `reviews.slop_detection` y `reviews.post_merge_actions`

```yaml
reviews:
  slop_detection:
    enabled: true               # default true. "Available for public repositories on all plans
                                 # and private repositories on the Essentials plan and above"
                                 # (cita literal del schema) — desde 2026-08-21 también en
                                 # repos PRIVADOS, no solo públicos como documentaba el skill v2.
    include_all_authors: false  # default false. Si true, corre también para maintainers/owners.
    label: "slop"                # STRING opcional. Label a aplicar cuando se clasifica como slop.

  post_merge_actions: []        # array, maxItems 5. CADA acción: {enabled, name (≤100 chars),
                                 # prompt (≤10 000 chars)}. Corre DESPUÉS de mergear.
                                 # Existe en el schema; NO ACTIVAR sin decisión explícita del lead
                                 # — no hay guía dedicada de la doc oficial ni caso de uso
                                 # evaluado para este repo, y sería un cambio de arquitectura de
                                 # fábrica (post-merge automatizado) fuera de esta issue.
```

Fuente: `jq '.properties.reviews.properties.slop_detection, .properties.reviews.properties.post_merge_actions' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22); fecha del cambio a privados: changelog "Private Slop Detection" 2026-08-21.

## 10. `chat`

```yaml
chat:
  auto_reply: true              # default true. CR responde sin necesidad de mención/tag.
  art: true                     # default true. Genera arte ASCII/emoji en respuestas de chat.
  allow_non_org_members: true   # default true. Si false, restringe la interacción por chat/
                                 # comentario a miembros de la organización de GitHub.
  integrations:
    jira:
      usage: auto                # auto | enabled | disabled (default auto)
                                  # "auto" DESACTIVA la integración solo en repos PÚBLICOS.
    linear:
      usage: disabled             # RECOMENDADO explícito en este repo (ver nota abajo).
```

**Gotcha crítico para esta casa**: `chat.integrations.linear.usage: auto` (el default) solo
desactiva la creación de issues de Linear desde el chat en repos **públicos**. Este repo es
**privado** → con el default, CodeRabbit puede crear issues de Linear directamente desde un
comentario de chat de un PR, **fuera** del flujo obligatorio de `talent-issue-craft` (CLAUDE.md
regla 21: toda issue debe pasar por ese pipeline con initiative/project/labels correctos).
Recomendación: `chat.integrations.linear.usage: disabled` explícito en el `.coderabbit.yaml` del
repo (issue de higiene aparte, fuera de esta reescritura del skill — ver `SKILL.md`). Lo mismo
aplica, en menor medida, a `chat.integrations.jira.usage` si el repo llegara a usar Jira.

Fuente: `jq '.properties.chat' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22).

## 11. `knowledge_base`

```yaml
knowledge_base:
  opt_out: false                   # default false. true → desactiva KB completamente (privacidad).

  automatic_linking_mode: disabled  # auto | enabled | disabled (default disabled). SUSTITUYE a
                                     # automatic_repository_linking (ver nota DEPRECATED abajo).
  linked_repositories:               # array, maxItems 20. Forma: {repository, instructions}.
    - repository: "ejemplo/otro-repo"
      instructions: "Contiene los Edge Functions compartidos de embeddings."

  learnings:
    scope: auto                    # local | global | auto (default auto)
    approval_delay: 0              # INTEGER 0-30, default 0. Días que un admin tiene para
                                    # aprobar/rechazar un learning antes de que se aplique solo.
                                    # 0 = se aplica inmediatamente sin aprobación.

  issues:
    scope: auto                    # Contexto de issues de GitHub/GitLab (NO Jira/Linear).

  jira:
    usage: auto                    # auto | enabled | disabled (default auto; "auto" desactiva
                                    # solo en repos públicos — este repo es privado → activo)
    project_keys: []               # array de strings. Restringe el contexto a estos proyectos.
    excluded_project_keys: []      # array de strings. Exclusión a nivel workspace, tiene
                                    # precedencia sobre cualquier allowlist.

  linear:
    usage: disabled                 # RECOMENDADO explícito — misma razón que chat.integrations.linear
    team_keys: []                   # array de strings. Restringe el contexto a estos equipos ("ENG").

  code_guidelines:
    enabled: true
    filePatterns:
      # FORMA 1 (string plano): se auto-detecta como guideline Y SE SCOPEA al directorio del
      # propio fichero — NO gobierna el resto del repo.
      - "CLAUDE.md"
      # FORMA 2 (objeto, la que sí gobierna otros directorios):
      - files: "docs/decisions/**"
        applyTo: "src/**"          # <- sin esto, un ADR en docs/decisions/ solo se aplicaría
                                    #    como guideline a ficheros DENTRO de docs/decisions/.

  web_search:
    enabled: true                  # default true. Usa búsqueda web como contexto adicional.

  mcp:
    usage: auto                    # auto | enabled | disabled (default auto)
    disabled_servers: []           # array de strings (labels de servidor MCP a excluir).

  pull_requests:
    scope: auto                    # Contexto de PRs previos del repo para detectar patrones.
```

Puntos verificados contra el schema (todos con `jq` el 2026-09-05; re-verificados sin cambios el 2026-09-22):

- **`automatic_repository_linking` está DEPRECATED**: `"description": "Automatic Repository
  Linking | Deprecated. This setting has no effect. Use knowledge_base.automatic_linking_mode
  instead."` (cita literal, `"deprecated": true`). Si aparece en un YAML copiado del skill viejo,
  no hace nada — sustituir por `automatic_linking_mode` + `linked_repositories[]`.
- **`issues.scope` NO cubre Jira ni Linear.** Son claves propias (`knowledge_base.jira`,
  `knowledge_base.linear`) con estructura distinta (`project_keys`/`excluded_project_keys` para
  Jira, `team_keys` para Linear) — no hay un `scope: auto` compartido para las tres fuentes.
- **`code_guidelines.filePatterns` con string plano se auto-descubre pero se SCOPEA al directorio
  del propio fichero.** Solo la forma objeto `{files, applyTo}` hace que una guía en
  `docs/decisions/**` gobierne la revisión de `src/**`. El `.coderabbit.yaml` vivo de este repo usa
  la forma string plana (`filePatterns: ["CLAUDE.md", "AGENTS.md", "docs/decisions/**",
  "docs/explanation/**"]`) — casi con certeza esas guías NO se están aplicando a la revisión real
  de código fuera de esos mismos directorios (issue de higiene del yaml vivo, fuera de esta
  reescritura del skill).
- `filePatterns` por default ya incluye auto-detect de `**/CLAUDE.md`, `.github/copilot-
  instructions.md`, `**/AGENTS.md`, `**/GEMINI.md`, `**/.cursorrules`, `**/.cursor/rules/*`,
  `**/.windsurfrules`, `**/.clinerules/*`, `**/.rules/*`, `**/REVIEW.md` — no hace falta listarlos
  si ya existen con esos nombres.

Fuente: `jq '.properties.knowledge_base' schema.v2.json` (2026-09-05; re-verificado sin cambios de
schema 2026-09-22); confirmación cruzada <https://docs.coderabbit.ai/knowledge-base> y
<https://docs.coderabbit.ai/knowledge-base/code-guidelines> (consultados 2026-09-05, no
re-fetcheados hoy).

## 12. `code_generation` e `issue_enrichment`

```yaml
code_generation:
  docstrings:
    language: es                 # enum ISO (incluye es, es-AR, pt-BR, etc.)
    path_instructions:
      - path: "src/lib/**"
        instructions: "Document exported functions with JSDoc, en español."
  unit_tests:
    path_instructions:
      - path: "src/**"
        instructions: "Prefer Vitest; cover error branches."

issue_enrichment:
  auto_enrich:
    enabled: false               # default false. Analiza y enriquece issues nuevos automáticamente.
  planning:
    enabled: true                 # default true ("early preview"). Genera plan de implementación.
    auto_planning:
      enabled: true
      labels: ["feature", "!wip"] # "!" niega
  labeling:
    labeling_instructions:
      - label: "enhancement"
        instructions: "New feature or request."
    auto_apply_labels: false      # default false
```

`code_generation` **configura CÓMO** se genera contenido (idioma, path instructions); es distinto
de `reviews.finishing_touches`, que es el **toggle** de qué se genera (docstrings/unit_tests como
finishing touch) — ambos coexisten, no es un rename. `issue_enrichment` es el nombre de schema v2
del flujo que la doc de producto llama "CodeRabbit Plan" — opera sobre issues de GitHub/GitLab, no
sobre Linear/Jira.

Fuente: `jq '.properties.code_generation, .properties.issue_enrichment' schema.v2.json` (2026-09-05; re-verificado sin cambios 2026-09-22).

## 13. Errores comunes

Claves y sintaxis que **no existen** en el schema v2 vigente — si aparecen en un YAML (propio o
copiado), son inválidas y CodeRabbit las ignora en silencio (no rompen el parseo porque los objetos
anidados no fijan `additionalProperties: false`, pero tampoco hacen nada):

| Clave/sintaxis inválida | Por qué falla | Alternativa correcta |
|---|---|---|
| `reviews.tools.bandit` | No existe en las 59 tools del schema | No hay tool con ese nombre; para Python usar `ruff`, `pylint`, `flake8`, `semgrep`/`opengrep`, `osvScanner` |
| `reviews.tools.prettier` | No existe | `biome` (formatter+linter) o `eslint` |
| `reviews.tools.kubelinter` / `kube-linter` | No existe | No hay equivalente directo en las 59; usar `checkov`/`trivy` para IaC |
| `reviews.tools.dotnet_format` / `dotnet-format` | No existe | No hay equivalente en las 59 tools |
| `reviews.tools["github-checks"].timeout_ms` | El objeto solo tiene `enabled` | `github-checks: {enabled: true}` — sin timeout configurable |
| `pre_merge_checks.docstrings: true` (booleano directo) | Todo objeto de `pre_merge_checks.*` requiere `mode` | `docstrings: {mode: error, threshold: 80}` |
| `knowledge_base.automatic_repository_linking: true` | `"deprecated": true`, "has no effect" | `automatic_linking_mode: enabled` + `linked_repositories[]` |
| `knowledge_base.issues.scope` para Jira/Linear | `issues` es solo GitHub/GitLab | `knowledge_base.jira.usage` / `knowledge_base.linear.usage` |

**Retirado el 2026-09-22**: `reviews.tools["ast-grep"].enabled` figuraba aquí como inválido; desde
el cambio de schema de esa fecha (§6) el objeto SÍ tiene `enabled` propio — dejó de ser un error
común y se retira de esta tabla para no enseñar una alternativa que ya no hace falta.

La sección **"Errores comunes"** de este documento es la única parte del skill donde estos nombres
inválidos deben aparecer — en cualquier otro sitio (plantillas, ejemplos, `SKILL.md`) su presencia
es un defecto a corregir.

## 14. Validación y alcance fuera de este documento

```bash
# YAML bien formado (sintaxis, no schema):
python3 -c "import yaml; yaml.safe_load(open('.coderabbit.yaml'))" && echo "YAML válido"

# Validación contra el schema oficial vigente (CLI ≥0.7.1, no consume cuota de review):
coderabbit config validate .coderabbit.yaml
```

Ver `references/cli-review.md` para el resto de subcomandos del CLI. Para confirmar en vivo qué
config está aplicando CodeRabbit (merge de este YAML + defaults de la org), comentar
`@coderabbitai configuration` en un PR real — eso sí consume la cortesía de un comentario del bot
pero no una review.

**Deliberadamente fuera de alcance** de esta referencia (Example Project opera 100% en GitHub.com):

- **Learnings API** y el ciclo de vida completo de learnings más allá de `knowledge_base.learnings`.
- **Change Stack**: la interfaz de inspección por capas del review (`pr-reviews/change-stack`) es
  una feature de producto sobre cómo se PRESENTA el review en la UI, no una propiedad de
  `.coderabbit.yaml` — no confundirla con las fechas de soporte multi-VCS (GHES/GitLab/Azure
  DevOps), que son un frente aparte y tampoco tocan este YAML.
- **Multi-VCS** (GitHub Enterprise Server, GitLab, Azure DevOps): el producto lo soporta, pero este
  repo es GitHub.com — decisión consciente, no omisión.

## 15. Alternativa: `.coderabbit.config.ts`

Publicado en el changelog oficial el **2026-09-16** ("Dynamic CodeRabbit configuration with
TypeScript"; fuente: `docs.coderabbit.ai/changelog`, entrada del 16-sep, y
`docs.coderabbit.ai/configuration/typescript-configuration`, ambas consultadas 2026-09-22). No
sustituye a este documento — el schema v2 y `coderabbit config validate` siguen siendo la fuente de
verdad de QUÉ propiedades existen; esto es solo una forma alternativa de ESCRIBIR esa config.

- **Fichero**: `.coderabbit.config.ts` en la raíz del repo, en vez de (o además de, ver precedencia
  abajo) `.coderabbit.yaml`.
- **SDK opcional**: paquete npm `@coderabbitai/config` — da autocompletado de editor y type
  checking en CI; no es necesario para que el fichero funcione en runtime. Verificado en el
  registro npm el 2026-09-22 (`npm view @coderabbitai/config version dist-tags`): existe, publicado,
  `dist-tags.latest = 1.0.0` (`dist-tags.next = 0.1.0`) — la doc oficial lo referencia como
  `@coderabbitai/config@next` en su ejemplo de instalación, pero el registro ya tiene un `latest`
  estable 1.0.0 por encima del tag `next`.
- **API expuesta**: `defineConfig()` (objeto de config o factory `async`/síncrona que recibe un
  `context` con metadata del PR), `mergeConfig()` (merge profundo left-to-right: objetos se
  fusionan recursivamente, arrays se concatenan, escalares se sobrescriben) e `includeRemote()`
  (fetch en build-time de fragmentos compartidos, SOLO desde el repo `{owner}/coderabbit` de la
  organización — el repo origen no es configurable).
- **Condiciones por PR**: la factory recibe metadata del PR (autor, labels, ficheros cambiados,
  ramas origen/destino, equipos del autor, topics/custom properties del repo) para decidir config
  distinta según el PR — ej. un perfil `chill` salvo que el PR sea un hotfix.
- **Includes locales**: imports relativos de ficheros TypeScript o YAML del propio repo con sintaxis
  estándar; funcionan sin extensión (`CodeRabbit` prueba `.ts`, `.mts`, `.cts`, `.js`, `.mjs`,
  `.cjs`, `.yaml`, `.yml`).
- **Precedencia con YAML**: un `.coderabbit.yaml` (o `.coderabbit.yml`) committeado **siempre** gana
  sobre `.coderabbit.config.ts` si ambos coexisten — cita literal de la doc: *"A committed
  `.coderabbit.yaml` (or `.coderabbit.yml`) always takes precedence over `.coderabbit.config.ts`"*.
  Este repo usa YAML (`.coderabbit.yaml` en la raíz) → el `.ts` queda sin efecto salvo que se
  retire el YAML, decisión que esta reescritura NO toma por su cuenta.
- **Descubrimiento por el CLI**: el CLI busca primero YAML soportado; solo si no lo encuentra
  localmente pasa a `.coderabbit.config.ts` (`cr review` local, CLI ≥0.7.7 — changelog 15-sep).

```ts
// .coderabbit.config.ts — ejemplo oficial (hotfix con perfil distinto)
import { defineConfig, mergeConfig, includeRemote, type CodeRabbitContext } from "@coderabbitai/config"

function isHotfix(ctx: CodeRabbitContext): boolean {
  const pr = ctx.pr
  if (!pr) return false
  return /hotfix/i.test(pr.title) || pr.labels.some((l) => l.toLowerCase() === "hotfix")
}

const hotfix = includeRemote({ path: "hotfix.coderabbit.config.ts" })

export default defineConfig((ctx) =>
  mergeConfig(
    { reviews: { profile: "chill" } },
    isHotfix(ctx) ? hotfix : {}, // {} = no-op cuando no es hotfix
  ),
)
```

No hay decisión tomada de migrar este repo a `.coderabbit.config.ts` — se documenta como alternativa
vigente, no como recomendación. Cambiar de YAML a TS es una decisión de arquitectura del `.coderabbit.yaml`
vivo, fuera de alcance de esta referencia (regla 7 de CLAUDE.md: decisiones mayores requieren
aprobación explícita del lead).

## Gotchas y referencias cruzadas

- `references/rate-limits.md` — cuotas por plan de `custom_checks`, `finishing_touches.custom`,
  `linked_repositories` y MCP; el schema define techos de forma (`maxItems`) que pueden ser
  **mayores** que el techo real del plan contratado (ej.: `custom_checks` acepta 50 en el schema,
  pero Team hoy solo permite 10 — el resto se ignora o falla al guardar, según la org).
- `references/comment-taxonomy.md` — cómo se etiquetan los comentarios que generan estas tools y
  los checks de `pre_merge_checks`.
- `references/gate-cli-del-repo.md` — cómo el gate CR-CLI de este repo invoca `coderabbit config
  validate` y qué hace con los findings que `reviews.tools.*` produce.
- `talent-merger/references/04-coderabbit-cli-y-app.md` — doctrina de estación que decide CUÁNDO
  se toca el `.coderabbit.yaml` vivo de producción (este documento es solo referencia de schema,
  no autoriza cambios al yaml real).
