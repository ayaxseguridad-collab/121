<!-- prd: estado=DRAFT version=0.1 supersedes=- appetite=estandar -->

# PRD — <nombre del producto>

| Campo | Valor |
|---|---|
| Estado | DRAFT |
| Version | 0.1 |
| Supersedes | — |
| Appetite | estandar |

> Nivel Estandar: 18 secciones (las 9 de Lite + 9 propias). Para un producto de
> 1-3 meses o con mas de un flujo importante. Las secciones 1-9 son las mismas de
> Lite — misma guia, mismo rigor. Versionado: igual que en Lite (DRAFT→APPROVED,
> `supersedes=` para reescrituras; al cambiar la primera linea, actualiza tambien
> la tabla de abajo — la linea de comentario manda).

## 1. Resumen y pitch

<2-4 frases: que es, para quien, que cambia cuando existe.>

## 2. Problema y persona

<Persona con NOMBRE. Que hace hoy sin tu producto. Evidencia, no intuicion.>

## 3. Wedge

<La cunia minima que ya cambia algo. Por que ahora. Por que tu.>

## 4. Alcance del appetite

<Que entra y que se queda fuera a proposito. Modo de alcance elegido y por que.>

## 5. Historias de usuario

- Como ..., quiero ..., para ...

## 6. Criterios de aceptacion

- PASA si: <condicion observable>
- FALLA si: <condicion observable>

## 7. No-gos

- NO haremos <X>; en su lugar: <Y>.

## 8. Fases walking-skeleton

1. Esqueleto: <recorrido minimo completo>
2. <fase 2>

## 9. Riesgos y premisas

- Premisa: <...> · Como se verifica: <...>

## 10. Landscape

<Que existe ya que resuelve esto o casi. Con evidencia ACTUAL (buscada hoy con
tus herramientas, fuera del skill; aqui entra el snapshot con su fecha): nombres,
enlaces, que hacen bien y donde se quedan cortos. Si tu landscape sale de
memoria, esta caducado por definicion.>

## 11. Interrogatorio sellado

<Las respuestas finales a las 6 forcing questions del interrogatorio, tal como
quedaron selladas. Si una respuesta cambio durante el proceso, aqui va la ultima.>

## 12. Alternativas A B C

<Los tres recortes de alcance que se pusieron sobre la mesa, y cual se eligio.
A = minimo defendible · B = equilibrio · C = ambicioso. Di por que gano el elegido.>

## 13. Metricas de exito

<2-4 metricas observables con umbral y fecha. "Exito" sin numero no es una metrica.>

## 14. Flujo principal

<El recorrido de la persona de punta a punta, paso a paso, con el estado del sistema
en cada paso. Un solo flujo: el que justifica el producto.>

## 15. Requisitos no funcionales

<Solo los que este producto de verdad necesita: latencia, volumen, coste por uso,
accesibilidad, idiomas. Con numero cada uno.>

## 16. Dependencias y limites

<De que servicios, datos o personas depende esto. Que limite externo puede pararlo.>

## 17. Decisiones clasificadas

<El audit trail: cada decision relevante con su clase — mechanical (habia una sola
respuesta razonable), taste (eleccion de criterio, documenta el porque) o challenge
(cuestiono una premisa del propio PRD). Tabla: decision · clase · porque · quien.>

| Decision | Clase | Porque | Quien |
|---|---|---|---|

## 18. Plan de validacion

<Que prototipo, wayfinder o experimento valida las premisas gordas ANTES de
construir en serio. Que decision desbloquea cada experimento.>
