# Changelog — linear-skill

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-09 (paquete 1.7.4, versión intermedia)

- La clave de Linear se resuelve por este orden: `LINEAR_API_KEY` exportada; si `TA_OPERATION_ENV`
  está definida y no vacía, el fichero al que apunta y solo ese; si no, `.env.local` en la raíz del
  repo. Rige el procedimiento bash de `SKILL.md` y el cargador de `scripts/linear-client.ts`, que
  `batch-issues.ts` y `upload-attachment.ts` reutilizan. Un `TA_OPERATION_ENV` roto, o ninguna fuente,
  sale con un error que nombra la ruta y la variable, sin llamada de red ni clave vacía.
- Prueba nueva `tests/test-resolucion-clave.sh` (registrada en `tests/run-tests.sh`) y 7 casos nuevos
  en `linear-client.ts --action selftest`. Corre con cualquier Node 18 o superior: `tests/cargador-portable.cjs`
  evalúa el código de producción de TypeScript con los tipos borrados (sin tsx ni red); sin `node`
  sus casos de TypeScript se declaran SKIP (no verdes). README y Quick Start de `SKILL.md`
  remiten a la misma resolución de la clave.
- La prueba `tests/test-resolucion-clave.sh` detecta el TypeScript nativo de node CARGANDO un `.ts` mínimo
  con `--experimental-transform-types`, no por la bandera: un node compilado sin TypeScript (el paquete
  `nodejs` de Ubuntu 26.04) acepta la bandera con `-e` y falla con `ERR_NO_TYPESCRIPT` solo al cargar el
  fichero, lo que daba un positivo falso y un FAIL en la equivalencia. Sin TypeScript nativo se toma la rama
  INFO (sin FAIL ni SKIP; el total sigue en 22). Regresión nueva `tests/test-sonda-ts-nativo.sh` (15
  comprobaciones: dos node dobles —uno sin TypeScript y otro anterior a 22.7, que no dependen de la versión
  del node real—, el node real y un mutante con la sonda vieja), registrada en
  `tests/run-tests.sh`. El producto no cambia.
