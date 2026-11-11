-- esquema.sql — almacén SQLite del medidor (F1). Lo aplica recolector.py en cada apertura
-- (idempotente: todo es IF NOT EXISTS). El modo WAL y los permisos 0700 los pone el recolector.
--
-- Contrato de datos de personas: aquí SOLO viven numéricos, enumerados de conjunto cerrado,
-- identificadores opacos con forma validada y huellas sha256. Ninguna columna guarda texto
-- conversacional, rutas en claro ni campos fuera de la allowlist del extractor.
--
-- F2 y F3 consumen este fichero congelado por sha: cambiar una columna es un cambio de contrato.

-- Unidad contable = RESPUESTA (Claude: message.id · Codex: response_id). Una fila por unidad.
CREATE TABLE IF NOT EXISTS usage_raw (
  session_id    TEXT    NOT NULL,
  unidad_id     TEXT    NOT NULL,
  proveedor     TEXT    NOT NULL CHECK (proveedor IN ('claude', 'codex')),
  ts            REAL,                       -- epoch s; NULL si la fuente no lo trae (D3)
  ts_month      TEXT,                       -- 'AAAA-MM': partición lógica del raw
  model         TEXT,
  effort        TEXT    NOT NULL,
  fase          TEXT    NOT NULL,           -- plan | coordinacion | NO MEDIDO
  origen_turno  TEXT    NOT NULL,           -- cron | manual | NO MEDIDO
  part_id       TEXT    NOT NULL,
  rol           TEXT    NOT NULL,
  pane_kind     TEXT    NOT NULL,
  es_subagente  INTEGER NOT NULL DEFAULT 0,
  agent_type    TEXT,
  turn_id       TEXT,                       -- solo Codex
  nodo_uuid     TEXT,                       -- registro elegido (Claude): raíz del DAG de origen
  in_tok        INTEGER NOT NULL DEFAULT 0, -- input_tokens tal cual
  cache_w       INTEGER NOT NULL DEFAULT 0,
  cache_w_5m    INTEGER NOT NULL DEFAULT 0,
  cache_w_1h    INTEGER NOT NULL DEFAULT 0,
  cache_r       INTEGER NOT NULL DEFAULT 0,
  in_total      INTEGER NOT NULL,           -- fórmula de config/normalizacion.tsv
  out_tok       INTEGER NOT NULL,
  thinking_tok  INTEGER NOT NULL DEFAULT 0,
  cost_usd      REAL,                       -- NULL cuando cost_estado = 'NO MEDIDO', nunca 0
  cost_estado   TEXT    NOT NULL CHECK (cost_estado IN ('MEDIDO', 'NO MEDIDO')),
  cwd_sha       TEXT,
  UNIQUE (session_id, unidad_id)
);
CREATE INDEX IF NOT EXISTS usage_raw_ts      ON usage_raw (ts);
CREATE INDEX IF NOT EXISTS usage_raw_part_ts ON usage_raw (part_id, ts);
CREATE INDEX IF NOT EXISTS usage_raw_month   ON usage_raw (ts_month);

-- Los registros (líneas) que componen cada respuesta. Sumar por aquí multiplicaría el gasto.
CREATE TABLE IF NOT EXISTS registros_por_respuesta (
  session_id TEXT NOT NULL,
  unidad_id  TEXT NOT NULL,
  uuid       TEXT NOT NULL,
  UNIQUE (session_id, unidad_id, uuid)
);

-- DAG parentUuid persistido entre ticks (un fire puede quedar en el tick anterior).
-- origen/pm son memos: NULL = aún sin resolver (el padre no ha llegado).
CREATE TABLE IF NOT EXISTS nodos (
  session_id      TEXT NOT NULL,
  uuid            TEXT NOT NULL,
  parent_uuid     TEXT,
  tipo            TEXT NOT NULL,            -- user | assistant | system | otro
  subtipo         TEXT,                     -- scheduled_task_fire | compact_boundary | NULL
  permission_mode TEXT,
  origen          TEXT,
  pm              TEXT,
  PRIMARY KEY (session_id, uuid)
);

-- Codex: el acumulado del turno SOLO como control, nunca como uso.
CREATE TABLE IF NOT EXISTS codex_turno_snap (
  session_id TEXT    NOT NULL,
  unidad_id  TEXT    NOT NULL,
  turn_id    TEXT    NOT NULL,
  ts         REAL,
  orden      INTEGER NOT NULL,
  turno_in   INTEGER NOT NULL,
  turno_out  INTEGER NOT NULL,
  PRIMARY KEY (session_id, unidad_id)
);
CREATE TABLE IF NOT EXISTS control_turnos_codex (
  session_id TEXT    NOT NULL,
  turn_id    TEXT    NOT NULL,
  suma_in    INTEGER NOT NULL,
  suma_out   INTEGER NOT NULL,
  turno_in   INTEGER NOT NULL,
  turno_out  INTEGER NOT NULL,
  coincide   INTEGER NOT NULL,
  PRIMARY KEY (session_id, turn_id)
);

-- Muestras de cuota de Codex (event_msg.token_count): NUNCA filas de uso.
CREATE TABLE IF NOT EXISTS cuota_muestras (
  fuente_id      TEXT    NOT NULL,
  ts             REAL,
  ventana        TEXT    NOT NULL,          -- primary | secondary
  window_minutes INTEGER,
  resets_at      INTEGER,
  used_percent   REAL,
  UNIQUE (fuente_id, ts, ventana)
);

-- Rollups: se RECALCULAN desde usage_raw para cada bucket tocado (nunca delta a mano).
CREATE TABLE IF NOT EXISTS rollup_5m (
  bucket REAL NOT NULL, proveedor TEXT NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
  fase TEXT NOT NULL, part_id TEXT NOT NULL,
  n_unidades INTEGER NOT NULL, in_total INTEGER NOT NULL, out_tok INTEGER NOT NULL,
  thinking_tok INTEGER NOT NULL, cache_r INTEGER NOT NULL, cache_w INTEGER NOT NULL,
  cost_usd REAL NOT NULL, n_cost_no_medido INTEGER NOT NULL,
  PRIMARY KEY (bucket, proveedor, model, effort, fase, part_id)
);
CREATE TABLE IF NOT EXISTS rollup_1h (
  bucket REAL NOT NULL, proveedor TEXT NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
  fase TEXT NOT NULL, part_id TEXT NOT NULL,
  n_unidades INTEGER NOT NULL, in_total INTEGER NOT NULL, out_tok INTEGER NOT NULL,
  thinking_tok INTEGER NOT NULL, cache_r INTEGER NOT NULL, cache_w INTEGER NOT NULL,
  cost_usd REAL NOT NULL, n_cost_no_medido INTEGER NOT NULL,
  PRIMARY KEY (bucket, proveedor, model, effort, fase, part_id)
);
CREATE TABLE IF NOT EXISTS rollup_1d (
  bucket REAL NOT NULL, proveedor TEXT NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
  fase TEXT NOT NULL, part_id TEXT NOT NULL,
  n_unidades INTEGER NOT NULL, in_total INTEGER NOT NULL, out_tok INTEGER NOT NULL,
  thinking_tok INTEGER NOT NULL, cache_r INTEGER NOT NULL, cache_w INTEGER NOT NULL,
  cost_usd REAL NOT NULL, n_cost_no_medido INTEGER NOT NULL,
  PRIMARY KEY (bucket, proveedor, model, effort, fase, part_id)
);

CREATE TABLE IF NOT EXISTS sesiones (
  session_id TEXT PRIMARY KEY,
  proveedor  TEXT NOT NULL,
  primera_ts REAL,
  ultima_ts  REAL,
  n_unidades INTEGER NOT NULL,
  part_id    TEXT NOT NULL
);

-- Cursor por FUENTE: la ruta se guarda como sha256, nunca en claro. (inode, offset).
CREATE TABLE IF NOT EXISTS cursores (
  fuente_id  TEXT PRIMARY KEY,
  proveedor  TEXT    NOT NULL,
  inode      INTEGER NOT NULL,
  offset     INTEGER NOT NULL,
  estado     TEXT,                          -- JSON de enums/huellas (turn_context vigente de Codex)
  ultima_ts  REAL,
  actualizado REAL NOT NULL
);

-- Contadores operativos (rechazos por forma, avisos de perfil). Solo claves y números.
CREATE TABLE IF NOT EXISTS eventos (
  ts    REAL    NOT NULL,
  tipo  TEXT    NOT NULL,
  clave TEXT    NOT NULL,
  valor INTEGER NOT NULL
);
