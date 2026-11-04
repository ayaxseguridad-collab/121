# 02 · Modos de entrada

El pipeline arranca distinto segun de que partas. Tres modos, mismos destinos: las
7 fases. Lo que cambia es cuanto trabajo llega ya hecho y que se entrevista.

## Table of Contents

- [1. Como elegir el modo](#1-como-elegir-el-modo)
- [2. Modo greenfield](#2-modo-greenfield)
- [3. Modo brownfield-reconversion](#3-modo-brownfield-reconversion)
- [4. Modo PRD inicial existente](#4-modo-prd-inicial-existente)
- [5. Tabla comparativa](#5-tabla-comparativa)

## 1. Como elegir el modo

| Tienes... | Modo |
|---|---|
| Una idea (notas, conversaciones, nada ejecutable) | greenfield |
| Un repo que funciona (o casi) sin PRD que lo describa | brownfield-reconversion |
| Un PRD inicial ya escrito (tuyo o heredado) | PRD inicial existente |

Casos mixtos: repo + PRD viejo -> brownfield manda (el codigo es la verdad; el PRD
viejo es material del intake). Idea + prototipo tirado en una tarde -> greenfield
(el prototipo es evidencia, no as-is).

## 2. Modo greenfield

Partes de cero: la entrevista ES la fuente. Todo el peso cae en las fases 2-3.

Guia de entrevista (una pregunta por turno, en este orden):

1. Cuentame la idea como se la contarias a la persona que la necesita.
2. Las 6 forcing questions del interrogatorio (fase 2), de una en una.
3. ¿Que has probado ya? — conversaciones, maquetas, competidores usados.
4. ¿Cuanto quieres gastar en esto? — el appetite, en tiempo, no en features.

Senales de parada temprana:

- Dos forcing questions sin respuesta tras intentarlo -> la idea no esta lista
  para un PRD; el resultado honesto es una lista de deberes, no un documento.
- La licencia para matar se activa -> se mata y se escribe por que. Un PRD de
  una idea muerta es el mejor PRD barato que existe.

Salida tipica: PRD Lite o Estandar + wayfinder con 2-5 decisiones abiertas.

## 3. Modo brownfield-reconversion

Partes de un repo sin PRD. Regla de oro: **el as-is se extrae del codigo ANTES de
preguntar nada, y solo se entrevista el delta**. Preguntarle a la persona lo que
el codigo ya responde es gastar su paciencia en confirmar lo obvio.

Procedimiento:

1. Extraccion del as-is (sin entrevista): README y docs del repo, puntos de
   entrada, rutas/pantallas, modelos de datos, integraciones externas, tests como
   contrato de comportamiento. Se escribe la seccion `As-is del codigo`: que hace
   HOY el sistema, con rutas de fichero citadas entre backticks.
2. Confirmacion (entrevista minima): "esto es lo que hace hoy segun el codigo —
   ¿algo de esta lista esta muerto o miente?". Una pregunta, una lista.
3. Entrevista del DELTA (aqui si, fases 2-5): ¿que quieres que haga que hoy no
   hace? ¿que hace hoy que quieres quitar? El interrogatorio se aplica al delta:
   quien necesita el cambio, por que ahora, cual es el wedge del delta.
4. El PRD resultante lleva la seccion extra `As-is del codigo` (no esta en el
   superset: es del modo, con las rutas citadas verificables contra el repo) y
   las secciones normales de su nivel describen el TO-BE. La seccion as-is toma
   su numero H2 normal en la secuencia consecutiva del documento — es
   direccionable por `§N` como todas; el auditor de gaps simplemente la ignora.

Verificacion mecanica del as-is: `verificar-prd.sh <dir> --codigo <repo>`
comprueba que toda ruta citada entre backticks en la seccion as-is existe en el
repo — el as-is que cita ficheros inexistentes es fantasia, no extraccion.

Salida tipica: PRD Estandar con as-is + delta; wayfinder para las decisiones que
el codigo revelo abiertas.

## 4. Modo PRD inicial existente

Partes de un PRD ya escrito. No se tira: se AUDITA y se cubren los huecos.

Procedimiento:

1. Normalizacion minima: si el documento no tiene cabecera de versionado ni
   secciones numeradas, se le pone la cabecera (`estado=DRAFT`, el appetite que
   declare o el que se decida) y se numeran sus secciones. Contenido intacto.
2. Auditoria de gaps: `auditar-gaps.sh <prd.md>` contra el superset del nivel
   declarado -> el mapa de que secciones exigibles faltan y cuales del superset
   quedan fuera del appetite.
3. Triaje de cada gap, en orden de plantilla: ¿este hueco se cubre con evidencia
   que ya existe (rellenar), con entrevista (preguntar — las preguntas MINIMAS,
   una por turno) o con una decision abierta (ficha al wayfinder)?
4. Reescritura selladora: el documento cubierto pasa por la fase 7 (review
   adversarial) igual que uno nuevo. Un PRD heredado no hereda la aprobacion.

Cuidado con los gaps invisibles: un PRD viejo puede tener las 18 secciones y aun
asi mentir (landscape caducado, premisas ya refutadas). La auditoria de gaps mide
FORMA; la fase 3 se repite igualmente para premisas y landscape.

Salida tipica: el mismo PRD, versionado, con gaps cubiertos y review fresca.

## 5. Tabla comparativa

| | greenfield | brownfield | PRD existente |
|---|---|---|---|
| Fuente de verdad inicial | entrevista | el codigo | el documento |
| Que se entrevista | todo | solo el delta | solo los gaps |
| Seccion extra | — | As-is del codigo | — |
| Herramienta de arranque | interrogatorio | extraccion as-is | auditar-gaps.sh |
| Riesgo tipico | idea sin dolor real | preguntar lo obvio | heredar mentiras |
| Fase donde mas se invierte | 2-3 | 1 y 3 | 6-7 |
