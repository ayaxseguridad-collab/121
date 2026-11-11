# Changelog — talent-orchestrator

- Pieza P2 (issue 8544): puntero, herramientas y doctrina del paquete en `scripts/paquete/`; lista de diez miembros tras retirar skill-creator.

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 2.0.0)

## Sin publicar — compact vivo

Decisión sellada: banco por hooks + autocompact del CLI sustituye la ceremonia de torre.
Sale torre-compact.sh, su umbral exclusivo y 22 aserciones. Se conservan helpers y pruebas
lib-torre.sh e INV-OR-013/016/018/020–028; su limpieza queda para 2.1.

| Invariante retirada | Motivo y decisión |
|---|---|
| INV-OR-012 | Recogida externa del handoff sustituida por banco vivo; retiro sellado de torre |
| INV-OR-014 | Aborto de ceremonia sustituido por lista blanca y lectura obligatoria; retiro sellado |
| INV-OR-015 | Captura de pantalla de ceremonia ya no existe; retiro sellado |
| INV-OR-017 | Doctrina de handoff de compact reemplazada por rescate por niveles; retiro sellado |
| INV-OR-019 | Guarda del directorio de handoff de ceremonia sale con el script; banco rechaza enlaces |
