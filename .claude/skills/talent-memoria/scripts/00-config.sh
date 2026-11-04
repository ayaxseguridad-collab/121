#!/usr/bin/env bash
# 00-config.sh — constantes del skill talent-memoria. Se sourcea, no se ejecuta.
# Todo es local: cero red, cero credenciales. Allowlist de comandos abajo.
# shellcheck disable=SC2034  # las constantes las consumen los scripts que sourcean

# Orden y colacion DETERMINISTAS en cualquier maquina/locale (sort, comm, join,
# rangos de grep): sin esto, dos maquinas listan candidatos en ordenes distintos.
export LC_ALL=C

# Nombre del fichero indice dentro de un corpus (override: TM_INDEX_FILE)
TM_INDEX_FILE="${TM_INDEX_FILE:-MEMORY.md}"

# Estados validos de una nota no-viva (taxonomia de references/02)
TM_ESTADOS='ANULADA|ACOTADA|CADUCADA|SUPERSEDED|ALIAS-STUB|PENDIENTE'

# Estados que forman un bloque de ANULACION propiamente dicho (references/02 §4
# y §9): ALIAS-STUB y PENDIENTE viven dentro de TM_ESTADOS (S3 los acepta) pero
# tienen su CONTRATO PROPIO (marca +sucesora / placeholder corto) y NO cuentan
# como marca de anulacion — un "> ALIAS-STUB ..." declarado semantico:anulacion
# no debe colar.
TM_ESTADOS_ANULACION='ANULADA|ACOTADA|CADUCADA|SUPERSEDED'

# Fecha ISO/compacta con RANGOS VALIDOS (mes 01-12, dia 01-31 lexico, no
# calendario real: 2026-02-31 pasa — limite declarado, date -d rompe GNU/BSD)
# y DELIMITADA contra digito adyacente: sin esto, "2026-12-310" o
# "12026-12-31" colarian una fecha valida como subcadena de una invalida.
# [^0-9] y no [[:space:]] como delimitador: la fecha puede ir pegada a '.', ')'
# o al em-dash (3 bytes no-digito bajo LC_ALL=C, que siguen delimitando bien).
# Fuente UNICA para el skill (gate de verificar.sh + censo de tm_tiene_fecha);
# el oraculo de eval (§9 del plan) NO la consume — implementacion propia,
# deliberadamente independiente, con sus propios negativos.
TM_RE_FECHA_ISO='(^|[^0-9])20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])([^0-9]|$)'
TM_RE_FECHA_COMPACTA='(^|[^0-9])20[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([^0-9]|$)'

# Modos validos de una fila de fichero en cambios-declarados.tsv
# ("alta" = fichero NUEVO declarado, item 8: el placeholder del paso 5 —
# references/02 seccion 10 — no era verificable por su propio verificador)
TM_MODOS='intacto|solo-adicion|semantico:anulacion|semantico:fusion|semantico:alias-stub|semantico:indice|alta'

# Umbral de lineas a partir del cual el diagnostico sugiere compactar el indice
TM_INDICE_LINEAS_MAX="${TM_INDICE_LINEAS_MAX:-50}"

# Similitud de titulos para candidatos a duplicado: prefijo comun minimo (caracteres)
TM_DUP_PREFIJO="${TM_DUP_PREFIJO:-16}"

# Permisos de la salvaguarda (S1): directorio y ficheros
TM_SNAP_DIR_MODE=700
TM_SNAP_FILE_MODE=600

# Allowlist de comandos externos que los scripts de este skill pueden ejecutar.
# tests/probar-invariants.sh la contrasta contra el codigo real (fail-closed).
TM_ALLOWED_CMDS="bash cat pwd grep diff tar git find sort comm join wc sed awk head tail cut tr mktemp date basename dirname chmod mkdir cp mv rm stat sha256sum shasum uname"
