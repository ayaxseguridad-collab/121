---
name: talent-repo-onboarding
description: >
  Usar este skill al montar la fábrica (canales + estación de merge + gates locales) en un
  repositorio nuevo o al auditar la paridad de uno ya montado. Cubre: verificación de las
  5 capas (identidad, branch protection, scripts idénticos, equivalentes estructurales y
  entorno), checklist Definition of Ready (8 puntos), verificador de paridad
  `verify-repo-parity.sh` (read-only, fail-closed, exits 0/1/2/3 sellados), receipts de
  checks MANUAL, atestaciones GitHub, ensayo general E2E. Trigger cuando el usuario menciona:
  onboarding de repo, fábrica, paridad, branch protection, pre-push, verify-handoff,
  draft-handoff, local-gates, setup-githooks, capa A/B/C/D, IDÉNTICO, EQUIVALENTE,
  receipt, atestación, check MANUAL, ensayo E2E, DoR, Definition of Ready, montar canal,
  nuevo repo, verificar repo, auditar repo, clone nuevo, pre-push hook, cr-review en
  repo nuevo, coderabbit en repo nuevo, hookspath, issue-craft-perfil, linear_team_key.
when_to_use: >
  Al montar la fábrica en un repositorio nuevo o auditar la paridad de uno montado.
  También al crear el Anexo por repo, configurar branch protection, o antes de despachar
  el primer encargo de producción a un canal nuevo.
---

# Skill: talent-repo-onboarding

## Quick Orientation

**Versión 1.2** (2026-07-23 · paquete v1, TAL-3348/3349; base 1.1 TAL-3318, 1.0 TAL-3270).

Este skill canoniza el proceso de **onboarding de repos a la fábrica**: montar las 5 capas
de infraestructura que permiten a los canales y al Mergeador operar sin supervisión continua
del lead.

**Carve-out de canónicos (D4, paquete v1)**: los artefactos RAÍZ del flujo (hook `pre-push`,
scripts A4 `draft-handoff`/`verify-handoff`/`cr-review`/`audit-go`, plantilla HANDOFF) siguen
CANÓNICOS en el repo fundador (TA); SOLO el paquete de 9 skills es canónico en el motor
`talent-factory` y viaja motor-primero (`sync-package.sh`, overlays por repo intactos).

**Cuándo cargarlo**:
- Al inicializar un repo nuevo que recibirá encargos de producción.
- Al auditar un repo existente: `bash verify-repo-parity.sh <REPO_DIR>`.
- Al crear el Anexo por repo (ficha de identidad para el verificador y la estación de merge).

**Contexto del problema resuelto**: sin este proceso, cada repo nuevo requiere análisis
manual de paridad (caso CRM: 58 issues en ventana de 3 días). Este skill lo formaliza
como un checker ejecutable que certifica PARIDAD REAL, no mera presencia.

---

## Reference Files

| Archivo | Cuándo leer |
|---------|-------------|
| `references/01-capas-y-contratos.md` | Valores canónicos de A2 (12 campos), A2b (4 campos), B (IDÉNTICOS), C (EQUIVALENTES), D (entorno) |
| `references/02-anexo-por-repo.md` | Estructura del Anexo por repo; campos obligatorios (linear_team_key, superficies, autoridades) |
| `references/03-verificacion-y-ensayo.md` | DoR ejecutable, ensayo E2E, contrato completo de receipts + atestaciones |
| `assets/parity-manifest.tsv` | Manifiesto machine-readable que gobierna al verificador (UNA fila por artefacto) |
| `assets/plantilla-anexo-por-repo.md` | Plantilla para crear el Anexo de un repo concreto |
| `assets/plantilla-manifiesto-gates.md` | Plantilla del manifiesto de gates locales del repo destino |
| `assets/bloque-reglas-fabrica.md` | Bloque EQUIVALENTE (procedencia derivada) para CLAUDE.md/AGENTS.md del repo destino |
| `assets/coderabbit-politica.yaml` | Política base EQUIVALENTE para `.coderabbit.yaml` del repo destino |
| `scripts/verify-repo-parity.sh` | Verificador principal (READ-ONLY, gobernado por el manifiesto) |
| `assets/canon-paquete.tsv` | Mapa producto→paquete: de dónde sale el canon de los IDENTICOS dentro del propio ZIP |
| `tests/run-tests.sh` | Runner de los 46 casos sellados (canon del paquete + clave Linear + `.gitignore` + lectura estable incluidos) |

---

## Quick Start — Montar la fábrica en un repo nuevo

```bash
# 1. Clonar y configurar
git clone git@github.com:owner/repo.git && cd repo

# 2. Copiar IDÉNTICOS desde el PROPIO paquete de fábrica (el ZIP descomprimido): el canon viaja en él
#    (githooks/, plantillas/, scripts/…) y assets/canon-paquete.tsv traduce cada ruta del repo de
#    producto a su ruta en el paquete — SIN checkout de casa ni origen git (TAL-8037). NUNCA desde
#    origin/main del repo DESTINO: en un onboarding nuevo ese origin/main todavía no tiene los
#    canónicos — es justo lo que este paso instala. Mismo contrato que consume
#    verify-repo-parity.sh (por defecto deriva la raíz del paquete de la ubicación del skill;
#    TRO_CANON_PACKAGE_DIR la fija a mano). Override git explícito (checkout local de un repo que ya
#    tiene el canon): TRO_CANON_REPO_DIR/TRO_CANON_REF, como antes.
PKG_DIR="${TRO_CANON_PACKAGE_DIR:?Exporta TRO_CANON_PACKAGE_DIR=<raíz del paquete de fábrica descomprimido (talent-factory/)>}"
while IFS=$'\t' read -r prod rel; do
  case "$prod" in '#'*|'') continue ;; esac
  mkdir -p "$(dirname "$prod")"; cp -- "$PKG_DIR/$rel" "$prod"
  case "$prod" in *.sh|.githooks/pre-push) chmod +x "$prod" ;; esac
done < "$PKG_DIR/skills/talent-repo-onboarding/assets/canon-paquete.tsv"
bash scripts/setup-githooks.sh          # el INSTALADO: core.hooksPath=.githooks (elige .githooks/ porque ahí está pre-push)

# 3. Crear EQUIVALENTES (adaptar plantillas a las particularidades del repo)
#    Ver assets/bloque-reglas-fabrica.md, assets/coderabbit-politica.yaml

# 4. Configurar branch protection (A2) y repo settings (A2b)
bash scripts/setup-branch-protection.sh   # en el repo TA

# 5. Verificar (TF_LINEAR_TEAM_KEY es de la INSTANCIA: sin default de casa — sin ella, o sin la
#    línea TF_LINEAR_TEAM_KEY= del manifiesto, el checker sale con exit 2)
TF_LINEAR_TEAM_KEY=<KEY> bash .claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh .
# → exit 3 (MANUAL-PENDING): los 7 checks MANUAL aún sin receipts
# → exit 0 cuando se provean los 7 receipts válidos

# 6. Ensayo E2E (ver references/03)
```

---

## Modelo de 5 Capas

| Capa | Nombre | Contrato | Verificación |
|------|--------|----------|--------------|
| **0** | Identidad | `linear_team_key`, slug, initiative | Anexo por repo |
| **A** | Branch protection + repo settings | A2: 12 valores; A2b: 4 valores | API GitHub en vivo |
| **B** | Scripts IDÉNTICOS (10) | Hash bytes + modo + exec | `verify-repo-parity.sh` bloque 1 |
| **C** | Artefactos EQUIVALENTES (8) | Contrato estructural cerrado | `verify-repo-parity.sh` bloque 1 |
| **D** | Entorno del clon | hooksPath + skill + perfil | `verify-repo-parity.sh` bloque 1 |

**Capa B — cierre transitivo** (derivado por grep, no lista manual):
- `verify-handoff.sh` invoca `validar-rama-pr.sh` + `lib/handoff.sh`
- `draft-handoff.sh` invoca `validar-rama-pr.sh`
- `cr-review.sh` invoca `lib/cr-finding-normalize.jq`

---

## Definition of Ready (DoR) — 8 puntos

| # | Punto | Exit si falla |
|---|-------|--------------|
| 1 | A2: 12 valores de branch protection | 1 (FAIL) |
| 2 | A2b: 4 valores de repo settings | 1 (FAIL) |
| 3 | 10 scripts IDÉNTICOS (hash + modo + exec) | 1 (FAIL) |
| 4 | 8 artefactos EQUIVALENTES | 1 (FAIL) |
| 5 | Entorno D (hooksPath + skill + perfil) | 1 (FAIL) |
| 6 | Magic word con KEY del equipo Linear | 1 (FAIL) |
| 7 | Gates locales verdes (primer ciclo) | Manual |
| 8 | 7 receipts MANUAL válidos | 3 (PENDING) |

El verificador certifica automáticamente los puntos 1-6. Los puntos 7-8 son MANUAL (límites
honestos del token): requieren evidencia fuera del repo, documentada en receipts firmados.

---

## Critical Gotchas

1. **G1 — `linear_team_key` incorrecto**: Un key equivocado produce falsos negativos en el magic-word y falsos positivos en checks cruzados entre repos. Verificar siempre en Linear UI → team settings antes de ejecutar el verificador. Pasar `TRO_LINEAR_KEY=<KEY>` explícitamente.

2. **G2 — `core.hooksPath` sin activar**: Un script `.githooks/pre-push` byte-idéntico al canónico **nunca corre** si `core.hooksPath` no apunta a `.githooks`. Correr `bash scripts/setup-githooks.sh` una vez por clon. El verificador detecta esto (capa D, entorno:hookspath → exit 1).

3. **G3 — `auto_review.drafts: false` es obligatorio**: Si `.coderabbit.yaml` omite `drafts: false`, la App de CodeRabbit revisa los PRs en draft de los canales, consumiendo cuota y generando ruido. El verificador lo detecta (estructura:coderabbit, campo 2/3 → exit 1 si falta).

4. **G4 — `command grep` en matchers (nunca `grep` inline)**: El harness de tests puede alias `grep` a `ugrep`, que acepta `\d` y `(?i)` — falsos verdes garantizados. Usar siempre `command grep` con ERE POSIX (`[0-9]`, no `\d`; `-i`, no `(?i)`). El verificador cumple esta regla internamente; los scripts del repo destino también deben.

5. **G5 — Dos gramáticas del magic word**: Template PR: literal `Closes <KEY>-N` (template-check). PR body / receipts: `command grep -iE "(closes|fixes|resolves)[[:space:]]+<KEY>-[0-9]+"`. Mezclarlas produce falsos positivos (un template con `Closes ENG-N` pasa el check genérico pero falla el check por-KEY).

6. **G6 — GitHub Actions OFF ≠ sin gates**: El gate `local-gates` es el ÚNICO requerido en branch protection de `main`. Sin posteo del status tras correr los gates locales, el PR queda bloqueado aunque los checks hayan pasado. Flujo: `run-local-gates.sh` → `post-local-gates.sh <run_group> <slug> <pr>`.

7. **G7 — Receipts: attest_comment_id dentro de evidencia (bootstrap circular)**: Para emitir una atestación: (1) postear placeholder → obtener comment_id; (2) construir evidencia completa con ese ID; (3) calcular `evidencia_sha256 = sha256(jq -S -c .evidencia)`; (4) editar el comentario con la línea `attest v1 ...` final. Ver references/03.

8. **G8 — Canónicos: nunca desde `origin/main` del repo destino**: Copiar IDÉNTICOS SIEMPRE desde el canon del PROPIO paquete de fábrica (mapa `assets/canon-paquete.tsv`) o, como override explícito, desde un `CANON_DIR` (checkout local de un repo que ya tiene el canon) vía `git -C "$CANON_DIR" show "$CANON_REF:<path>"` — nunca desde el working tree ni desde `origin/main` del repo destino (en un onboarding nuevo ese remoto todavía no tiene los canónicos). Si el paquete (o el repo canónico) actualiza un canónico, el repo destino debe re-copiar para mantener paridad byte a byte.

9. **G9 — Plan-Free: exit 3 procedural**: Si GitHub responde 403 "Upgrade to GitHub Pro" en el check A2, el verificador emite MANUAL-PENDING (exit 3). El lead debe verificar y aplicar la protección proceduralmente. No es un error (exit 2); es el comportamiento correcto en plan Free.

10. **G10 — Lista de autoridades vacía → fail-closed**: `TRO_RECEIPT_AUTHORITIES` vacío hace que TODOS los receipts sean rechazados. Es el default correcto (fail-closed). Añadir los `user.id` de los firmantes autorizados en `assets/receipt-authorities.txt` del Anexo del repo.

11. **G11 — Artefactos fuera de git: sha256 fail-closed o NO hay entrega**: Todo artefacto del montaje que viaje fuera de git (manifiesto del motor, bundles de scripts, paquetes de skills para la flota) se entrega CON su sha256 declarado por el emisor, y el receptor lo verifica POST-instalación (`sha256sum -c` o comparación del digest) ANTES de usarlo. Un «vN entregado» sin hash verificado NO es una entrega — tratarlo como pendiente. Lección del arranque CRM (2026-07-22): horas de HOLD por un «paquete v3» citado que nunca existió. Ver references/03 §Entrega de artefactos fuera de git.

12. **G12 — Ruta EXACTA del validador de manifiestos del motor**: `.claude/skills/talent-channels/scripts/validate-manifest.sh` (repo TA). El validador vive en el skill `talent-channels`, NO dentro del motor — `talent-factory/scripts/validate-manifest.sh` NO existe, y citar esa ruta rompe la instrucción en el peor momento (montaje remoto sin nadie que corrija sobre la marcha).

---

## Cross-Skill Integration

| Skill | Cuándo usar juntos |
|-------|-------------------|
| `talent-channels` | Montar la infra de canales/estación/runners de la fábrica que servirá al repo; su `scripts/validate-manifest.sh` valida el manifiesto del motor (ruta exacta en G12) |
| `linear-skill` | Crear issue `<KEY>-<N>` tipo `chore` antes de empezar (la del Anexo del repo); mover a In Review al abrir el PR |
| `talent-channel-operation` | Los canales requieren el DoR completo antes del primer despacho |
| `talent-merger` | El Mergeador verifica HANDOFF y corre CodeRabbit; necesita el Anexo para superficies sensibles |
| `coderabbit-talent` | Si el Mergeador encuentra un finding bloqueante en el repo recién montado |
| `talent-issue-craft` | Crear issues de onboarding bien formadas (8 puntos del DoR como sub-tareas) |

---

## Next Steps

1. Completar los 7 receipts MANUAL para que `verify-repo-parity.sh` devuelva exit 0.
2. Correr el ensayo E2E completo (references/03) antes de activar el canal de producción.
3. Guardar el Anexo del repo en el repo TA como `docs/reference/onboarding-anexo-<slug>.md`.
4. Despachar el primer encargo con `talent-channel-operation` una vez el DoR está completo.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
