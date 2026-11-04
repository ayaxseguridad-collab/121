# 02 · El motor: vLLM en contenedor

## Table of Contents

- [1. Por que vLLM y no otra cosa](#1-por-que-vllm-y-no-otra-cosa)
- [2. La unidad, flag por flag](#2-la-unidad-flag-por-flag)
- [3. El entorno del contenedor](#3-el-entorno-del-contenedor)
- [4. Tensor parallel sin acceso directo entre GPU](#4-tensor-parallel-sin-acceso-directo-entre-gpu)
- [5. El limite de potencia, que es volatil](#5-el-limite-de-potencia-que-es-volatil)
- [6. Arranque, parada y que esperar](#6-arranque-parada-y-que-esperar)
- [7. Reproducibilidad: digest, no etiqueta](#7-reproducibilidad-digest-no-etiqueta)
- [8. Cambiar algo sin romperlo](#8-cambiar-algo-sin-romperlo)

---

## 1. Por que vLLM y no otra cosa

Hay motores mas comodos de instalar. Se eligio este por una razon medida:

> **Este montaje sirve a cinco clientes a la vez.** Los motores pensados para «una
> persona charlando con su modelo» **serializan**: ocho peticiones tardan ocho veces lo
> que una. vLLM las agrupa en el mismo paso de calculo (*continuous batching*), asi que
> cinco clientes no cuestan cinco veces mas.

El numero que lo justifica, medido en la maquina de referencia:

| Escenario | Resultado |
|---|---|
| 1 cliente | 127-135 tok/s |
| 5 clientes a la vez | ~72 tok/s **cada uno** · 359 agregados, sin colas |

Con un motor que serializa, esos cinco clientes habrian dado ~26 tok/s cada uno. La
diferencia no es de ajuste fino: es de arquitectura.

Otras decisiones, con su motivo:

| Decision | Por que |
|---|---|
| **NVFP4** y no FP8 | FP8 no cabe (34,89 GiB sobre 31 disponibles) y ademas falla en estas tarjetas |
| **Sin MTP** (prediccion multi-token) | Rompe las llamadas a herramientas y es incompatible con el cache de prefijo, que con agentes vale mas |
| **Un solo servidor**, no uno por usuario | Dos instancias pedirian 44 GB sobre 32 |
| **`--moe-backend marlin`** | Es lo que recomienda el propio publicador del modelo cuantizado |

## 2. La unidad, flag por flag

```ini
ExecStart=/usr/bin/docker run --rm --name vllm \
  --runtime nvidia --gpus all \
  --ipc=host \
  -v /srv/models/hf:/root/.cache/huggingface \
  -p 127.0.0.1:8000:8000 \
  --env-file /etc/llm-local/vllm.env \
  vllm/vllm-openai@sha256:ffb2d59b… \
    --model nvidia/Qwen3.6-35B-A3B-NVFP4 \
    --served-model-name claude-qwen-local \
    --tensor-parallel-size 2 \
    --disable-custom-all-reduce \
    --moe-backend marlin \
    --max-model-len 262144 \
    --max-num-seqs 16 \
    --gpu-memory-utilization 0.90 \
    --enable-prefix-caching \
    --limit-mm-per-prompt "{\"image\":0,\"video\":0}" \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_xml --enable-auto-tool-choice
```

Fijate en lo que **no** esta: `--api-key`. El motor toma su clave de `VLLM_API_KEY`, en
el fichero de entorno (modo 600). Ver §2.1.

| Flag | Que hace y por que esta |
|---|---|
| `--gpus all` | **Nunca** `--gpus '"device=0,1"'`: esa forma no sobrevive al parseo de `ExecStart` y systemd aborta con «cannot set both Count and DeviceIDs» |
| `-p 127.0.0.1:8000:8000` | Solo loopback. El servidor **no** se expone a la red local |
| `--max-num-seqs 16` | El valor por defecto (256) **impide arrancar** con este modelo por los bloques Mamba de sus capas lineales. No es un ajuste de rendimiento |
| `--max-model-len 262144` | Ventana nativa del modelo. Con 131072 el cliente se atasca antes (ver averias) |
| `--gpu-memory-utilization 0.90` | Deja un 10 % de margen. Subirlo aprieta el cache de contexto y acerca el fallo por memoria |
| `--enable-prefix-caching` | Con agentes, la conversacion crece por el final: reutilizar el prefijo ya calculado ahorra la mayor parte del trabajo de lectura. Medido: una conversacion de 100k reenviada pasa de 26,9 s a **2,2 s** hasta el primer token (12×) |
| `--limit-mm-per-prompt` a cero | Este montaje es de texto. Reservar memoria para imagen y video seria tirarla |
| `--reasoning-parser qwen3` | Sin el, el razonamiento sale mezclado con la respuesta como texto plano |
| `--tool-call-parser qwen3_xml` | Idem con las llamadas a herramientas: sin el, el cliente no las distingue |
| `--disable-custom-all-reduce` | La reduccion propia de vLLM asume acceso directo entre GPU, que aqui no existe |

### 2.1 · Por que las claves no estan aqui

Los argumentos de un proceso los lee **cualquier usuario de la maquina**:

```bash
ps aux | grep vllm      # esto lo puede correr quien sea
```

Si las cinco claves de usuario estuvieran en esa linea, cualquiera podria usar la de
otro y la atribucion por usuario dejaria de significar nada — que es justamente para lo
que existe el medidor. Asi que:

```text
  medidor  ──►  conoce las 5 claves de usuario   (claves.env, modo 640 root:usuario)
               autentica, contabiliza, y reescribe
               la cabecera hacia el motor
                        │
  motor    ◄────────────┘  conoce UNA clave interna  (vllm.env, modo 600 root)
                           que no aparece en ninguna linea de arranque
```

`verificar.sh` comprueba las dos mitades: que las cinco claves autorizan **en el
medidor**, que una inventada se rechaza, que el **motor** no atiende con una clave de
usuario, y que no hay ninguna clave visible en la linea de arranque.

Si algun dia usas `--api-key` a mano, recuerda que va **una sola vez** con todas las
claves detras: repetir el flag hace que la ultima pise a las demas, vLLM lo avisa con
«Found duplicate keys» entre el ruido del arranque, y como una si funciona el fallo
parece intermitente.

## 3. El entorno del contenedor

`/etc/llm-local/vllm.env`, **modo 600** — aqui vive la clave interna del motor, que es
el sitio correcto para ella: un fichero restringido no lo lee cualquiera, y un argumento
de proceso si.

```bash
VLLM_API_KEY=<clave interna, generada al montar>
UPSTREAM_KEY=<el mismo valor, con el nombre que espera el medidor>
CUDA_DEVICE_ORDER=PCI_BUS_ID
NCCL_P2P_DISABLE=1
NCCL_IB_DISABLE=1
VLLM_USE_DEEP_GEMM=0
HF_HUB_OFFLINE=1
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
```

`HF_HUB_OFFLINE=1` hace que los arranques del dia a dia no salgan a internet: mas
rapidos y deterministas. Por eso los pesos se descargan **antes**, en su propia fase, con
la red abierta. Si algun dia cambias de modelo, comenta esa linea primero.

## 4. Tensor parallel sin acceso directo entre GPU

En una maquina de sobremesa, las dos tarjetas normalmente **no** pueden hablarse
directamente: no hay puente entre ellas y una suele colgar del chipset. Compruebalo:

```bash
nvidia-smi topo -p2p rw
#   CNS  =  Chipset Not Supported  ->  no hay acceso directo
```

Dejar que la libreria de comunicacion lo intente cuesta arranques fallidos y cuelgues sin
mensaje. De ahi las tres piezas:

```text
NCCL_P2P_DISABLE=1        no intentes acceso directo entre tarjetas
NCCL_IB_DISABLE=1         no busques red de altas prestaciones que no existe
--disable-custom-all-reduce   usa la reduccion estandar, no la que asume acceso directo
```

Se paga algo de latencia en cada paso, y aun asi salen 127-135 tok/s. Perseguir ese
margen a cambio de arranques inestables es mal negocio.

## 5. El limite de potencia, que es volatil

El limite de potencia y los ajustes de reloj **se pierden en cada reinicio**. Aplicarlos
a mano una vez y darlos por hechos es el error clasico: meses despues la maquina corre a
tope y nadie lo sabe.

Por eso viven en su propia unidad, que se ejecuta antes que Docker:

```bash
systemctl status nvidia-powerlimit     # ¿quedo aplicado?
nvidia-smi --query-gpu=index,enforced.power.limit,temperature.gpu --format=csv
```

El script **falla ruidosamente**: comprueba que el limite pedido esta dentro del rango de
la tarjeta, lo aplica en **todas** (no solo en la primera) y verifica despues que quedo
puesto y que las dos tienen los mismos relojes maximos. Una tarjeta con reloj distinto
crea un rezagado que frena a las dos.

Y en `verificar.sh` este punto **se cuenta aparte**. Un limite que no queda aplicado no
puede esconderse dentro de un «persistencia correcta»: cambiaria el consumo y la
temperatura reales de la maquina sin que nadie se entere.

Para desactivarlo: `APLICAR_POWER_LIMIT=no` en `scripts/00-config.sh`.

## 6. Arranque, parada y que esperar

```bash
sudo systemctl status vllm
sudo systemctl restart vllm
journalctl -u vllm -f                 # seguir el arranque en vivo
curl -sf localhost:8000/health && echo listo
```

- **El primer arranque tarda 2-3 minutos.** Compila los grafos de calculo. No es que
  este colgado.
- **La primera peticion tras arrancar va a ~18 tok/s.** Es calentamiento; se descarta al
  medir.
- `docker logs -f vllm` imprime el rendimiento medio cada pocos segundos.

## 7. Reproducibilidad: digest, no etiqueta

La unidad fija la imagen por **digest**:

```text
vllm/vllm-openai@sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52
```

equivalente hoy a la etiqueta `v0.26.0`. Una etiqueta movil es comoda y hace que la
maquina de dentro de tres meses no sea la que se rodo hoy: cuando algo falle, no se
podra saber si cambio tu configuracion o cambio la imagen.

El digest se comprobo **descargable de forma anonima**, sin cuenta ni credenciales de
registro: la copia local demuestra que se rodo, no que otro pueda traersela.

Para actualizar a proposito: cambia `VLLM_IMAGE` en `scripts/00-config.sh`, corre
`sudo bash scripts/montar.sh --only servicio` y vuelve a pasar `banco.sh`. Sin medir
despues, no sabras si la version nueva mejoro o empeoro.

## 8. Cambiar algo sin romperlo

Todo lo configurable esta en `scripts/00-config.sh` y se puede sobreescribir por entorno.
La forma segura de tocar algo:

```bash
# 1. mira lo que cambiaria, sin tocar nada
MAX_NUM_SEQS=24 bash scripts/montar.sh --only servicio --dry-run

# 2. aplicalo
sudo MAX_NUM_SEQS=24 bash scripts/montar.sh --only servicio

# 3. comprueba y MIDE — un cambio sin medir no es una mejora, es una esperanza
bash scripts/verificar.sh && bash scripts/banco.sh
```

Dos avisos con nombre propio:

- **No bajes `--max-model-len` a 131072.** Parece inofensivo y provoca un atasco sin
  salida en Claude Code (esta contado en `07-averias.md`).
- **No subas `--gpu-memory-utilization` por encima de 0.90.** El margen que quitas sale
  del cache de contexto, y el fallo aparece a mitad de una conversacion larga, no al
  arrancar.
