# Changelog — talent-channel-operation

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 1.7.4, versión intermedia)

- 1.7.4f: un «[Request interrupted by user]» final (o su variante «… for tool use]»), solo en la
  forma array de UN elemento `text` con el texto exacto (un string con ese texto es un humano),
  cuenta como reposo en `tco_transcript_inflight_from`, de modo que `tco_pane_busy` ya no ve «ocupado» tras el
  Escape del plan-gate y `tco_set_model`/`tco_set_effort` pueden abrir el picker. Un único predicado
  compartido (`_TCO_JQ_INTERRUPT_DEFS`) lo aplica también a `tco_exitplan_plan_from`,
  `tco_last_assistant_text_from` y `tco_user_submit_*`.
