# 04 · El puente y Claude Code

## Table of Contents

- [1. Que problema resuelve](#1-que-problema-resuelve)
- [2. La regla que no se salta nunca](#2-la-regla-que-no-se-salta-nunca)
- [3. Como queda tu settings.json](#3-como-queda-tu-settingsjson)
- [4. Lo que hace el puente por dentro](#4-lo-que-hace-el-puente-por-dentro)
- [5. Es opcional](#5-es-opcional)
- [6. Comprobarlo de verdad](#6-comprobarlo-de-verdad)
- [7. Si algo va mal](#7-si-algo-va-mal)

---

## 1. Que problema resuelve

Tu modelo local habla el formato de OpenAI. Claude Code habla el formato de Anthropic, y
**solo** acepta tres: Anthropic, Bedrock y Vertex. No hay opcion de «usa este endpoint de
OpenAI».

El puente traduce entre los dos, y hace algo mas importante: **deja pasar intactos** los
modelos de Anthropic.

```text
                    ┌─────────── puente :8787 ───────────┐
                    │                                    │
  Claude Code ──────┤  ¿el modelo es qwen o qwent?        │
                    │        │              │            │
                    │       si             no            │
                    │        │              │            │
                    │   traduce a       PASO DIRECTO ────┼──► api.anthropic.com
                    │   OpenAI          sin tocar        │    (tu suscripcion,
                    │        │          nada             │     intacta)
                    │        ▼                           │
                    │   medidor :8001 ──► motor :8000    │
                    └────────────────────────────────────┘
```

El paso directo es literal: no toca la autenticacion, ni las cabeceras, ni la estructura
del mensaje. Si Anthropic devuelve un error, te llega **su** error con **su**
identificador de peticion, no una version reescrita.

## 2. La regla que no se salta nunca

> **Nunca anadas `ANTHROPIC_AUTH_TOKEN` ni `ANTHROPIC_API_KEY` ni `apiKeyHelper`.**

Cualquiera de esas tres le dice a Claude Code «esto va por pasarela de pago» y **anula tu
suscripcion**. Empezarias a pagar por token sin darte cuenta, o directamente a recibir
errores de autenticacion.

El montaje funciona con **solo** `ANTHROPIC_BASE_URL`. Eso es justo lo que preserva el
paso directo autenticado: Claude Code sigue mandando su propia credencial de suscripcion,
y el puente ni la mira ni la sustituye.

`verificar.sh` comprueba esto explicitamente y lo marca como fallo si aparece alguna.

## 3. Como queda tu settings.json

La fase `claude` de `montar.sh` anade **solo** estas claves a `~/.claude/settings.json`,
respetando todo lo demas que tengas:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "qwen3.6-35b-local",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Qwen3.6 35B (local)",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Tu propio modelo, corriendo en tus GPU",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}
```

Antes de tocar nada se guarda una copia en `settings.json.antes-de-llm-local`, y **solo
la primera vez**: correr el montaje dos veces no pisa el respaldo del original con el ya
modificado.

Ademas se anota en `~/llm-local/claves-anadidas.txt` **que** claves puso el skill. Eso es
lo que permite que `desmontar.sh` quite exactamente esas y deje intacto lo que hayas
configurado tu despues. Restaurar el respaldo entero seria mas facil y te borraria meses
de ajustes.

### Tres cosas que sorprenden la primera vez

1. **Claude Code lee el entorno al ARRANCAR.** Una sesion ya abierta no ve el modelo
   nuevo por mucho que recargues. Abre una sesion nueva.
2. **La entrada aparece al final del selector**, no arriba.
3. **`qwent` no sale en el selector.** Claude Code admite un unico modelo propio en la
   lista. `qwent` existe igual: se teclea `/model qwent`.

### Salida de emergencia

Si el puente muere y necesitas Claude Code ya:

```bash
ANTHROPIC_BASE_URL="" claude
```

Vuelve a hablar directamente con Anthropic, sin tocar ningun fichero.

## 4. Lo que hace el puente por dentro

Mas de lo que parece. Cada una de estas piezas esta porque **algo se rompio sin ella**:

| Pieza | Por que existe |
|---|---|
| Degrada los mensajes de sistema de mitad de conversacion | Claude Code los manda, y la plantilla del modelo solo acepta sistema en la primera posicion. Sin esto, el **segundo** turno de cada conversacion devuelve error 400 |
| Cuenta la entrada real y recorta el presupuesto de salida | Claude Code no conoce la ventana del modelo local y pide un fijo. Sin esto la sesion se atasca **sin salida**: hasta `/compact` falla por lo mismo |
| Aplica el muestreo por modo | Los parametros oficiales son distintos en cada modo, y nadie mas los pone |
| Sube el minimo de salida en modo pensante | Con presupuesto corto el razonamiento se come el hueco y no sale respuesta |
| Devuelve el razonamiento historico en los dos nombres de campo | vLLM lo renombro en la 0.26; leerlo mal da el mismo sintoma que el punto anterior |
| Estima los tokens de entrada al abrir el stream | El servidor solo da el conteo al final, y Claude Code lo lee al principio: sin esto, el indicador de contexto de la barra inferior no funciona |

El recorte de presupuesto tiene su propia leccion, y es un fallo **mio** de esta misma
construccion: puse un suelo de seguridad de 1.024 tokens con la forma
`max(suelo, hueco)`, y ese suelo **se saltaba el recorte** — con un contexto casi lleno
el hueco real eran 511 y se pedian 1.024, desbordando por un token. Un suelo que puede
superar al techo no es una salvaguarda: es el mismo fallo con otra cara.

## 5. Es opcional

Todo esto sirve para usar el modelo desde Claude Code. Si no tienes suscripcion, o
simplemente no lo quieres:

```bash
sudo bash scripts/montar.sh --sin-puente
```

Te quedas con el motor, el medidor, los cuatro puestos de agente y el acceso directo por
el formato de OpenAI en `127.0.0.1:8001/v1`. Es un montaje **completo**, no uno a medias:
`verificar.sh` marca esos puntos como `OMIT`, no como fallo.

Anadirlo despues es una fase:

```bash
sudo bash scripts/montar.sh --only puente
sudo bash scripts/montar.sh --only claude
```

(`--only` admite una fase por invocacion; para encadenar desde una en adelante,
`--from puente`.)

## 6. Comprobarlo de verdad

Que el servicio este arriba no demuestra nada. Lo que hay que ver:

```bash
# el alias rapido responde
curl -s localhost:8787/v1/messages -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"qwen","max_tokens":64,"messages":[{"role":"user","content":"di listo"}]}'

# el pensante ademas devuelve un bloque de razonamiento
curl -s localhost:8787/v1/messages -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"qwent","max_tokens":6000,"messages":[{"role":"user","content":"di listo"}]}' \
  | grep -o '"thinking"' && echo "razona"

# y tu consumo aparece atribuido
curl -s localhost:8001/stats | python3 -m json.tool
```

La comprobacion que de verdad cierra el asunto es manual, en una sesion nueva:
`/model qwen` responde → `/model opus` responde **por suscripcion, sin error 401** →
vuelta a `qwen`. Si esas tres pasan, el puente y el paso directo conviven.

Aviso del propio selector: **cambiar de modelo relee toda la conversacion sin cache**.
Alternar cada dos mensajes en una conversacion larga sale caro en tiempo.

## 7. Si algo va mal

| Sintoma | Causa probable | Que hacer |
|---|---|---|
| El modelo local no aparece en `/model` | Sesion abierta antes del cambio | Abre una sesion nueva |
| Error 400 en el segundo mensaje, el primero fue bien | Mensaje de sistema a mitad de conversacion | Version antigua del puente; ver `07-averias.md` |
| `qwent` gasta tokens y responde vacio | Presupuesto de salida corto, o campo de razonamiento mal leido | Ver `03-modelo-y-muestreo.md` §6 |
| La sesion se atasca y hasta `/compact` falla | Recorte de contexto | `/model opus`, compacta alli, vuelve |
| Los modelos de Anthropic dan 401 | Hay credencial de pasarela en `settings.json` | Quitala. Es el unico error irreversible de esta pagina |
| El indicador de contexto no se mueve | Estimacion de entrada | Ver `07-averias.md` |

```bash
journalctl -u llm-bridge -f                    # todo lo que pasa por el puente
journalctl -u llm-bridge -f | grep tok/s       # velocidad de cada respuesta local
```
# Uso personal fuera de la fábrica

Las órdenes interactivas para volver del modelo local las teclea el alumno en su propio CLI.
El alias de familia es la orden real de ese CLI personal; queda fuera de la doctrina de modelos
de la fábrica, cuyos roles consumen exclusivamente los identificadores completos del registro.
