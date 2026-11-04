<!-- prd: estado=APPROVED version=1.0 supersedes=- appetite=lite -->

# PRD — Recordatorio de riego

| Campo | Valor |
|---|---|
| Estado | APPROVED |
| Version | 1.0 |
| Supersedes | — |
| Appetite | lite |

## 1. Resumen y pitch

App minima que avisa a Marta de cuando regar cada planta. Una lista, una
frecuencia por planta, un aviso. Nada mas.

## 2. Problema y persona

Marta (arquetipo: oficinista con 12 plantas) riega por intuicion y se le mueren
2-3 plantas al anio. Hoy usa notas en papel que pierde.

## 3. Wedge

La cunia: el aviso de riego de UNA planta ya evita una muerte. Por que ahora:
Marta acaba de perder la monstera.

## 4. Alcance del appetite

Entra: lista de plantas, frecuencia fija, aviso local. Fuera a proposito: fotos,
sensores, comunidad.

## 5. Historias de usuario

- Como Marta, quiero anadir una planta con su frecuencia, para no memorizarla.
- Como Marta, quiero recibir el aviso el dia que toca, para regar a tiempo.

## 6. Criterios de aceptacion

- PASA si: al crear una planta con frecuencia 7, el aviso salta a los 7 dias.
- FALLA si: un aviso llega mas de 12 horas tarde.

## 7. No-gos

- NO haremos cuentas de usuario; en su lugar: todo local en el dispositivo.

## 8. Fases walking-skeleton

1. Esqueleto: crear planta -> esperar -> ver el aviso (feo pero entero).
2. Editar y borrar plantas.

## 9. Riesgos y premisas

- Premisa: a Marta le vale frecuencia fija · Como se verifica: 2 semanas de uso propio.
- Riesgo aceptado: sin backup — si pierde el movil, pierde la lista.
