# 03 · El modelo, los dos alias y el muestreo

## Table of Contents

- [1. Que modelo es y por que este](#1-que-modelo-es-y-por-que-este)
- [2. Un modelo cargado, dos alias](#2-un-modelo-cargado-dos-alias)
- [3. Los parametros de muestreo, exactos](#3-los-parametros-de-muestreo-exactos)
- [4. Cuando qwen y cuando qwent: los datos](#4-cuando-qwen-y-cuando-qwent-los-datos)
- [5. El reparto de papeles que salio de usarlo](#5-el-reparto-de-papeles-que-salio-de-usarlo)
- [6. Dos detalles del modo pensante que cuestan caros](#6-dos-detalles-del-modo-pensante-que-cuestan-caros)
- [7. Que NO esperes de el](#7-que-no-esperes-de-el)

---

## 1. Que modelo es y por que este

`nvidia/Qwen3.6-35B-A3B-NVFP4` — 35.000 millones de parametros de los que solo se activan
unos 3.000 millones en cada token (arquitectura de expertos). Traduccion practica:
**calidad de modelo grande al coste de calculo de uno pequenio**.

Dos propiedades importan para que quepa:

| Propiedad | Consecuencia |
|---|---|
| Cuantizacion **NVFP4** | 21,82 GiB de pesos. En FP8 serian 34,89 GiB: no cabrian |
| 30 de sus 40 capas son de atencion lineal | El cache de contexto cuesta **20 KiB por token**, unas 4 veces menos que un modelo convencional. Por eso caben 333.000 tokens de contexto en lo que sobra |

Y por eso la puerta exige Blackwell: NVFP4 no existe en tarjetas anteriores. No es que
vaya mas lento — es que no arranca.

## 2. Un modelo cargado, dos alias

El razonamiento no es otro modelo: es el **mismo**, con el modo de pensar encendido. Asi
que los dos alias comparten los mismos pesos en memoria y **no cuestan un byte extra de
VRAM**. Se cambia de uno a otro en caliente.

| Escribes | Razonamiento | Para que |
|---|---|---|
| `/model qwen` | apagado | Trabajo normal, escribir codigo, herramientas. **El de todos los dias** |
| `/model qwent` | encendido | Depurar un fallo, matematicas, cualquier cosa con pasos intermedios |

En el selector de `/model` solo aparece una entrada (Claude Code admite un unico modelo
propio). `qwent` se teclea directamente: `/model qwent` y ya.

```text
   /model qwen  ─┐
                 ├──► puente ──► el MISMO modelo cargado ──► responde
   /model qwent ─┘        │
                          └── decide: ¿enciendo el modo de pensar?
                              ¿que parametros de muestreo aplico?
```

## 3. Los parametros de muestreo, exactos

Qwen publica parametros **distintos por modo**, y no usarlos degrada el resultado sin que
lo parezca. El puente los aplica solo:

| | `temperature` | `top_p` | `top_k` | `presence_penalty` |
|---|---|---|---|---|
| **qwen** (rapido) | 0.7 | **0.80** | 20 | **1.5** |
| **qwent** (pensante) | 0.6 | 0.95 | 20 | **0.0** |

Cuidado con una confusion que circula por ahi: el perfil pensante **general** lleva
`presence_penalty` 1.5, pero el de **codigo preciso** lleva 0.0. Son dos filas distintas
de la misma ficha, no una contradiccion. Aqui se usa el de codigo, porque el puente sirve
a Claude Code.

Ademas, en el modo pensante el puente:

- Eleva el minimo de salida a **6.000 tokens**. Con presupuestos cortos el razonamiento
  se agota dentro del bloque y **no sale respuesta**: tokens gastados, pantalla vacia.
- Activa **`preserve_thinking`** y devuelve el razonamiento historico en el siguiente
  turno. Sin ese ida y vuelta, cada mensaje nuevo borra los razonamientos previos, el
  prefijo de la conversacion cambia y hay que releerla entera.

Comprobado con el contador del propio servidor: con `preserve_thinking` el razonamiento
historico se renderiza; sin el, se descarta.

## 4. Cuando qwen y cuando qwent: los datos

### Banco de 12 tareas con respuesta verificable

| Tarea | qwen | qwent |
|---|---|---|
| Aritmetica de varios pasos | **0/5** | 4/5 |
| Logica (cajas mal etiquetadas) | **0/5** | 5/5 |
| Contar letras | **0/5** | 5/5 |
| Descuento + impuesto | **0/5** | 5/5 |
| Seguir un formato estricto | **1/5** | 5/5 |
| Codigo, JSON, resumen, orden, factual (7 tareas) | 3/3 | 3/3 |
| **Total** | **21/36** | **32/36** |
| **Coste** | **188 tok · 3,0 s** | **14.751 tok · 123,6 s** |

Dos lecturas que importan:

- En razonamiento el rapido no saca «un poco menos»: saca **cero**. No es cuestion de
  insistir con el prompt.
- En **7 de 12 tareas empatan**. Ahi el modo pensante es desperdicio puro: 78 veces mas
  tokens para el mismo resultado. El criterio no es «tarea dificil» sino **«¿hacen falta
  pasos intermedios?»**.

### Banco de programacion, con ciclo de correccion

8 tareas con trampa × 3 repeticiones. Al fallo se le devuelve el mensaje exacto del test
y se pide arreglo, hasta 2 rondas:

| | en frio | tras 1 ronda | tokens | tiempo | regresiones |
|---|---|---|---|---|---|
| **qwen** | 19/24 | **21/24** | **6.900** | **76 s** | **0** |
| **qwent** | **21/24** | 21/24 | 131.228 | 1.180 s | 3 |

> **El pensante es mejor en frio, pero una sola ronda de correccion iguala al rapido — a
> 1/19 del coste en tokens y 1/15 del tiempo.**

Es el hallazgo mas util de todo el banco: **revisar es una palanca mucho mas barata que
razonar**. Y valida el esquema de trabajo: que el modelo local ejecute y que la revision
venga de fuera.

Detalle incomodo del pensante: **fallo dos veces en producir codigo usable** — no definio
la funcion que se le pedia, pese a un «sin explicaciones» explicito. Razonar mas le hizo
seguir peor las instrucciones.

### Y con cinco usuarios

Misma pregunta de razonamiento lanzada por los 5 clientes a la vez:
**rapido 1,0 s de reloj · pensante 61,1 s.** Poner a todos en modo pensante colapsa la
maquina. `qwen` es el modo por defecto por esto tambien.

## 5. El reparto de papeles que salio de usarlo

Esto no sale del banco sino de un dia construyendo una aplicacion de verdad con el:

| | `qwen` (rapido) | `qwent` (pensante) |
|---|---|---|
| Escribir codigo nuevo desde un plan | rapidisimo | lento y caro, sin ventaja |
| Diagnosticar un fallo **ya reportado** | no lo intenta | **acerto 2 de 2** desde el sintoma solo |
| Verificar su propio trabajo | **no verifica** | no observado |
| Fidelidad al plan | transcribe los defectos, y ademas se salta partes buenas | — |
| Encontrar lo que nadie ha reportado | no | **tampoco** |

De ahi salen tres reglas practicas:

1. **Escribir codigo nuevo → `qwen`.** Es donde el coste importa y donde el pensante no
   aporta.
2. **Depurar algo que ya falla → `qwent`.** Es su punto fuerte medido.
3. **Encontrar defectos que nadie ha reportado → ninguno de los dos.** Tiene que ser
   externo.

La prueba del punto 3 es fea y por eso vale: en un experimento controlado, `qwent`
escribio el plan, `qwen` lo ejecuto, y un fallo de seguridad **entro en el plan y salio
intacto en el codigo**. El razonamiento extra no lo evito en ninguna de las dos fases.
Hay una categoria entera de defectos que solo aparece si alguien los busca a proposito.

## 6. Dos detalles del modo pensante que cuestan caros

**Presupuesto de salida corto = respuesta vacia.** No falla con un error: gasta los
tokens dentro del bloque de razonamiento y termina sin haber escrito nada. Por eso el
minimo de 6.000. Si ves respuestas vacias en `qwent`, mira eso primero.

**El campo del razonamiento cambio de nombre.** Desde vLLM 0.26 llega en `reasoning`;
antes era `reasoning_content`. El puente lee los dos, precisamente porque el sintoma de
leerlo mal es *identico* al del parrafo anterior: tokens consumidos, bloque vacio. Dos
causas distintas, un solo sintoma.

## 7. Que NO esperes de el

Es un modelo local de tamanio medio en hardware de consumo. El marco correcto para
juzgarlo es «cual es su envoltura de trabajo», no «mira, otro fallo». Con eso dicho, tres
cosas medidas que conviene tener presentes:

**No comprueba su trabajo.** Te dira que termino cuando no ha terminado. No por mentir:
porque no vuelve a mirar. En una sesion real declaro «todo funciona» tres veces sin
serlo. Si algo importa, **lo verificas tu o lo verifica un script**.

**Encuentra lo que da error, no lo que esta mal.** Lo que falla ruidosamente lo arregla
muy bien. Lo que esta mal pero funciona —un fallo de seguridad, una promesa incumplida—
no lo vera jamas, porque nadie se lo pide.

**Los datos verificables hay que verificarlos.** Llego a afirmar que una peticion
devolvia «HTTP 370 con 0 elementos» cuando devolvia 200 con 146 — y el numero correcto
estaba en su propio documento tres parrafos mas abajo. No inventa por maldad: rellena
huecos con lo que suena plausible.

Y en positivo, tambien medido: en una tarde construyo una aplicacion de 11 ficheros, se
autocorrigio cinco veces sin ayuda al ver los errores reales, aplico nueve parches que
resultaron correctos al verificarlos uno a uno, y diagnostico una condicion de carrera
partiendo solo del sintoma. Para eso da.
