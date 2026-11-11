# Changelog — talent-sentry-guard

## P5a — retorno de la creación enmascarado — 2026-10-13

`github_seguridad.py --crear-issue --apply` imprime `CREADA: <identificador> <url>` enmascarado (dato devuelto por Linear); dos `crudo=True` de texto fijo retirados y los otros tres probados en `test-secretos-github.py`.

## P5 — Vigía ampliado: parte de guardia y barrido paginado — 2026-10-12

`scripts/parte_guardia.sh` convierte el parte de la guardia (antes prosa) en un script de
solo lectura: puerta del doctor, issues NUEVAS de Sentry frente al parte anterior y en la
ventana de 60 min tras cada fusión, alertas de seguridad de GitHub (`github_seguridad.py
--json`, sin config sale «no vigilada»), consultas de dinero `select`/`with` por la
Management API y silencio previo contra `2 × cadencia` leída del perfil. Una cifra por línea
(`tree=` e `instant=`), estado `LIMPIO | NOVEDAD | SONDA-ROJA`; `LIMPIO` es inalcanzable si
alguna sección no corrió (INV-SG-012). El repo se declara (`TA_PARTE_REPO` + `TA_PARTE_REPO_ID`),
nunca sale del cwd. No sella al bus ni instala cron.
`sentry_triage.py` sigue el cursor de Sentry (`Link rel="next"; results="true"`) con tope de
20 páginas por ordenación, sin duplicados y sin enviar el token fuera del endpoint del
proyecto; añade `--json --grupos` (`total_unresolved` y lista compacta) para el parte. Antes
el barrido solo miraba la primera página: un grupo nuevo nacido tras un despliegue y fuera
de ella (el caso del 14-sep) salía «limpio». Pruebas: `test-triage-paginacion.py` y
`test-parte-guardia.sh` (C1-C8, C10 con línea base de carga, mutantes de las guardas).
Ronda 2 de revisión: el parte enmascara las credenciales reflejadas en títulos, enlaces y errores
(y pasa a `SONDA-ROJA` si enmascara algo); el `Link` solo se sigue si la ruta, cruda y normalizada,
es exactamente el endpoint de issues del proyecto; las consultas de dinero rechazan `SELECT … INTO`.
Fronteras de fuga: el detalle de un error se lee entero hasta 1 MiB (fstat; por encima, `SONDA-ROJA`
`detalle-no-acotado` sin leerlo), la coincidencia tolerante a blancos empieza en 4 caracteres y una
credencial declarada de menos de 4 da rc 2 sin cifras.

## P5 — Vigía ampliado: resolución verificada — 2026-10-11

`resolver_ficha.py` permite resolver con PR fundido a main que cierra la
issue y cita el grupo, deploy LIVE y cese re-medido con sello previo OK.
Consulta por defecto; --apply exige header de escritura 0600 distinto,
hace un PUT sin reintento y sella VIGIA-RESUELTA con identidad del rol.
INV-SG-005 y -007 pasan de orden humana a resolución exclusivamente por
el script con tres pruebas; se conserva la prohibición de ignorar grupos.
INV-SG-008 y -009 fijan las tres pruebas y el fallo sin reintento ni sello.
No se amplían las facultades de código, merge, cierre Linear ni producción.
Pruebas C1-C9, negativos y tres mutaciones aisladas; fila vigia para estación.

## P5 — Vigía ampliado: alertas de seguridad de GitHub — 2026-10-12

`github_seguridad.py` vigila Dependabot, code scanning, secret scanning y advisories
de un repositorio declarado por entorno, solo con `gh api --method GET --paginate`.
Triage S0-S4 con la tabla por defecto de `references/02-taxonomia-triage.md`, NUEVOS /
ESCALA con cursor propio y `--json` (esquema fijo). `--crear-issue` monta el body
issue-craft y reutiliza el dedupe fail-closed de `crear_issue_desde_sentry.py`
(marcador de identidad y título; `issueCreate` sin reintento; dry-run por defecto).
El valor de un `secret` no sale por ninguna salida (`hide_secret=true`, descarte al
leer y enmascarado). Una superficie que no responde con una lista es fallo, no calma.
`sentry_doctor.sh` suma `check_github` como sexta fuente OPCIONAL: sin
`SENTRY_DOCTOR_GITHUB_REPO` muestra «github: no vigilada» y sigue; con la variable
definida es fail-closed (header-file 0600, identidad y superficies). `crear_issue_desde_sentry.py`
resuelve plantillas y gate de issue-craft desde la carpeta de skills, también sin
`.claude/`. INV-SG-010 y -011 guardan la solo-lectura y el secreto.

## Distribución pública — 2026-10 (paquete 2.0.0)

Entra en el paquete como miembro formal; la versión del paquete se fija al publicar la 2.0.

- Pieza P2 (issue 8544): puntero, herramientas y doctrina del paquete en `scripts/paquete/`; lista de diez miembros tras retirar skill-creator.

## Alta estructural en el paquete — 2026-10-10

Pieza P1 del plan v2 (issue 8543): miembro formal del paquete de once skills,
sin ampliar sus funciones. Siete invariantes de cinco columnas guardan las
prohibiciones de código, PR/merge, cierre, mutación de producción, resolución
sin orden y exposición de tokens; la séptima mantiene la orden del CEO en
references/04-contrato-de-issue.md.
