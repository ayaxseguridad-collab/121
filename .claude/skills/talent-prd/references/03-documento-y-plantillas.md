# 03 · Documento y plantillas

La fase 6 en detalle: como el appetite elige plantilla, que exige cada nivel, el
superset de 27 secciones y las reglas de forma que hacen el documento verificable.

## Table of Contents

- [1. Appetite manda](#1-appetite-manda)
- [2. El superset de 27 secciones](#2-el-superset-de-27-secciones)
- [3. Formato hibrido por nivel](#3-formato-hibrido-por-nivel)
- [4. Reglas de forma verificables](#4-reglas-de-forma-verificables)
- [5. Versionado del documento](#5-versionado-del-documento)
- [6. Cabecera machine-readable](#6-cabecera-machine-readable)

## 1. Appetite manda

El appetite (cuanto quieres gastar, decidido en la fase 5) elige el nivel — no al
reves. Nadie escribe 27 secciones para un experimento de dos semanas.

| Appetite | Nivel | Secciones | Plantilla |
|---|---|---|---|
| 1-2 semanas, un flujo | lite | 1-9 | `assets/plantilla-prd-lite.md` |
| 1-3 meses, varios flujos | estandar | 1-18 | `assets/plantilla-prd-estandar.md` |
| Mas, o varios actores / integraciones / dinero | completo | 1-27 | `assets/plantilla-prd-completo.md` |

Los niveles son acumulativos: Estandar contiene las 9 de Lite; Completo contiene
las 18 de Estandar. Subir de nivel a mitad de camino es legal (se declara con una
version nueva); bajar tambien, recortando con `supersedes=`.

## 2. El superset de 27 secciones

La columna Nivel marca desde que nivel la seccion es EXIGIBLE (L = desde lite,
E = desde estandar, C = solo completo). `auditar-gaps.sh` usa exactamente esta
tabla: exigible ausente = GAP; no exigible ausente = fuera de tu appetite (informativo).

| # | Seccion | Nivel | Que responde |
|---|---|---|---|
| 1 | Resumen y pitch | L | que es, en 4 frases |
| 2 | Problema y persona | L | quien (con nombre) y que le duele |
| 3 | Wedge | L | la cunia minima, por que ahora |
| 4 | Alcance del appetite | L | que entra y que no, a proposito |
| 5 | Historias de usuario | L | el que, narrado por la persona |
| 6 | Criterios de aceptacion | L | pass/fail observable |
| 7 | No-gos | L | que no haremos y que haremos en su lugar |
| 8 | Fases walking-skeleton | L | el esqueleto y como engorda |
| 9 | Riesgos y premisas | L | lo asumido y como se verifica |
| 10 | Landscape | E | que existe ya, con evidencia actual |
| 11 | Interrogatorio sellado | E | las 6 respuestas finales |
| 12 | Alternativas A B C | E | los tres recortes y cual gano |
| 13 | Metricas de exito | E | numeros con umbral y fecha |
| 14 | Flujo principal | E | el recorrido punta a punta |
| 15 | Requisitos no funcionales | E | latencia/volumen/coste con numero |
| 16 | Dependencias y limites | E | de que depende, que lo para |
| 17 | Decisiones clasificadas | E | audit trail mechanical/taste/challenge |
| 18 | Plan de validacion | E | que experimento valida cada premisa |
| 19 | Casos de uso formales | C | el que, formalizado por actor |
| 20 | Diagrama actores-modulos | C | quien toca que |
| 21 | Modelo de entidades | C | el dominio y sus relaciones |
| 22 | Version 10-estrellas | C | el maximo absurdo y su recorte |
| 23 | Estados y errores | C | por donde pasa el objeto central |
| 24 | Seguridad y privacidad | C | datos, quien ve que, borrado |
| 25 | Operacion y despliegue | C | publicar, revertir, monitorizar |
| 26 | Presupuesto y costes | C | construir y operar, con numeros |
| 27 | Glosario | C | las palabras con dueno |

Los nombres de la tabla son canonicos: el auditor busca `## N. <Seccion>` con el
nombre EXACTO. Renombrar una seccion es romper la auditoria a proposito.

El modo brownfield anade `As-is del codigo` (ver `02-modos-de-entrada.md`), que
no esta en el superset: es una seccion de modo, no de nivel. Numeracion: recibe
su numero H2 NORMAL dentro de la secuencia consecutiva del documento (es
direccionable como cualquier otra — la review y el backlog la citan por su `§N`);
lo unico que no tiene es fila en la tabla del superset, y el auditor de gaps la
ignora sin castigo.

## 3. Formato hibrido por nivel

- Lite y Estandar: historias de usuario (seccion 5) como formato principal del
  "que". Ligero, narrable, suficiente cuando hay un actor dominante.
- Completo: las historias se CONSERVAN como resumen narrativo con ID estable
  (H1, H2...) y se formalizan en casos de uso (seccion 19: actor, precondicion,
  disparador, flujos, postcondicion), con el diagrama actores-modulos (20) y el
  modelo de entidades (21). Cada caso de uso cita en su campo Historia el ID que
  formaliza — las dos vistas no compiten, se referencian.

## 4. Reglas de forma verificables

Las comprueba `scripts/verificar-prd.sh` — estas no son sugerencias de estilo:

1. Secciones direccionables: H2 numerados `## N. Titulo`, numeracion consecutiva
   desde 1, sin huecos ni repetidos. Todo lo que cite el PRD (backlog, review,
   wayfinder) apunta a `§N`.
2. Criterios pass/fail: el script exige que exista AL MENOS un par `- PASA si:` /
   `- FALLA si:` (frontera mecanica declarada); la vara real — un par por
   historia critica, binario y observable — la juzga la review (dimension
   verificabilidad). "Funciona bien" no compila en ninguna de las dos.
3. No-gos en positivo: cada no-go dice que se hara en su lugar. (Esta la revisa
   la fase 7 — el verificador mecanico no juzga redaccion.)
4. Walking-skeleton: la fase 1 es el recorrido completo minimo; ninguna fase es
   "el modulo X entero". (Tambien juicio de la review, no del script.)
5. Wayfinder y backlog, si existen, cumplen su forma (indice consistente, bloques
   con Contexto/DoD/Surfaced by) — detalle en `05-wayfinder-local.md` y en la
   plantilla de backlog.

## 5. Versionado del documento

- El PRD nace `estado=DRAFT`. Solo la review adversarial aprobada (fase 7) lo pasa
  a `estado=APPROVED`.
- Un APPROVED es inmutable, SIEMPRE: la reescritura es un fichero NUEVO (nombre
  o directorio versionado, p. ej. `prd-v2.md`) con `supersedes=<version
  anterior>` obligatorio; la historia del producto se lee siguiendo la cadena de
  supersedes. Nunca se sobrescribe el fichero de un APPROVED.
- La edicion directa existe solo para DRAFT: edita y sube `version=`.

## 6. Cabecera machine-readable

Primera linea del `prd.md`, exacta:

```text
<!-- prd: estado=DRAFT version=0.1 supersedes=- appetite=lite -->
```

- `estado`: `DRAFT` o `APPROVED`. Nada mas.
- `version`: la que sea, no vacia (`0.1`, `1.0`, `2.0-rc1`).
- `supersedes`: `-` si es el primero; si no, la version a la que sustituye.
- `appetite`: `lite`, `estandar` o `completo` — el nivel contra el que audita
  `auditar-gaps.sh`.

La tabla humana de debajo (Estado/Version/Supersedes/Appetite) repite estos campos
para quien lee; la linea de comentario es la que leen los scripts. Si discrepan,
manda la linea de comentario: actualiza la tabla a mano cuando cambies la cabecera.
