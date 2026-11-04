# 03 — Fronteras bilaterales: contratos, ventanas y cuadres con contrapartes

El PM es el custodio de las fronteras del producto con terceros (otro equipo, otra fábrica, un
recurso compartido). Este protocolo se forjó operando una frontera real de base de datos
compartida entre dos equipos, y sus reglas son simétricas: lo que exigimos, lo ofrecemos.

## Table of Contents

- [Preavisos: medidos, no narrados](#preavisos-medidos-no-narrados)
- [Acuses por tanda](#acuses-por-tanda)
- [Contratos estable-aditivos](#contratos-estable-aditivos)
- [Ventanas de aplicación](#ventanas-de-aplicación)
- [Cuadres firmados a dos lados](#cuadres-firmados-a-dos-lados)
- [Recursos compartidos](#recursos-compartidos)

## Preavisos: medidos, no narrados

Todo cambio que cruce una frontera se preavisa ANTES de ejecutarse, y el preaviso se construye
**midiendo contra el catálogo vivo** (¿qué existe hoy?, ¿qué colisiona?, ¿qué toca del otro
lado?), nunca de memoria. Un preaviso honesto declara también lo incómodo: la asimetría que
crea, el riesgo que traslada, la pregunta que no sabe responder. Recibido un preaviso ajeno,
el PM lo VERIFICA con medición propia antes de acusar — los preavisos también se equivocan, y
un acuse sobre una premisa falsa compromete a las dos partes.

## Acuses por tanda

Las tandas de cambios de una contraparte se acusan una a una: «un conforme por tanda». El acuse
puede ser CONDICIONADO (conforme sujeto a correcciones enumeradas — p. ej. un identificador de
versión que rompería el orden del registro común) y toda condición es bloqueante hasta constar
resuelta. Lo que no se pidió acusar no se acusa por arrastre; lo anunciado «para más adelante»
se espera con su preaviso propio.

## Contratos estable-aditivos

Cuando una parte lee o consume estructuras de la otra, la interfaz consumida queda bajo
**contrato estable-aditivo con preaviso**: las columnas/campos/rutas del contrato no se
renombran, retipan ni eliminan sin preaviso bilateral; añadir es libre. Los consumidores se
obligan a lecturas robustas (jamás asumir conjunto cerrado de campos). El contrato se registra
por escrito EN AMBOS lados (issue/expediente de cada parte) y sobrevive a las personas y a las
sesiones. Regla espejo: lo que firmamos hacia fuera nos obliga hacia dentro con la misma letra.

## Ventanas de aplicación

Los cambios sensibles de frontera se ejecutan en **ventanas pactadas**:

- **Corte duro**: la ventana declara hora de corte con colchón sobrante — se dimensiona para
  terminar MUCHO antes del límite, no para caber justa. Trabajo real de minutos recibe ventana
  de decenas de minutos; el colchón es a propósito.
- **Regla de deslizamiento**: «el hueco es una FORMA, no una hora» — se pacta la forma (franjas
  válidas, franjas prohibidas por procesos de cualquiera de las partes) y un deslizamiento
  dentro de la forma se ANUNCIA sin renegociar. Un adelanto o retraso fuera de la forma sí
  renegocia.
- **Rollback a mano**: el material de reversión (leído del estado real ANTES de tocar, no
  reconstruido) está preparado y localizado durante toda la ventana. Ante fallo en superficie
  crítica: revertir en el acto y diagnosticar después — con la excepción de las verificaciones
  post-cambio cuya semántica exige ALTO sin reversión automática (ver `04`).
- **Silencio operativo**: quien ejecuta calla hasta el cierre salvo aborto, que se anuncia de
  inmediato. El otro lado no toca el recurso compartido durante la ventana.

## Cuadres firmados a dos lados

El cierre de una ventana es un **cuadre bilateral**: cada parte mide POR SU CUENTA el estado
resultante (conteos, versiones máximas, huellas de los objetos tocados, salud del primer ciclo
posterior) y la firma solo si su medida coincide con la declarada. Una firma sobre la medida
del otro no es una firma: es un eco. El cuadre queda registrado con las cifras exactas en los
expedientes de ambas partes.

## Recursos compartidos

Un recurso compartido (base de datos, registro de versiones, esquema, cola) JAMÁS se aplica
unilateralmente: existe UNA parte aplicadora pactada y la otra entrega su material versionado y
verificado por el circuito bilateral. Identificadores ordenados (timestamps de migración,
versiones) se sellan contra el máximo REMOTO en el instante de sellar — el registro común avanza
por el tren de la otra parte y una foto vieja produce colisiones o bloqueos para ambos.
