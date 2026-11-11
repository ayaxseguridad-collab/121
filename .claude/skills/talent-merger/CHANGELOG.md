# Changelog — talent-merger

- Pieza P10 (issue 8583): paso 8-bis de destilado de findings (analítico, reintentable, no bloqueante) con `scripts/distill-findings.sh`, sus pruebas y mutantes, y la métrica refacto-vs-bounce en `references/05-canales-de-refactorizacion.md` §1; siete filas nuevas en `invariants.tsv` (INV-ME-413 a INV-ME-419).
- Pieza P2 (issue 8544): puntero, herramientas y doctrina del paquete en `scripts/paquete/`; lista de diez miembros tras retirar skill-creator.

- Pieza P15: PROC-M13 mide la cuota de `database/query` antes de empezar (Paso 0a), reintenta el 429 de las lecturas posteriores al apply (ledger y advisors) y ensaya el lote entero con `rollback;` antes de aplicar (Paso 2b); doctrina en ref 06 §3 y ref 07 §4, autoprueba T37.

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 2.0.0)
