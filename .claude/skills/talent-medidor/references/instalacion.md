# Instalación y atribución del medidor en una instancia

Esta guía es genérica: no nombra ninguna instancia. El skill es agnóstico y toda la identidad
(nombres de partes, rutas de trabajo) vive en el **perfil de instancia** que la propia instancia
escribe.

## 1. Qué perfil lee el medidor

El medidor no tiene parser propio de perfil: lo lee **solo** con `source` de
`talent-ceo/scripts/lib-perfil.sh`. La variable que lo apunta es `TA_PERFIL` (precedencia:
`TA_PERFIL`, luego `$SECRET_DIR/perfil.tsv`, luego el del motor; la decide `lib-perfil.sh`).

```bash
export TA_PERFIL="<ruta-al-perfil-de-la-instancia>.tsv"
bash skills/talent-ceo/scripts/lib-perfil.sh --check     # rc 0 = perfil válido (V1-V9)
```

Con el perfil ausente o inválido (rc 2 de `lib-perfil.sh`) el recolector sigue midiendo, pero
`part_id`, `rol` y `pane_kind` salen `NO MEDIDO` y avisa por stderr (`aviso_perfil rc=2`). Nunca
se sirve una fila de un perfil roto.

## 2. Cómo se atribuye una respuesta a una parte

El transcript no trae el nombre de la sesión, solo el directorio de trabajo (`cwd`). El recolector
guarda **la huella sha256 del `cwd`** (nunca la ruta) y la cruza con el atributo `cwd=` de las filas
del perfil. Para que una parte se atribuya, su fila declara `cwd=` (y opcionalmente `rol=` y
`pane_kind=`):

```text
torre	<id>	<maquina>	-	<sesion>	rol=coordinador;cwd=/srv/fabrica/torre-demo;pane_kind=coordinacion
```

Reglas:

- `cwd=` es una ruta absoluta escrita exactamente igual que la ruta de trabajo que registra el
  cliente: se compara su huella sha256, carácter a carácter.
- **Cada `cwd=` debe ser único en el perfil.** Esta primera fase NO lo comprueba ni avisa: si dos
  filas declaran el mismo `cwd=`, todo el gasto de esa ruta se atribuye a UNA sola de ellas, la
  última que emite el recolector (recorre los tipos en el orden `maquina`, `torre`, `estacion`,
  `canal`, `runner`, `cron`, `bus`, `ceo`, `pm` y, dentro de cada tipo, el orden del fichero). La
  otra parte queda sin gasto. Rechazar el duplicado queda para la 2.1 (`PENDIENTE-2.1.md`).
- **Sin `cwd=` la parte sale `NO MEDIDO`.** Los totales por modelo y por hora sí se miden; lo que
  no se puede decir es «qué parte los gastó». Es un límite declarado, no un fallo del recolector.

## 3. Orden de instalación en un host

```bash
# 1. el timer de usuario de 5 minutos (--sin-activar escribe la unidad sin llamar a systemctl)
bash skills/talent-medidor/scripts/instalar-unidades.sh --solo recolector

# 2. la primera carga del historial, UNA vez y fuera del timer (se relanza bajo nice -n 19)
python3 skills/talent-medidor/scripts/recolector.py --bootstrap

# 3. el estado de salud: por fuente la última marca, los cursores y los contadores de rechazo
python3 skills/talent-medidor/scripts/recolector.py --salud

# 4. la cifra publicada contra una segunda implementación independiente (jq)
bash skills/talent-medidor/scripts/reconciliar.sh        # rc 0 y DIFERENCIA=0
```

El almacén vive en `~/.local/state/talent-medidor/medidor.db` (directorio 0700). Las raíces y la DB
se redirigen con `TALENT_MEDIDOR_CLAUDE_DIR`, `TALENT_MEDIDOR_CODEX_DIR`, `TALENT_MEDIDOR_DB`,
`TALENT_MEDIDOR_PRECIOS` y `TALENT_MEDIDOR_NORMALIZACION`.

## 4. Precios: la instancia pone sus tarifas

`config/precios.tsv` viaja **sin filas de datos**: un coste sin tarifa vigente es `NULL` con
`cost_estado='NO MEDIDO'`, nunca 0. Para medir coste, la instancia mantiene su propia tabla
(una fila por modelo y fecha, con la URL oficial del proveedor y la fecha de consulta) y la apunta
con `TALENT_MEDIDOR_PRECIOS`. El paquete no lleva identificadores de modelo concretos.

## 5. Qué NO hace esta versión

- No avisa de cuota agotada: **mide lo gastado, no lo que queda** (la vigía de cuota es de
  `talent-ceo`).
- No activa el timer ni genera `cwd=` en el perfil por sí solo: ambos son pasos manuales de esta guía.
- No tiene panel ni optimizador: leer el almacén es SQL directo sobre `usage_raw` y los rollups.
