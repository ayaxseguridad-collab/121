<!-- prd: estado=DRAFT version=0.1 supersedes=- appetite=completo -->

# PRD — <nombre del producto>

| Campo | Valor |
|---|---|
| Estado | DRAFT |
| Version | 0.1 |
| Supersedes | — |
| Appetite | completo |

> Nivel Completo: las 27 secciones del superset (las 18 de Estandar + 9 propias).
> Para productos con varios actores, integraciones o dinero de por medio. Formato
> hibrido: las historias de usuario (seccion 5) se conservan como resumen narrativo
> con ID (H<n>) y se FORMALIZAN en casos de uso (seccion 19). Versionado: igual que
> en Lite (al cambiar la primera linea, actualiza tambien la tabla de abajo).

## 1. Resumen y pitch

<2-4 frases.>

## 2. Problema y persona

<Persona con NOMBRE. Evidencia, no intuicion.>

## 3. Wedge

<La cunia minima. Por que ahora. Por que tu.>

## 4. Alcance del appetite

<Que entra y que no, a proposito.>

## 5. Historias de usuario

<En Completo cada historia lleva ID estable (H1, H2...) para que los casos de
uso de la seccion 19 la referencien sin ambiguedad.>

- H1 · Como ..., quiero ..., para ...
- H2 · Como ..., quiero ..., para ...

## 6. Criterios de aceptacion

- PASA si: <condicion observable>
- FALLA si: <condicion observable>

## 7. No-gos

- NO haremos <X>; en su lugar: <Y>.

## 8. Fases walking-skeleton

1. Esqueleto: <recorrido minimo completo>

## 9. Riesgos y premisas

- Premisa: <...> · Como se verifica: <...>

## 10. Landscape

<Evidencia actual, no memoria.>

## 11. Interrogatorio sellado

<Respuestas finales a las 6 forcing questions.>

## 12. Alternativas A B C

<Los tres recortes y cual gano.>

## 13. Metricas de exito

<Umbral y fecha en cada una.>

## 14. Flujo principal

<Punta a punta, con estado del sistema en cada paso.>

## 15. Requisitos no funcionales

<Con numero cada uno.>

## 16. Dependencias y limites

<Servicios, datos, personas, limites externos.>

## 17. Decisiones clasificadas

| Decision | Clase | Porque | Quien |
|---|---|---|---|

## 18. Plan de validacion

<Prototipos y experimentos que validan premisas antes de construir.>

## 19. Casos de uso formales

<Uno por interaccion relevante. Formato: actor · precondicion · disparador · flujo
principal numerado · flujos alternativos · postcondicion. Cada caso de uso cita en
su campo Historia el ID (H<n>) de la seccion 5 que formaliza.>

### CU-01 · <nombre>

- Historia: H1
- Actor: <...>
- Precondicion: <...>
- Disparador: <...>
- Flujo principal: 1. <...> 2. <...>
- Alternativos: <...>
- Postcondicion: <...>

## 20. Diagrama actores-modulos

<Diagrama ASCII: actores a la izquierda, modulos del sistema a la derecha, flechas
con el verbo de la interaccion. Todo actor de la seccion 19 aparece aqui.>

```text
[Actor] --verbo--> [Modulo]
```

## 21. Modelo de entidades

<Las entidades del dominio con sus campos clave y relaciones (1-1, 1-N, N-N).
Solo el dominio: nada de tablas de infraestructura.>

```text
Entidad A (campo, campo) 1--N Entidad B (campo)
```

## 22. Version 10-estrellas

<Opt-in del ejercicio: describe la experiencia de 10 estrellas — la version tan
buena que resulta absurda — y despues recorta hacia atras hasta la que si puedes
construir. Lo que sobrevive al recorte revela que es esencial.>

## 23. Estados y errores

<Los estados por los que pasa el objeto central del producto y que ve la persona en
cada error. Todo error tiene mensaje y salida — nada de callejones.>

## 24. Seguridad y privacidad

<Que datos personales tocas, donde viven, quien puede verlos, que pasa al borrar
una cuenta. Amenazas que decidiste cubrir y cuales aceptaste.>

## 25. Operacion y despliegue

<Como se publica una version, como se revierte, que se monitoriza y quien despierta
cuando algo se cae.>

## 26. Presupuesto y costes

<Coste de construir (tiempo) y coste de operar (dinero/mes) con los numeros gordos.
A partir de que uso el coste variable te preocupa.>

## 27. Glosario

<Los terminos del dominio con la definicion que USA ESTE DOCUMENTO. Si dos personas
pueden entender distinto una palabra, va aqui.>
