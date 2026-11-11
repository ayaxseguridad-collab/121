# Changelog

## Distribución pública — 2026-10 (paquete 2.0.0)

Entra en el paquete como miembro formal; la versión del paquete se fija al publicar la 2.0.

## 2026-10-10

- Las trece expresiones awk de métricas usan programas literales y valores por
  `-v`, conservando salidas, umbrales y guardas de total cero, sin excepciones
  nuevas al comprobador de portabilidad.

- Se completa la neutralización de prefijos en ramas, migraciones y placeholders
  de las evaluaciones y ejemplos; la detección de stack usa una variable neutra.
- Se corrigen los dos destinos del índice del gate CLI para coincidir con sus
  encabezados ABC, conservando doctrina y resultados históricos.

- El registro histórico `evals/results-2026-09-05.md` deja de citar un ID de modelo fijo (regla de modelos rodantes del paquete); describe el modelo como «el modelo de código vigente en esa fecha». Sin cambio en los resultados.

- coderabbit-talent entra al paquete 2.0 desde `origin/main` del producto,
  SHA `8e358697d3483a26f69ecb32be81467e3228721a`.
- Se conserva la doctrina y se neutralizan los ejemplos de organización,
  repositorio, proyecto e identificadores de issues, también en evaluaciones históricas.
- El origen ya cumple los límites de líneas y description: no se mueven bloques.
- Se añade la sección Paquete de fábrica, ocho invariantes trazables y una entrada
  de tests que ejecuta el corrector existente sin cambiar sus criterios ni su rc.
- EXTENSION-sonarqube.md está excluida; el origen actual ya la había retirado.

### Corrección del registro de evaluaciones

- Se retira tests/run-tests.sh: envolvía el corrector histórico
  evals/runs-2026-09-05/grade.sh, con condiciones sin skill (`none`, `none-clean`),
  FAIL deliberados y dependencia de la CLI de CodeRabbit. No es una suite del miembro.
- Las evaluaciones y su corrector se conservan como registro histórico, igual que
  las evaluaciones de linear-skill; no se añade una suite sustituta.
