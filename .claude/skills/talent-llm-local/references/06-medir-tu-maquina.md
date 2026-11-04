# 06 · Medir tu maquina

## Table of Contents

- [1. Por que tienes que medir tu](#1-por-que-tienes-que-medir-tu)
- [2. Correr el banco](#2-correr-el-banco)
- [3. Las cifras y como leerlas](#3-las-cifras-y-como-leerlas)
- [4. Lectura frente a escritura: la asimetria que cambia como trabajas](#4-lectura-frente-a-escritura-la-asimetria-que-cambia-como-trabajas)
- [5. Si tus numeros son peores de lo que deberian](#5-si-tus-numeros-son-peores-de-lo-que-deberian)
- [6. Medir sin enganiarte](#6-medir-sin-enganiarte)
- [7. Medir la calidad, no solo la velocidad](#7-medir-la-calidad-no-solo-la-velocidad)

---

## 1. Por que tienes que medir tu

Todas las cifras de este skill salen de **una** maquina: dos RTX 5060 Ti conectadas a
PCIe de cuarta generacion, una por lineas del procesador y otra por el chipset.

Otro par de tarjetas Blackwell de 16 GB pasa la puerta con todo el derecho y puede dar
numeros distintos: mas rapidas o mas lentas, y con otro comportamiento termico. La puerta
autoriza **compatibilidad**, no promete **rendimiento**.

Asi que el numero que vale para ti es el que salga de tu maquina.

## 2. Correr el banco

```bash
bash scripts/banco.sh
```

Tarda unos minutos y guarda el resultado en `~/llm-local/banco-<fecha>.txt`.

Lo primero que hace es una tirada de calentamiento **que descarta**: la primera peticion
tras arrancar el motor va a unos 18 tok/s porque esta compilando los grafos de calculo.
Medir ahi es medir el arranque, no la maquina.

## 3. Las cifras y como leerlas

```text
1 cliente          131.4 tok/s
5 clientes         358.7 tok/s agregados (~71.7 cada uno)

lectura de contexto (texto unico, tokens reales del servidor):
     4k   5381 tok/s  (3928 tok en 0.73s)
    32k   4952 tok/s  (31839 tok en 6.43s)
   100k   3635 tok/s  (99333 tok en 27.33s)
cache de prefijo   100k en frio 27.33s · +1 turno nuevo 1.32s  (20x)
```

| Cifra | Que significa | Referencia (2× RTX 5060 Ti) |
|---|---|---|
| **1 cliente** | Lo rapido que escribe cuando esta solo. Es lo que notas tecleando | 127-135 tok/s |
| **5 clientes** | Lo que de verdad importa si vas a tener agentes trabajando | ~359 agregados · ~72 cada uno |
| **Lectura de contexto** | Lo rapido que **lee** lo que le das antes de empezar a escribir. **No es una cifra, es una curva**: se degrada al crecer el contexto porque el coste de la atencion es cuadratico | 5.873 tok/s a 4k · 4.860 a 32k · 3.682 a 100k · 2.997 a 160k |
| **Cache de prefijo** | Cuanto ahorra reenviar una conversacion que el motor ya leyo: **solo se paga lo nuevo de cada turno**, no el total | 100k en frio ~27 s → con un turno nuevo de 2k, **1,3 s (20×)**; con turnos de 5k, 2,2 s (12×) |

La curva de lectura tiene una consecuencia directa: la espera hasta el primer token de una
peticion **en frio** crece mas que linealmente. Medido: 0,7 s a 4k · 6,6 s a 32k · 26,9 s
a 100k · 53,4 s a 160k. Lo que hace vivible trabajar con contextos grandes no es la
velocidad de lectura: es el cache de prefijo, que convierte esos ~27 s en 1-2.

La segunda es la que justifica todo el montaje. Si los cinco clientes dieran ~26 tok/s
cada uno (un quinto de la cifra en solitario), el servidor estaria serializando y sobraria
la mitad de la configuracion. Que den ~72 significa que estan compartiendo el mismo paso
de calculo.

Comprobacion rapida: **agregado ÷ solitario** deberia estar entre 2,5 y 3. Si sale
cercano a 1, algo serializa.

## 4. Lectura frente a escritura: la asimetria que cambia como trabajas

Fijate en la diferencia: **miles de tok/s leyendo frente a ~130 escribiendo**. El factor
exacto depende del tamanio — de unas 45 veces con contextos de 4k a unas 28 con 100k,
porque la lectura se degrada con el contexto y la escritura no — pero el orden de
magnitud se mantiene: leer es decenas de veces mas barato que escribir.

Eso no es un detalle tecnico, es una forma de trabajar. En una sesion real de trabajo
medida aqui salieron **39,7 millones de tokens de entrada frente a 605.000 de salida** —
una proporcion de 66 a 1. Casi todo el trabajo es leer.

Consecuencias practicas:

- **Dale contexto sin miedo.** Pegar un fichero entero cuesta casi nada comparado con la
  respuesta que va a escribir. Resumir a mano para «ahorrarle trabajo» suele salir peor.
- **Lo que duele es que escriba de mas.** De ahi que el modo pensante sea caro: solo
  infla la parte lenta.
- **El cache de prefijo importa mucho** con agentes, y ahora con numero propio: una
  conversacion de 100k reenviada entera tarda **2,2 s** hasta el primer token en vez de
  los **26,9 s** del frio (12×). Y lo mejor es la forma: al crecer la conversacion de 25k
  a 100k, la espera se queda casi plana (1,4 → 2,2 s), porque solo se paga lo NUEVO de
  cada turno, no el total. Ojo: el cache es **compartido** entre los 5 usuarios y se
  puede perder — el detalle esta en `05-cinco-usuarios-y-hermes.md` §5.

## 5. Si tus numeros son peores de lo que deberian

Con el mismo hardware que la referencia, en este orden:

```bash
# 1. ¿estan las tarjetas limitadas y frescas?
nvidia-smi --query-gpu=index,enforced.power.limit,temperature.gpu,clocks.max.sm --format=csv

# 2. ¿hay cola? (waiting sostenido > 0 = saturado, no lento)
curl -s localhost:8001/stats | python3 -m json.tool

# 3. ¿esta compartiendo las GPU con algo? un juego se lleva 8-12 GB
nvidia-smi

# 4. ¿que dice el propio motor?
docker logs --tail 40 vllm
```

| Sintoma | Causa habitual |
|---|---|
| Solitario bien, cinco clientes mal | `waiting > 0`: mas trabajo del que cabe. Es saturacion, no lentitud |
| Todo lento y las tarjetas calientes | Estrangulamiento termico. Mira la temperatura bajo carga |
| Una tarjeta a menos relojes que la otra | Asimetria: la lenta marca el ritmo de las dos. `systemctl restart nvidia-powerlimit` |
| Solo la primera peticion es lenta | Normal, es el calentamiento |
| Va lento solo cuando OTRO usuario esta trabajando | No es tu maquina: es la cola detras de la peticion del vecino (medido: 250× si el esta leyendo un contexto grande) y/o tu prefijo desalojado del cache compartido. Ver `05-cinco-usuarios-y-hermes.md` §5 |
| Todo mucho peor de golpe | ¿Cambiaste la imagen? Por eso va fijada por digest |

Una nota sobre temperatura: si la maquina esta en un sitio cerrado o con poco aire, las
tarjetas se estrangulan solas y no hay ajuste que lo arregle. Se ve en
`temperature.gpu` bajo carga sostenida.

## 6. Medir sin enganiarte

Tres trampas que nos costaron mediciones invalidas, para que no las repitas:

**1. Texto repetido mide el cache, no la maquina.** Un banco que manda 1.200 veces la
misma frase encuentra el prefijo ya calculado y devuelve una cifra inflada que no
volveras a ver en uso real. El contenido de cada peticion de un banco tiene que ser
**unico** (aleatorio vale). La verificacion honesta es leer los contadores del motor:
`vllm:prefix_cache_hits_total` en `/metrics` no debe moverse durante el banco. En el
nuestro: 0 aciertos en 755.000 consultas — solo entonces la curva de lectura es real.

**2. Una maquina «que no esta usando nadie» casi nunca esta ociosa.** Nos paso: un banco
salio con dos turnos absurdos (75 s donde tocaban 2) porque una sesion real seguia
mandando peticiones por el puente. Antes de medir, exige silencio y compruebalo — motor
sin peticiones en curso (`Running: 0` en los logs) y un rato sin trafico —, y al terminar
verifica que nadie entro durante la ventana. Si hubo trafico ajeno, los numeros no valen:
repite. La regla de oro: **el veredicto de limpieza lo da un check, no tu buen ojo.**

**3. No des explicaciones que no has comprobado.** Tuvimos una lectura rara (la latencia
a 1k oscila entre ~0,4 y ~0,7 s sin patron) y la primera explicacion — «las GPU estan
subiendo relojes» — sono tan razonable que casi se queda escrita. Al medirla era falsa:
los relojes suben en la segunda peticion y la oscilacion sigue con las frecuencias al
maximo. Sigue **sin explicar**, y asi se dice. Impacto practico: decimas en peticiones
cortas, ninguna conclusion depende de ello. Una anomalia anotada como «no explicada» vale
mas que una explicacion bonita sin datos.

## 7. Medir la calidad, no solo la velocidad

Los tokens por segundo no dicen si las respuestas sirven. Para eso hay dos bancos mas, y
lo importante de ellos es el **metodo**, que puedes copiar para lo que tu hagas:

**Compara los dos modos en tareas con respuesta verificable.** No «¿cual me gusta mas?»,
sino tareas donde un script pueda decir si acerto. Asi es como salio que en 7 de 12
tareas empatan y en esas el modo pensante es desperdicio puro.

**Prueba con ciclo de correccion, no solo en frio.** Es la diferencia entre «este modelo
saca 19 de 24» y «saca 21 de 24 si le devuelves el error». La segunda es la que describe
como vas a trabajar de verdad, y fue la que revelo el hallazgo mas util de todos:

> Una sola ronda de correccion iguala al modo pensante, a **1/19** del coste en tokens.
> Revisar es una palanca mucho mas barata que razonar.

**Y verifica tu verificador antes de acusar al modelo.** Aqui paso: un test esperaba 8
cuando la respuesta correcta era 9. El modelo acertaba y se le estaba puntuando mal.
Antes de concluir que el modelo falla, comprueba que el que juzga tiene razon.

Los dos bancos completos estan descritos en `03-modelo-y-muestreo.md` §4, con sus tablas
de resultados.
