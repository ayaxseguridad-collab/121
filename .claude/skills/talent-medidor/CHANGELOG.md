# Changelog — talent-medidor

Esta es la distribución publicable del paquete de fábrica: la bitácora interna de
desarrollo no se incluye.

## Distribución pública — 2026-10 (paquete 2.0.0)

Entra en el paquete como miembro formal (el 13.º); la versión del paquete se fija al publicar
la 2.0.

### Qué entra (primera fase del medidor)

- **Extractores** de Claude (`message.id`, último `usage` por `timestamp`) y de Codex
  (`response_id`, `turn_context` vigente, muestras de cuota de `token_count`): stdlib puro, con
  allowlist de claves y validación de forma de identificadores y modelo.
- **Recolector** incremental del host: cursor `(inode, offset)` por fuente, `ON CONFLICT DO UPDATE`
  por unidad, orden extraer, insertar, COMMIT y cursor, grafo `parentUuid` persistido entre ticks,
  rollups de 5 minutos, 1 hora y 1 día recalculados desde `usage_raw`, `--bootstrap` bajo
  `nice -n 19` y `--salud`.
- **Esquema SQLite** (`esquema.sql`, modo WAL, directorio 0700) y **reconciliación** independiente
  con `jq` (`reconciliar.sh`).
- **Configuración**: `normalizacion.tsv` y `precios.tsv` **sin filas de datos**: sin tarifa
  oficial fechada todo coste sale `NO MEDIDO`, nunca 0.
- **Timer de usuario** de 5 minutos (`instalar-unidades.sh --solo recolector`).
- **Guía de instalación genérica** (`references/instalacion.md`): variable del perfil, atributo
  `cwd=` por parte, orden de instalación y límites.
- **Suite hermética** con `TOTAL_ESPERADO`: las 62 aserciones de la primera fase más K38
  (ráfaga de tres partes y dos proveedores con cinco copias por respuesta, reparto literal por
  parte y reconciliación con `DIFERENCIA=0`), K39 (neutralidad del árbol y base declarada) y K40
  (`cwd=` repetido en el perfil: gana la última fila y la guía lo declara).
- **18 invariantes** doctrinales (mínimo del manifiesto: 6).

### Ediciones de neutralidad respecto al origen

- Los identificadores de modelo de las fixtures sintéticas y de la suite pasan a nombres
  neutros (`claude-fx-modelo-a`, `claude-fx-modelo-b`): el paquete no lleva identificadores de
  modelo concretos. Las fórmulas y los esperados no cambian.
- Se quitan las claves de issue de los comentarios de `config/` y de `references/`.
- Se retira el anexo de instancia y el `overlay-prefix`: la distribución no lleva overlays. Lo
  genérico vive en `references/instalacion.md`.
- La sección «Paquete de fábrica» de `SKILL.md` pasa a la forma vigente de 13 nombres y el
  invariante del puntero al manifiesto apunta a `scripts/paquete/package.manifest`.
- Los siete scripts y las tres fixtures sin identificadores de modelo son idénticos al origen
  byte a byte; el contrato de la unidad contable no cambia.

### Pendiente, con dueño

- Alerta de cuota agotada, panel, optimizador y reglas de crons: no están en esta fase (mide lo
  gastado, no lo que queda). Quedan en `PENDIENTE-2.1.md`.
- Que el instalador active el timer y que el perfil generado declare `cwd=` por parte: hoy es un
  paso manual de `references/instalacion.md`.
- Filas de `config/precios.tsv`: las pone la instancia con la tabla oficial del proveedor y su
  fecha, vía `TALENT_MEDIDOR_PRECIOS`.
