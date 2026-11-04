# Cómo volver a la versión anterior

> Probado el 22/08/2026. Si algo de la v3 no anda, esto la devuelve a como estaba.

## Lo primero que hay que saber

**No alcanza con volver el código.** La v3 cambia la estructura de la tabla de
usuarios al arrancar, y esa migración no se deshace sola. Si se vuelve solo el
código, el panel arranca pero **el administrador no puede entrar**: el código
viejo busca al usuario por su área, y en la tabla nueva el administrador no
tiene área. Sin administrador no se puede administrar nada.

Probado: código v2.2 sobre base migrada → `{"error":"Área o clave incorrecta"}`.

**Hay que volver las dos cosas: el código y la base.**

## Los puntos de retorno

| | |
|---|---|
| Código anterior | etiqueta `v2.2.0` en GitHub |
| Código actual | etiqueta `v3.0.0` |
| Base anterior | `datos/copias/crm-20260822-1843-a-mano.db` en el volumen de Railway |

La copia de la base es de las 18:43 del 22/08, siete minutos antes del despliegue.
Railway además guarda una copia automática cada vez que el servicio arranca.

## El procedimiento

**1. Restaurar la base.** Desde el panel, en Configuración → Copias, elegir
`crm-20260822-1843-a-mano.db` y restaurar. O por API:

```
POST /api/copias/restaurar   {"archivo": "crm-20260822-1843-a-mano.db"}
```

**2. Volver el código.** Desde la máquina, en `crm-atencion`:

```
git revert --no-edit 1099bf6
git push origin master
```

Railway redespliega solo. Tarda unos dos minutos.

**Ese orden importa**: si se vuelve el código primero, el panel queda unos
minutos sin que nadie pueda administrarlo.

## Qué se pierde al volver

Todo lo que se haya cargado **entre el despliegue y la vuelta atrás**: pedidos
nuevos, movimientos, notas y personas dadas de alta. La base vuelve al estado de
las 18:43 del 22/08.

Si ya pasó un día de uso, conviene primero mirar qué se cargó en el medio y
decidir si vale la pena rehacerlo a mano.

## Antes de volver atrás, mirar si el problema es otro

Tres cosas que parecen "no anda" y se arreglan sin tocar nada:

- **«No puedo entrar»** — las sesiones abiertas se cerraron con la actualización.
  Hay que entrar de nuevo, con la misma clave de siempre. El usuario se llama
  igual que el área.
- **«No veo mis pedidos»** — los usuarios migrados quedaron viendo todo. Si
  alguien ve de menos, es porque tiene encendido «ve solo su sector» en Personas.
- **«No llegan los avisos»** — mirar en Avisos si WhatsApp figura conectado. Es
  lo primero que se cae, y no tiene nada que ver con esta versión.
