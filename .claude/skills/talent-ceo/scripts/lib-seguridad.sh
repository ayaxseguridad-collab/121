#!/usr/bin/env bash
# lib-seguridad.sh — Sondas de seguridad del doctor (talent-ceo, ref 07, issue 9559). La carga doctor.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034 # variables y arrays compartidos con doctor.sh
#
# Node con suelo de parche, sesiones zombi y LiteLLM. Node y zombis son baratos y los mide el doctor normal. La
# búsqueda de LiteLLM es CARA (recorre hogares y contenedores): la hace el modo escritor `doctor.sh --seguridad`
# (cron diario) y la deja SELLADA en el bus; el doctor normal solo LEE ese resultado. Todo es de solo lectura sobre el
# sistema medido: el único fichero que escribe el modo escritor es su resultado, bajo su directorio de estado.
#
# Las órdenes salen de doctor-sondas.tsv, el MISMO fichero del que fases.py escribe las reglas exactas del sudoers.
SEG_R="${TA_SEG_RAIZ:-}"
[[ -z $SEG_R || $SEG_R =~ ^/[A-Za-z0-9_./-]+$ ]] || die2 "TA_SEG_RAIZ no es una ruta absoluta simple"
ZOMBI_S=$((25 * 86400))       # decisión sellada: zombi = claude/codex vivo y más de 25 días sin actividad de tmux
SEG_EDAD_MAX=$((26 * 3600))   # decisión del CEO: un resultado de LiteLLM de más de 26 h es FALLA
SEG_TSV="$HERE/doctor-sondas.tsv"
declare -A SEG_SUELO=() SEG_FILA=() SEG_CONST=()
declare -a SEG_USERS=() SEG_ARGV=() SEG_FILAS=() SEG_ESPERADOS=()
SEG_MSG=''; SEG_PRES=600
SEG_SUDO_MSG='sudo -n no autoriza esta consulta: el sudoers del montaje solo admite consultas exactas y esta sonda no figura en él'
seg_aplica() {
  local m
  [ "${D_READY:-0}" -eq 1 ] || return 1
  for m in "${D_MEMBERS[@]}"; do [ "$m" != talent-channels ] || return 0; done
  return 1
}
# Sin `talent-channels` en el manifiesto de la instancia (una fábrica real siempre lo declara) las sondas no se
# evalúan, pero NUNCA en silencio: una línea AVISO en cada corrida (el AVISO no cierra la puerta ni toca RESUMEN).
check_sondas_alcance() {
  seg_aplica && return 0
  [ "${D_READY:-0}" -ne 1 ] || aviso seguridad sondas 'no se evalúan Node, LiteLLM ni zombis: el manifiesto de la instancia no declara talent-channels'
  return 0
}
# Usuarios locales distintos del propio que declara el perfil (los de otra máquina no se miden desde aquí).
seg_usuarios() {
  local t f maq usr
  SEG_USERS=()
  for t in ceo pm torre estacion canal runner cron; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      perfil_campos "$f"; maq="${PERFIL_CAMPOS[2]-}"
      case "$maq" in ''|'-'|"$LOCAL_ID") : ;; *) continue ;; esac
      usr="$(perfil_attr "${PERFIL_CAMPOS[5]-}" usuario || true)"
      { [ -n "$usr" ] && [ "$usr" != "$YO" ] && usuario_ok "$usr" && id -u "$usr" >/dev/null 2>&1; } || continue
      case " ${SEG_USERS[*]-} " in *" $usr "*) continue ;; esac
      SEG_USERS+=("$usr")
    done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
  done
}

# ── Node: UN solo fichero de suelos, el que lee el golden (talent-channels) ─────────────────────
seg_suelos() { # rc 0 con SEG_SUELO[mayor]=X.Y.Z · rc 1 con SEG_MSG
  local f="$SKILLS/talent-channels/assets/node-suelos.tsv" m v x
  SEG_SUELO=()
  if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then SEG_MSG='node-suelos.tsv ausente, ilegible o symlink'; return 1; fi
  while IFS=$'\t' read -r m v x || [ -n "$m" ]; do
    case "$m" in ''|'#'*) continue ;; esac
    if [[ ! $m =~ ^[0-9]{1,6}$ || ! $v =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || [ "${v%%.*}" != "$m" ] ||
       [ -n "$x" ] || [ -n "${SEG_SUELO[$m]+x}" ]; then
      SEG_MSG='node-suelos.tsv con fila inválida o mayor repetida'; return 1
    fi
    SEG_SUELO[$m]="$v"
  done < "$f"
  [ "${#SEG_SUELO[@]}" -gt 0 ] || { SEG_MSG='node-suelos.tsv sin ningún suelo'; return 1; }
}
seg_node_juzga() { # sujeto salida-de-node-v
  local ver maj min pat suelo fmin fpat
  ver="$(printf '%s' "$2" | tr -d '[:space:]')"; ver="${ver#v}"
  if [[ ! $ver =~ ^([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$ ]]; then
    noverif seguridad-node "$1" 'node -v no devolvió una versión X.Y.Z'; return
  fi
  maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; pat="${BASH_REMATCH[3]}"
  suelo="${SEG_SUELO[$maj]-}"
  # Una mayor sin suelo (la de apt, una EOL) no recibe el parche: FALLA, como el golden y F0.
  if [ -z "$suelo" ]; then falla seguridad-node "$1" "$ver: la mayor $maj no tiene suelo de parche conocido"; return; fi
  IFS=. read -r _ fmin fpat <<< "$suelo"
  if [ "$((10#$min))" -gt "$((10#$fmin))" ] || { [ "$((10#$min))" -eq "$((10#$fmin))" ] && [ "$((10#$pat))" -ge "$((10#$fpat))" ]; }; then
    ok seguridad-node "$1" "$ver >= $suelo"
  else
    falla seguridad-node "$1" "$ver < $suelo"
  fi
}
# Canales/runners declarados que la medida no alcanza o que no existen: nunca en silencio.
seg_canales_alcance() { # categoría
  local x
  for x in "${SEG_C_EXC[@]}"; do noverif "$1" "$x" 'canal excluido de la medida: identidad del canal sin resolver o usuario del canal ilegible'; done
  if [ "${#SEG_C_ID[@]}" -eq 0 ] && [ "${#SEG_C_EXC[@]}" -eq 0 ]; then
    ok "$1" canales 'ningún canal ni runner RUNNING declarado en esta máquina: nada que medir en canales'
  fi
}
check_node() {
  local i
  seg_aplica || return 0
  if ! seg_suelos; then noverif seguridad-node suelos "$SEG_MSG"; return 0; fi
  if ! command -v node >/dev/null 2>&1; then
    noverif seguridad-node host 'no hay node en el PATH del usuario del doctor'
  else
    COMO_TIMEOUT=20 como "" node -v </dev/null
    if [ "$COMO_RC" -ne 0 ]; then noverif seguridad-node host "node -v falló (rc=$COMO_RC)"
    else seg_node_juzga host "$COMO_OUT"; fi
  fi
  seg_canales_alcance seguridad-node
  if [ "${#SEG_C_ID[@]}" -gt 0 ] && ! seg_tsv; then noverif seguridad-node sondas "$SEG_MSG"; return 0; fi
  for i in "${!SEG_C_ID[@]}"; do
    if ! seg_sonda node-canal "${SEG_C_CONT[$i]}" "$CUSER" ''; then noverif seguridad-node "${SEG_C_ID[$i]}" "$SEG_MSG"; continue; fi
    COMO_TIMEOUT=90 como "${SEG_C_USR[$i]}" "${SEG_ARGV[@]}" </dev/null
    if [ "$COMO_SUDO" -eq 1 ]; then noverif seguridad-node "${SEG_C_ID[$i]}" "$SEG_SUDO_MSG"
    elif [ "$COMO_RC" -ne 0 ]; then noverif seguridad-node "${SEG_C_ID[$i]}" "node -v no se pudo medir en el canal (rc=$COMO_RC)"
    else seg_node_juzga "${SEG_C_ID[$i]}" "$COMO_OUT"; fi
  done
}

# ── doctor-sondas.tsv: un campo = un argumento; filas canal/usuario/propio y constantes (const) ──
seg_tsv() { # carga y valida el tsv · rc 1 con SEG_MSG
  local linea id resto amb val
  SEG_FILA=(); SEG_CONST=()
  if [ ! -f "$SEG_TSV" ] || [ -L "$SEG_TSV" ] || [ ! -r "$SEG_TSV" ]; then SEG_MSG='doctor-sondas.tsv ausente, ilegible o symlink'; return 1; fi
  while IFS= read -r linea || [ -n "$linea" ]; do
    case "$linea" in ''|'#'*) continue ;; esac
    id="${linea%%$'\t'*}"; resto="${linea#*$'\t'}"; amb="${resto%%$'\t'*}"; val="${resto#*$'\t'}"
    if [[ ! $id =~ ^[a-z0-9-]+$ ]] || [ "$resto" = "$linea" ] || [ "$amb" = "$resto" ] ||
       { [ "$amb" != canal ] && [ "$amb" != usuario ] && [ "$amb" != propio ] && [ "$amb" != const ]; } ||
       [ -n "${SEG_FILA[$id]+x}" ] || [ -n "${SEG_CONST[$id]+x}" ]; then
      SEG_MSG='doctor-sondas.tsv con fila inválida o id repetido'; return 1
    fi
    if [ "$amb" = const ]; then
      [[ $val =~ ^[0-9]{1,4}$ ]] || { SEG_MSG='doctor-sondas.tsv con constante no numérica'; return 1; }
      SEG_CONST[$id]="$val"
    else SEG_FILA[$id]="$linea"; fi
  done < "$SEG_TSV"
  SEG_PRES="${SEG_CONST[presupuesto-s]-}"
  if [ "${#SEG_FILA[@]}" -eq 0 ] || [ -z "$SEG_PRES" ] || [ "$SEG_PRES" -lt 10 ]; then
    SEG_MSG='doctor-sondas.tsv sin sondas o sin presupuesto-s válido'; return 1
  fi
}
seg_sonda() { # id contenedor cuser hogar → SEG_ARGV (marcadores sustituidos) · rc 1 si la fila falta
  local linea="${SEG_FILA[$1]-}" a
  local -a campos=()
  SEG_ARGV=()
  [ -n "$linea" ] || { SEG_MSG="doctor-sondas.tsv no tiene la fila $1"; return 1; }
  IFS=$'\t' read -r -a campos <<< "$linea"
  for a in "${campos[@]:2}"; do
    a="${a//\{contenedor\}/$2}"; a="${a//\{cuser\}/$3}"; a="${a//\{hogar\}/$4}"; a="${a//\{raiz\}/$SEG_R}"; a="${a//\{presupuesto\}/$SEG_PRES}"
    SEG_ARGV+=("$a")
  done
}
seg_hogar_ok() { [[ ${1-} =~ ^/[A-Za-z0-9_./-]+$ ]]; }
seg_reg() { SEG_FILAS+=("$1"$'\t'"$(printf '%s' "$2" | tr '\t\n' '  ')"$'\t'"$(printf '%s' "$3" | tr '\t\n' '  ')"); }
# inerte() corta cada campo a 200. Un campo que cabe sale ENTERO; si no cabe, se acortan SOLO sus rutas (palabras de más de 60
# caracteres): principio + la mayor cola que quepa. El campo ORIGINAL entero queda en SEG_LARGAS y sale troceado en líneas AVISO.
SEG_LARGAS=(); SEG_AJ=''
seg_ajusta() { # texto máximo → SEG_AJ
  local IFS=' ' o="$1" t="$1" w i f ex c k h ws=()
  SEG_AJ="$t"; [ "${#t}" -gt "$2" ] || return 0
  SEG_LARGAS+=("$o")   # el campo ORIGINAL entero (con sus espacios) para el AVISO, no las palabras
  read -ra ws <<< "$t"; t="${ws[*]}"; ex=$((${#t} - $2))
  for ((f = 0; f < ${#ws[@]} && ${#ws[f]} <= 60; f++)); do :; done   # f = la primera ruta: la que más conserva
  for ((i = ${#ws[@]} - 1; i >= f && ex > 0; i--)); do   # de atrás adelante: lo último (lista de raíces) se acorta primero
    w="${ws[i]}"; [ "${#w}" -gt 60 ] || continue
    c=$((${#w} - (i == f ? 32 : 20))); [ "$c" -le "$ex" ] || c=$ex
    k=$((${#w} - c)); h=25; [ "$k" -ge 60 ] || h=$(((k - 3) / 3))
    ws[i]="${w:0:h}...${w: -$((k - 3 - h))}"; ex=$((ex - c))
  done
  SEG_AJ="${ws[*]}"
  # Ninguna palabra basta: solo si el campo ES una ruta (empieza por /, con espacios) se recorta entero conservando la cola;
  # un detalle no se recorta por la cola: inerte() lo corta por el final y el motivo, que va al principio, sobrevive.
  [ "$ex" -le 0 ] || [[ $o != /* ]] || SEG_AJ="${o:0:25}...${o: -$(($2 - 28))}"
}
seg_avisa() { # id etiqueta texto → líneas AVISO de 170 caracteres («etiqueta: trozo», luego «etiqueta (cont.): trozo»)
  local p="$2" t="$3" n b
  while [ -n "$t" ]; do
    n=170   # nunca parte un carácter UTF-8: retrocede mientras el siguiente byte sea de continuación (0x80-0xBF)
    while [ "$n" -gt 0 ] && [ "${#t}" -gt "$n" ] && b=$(printf '%d' "'${t:n:1}") && [ "$b" -ge 128 ] && [ "$b" -lt 192 ]; do n=$((n - 1)); done
    [ "$n" -gt 0 ] || n=170
    aviso seguridad-litellm "$1" "$p: ${t:0:n}"; t="${t:n}"; p="$2 (cont.)"
  done
}
seg_prof() { [[ ${SEG_ARGV[*]} =~ -maxdepth\ ([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# El sitecustomize.py del sistema se reconoce SOLO por su ruta anclada /usr/lib/python3.N/sitecustomize.py, sin
# comprobar que enlace a /etc: riesgo residual aceptado (CEO, 23-oct-2026; suplantar esa ruta exige root). Cualquier
# otro sitecustomize.py en una librería de Python es FALLA. Es el ÚNICO filtro de sitecustomize.
seg_sc_sistema() { # ruta prefijo-regex
  [[ $1 =~ ^$2/usr/lib/python3(\.[0-9]+)?/sitecustomize\.py$ ]]
}
# Juzga UNA búsqueda (usa COMO_OUT/COMO_RC/COMO_ERR/COMO_SUDO): hallazgos FALLA; cualquier rc ≠ 0 o un canal que no llegó
# a ejecutarla (sin INICIO) es NOVERIF con su motivo; nunca OK sobre una búsqueda que no terminó.
seg_juzga_busqueda() { # sujeto prefijo-del-sistema exige-INICIO(1|0) descripción-de-raíces
  local ruta n=0 ini=0 pfx="${2//./\\.}" base
  local lib='/lib(64)?/(python3(\.[0-9]+t?)?|pypy3(\.[0-9]+)?)/((site|dist)-packages/)?(cook\.pth|cook\.py|litellm-1\.107\.0\.dist-info|sitecustomize\.py)$'
  while IFS= read -r ruta; do
    [ -n "$ruta" ] || continue
    if [ "$ruta" = INICIO ]; then ini=1; continue; fi
    [[ $ruta =~ $lib ]] || continue
    base="${ruta##*/}"
    if [ "$base" != sitecustomize.py ]; then
      seg_reg FALLA "$ruta" "indicador de la puerta trasera de LiteLLM 1.107.0 ($1)"; n=$((n + 1))
    elif ! seg_sc_sistema "$ruta" "$pfx"; then
      seg_reg FALLA "$ruta" "sitecustomize.py ajeno al del sistema ($1)"; n=$((n + 1))
    fi
  done <<< "$COMO_OUT"
  if [ "$COMO_SUDO" -eq 1 ]; then seg_reg NOVERIF "$1" "$SEG_SUDO_MSG"
  elif [ "$3" = 1 ] && [ "$ini" -eq 0 ]; then seg_reg NOVERIF "$1" "la orden no llegó a ejecutarse en el canal (rc=$COMO_RC): ${COMO_ERR:-sin detalle}"
  elif [ "$COMO_RC" -eq 124 ]; then seg_reg NOVERIF "$1" "agotado tras $SEG_PRES s en $4"
  elif [ "$COMO_RC" -ne 0 ]; then seg_reg NOVERIF "$1" "búsqueda incompleta (rc=$COMO_RC): ${COMO_ERR:-sin detalle} [en $4]"
  elif [ "$n" -eq 0 ]; then seg_reg OK "$1" "sin indicadores de LiteLLM ni sitecustomize ajeno en $4"; fi
}
# Una búsqueda de hogar o de sistema ejecutada por el propio usuario del doctor o por otro vía sudo.
seg_busca_directa() { # sujeto usuario fila hogar raíces-para-el-mensaje
  if ! seg_sonda "$3" '' '' "$4"; then seg_reg NOVERIF "$1" "$SEG_MSG"; return; fi
  COMO_NICE=1 COMO_TIMEOUT="$SEG_PRES" como "$2" "${SEG_ARGV[@]}" </dev/null
  seg_juzga_busqueda "$1" "$SEG_R" 0 "$5 (prof. $(seg_prof))"
}
# El barrido completo → SEG_FILAS (una fila «ESTADO TAB sujeto TAB detalle» por sujeto o hallazgo).
seg_barrido() {
  local u i home lock ini fin pres plk lin
  SEG_FILAS=()
  seg_usuarios
  lock="$SEG_R/tmp/remote_code_loader.lock"
  # Toda fila FALLA termina en «(<sujeto>)» con el sujeto medido: el lector la cuenta como cobertura de ese sujeto.
  if [ -e "$lock" ] || [ -L "$lock" ]; then seg_reg FALLA "$lock" 'señuelo del cargador remoto de LiteLLM (host/senuelo)'
  else seg_reg OK host/senuelo 'señuelo ausente'; fi
  seg_busca_directa host/sistema '' litellm-sistema '' "$SEG_R/usr/lib $SEG_R/usr/local/lib $SEG_R/opt"
  home="${HOST_HOME:-$HOME}"
  if seg_hogar_ok "$home"; then seg_busca_directa host '' litellm-usuario "$home" "$home"
  else seg_reg NOVERIF host 'hogar del usuario no verificable'; fi
  for u in "${SEG_USERS[@]}"; do
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    if seg_hogar_ok "$home"; then seg_busca_directa "host/$u" "$u" litellm-usuario "$home" "$home"
    else seg_reg NOVERIF "host/$u" 'hogar del usuario no verificable'; fi
  done
  for u in "${SEG_C_EXC[@]}"; do seg_reg NOVERIF "$u" 'canal excluido de la medida: identidad del canal sin resolver o usuario del canal ilegible'; done
  pres=$((SEG_PRES + 30))   # el tope interno del canal (SEG_PRES) muere primero y deja ver el rc 124 con INICIO
  for i in "${!SEG_C_ID[@]}"; do
    if seg_sonda lock-canal "${SEG_C_CONT[$i]}" "$CUSER" ''; then
      COMO_TIMEOUT="$pres" como "${SEG_C_USR[$i]}" "${SEG_ARGV[@]}" </dev/null
      ini=0; fin=0; plk=0
      while IFS= read -r lin; do
        case "$lin" in INICIO) ini=1 ;; FIN) fin=1 ;; PRESENTE) plk=1 ;; esac
      done <<< "$COMO_OUT"
      if [ "$COMO_SUDO" -eq 1 ]; then seg_reg NOVERIF "${SEG_C_ID[$i]}/senuelo" "$SEG_SUDO_MSG"
      elif [ "$ini" -eq 0 ] || [ "$fin" -eq 0 ]; then seg_reg NOVERIF "${SEG_C_ID[$i]}/senuelo" "comprobación del señuelo incompleta (rc=$COMO_RC): ${COMO_ERR:-sin detalle}"
      elif [ "$plk" -eq 1 ]; then seg_reg FALLA /tmp/remote_code_loader.lock "señuelo del cargador remoto de LiteLLM (${SEG_C_ID[$i]}/senuelo)"
      else seg_reg OK "${SEG_C_ID[$i]}/senuelo" 'señuelo ausente'; fi
    else seg_reg NOVERIF "${SEG_C_ID[$i]}/senuelo" "$SEG_MSG"; fi
    if ! seg_sonda litellm-canal "${SEG_C_CONT[$i]}" "$CUSER" ''; then seg_reg NOVERIF "${SEG_C_ID[$i]}" "$SEG_MSG"; continue; fi
    COMO_TIMEOUT="$pres" como "${SEG_C_USR[$i]}" "${SEG_ARGV[@]}" </dev/null
    seg_juzga_busqueda "${SEG_C_ID[$i]}" '' 1 "/usr/lib /usr/local/lib /opt /home (prof. $(seg_prof))"
  done
  [ "${#SEG_C_ID[@]}" -gt 0 ] || [ "${#SEG_C_EXC[@]}" -gt 0 ] || seg_reg OK canales 'ningún canal ni runner RUNNING declarado en esta máquina: nada que medir en canales'
}

# ── Modo escritor: `doctor.sh --seguridad` (cron diario) ─────────────────────────────────────
# Escribe SOLO $(bus_dir_estado)/seguridad/ultimo.res (0600, directorio 0700, atómico) y un sello SEG-<12 hex del sha
# del resultado> en el bus (la hora la mide bus-sellar.sh). rc 0 = sin hallazgos ni NOVERIF · 1 = los hay · 2 = no puede.
seg_escritor() {
  local dir res tmp sha rol f est id det i2 l n_f=0 n_n=0 n_o=0
  seg_aplica || { echo 'doctor: --seguridad: el manifiesto de la instancia no declara talent-channels; no se mide' >&2; return 2; }
  seg_tsv || { echo "doctor: --seguridad: $SEG_MSG" >&2; return 2; }
  [ -f "$BUS" ] || { echo 'doctor: --seguridad: bus ilegible; no se puede sellar' >&2; return 2; }
  rol="$(perfil_row1 ceo 2>/dev/null | cut -f2)"; nombre_ok "$rol" || { echo 'doctor: --seguridad: el perfil no declara el rol ceo' >&2; return 2; }
  dir="$(bus_dir_estado)/seguridad"; res="$dir/ultimo.res"
  if [ -L "$dir" ] || { [ -e "$dir" ] && { [ ! -d "$dir" ] || [ ! -O "$dir" ] || [ "$(stat -c %a "$dir")" != 700 ]; }; }; then
    echo "doctor: --seguridad: $dir no es un directorio propio 0700" >&2; return 2
  fi
  [ -d "$dir" ] || mkdir -m 700 "$dir" || { echo "doctor: --seguridad: no se pudo crear $dir" >&2; return 2; }
  # Una sola búsqueda a la vez (cron + manual): flock -n sobre $dir/.lock; el descriptor vive hasta que el proceso acaba.
  command -v flock >/dev/null 2>&1 || { echo 'doctor: --seguridad: falta flock (util-linux)' >&2; return 2; }
  [ ! -L "$dir/.lock" ] || { echo "doctor: --seguridad: $dir/.lock es un enlace" >&2; return 2; }
  exec 9>>"$dir/.lock" || { echo "doctor: --seguridad: no se pudo abrir $dir/.lock" >&2; return 2; }
  flock -n 9 || { echo "doctor: --seguridad: ya hay otra búsqueda de seguridad en marcha (bloqueo $dir/.lock); no se lanza una segunda" >&2; return 2; }
  # Con el bloqueo en la mano, un .res.XXXXXX es de una corrida muerta: NO se borra, se aparta (mv) dentro del directorio.
  for f in "$dir"/.res.*; do
    [ -e "$f" ] || continue
    [ -d "$dir/apartado" ] || mkdir -m 700 "$dir/apartado" 2>/dev/null || break
    mv -n -- "$f" "$dir/apartado/${f##*/}.$(date -u +%s).$$" 2>/dev/null || true
  done
  seg_barrido
  for f in "${SEG_FILAS[@]}"; do
    case "${f%%$'\t'*}" in FALLA) n_f=$((n_f + 1)) ;; NOVERIF) n_n=$((n_n + 1)) ;; *) n_o=$((n_o + 1)) ;; esac
  done
  tmp="$(mktemp "$dir/.res.XXXXXX")" || { echo 'doctor: --seguridad: no se pudo crear el temporal' >&2; return 2; }
  { printf '# seguridad medido=%s prof-hogar=6 prof-canal=7 presupuesto=%s sujetos=%s sondas=%s fallas=%s noverif=%s\n' \
      "$(date -u +%s)" "$SEG_PRES" "$((n_o + n_f + n_n))" "$(sha256sum "$SEG_TSV" | cut -c1-16)" "$n_f" "$n_n"
    printf '%s\n' "${SEG_FILAS[@]}"; } > "$tmp"
  # Orden: sha del TEMPORAL → sello en el bus → solo si el sello salió, publicar con mv. Así nunca hay un ultimo.res
  # sin sello a la vista del doctor normal. Un fallo deja el resultado anterior intacto y aparta (mv) el temporal.
  seg_aparta_tmp() { # no se borra nada: el temporal fallido va a $dir/apartado
    [ -d "$dir/apartado" ] || mkdir -m 700 "$dir/apartado" 2>/dev/null || return 0
    mv -n -- "$tmp" "$dir/apartado/${tmp##*/}.$(date -u +%s).$$" 2>/dev/null || true
  }
  chmod 600 "$tmp" || { seg_aparta_tmp; echo 'doctor: --seguridad: no se pudo escribir el resultado' >&2; return 2; }
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
  env TA_BUS="$BUS" TA_PERFIL="$PERFIL" bash "$HERE/bus-sellar.sh" --rol "$rol" --marcador "SEG-${sha:0:12}" >/dev/null ||
    { seg_aparta_tmp; echo 'doctor: --seguridad: el sello en el bus falló; el resultado NO se publica (queda el anterior)' >&2; return 2; }
  mv -f "$tmp" "$res" || { echo 'doctor: --seguridad: sellado, pero no se pudo publicar el resultado' >&2; return 2; }
  for f in "${SEG_FILAS[@]}"; do
    IFS=$'\t' read -r est id det <<< "$f"
    SEG_LARGAS=(); seg_ajusta "$id" 200; i2="$SEG_AJ"; seg_ajusta "$det" 200
    printf '%s seguridad-litellm %s: %s\n' "$est" "$(inerte "$i2")" "$(inerte "$SEG_AJ")"
    for l in "${SEG_LARGAS[@]}"; do seg_avisa ruta-completa 'ruta completa' "$l"; done
  done
  printf 'SEGURIDAD sellado SEG-%s ok=%s falla=%s noverif=%s\n' "${sha:0:12}" "$n_o" "$n_f" "$n_n"
  [ "$n_f" -eq 0 ] && [ "$n_n" -eq 0 ]
}

# ── Doctor normal: LEE el último resultado sellado (no repite la búsqueda) ────────────────────
# Rojo → FALLA · con NOVERIF → FALLA (con su sujeto y raíz) · más de 26 h → FALLA ·
# inexistente o con el sello que no cuadra (sha, sondas distintas) → NOVERIF con su remedio.
seg_sello_hora() { # rol hex12 → epoch del último sello SEG-<hex12> de <rol> en el bus (rc 1 si no hay o no es canónico)
  local ts canon
  ts="$(TA_R="$1" TA_M="SEG-$2]" awk '$2 == "[rol:" && $3 == ENVIRON["TA_R"] "]" && $4 == "[marcador:" && $5 == ENVIRON["TA_M"] { t = $1 } END { if (t != "") print t }' "$BUS" 2>/dev/null)"
  [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  canon="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" && [ "$canon" = "$ts" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null
}
# Los sujetos que el modo escritor mide HOY con este perfil → SEG_ESPERADOS (el lector exige una fila de cada uno).
seg_sujetos_esperados() {
  local u i
  SEG_ESPERADOS=(host/senuelo host/sistema host)
  seg_usuarios
  for u in "${SEG_USERS[@]}"; do SEG_ESPERADOS+=("host/$u"); done
  for u in "${SEG_C_EXC[@]}"; do SEG_ESPERADOS+=("$u"); done
  for i in "${!SEG_C_ID[@]}"; do SEG_ESPERADOS+=("${SEG_C_ID[$i]}" "${SEG_C_ID[$i]}/senuelo"); done
  if [ "${#SEG_C_ID[@]}" -eq 0 ] && [ "${#SEG_C_EXC[@]}" -eq 0 ]; then SEG_ESPERADOS+=(canales); fi
}
# Envoltura: si la lectura del resultado deja un NOVERIF o una FALLA, el directorio de estado COMPLETO sale en SU propia línea (AVISO: no cuenta
# como NOVERIF ni cambia el RESUMEN). En el detalle de cada mensaje no cabe junto al motivo: inerte() corta a 200 y un directorio largo lo desplaza.
check_litellm_resultado() {
  local antes=$((N_NOVERIF + N_FALLA)) rc=0
  _check_litellm_resultado || rc=$?
  [ $((N_NOVERIF + N_FALLA)) -le "$antes" ] || seg_avisa resultado 'directorio completo' "$(bus_dir_estado)/seguridad"
  return "$rc"
}
_check_litellm_resultado() {
  local dir res rol sha hora medido sondas f est id det n_o=0 mal=0 edad nfilas=0 decl x i2
  local -A cub=()
  local rem='ejecutar doctor.sh --seguridad como el usuario CEO'
  seg_aplica || return 0
  if ! seg_tsv; then noverif seguridad-litellm resultado "$SEG_MSG"; return 0; fi
  dir="$(bus_dir_estado)/seguridad"; res="$dir/ultimo.res"
  # El resultado vive en $(bus_dir_estado) (TA_BUS_STATE_DIR, o XDG_RUNTIME_DIR/talent-ceo, que es volátil): un doctor
  # lanzado a mano sin el mismo entorno que el cron busca en otro sitio, y su remedio escribiría una segunda copia.
  rem="$rem y con el MISMO TA_BUS_STATE_DIR"   # el directorio completo va en su propia línea (envoltura de abajo): aquí inerte() lo cortaría a 200
  if [ ! -e "$res" ] && [ ! -L "$res" ]; then noverif seguridad-litellm resultado "no existe el resultado de la búsqueda de LiteLLM; $rem"; return 0; fi
  if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ] || [ "$(stat -c %a "$dir" 2>/dev/null)" != 700 ] ||
     [ -L "$res" ] || [ ! -f "$res" ] || [ ! -O "$res" ] || [ "$(stat -c %a "$res" 2>/dev/null)" != 600 ]; then
    noverif seguridad-litellm resultado "el resultado o su directorio no son propios con modo 0600/0700; $rem"; return 0
  fi
  rol="$(perfil_row1 ceo 2>/dev/null | cut -f2)"
  sha="$(sha256sum "$res" 2>/dev/null | cut -d' ' -f1)"
  if ! hora="$(seg_sello_hora "$rol" "${sha:0:12}")" || [ "$hora" -gt "$NOW" ]; then
    noverif seguridad-litellm resultado "el sha del resultado no tiene sello SEG- válido en el bus; $rem"; return 0
  fi
  medido="$(sed -n '1s/^.* medido=\([0-9]*\) .*$/\1/p' "$res")"; sondas="$(sed -n '1s/^.* sondas=\([0-9a-f]*\) .*$/\1/p' "$res")"
  if [ -z "$medido" ] || [ "$((medido > hora ? medido - hora : hora - medido))" -gt 120 ]; then
    noverif seguridad-litellm resultado "la hora medida del resultado no cuadra con su sello; $rem"; return 0
  fi
  if [ "$sondas" != "$(sha256sum "$SEG_TSV" | cut -c1-16)" ]; then
    noverif seguridad-litellm resultado "el resultado es de otras sondas (doctor-sondas.tsv cambió); $rem"; return 0
  fi
  edad=$((NOW - hora))
  # Cobertura: la cabecera declara tantos sujetos como filas trae, y CADA sujeto actual del perfil tiene la suya (o un
  # hallazgo FALLA que termina en «(<sujeto>)»). Un canal o usuario añadido después del último cron, o un resultado
  # vacío o recortado, no se da por medido.
  decl="$(sed -n '1s/^.* sujetos=\([0-9]*\) .*$/\1/p' "$res")"
  while IFS=$'\t' read -r est id det; do
    [ -n "$est$id" ] || continue
    nfilas=$((nfilas + 1)); cub["${id:-_}"]=1
    if [ "$est" = FALLA ] && [[ $det =~ \(([^()]+)\)$ ]]; then cub["${BASH_REMATCH[1]}"]=1; fi
  done < <(tail -n +2 "$res")
  if [ "$decl" != "$nfilas" ]; then
    noverif seguridad-litellm resultado "la cabecera declara sujetos=${decl:-?} y el resultado trae $nfilas filas (recortado o alterado); $rem"; return 0
  fi
  seg_sujetos_esperados
  for x in "${SEG_ESPERADOS[@]}"; do
    [ -n "${cub[$x]-}" ] && continue
    noverif seguridad-litellm resultado "sujeto $x sin medir en el último resultado; $rem"; mal=1
  done
  if [ "$edad" -gt "$SEG_EDAD_MAX" ]; then falla seguridad-litellm resultado "resultado sellado hace $((edad / 3600)) h (más de 26 h); $rem"; mal=1; fi
  while IFS=$'\t' read -r est id det; do
    case "$est" in
      FALLA) det="$det (resultado sellado hace $((edad / 3600)) h)" ;;
      NOVERIF) det="búsqueda sin completar: $det (resultado sellado hace $((edad / 3600)) h)" ;;
      OK) n_o=$((n_o + 1)); continue ;;
      *) continue ;;
    esac
    SEG_LARGAS=(); seg_ajusta "$id" 200; i2="$SEG_AJ"; seg_ajusta "$det" 200
    falla seguridad-litellm "$i2" "$SEG_AJ"; mal=1
    for x in "${SEG_LARGAS[@]}"; do seg_avisa ruta-completa 'ruta completa' "$x"; done
  done < <(tail -n +2 "$res")
  [ "$mal" -eq 1 ] || ok seguridad-litellm resultado "sellado hace $((edad / 3600)) h $((edad % 3600 / 60)) min: $n_o sujetos sin indicadores (prof. 6 hogares, 7 canales; $SEG_PRES s por sujeto)"
}

# ── Zombis: solo informan (AVISO). Viva = claude o codex descendiente de algún pane de la sesión (por ejecutable) ──
seg_zombi_juzga() { # sujeto salida-de-list-panes salida-de-ps
  local lin pid rest wa sa nombre a n=0 z=0 d
  local -A act=() pids=()
  local -a orden=()
  while IFS= read -r lin; do
    pid="${lin##*|}"; rest="${lin%|*}"; wa="${rest##*|}"; rest="${rest%|*}"; sa="${rest##*|}"; nombre="${rest%|*}"
    [[ -n $nombre && $pid =~ ^[0-9]{1,12}$ && $wa =~ ^[0-9]{1,12}$ && $sa =~ ^[0-9]{1,12}$ ]] || continue
    [ "$((10#$sa))" -le "$NOW" ] && [ "$((10#$wa))" -le "$NOW" ] || continue
    a=$(( 10#$sa > 10#$wa ? 10#$sa : 10#$wa ))
    if [ -z "${act[$nombre]+x}" ]; then orden+=("$nombre"); act[$nombre]=$a
    elif [ "$a" -gt "${act[$nombre]}" ]; then act[$nombre]=$a; fi
    pids[$nombre]="${pids[$nombre]-} $pid"
  done <<< "$2"
  for nombre in "${orden[@]}"; do
    n=$((n + 1))
    printf '%s\n' "$3" | descendientes_comm "${pids[$nombre]}" | grep -qxE 'claude|codex' || continue
    d=$((NOW - ${act[$nombre]}))
    if [ "$d" -gt "$ZOMBI_S" ]; then aviso zombi "$1/$nombre" "$((d / 86400)) d"; z=$((z + 1)); fi
  done
  if [ "$n" -gt 0 ] && [ "$z" -eq 0 ]; then ok zombi "$1" "$n sesiones medidas, ninguna zombi (claude/codex inactivo más de 25 d)"; fi
}
check_zombis() {
  local u i panes ps_out ini x
  seg_aplica || return 0
  if ! seg_tsv; then noverif zombi sondas "$SEG_MSG"; return 0; fi
  seg_usuarios
  if ps_out="$(ps -e -o pid=,ppid=,comm= 2>/dev/null)"; then
    for u in "" "${SEG_USERS[@]}"; do
      if ! seg_sonda panes-usuario '' '' ''; then noverif zombi "${u:-$YO}" "$SEG_MSG"; continue; fi
      COMO_TIMEOUT=20 como "$u" "${SEG_ARGV[@]}" </dev/null
      # rc 1 sin rechazo de sudo = no hay servidor tmux (informativo); rc ≥ 2 (124, 127…) o sudo rechazado = NOVERIF.
      if [ "$COMO_SUDO" -eq 1 ]; then noverif zombi "${u:-$YO}" "$SEG_SUDO_MSG"
      elif [ "$COMO_RC" -ge 2 ]; then noverif zombi "${u:-$YO}" "tmux list-panes no se pudo medir (rc=$COMO_RC): ${COMO_ERR:-sin detalle}"
      elif [ "$COMO_RC" -eq 0 ]; then seg_zombi_juzga "${u:-$YO}" "$COMO_OUT" "$ps_out"; fi
    done
  else
    noverif zombi host 'ps falló: no se pueden medir las sesiones'
  fi
  seg_canales_alcance zombi
  for i in "${!SEG_C_ID[@]}"; do
    if ! seg_sonda panes-canal "${SEG_C_CONT[$i]}" "$CUSER" ''; then noverif zombi "${SEG_C_ID[$i]}" "$SEG_MSG"; continue; fi
    COMO_TIMEOUT=90 como "${SEG_C_USR[$i]}" "${SEG_ARGV[@]}" </dev/null
    ini=0; panes=''
    while IFS= read -r x; do if [ "$x" = INICIO ]; then ini=1; else panes+="$x"$'\n'; fi; done <<< "$COMO_OUT"
    if [ "$COMO_SUDO" -eq 1 ]; then noverif zombi "${SEG_C_ID[$i]}" "$SEG_SUDO_MSG"; continue; fi
    if [ "$ini" -eq 0 ] || [ "$COMO_RC" -ge 2 ]; then
      noverif zombi "${SEG_C_ID[$i]}" "tmux list-panes no se pudo medir en el canal (rc=$COMO_RC): ${COMO_ERR:-sin detalle}"; continue
    fi
    [ "$COMO_RC" -eq 0 ] || continue
    if ! seg_sonda ps-canal "${SEG_C_CONT[$i]}" "$CUSER" ''; then noverif zombi "${SEG_C_ID[$i]}" "$SEG_MSG"; continue; fi
    COMO_TIMEOUT=90 como "${SEG_C_USR[$i]}" "${SEG_ARGV[@]}" </dev/null
    if [ "$COMO_RC" -ne 0 ]; then noverif zombi "${SEG_C_ID[$i]}" 'ps del canal falló: no se pueden medir sus sesiones'
    else seg_zombi_juzga "${SEG_C_ID[$i]}" "$panes" "$COMO_OUT"; fi
  done
}
