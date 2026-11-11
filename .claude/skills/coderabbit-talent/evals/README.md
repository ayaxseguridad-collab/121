# Evals de `coderabbit-talent`

`evals.json` define ≥3 escenarios ciegos (`"blind": true`) para medir si la
v3 del skill cierra las brechas que dejaba la v2. Este bloque **no los
ejecuta** — los corre el coordinador con subagentes ciegos, en dos comparativas:

1. **Con-skill vs sin-skill**: mismo `prompt`, un subagente sin ningún
   fichero del skill y otro con los `files_needed` del escenario.
2. **A/B ciego v2 vs v3**: mismo `prompt`, un subagente con el snapshot
   congelado de la v2 (pre-ABC-5478) y otro con la v3 de esta rama.

Cada entrada de `expected` es un criterio verificable por grep, código de
salida de un comando, o parseo de un fichero — no por juicio subjetivo del
evaluador. El resultado de una corrida se registra en `results-<fecha>.md`
(no incluido en este commit: lo genera el coordinador al correr los evals).

## Escenarios

| id | Qué mide |
|---|---|
| `triage-pr-2182` | Triage real usando `fetch_cr_comments.sh` sobre un PR con comentarios de CodeRabbit; distingue `is_committable` de `has_ai_prompt`; informe con secciones fijas. |
| `new-node-ts-repo-yaml` | Un `.coderabbit.yaml` de partida para un repo Node/TS nuevo que sea válido contra el schema v2 (`coderabbit config validate`), sin tools inexistentes ni claves muertas. |
| `diagnose-blocked-push-and-rate-limit` | Diagnóstico correcto de tres síntomas que se confunden fácilmente: gate local del repo, rate limit del producto (status `FAILURE` no es veredicto), y `--type` retirada en CLI ≥0.7.0. |

## Cómo correrlos (fuera de este bloque)

1. Congelar un snapshot de la v2 (commit previo a ABC-5478) y de la v3
   (HEAD de esta rama) — mismo patrón que `stripe-skill/evals/`.
2. Por cada escenario, lanzar 2 (sin-skill/con-skill) o 2 (v2/v3) subagentes
   con el mismo `prompt` y, cuando aplique, los `files_needed`.
3. Evaluar cada `expected[].pass_if` de forma mecánica sobre la transcripción
   o el artefacto producido.
4. Volcar resultado a `results-<fecha>.md`: una fila por
   (escenario, condición, criterio, pass/fail) + `runs-<fecha>/` con las
   respuestas crudas.

No se han corrido evals en este bloque: `evals.json` es el harness, no el
resultado.

## Corrector

`runs-2026-09-05/grade.sh [dir]` es el corrector mecánico que produjo `results-2026-09-05.md`: comprueba por
palabras clave y estructura mínima (a propósito: cambiar su semántica invalidaría ese registro), imprime la tabla y sale con `1` si
hay algún FAIL. Por defecto lee las corridas de su propio directorio.
