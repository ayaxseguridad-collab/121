#!/usr/bin/env bash
# Gate anti-fugas M5. Dos modos:
#   --cached : ANTES de cada commit — escanea el indice (staged) y los archivos
#              no rastreados (nombres NUL-delimitados: soporta espacios).
#   (defecto): gate final — escanea CADA commit de la rama (rev-list base..HEAD),
#              no el diff acumulado: un secreto que entro y "se tapo" en un
#              commit posterior TAMBIEN falla. La historia se rehace, no se tapa.
# En ambos modos: veto de binarios POR COMMIT (un keystore no lo caza un regex)
# y analisis del patch real de Git (textconv y diff drivers desactivados).
# Las funciones que mutan el contador se alimentan por process substitution,
# NUNCA como ultimo eslabon de un pipeline: un subshell perderia el contador y
# el gate diria LIMPIO con hallazgos (fallo real cazado en revision ronda 4).
set -euo pipefail

BASE="${TB_ANTIFUGAS_BASE:-main}"
# Patrones de secretos conocidos del despliegue. Escritos para no auto-matchear
# su propia definicion en este archivo.
#
# DETECCION vs REDACCION son patrones SEPARADOS a proposito (M2, 2a vuelta):
# el DETECTOR puede ser amplio y disparar solo por el prefijo (sk-lead/sk-hermes);
# el REDACTOR, en cambio, debe consumir la credencial COMPLETA hasta un
# delimitador seguro — si solo borra el prefijo, el sufijo queda visible y el
# prefijo es trivialmente reconstruible desde el marcador (fuga parcial). NSEC y
# HEX64 ya casan el token entero (nsec1+58 / 64 hex); solo SK necesitaba
# extenderse mas alla del prefijo.
RE_NSEC='nsec1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{50,}'
RE_SK='sk-(lead|hermes)'                       # DETECTOR: prefijo, deliberadamente amplio
RE_HEX64='[0-9a-f]{64}'
REGEX="$RE_NSEC|$RE_SK|$RE_HEX64"
# REDACTORES: consumen el token entero. `[A-Za-z0-9._-]*` traga el sufijo de la
# credencial y para en un delimitador seguro (espacio, `/`, comillas, `:`, `=`).
RED_SK='sk-(lead|hermes)[A-Za-z0-9._-]*'

GITQ=(git -c diff.external= -c core.attributesFile=/dev/null)
fallos=0

redacta() { # filtro stdin→stdout: sustituye cualquier secreto por un marcador
  # con su TIPO. Sirve para mostrar RUTAS/etiquetas NO confiables (un secreto
  # puede vivir en el NOMBRE de un fichero) sin que el propio gate lo revele
  # (ronda corta 1.2.1, M2). Orden: NSEC y SK antes que HEX64 (un token nsec/sk
  # podria contener una subcadena hex de 64). Para SK se usa RED_SK (token
  # completo), no el detector RE_SK (solo prefijo): borrar solo el prefijo dejaba
  # el sufijo visible y el prefijo reconstruible (M2, 2a vuelta).
  sed -E -e "s/$RE_NSEC/[SECRETO:NSEC]/g" \
         -e "s/$RED_SK/[SECRETO:SK]/g" \
         -e "s/$RE_HEX64/[SECRETO:HEX64]/g"
}

escanea_texto() { # $1: etiqueta; stdin: patch/contenido
  # Reporta etiqueta + nº de línea + TIPO de secreto (NSEC/SK/HEX64). NUNCA
  # imprime el contenido casado: un gate anti-fugas que echa el secreto al log
  # ES una fuga (ronda corta 1.2.1). El tipo se clasifica por prefijo, no por el
  # valor: `nsec1…` → NSEC, `sk-lead|sk-hermes` → SK, resto → HEX64.
  local hits
  hits=$(grep -nE -e "$REGEX" - | grep -v '^Binary files' \
    | awk 'BEGIN{FS=":"} {
        ln=$1; rest=$0; sub(/^[0-9]+:/,"",rest);
        tipo=(rest ~ /nsec1/)?"NSEC":(rest ~ /sk-(lead|hermes)/)?"SK":"HEX64";
        print "    linea " ln " tipo " tipo;
      }' | head -5 || true)
  if [ -n "$hits" ]; then
    # $1 puede llevar una ruta no confiable (p.ej. "untracked <nombre>"): redacta.
    echo "FUGA en $(printf '%s' "$1" | redacta):"; echo "$hits"; fallos=$((fallos+1))
  fi
}

veta_binarios() { # $1: etiqueta; stdin: salida numstat
  local bins
  bins=$(awk -F'\t' '$1=="-" && $2=="-" {print $3}' - || true)
  if [ -n "$bins" ]; then
    # Tanto la etiqueta como las RUTAS binarias pueden portar un secreto en el
    # nombre: redacta ambas antes de mostrarlas (M2).
    echo "BINARIO VETADO en $(printf '%s' "$1" | redacta):"
    printf '%s\n' "$bins" | redacta | sed 's/^/    /'
    fallos=$((fallos+1))
  fi
}

if [ "${1:-}" = "--cached" ]; then
  escanea_texto "indice (staged)" < <("${GITQ[@]}" diff --cached --no-textconv --no-ext-diff)
  veta_binarios "indice (staged)" < <("${GITQ[@]}" diff --cached --numstat)
  escanea_texto "nombres staged" < <("${GITQ[@]}" diff --cached --name-only -z | tr '\0' '\n')
  # no rastreados, NUL-delimitados
  while IFS= read -r -d '' f; do
    escanea_texto "nombre untracked" < <(printf '%s\n' "$f")
    if file -b --mime "$f" 2>/dev/null | grep -qv 'charset=binary'; then
      escanea_texto "untracked $f" < "$f"
    else
      echo "BINARIO VETADO en untracked: $(printf '%s' "$f" | redacta)"; fallos=$((fallos+1))
    fi
  done < <(git ls-files -z -o --exclude-standard)
else
  # La base DEBE existir: un error de base convertido en "sin commits" seria
  # un gate silenciosamente vacio (sugerencia Alta, ronda 5).
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || { echo "probar-antifugas: la base '$BASE' no existe en este repo"; exit 2; }
  commits=$("${GITQ[@]}" rev-list "$BASE"..HEAD)
  if [ -z "$commits" ]; then
    echo "probar-antifugas: sin commits sobre $BASE — nada que escanear"
    exit 0
  fi
  for sha in $commits; do
    # `-m` es OBLIGATORIO (ronda de seguridad, critico 2): sin el, git show
    # de un MERGE emite el diff combinado denso, que OMITE los ficheros cuyo
    # resultado iguala a un padre — un merge que re-introduce un secreto
    # tomando la version del padre lateral es INVISIBLE (rodado: fixture 7).
    # Con -m se emite el diff contra CADA padre y el secreto aparece.
    escanea_texto "commit $sha" < <("${GITQ[@]}" show -m --no-textconv --no-ext-diff "$sha")
    veta_binarios "commit $sha" < <("${GITQ[@]}" show -m --numstat --format= "$sha")
  done
  echo "escaneados $(echo "$commits" | wc -l) commit(s) de la rama"
fi

if [ "$fallos" -gt 0 ]; then
  echo "probar-antifugas: $fallos hallazgo(s). Si el secreto esta en la historia, REHAZ la rama (rebase/squash): taparlo con otro commit no lo saca del PR."
  exit 1
fi
echo "probar-antifugas: LIMPIO"
