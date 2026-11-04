# 08 · Ya funciona, ¿y ahora que?

## Table of Contents

- [1. La idea que hay que entender primero](#1-la-idea-que-hay-que-entender-primero)
- [2. Las cuatro razones por las que local gana](#2-las-cuatro-razones-por-las-que-local-gana)
- [3. Ocho proyectos para empezar](#3-ocho-proyectos-para-empezar)
- [4. Las tres lecciones de usarla de verdad](#4-las-tres-lecciones-de-usarla-de-verdad)
- [5. Como saber cuanto te esta ahorrando](#5-como-saber-cuanto-te-esta-ahorrando)

---

## 1. La idea que hay que entender primero

Con una API pagas por cada palabra. Eso te hace **cuidadoso**: piensas el prompt, lo
lanzas una vez, aprovechas la respuesta. Es una forma de trabajar razonable y tambien una
jaula.

Con el modelo en tu maquina el coste marginal es **cero**. Y eso no significa «lo mismo
pero gratis»: significa que puedes ser **derrochador**, y ser derrochador es como se
aprende. Puedes lanzar la misma tarea con cincuenta prompts distintos para ver cual
funciona. Puedes dejar cuatro agentes trabajando toda la noche. Puedes procesar tus diez
mil fotos. Puedes equivocarte doscientas veces seguidas sin mirar el contador.

> **La pregunta correcta no es «¿que modelo es mejor?». Es «¿que haria yo si esto fuese
> gratis e ilimitado?».** Ahi es donde estan las cosas interesantes.

## 2. Las cuatro razones por las que local gana

| Razon | Que desbloquea |
|---|---|
| **Volumen** | Procesar miles de elementos. Por API costaria cientos de euros; aqui es una noche encendido |
| **Privacidad** | Datos que no deben salir: tus notas, tus clientes, tus fotos, contratos, historiales |
| **Siempre encendido** | Agentes corriendo sin contador. Un bot que vigila algo por ti para siempre |
| **Derroche** | Probar 50 variantes, reintentar sin miedo, dejar bucles largos. Experimentar de verdad |

Si un proyecto no encaja en ninguna de las cuatro, **probablemente lo mejor sea usar una
API**. Decirlo asi es mas honesto que vender que lo local sirve para todo.

## 3. Ocho proyectos para empezar

### 1 · El vigilante · *siempre encendido*

Un bot que mira algo por ti sin parar y te avisa solo cuando pasa algo: precios que bajan,
una web que cambia, tus registros de errores, una oferta de trabajo, un torneo que abre
inscripciones.

**Por que local:** vigilar es **muchas comprobaciones y pocas respuestas**. Por API pagas
cada comprobacion aunque no pase nada. Aqui, mirar cada minuto durante un anio no cuesta
mas que mirar una vez.

**Empieza por este.** Se entiende en dos minutos y el dia que salta el aviso engancha.

### 2 · Los cuatro agentes trabajando mientras duermes · *siempre encendido + derroche*

Tienes cuatro puestos. Repartes una tarea larga entre ellos al acostarte y por la maniana
hay resultado: revisar un repositorio entero, resumir cincuenta articulos guardados,
traducir un curso, generar los tests que faltan.

**Lo que hay que aprender aqui:** a dejar rastro. Un agente que trabaja de noche y no
registra lo que hizo es inservible. Que escriba un diario de lo que intento y que fallo.

### 3 · Buscador de tu propia vida en fotos · *volumen + privacidad*

Un modelo describe **todas** tus fotos —diez mil, las que tengas— y guarda las
descripciones. Despues buscas en lenguaje natural: *«la cena en la terraza con la
camiseta roja»*, *«capturas con codigo de error»*, *«fotos de mi perro en la nieve»*.

**Por que local:** describir 10.000 fotos por API cuesta cientos de euros y le entregas tu
vida entera a un tercero. Aqui es una noche de GPU y no sale nada de la maquina.

**El giro que lo hace bueno:** funciona con capturas de pantalla. Todo el mundo tiene
miles y ninguna es encontrable.

### 4 · Pregunta a tu propio codigo · *privacidad*

Indexas tus proyectos y preguntas en lenguaje natural: *«¿donde se valida el email?»*,
*«¿por que existe esta funcion?»*, *«¿que rompo si cambio esto?»*.

**Por que local:** el codigo de un cliente no se sube a ningun sitio. Y convierte la IA de
«escribe codigo nuevo» a «entiende el que ya hay», que es donde de verdad se pierde el
tiempo.

### 5 · Transcribe y resume todo lo que consumes · *volumen*

Cada video, podcast o reunion pasa por transcripcion y resumen automaticos. Al cabo de un
mes tienes una base de conocimiento buscable de todo lo que has visto y oido.

### 6 · Genera cincuenta y quedate con la mejor · *derroche*

En vez de pedir una respuesta y conformarte, pides cincuenta variantes y las filtras:
nombres para un producto, titulares, descripciones, ideas de guion.

**Lo que ensenia:** que la calidad muchas veces sale de la **cantidad mas un buen filtro**,
no de acertar a la primera. Es un cambio de mentalidad mas valioso que cualquier truco de
prompt, y es exactamente la estrategia que una API castiga y tu maquina premia.

### 7 · Tu segundo cerebro, que no se le cuenta a nadie · *privacidad*

Notas, diarios, ideas, listas — todo indexado y consultable. *«¿Que pensaba yo de esto
hace un anio?»*, *«¿de que hable con esta persona?»*.

Aqui la privacidad no es un detalle: es el requisito.

### 8 · El companiero de repaso que no se cansa · *derroche*

Le das el material y te examina. Cuantas veces quieras, a cualquier hora, con preguntas
nuevas cada vez. Que te explique lo que fallaste y vuelva a preguntar.

Repasar es repeticion pura. Con contador, cortas antes de tiempo.

## 4. Las tres lecciones de usarla de verdad

Estas valen mas que cualquier receta, y salen de haber construido cosas con este modelo,
no de la teoria:

### El modelo no comprueba su trabajo

Te dira que termino cuando no ha terminado. No por mentir: **porque no vuelve a mirar**.
En una sesion real declaro «todo funciona» tres veces sin serlo.

Si algo importa, **lo verificas tu o lo verifica un script**. Escribir la comprobacion
*antes* de pedirle la tarea es la costumbre mas rentable que puedes coger.

### Encuentra lo que da error, no lo que esta mal

Si algo falla ruidosamente, lo arregla muy bien: en una sesion se autocorrigio cinco veces
seguidas al ver los errores reales.

Si algo esta mal pero **funciona** —un fallo de seguridad, una logica torcida, una promesa
incumplida— no lo vera jamas, porque nadie se lo pide. Esa clase de defecto necesita a
alguien buscandolo a proposito.

La prueba de esto es fea y por eso vale: en un experimento controlado, el modo pensante
escribio un plan que contenia un fallo de seguridad, el modo rapido lo ejecuto, y el fallo
**entro en el plan y salio intacto en el codigo**. Razonar mas no lo evito.

### Los datos verificables hay que verificarlos

Cuando afirme un numero, una version o una direccion, compruebalo. Llego a escribir que
una peticion devolvia «HTTP 370 con 0 elementos» cuando devolvia 200 con 146 — y el numero
correcto estaba en su propio documento tres parrafos mas abajo. No inventa por maldad:
rellena huecos con lo que suena plausible.

### Y el corolario practico

Escribir codigo nuevo → **`qwen`**. Depurar algo que ya falla → **`qwent`**. Encontrar lo
que nadie ha reportado → **ninguno de los dos**: eso es tuyo, o de un revisor externo.

## 5. Como saber cuanto te esta ahorrando

El medidor lleva la cuenta desde el primer dia. Suma los tokens de salida de este mes:

```bash
python3 - <<'PY'
import json, glob, os, collections
t = collections.Counter()
for f in glob.glob(os.path.expanduser("~/llm-local/history/usage-*.jsonl")):
    for linea in open(f):
        for usuario, d in json.loads(linea)["deltas"].items():
            t[usuario] += d["out"]
total = sum(t.values())
for u, n in t.most_common():
    print(f"{u:24} {n:>12,}")
print(f"{'TOTAL':24} {total:>12,} tokens de salida")
PY
```

Multiplicalo por lo que cobra cualquier API comercial por token de salida y tendras la
cifra. Pero el numero de verdad no es ese: es **lo que no habrias intentado** con el
contador corriendo.

Ese es el punto de tener el modelo en casa.
