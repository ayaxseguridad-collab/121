# Anexo por repo — migracion-crm (talent-ceo)

Lectura obligatoria antes de operar este repositorio. El estado vivo del destino
y las APIs son la fuente de verdad; ante divergencia, parar y escalar al lead.
Este overlay se prepara para adjudicarlo en el destino, no dentro del núcleo.

## §1 — Identidad

| Campo | Valor |
|---|---|
| `repo_slug` | `ayaxseguridad-collab/121` |
| `nombre_legible` | migracion-crm |
| `linear_workspace` | `gaston-ayax` |
| `linear_team_key` | `GAS` |
| `linear_team_id` | `b1360ead-d032-4ed9-bf71-8f5dc0d3e95b` |
| `initiative_id` | No aplica: esta instancia no declara una initiative de Linear. |
| Proyecto Linear | Prueba fabrica |
| In Progress | `c1fec9c2-7af8-491b-83df-bd10b34646bc` |
| In Review | `908d0ec4-b442-4070-847b-2feb90f06ac4` |
| Repositorio | https://github.com/ayaxseguridad-collab/121 |
| Rama de integración | `main` |
| Stack | `ninguno` |
| Perfil | `/home/gt/talent-factory/manifiestos/migracion-crm.perfil.tsv` |

Auditor de los canales: claude-root.
Configuración autoritativa de Linear: `/home/gt/talent-factory/instalacion/generado/linear-instancia.json`.
Consultar estados y labels existentes con consultar-estados-linear.sh antes de
operar; no inventar IDs ni usar la configuración de ejemplo de otro workspace.
La key gobierna `closes GAS-N` y `refs GAS-N`.

## §2 — Gates locales

Instalación de dependencias: `true`.
Validador de rama: `scripts/github/validar-rama-pr.sh`.
Motor: `/home/gt/talent-factory/scripts/run-local-gates.sh`, manifiesto: `/home/gt/talent-factory/manifiestos/migracion-crm.conf`.

| Gate activo | Comando |
|---|---|
| `readme` | `test -s README.md` |

Shards E2E: no aplican; no hay familias ni wrapper declarados.
La estación agrega receipts sellados a head en `local-gates`; verificar la
protección REAL de la rama antes de operar. No sustituir receipts por una
captura de pantalla ni omitir gates por ser una entrega de documentación.

## §3 — Protocolo de migraciones

Supabase: no; no hay base de datos gestionada en esta instancia.
Ref y método de apply: no aplican. `migration_slots: n/a`.
PROC-M13 no aplica; tampoco PROC-M14/M15, porque el stack es ninguno.
Actor del apply: No aplica: no hay base de datos gestionada..


## §4 — Superficies con path-patterns (solo excepciones al default)

Superficies declaradas en el manifiesto: `auth credenciales`.
Excepciones por path-pattern: no aplican, no hay excepciones adjudicadas al default.
Fuera de las excepciones declaradas rige review normal; las destructivas
requieren GO explícito del lead. Ante duda, clasificar como destructiva.

## §5 — Actor post-merge

Mergeador: verifica merge, receipts y cierre real.
Deploy automático: no configurado; no aplica un deploy de plataforma en esta instalación.
No se ha declarado plataforma ni comando de deploy; no inferirlos del repositorio.
Actor de migraciones: no aplica; stack ninguno.
Notificación al lead: informar en la sesión de operación de toda finalización
y de cualquier bloqueo. No aplica una integración externa de notificaciones:
esta instancia no la configura y no autoriza envíos externos.
Migraciones escaladas/manuales: `refs GAS-N` y label
`apply-pendiente`; Done manual solo tras confirmar apply y advisors.
`closes` requiere apply del Mergeador en el mismo turno si hay migraciones.

## §6 — Lista de autoridades de receipts

Autoridades de onboarding: vacías por defecto; todo receipt rechazado
(fail-closed). No se ha adjudicado ningún user.id de GitHub en la instalación.
Antes de aceptar atestaciones, el lead debe adjudicar enteros verificados en
`assets/receipt-authorities.txt` del skill talent-repo-onboarding o mediante
`TRO_RECEIPT_AUTHORITIES`. No confundirlos con los receipts de gates.
Consultar `gh api users/ayaxseguridad-collab --jq '.id'` durante el onboarding:
no convertir el login en un ID inventado ni considerar acreditado el actor.

## Notas operativas

Lead responsable: `ayaxseguridad-collab`.
Onboarding: consultar el contrato validado en F4; generar en F1 no acredita montaje.
Ensayo E2E y primer encargo de producción: exigir la evidencia durable de F8.
Credenciales: solo nombres en el escrow; exigir check-F3 y acreditación de F7.
Git de los canales: nombre `{channel}`, correo `{channel}@channels.invalid`.
Topología y usuarios: el TSV del perfil manda sobre esta descripción.

## Lectura del perfil y operación del CEO

Perfil autoritativo: `/home/gt/talent-factory/manifiestos/migracion-crm.perfil.tsv`. Tras adjudicar, su copia vive en
`manifiestos/migracion-crm.perfil.tsv` del producto. El descubrimiento normal
de lib-perfil.sh debe encontrar exactamente uno; más de uno falla cerrado.
Validar con `bash /home/gt/talent-factory/skills/talent-ceo/scripts/lib-perfil.sh --check /home/gt/talent-factory/manifiestos/migracion-crm.perfil.tsv`.
El escrow de perfiles es opcional; no inventar un fallo por su ausencia.

| Tipo | Censo inicial |
|---|---|
| `maquina` | 1 |
| `ceo` | 1 |
| `torre` | 1 |
| `estacion` | 1 |
| `canal` | 1 |
| `runner` | 1 |
| `pm` | 0 |
| `bus` | 1 |
| `cron` | 1 |

Los IDs son únicos globalmente. La columna tipo clasifica el actor;
contenedor es un identificador opaco. No deducir roles por prefijos.
Usuarios por rol y sesiones: consultar el TSV; cada actor que sella tiene
usuario distinto de cualquier otra fila de su máquina. Los canales comparten
`migracion-crm-incus`, operador Incus del host, también declarado para el runner.
Dentro de los canales se usa `vivecoder`; dentro del runner se usa `runner`.
PM no aplica: no se solicitó este rol y no hay fila pm; no deducirla de CEO.
No hay satélites ni tablas adicionales adjudicadas en este perfil.
Runner local adjudicado: `runner-migracion-crm`, contenedor `runner-migracion-crm` en `maquina-1`
(host `gt-Default-string`, según `manifiestos/runner-identity.map`).
Operador Incus del host: `migracion-crm-incus`; usuario sin privilegios del
contenedor: `runner`; repositorio: `/home/runner/repo`. No hay máquinas remotas adjudicadas.
La estación lee `~/.config/talent-factory/station.conf`: `TF_RUNNERS=runner-migracion-crm`,
`TF_RUNNER_USER=runner`, `TF_RUNNER_REPO=/home/runner/repo`, `TF_STATION_HOST=gt-Default-string`.
Desde la sesión M1, cargar esa configuración pública y ejecutar/publicar los gates:

```bash
set -a
. "$HOME/.config/talent-factory/station.conf"
set +a
bash /home/gt/talent-factory/scripts/seal-suite.sh "$PR" "$SHA" origin/main "$RUNGROUP"
```
PR, SHA y RUNGROUP corresponden al handoff validado; seal-suite agrega receipts
y publica `local-gates`. Exigir éxito de todos los gates; no usar --no-post al entregar.

### Cron y bus

Fila CRON: dueño CEO, minutos `07,22,37,52`. Se leen del perfil;
este documento no instala tareas ni autoriza copiarlo al crontab.
Fila BUS: `/home/gt/migracion-crm/bus`; lectores declarados en el TSV: CEO, C1, M1 y los
actores ORQ/PM si se solicitan. Los comandos usan flock mediante sus rutas
de runtime; ningún atributo lock del perfil configura ese bloqueo.
Los lectores declarados no acreditan permisos: bus-leer.sh usa su argumento
lector y un cursor propio, sin imponer una ACL desde el perfil.
Cursor y permisos del bus: los crea F6 y los acredita el doctor en F7 antes de operar.
No escribir credenciales ni PII en el bus.
Leer ledger `/home/gt/talent-factory/ledger/cuentas.json`: coordinator_host `gt-Default-string`.
Pozos y cuentas: consultar ledger y check-F3; habilitada_fabrica no prueba login.
Nunca volcar el entorno ni ficheros de credenciales; comprobar únicamente nombres y presencia.
