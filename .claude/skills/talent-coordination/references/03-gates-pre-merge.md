# Gates Pre-Merge — Complete Reference

## Table of Contents

1. [El contrato del gate](#1-el-contrato-del-gate)
2. [Gate de diff completo](#2-gate-de-diff-completo)
3. [Re-STOP: diff-of-diffs](#3-re-stop-diff-of-diffs)
4. [Checklist por tipo de cambio](#4-checklist-por-tipo-de-cambio)
5. [Auditoría retroactiva (merge sin gate)](#5-auditoria-retroactiva-merge-sin-gate)
6. [Reviewers automáticos caídos](#6-reviewers-automaticos-caidos)
7. [El veredicto](#7-el-veredicto)
8. [Gotchas & Cross-References](#8-gotchas--cross-references)

---

## 1. El contrato del gate

TODO PR de carril pasa por el gate del coordinador ANTES del squash. El carril
abre el PR, publica su STOP (evidencia de validación incluida) y ESPERA el GO
explícito. La urgencia no exime: un gate express de CSS tarda minutos.

```text
STOP del carril ──► coordinador baja el diff REAL ──► audita ──► veredicto
   (o el BARRIDO detecta el PR abierto sin STOP)     (gh pr diff N — jamás del reporte)
```

Principio: el reporte del carril ORIENTA el gate, no lo sustituye. Los checks
que el carril dice haber pasado se contrastan con el estado real del PR
(`gh pr view --json statusCheckRollup,mergeable`). El STOP **dispara** el gate,
pero el gate **ya no depende SOLO del reporte**: el barrido de supervisión activa
(SKILL.md §"Loop") detecta también los carriles que abrieron PR o terminaron sin
STOP — esa es la **verificación por nivel** hacia abajo. Un PR abierto que el
barrido descubre se gatea igual, no se espera un STOP que quizá no llegue.

## 2. Gate de diff completo

Cuándo: primer STOP de un PR, o SIEMPRE que el coordinador no tenga registro
propio de una auditoría previa (aunque el carril cite "el diff que ya
auditaste" — los carriles confunden interlocutores entre máquinas).

```bash
gh pr diff <N> > /tmp/pr<N>.diff && wc -l /tmp/pr<N>.diff
gh pr view <N> --json files,mergeable,statusCheckRollup
# Leer el diff ENTERO. En diffs >2k líneas, por bloques — sin saltarse los tests.
```

Qué busca el gate (en orden): seguridad (authz, RLS, secrets, spoofing,
XSS/inyección) → correción (lógica, races, idempotencia, estados terminales)
→ contratos (firmas, shapes, compat con lo desplegado) → BD (ver checklist) →
tests (¿prueban lo que dicen? ¿asserts empíricos?) → convenciones del repo.

## 3. Re-STOP: diff-of-diffs

Cuándo: el PR vuelve tras un fix/rebase solicitado. El delta debe ser SOLO lo
declarado.

```bash
gh pr diff <N> > /tmp/pr<N>-v2.diff
diff /tmp/pr<N>.diff /tmp/pr<N>-v2.diff > /tmp/pr<N>-delta.txt
wc -l /tmp/pr<N>-delta.txt   # leerlo ENTERO
```

Interpretación del delta: cambios de `index <hash>` y offsets `@@` = main se
movió (inofensivo); líneas de contenido = deben mapear 1:1 con lo que el
carril declaró. Para renames de migración: verificar contenido byte-idéntico
extrayendo ambos cuerpos y comparándolos.

## 4. Checklist por tipo de cambio

| Tipo | Checks obligatorios del gate |
|------|------------------------------|
| Migración BD | Timestamp libre en `main` Y en ledger de prod EN ESTE MOMENTO · serie del carril o post-head justificado · idempotencia/no-op donde aplique · RLS en tablas nuevas · ACLs explícitas en funciones · no reabre revokes de otras migraciones · orden de replay válido (objetos tocados nacen antes) · plan de apply correcto (`--include-all` si out-of-order) |
| RPC/SQL | Patrón del repo (p. ej. impl DEFINER + wrapper INVOKER) · gates DENTRO del impl (auth, acceso, flags, estado terminal COMPLETO del pipeline que toca) · errcodes estables · anti-spoof (nada de actor por parámetro) · throttles con lock si hay carrera |
| UI/CSS | Solo presentación si así se declaró · data-testids conservados · responsive multi-viewport con capturas · a11y (un solo `<a>` por card, focus visible) |
| Tests | Prueban el efecto OBSERVABLE · idempotencia con asserts de BD (deltas sobre baseline, no absolutos) · cleanup que LANZA si falla · guards anti-prod en specs que mutan · skips dinámicos documentados |
| Config/infra | Alcance mínimo · sin secrets · reversible · documentado dónde toca |
| Todo tipo | **Sentinel de push vigente para el HEAD del PR** — ver §6, evidencia obligatoria en el STOP |

## 5. Auditoría retroactiva (merge sin gate)

Si un merge entra sin gate (pasa — tres veces pasó):

1. Auditoría retroactiva INMEDIATA del diff mergeado, mismo rigor.
2. Hallazgos → fix-forward urgente (nueva issue, mismo carril).
3. Refuerzo del protocolo en el SIGUIENTE prompt de ese carril ("STOP significa
   esperar el GO") + anotar la ocurrencia (3 ocurrencias = regla reforzada).
4. Sin drama y sin perdón: el dato es que las retroactivas salieron limpias
   "hasta que un día no" — esa frase va en el refuerzo.

## 6. Reviewers automáticos caídos

```text
Reviewer (CodeRabbit/etc.) en fail "administrativo" (créditos/billing/caído):
├── ¿El check es REQUIRED en branch protection? ── SÍ → desbloquear primero
│   (dismiss/bypass según política del repo, con registro)
└── NO → PRECEDENTE: avanzar con el gate del coordinador como única review.
    Primera vez: decisión explícita registrada. Siguientes: citar el precedente.
    SIEMPRE: avisar al lead (recargar créditos es decisión de billing suya)
    y propagar el estado del reviewer a TODOS los carriles (no viaja solo).
```

Review legítima del reviewer (hallazgos reales): bloqueantes se atienden antes
del GO (severidad > minor / P0-P1); cosmético se cierra sin fix y no bloquea.

### Evidencia del sentinel de push (TAL-1518) — obligatoria en TODO STOP

El repo bloquea `git push` sin un sentinel válido para el SHA exacto empujado
(`.githooks/pre-push`). Hay DOS rutas — el gate exige que el STOP declare
CUÁL aplica al carril y su evidencia, ANTES del GO:

| Ruta del carril | Sentinel | Qué exige el gate |
|---|---|---|
| **Flujo clásico no-draft** (el que coordina este skill: terminales sueltos, fuera del sistema de canales) | `.claude/.cr-review-ok` | El STOP **lee `.claude/.cr-review-ok` y verifica que contiene el SHA EXACTO del HEAD del PR** que se empujará (prueba de que `scripts/cr-review.sh` corrió limpio sobre ESE head, no sobre uno anterior). En la ruta `deferred`, el **label `cr-review` por sí solo NO es evidencia suficiente**: exige además el artefacto equivalente que emite esa ruta, validado contra el MISMO SHA. Sin esa evidencia SHA-exacta, el gate NO da GO — dar GO sin ella es dar GO a ciegas sobre un push que el propio hook no habría dejado salir. |
| **Canal de producción** (Fábrica v2 / ADR-0043, fuera del alcance normal de este skill) | `.claude/.draft-handoff` | Exención del gate CR: el canal entrega PR draft + HANDOFF y NO corre CodeRabbit — lo consume EXCLUSIVAMENTE el Mergeador (`talent-merger`) sobre ese PR. El gate del coordinador de este skill no aplica en esa ruta. |

Ambas rutas son independientes del **Gate 1 de auditoría** (`.claude/.audit-go`,
`check-push-audit.sh`): ninguna las exime — el código auditado sigue siendo
requisito previo al push en las dos.

## 7. El veredicto

Formato fijo, TODOS los hallazgos en una pasada (sin ping-pong de NO-GOs):

```text
## Dictamen gate #<PR> — GO ✅ | NO-GO (n bloqueantes) | GO condicionado
### 🔴 Bloqueantes (si los hay): hallazgo + FIX exacto paso a paso
### ✅ Auditado en verde: qué se revisó y por qué pasa (citar lo notable)
### Observaciones no bloqueantes: deudas/avisos (capturar como issue si toca)
### Instrucción de ejecución: comando de merge + post-merge (apply/reconcile/
    advisors si hay BD) + qué reportar de vuelta
```

El GO es del CONTENIDO; si un required check sigue corriendo, el GO queda
"condicionado a su verde" (el merge fallaría igualmente sin él).

## 8. Gotchas & Cross-References

1. **El diff se baja, no se lee del reporte** → El texto del STOP puede estar
   desactualizado respecto al HEAD real del PR.

2. **`mergeable: CONFLICTING` se detecta en el gate, no en el merge** → Mirar
   `mergeable` SIEMPRE; si conflictúa, instruir el rebase con la resolución
   esperada (qué se combina, qué prevalece) antes del re-STOP.

3. **Dos carriles endureciendo el mismo helper = conflicto seguro** → Archivos
   de memoria compartida (gotchas, setups de test) los tocan todos; en el GO
   recordar "combina ambos bloques, no pises".

4. **El gate de tests lee los tests** → Un PR con tests excelentes se gatea
   igual: ¿el assert mide el efecto o el optimista? ¿el cleanup lanza? ¿el
   baseline es delta o absoluto?

5. **Los hallazgos del gate enseñan** → El dictamen cita QUÉ está bien y por
   qué (los carriles aprenden del gate; la calidad media sube sesión a sesión).

Cross-references: timestamps/colisiones → `06-carriles-y-recursos.md` ·
verificación post-merge → `05-verificacion-independiente.md`.
