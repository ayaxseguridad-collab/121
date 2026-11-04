# Doctrina Compact-60 y Checkpoint Limpio — Complete Reference

Cubre el umbral del 60 %, por qué 60 y no 70+, y la definición de "checkpoint limpio" por rol.
Doctrina del lead 2026-07-08 (supersede el >70 % previo); validada 2026-07-17.

## Table of Contents

1. [El umbral: 60 %](#1-el-umbral-60-)
2. [Por qué 60 y no 70+ (ni pánico al 43 %)](#2-por-qué-60-y-no-70-ni-pánico-al-43-)
3. [Cómo se mide el % (barra `ctx:`, no `/context`)](#3-cómo-se-mide-el--barra-ctx-no-context)
4. [Checkpoint limpio por rol](#4-checkpoint-limpio-por-rol)
5. [Gotchas & Cross-References](#5-gotchas--cross-references)

---

## 1. El umbral: 60 %

**Regla Compact-60:** al cruzar el **60 %** de uso de la ventana de contexto, la sesión se compacta
en su **siguiente checkpoint limpio** — no de inmediato (eso sería mid-tarea), pero tampoco "cuando
se llene" (eso es tarde). El objetivo es preservar continuidad de la tarea **antes** de que el
auto-compact del CLI dispare por su cuenta y capture el estado de forma imperfecta.

El invariante que sostiene todo: **JAMÁS `/compact` sin el fichero de regreso YA escrito y verificado
FUERA de la sesión** (ver `references/02-protocolo-de-relevo.md`).

```text
0% ───────────────── 60% ═══════════ 70% ─────────── ~90% ───► límite duro / auto-compact salvaje
        trabajar        │ ZONA de       margen real          (el CLI compacta solo, mid-anything)
                        │ compact-60     pero arriesgado
                        └─ compacta en el próximo checkpoint limpio
```

---

## 2. Por qué 60 y no 70+ (ni pánico al 43 %)

Dos errores simétricos que la doctrina corrige:

- **Demasiado tarde (>70 %)**: esperar a más del 70 % dejó **gates a medias** por quedarse sin
  contexto o por rate-limit en mitad de un paso caro. El umbral previo (>70 %) era menos
  conservador y produjo relevos sucios.
- **Demasiado pronto (pánico al ~43 %)**: los agentes tienden a **auto-diagnosticarse "crítico"**
  mucho antes de tiempo. Hay margen real de trabajo por encima del 43 %; compactar ahí desperdicia
  contexto útil y multiplica relevos innecesarios.

El punto de equilibrio medido es **60 %**: suficiente colchón para cerrar el paso limpio y escribir
el regreso, sin tirar contexto aprovechable. Evidencia de campo: **7/7 relevos limpios** en torres
(coordinadores + estaciones) y 1 rama-backup end-to-end validada (M4), 2026-07-17.

---

## 3. Cómo se mide el % (barra `ctx:`, no `/context`)

El porcentaje que dispara la doctrina es el de la **barra de estado** del pane (`ctx: NN%`), NO el
de un comando `/context` (que gasta un turno y cuyo valor no es el operativo).

```bash
# Lectura del ctx% desde una captura del pane (helper puro; ver scripts/lib.sh):
#   - último match de 'ctx: NN%' (la barra vive abajo)
#   - sin match -> UNKNOWN fail-closed (rc 1): jamás asumir 0 ni 100
printf 'ctx: 63%%\n' | tc_ctx_pct    # => 63
printf 'sin barra\n' | tc_ctx_pct    # => rc 1 (UNKNOWN)
```

**UNKNOWN es fail-closed**: si la barra no es legible (overlay, pane redibujando, TUI sin barra), la
respuesta correcta es *inspección manual*, nunca "asumo que voy bien".

---

## 4. Checkpoint limpio por rol

Un **checkpoint limpio** es un instante en el que compactar no parte una operación en dos. Depende
del rol; la columna derecha es SIEMPRE sucia (no compactar ahí):

| Rol | Limpio (compacta aquí) | Sucio (NO compactar) |
|---|---|---|
| Sesión standalone | idle, tras cerrar un paso/commit, sin edición a medias | mid-edición, comando largo en vuelo |
| Canal dev | tras commit o al entregar a auditoría | mid-fix, mid-edición de archivos |
| Coordinador | entre despachos | mid-despacho de un encargo |
| Estación de merge | gate lanzado y cosecha lejana | mid-merge, aplicando una migración |
| **Cualquiera** | — | **menú modal abierto** (ExitPlanMode y similares) |

```text
   ¿estoy a mitad de algo que se rompe si lo corto en dos?
        │                                  │
        sí ─► NO es checkpoint limpio       no ─► ¿hay un menú/diálogo modal abierto?
              (termina el paso primero)            │                       │
                                                   sí ─► Escape primero     no ─► checkpoint LIMPIO
```

La regla del menú abierto es dura: el diálogo de ExitPlanMode es **modal** y **traga o aprueba**
teclas; un `/compact` o un relay con el menú arriba corrompe el estado (ver gotcha 3 del SKILL.md).

---

## 5. Gotchas & Cross-References

**Errores comunes en esta área:**

1. **Confundir el % de `/context` con el de la barra** → El operativo es el de la barra `ctx:`;
   `/context` gasta turno y no es el disparador.
2. **Tratar UNKNOWN como OK** → Sin `ctx:` legible es fail-closed (inspección manual), jamás
   "asumo 0/100".
3. **Compactar por pánico al 43 %** → Hay margen; el umbral es 60 %, no "cuando me siento lleno".
4. **Compactar con un menú modal abierto** → Siempre sucio; Escape primero.

**Related reference files:**
- Para ejecutar el relevo (regreso + `/compact`) → `references/02-protocolo-de-relevo.md`
- Para el paso-0 de reanudación → `references/03-paso-0-post-relevo.md`
- Para la vigilancia automática del ctx% → `references/04-ctx-watcher.md`
