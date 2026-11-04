<!-- prd: estado=DRAFT version=0.2 supersedes=- appetite=lite -->

# PRD — Registro de horas, reconversion

| Campo | Valor |
|---|---|
| Estado | DRAFT |
| Version | 0.2 |
| Supersedes | — |
| Appetite | lite |

## 1. Resumen y pitch

El script de horas que Iker ya usa, convertido en herramienta con informes por
cliente. El as-is funciona; el PRD documenta el delta.

## 2. Problema y persona

Iker (freelance) registra horas en un fichero de texto y pierde una tarde al mes
montando la factura a mano.

## 3. Wedge

El informe mensual por cliente en un comando: la tarde de facturas pasa a 5 minutos.

## 4. Alcance del appetite

Entra: informe por cliente y mes. Fuera a proposito: facturacion, web, multiusuario.

## 5. Historias de usuario

- Como Iker, quiero el total de horas por cliente del mes, para facturar sin sumar a mano.

## 6. Criterios de aceptacion

- PASA si: el informe de julio suma exactamente las lineas de julio del registro.
- FALLA si: una linea del registro queda fuera del informe de su mes.

## 7. No-gos

- NO haremos interfaz grafica; en su lugar: un subcomando 'informe'.

## 8. As-is del codigo

Lo que el sistema hace HOY, extraido del repo antes de entrevistar:

- `codigo/exportar.sh` vuelca el registro completo por stdout.
- `codigo/registro/horas.txt` guarda una linea por apunte: fecha, cliente, horas.

No hay tests ni agregacion: el "informe" actual es leer el fichero entero.

## 9. Fases walking-skeleton

1. Esqueleto: leer registro -> filtrar mes -> total por cliente, en texto plano.

## 10. Riesgos y premisas

- Premisa: el formato de linea actual no cambia · Como se verifica: Iker lo confirma.
