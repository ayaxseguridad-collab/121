# 03 — Registro de flota (issue-registro)

## Table of Contents

- [Formato](#formato)
- [Reglas duras](#reglas-duras)
- [Normalización de canal](#normalización-de-canal)
- [Uso](#uso)

La **fuente de verdad de los canales** es una issue Linear (siempre In Progress, label `registry`)
en el proyecto Coordinación. Mejor que un archivo: la lee cualquier orquestador/coordinador del
tailnet con el token, sin distribuir nada.

```text
issue-registro: tabla cercada (6 columnas fuente) → registry.sh deriva "container" → TSV (7 columnas)

  FUENTE (issue body):
  | channel          | machine | hwclass | role | coordinador  | repo      |
  |------------------|---------|---------|------|--------------|-----------|
  | vibe-channel-01  | m0      | cpu     | dev  | coord-talent | org/repo  |

  registry.sh → torc_to_container() deriva el 7º campo ──►

  SALIDA (TSV): channel_id  container         machine  hwclass  role  coordinador   repo
                01          vibe-channel-01   m0       cpu      dev   coord-talent  org/repo
```

## Formato

El cuerpo lleva una **tabla cercada** (```` ``` ````). `registry.sh` extrae solo las filas que
contienen `vibe-channel-`:

```text
| channel | machine | hwclass | role | coordinador | repo |
|---|---|---|---|---|---|
| vibe-channel-01 | m0 | cpu | dev | coord-talent | org-ejemplo/producto |
| vibe-channel-05 | m0 | gpu | audit-ciber | coord-talent | org-ejemplo/producto |
```

## Reglas duras

- **CERO secretos** (regla 18): el registro solo **mapea** canal→coordinador + hardware + repo.
  Las creds/tokens por canal viven en el **escrow del canal** (lo gestiona `talent-channels`).
- **Config lenta**: se edita cuando cambia la topología de la flota, no en cada batch. El estado
  libre/ocupado en vivo NO va aquí (es runtime del Coordinador).

## Normalización de canal

El Coordinador usa `channel_id` corto (`01`) y construye el contenedor con prefijo
(`vibe-channel-01`). `registry.sh` expone **ambos** (`torc_to_channel_id` / `torc_to_container`), de modo
que quien lee el registro obtiene el ID corto (`01 02 …`) o el nombre del contenedor según lo necesite.

## Uso

```bash
bash scripts/registry.sh                       # toda la flota
bash scripts/registry.sh --coordinador coord-talent   # solo la cuadrilla de un coordinador
```
