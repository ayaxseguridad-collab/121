# 05 · Cinco usuarios, el medidor y los agentes

## Table of Contents

- [1. Cinco identidades, cinco claves](#1-cinco-identidades-cinco-claves)
- [2. Todos al medidor, nadie al motor](#2-todos-al-medidor-nadie-al-motor)
- [3. El historico y para que sirve](#3-el-historico-y-para-que-sirve)
- [4. Los cuatro puestos de agente](#4-los-cuatro-puestos-de-agente)
- [5. Usuarios configurados no es concurrencia efectiva](#5-usuarios-configurados-no-es-concurrencia-efectiva)
- [6. Conectar otros clientes](#6-conectar-otros-clientes)

---

## 1. Cinco identidades, cinco claves

El montaje genera **cinco claves aleatorias** en tu maquina, durante la instalacion:

```text
  tu sesion (Claude Code, via puente)   sk-lead-<aleatorio>
  puesto 1                              sk-hermes-1-<aleatorio>
  puesto 2                              sk-hermes-2-<aleatorio>
  puesto 3                              sk-hermes-3-<aleatorio>
  puesto 4                              sk-hermes-4-<aleatorio>
```

Viven en `/etc/llm-local/claves.env`, modo `0640` y grupo tu usuario: systemd las lee
como administrador antes de bajar privilegios, tu puedes consultarlas para configurar
clientes a mano, y el resto del sistema no.

**Quien las valida es el MEDIDOR**, no el motor. Y no es un detalle de implementacion:

```text
  cliente ──clave propia──► medidor  ──clave interna──► motor
                            (autentica y contabiliza)   (solo conoce una clave,
                                                         en un fichero modo 600)
```

Si las cinco claves estuvieran en la linea de arranque del motor, **cualquier usuario de
la maquina las veria con `ps`** y podria hacerse pasar por otro. Como el reparto por
usuario es justamente el sentido de tener cinco claves, eso lo dejaria en nada. Por eso
el motor no lleva `--api-key`.

**Por que aleatorias y no `sk-lead` a secas.** Por lo mismo: el servidor solo escucha en
loopback, asi que no se trata de que alguien las adivine desde fuera, sino de que una
clave predecible permite a cualquier proceso local usar la de otro.

Ver las tuyas:

```bash
sudo cat /etc/llm-local/claves.env
```

Rotarlas: borra el fichero y corre `sudo bash scripts/montar.sh --only claves --from claves`.

## 2. Todos al medidor, nadie al motor

```text
  clientes ──► medidor :8001 ──► motor :8000
                   │
                   └─► /stats  ¿quien esta consumiendo, ahora mismo?
```

El medidor es un intermediario transparente que no toca las peticiones: solo apunta
quien consume cuanto. Retransmite los streams trozo a trozo sin acumularlos, e inyecta la
peticion de contabilidad para que el ultimo trozo traiga el consumo real.

> **Regla:** todos los clientes hablan con **:8001**. Nadie con **:8000** salvo el propio
> medidor.
>
> Apuntar al motor directamente **funciona igual de bien**, y por eso es peligroso: no da
> ningun error, simplemente ese consumo desaparece del reparto y las cuentas dejan de
> cuadrar sin que nada avise.

Consultarlo:

```bash
curl -s localhost:8001/stats | python3 -m json.tool
```

```json
{
  "agg_gen_tps": 359.4,
  "running": 5,
  "waiting": 0,
  "users": [
    {"user": "tu sesion", "gen_tps": 72.1, "out_total": 184203, "in_total": 39700412, "reqs": 412},
    {"user": "hermes-1",  "gen_tps": 71.8, "out_total":  94011, "in_total":  2210044, "reqs": 128}
  ]
}
```

`waiting` sostenido por encima de 0 significa que el servidor esta saturado: hay mas
trabajo del que puede atender a la vez.

Y en vivo, para toda la maquina (tambien por el medidor, la regla vale para las
herramientas propias):

```bash
STATS_KEY=<tu clave> python3 /opt/llm-local/tps.py    # escritura y lectura, cada 2 s
```

## 3. El historico y para que sirve

El medidor vuelca una linea por minuto **con actividad** en
`~/llm-local/history/usage-AAAA-MM.jsonl`, rotada por mes. Sobrevive a los reinicios.

Cada linea lleva los **deltas** de ese minuto y los totales del proceso. Para agregar
historicamente hay que sumar los **deltas**: los totales se reinician cuando el servicio
se reinicia.

```bash
# tokens generados este mes, por usuario
python3 - <<'PY'
import json, glob, collections
t = collections.Counter()
for f in glob.glob("~/llm-local/history/usage-*.jsonl".replace("~", __import__("os").path.expanduser("~"))):
    for linea in open(f):
        for usuario, d in json.loads(linea)["deltas"].items():
            t[usuario] += d["out"]
for u, n in t.most_common():
    print(f"{u:24} {n:>12,} tokens")
PY
```

Con eso puedes calcular lo que te habria costado por API el mismo trabajo. Es el numero
que hace entender de golpe para que sirve tener el modelo en casa.

## 4. Los cuatro puestos de agente

Cada puesto tiene su propio perfil, su propia clave y su propio directorio de datos:

```yaml
# ~/.hermes/profiles/hermes-1/config.yaml
model:
  default: claude-qwen-local
  provider: custom
  base_url: http://127.0.0.1:8001/v1
  api_key: sk-hermes-1-<aleatorio>
  context_length: 131072

delegation:
  max_concurrent_children: 1
```

```bash
hermes-1 chat                       # interactivo
hermes-1 chat -Q -q "resume esto"   # una sola pregunta, sin interfaz
```

Tres avisos que se pagan caros:

1. **Nunca dos instancias sobre el mismo directorio de datos.** Corrompe el estado. Por
   eso hay cuatro perfiles separados y no uno usado cuatro veces.
2. **`max_concurrent_children: 1`.** Con la delegacion por defecto (3 hijos por agente),
   cuatro puestos pueden generar **hasta 16 flujos** contra un servidor dimensionado para
   5. Este valor viene de trabajo de campo, no de la documentacion oficial: si tu version
   lo ignora, lo veras en `waiting` del medidor.
3. **Para scripts, siempre `-Q -q`.** Meterle texto por una tuberia sin esas opciones
   abre la interfaz interactiva y muere sin explicacion.

Medido: los cuatro en paralelo, una pregunta con calculo cada uno, **13 segundos de
reloj, 4 de 4 correctas**.

Si Hermes no esta instalado, el montaje escribe los perfiles igualmente y te dice como
instalarlo. No se pierde nada.

## 5. Usuarios configurados no es concurrencia efectiva

Son dos cosas distintas y conviene no confundirlas:

| | Que significa |
|---|---|
| **Usuarios configurados** | Cuantas identidades hay con clave propia y consumo atribuido. Aqui: **5**, siempre |
| **Concurrencia efectiva** | Cuantos pueden trabajar a la vez sin hacer cola. Depende de tu maquina |

En la de referencia coinciden: 5 clientes reales dieron ~72 tok/s cada uno **sin colas**.
En otra maquina que pase la puerta pueden configurarse los mismos 5 y encontrarse con
`waiting > 0`. Por eso el skill no promete concurrencia: promete cinco identidades, y te
da `banco.sh` para que midas la tuya.

Un caso concreto de saturacion, medido: poner a los cinco en modo pensante a la vez llevo
un lote de **1 segundo a 61**. El modo pensante no es «un poco mas lento»: monopoliza la
maquina.

Y hay un tercer eje, que es el que muerde cuando la maquina tiene carga real: **el cache
de contexto es un recurso COMPARTIDO**. En la referencia son 333.077 tokens para los
cinco usuarios juntos — una sola conversacion a ventana completa (262k) ocupa el 79% ella
sola. Tres numeros medidos que conviene saber antes de prometer tiempos:

| Que pasa | Medido |
|---|---|
| Trafico ajeno moderado (~50k tokens) | Tu prefijo de 100k **sobrevive**: 98,4% de acierto, 0,7 s |
| Trafico ajeno grande (100k o mas) | Tu prefijo **muere entero**: 0,0% de acierto, no degradacion gradual |
| Tu peticion detras de un vecino que lee 160k | **77 s** donde solias tener 0,3 (250×) |

El desalojo es un acantilado por como funciona el cache: se desalojan primero los bloques
mas viejos, que son el **comienzo** de tu prefijo — y un prefijo sin cabeza no sirve
aunque el resto siga en memoria. La parte tranquilizadora, tambien medida: volver con el
prefijo desalojado cuesta **exactamente lo mismo que en frio** (26,49 s frente a 26,92),
ni un segundo de castigo extra.

Regla de andar por casa: con turnos de agente de 2-5k tokens, **10-25 turnos ajenos**
bastan para tumbar un prefijo de 100k. Si tu sesion de Claude Code va cargada y los
puestos Hermes estan trabajando, la espera larga del primer token no es una averia: es el
cache compartido haciendo su aritmetica. Nada que arreglar — pero si algo que saber.

## 6. Conectar otros clientes

Cualquier cosa que hable el formato de OpenAI vale. Siempre contra **:8001**:

```python
from openai import OpenAI

cliente = OpenAI(base_url="http://127.0.0.1:8001/v1", api_key="sk-hermes-1-…")
r = cliente.chat.completions.create(
    model="claude-qwen-local",
    messages=[{"role": "user", "content": "Hola"}],
    temperature=0.7, top_p=0.80,
    extra_body={"top_k": 20, "presence_penalty": 1.5},   # perfil rapido
)
print(r.choices[0].message.content)
```

Para el modo pensante desde un cliente propio, sin pasar por el puente:

```python
r = cliente.chat.completions.create(
    model="claude-qwen-local",
    messages=[{"role": "user", "content": "¿Cuantas erres hay en ferrocarril?"}],
    max_tokens=6000,                       # margen suficiente, o no habra respuesta
    temperature=0.6, top_p=0.95,
    extra_body={"top_k": 20, "presence_penalty": 0.0,
                "chat_template_kwargs": {"enable_thinking": True}},
)
```

Si escribes tu propio cliente y quieres los dos modos, copia los parametros de
`03-modelo-y-muestreo.md` §3 tal cual. No usarlos degrada el resultado sin que lo
parezca.
