#!/usr/bin/env bash
# shellcheck disable=SC2143  # S6: [ -n "$(grep…)" ] deliberado — `| grep -q` ES el bug (SIGPIPE+pipefail → falso pass)
# verificar.sh <SNAPSHOT-DIR> <CORPUS-DIR> <CAMBIOS.tsv> — S3/S5/S6 + mundo cerrado.
# Fail-closed en todo: entradas ausentes/malformadas → exit 2 con motivo;
# cualquier check en rojo → exit 1. Exit 0 SOLO con todo verde.
#
# Gramatica del TSV (separador TAB, exactamente 3 columnas):
#   fila de fichero: <ruta> TAB <modo> TAB <descriptor>
#     modo: intacto | solo-adicion | alta | semantico:{anulacion|fusion|alias-stub|indice}
#     descriptor: '-' para intacto y semantico:indice; para el resto, ruta a fichero:
#       solo-adicion        → el bloque anadido EXACTO (linea a linea)
#       alta                → el fichero NUEVO completo (byte a byte, item 8)
#       semantico:anulacion → linea 1: fragmento literal de la linea muerta
#       semantico:fusion    → una clausula preservada por linea (todas deben aparecer)
#       semantico:alias-stub→ linea 1: slug/nombre de la nota sucesora
#       semantico:indice    → '-' (el fichero indice se verifica con sus filas INDEX)
#   fila de indice:  INDEX TAB <one-liner-nuevo> TAB <one-liner-viejo>
# Rutas con espacios: soportadas (el TAB separa). Un TAB o salto de linea DENTRO
# de una ruta no es representable en esta gramatica → fila con !=3 columnas → exit 2.
# Descriptor: NUNCA symlink/hardlink al fichero del corpus, ni dentro del propio
# corpus (anti-circularidad por identidad de fichero, item 8) → exit 2.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ $# -eq 3 ] || tm_die "uso: verificar.sh <snapshot-dir> <corpus-dir> <cambios-declarados.tsv>"
SNAP="$1"; CORPUS="$2"; TSV="$3"
[ -d "$SNAP" ]   || tm_die "no existe el snapshot-dir: $SNAP"
[ -d "$CORPUS" ] || tm_die "no existe el corpus-dir: $CORPUS"
# ruta FISICA del corpus (tecnica de salvaguarda.sh): la usa el guard
# anti-circularidad de descriptores (item 8, mas abajo)
CORPUS_REAL="$(cd "$CORPUS" && pwd -P)"
[ -f "$TSV" ]    || tm_die "no existe el fichero de cambios declarados: $TSV"
[ -f "$SNAP/manifest.txt" ] || tm_die "snapshot-dir sin manifest.txt (¿salio de salvaguarda.sh?)"
# un snapshot-dir con VARIOS tars es un baseline ambiguo: elegir uno en silencio
# podria verificar contra la salvaguarda equivocada (fail-closed)
TARS_N="$(find "$SNAP" -maxdepth 1 -name 'snapshot-*.tar.gz' | wc -l)"
[ "$TARS_N" -ge 1 ] || tm_die "snapshot-dir sin snapshot-*.tar.gz"
[ "$TARS_N" -eq 1 ] || tm_die "snapshot-dir con $TARS_N snapshot-*.tar.gz (baseline ambiguo, fail-closed): $SNAP"
TAR="$(find "$SNAP" -maxdepth 1 -name 'snapshot-*.tar.gz')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. parsear el TSV (fail-closed) -----------------------------------------
DECL_PATHS="$WORK/decl_paths"; : > "$DECL_PATHS"
DECL_DELTA="$WORK/decl_delta"; : > "$DECL_DELTA"
ROWS="$WORK/rows"; : > "$ROWS"
IDX_ROWS="$WORK/idx_rows"; : > "$IDX_ROWS"
ln=0
while IFS= read -r line || [ -n "$line" ]; do
  ln=$((ln+1))
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  ncols="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  [ "$ncols" -eq 3 ] || tm_die "TSV linea $ln: $ncols columnas (deben ser 3; ¿TAB dentro de una ruta?)"
  c1="$(printf '%s' "$line" | cut -f1)"
  c2="$(printf '%s' "$line" | cut -f2)"
  c3="$(printf '%s' "$line" | cut -f3)"
  if [ "$c1" = "INDEX" ]; then
    printf '%s\n' "$line" >> "$IDX_ROWS"
    continue
  fi
  ruta="${c1#./}"
  # las rutas del TSV son SIEMPRE relativas al corpus: una absoluta o con
  # travesia '..' verificaria ficheros FUERA del corpus (fail-closed)
  case "/$ruta/" in
    //*|*/../*) tm_die "TSV linea $ln: ruta absoluta o con travesia '..' (fuera del corpus): '$c1'";;
  esac
  printf '%s\n' "$c2" | grep -qE "^($TM_MODOS)\$" || tm_die "TSV linea $ln: modo invalido '$c2'"
  grep -qFx -- "$ruta" "$DECL_PATHS" && tm_die "TSV linea $ln: ruta duplicada '$ruta'"
  printf '%s\n' "$ruta" >> "$DECL_PATHS"
  [ "$c2" != "intacto" ] && printf '%s\n' "$ruta" >> "$DECL_DELTA"
  # gramatica estricta del descriptor: intacto y semantico:indice exigen '-'
  # EXACTO (el indice se verifica con sus filas INDEX); el resto exige un
  # fichero descriptor existente y NO VACIO (un descriptor vacio verificaria nada)
  if [ "$c2" = "intacto" ] || [ "$c2" = "semantico:indice" ]; then
    [ "$c3" = "-" ] || tm_die "TSV linea $ln: el modo '$c2' exige descriptor '-' (tiene '$c3')"
    # semantico:indice SOLO tiene sentido sobre el propio fichero indice: S6 (mas
    # abajo) verifica UNICAMENTE $CORPUS/$TM_INDEX_FILE, asi que declarar este modo
    # sobre otra ruta la marcaria tm_ok sin que nadie la comprobara jamas (fail-closed)
    [ "$c2" != "semantico:indice" ] || [ "$ruta" = "$TM_INDEX_FILE" ] \
      || tm_die "TSV linea $ln: 'semantico:indice' solo aplica a '$TM_INDEX_FILE' (tiene '$ruta')"
  else
    [ -f "$c3" ] || tm_die "TSV linea $ln: descriptor no existe: $c3"
    # anti-circularidad por IDENTIDAD DE FICHERO, no de directorio (item 8): un
    # descriptor "externo" que sea symlink o hardlink al fichero del corpus (o
    # que viva DENTRO del corpus) deja un diff/grep comparando el mismo inodo
    # consigo mismo — critico para 'alta', que hace diff fichero-completo.
    [ -L "$c3" ] && tm_die "TSV linea $ln: descriptor es un symlink (fail-closed): $c3"
    [ -e "$CORPUS/$ruta" ] && [ "$c3" -ef "$CORPUS/$ruta" ] \
      && tm_die "TSV linea $ln: descriptor es el MISMO fichero (hardlink/identidad) que '$ruta' (fail-closed): $c3"
    C3_PADRE_REAL="$(cd "$(dirname "$c3")" 2>/dev/null && pwd -P)" \
      || tm_die "TSV linea $ln: no puedo resolver el directorio del descriptor: $c3"
    C3_REAL="$C3_PADRE_REAL/$(basename "$c3")"
    case "$C3_REAL/" in
      "$CORPUS_REAL"/*) tm_die "TSV linea $ln: descriptor vive DENTRO del corpus (fail-closed): $c3";;
    esac
    grep -qE '[^[:space:]]' "$c3" || tm_die "TSV linea $ln: descriptor VACIO: $c3 (fail-closed: no hay nada que verificar)"
    # los modos que consumen la 1a linea del descriptor como PATRON de busqueda
    # no toleran que ESA linea este en blanco: el guard de arriba solo exige un
    # no-blanco en CUALQUIER sitio del fichero, asi que un descriptor que empieza
    # por linea vacia lo pasa y deja el patron VACIO — y `grep -F ""` matchea
    # TODAS las lineas, con lo que el guard correspondiente (texto muerto
    # ausente / sucesora no referenciada) NUNCA dispararia: falso PASS sobre un
    # borrado append-only, justo lo que este verificador existe para cazar.
    case "$c2" in
      semantico:anulacion|semantico:alias-stub)
        head -1 "$c3" | grep -qE '[^[:space:]]' || tm_die "TSV linea $ln: el modo '$c2' exige que la 1a linea del descriptor NO este en blanco: $c3 (fail-closed: patron de busqueda vacio)";;
    esac
  fi
  printf '%s\t%s\t%s\n' "$ruta" "$c2" "$c3" >> "$ROWS"
done < "$TSV"

# symlinks: fuera del inventario de find -type f → un retarget seria invisible
# para el mundo cerrado. Fail-closed antes de verificar nada.
tm_no_symlinks "$CORPUS"

tm_say "VERIFICACION — $CORPUS contra $SNAP"

# --- 2. conjunto REAL de deltas (manifiestos de ambos lados) ------------------
tm_manifest "$CORPUS" > "$WORK/manifest_now"
# manifiesto -> "ruta<TAB>hash" normalizado (ruta sin ./), ordenado
norm() { sed 's/^\([0-9a-f]*\) [ *]\.\//\1\t/' "$1" | awk -F'\t' '{print $2 "\t" $1}' | sort; }
norm "$SNAP/manifest.txt" > "$WORK/antes"
norm "$WORK/manifest_now" > "$WORK/ahora"
cut -f1 "$WORK/antes" > "$WORK/antes_paths"
cut -f1 "$WORK/ahora" > "$WORK/ahora_paths"
# altas, bajas, modificados
comm -13 "$WORK/antes_paths" "$WORK/ahora_paths" > "$WORK/altas"
comm -23 "$WORK/antes_paths" "$WORK/ahora_paths" > "$WORK/bajas"
join -t "$(printf '\t')" "$WORK/antes" "$WORK/ahora" 2>/dev/null | \
  awk -F'\t' '$2 != $3 {print $1}' > "$WORK/modificados"
cat "$WORK/altas" "$WORK/bajas" "$WORK/modificados" | sort -u > "$WORK/real_delta"
sort -u "$DECL_DELTA" > "$WORK/decl_delta_sorted"

# --- 3. MUNDO CERRADO: real == declarado (modo != intacto) --------------------
while IFS= read -r p; do
  [ -n "$p" ] && tm_fail "mundo cerrado: '$p' cambio/aparecio/desaparecio y NO esta declarado"
done < <(comm -23 "$WORK/real_delta" "$WORK/decl_delta_sorted")
while IFS= read -r p; do
  [ -n "$p" ] && tm_fail "mundo cerrado: '$p' esta declarado como cambio pero NO cambio (¿pasada a medias o TSV desactualizado?)"
done < <(comm -13 "$WORK/real_delta" "$WORK/decl_delta_sorted")
[ "$TM_FALLOS" -eq 0 ] && tm_ok "mundo cerrado: los deltas reales ($(wc -l < "$WORK/real_delta" | tr -d ' ')) coinciden con lo declarado"

# --- 4. checks por fila -------------------------------------------------------
snap_cat() { tar -xzOf "$TAR" "./$1" 2>/dev/null; }
while IFS=$'\t' read -r ruta modo desc; do
  case "$modo" in
    intacto)
      # ruta EXACTA sobre el manifiesto ya normalizado ($WORK/antes, "ruta<TAB>hash"):
      # grep -F -- "./$ruta" podia casar la linea de OTRO fichero (un directorio
      # cuyo nombre acaba en '.' hace que "./a./nota.md" contenga "./nota.md").
      h_antes="$(awk -F'\t' -v r="$ruta" '$1==r{print $2; exit}' "$WORK/antes")"
      h_ahora="$( (cd "$CORPUS" && tm_sha "./$ruta" 2>/dev/null) | awk '{print $1}')"
      if [ -z "$h_antes" ]; then tm_fail "intacto '$ruta': no estaba en el snapshot"
      elif [ "$h_antes" = "$h_ahora" ]; then tm_ok "intacto '$ruta' (hash identico)"
      else tm_fail "intacto '$ruta': el hash CAMBIO"; fi
      ;;
    solo-adicion)
      if ! snap_cat "$ruta" > "$WORK/old" ; then tm_fail "solo-adicion '$ruta': no estaba en el snapshot"; continue; fi
      if [ ! -f "$CORPUS/$ruta" ]; then tm_fail "solo-adicion '$ruta': desaparecio del corpus"; continue; fi
      diff "$WORK/old" "$CORPUS/$ruta" > "$WORK/d" ; rc=$?
      if [ "$rc" -gt 1 ]; then tm_fail "solo-adicion '$ruta': error de diff (rc=$rc)"; continue; fi
      if grep -q '^<' "$WORK/d"; then tm_fail "solo-adicion '$ruta': hay lineas ELIMINADAS (S5)"; continue; fi
      grep '^>' "$WORK/d" | sed 's/^> //' > "$WORK/anadido"
      if diff -q "$WORK/anadido" "$desc" >/dev/null 2>&1; then
        tm_ok "solo-adicion '$ruta' (lo anadido == bloque declarado)"
      else
        tm_fail "solo-adicion '$ruta': lo anadido NO coincide con el bloque declarado (S5)"
      fi
      ;;
    alta)
      # ALTA declarada (item 8): fichero NUEVO — el placeholder del paso 5 pasa a
      # ser verificable. (1) NO debe estar en el snapshot (si esta, es reescritura
      # disfrazada de alta); (2) debe existir en el corpus; (3) COMPLETO == descriptor.
      h_snap="$(awk -F'\t' -v r="$ruta" '$1==r{print $2; exit}' "$WORK/antes")"
      if [ -n "$h_snap" ]; then tm_fail "alta '$ruta': YA estaba en el snapshot (es una reescritura, no un alta)"; continue; fi
      if [ ! -f "$CORPUS/$ruta" ]; then tm_fail "alta '$ruta': no existe en el corpus"; continue; fi
      if diff -q "$CORPUS/$ruta" "$desc" >/dev/null 2>&1; then
        tm_ok "alta '$ruta' (fichero nuevo == bloque declarado)"
      else
        tm_fail "alta '$ruta': el contenido NO coincide con el descriptor declarado"
      fi
      ;;
    semantico:anulacion)
      f="$CORPUS/$ruta"
      frag="$(head -1 "$desc")"
      if [ ! -f "$f" ]; then tm_fail "anulacion '$ruta': el fichero no existe"; continue; fi
      # La marca es el BLOQUE COMPLETO, no una palabra suelta en prosa (item 4):
      # apertura acotada a TM_ESTADOS_ANULACION (ALIAS-STUB/PENDIENTE tienen
      # contrato propio) + fecha ISO valida y delimitada + motivo real + los
      # campos del bloque (Linea muerta/Linea vigente/4o campo) con payload y
      # correlacionados con el descriptor y con S3. El estado en el description
      # NO cuenta como marca: S3 es un check separado — solo-description es una
      # nota disfrazada de anulada.
      ini="$(tm_body_start "$f")"
      apertura="$(tm_anulacion_apertura "$f" "$ini")"
      if [ -z "$apertura" ]; then
        tm_fail "anulacion '$ruta': sin marca de estado EN EL CUERPO (¿solo en description?)"; continue
      fi
      nl="$(printf '%s' "$apertura" | cut -f1)"
      estado="$(printf '%s' "$apertura" | cut -f2)"
      linea_apertura="$(sed -n "${nl}p" "$f")"
      l_frag="$(grep -nF -- "$frag" "$f" | grep -vE "^[0-9]+:>" | awk -F: -v ini="$ini" '!hit && $1>=ini{print $1; hit=1}')"
      if [ -z "$l_frag" ]; then tm_fail "anulacion '$ruta': la linea muerta declarada no aparece (¿se borro? append-only)"; continue; fi
      if [ "$nl" -ge "$l_frag" ]; then tm_fail "anulacion '$ruta': la marca esta DESPUES del texto muerto (gotcha 2)"; continue; fi
      if ! printf '%s' "$linea_apertura" | grep -qE "$TM_RE_FECHA_ISO"; then
        tm_fail "anulacion '$ruta': apertura sin fecha ISO valida"; continue
      fi
      resto="$(printf '%s' "$linea_apertura" | sed -E "s/^>[[:space:]]*//; s/^($TM_ESTADOS_ANULACION)//; s/$TM_RE_FECHA_ISO//")"
      if ! printf '%s' "$resto" | grep -qE '[[:alnum:]]{3}'; then
        tm_fail "anulacion '$ruta': apertura sin motivo real"; continue
      fi
      bloque="$(tm_anulacion_bloque "$f" "$nl")"
      if ! tm_anulacion_campo "$bloque" "L(i|í)nea muerta"; then
        tm_fail "anulacion '$ruta': bloque incompleto (falta 'Linea muerta:' con payload)"; continue
      fi
      linea_muerta="$(tm_anulacion_linea_etiqueta "$bloque" "L(i|í)nea muerta")"
      if ! printf '%s' "$linea_muerta" | grep -qF -- "$frag"; then
        tm_fail "anulacion '$ruta': la cita de 'Linea muerta' no correlaciona con el fragmento del descriptor"; continue
      fi
      if ! tm_anulacion_campo "$bloque" "L(i|í)nea vigente"; then
        tm_fail "anulacion '$ruta': bloque incompleto (falta 'Linea vigente:' con payload)"; continue
      fi
      campo4="Autoridad"; [ "$estado" = "ACOTADA" ] && campo4="Alcance residual"
      if ! tm_anulacion_campo "$bloque" "$campo4"; then
        tm_fail "anulacion '$ruta': bloque incompleto (falta '$campo4:' con payload)"; continue
      fi
      estado_desc="$(tm_s3_estado "$f")"
      if [ -z "$estado_desc" ]; then
        tm_fail "anulacion '$ruta': description sin estado (S3)"
      elif [ "$estado_desc" != "$estado" ]; then
        tm_fail "anulacion '$ruta': el token del cuerpo ('$estado') no coincide con el de description ('$estado_desc')"
      else
        tm_ok "anulacion '$ruta' (marca corporal antes del texto muerto + S3)"
      fi
      ;;
    semantico:fusion)
      f="$CORPUS/$ruta"; faltan=0; leidas=0
      if [ ! -f "$f" ]; then tm_fail "fusion '$ruta': el fichero no existe"; continue; fi
      while IFS= read -r clausula || [ -n "$clausula" ]; do
        [ -z "$clausula" ] && continue
        leidas=$((leidas+1))
        grep -qF -- "$clausula" "$f" || { tm_fail "fusion '$ruta': clausula perdida: \"$clausula\""; faltan=$((faltan+1)); }
      done < "$desc"
      if [ "$leidas" -eq 0 ]; then tm_fail "fusion '$ruta': descriptor sin clausulas (fail-closed)"
      elif [ "$faltan" -eq 0 ]; then tm_ok "fusion '$ruta' ($leidas clausulas preservadas)"; fi
      ;;
    semantico:indice)
      f="$CORPUS/$ruta"
      if [ ! -f "$f" ]; then tm_fail "indice '$ruta': el fichero no existe"; continue; fi
      if [ ! -s "$IDX_ROWS" ]; then
        tm_fail "indice '$ruta': declarado como semantico:indice pero SIN filas INDEX que lo verifiquen (S6)"
      else
        tm_ok "indice '$ruta' (se verifica con sus filas INDEX, abajo)"
      fi
      ;;
    semantico:alias-stub)
      f="$CORPUS/$ruta"
      sucesora="$(head -1 "$desc")"
      if [ ! -f "$f" ]; then tm_fail "alias-stub '$ruta': el fichero no existe"; continue; fi
      ok=1
      # marca y sucesora EN EL CUERPO (solo-description = stub disfrazado, M1)
      [ -n "$(tm_body_first_match "$f" 'ALIAS-STUB')" ] || { tm_fail "alias-stub '$ruta': sin marca ALIAS-STUB en el cuerpo"; ok=0; }
      ini="$(tm_body_start "$f")"
      # Sustitucion de comando, no `| grep -q`: con -q el grep sale al primer match y
      # el awk aun escribiendo recibe SIGPIPE (141) — bajo pipefail el rc del pipeline
      # seria 141 EN EL MATCH y dispararia el fail justo cuando la referencia SI esta.
      [ -n "$(awk -v ini="$ini" 'NR>=ini' "$f" | grep -F -- "$sucesora")" ] || { tm_fail "alias-stub '$ruta': el cuerpo no referencia a la sucesora '$sucesora'"; ok=0; }
      tm_s3_ok "$f"              || { tm_fail "alias-stub '$ruta': description sin estado (S3)"; ok=0; }
      [ "$ok" -eq 1 ] && tm_ok "alias-stub '$ruta' (marca corporal + sucesora + S3)"
      ;;
  esac
done < "$ROWS"

# --- 5. S6: filas INDEX por contenido ----------------------------------------
IDX="$CORPUS/$TM_INDEX_FILE"
if [ -s "$IDX_ROWS" ]; then
  if [ ! -f "$IDX" ]; then
    tm_fail "S6: hay filas INDEX pero no existe $TM_INDEX_FILE en el corpus"
  else
    while IFS= read -r line; do
      nuevo="$(printf '%s' "$line" | cut -f2)"
      viejo="$(printf '%s' "$line" | cut -f3)"
      if ! grep -F -x -q -- "$nuevo" "$IDX"; then
        tm_fail "S6: el one-liner nuevo NO esta (exacto) en el indice: \"$nuevo\""
      # La busqueda del viejo EXCLUYE la linea exacta del nuevo: un alias-stub o un
      # reencuadre legitimo CITA el nombre viejo dentro del one-liner nuevo, y sin
      # esta exclusion el check fallaria en verde ajeno (falso "viejo SIGUE").
      # Sustitucion de comando en vez de `| grep -q`: bajo pipefail, el -q cierra el
      # pipe al primer match y el SIGPIPE (141) del grep -v hacia FALSO PASS con
      # indices grandes (el viejo presente caia al tm_ok). Sin -q el grep lee TODO
      # el input: no hay early-exit, no hay SIGPIPE, y el veredicto es el contenido.
      elif [ -n "$(grep -F -x -v -- "$nuevo" "$IDX" | grep -F -- "$viejo")" ]; then
        tm_fail "S6: el one-liner viejo SIGUE en el indice: \"$viejo\""
      else
        tm_ok "S6 indice: nuevo presente, viejo ausente"
      fi
    done < "$IDX_ROWS"
  fi
fi

# --- veredicto ----------------------------------------------------------------
tm_say "VEREDICTO"
if [ "$TM_FALLOS" -eq 0 ]; then
  printf '  OK — cambio exactamente lo declarado, nada mas.\n'; exit 0
else
  printf '  FALLO — %s check(s) en rojo. NO se arregla a mano: restaurar del snapshot y repetir la pasada.\n' "$TM_FALLOS"
  exit 1
fi
