# Perfil de repo — parametrización de talent-issue-craft

Plantilla VACÍA. Cada repo adoptante la rellena una vez y la guarda donde su proyecto documente (recomendado: junto a la doc de referencia del repo, enlazada desde su archivo de instrucciones raíz). Las plantillas y rúbricas del skill referencian estos parámetros — el skill no trae ninguno de fábrica.

## 1. Identidad y stack

| Parámetro | Valor |
|---|---|
| Nombre del repo/producto | |
| Stack principal (solo lo que afecta a matrices: ¿UI web? ¿BD relacional con políticas de fila? ¿API pública?) | |
| Idiomas del producto (para la matriz FRONT) | |
| ¿Multi-tema (claro/oscuro)? | |

## 2. Checks/gates del repo

| Gate | Comando | ¿Bloqueante? |
|---|---|---|
| [typecheck] | | |
| [lint] | | |
| [build] | | |
| [tests unit] | | |
| [otros del repo] | | |

## 3. Régimen de cierre

- Default: PR + revisión + fusión (magic word de cierre del tracker en el PR).
- Enriquecido (solo si el repo lo declara): [p. ej. aplicar migraciones a producción post-fusión + validaciones del motor; gate editorial para contenido de cara al usuario; cierre manual con evidencia para operaciones de datos sin PR].

## 4. Superficies sensibles

[Lista de dominios que activan la variante `seguridad` y el cuidado reforzado: auth, pagos, credenciales, datos personales, migraciones destructivas… Con sus paths característicos si los hay.]

## 5. Convenciones

- Título de issue: [imperativo / `tipo(área): …` / …]
- Rama: [prefijos válidos]
- Estimate: [escala y tope por issue; qué pasa al excederlo (sub-issues)]

## 6. Destinatario de escalada

Cuando el ejecutor detecta que la premisa de la issue contradice el código/docs/tests reales (escalada-con-citas), escala a: **[autor de la issue / revisor / responsable — definir]**, por **[canal]**.

## 7. Escalera de enforcement (¿cuándo se corre `audit-issue`?)

Marcar el peldaño del modelo operativo de este repo:

- [ ] **Dev solo** → antes de empezar cada issue.
- [ ] **Equipo** → al pasar una issue de backlog a la lista de trabajo.
- [ ] **Multi-agente** → además, al agrupar lotes de trabajo y al asignar a un ejecutor.

**Regla de elegibilidad (idéntica en todos los peldaños)**: el gate operativo SOLO se satisface con una corrida `--issue` (evidencia remota completa) que termine con `classification_source=marker` + `operational_gate_eligible=true` + exit 0. `--file` (body-only) y cualquier override NUNCA lo acreditan — son pre-check de autoría y calibración.

## 8. Umbral de `audit-issue` y calibración

| Parámetro | Valor |
|---|---|
| Umbral `--min-score` vigente | [default genérico: 70 — recalibrar con corpus propio] |
| Método | `references/02-verificaciones.md` §10 (≥5 gold vs ≥5 malas → discriminación completa) |
| Última calibración | [fecha + link a la tabla de scores] |
| Próxima recalibración | [al acumular 10+ issues cerradas / fecha] |

## 9. Loop post-rechazo

- Registro de gaps ("¿la issue pudo haberlo prevenido?"): **[dónde — doc/etiqueta/hilo]**
- Responsable de iterar las plantillas con los gaps acumulados: **[quién]**
- Recordatorio: cambio de núcleo = canon + manifest + 9 plantillas en el MISMO cambio (`templates/00-nucleo.md` §mantenimiento).
