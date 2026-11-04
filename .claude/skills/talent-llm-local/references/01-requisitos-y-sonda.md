# 01 · Requisitos y la sonda

## Table of Contents

- [1. La sonda es una puerta, no un selector](#1-la-sonda-es-una-puerta-no-un-selector)
- [2. Los siete requisitos y de donde sale cada numero](#2-los-siete-requisitos-y-de-donde-sale-cada-numero)
- [3. La trampa de las unidades](#3-la-trampa-de-las-unidades)
- [4. Docker y el toolkit no son requisito: se instalan](#4-docker-y-el-toolkit-no-son-requisito-se-instalan)
- [5. Correrla y leer el veredicto](#5-correrla-y-leer-el-veredicto)
- [6. Probarla sin tener el hardware](#6-probarla-sin-tener-el-hardware)
- [7. Lo que queda fuera, y que haria falta](#7-lo-que-queda-fuera-y-que-haria-falta)
- [8. perfil.conf: el fichero que si puedes compartir](#8-perfilconf-el-fichero-que-si-puedes-compartir)

---

## 1. La sonda es una puerta, no un selector

Casi todos los instaladores de IA local hacen lo mismo: miran tu maquina y te montan
«lo mejor que te quepa». Este no.

Este montaje existe porque se **rodo** durante un dia entero: se midio, se rompio, se
arreglo y se volvio a medir. Lo que se sabe que funciona es **una** configuracion
concreta sobre **un** tipo de maquina. Cualquier variante seria una suposicion, y una
suposicion presentada como producto terminado es peor que un «no».

Asi que la sonda hace dos cosas y solo dos:

```text
   mide  ──►  ¿coincide con lo rodado?  ──►  si  ──►  AUTORIZA
                        │
                        no
                        │
                        └──►  RECHAZA, y dice exactamente que falta y cuanto
```

No hay tercera salida. Si tu equipo no llega, el montaje **para**.

## 2. Los siete requisitos y de donde sale cada numero

| Requisito | Umbral | Por que ese numero |
|---|---|---|
| Numero de tarjetas | **exactamente 2, identicas** | La configuracion es tensor parallel de tamanio 2. Con una sola no hay reparto posible; con cuatro u ocho la topologia es otra y no se ha probado |
| VRAM por tarjeta | **>= 16000 MiB** | Cada tarjeta carga su mitad. Medido en la maquina de referencia: 15,2 y 14,7 GiB |
| VRAM agregada | **>= 32000 MiB** | El montaje ocupa **29,9 GiB** en marcha. 32 GB es la unica capacidad en la que se ha visto funcionar; poner el umbral mas abajo seria extrapolar hacia el fallo |
| Capacidad de computo | **>= 10.0** | NVFP4 solo existe desde Blackwell. En tarjetas anteriores este modelo cuantizado no arranca, no es que vaya lento |
| Sistema | Linux con systemd | Las unidades que sobreviven al reinicio y el NVIDIA Container Toolkit |
| Distribucion | **Ubuntu** | El instalador da de alta los repositorios oficiales de Docker y de NVIDIA. Que exista `apt-get` no basta: lo rodado de extremo a extremo es Ubuntu |
| Disco libre | **>= 70 GB** | Medido: 22 GB de pesos + 28,1 GB de imagen extraida = ~50 GB, mas margen |

La huella de disco se midio con estos comandos exactos, para que cualquiera pueda
reproducirla:

```bash
du -sh /srv/models/hf     # 22G   — pesos y cache del modelo
docker image ls           # 28.1GB — imagen YA EXTRAIDA en disco
```

Ojo con la ultima: `docker image inspect --format '{{.Size}}'` devuelve otra cifra segun
la metrica, y el registro publica el tamanio **comprimido**, bastante mas pequenio. La
que importa para el disco es la extraida, que es la que informa `docker image ls`.

Si los pesos y la imagen viven en sistemas de ficheros distintos, la sonda pide 30 GB en
uno y 40 GB en el otro en vez de 70 en el mismo.

## 3. La trampa de las unidades

Una tarjeta que se vende «de 16 GB» declara **16311 MiB**, que son **15,93 GiB**. No
16384.

Esto no es una curiosidad: si los umbrales se escriben en GiB, la puerta rechaza la
maquina de la que salio este montaje. Por eso todos los umbrales de VRAM del skill van
en **MiB, tal cual los informa `nvidia-smi`**, y estan comentados como tales en
`scripts/00-config.sh`.

```bash
nvidia-smi --query-gpu=name,memory.total --format=csv
# NVIDIA GeForce RTX 5060 Ti, 16311 MiB   <- no 16384
```

## 4. Docker y el toolkit no son requisito: se instalan

La sonda **detecta** Docker y el NVIDIA Container Toolkit, pero no los usa como motivo de
rechazo. Si faltan, la fase `requisitos` de `montar.sh` los instala desde sus
repositorios oficiales, pidiendo confirmacion antes.

Lo que si hace falta que ya este es el **driver propietario de NVIDIA**: sin `nvidia-smi`
no hay nada que medir.

Y por eso la puerta exige **Ubuntu**, no solo «una distribucion con apt»: el instalador
da de alta repositorios concretos, y autorizar algo que luego no sabe preparar seria un
falso positivo de compatibilidad. El origen de Docker se deriva de tu `/etc/os-release`
(no se da por supuesto), asi que si aceptas el riesgo a sabiendas puedes forzar la puerta:

```bash
LL_DISTRO_ID=ubuntu bash scripts/sonda.sh    # bajo tu responsabilidad: sin rodar
```

Ademas, la fase de requisitos no se conforma con que los paquetes esten instalados:
comprueba que un contenedor **ve** las tarjetas. Que `nvidia-ctk` exista no demuestra que
el runtime funcione.

## 5. Correrla y leer el veredicto

```bash
bash scripts/sonda.sh          # no cambia nada y no necesita administrador
bash scripts/sonda.sh --json   # lo mismo, para consumir desde un script
```

Autorizada:

```text
  Sistema      Linux (Ubuntu 26.04)
  GPU          2 x NVIDIA GeForce RTX 5060 Ti
  VRAM         32622 MiB en total · 16311 MiB la mas pequenia
  Computo      12.0 · driver 595.84
  Disco        635 GB libres (pesos) · 635 GB libres (imagen)

  OK   Tu maquina puede correr esta configuracion. Sigue con:  sudo bash montar.sh
```

Rechazada — se enumeran **todos** los motivos de golpe, no el primero que aparece:

```text
  FALLO Tu maquina no llega a esta configuracion. Motivos (2):

   · GPU: hay 1 tarjeta(s) y hacen falta exactamente 2. Esta configuracion es tensor
     parallel de tamanio 2: con otra cantidad seria otro montaje, y no lo hemos rodado.

   · GPU: capacidad de computo 8.9, y NVFP4 necesita 10.0 o superior (Blackwell).
```

## 6. Probarla sin tener el hardware

La puerta se ejercita entera con un `nvidia-smi` de mentira:

```bash
bash tests/probar-sonda.sh          # 20 casos, veredicto Y motivo
```

Cada caso comprueba dos cosas: que rechaza, y que rechaza **por el motivo correcto**. Un
rechazo por la razon equivocada es un fallo, no un aprobado con suerte.

Para un caso suelto:

```bash
FAKE_GPUS='RTX 4090|24564|8.9;RTX 4090|24564|8.9' \
  NVIDIA_SMI=tests/fake-nvidia-smi.sh bash scripts/sonda.sh
```

## 7. Lo que queda fuera, y que haria falta

Esto es **informacion, no promesa**: son configuraciones que nadie ha rodado aqui. Si te
metes en ellas, vas por tu cuenta.

| Caso | Que haria falta | Estado |
|---|---|---|
| Una sola GPU de 32 GB | `--tensor-parallel-size 1` y recalcular la reserva de memoria | Sin rodar |
| 4 u 8 GPU | Otro tamanio de tensor parallel; el numero de cabezas de atencion tiene que ser divisible | Sin rodar |
| Tarjetas distintas entre si | El reparto es simetrico: la pequenia marca el ritmo y la grande se desaprovecha | Desaconsejado |
| GPU anterior a Blackwell | Otro artefacto del modelo (AWQ o GPTQ). **Otro tamanio y otra huella**: no basta con «el mismo modelo en otro formato» | Sin rodar |
| Linux que no sea Ubuntu | El instalador ya deriva el origen de Docker de tu `/etc/os-release`, asi que Debian tiene bastantes papeletas de funcionar — pero no se ha probado de extremo a extremo. Forzable con `LL_DISTRO_ID=ubuntu` | Sin rodar |
| macOS / Windows | Otro motor entero; vLLM y el toolkit son de Linux | Fuera de alcance |

Si alguna de estas se rueda algun dia y se mide, entrara aqui con sus numeros. Hasta
entonces, la puerta sigue cerrada a proposito.

**Por que la puerta NO mira CPU, placa base ni PCIe.** No es un descuido: se midio. El
trafico entre las dos tarjetas en tensor parallel es constante por token (~320 KiB, dos
sincronizaciones por capa), y en el pico de lectura son **1,89 GB/s — el 24% del enlace
mas lento de la maquina de referencia**, que va a PCIe 4.0 x4 por el chipset. Ambas GPU
al 100% de uso durante todo el banco: nadie espera transferencias. La velocidad de esta
configuracion la fijan las tarjetas, no la placa — exigir una placa concreta rechazaria
maquinas perfectamente validas. Con las dos GPU en cualquier combinacion de ranuras
x16/x8/x4 de generacion 3 o mejor vas sobrado; solo revisa el manual de tu placa para la
trampa del M.2 que roba lineas (esta en `07-averias.md`).

## 8. perfil.conf: el fichero que si puedes compartir

Cada pasada de la sonda escribe `~/llm-local/perfil.conf` con lo que midio: modelo de
GPU, VRAM, capacidad de computo, driver, version de Docker, digest de la imagen y fecha.

**No lleva claves, ni tokens, ni nada con lo que reconstruirlos.** Esta pensado
justamente para poder pegarlo en una consulta o en un foro sin tener que revisarlo antes.

```bash
cat ~/llm-local/perfil.conf
```
