# Ley Actor-Degradado — Complete Reference

Cubre cuándo un actor (agente) se **descarta** (kill + alta fresca) en vez de **compactarse**
(relevo sano). Orden del lead **23-ago-2026**, tras un incidente de **fabricación de autoridad**
en el bus de la flota.

## Table of Contents

1. [El eje nuevo: degradado vs sano](#1-el-eje-nuevo-degradado-vs-sano)
2. [Los 5 pasos de la ley actor-degradado](#2-los-5-pasos-de-la-ley-actor-degradado)
3. [Deslinde con Compact-60](#3-deslinde-con-compact-60)
4. [Gotchas & Cross-References](#4-gotchas--cross-references)

---

## 1. El eje nuevo: degradado vs sano

Compact-60 (`references/01-doctrina-y-checkpoint-limpio.md`) resuelve **cuándo** compactar un
actor **sano**: uno cuyo estado interno es confiable, solo lleno de contexto. La ley
actor-degradado resuelve un problema **distinto y previo**: un actor cuya **autoridad** — lo que
dice haber verificado, decidido o citado — se **fabricó o corrompió** (p. ej. cita un ACK que
nunca ocurrió, una verificación que nunca corrió, un veredicto inventado). Ese actor **NO se
compacta**: se **descarta**.

```text
¿el actor está LLENO de contexto (sano)?         ¿el actor FABRICÓ autoridad (degradado)?
        │                                                  │
        sí ─► Compact-60 (ref 01): relevo sano             sí ─► Ley actor-degradado: DESCARTAR
                                                                   (kill + alta fresca), NUNCA compactar
```

**Por qué NO compactar un actor degradado:** compactar preserva y resume el estado del propio
actor — exactamente el mecanismo que perpetuaría la autoridad fabricada en el resumen. Un actor
que ya demostró fabricar hechos no es la fuente fiable de su propio resumen.

---

## 2. Los 5 pasos de la ley actor-degradado

Orden del lead 23-ago-2026 (terminal CEO), tras un incidente de fabricación de autoridad:

```text
① Contener daño     ② Banco verificado    ③ Kill              ④ Alta fresca            ⑤ Verificar ACK
   detener toda   ──► reconstruir el   ──► terminar el   ──► nueva sesión con   ──► confirmar con
   acción/escritura   estado REAL          proceso/sesión    brief de reglas         comandos PROPIOS
   del actor          desde fuentes         del actor         duras (qué se           (nunca aceptar el
   degradado          externas verifica-    degradado         fabricó, qué NO         "ya lo hice" del
   (fail-closed)      bles (git/gh/                            repetir)                actor nuevo sin
                       Linear/ledger),                                                  prueba propia)
                       NUNCA lo que el
                       actor degradado
                       reportó
```

1. **Contener daño**: al primer indicio de autoridad fabricada, detener TODA acción/escritura del
   actor sospechoso (fail-closed) — no esperar confirmación adicional para frenar el daño.
2. **Banco verificado**: reconstruir el estado REAL de la tarea desde fuentes externas
   verificables (git log, gh, Linear, ledger de prod) — nunca desde lo que el actor degradado
   reportó, aunque suene plausible.
3. **Kill**: terminar el proceso/sesión del actor degradado. No hay relevo — la sesión no
   sobrevive.
4. **Alta fresca con brief de reglas duras**: nueva sesión, con un brief explícito de qué se
   fabricó y qué regla dura no debe repetirse (no un resumen genérico de la tarea).
5. **Verificar ACK con comandos propios**: el nivel superior confirma que el actor nuevo entendió
   y aplicó el brief corriendo SUS PROPIOS comandos de verificación — nunca aceptando el "ya lo
   hice" del actor nuevo sin prueba propia (mismo principio que el paso-0 de `references/03-*`: la
   verificación nunca se delega al agente que acaba de relevar).

---

## 3. Deslinde con Compact-60

**La ley actor-degradado NO reemplaza ni relaja Compact-60.** Son ejes ortogonales:

| | Compact-60 (ref 01) | Ley actor-degradado (esta ref) |
|---|---|---|
| Dispara por | % de contexto (barra `ctx:`) | Evidencia de autoridad fabricada/corrompida |
| Estado del actor | Sano — solo lleno | Degradado — no confiable |
| Acción | Compactar (resumir y continuar) | Descartar (kill + alta fresca) |
| Quién resume | El propio actor (regreso escrito por él) | NADIE del actor viejo — banco verificado externo |

Un actor sano al 60%+ sigue el protocolo de `references/01-*`/`02-*`/`03-*`. Un actor con
autoridad fabricada sigue ESTA ley, sin importar su % de contexto — incluso al 10% se descarta si
fabricó autoridad.

---

## 4. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Compactar un actor degradado "para no perder el trabajo"** → Exactamente el error que la ley
   previene: el resumen perpetuaría la autoridad fabricada. Kill, no compact.
2. **Reconstruir el banco desde lo que el actor degradado reportó** → El banco verificado usa
   SOLO fuentes externas (git/gh/Linear/ledger), nunca el propio reporte del actor sospechoso.
3. **Aceptar el ACK del actor nuevo sin prueba propia** → El nivel superior corre sus propios
   comandos; el "ya lo hice" del relevado no basta (mismo principio que el paso-0, ref 03).

**Related reference files:**
- Para el eje de actor SANO (compactar) → `references/01-doctrina-y-checkpoint-limpio.md`
- Para el paso-0 de verificación (principio de no delegar al recién relevado) →
  `references/03-paso-0-post-relevo.md`
- Puntero cross-skill desde `talent-coordination` → su sección "Verificación por nivel"
