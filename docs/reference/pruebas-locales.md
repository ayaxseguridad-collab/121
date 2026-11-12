---
title: "Pruebas locales del CRM"
created: 2026-11-11
updated: 2026-11-11
author: vibe-channel-11
status: active
---

# Pruebas locales del CRM

Cómo correr en una máquina de desarrollo la batería de pruebas automáticas del CRM.

## Requisito

Node 24 o más nuevo (`"engines": { "node": ">=24" }` en `package.json`): el CRM y sus
pruebas usan `node:sqlite`. Comprobarlo con `node --version`.

## Dependencias

Desde la raíz del repo:

```bash
npm install
```

Instala las dependencias de `package.json`, que son las que necesita el servidor para
WhatsApp. La batería de pruebas solo usa módulos nativos de Node: no usa WhatsApp ni accede
a la red exterior (las pruebas que levantan una copia del CRM le hablan por HTTP local).

## Correr toda la batería

```bash
npm test
```

`npm test` ejecuta el script `test` de `package.json`, que es literalmente:

```bash
node --test tests/altas.test.cjs tests/config.test.cjs tests/pin.test.cjs tests/limites.test.cjs
```

## Ficheros de prueba

| Fichero | Qué cubre |
|---|---|
| `tests/altas.test.cjs` | Avisos de los pasos 8 y 12 del Alta (destinatarios, reintentos, sin duplicados), con SQLite en memoria y transporte simulado |
| `tests/config.test.cjs` | GAS-400 y GAS-402: `POST /api/config` solo guarda claves conocidas y la pestaña Avisos escapa las horas |
| `tests/pin.test.cjs` | GAS-401: la clave de cierre no viene fija y los intentos fallidos se frenan |
| `tests/limites.test.cjs` | GAS-403 y GAS-404: tope de 1 MB al cuerpo (413) y validación de horas, plazos y preaviso |

## Correr un solo fichero

```bash
node --test tests/<fichero>
```

Por ejemplo, `node --test tests/pin.test.cjs`.

## Ficheros de apoyo

El resto de `tests/` son ayudas de las pruebas (`altas-fixture.cjs`, `crm-copia.cjs`,
`servidor-simulado.cjs`, que trabajan con copias temporales y transporte simulado) o una
auditoría aparte con navegador (`altas-navegador.cjs`) que `npm test` no ejecuta.
