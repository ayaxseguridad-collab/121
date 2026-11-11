#!/usr/bin/env bash
# Doctor de desvío: datos literales, consultas acotadas y ningún acto de reparación.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2004,SC2016 # Arrays asociativos del llamador y código literal para bash hijo.

desvio_remedios() {
  local f="$1" cat gravedad volver extra
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  while IFS=$'\t' read -r cat gravedad volver extra || [ -n "$cat" ]; do
    case "$cat" in ''|'#'*) continue ;; esac
    [[ $cat =~ ^[a-z][a-z.-]*$ ]] || return 1
    case "$gravedad" in alta|media|baja) : ;; *) return 1 ;; esac
    [ -n "$volver" ] && [ -z "$extra" ] && [ -z "${D_VOLVER[$cat]+x}" ] || return 1
    D_GRAVEDAD[$cat]="$gravedad"; D_VOLVER[$cat]="$volver"
  done < "$f"
}

desvio_md() {
  local v
  v="$(inerte "$1")"; v="${v//&/\&amp;}"; v="${v//</\&lt;}"; v="${v//>/\&gt;}"
  v="${v//|/\&#124;}"; v="${v//\\/\&#92;}"; v="${v//\`/\&#96;}"
  printf '%s' "$v"
}

desvio_informe() {
  if [ "$N_FALLA" -eq 0 ] && [ "$N_NOVERIF" -eq 0 ]; then
    printf 'Sin desviaciones.\n'
  else
    printf '| desviación | gravedad | cómo volver |\n|---|---|---|\n'
    printf '%s\n' "${D_FILAS[@]}"
  fi
}

desvio_ruta() {
  # Los tokens nunca son entradas verificables del núcleo, ni siquiera en un manifiesto adulterado.
  case "/$1/" in */.env.local/*) return 1 ;; esac
  [[ $1 =~ ^[A-Za-z0-9._/-]+$ ]] && [[ ! $1 =~ (^|/)\.\.?(/|$) ]] &&
    [[ $1 != /* && $1 != *//* ]]
}

desvio_sha() { # Manifiesto no vacío, rutas confinadas y únicas; nunca sha256sum -c sobre datos ajenos.
  local f="$1" sha ruta
  D_SHA=()
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  awk 'length($1)!=64 || $1~/[^0-9a-f]/ || NF!=2 || substr($0,65,2)!="  " {bad=1}
       END {exit (bad || NR==0)}' "$f" || return 1
  while read -r sha ruta || [ -n "$sha$ruta" ]; do
    desvio_ruta "$ruta" && [ -z "${D_SHA[$ruta]+x}" ] || return 1
    D_SHA[$ruta]="$sha"
  done < "$f"
}

desvio_manifest() { # Parser de P2 aislado: pkg_die2 nunca termina el doctor.
  local mf="$1" datos tipo valor
  datos="$(
    # shellcheck source=/dev/null
    . "$D_ROOT/scripts/paquete/lib-package.sh"
    pkg_parse_manifest "$mf"
    printf 'version\t%s\n' "$PKG_VERSION"
    printf 'member\t%s\n' "${PKG_MEMBERS[@]}"
    if [ "${#PKG_OVERLAY_EXACT[@]}" -gt 0 ]; then printf 'overlay\t%s\n' "${PKG_OVERLAY_EXACT[@]}"; fi
    if [ "${#PKG_OVERLAY_PREFIX[@]}" -gt 0 ]; then printf 'prefix\t%s\n' "${PKG_OVERLAY_PREFIX[@]}"; fi
  )" 2>/dev/null || return 1
  D_MEMBERS=(); D_OVERLAY=(); D_PREFIX=(); D_VERSION=''
  while IFS=$'\t' read -r tipo valor; do
    case "$tipo" in
      version) D_VERSION="$valor" ;;
      member) D_MEMBERS+=("$valor") ;;
      overlay) D_OVERLAY+=("$valor") ;;
      prefix) D_PREFIX+=("$valor") ;;
    esac
  done <<< "$datos"
  [ -n "$D_VERSION" ] && [ "${#D_MEMBERS[@]}" -gt 0 ]
}

desvio_overlay() {
  local rel="${1#skills/}" e
  rel="${rel/\//:}"
  for e in "${D_OVERLAY[@]}"; do [ "$rel" != "$e" ] || return 0; done
  for e in "${D_PREFIX[@]}"; do [[ $rel != "$e"* ]] || return 0; done
  return 1
}

desvio_guardas_datos() {
  local ruta amb motivo extra
  D_GUARDAS=()
  [ -f "$HERE/doctor-guardas.tsv" ] && [ -r "$HERE/doctor-guardas.tsv" ] || return 1
  while IFS=$'\t' read -r ruta amb motivo extra || [ -n "$ruta" ]; do
    case "$ruta" in ''|'#'*) continue ;; esac
    desvio_ruta "$ruta" && [ -n "$motivo" ] && [ -z "$extra" ] &&
      [ -z "${D_GUARDAS[$ruta]+x}" ] || return 1
    case "$amb" in paquete|ambos) : ;; *) return 1 ;; esac
    D_GUARDAS[$ruta]="$amb"
  done < "$HERE/doctor-guardas.tsv"
  [ "${#D_GUARDAS[@]}" -gt 0 ]
}

desvio_init() {
  local dir
  local -A conf=()
  D_ROOT="${TA_PAQUETE:-${TF_ROOT:-}}"; D_READY=0; D_CORE=0; D_GUARD_READY=0
  D_PUBLIC=0; D_DECLARADA=0; D_PVERSION=''; D_SOURCE=''
  if [ -z "$D_ROOT" ]; then
    leer_conf "${SECRET_DIR:-${HOST_HOME:-$HOME}/.config/talent-channel-operation}/agents.conf" conf agents &&
      D_ROOT="${conf[TF_ROOT]-}"
  fi
  case "$D_ROOT" in /*) : ;; *) return ;; esac
  D_ROOT="$(realpath -e -- "$D_ROOT" 2>/dev/null)" || return
  [ -r "$D_ROOT/scripts/paquete/lib-package.sh" ] || return
  dir="$(
    # shellcheck source=/dev/null
    . "$D_ROOT/scripts/paquete/lib-package.sh"
    pkg_dir_de "$SKILLS"
  )" || return
  desvio_manifest "$dir/package.manifest" || return
  D_READY=1
  desvio_sha "$D_ROOT/instalacion/NUCLEO.sha256" && D_CORE=1
  desvio_guardas_datos && D_GUARD_READY=1
}

desvio_publicado() {
  local fila fuente url autoridad datos
  fuente=''
  fila="$(perfil_row1 ceo 2>/dev/null || true)"
  if [ -n "$fila" ]; then
    perfil_campos "$fila"; fuente="$(perfil_attr "${PERFIL_CAMPOS[5]-}" paquete_publicado || true)"
  fi
  fuente="${TA_PAQUETE_PUBLICADO-$fuente}"
  [ -n "$fuente" ] || return 0
  D_DECLARADA=1
  command -v unzip >/dev/null 2>&1 || return 1
  case "$fuente" in
    /*) [ -f "$fuente" ] && [ -r "$fuente" ] && [ ! -L "$fuente" ] || return 1; D_SOURCE="$fuente" ;;
    https://*)
      # No redirecciones ni credenciales, tampoco secretos en consulta o fragmento.
      [[ $fuente != *[[:cntrl:][:space:]]* && $fuente != *'?'* && $fuente != *'#'* ]] || return 1
      url="${fuente#https://}"; autoridad="${url%%/*}"
      [[ $autoridad =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || return 1
      command -v curl >/dev/null 2>&1 || return 1
      D_SOURCE="$D_TMP/publicado.zip"
      curl --fail --silent --show-error --proto '=https' --max-time 15 --max-filesize 33554432 \
        --output "$D_SOURCE" "$fuente" 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  # Solo dos nombres fijos: jamás se extrae el ZIP ni se ejecuta lo que contiene.
  unzip -p "$D_SOURCE" talent-factory/scripts/paquete/package.manifest > "$D_TMP/publicado.manifest" 2>/dev/null || return 1
  unzip -p "$D_SOURCE" talent-factory/instalacion/NUCLEO.sha256 > "$D_TMP/publicado.sha256" 2>/dev/null || return 1
  datos="$(
    # shellcheck source=/dev/null
    . "$D_ROOT/scripts/paquete/lib-package.sh"
    pkg_parse_manifest "$D_TMP/publicado.manifest"
    printf '%s' "$PKG_VERSION"
  )" 2>/dev/null || return 1
  # Valida el manifiesto publicado en un subshell para conservar la autoridad local.
  (desvio_sha "$D_TMP/publicado.sha256") || return 1
  D_PVERSION="$datos"; D_PUBLIC=1
}

check_version() {
  [ "$D_READY" -eq 1 ] || { noverif version paquete 'NO MEDIDO: paquete o manifiesto de instancia ilegible'; return; }
  desvio_publicado || { noverif version publicado 'NO MEDIDO: fuente declarada rechazada o ilegible'; return; }
  if [ "$D_DECLARADA" -eq 0 ]; then
    printf 'AVISO version-no-medida: NO MEDIDO; sin fuente publicada declarada\n'; return
  fi
  if [ "$D_VERSION" = "$D_PVERSION" ]; then ok version paquete "AL DÍA: $D_VERSION"
  elif [ "$(printf '%s\n%s\n' "$D_VERSION" "$D_PVERSION" | sort -V | head -n1)" = "$D_VERSION" ]; then
    falla version paquete "ATRASADA: instalada $D_VERSION, publicada $D_PVERSION"
  else
    falla version paquete "instalada $D_VERSION posterior a la publicada $D_PVERSION; revisar autoridad"
  fi
}

desvio_compara() { # ruta física, entrada relativa; acumula en el eje, máximo tres ejemplos.
  local f="$1" rel="$2" sha
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then D_AUS=$((D_AUS+1)); desvio_ejemplo "$rel (ausente)"
  elif [ ! -f "$f" ] || [ -L "$f" ]; then D_DIST=$((D_DIST+1)); desvio_ejemplo "$rel (tipo)"
  elif [ ! -r "$f" ] || ! sha="$(sha256sum -- "$f" 2>/dev/null)"; then D_NO=$((D_NO+1)); desvio_ejemplo "$rel (ilegible)"
  elif [ "${sha%% *}" != "${D_SHA[$rel]}" ]; then D_DIST=$((D_DIST+1)); desvio_ejemplo "$rel"
  fi
}
desvio_ejemplo() {
  if [ "$D_NPRIMEROS" -lt 3 ]; then D_PRIMEROS+="${D_PRIMEROS:+, }$1"; D_NPRIMEROS=$((D_NPRIMEROS+1)); fi
}
desvio_contadores() { D_DIST=0; D_AUS=0; D_NO=0; D_NPRIMEROS=0; D_PRIMEROS=''; }
desvio_resultado() {
  local eje="$1"
  if [ "$D_NO" -gt 0 ]; then noverif "$eje" paquete "$D_NO ficheros ilegibles (primeros: $D_PRIMEROS)"
  elif [ "$D_DIST" -gt 0 ] || [ "$D_AUS" -gt 0 ]; then
    falla "$eje" paquete "$D_DIST ficheros distintos, $D_AUS ausentes (primeros: $D_PRIMEROS)"
  else ok "$eje" paquete 'contenido íntegro según manifiesto'; fi
}

check_nucleo() {
  local rel sha actual esperado
  [ "$D_READY" -eq 1 ] && [ "$D_CORE" -eq 1 ] && [ "$D_GUARD_READY" -eq 1 ] || {
    noverif nucleo paquete 'raíz, manifiesto de núcleo o lista de guardas ilegible'; return; }
  desvio_contadores
  if [ "$D_PUBLIC" -eq 1 ] && [ "$D_VERSION" = "$D_PVERSION" ]; then
    actual="$(sha256sum -- "$D_ROOT/instalacion/NUCLEO.sha256")" || D_NO=$((D_NO+1))
    esperado="$(sha256sum -- "$D_TMP/publicado.sha256")" || D_NO=$((D_NO+1))
    if [ "${actual%% *}" != "${esperado%% *}" ]; then D_DIST=$((D_DIST+1)); desvio_ejemplo instalacion/NUCLEO.sha256; fi
  fi
  while read -r sha rel || [ -n "$sha$rel" ]; do
    [ -z "${D_GUARDAS[$rel]+x}" ] || continue
    desvio_overlay "$rel" && continue
    desvio_compara "$D_ROOT/$rel" "$rel"
    if [ "$SKILLS" != "$D_ROOT/skills" ]; then
      case "$rel" in skills/*) desvio_compara "$SKILLS/${rel#skills/}" "$rel" ;; esac
    fi
  done < "$D_ROOT/instalacion/NUCLEO.sha256"
  desvio_resultado nucleo
}

check_miembros() {
  local m faltan=''
  [ "$D_READY" -eq 1 ] || { noverif miembros paquete 'paquete o manifiesto de instancia ilegible'; return; }
  for m in "${D_MEMBERS[@]}"; do
    if [ ! -f "$SKILLS/$m/SKILL.md" ] || [ -L "$SKILLS/$m/SKILL.md" ]; then faltan+="${faltan:+, }$m"; fi
  done
  if [ -n "$faltan" ]; then falla miembros instancia "miembros sin SKILL.md: $faltan"
  else ok miembros instancia "${#D_MEMBERS[@]} miembros declarados presentes; skills propios admitidos"; fi
}

check_modelos_rol() {
  local t fila usr referencia='' propietario='' usuarios="$YO" distintos='' no='' par rol anterior nuevo leido fallo
  # La misma biblioteca que se comprueba es la que ejecuta la consulta y la que autoriza el sudoers.
  local lib="$SKILLS/talent-channel-operation/scripts/lib-modelos.sh"
  [ "$D_READY" -eq 1 ] && [ -r "$lib" ] || { noverif modelos-rol paquete 'librería de modelos no localizable'; return; }
  for t in ceo torre estacion; do
    while IFS= read -r fila; do
      [ -n "$fila" ] || continue
      perfil_campos "$fila"; [ "${PERFIL_CAMPOS[2]-}" = "$LOCAL_ID" ] || continue
      usr="$(perfil_attr "${PERFIL_CAMPOS[5]-}" usuario || true)"; usr="${usr:-$YO}"
      usuarios+=$'\n'"$usr"
    done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
  done
  # Un registro heredado del entorno no debe desviar la lectura del usuario propio.
  # Se conserva existencia, valor y atributo de exportación para restaurarlos tal cual.
  local reg_def=0 reg_val='' reg_exp=0 reg_attr
  reg_attr="$(declare -p TCO_MODELOS_REGISTRO 2>/dev/null || true)"
  if [ -n "${TCO_MODELOS_REGISTRO+x}" ]; then
    reg_def=1; reg_val="$TCO_MODELOS_REGISTRO"
    reg_attr="${reg_attr#declare }"; reg_attr="${reg_attr%% *}"
    case "$reg_attr" in *x*) reg_exp=1 ;; esac
  fi
  unset TCO_MODELOS_REGISTRO
  while IFS= read -r usr; do
    usuario_ok "$usr" || { no+=" usuario inválido"; continue; }
    # Misma orden que autoriza el montaje (sudoers), una llamada por rol: solo cambia $2.
    leido=''; fallo=0
    for rol in ceo plan replan fallback coding audit coordinador merge salud; do
      # shellcheck disable=SC2016 # Código literal para el proceso del propietario.
      como "$usr" bash -c '. "$1"; tco_modelo_read "$2"' _ "$lib" "$rol"
      if [ "$COMO_RC" -ne 0 ] || [ -z "$COMO_OUT" ]; then fallo=1; break; fi
      leido+="$rol=$COMO_OUT;"
    done
    COMO_OUT="$leido"
    if [ "$fallo" -ne 0 ]; then no+=" $usr"; continue; fi
    if [ -z "$referencia" ]; then referencia="$COMO_OUT"; propietario="$usr"
    elif [ "$referencia" != "$COMO_OUT" ]; then
      for par in ${COMO_OUT//;/ }; do
        rol="${par%%=*}"; nuevo="${par#*=}"
        anterior="${referencia#*"$rol="}"; anterior="${anterior%%;*}"
        if [ "$anterior" != "$nuevo" ]; then
          distintos="$rol: $propietario=$anterior, $usr=$nuevo"; break
        fi
      done
    fi
  done < <(printf '%s\n' "$usuarios" | sort -u)
  if [ "$reg_def" -eq 1 ]; then
    TCO_MODELOS_REGISTRO="$reg_val"
    if [ "$reg_exp" -eq 1 ]; then export TCO_MODELOS_REGISTRO; fi
  fi
  if [ -n "$no" ]; then noverif modelos-rol usuarios "registros no comprobables:$no"
  elif [ -n "$distintos" ]; then falla modelos-rol usuarios "$distintos"
  else ok modelos-rol usuarios 'roles ceo/plan/replan/fallback/coding/audit/coordinador/merge/salud iguales; formato vigente OPUS_MODEL/SONNET_MODEL/RESOLVED_UTC/CLI_VERSION'; fi
}

check_guardas() {
  local rel amb clon hooks rc
  [ "$D_READY" -eq 1 ] && [ "$D_CORE" -eq 1 ] && [ "$D_GUARD_READY" -eq 1 ] || {
    noverif guardas paquete 'raíz, manifiesto de núcleo o lista de guardas ilegible'; return; }
  desvio_contadores
  while IFS=$'\t' read -r rel amb _; do
    case "$rel" in ''|'#'*) continue ;; esac
    if [ -z "${D_SHA[$rel]+x}" ]; then D_NO=$((D_NO+1)); desvio_ejemplo "$rel (sin sha)"; continue; fi
    desvio_compara "$D_ROOT/$rel" "$rel"
    if [ "$amb" = ambos ]; then
      case "$rel" in skills/*) desvio_compara "$SKILLS/${rel#skills/}" "$rel" ;; esac
    fi
  done < "$HERE/doctor-guardas.tsv"
  # En la distribución todavía no hay clon. En una instancia .claude, el hook debe estar activo.
  if [ "$(basename "$(dirname "$SKILLS")")" = .claude ]; then
    clon="$(dirname "$(dirname "$SKILLS")")"
    rc=127; hooks=''
    if command -v git >/dev/null 2>&1; then
      hooks="$(git -C "$clon" config --get core.hooksPath 2>/dev/null)"; rc=$?
    fi
    if [ "$rc" -gt 1 ]; then
      D_NO=$((D_NO+1)); desvio_ejemplo 'core.hooksPath (no comprobable)'
    elif [ "$rc" -eq 1 ] || [ "$hooks" != .githooks ]; then D_DIST=$((D_DIST+1)); desvio_ejemplo core.hooksPath; fi
    if [ -z "${D_SHA[githooks/pre-push]+x}" ]; then D_NO=$((D_NO+1))
    else desvio_compara "$clon/.githooks/pre-push" githooks/pre-push; fi
    if [ -e "$clon/.githooks/pre-push" ] && [ ! -x "$clon/.githooks/pre-push" ]; then
      D_DIST=$((D_DIST+1)); desvio_ejemplo '.githooks/pre-push (no ejecutable)'
    fi
  fi
  desvio_resultado guardas
}

check_doctor_extra() {
  local f funcion registrado dir="$HERE/doctor.d"
  local -a DOCTOR_EXTRA=()
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    falla doctor.d extension 'directorio de extensiones ilegible o inválido'; return
  fi
  # Inventario comprobado antes de cargar; un fallo no puede aparentar directorio vacío.
  if ! find "$dir" -mindepth 1 -maxdepth 1 -name '[0-9][0-9]-*.sh' -print0 > "$D_TMP/extensiones" 2>/dev/null ||
     ! LC_ALL=C sort -z "$D_TMP/extensiones" > "$D_TMP/extensiones-ordenadas"; then
    falla doctor.d extension 'inventario de extensiones no comprobable'; return
  fi
  while IFS= read -r -d '' f; do
    if [ ! -f "$f" ] || [ ! -r "$f" ] || [ -L "$f" ] || ! bash -n "$f" 2>/dev/null; then
      falla doctor.d extension 'extensión ilegible o con error de sintaxis'; continue
    fi
    DOCTOR_EXTRA=()
    # Código versionado de extensión, nunca configuración de la instancia.
    # shellcheck source=/dev/null
    if ! source "$f"; then falla doctor.d extension 'error al cargar extensión'; continue; fi
    if [ "${#DOCTOR_EXTRA[@]}" -eq 0 ]; then falla doctor.d extension 'extensión sin comprobaciones registradas'; continue; fi
    if [ -e "${f%.sh}.volver.tsv" ] && ! desvio_remedios "${f%.sh}.volver.tsv"; then
      falla doctor.d extension 'tabla de remedios inválida'; continue
    fi
    for funcion in "${DOCTOR_EXTRA[@]}"; do
      if [[ ! $funcion =~ ^check_[a-zA-Z0-9_]+$ ]] || ! declare -F "$funcion" >/dev/null; then
        falla doctor.d extension 'función registrada inválida'; continue
      fi
      registrado=$((N_OK+N_FALLA+N_NOVERIF))
      if ! "$funcion"; then falla doctor.d extension 'comprobación devolvió error'; fi
      if [ "$registrado" -eq $((N_OK+N_FALLA+N_NOVERIF)) ]; then falla doctor.d extension 'comprobación no emitió resultado'; fi
    done
  done < "$D_TMP/extensiones-ordenadas"
}
