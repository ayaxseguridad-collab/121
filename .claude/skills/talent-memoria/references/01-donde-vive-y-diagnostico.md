# 01 · Donde vive tu memoria y como diagnosticarla

Antes de limpiar nada hay que saber DONDE esta la memoria y QUE tan degradada esta.
Este documento mapea los sitios donde Claude Code persiste memoria y explica el censo
que hace `diagnostico.sh` — que es solo-lectura por contrato: mide, no toca.

## Table of Contents

- [1. Los tres sitios](#1-los-tres-sitios)
- [2. Cual es el canonico cuando hay varios](#2-cual-es-el-canonico-cuando-hay-varios)
- [3. Anatomia de una nota sana](#3-anatomia-de-una-nota-sana)
- [4. El censo: que mide diagnostico.sh](#4-el-censo-que-mide-diagnosticosh)
- [5. Leer el veredicto](#5-leer-el-veredicto)
- [6. Sintomas por tipo de degradacion](#6-sintomas-por-tipo-de-degradacion)

## 1. Los tres sitios

```text
  ┌─ EN TU REPO (viaja con el proyecto, entra en git) ──────────────────┐
  │  CLAUDE.md                  instrucciones del proyecto: la ley       │
  │  .claude/memory/*.md        notas de memoria del proyecto (si las    │
  │                             usas): MEMORY.md indice + notas          │
  └──────────────────────────────────────────────────────────────────────┘
  ┌─ EN TU MAQUINA (no viaja, NO esta en git) ──────────────────────────┐
  │  ~/.claude/projects/<slug-del-path>/memory/                          │
  │                             la memoria general del harness: MEMORY.md │
  │                             (indice que se carga cada sesion) + un    │
  │                             fichero por nota                          │
  │  ~/.claude/CLAUDE.md        instrucciones globales de usuario (si     │
  │                             existe): manda FUERA de los repos          │
  └──────────────────────────────────────────────────────────────────────┘
```

El `<slug-del-path>` es la ruta de tu proyecto con los separadores convertidos en
guiones. Cada proyecto tiene SU directorio de memoria general: si trabajas en tres
repos, tienes tres corpus del harness (mas los de repo que existan).

Consecuencia operativa (importa para `references/03`): lo del repo se salvaguarda con
git SI cumple los criterios duros; lo de la maquina va SIEMPRE por snapshot.

## 2. Cual es el canonico cuando hay varios

Cuando la misma informacion vive en dos sitios, decide UNA vez cual manda y anotalo.
Regla practica que no suele fallar:

- **Instrucciones** (como debe comportarse tu agente): canonico = CLAUDE.md del
  ambito (el del repo dentro del repo; el global fuera). Las notas pueden explicar el
  porque, pero la orden vive en un solo sitio.
- **Conocimiento del proyecto** (que aprendiste, que decidiste, que fallo): canonico =
  el corpus de notas donde lo escribiste primero; el otro sitio, si existe, es copia
  y se marca como tal.
- ¿No esta claro cual manda? Esa ambiguedad ES una contradiccion: se adjudica con el
  pipeline (`references/02`, paso 2) antes de tocar ninguna de las dos.

## 3. Anatomia de una nota sana

El diagnostico evalua contra este minimo (que es tambien lo que `references/04`
ensena a escribir desde el primer dia):

```text
---
name: slug-corto-en-kebab                  <- opcional pero util para enlaces
description: una linea que resume — CON el estado delante si no esta viva
metadata / fecha: alguna forma de fecha    <- SIN fecha no hay adjudicacion posible
---
El contenido. Un tema por nota. Si ordena ejecutar algo, la ruta/comando existe.
Enlaces a notas relacionadas ([[slug]] o ruta) cuando los hay.
```

No necesitas exactamente este frontmatter — el diagnostico acepta variantes (fecha en
el nombre del fichero, fecha en el cuerpo). Lo que no perdona es la AUSENCIA de
fecha: una nota sin ninguna datacion queda fuera del desempate por recencia para
siempre (gotcha 10 del SKILL.md).

## 4. El censo: que mide diagnostico.sh

```bash
bash scripts/diagnostico.sh                    # autodetecta los tres sitios
bash scripts/diagnostico.sh /ruta/al/corpus    # o un corpus explicito
```

Autodeteccion: comprueba los sitios de la seccion 1 (CLAUDE.md y `.claude/memory/`
bajo el directorio actual; el corpus del harness que corresponde al directorio
actual; el CLAUDE.md global). Si no encuentra NADA, lo dice y te pide la ruta —
fail-closed, nunca adivina un directorio y se pone a medirlo.

**Symlinks: NO soportados, fail-closed (exit 2)** — el censo (como
`salvaguarda.sh`/`verificar.sh`, `references/03` §9) recorre solo ficheros
regulares; un symlink podria cambiar de destino sin dejar rastro en las metricas.
Si tu corpus los tiene, sustituyelos por ficheros reales antes de diagnosticar.

Por cada corpus encontrado mide, en solo-lectura:

| Metrica | Que indica |
|---|---|
| Numero de notas y tamano total | la escala del trabajo |
| Notas sin fecha detectable | cuantos conflictos serian in-adjudicables hoy |
| Pares candidatos a duplicado | titulos/slugs con alta similitud (candidatos: la decision es tuya) |
| Notas con estado ya marcado | ANULADA/ACOTADA/CADUCADA/SUPERSEDED/ALIAS-STUB existentes |
| Estados solo-en-cuerpo | notas con marca en el cuerpo pero description sin estado (violan S3) |
| Rutas/comandos citados que no existen | candidatos a instruccion muerta (mapa falso) |
| Indice vs corpus | entradas del indice que apuntan a notas inexistentes, y notas sin entrada |
| Lineas del indice | si el indice ya necesita compactacion (`references/04`) |

El reporte da NUMEROS y LISTAS de candidatos, nunca contenido completo de tus notas:
el censo esta pensado para poder compartirse (pedir ayuda con tu diagnostico) sin
pasear lo que tus notas dicen.

## 5. Leer el veredicto

El diagnostico no tiene "aprobado/suspendido": tiene hallazgos, cada uno con el paso
del pipeline que lo trata:

```text
  hallazgo                                → paso del pipeline (references/02)
  ────────────────────────────────────────────────────────────────────────
  pares candidatos a duplicado            → paso 1 (dedupe)
  notas contradictorias entre si          → paso 2 (contradicciones)  [*]
  notas con ventana vencida               → paso 4 (caducadas)
  rutas/comandos muertos                  → paso 6 (sync realidad)
  indice desincronizado                   → S6 + paso final de indice
  notas sin fecha                         → paso 5 si entran en conflicto;
                                            references/04 para datarlas hacia delante
  estados solo-en-cuerpo                  → completar S3 (description)
```

[*] La contradiccion SEMANTICA (dos notas fechadas que ordenan cosas opuestas) no la
detecta ningun script: la detectas tu al leer los candidatos, o tu sesion de Claude
Code leyendo el corpus contigo. El censo te acota donde mirar; no sustituye la
lectura.

## 6. Sintomas por tipo de degradacion

Como se ve cada degradacion DESDE FUERA, antes de diagnosticar — por si alguno te
suena, ese es el motivo para correr el censo hoy:

- **Tu agente "desobedece"**: hace caso a una norma que tu ya cambiaste. Casi siempre
  es una nota vieja sin anular que gana el grep (gotcha 2) — o una contradiccion
  entre memoria y CLAUDE.md que se esta adjudicando sola, mal.
- **Tu agente ejecuta cosas que fallan**: rutas o comandos que ya no existen. Mapa
  operativo falso (paso 6).
- **Respuestas que mezclan dos epocas**: mitad politica nueva, mitad vieja. Duplicados
  o SUPERSEDED sin marcar.
- **El indice no te sirve para encontrar nada**: o esta desincronizado (S6) o crecio
  sin compactar (`references/04`).
- **Te da miedo tocar tu memoria**: no tienes salvaguarda. Eso no es un sintoma del
  corpus sino del proceso — y es el primero que se arregla (`references/03`).
