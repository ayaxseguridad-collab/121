#!/usr/bin/env bash
# 00-config.sh — valores por defecto del montaje. Todo es sobreescribible por entorno.
#
# Este fichero NO contiene claves ni secretos. Donde viven, y con que permisos:
#   $KEYS_FILE (0640 root:<usuario>)  las 5 claves de usuario, generadas al azar al
#                                     montar. Las lee el MEDIDOR, que es quien autentica.
#   $ENV_FILE  (0600 root)            la clave INTERNA del motor, la unica que el
#                                     motor conoce. Nunca aparece en la linea de
#                                     arranque de ningun proceso (`ps` la veria).

# ---------------------------------------------------------------- identidad
: "${LL_USER:=${SUDO_USER:-$USER}}"
: "${LL_HOME:=$(getent passwd "$LL_USER" | cut -d: -f6)}"

# ---------------------------------------------------------------- rutas
: "${LL_PREFIX:=/opt/llm-local}"          # binarios y scripts instalados
: "${LL_ETC:=/etc/llm-local}"             # configuracion y entorno del servicio
: "${LL_STATE:=$LL_HOME/llm-local}"       # historico del medidor, perfil.conf, banco
: "${LL_MODELS:=/srv/models/hf}"          # cache de pesos (bind mount al contenedor)
: "${ENV_FILE:=$LL_ETC/vllm.env}"
: "${KEYS_FILE:=$LL_ETC/claves.env}"
: "${PERFIL:=$LL_STATE/perfil.conf}"

# ---------------------------------------------------------------- motor
# Imagen fijada por etiqueta Y digest: la etiqueta se lee, el digest es el que manda.
# Verificado con descarga anonima del registro publico el 2026-07-26.
: "${VLLM_VERSION:=v0.26.0}"
: "${VLLM_IMAGE:=vllm/vllm-openai@sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52}"
: "${MODEL_ID:=nvidia/Qwen3.6-35B-A3B-NVFP4}"
: "${SERVED_NAME:=claude-qwen-local}"

: "${TP_SIZE:=2}"                          # tensor parallel — ligado a EXIGE_GPUS
: "${MAX_MODEL_LEN:=262144}"
: "${MAX_NUM_SEQS:=16}"                    # 256 (defecto de vLLM) impide arrancar: bloques Mamba
: "${GPU_MEM_UTIL:=0.90}"
: "${MOE_BACKEND:=marlin}"

# ---------------------------------------------------------------- puertos (todo en loopback)
: "${PORT_MOTOR:=8000}"                    # vLLM — solo lo habla el medidor
: "${PORT_MEDIDOR:=8001}"                  # medidor — aqui apuntan TODOS los clientes
: "${PORT_PUENTE:=8787}"                   # puente Anthropic <-> OpenAI
: "${BIND_ADDR:=127.0.0.1}"

# ---------------------------------------------------------------- usuarios
: "${N_HERMES:=4}"                         # 4 puestos de agente + el alumno = 5

# ---------------------------------------------------------------- la puerta (umbrales)
#
# TRAMPA DE UNIDADES, leer antes de tocar estos numeros: `nvidia-smi` informa la VRAM
# en MiB y una tarjeta "de 16 GB" declara 16311 MiB, que son 15,93 GiB — NO 16384.
# Poner el umbral en GiB haria que la puerta rechazase la maquina de la que salio este
# montaje. Los umbrales van en MiB, tal cual los informa nvidia-smi.
: "${EXIGE_GPUS:=2}"                       # exactamente 2 — es la topologia de TP=2
: "${MIN_VRAM_POR_GPU_MIB:=16000}"         # 16311 pasa · 12288 (12 GB) no
: "${MIN_VRAM_TOTAL_MIB:=32000}"           # 2x16311 = 32622 pasa
: "${MIN_COMPUTE:=10.0}"                   # NVFP4 existe desde Blackwell (sm_100 / sm_120)

# Disco. Medido en la maquina de referencia, con estos comandos exactos:
#   du -sh /srv/models/hf   -> 22 GB   (pesos + cache del modelo)
#   docker image ls         -> 28,1 GB (imagen YA EXTRAIDA en disco)
# Ojo: `docker image inspect --format '{{.Size}}'` devuelve otra cifra segun la
# metrica, y el registro publica el tamanio COMPRIMIDO, mas pequenio. La que importa
# para el disco del alumno es la extraida, que es la que informa `docker image ls`.
: "${MIN_DISCO_MODELOS_GB:=30}"            # 22 medidos + margen de descarga temporal
: "${MIN_DISCO_DOCKER_GB:=40}"             # 28,1 medidos + margen de actualizacion
: "${MIN_DISCO_GB:=70}"                    # exigido cuando ambos comparten sistema de ficheros

# ---------------------------------------------------------------- muestreo
# Perfil oficial de Qwen por modo. El puente los aplica; aqui se documentan para que
# el alumno vea de un vistazo con que numeros corre su maquina.
: "${FAST_TEMP:=0.7}";  : "${FAST_TOP_P:=0.80}"; : "${FAST_TOP_K:=20}"; : "${FAST_PRES:=1.5}"
: "${THINK_TEMP:=0.6}"; : "${THINK_TOP_P:=0.95}"; : "${THINK_TOP_K:=20}"; : "${THINK_PRES:=0.0}"
: "${THINK_MIN_TOKENS:=6000}"              # por debajo, el razonamiento se agota dentro
                                           # del <think> y no sale respuesta

# ---------------------------------------------------------------- GPU
: "${POWER_LIMIT_W:=150}"                  # volatil: se pierde en cada reinicio, por eso
                                           # va en su propia unidad systemd
: "${APLICAR_POWER_LIMIT:=si}"

# ---------------------------------------------------------------- alias
: "${LOCAL_MODEL_ID:=qwen3.6-35b-local}"   # alias corto en /model: qwen
: "${LOCAL_THINK_MODEL_ID:=qwen3.6-35b-local-think}"  # alias corto: qwent
