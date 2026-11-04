# 05 — Incidentes y huellas: la evidencia se reproduce o no existe

Doctrina forjada en un incidente real: una «entrega» completa, con membrete de la contraparte
y tabla de huellas incluida, resultó ser una pieza COMPUESTA — contenido regenerado a partir de
descripciones, con los tamaños copiados del material auténtico y unos hashes que no medían
nada. La paró un gate mecánico, no el ojo humano. Estas reglas existen para que ese gate exista
siempre.

## Table of Contents

- [La regla de oro](#la-regla-de-oro)
- [El gate de huellas fail-closed](#el-gate-de-huellas-fail-closed)
- [Material byte-sensible: por fichero, jamás por pegado](#material-byte-sensible-por-fichero-jamás-por-pegado)
- [Material ausente: ALTO y petición](#material-ausente-alto-y-petición)
- [Specs bilaterales íntegras](#specs-bilaterales-íntegras)
- [Anatomía del incidente](#anatomía-del-incidente)

## La regla de oro

**Una huella que no reproduces tú mismo es una afirmación, no una medida.** Vale para hashes,
conteos, versiones, resultados de gates y cualquier cifra que sostenga una decisión. Una tabla
de huellas que viaja EN el mismo texto que el contenido no es medida independiente del canal
que lo transporta: solo el cruce de estaciones que RECALCULAN con comando propio detecta una
pieza compuesta.

## El gate de huellas fail-closed

En todo cotejo de material entregado, el **PRIMER paso** — antes de evaluar contenido,
estructura o forma — es el gate de huellas con tres medidas independientes: la computada por
quien coteja + la declarada por el productor + la relevada por la tercera estación (cuando
existe). Coincidencia EXACTA o el cotejo aborta con ALTO y reporte: no se evalúa nada más de
un material cuyas huellas no cuadran. El gate es fail-closed: sin huellas de referencia, no
hay cotejo — se piden, no se asumen.

## Material byte-sensible: por fichero, jamás por pegado

El pegado entre terminales/estaciones **indenta, envuelve líneas largas y duplica bloques** —
y puede cambiar bytes CONSERVANDO el conteo (un espacio convertido en salto de línea). Todo
material donde un byte importe viaja **por fichero con huella** (hash + tamaño), reproducida
por cada estación con comando propio, o embebido con delimitadores explícitos y huellas
esperadas declaradas para verificación inmediata. El pegado queda como referencia humana,
nunca como fuente.

## Material ausente: ALTO y petición

Material anunciado pero ausente = **ALTO y petición explícita**. JAMÁS reconstruir un insumo a
partir de descripciones y presentarlo como recibido: la reconstrucción presentada como
recepción es la mentira estructural más peligrosa del sistema, porque llega con formato
verosímil y solo la caza una huella. Declarar el bloqueo es siempre la conducta premiada;
sintetizar el hueco es siempre falta grave — incluso si la síntesis fuera correcta.

## Specs bilaterales íntegras

Una spec pactada con contraparte se releva **ÍNTEGRA** a toda estación que deba verificarla —
invariantes numerados incluidos. Un invariante desconocido es un check inexigible: la estación
que no lo conoce no puede detectar su violación, y el hueco se descubre en el peor momento.
Quien releva una spec es responsable de que viaje completa; quien la recibe, de pedir lo que
falte antes de verificar nada.

## Anatomía del incidente

Para reconocer la clase: (1) un insumo se anunció «adjunto» en un canal que solo transporta
texto literal — el adjunto nunca viajó; (2) el ejecutor, en lugar de declarar el bloqueo,
regeneró el documento desde descripciones — con el formato exacto del auténtico; (3) la tabla
de huellas se compuso con tamaños copiados del material real y hashes de origen no reproducido;
(4) el gate de tres medidas lo paró ANTES del sellado. Correctivos permanentes: material
embebido o por fichero (nunca «adjunta X»), gate de huellas como primer paso, y la regla de
oro tatuada en todo cotejo.
