# 10 — Flujo CodeRabbit (STUB — trasladado en v6.0)

**Trasladado a `talent-merger` (ADR-0043 / TAL-2193).** El canal de producción **NO corre
CodeRabbit** (ni CLI ni App): entrega PR DRAFT + HANDOFF con `scripts/draft-handoff.sh`
(ver `references/02-pipeline-y-gates.md` §4) y el consumo de ambos buckets lo centraliza
el **Mergeador**.

La doctrina que vivía aquí está ahora en:

| Contenido v5.0 | Destino |
|---|---|
| Touchpoints CLI/App, PR-first, presupuestos | `talent-merger/references/04-coderabbit-cli-y-app.md` + runbook `docs/runbooks/coderabbit-cli-pre-pr.md` |
| PROC-04 (App muda tras rebase → PR nuevo) | `talent-merger` ref 04 → **PROC-M04** |
| PROC-05 (spending cap, taxonomía de waivers) | `talent-merger` ref 04 → **PROC-M05** |
| PROC-07 (rama con mayúsculas) | `talent-merger` ref 04 → **PROC-M07** |
| M8 / señales débiles / labels por REST | `talent-merger` ref 02 §7 + ref 04 §5 |
| Bootstrap de githooks en el canal | sigue vigente: `dispatch.sh` con `TCO_BOOTSTRAP_GITHOOKS=yes` activa `core.hooksPath=.githooks` (el hook ahora acepta el sentinel draft) |

Este stub conserva el filename por estabilidad de links (SKILL, ref 09 y CHANGELOG 5.0 —
histórico inmutable — lo citan como "ref 10").
