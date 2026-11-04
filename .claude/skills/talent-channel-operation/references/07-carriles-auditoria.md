# 07 — Carriles de auditoría 5/6 [M3]

Los carriles `TCO_AUDIT_CARRILES="05 06"` corren en modo **audit-only**. Driver:
`audit-carril.sh`.

## Table of Contents

- [1. Roles de los carriles](#1-roles-de-los-carriles)
- [2. Regla del lead: nunca crean issues solos](#2-regla-del-lead-nunca-crean-issues-solos)
- [3. Forma del reporte de findings](#3-forma-del-reporte-de-findings)
- [4. Creación tras el OK](#4-creación-tras-el-ok)

## 1. Roles de los carriles

- **05 — ciberseguridad**: OWASP, controles de acceso faltantes o débiles en funciones del
  backend del repo, secretos, auth/authz, inyección.
- **06 — sistema + Playwright**: build/types, flujos E2E, regresiones de UX, performance.
  **Los flujos concretos a recorrer los define el anexo del repo**: la sección de flujos del
  carril de auditoría funcional de `references/anexo-*.md`, que el **coordinador releva a mano**
  al lanzar el carril 06 (no hay sustitución automática: el rol base
  `assets/audit-role-playwright.txt` remite explícitamente a ese relevo). El anexo lista también
  las precauciones específicas (p. ej. superficies que operan contra datos reales: **observar y
  reportar, jamás mutar**).

## 2. Regla del lead: nunca crean issues solos

Regla del lead (2026-06-28): **los carriles 5/6 NUNCA crean issues en Linear automáticamente.**
El milestone autónomo de 1-4 **no se desvía** generando trabajo nuevo por su cuenta. Producen un
**reporte de findings**; la creación de cada issue **siempre** pasa por:

1. **Auditoría** del finding (que sea real y bloqueante, no ruido).
2. **Autorización explícita del lead** — incluso en modo desatendido.

## 3. Forma del reporte de findings

Cada finding incluye:

- **Evidencia**: archivo:línea, repro, o traza.
- **Severidad ≥ mínimo por defecto**: por debajo del umbral se descarta (anti-ruido).
- **Dedupe** vs issues existentes en Linear (no reportar lo ya abierto).
- **Cap por corrida**: tope de findings por corrida para no inundar.

## 4. Creación tras el OK

Solo tras el OK del lead, al crear el issue (vía `linear-skill`):

- **Label del vertical del repo obligatorio** (`vertical/*`, + `kind:*` + `actor/*`) +
  **project de la initiative del repo** (gestión obligatoria vía Linear — en Academia Ejemplo: regla 21 del CLAUDE.md; guía Linear operativa
  del repo).
- Título imperativo, prefijo correcto.

Solo entonces el issue autorizado puede entrar a la cola de los carriles 1-4
(`select-issues.sh`).
