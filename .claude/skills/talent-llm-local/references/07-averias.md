# 07 · Averias: sintoma, causa, arreglo

## Table of Contents

- [1. Como usar esta pagina](#1-como-usar-esta-pagina)
- [2. El motor no arranca](#2-el-motor-no-arranca)
- [3. Errores de autenticacion](#3-errores-de-autenticacion)
- [4. Claude Code y el puente](#4-claude-code-y-el-puente)
- [5. Rendimiento y GPU](#5-rendimiento-y-gpu)
- [6. Instalacion y scripts](#6-instalacion-y-scripts)
- [7. Cuando nada de esto encaja](#7-cuando-nada-de-esto-encaja)

---

## 1. Como usar esta pagina

Todo lo que hay aqui **nos ha pasado de verdad** montando esto. No es una lista de cosas
que podrian fallar: es la lista de las que fallaron, con lo que costo entender cada una.

Empieza siempre por lo mismo:

```bash
bash scripts/verificar.sh    # te dice que esta mal Y que comando lo arregla
```

Si eso no basta, busca tu sintoma abajo.

## 2. El motor no arranca

### Arranca y se cae en bucle, sin mensaje claro

**Causa mas probable:** `--max-num-seqs` demasiado alto. El valor por defecto de vLLM
(256) **impide arrancar** con este modelo por los bloques Mamba de sus capas lineales.

```bash
grep max-num-seqs /etc/systemd/system/vllm.service    # tiene que poner 16
```

No es un ajuste de rendimiento que se pueda subir «un poco»: sin el no hay servidor.

### `cannot set both Count and DeviceIDs`

**Causa:** la unidad lleva `--gpus '"device=0,1"'`. Esa forma no sobrevive al parseo de
`ExecStart`.

**Arreglo:** `--gpus all`. Si tienes otras tarjetas NVIDIA que no quieres usar, limita
con `CUDA_VISIBLE_DEVICES` en el fichero de entorno, no en la linea de Docker.

### Se queda parado dos o tres minutos al arrancar

**No esta colgado.** Esta compilando los grafos de calculo. Solo pasa en el primer
arranque tras cambiar la configuracion.

```bash
journalctl -u vllm -f     # veras el progreso
```

### Falta de memoria al cargar

**Causas, por probabilidad:**

1. Hay otra cosa usando las GPU. Un juego se lleva 8-12 GB. `nvidia-smi` lo muestra.
2. Alguien subio `--gpu-memory-utilization` por encima de 0.90.
3. Quedo un contenedor viejo vivo: `docker rm -f vllm`.

### Cuelgue al arrancar en multi-GPU, sin error

**Causa:** la libreria de comunicacion intentando acceso directo entre tarjetas que no
existe.

```bash
nvidia-smi topo -p2p rw        # CNS = no hay acceso directo
grep NCCL_P2P /etc/llm-local/vllm.env    # tiene que estar en 1
```

Deben estar los tres: `NCCL_P2P_DISABLE=1`, `NCCL_IB_DISABLE=1` y
`--disable-custom-all-reduce`.

### La segunda GPU ha desaparecido

**Causa fisica, no de software:** en muchas placas el tercer conector M.2 comparte lineas
con la segunda ranura PCIe. Poner un disco ahi apaga la tarjeta.

```bash
nvidia-smi -L    # ¿salen las dos?
```

## 3. Errores de autenticacion

### Todas las claves dan 401 de golpe

Quien autentica es el **medidor**, y lee las claves de `ALIAS_MAP` en
`/etc/llm-local/claves.env`. Si esa variable falta o llega vacia, el medidor **cierra**
(no se abre: fail-closed) y rechaza todo.

```bash
sudo grep -c '^ALIAS_MAP=' /etc/llm-local/claves.env    # tiene que ser 1
sudo systemctl restart llm-meter
journalctl -u llm-meter -n 30 --no-pager
```

### Una clave concreta da 401 y las demas no

Esa clave no esta en `ALIAS_MAP`. Suele pasar tras editar el fichero a mano. Lo mas
limpio es regenerar todo:

```bash
sudo rm /etc/llm-local/claves.env
sudo bash scripts/montar.sh --from claves
```

### El motor devuelve 401 al medidor (`corriendo/esperando` salen a -1)

El medidor habla con el motor usando `UPSTREAM_KEY`, que sale de
`/etc/llm-local/vllm.env`. Si los dos no coinciden, el proxy no pasa nada:

```bash
sudo systemctl restart llm-meter    # relee el fichero
```

### El medidor acepta cualquier clave

No deberia. `verificar.sh` lo comprueba probando una inventada: que rechace lo que debe
rechazar es la mitad de la prueba. Si pasa, mira `ALIAS_MAP` y reinicia el medidor.

### Si algun dia pones `--api-key` a mano

Va **una sola vez** con todas las claves detras. Repetir el flag hace que la ultima pise
a las demas — vLLM avisa con «Found duplicate keys» entre el ruido del arranque, y como
una si funciona el fallo parece intermitente y se busca donde no es.

```ini
# MAL
--api-key sk-a --api-key sk-b --api-key sk-c
# BIEN
--api-key sk-a sk-b sk-c
```

### El medidor no muestra a nadie / faltan usuarios

Alguien esta apuntando al motor (`:8000`) en vez de al medidor (`:8001`). **No da ningun
error**: simplemente ese consumo desaparece del reparto.

```bash
grep -r 8000 ~/.hermes/profiles/ /etc/systemd/system/llm-bridge.service
# todo esto deberia apuntar a 8001
```

## 4. Claude Code y el puente

### Error 400 en el segundo mensaje; el primero fue bien

**Causa:** Claude Code manda mensajes con rol de sistema **a mitad** de conversacion, y la
plantilla del modelo solo los acepta en la primera posicion. El primer turno funciona, lo
que despista mucho.

Ademas, la recuperacion automatica de Claude Code no salta, porque busca el texto de
error de Anthropic y este lo emite vLLM con otras palabras.

**Arreglo:** el puente degrada esos mensajes a turno de usuario. Si te pasa, tienes una
version antigua: `sudo bash scripts/montar.sh --only puente`.

### La sesion se atasca y hasta `/compact` falla

**El peor de todos**, porque lo que te sacaria del atasco falla por lo mismo:

```text
400 maximum context length is 131072 … requested 32000 output tokens
    and your prompt contains at least 99073 input tokens
```

Claude Code no conoce la ventana del modelo local y pide un presupuesto de salida fijo.
Cuando el contexto se llena, se pasa **por un token** — y `/compact` pide el mismo
presupuesto, asi que tampoco cabe. Sesion sin salida.

**Salida inmediata:** `/model opus`, compacta alli, vuelve a `qwen`.

**Arreglo de fondo:** el puente cuenta la entrada real y recorta el presupuesto de salida
al hueco que queda. Y `--max-model-len` esta en **262144**, no en 131072, precisamente
para tener margen.

> Leccion que vale mas que el arreglo: la primera version de ese recorte tenia un suelo de
> seguridad de 1.024 tokens escrito como `max(suelo, hueco)`, y ese suelo **se saltaba el
> recorte**. Con el contexto casi lleno el hueco real eran 511 y se pedian 1.024: mismo
> desbordamiento, ahora causado por la salvaguarda. **Un suelo que puede superar al techo
> no protege de nada.**

### `qwent` gasta tokens y responde vacio

Dos causas distintas, un solo sintoma:

1. **Presupuesto de salida corto.** El razonamiento se come el hueco y termina sin
   escribir respuesta. El puente sube el minimo a 6.000 por esto.
2. **Campo de razonamiento mal leido.** vLLM lo renombro de `reasoning_content` a
   `reasoning` en la 0.26. El puente lee los dos.

Como distinguirlas: si pasa **siempre**, es la segunda; si pasa solo con respuestas
cortas, es la primera.

### El modelo local no aparece en `/model`

Claude Code lee el entorno **al arrancar**. Abre una sesion nueva. La entrada aparece al
**final** del selector.

### `qwent` no sale en el selector

Correcto: Claude Code admite un unico modelo propio en la lista. `qwent` existe igual, se
teclea: `/model qwent`.

### Los modelos de Anthropic dan 401

**El unico error de esta pagina con consecuencia real fuera de tu maquina.** Hay una
credencial de pasarela en `settings.json`:

```bash
grep -E 'ANTHROPIC_(AUTH_TOKEN|API_KEY)' ~/.claude/settings.json
```

Si aparece alguna, **quitala**: anula tu suscripcion. El montaje funciona con **solo**
`ANTHROPIC_BASE_URL`.

### El indicador de contexto de la barra no se mueve

El servidor solo informa del consumo **al final** del stream, y Claude Code lo lee al
principio. El puente estima al abrir y corrige con el dato real al cerrar. Si no se
mueve, tienes una version antigua del puente.

## 5. Rendimiento y GPU

### Todo mas lento de lo esperado, con el mismo hardware

```bash
nvidia-smi --query-gpu=index,enforced.power.limit,temperature.gpu,clocks.max.sm --format=csv
```

- **Limite de potencia distinto entre tarjetas** → una marca el ritmo de las dos.
- **Temperatura alta sostenida** → estrangulamiento termico. Es de ventilacion, no de
  configuracion.
- **Relojes maximos distintos** → `sudo systemctl restart nvidia-powerlimit`.

### El limite de potencia no queda aplicado tras reiniciar

Es **volatil** por naturaleza. Tiene que estar la unidad:

```bash
systemctl is-enabled nvidia-powerlimit    # enabled
systemctl status nvidia-powerlimit
```

Una version antigua de este ajuste, en la maquina de referencia, aplicaba **198 W y
overclock a una sola tarjeta** porque el numero que se le pasaba eran megahercios y no
vatios, y solo tocaba el indice 0. Estuvo meses asi sin que nadie lo notara. Por eso el
script actual verifica despues, exige simetria y **falla ruidosamente**.

### La primera peticion tras arrancar va a 18 tok/s

Normal. Es calentamiento de los grafos. `banco.sh` la descarta a proposito.

## 6. Instalacion y scripts

### La sonda dice que no encuentra `nvidia-smi` y si esta

**Rutas con espacios.** Si el directorio del skill tiene espacios y algun script hace
`${VARIABLE%% *}` para quedarse con el nombre del programa, la ruta se parte por la mitad.

Nos paso montando esto: `/home/usuario/Mis Documentos/…` se convertia en `/home/usuario/Mis`.
La sonda actual no trocea la variable.

### `montar.sh` pide administrador con `--dry-run`

No deberia: `--dry-run` no toca nada y ese es justo el sentido de poder mirarlo antes de
dar permisos. Si te lo pide, tienes una version antigua.

### Correr el montaje dos veces, ¿duplica algo?

No, y esta probado. Las unidades se reescriben, las claves **se conservan** (no rotan
solas), los perfiles de agente se reescriben y el bloque de `settings.json` se sustituye,
no se anade otra vez.

### Quiero quitarlo todo

```bash
sudo bash scripts/desmontar.sh              # servicios y configuracion
sudo bash scripts/desmontar.sh --con-pesos  # ademas los 22 GB de pesos
```

Quita **solo** lo que instalo el skill. De `settings.json` retira exactamente las claves
que anadio, anotadas al instalar: el resto de tus preferencias se queda. Tu historico de
consumo tampoco se toca.

### `hermes` muere si le paso texto por una tuberia

Sin `-Q -q` abre la interfaz interactiva y muere al no encontrar terminal. Para scripts:
`hermes-1 chat -Q -q "..."`.

## 7. Cuando nada de esto encaja

En este orden:

```bash
bash scripts/verificar.sh                 # el diagnostico completo
journalctl -u vllm -n 100 --no-pager      # el motor
journalctl -u llm-bridge -n 100 --no-pager  # el puente
journalctl -u llm-meter -n 50 --no-pager    # el medidor
docker logs --tail 50 vllm                # lo que dice vLLM por dentro
cat ~/llm-local/perfil.conf               # tu maquina, sin secretos: se puede compartir
```

`perfil.conf` esta pensado exactamente para esto: no lleva claves ni nada con lo que
reconstruirlas, asi que puedes pegarlo entero al pedir ayuda sin tener que revisarlo
antes.
# Uso personal fuera de la fábrica

Las órdenes interactivas para volver del modelo local las teclea el alumno en su propio CLI.
El alias de familia es la orden real de ese CLI personal; queda fuera de la doctrina de modelos
de la fábrica, cuyos roles consumen exclusivamente los identificadores completos del registro.
