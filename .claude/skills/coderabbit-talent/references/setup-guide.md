# Setup Guide: CodeRabbit GitHub App

> `last_verified: 2026-09-05`

Setup completo de CodeRabbit en un repo de GitHub usando el **GitHub App** (incluido en los planes de
pago Essentials/Team/Advanced/Enterprise). No cubre el uso del CLI para depurar a mano — eso vive en
`references/cli-review.md`; el CLI como **gate obligatorio pre-push** de este repo se documenta en
`references/gate-cli-del-repo.md`.

## Tabla de contenidos

1. [Alcance de este setup](#1-alcance-de-este-setup)
2. [Prerrequisitos](#2-prerrequisitos)
3. [Paso 1: Instalar el GitHub App](#3-paso-1-instalar-el-github-app)
4. [Paso 2: Confirmar que CodeRabbit está activo](#4-paso-2-confirmar-que-coderabbit-está-activo)
5. [Paso 3: Crear `.coderabbit.yaml`](#5-paso-3-crear-coderabbityaml)
6. [Paso 4: Commit y push](#6-paso-4-commit-y-push)
7. [Paso 5: Probar](#7-paso-5-probar)
8. [Paso 6: Integraciones para agentes (Claude Code y otros)](#8-paso-6-integraciones-para-agentes-claude-code-y-otros)
9. [Paso 7 (opcional): Habilitar Issue Planner](#9-paso-7-opcional-habilitar-issue-planner)
10. [Costos y límites por plan](#10-costos-y-límites-por-plan)
11. [Permisos reales del App](#11-permisos-reales-del-app)
12. [Deshabilitar temporalmente](#12-deshabilitar-temporalmente)
13. [Gotchas y referencias cruzadas](#13-gotchas-y-referencias-cruzadas)

## 1. Alcance de este setup

```text
  Instalación de CodeRabbit
     │
     ├─ GitHub App (este documento) ─▶ bot revisa PRs, chat @coderabbitai, YAML del repo
     │
     └─ CLI de pago (`references/cli-review.md`) ─▶ review local, JSON --agent, gate pre-push
                                                       (`references/gate-cli-del-repo.md`)
```

Este documento cubre el alta del **GitHub App** en GitHub.com — la integración canónica del workflow de
este skill. CodeRabbit también soporta GitLab / Azure DevOps / GitHub Enterprise Server, fuera de
alcance aquí (Talent opera 100% en GitHub.com).

> **Nota para ESTE repo:** además del GitHub App, el repositorio **exige el CLI de CodeRabbit como
> gate local obligatorio pre-push** (ABC-1518) — no es opcional. El hook `.githooks/pre-push` valida un
> sentinel por SHA. Ver `references/gate-cli-del-repo.md` para el contrato completo. El uso *ad-hoc* del
> CLI (correrlo suelto para depurar, fuera del gate) sigue bajo petición explícita del lead.

## 2. Prerrequisitos

- Plan CodeRabbit activo en la organización — hoy los planes de pago son **Essentials (ex Pro)**,
  **Team (ex Pro+)**, **Advanced** y **Enterprise** (ver mapping org→plan en `rate-limits.md`; detectar
  con `scripts/detect_plan.sh`).
- Admin access a la organización de GitHub (o al repo personal).
- `gh` CLI instalado y autenticado (`gh auth login`).

## 3. Paso 1: Instalar el GitHub App

El GitHub App se instala desde el navegador — no es automatizable:

1. Ir a **<https://github.com/apps/coderabbitai/installations/new>**.
2. Elegir la organización o cuenta personal.
3. Seleccionar repos:
   - **All repositories**: acceso a todos (futuros incluidos). Recomendado para orgs pequeñas.
   - **Only select repositories**: selección manual. Recomendado para orgs grandes.
4. Click **Install & Authorize**.
5. Serás redirigido a **app.coderabbit.ai** — completar el setup asociando la cuenta.

**Si ves "Request" en lugar de "Install"**: tu usuario no es owner de la org. Pide al owner que apruebe.

## 4. Paso 2: Confirmar que CodeRabbit está activo

**No existe con el token de usuario de `gh` un endpoint que confirme de forma autoritativa que el App
está instalado y con acceso a ESTE repo.** El endpoint REST «obtener la instalación de un repo para la
app autenticada» (`GET` sobre `/repos/<owner>/<repo>/installation`, escrito con separadores literales
para no invitar a copiarlo tal cual) exige autenticarse **como la propia App** vía JWT — con un token de
usuario devuelve `401 "A JSON web token could not be decoded"` **incluso cuando CodeRabbit SÍ está
instalado y activo** (falso negativo, verificado en vivo el 2026-09-05 contra este mismo repo). No uses
ese endpoint como prueba de instalación.

Usa en su lugar las señales honestas que documenta `SKILL.md` en «Verificar que CodeRabbit está activo
en el repo» (señales A-D):

- **(A)** ¿`coderabbitai[bot]` ha revisado PRs recientes de este repo? — evidencia histórica fuerte,
  no prueba estado actual.
- **(B)** ¿Existe `.coderabbit.yaml` en la raíz? — intención, no prueba de instalación.
- **(C)** Comentar `@coderabbitai review` en un PR y ver que responde AHORA — única prueba de estado
  actual.
- **(D)** Si eres owner de la org, `gh api --paginate 'orgs/{owner}/installations'` — inventario a
  nivel de org, con el límite de que puede dar falso positivo para repos con
  `repository_selection: "selected"` que no incluyan este repo.

Ver `SKILL.md` para el detalle completo de qué prueba cada señal y sus límites.

## 5. Paso 3: Crear `.coderabbit.yaml`

Esta skill tiene 9 plantillas en `../assets/coderabbit-templates/`:

```text
base-talent.yaml            # Punto de partida genérico (español, chill)
node-typescript.yaml        # package.json → TS/JS projects
python.yaml                 # pyproject.toml → Python
go.yaml                     # go.mod → Go
rust.yaml                   # Cargo.toml → Rust
solidity-defi.yaml          # hardhat/foundry → DeFi (Hyperliquid, Uniswap V3)
monorepo.yaml               # pnpm-workspace.yaml / turbo.json
docs-only.yaml               # Solo markdown
stack-internals.yaml  # Todo el stack de Example Stack con path_instructions
```

Usa `detect_project_type.sh` para auto-detectar:

```bash
TEMPLATE=$(bash scripts/detect_project_type.sh .)
cp "assets/coderabbit-templates/${TEMPLATE}.yaml" .coderabbit.yaml
```

Ajusta a tu repo específico: `reviews.path_filters` para carpetas generadas, `reviews.path_instructions`
con foco por subdirectorio. Antes de commitear, validar sin gastar cuota:

```bash
coderabbit config validate .coderabbit.yaml   # valida contra el schema oficial vigente; no consume review
```

**Dos vías nuevas para generar la config inicial** (además de copiar una plantilla a mano, que
sigue siendo el método de este skill): `coderabbit config` guiado por el CLI (≥0.7.7, changelog
15-sep-2026) — **`coderabbit config` A SECAS crea o modifica el `.coderabbit.yaml` del repo**
(`--generate` es su default; ver `--help` completo en `cli-0.8.0-help/config.txt`), por lo que este
skill nunca lo ejecuta sin supervisión explícita del lead, igual que el resto de subcomandos
mutantes del CLI (`references/gate-cli-del-repo.md`); y `.coderabbit.config.ts` (TypeScript,
changelog 16-sep-2026) — ver `references/yaml-reference.md` §15 para su schema, precedencia y
límites.

## 6. Paso 4: Commit y push

```bash
git add .coderabbit.yaml
git commit -m "chore(ci): add CodeRabbit config with Example Stack defaults"
git push
```

CodeRabbit lee la config en cada PR — no hay que reiniciar ni reinstalar.

## 7. Paso 5: Probar

1. Abrir un PR con cualquier cambio.
2. Esperar 1-3 min — CodeRabbit publicará un review completo automáticamente (si `auto_review` está
   habilitado; si el repo usa el modelo opt-in por label, ver §12 y `references/troubleshooting.md`
   §7).
3. Verificar que los comentarios están en español (confirma que `language: es-ES` funcionó).
4. Si no aparece review: ver `references/troubleshooting.md`, o forzar con
   `gh pr comment <PR> --body "@coderabbitai review"`.

## 8. Paso 6: Integraciones para agentes (Claude Code y otros)

Existen dos vías oficiales del vendor que este skill **no instala** por defecto — documentadas aquí
como referencia, a evaluar bajo decisión del lead antes de adoptarlas:

- **`coderabbit skills`** (subcomando de la CLI, ≥0.7.0): instala/actualiza skills verificadas de
  CodeRabbit para Codex, Claude Code, Cursor, Gemini CLI y GitHub Copilot, con preview de cambios antes
  de escribir. Detalle: `references/cli-review.md`.
- **`npx skills add coderabbitai/skills -a claude-code`**: instala dos skills comunitarias de autofix
  publicadas por CodeRabbit.

**No las instales si vas a usar `coderabbit-talent`** — esta skill ya cubre workflow pasivo + agentic +
triage + config usando el GitHub App y el gate CLI del repo, sin depender de esas skills externas.

Adicionalmente, existe un **plugin nativo de Claude Code** (`/plugin install coderabbit`, comando
`/coderabbit:review`) desde 2026-02, pensado para uso interactivo manual — no sustituye el gate
`cr-review.sh` del repo, que necesita el JSON `--agent` crudo para emitir sentinels deterministas. Ver
`references/cli-review.md` §«Ruta C».

## 9. Paso 7 (opcional): Habilitar Issue Planner

CodeRabbit Issue Planner integra con Linear, Jira, GitHub Issues, para que CR entienda el "por qué" del
PR antes de revisar código:

1. Ir a **app.coderabbit.ai** → Integrations → conectar Linear/Jira.
2. En tus PRs, incluir referencias a issues como `Closes #123` o `Fixes ABC-456`.
3. CR leerá el issue y adaptará el review al contexto.

**Cuidado**: si usas la integración de Linear vía chat de PR (`chat.integrations.linear.usage`, default
`auto`), CodeRabbit puede crear issues de Linear **directamente desde el chat**, fuera del flujo de
`talent-issue-craft`/`linear-skill` que exige proyecto de la initiative correcto y labels `vertical/*`
(CLAUDE.md regla 21). Si no se desea ese atajo, fijar `chat.integrations.linear.usage: disabled`
explícitamente. Detalle: `references/troubleshooting.md` §17.

## 10. Costos y límites por plan

| Plan | Precio (anual/mensual, USD/dev/mes) | PR reviews/dev/h | Ficheros/PR | Notas |
|---|---|---|---|---|
| Free | $0 | 1 | — | Solo summaries de PR (3/dev), CLI/IDE limitado, trial 14 días de Team |
| **Essentials** (ex Pro) | $24 / $30 | 5 | 150 | |
| **Team** (ex Pro+) | $48 / $60 | 8 estándar (hasta 10 si *grandfathered*) | 300 | Plan real de `ejemplo` — ver `rate-limits.md` |
| **Advanced** | $72 / $90 | 10 | 300 | Tier intermedio nuevo entre Team y Enterprise |
| Enterprise | Contactar ventas | 12 (sin límite adaptativo) | 300 | Self-hosting, SSO, RBAC, API access, audit logs |

Fuente: <https://docs.coderabbit.ai/management/plans> y
<https://docs.coderabbit.ai/management/rate-limits> (consultadas 2026-09-05); límite de ficheros por
plan también en changelog, entrada 2026-07-15: el tier hoy llamado Essentials (ex Pro) queda limitado a
150 archivos por review y el tier hoy llamado Team (ex Pro+) a 300, con techo global de 300.

**Add-on usage-based** (Essentials y superiores): consumo extra para seguir revisando al agotar la
cuota del plan (`--use-credits` en CLI, ver `references/cli-review.md`). NO hay reviews "ilimitados" en
ningún plan de pago; Enterprise es el único sin límite **adaptativo** (Fair Usage). Detalle completo:
`references/rate-limits.md`.

## 11. Permisos reales del App

Verificado en vivo contra este repo (`gh api orgs/{org}/installations`): `checks: write`, `issues:
write`, `actions: read`, `members: read`, `contents: write`, `metadata: read`, `statuses: write`,
`discussions: read`, `pull_requests: write`. La doc pública del vendor describe `checks` como
read-only — la instalación real lo tiene en `write` (discrepancia menor, sin impacto operativo
conocido). Fuente: `gh api` en vivo 2026-09-05; <https://docs.coderabbit.ai/platforms/github-com>.

## 12. Deshabilitar temporalmente

- **Pausar un PR específico**: añadir `@coderabbitai ignore` en la descripción del PR.
- **Pausar todo el repo**: comentar `@coderabbitai pause` en cualquier PR; reanudar con
  `@coderabbitai resume`.
- **Deshabilitar completamente**: GitHub Settings → Applications → CodeRabbit → Configure → remover el
  repo de la selección.

## 13. Gotchas y referencias cruzadas

1. **No uses el endpoint de instalación de la app (`/repos/<owner>/<repo>/installation`) como prueba de
   instalación** (§4) — da 401 con token de usuario aunque CR esté activo.
2. **`drafts: false` en este repo es intencional** (§7) — no lo cambies sin entender el modelo CR 2.0
   opt-in-por-label.
3. **`chat.integrations.linear` en `auto` puede crear issues fuera del flujo** (§9).
4. **No instales las skills/plugins oficiales del vendor si ya usas este skill** (§8) — se solapan.

**Referencias relacionadas:**

- Para el schema completo de `.coderabbit.yaml` → `references/yaml-reference.md`
- Para el gate CLI obligatorio del repo → `references/gate-cli-del-repo.md`
- Para instalar/usar el CLI fuera del gate → `references/cli-review.md`
- Para diagnosticar un fallo → `references/troubleshooting.md`
