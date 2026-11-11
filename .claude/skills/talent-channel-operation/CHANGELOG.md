# Changelog — talent-channel-operation

- Modelos por rol y proveedor: PM en Opus vigente, código sensible en Opus y auditor Sol vigente con esfuerzo medio; independencia o degradación declarada.

- Pieza P2 (issue 8544): puntero, herramientas y doctrina del paquete en `scripts/paquete/`; lista de diez miembros tras retirar skill-creator.
- Pieza P11 (issue 8585): vigía de canal activo sin progreso (`scripts/behavior-watch.sh`, token PROGRESO-ESTANCADO, solo avisa), su escritor de runs (`scripts/run-state-write.sh`) y la columna `behavior` de `scripts/status.sh`; doctrina en la referencia 11, sección 10.

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 2.0.0)

- Plan-gate con Claude Code 2.1.318 (issue 10139): el CLI no vuelca al transcript el ExitPlanMode pendiente hasta que
  se contesta el diálogo, así que la segunda presentación tras un rechazo daba `extract-plan.sh` exit 19 sin salida.
  Con el transcript en rechazado u obsoleto y la sesión en `status: "waiting"` (`tco_plan_from_transcript` devuelve 6),
  el extractor hace UNA captura y, si el diálogo de plan está abierto y completo al final (`tco_plan_dialog_head_from`,
  predicado puro que no teclea), toma el plan de la pantalla (solo el bloque pegado al diálogo) con
  `origen=pantalla (transcript sin volcar)`. Exit nuevo 21: el plan es idéntico (mismo sha256 del texto normalizado
  solo en espacios en blanco) al de una ronda ya auditada. Sin `waiting`, sin captura y exit 19 como siempre. Sub-suite
  `tests/test-plan-pantalla.sh` con capturas reales de 2.1.318.

- Perfil de Codex del analizador del TUI: elige sus reglas por el CLI de cada panel (`TCO_TUI_CLI`, que fijan con
  `local -x` las entradas por panel desde el CLI declarado y que `00-config.sh` nunca hereda del entorno).
  Vacío o `claude` conserva las reglas de siempre; `codex` usa las suyas (compositor `›` sin bordes, línea de
  estado, ocupado por la última línea en columna 0 y lista de órdenes propia); cualquier otro valor da rc 2.
  Fixtures reales `codex_0.166.0` y prueba `tests/test-tui-codex.sh`.
- 1.7.4f: un «[Request interrupted by user]» final (o su variante «… for tool use]»), solo en la
  forma array de UN elemento `text` con el texto exacto (un string con ese texto es un humano),
  cuenta como reposo en `tco_transcript_inflight_from`, de modo que `tco_pane_busy` ya no ve «ocupado» tras el
  Escape del plan-gate y `tco_set_model`/`tco_set_effort` pueden abrir el picker. Un único predicado
  compartido (`_TCO_JQ_INTERRUPT_DEFS`) lo aplica también a `tco_exitplan_plan_from`,
  `tco_last_assistant_text_from` y `tco_user_submit_*`.
