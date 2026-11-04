<!-- prd: estado=DRAFT version=0.1 supersedes=- appetite=completo -->

# PRD — Taquilla de paquetes (instancia minima del nivel Completo)

| Campo | Valor |
|---|---|
| Estado | DRAFT |
| Version | 0.1 |
| Supersedes | — |
| Appetite | completo |

## 1. Resumen y pitch

Taquillas compartidas de edificio para recibir paquetes sin estar en casa.

## 2. Problema y persona

Nadia (teletrabaja martes y jueves) pierde 2 paquetes al mes en porterias ajenas.

## 3. Wedge

Una taquilla en SU portal: el repartidor deja, Nadia recoge con codigo.

## 4. Alcance del appetite

Entra: reserva, deposito, recogida, avisos. Fuera: pagos entre vecinos.

## 5. Historias de usuario

- H1 · Como Nadia, quiero un codigo de recogida por paquete, para abrir solo mi taquilla.

## 6. Criterios de aceptacion

- PASA si: el codigo abre exactamente la taquilla asignada y solo una vez.
- FALLA si: un codigo caducado abre cualquier taquilla.

## 7. No-gos

- NO haremos app para el repartidor; en su lugar: teclado fisico en la taquilla.

## 8. Fases walking-skeleton

1. Esqueleto: asignar taquilla -> depositar -> codigo -> recoger.

## 9. Riesgos y premisas

- Premisa: los repartidores usaran el teclado · Como se verifica: piloto de 2 semanas.

## 10. Landscape

Consignas comerciales existen en supermercados; ninguna opera dentro de portales.

## 11. Interrogatorio sellado

Las 6 respuestas selladas el 2026-06-20 (persona: Nadia; wedge: portal propio).

## 12. Alternativas A B C

A solo-recogida · B recogida+devoluciones · C red de portales. Gano A.

## 13. Metricas de exito

0 paquetes perdidos en el piloto de 8 semanas; >= 70% de entregas via taquilla.

## 14. Flujo principal

Repartidor llega -> teclea referencia -> taquilla abre -> deposita -> Nadia recibe codigo -> recoge.

## 15. Requisitos no funcionales

Apertura < 2 s; bateria de respaldo 48 h; teclado apto para guantes.

## 16. Dependencias y limites

Depende del permiso de la comunidad de vecinos y de corriente en el portal.

## 17. Decisiones clasificadas

| Decision | Clase | Porque | Quien |
|---|---|---|---|
| Teclado fisico y no app | taste | menos friccion para repartidores | Nadia |

## 18. Plan de validacion

Maqueta con cerradura y teclado en un portal amigo antes de fabricar.

## 19. Casos de uso formales

### CU-01 · Recoger paquete

- Historia: H1
- Actor: Nadia
- Precondicion: paquete depositado, codigo vigente
- Disparador: teclea el codigo
- Flujo principal: 1. valida codigo 2. abre taquilla 3. marca recogido
- Alternativos: codigo caducado -> mensaje y aviso
- Postcondicion: taquilla libre

## 20. Diagrama actores-modulos

```text
[Repartidor] --deposita--> [Taquilla]
[Nadia] --recoge--> [Taquilla] --avisa--> [Notificador]
```

## 21. Modelo de entidades

```text
Vecino (nombre, portal) 1--N Paquete (referencia, estado) N--1 Taquilla (numero)
```

## 22. Version 10-estrellas

El paquete se teletransporta a la cocina. Recorte: la taquilla en el portal ya
captura el 90% del valor.

## 23. Estados y errores

Paquete: esperado -> depositado -> recogido | caducado. Todo error con mensaje en pantalla.

## 24. Seguridad y privacidad

Solo nombre y portal; los codigos caducan a las 72 h; borrado al darse de baja.

## 25. Operacion y despliegue

Firmware actualizable por USB; reversion a la version anterior guardada en la placa.

## 26. Presupuesto y costes

Prototipo 400; coste por taquilla 90; operacion 3/mes por electricidad y SIM.

## 27. Glosario

Referencia: el identificador que teclea el repartidor. Codigo: el secreto de recogida.
