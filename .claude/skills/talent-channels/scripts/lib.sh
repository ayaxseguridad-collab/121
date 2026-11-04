#!/usr/bin/env bash
# lib.sh — helpers comunes del skill talent-channels. Se "source-ea".
# Contrato de secretos: umask 077, set +x alrededor de secretos, nunca imprimir valores,
# escritura 0600 en $SECRET_DIR, limpieza de temporales con trap.
# shellcheck shell=bash

tc_say()  { printf '\n==== %s ====\n' "$*"; }
tc_info() { printf '  %s\n' "$*"; }
tc_err()  { printf 'ERROR: %s\n' "$*" >&2; }
tc_warn() { printf '  ⚠️  AVISO: %s\n' "$*" >&2; }
tc_die()  { tc_err "$*"; exit 1; }

# Ejecuta en un contenedor como root.
tc_cexec() { incus exec "$1" -- bash -lc "$2"; }
# Ejecuta en un contenedor como el usuario del carril.
tc_cuser() { incus exec "$1" -- su - "$CUSER" -c "$2"; }

# Espera a que el contenedor tenga systemd listo.
tc_wait_container() {
  local n="$1"
  for _ in $(seq 1 60); do
    incus exec "$n" -- systemctl is-system-running >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Espera salida real a internet (TCP, no solo DNS) desde un contenedor.
tc_wait_net() {
  local n="$1"
  for _ in $(seq 1 60); do
    incus exec "$n" -- bash -c 'timeout 4 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null' && return 0
    sleep 2
  done
  return 1
}

# Asegura el directorio de escrow (0700).
tc_secret_dir() { mkdir -p "$SECRET_DIR" && chmod 700 "$SECRET_DIR"; }

# Pide un secreto sin eco, valida (regex opcional), lo escribe 0600 en $SECRET_DIR/<file>.
# Uso: tc_prompt_secret <file> "mensaje" [regex] [required:yes|no]
# NUNCA imprime el valor. Si ya existe, lo conserva (borrar el archivo para re-preguntar).
tc_prompt_secret() {
  local file="$1" msg="$2" regex="${3:-}" required="${4:-yes}" dest="$SECRET_DIR/$1" val
  tc_secret_dir
  # [-e], no [-s]: un opcional dejado en blanco crea archivo VACÍO a propósito (respuesta
  # "no tengo") — con [-s] ese marcador nunca pasaría y el prompt se repetiría en cada re-run.
  # tc_have_secret sigue usando [-s]: para los consumidores, vacío == "no hay secreto".
  if [ -e "$dest" ]; then tc_info "$file: ya presente (conservado)"; return 0; fi
  set +x
  ( umask 077
    while :; do
      read -rsp "  $msg: " val; echo
      if [ -z "$val" ]; then
        [ "$required" = "no" ] && { : > "$dest"; chmod 600 "$dest"; break; }
        echo "  (requerido)"; continue
      fi
      if [ -n "$regex" ] && ! printf '%s' "$val" | grep -qE "$regex"; then
        echo "  (formato inválido)"; continue
      fi
      printf '%s' "$val" > "$dest"; chmod 600 "$dest"; break
    done )
  unset val
  tc_info "$file: guardado en \$SECRET_DIR (0600)"
}

# Lee un secreto a stdout (uso interno; el llamador NO debe imprimirlo).
tc_read_secret() { cat "$SECRET_DIR/$1" 2>/dev/null; }
# ¿Existe y no vacío?
tc_have_secret() { [ -s "$SECRET_DIR/$1" ]; }

# Push de un archivo a un contenedor y reaplica owner+perm (para secretos).
# Uso: tc_push_secret_file <host_src> <carril> <dest_in_container> [mode]
tc_push_secret_file() {
  local src="$1" n="$2" dst="$3" mode="${4:-600}"
  incus file push "$src" "$n$dst" >/dev/null
  incus exec "$n" -- chown "$CUSER:$CUSER" "$dst"
  incus exec "$n" -- chmod "$mode" "$dst"
}

# >>> TF-PROC-SNIPPET v2 — quiescencia por EJECUTABLE (TAL-8042). Copia IDÉNTICA en
# talent-channels/scripts/{lib.sh,auth-move-lib.sh} y talent-channel-operation/scripts/lib.sh
# («duplicar antes que acoplar», TAL-5507); la paridad la asserta talent-channels/tests/run-tests.sh.
# Corre DENTRO del endpoint (bash -c): jamás casa la línea de comandos (el viejo `-f` alcanzaba
# `~/.codex`, `--agent codex`, `tee codex.log` y al lector de stdout del propio MOVE → SIGPIPE tras
# DONE). Un proceso es el agente si el basename de su argv[0] O su `comm` casa, ANCLADO, la ERE dada.
# Zombis fuera (estado Z/X). Protegidos (jamás se les envía señal): ancestros, grupo y sesión de `$$`
# + los PID declarados por el caller; un protegido que SÍ es el agente cuenta como VIVO (falla cerrado).
# Sin comillas simples en el cuerpo (se embebe en un `bash -c '…'`).
read -r -d '' TC_PROC_SNIPPET <<'TF_PROC_EOF' || true
_tf_prot() { # usuario → PID protegidos (ancestros + grupo + sesión de $$); rc 2 = error de enumeración
  local u="$1" p="$$" line rest st ppid pgrp sid out=" " q mypg mysid pids rc
  line="$(cat "/proc/$$/stat" 2>/dev/null)" || return 2
  rest="${line##*) }"; read -r st ppid mypg mysid _ <<< "$rest"
  while [ "${p:-0}" -gt 1 ] 2>/dev/null; do
    out="$out$p "
    line="$(cat "/proc/$p/stat" 2>/dev/null)" || return 2
    rest="${line##*) }"; read -r st ppid pgrp sid _ <<< "$rest"
    p="$ppid"
  done
  pids="$(pgrep -u "$u" 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  for q in $pids; do
    line="$(cat "/proc/$q/stat" 2>/dev/null)" || { [ ! -d "/proc/$q" ] && continue; return 2; }
    rest="${line##*) }"; read -r st ppid pgrp sid _ <<< "$rest"
    if [ "$pgrp" = "$mypg" ] || [ "$sid" = "$mysid" ]; then out="$out$q "; fi
  done
  printf "%s" "$out"
}
_tf_identity() { # PID → identidad; rc 4 = terminal Z/X comprobado, rc 2 = ilegible
  local p="$1" line rest uid exe file
  line="$(cat "/proc/$p/stat" 2>/dev/null)" || return 2
  rest="${line##*) }"
  set -- $rest
  [ "$#" -ge 20 ] || return 2
  case "$1" in Z|X) return 4 ;; esac
  uid="$(stat -c "%u" "/proc/$p" 2>/dev/null)" || return 2
  exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || return 2
  file="$(stat -Lc "%d:%i" "/proc/$p/exe" 2>/dev/null)" || return 2
  [ -n "$exe" ] || return 2
  printf "%s:%s:%s:%q" "${20}" "$uid" "$file" "$exe"
}
_tf_agent_scan() { # usuario ERE → PID TAB identidad VIVOS; rc 2 = error o ERE inválida
  local u="$1" re="$2" pids rc p line rest st c a n m identity confirmed identity_rc
  [ -n "$u" ] && [ -n "$re" ] || return 2
  # Validar incluso sin procesos ni nombres legibles.
  rc=0; [[ "" =~ ^($re)$ ]] || rc=$?
  [ "$rc" -le 1 ] || return 2
  pids="$(pgrep -u "$u" 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  for p in $pids; do
    line="$(cat "/proc/$p/stat" 2>/dev/null)" || { [ ! -d "/proc/$p" ] && continue; return 2; }
    rest="${line##*) }"; st="${rest%% *}"
    case "$st" in Z|X) continue ;; esac
    # Conservar la lectura previa al nombre, pero exigirla solo si casa.
    identity_rc=0; identity="$(_tf_identity "$p")" || identity_rc=$?
    { [ "$identity_rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && continue
    # read hasta NUL/EOF conserva espacios y saltos; quitar SOLO el terminador de proc.
    c=""; { IFS= read -r -d "" c < "/proc/$p/comm"; } 2>/dev/null || [ -n "$c" ] || { [ ! -d "/proc/$p" ] && continue; return 2; }
    c="${c%?}"
    a=""; { IFS= read -r -d "" a < "/proc/$p/cmdline"; } 2>/dev/null || true
    a="${a##*/}"
    for n in "$c" "$a"; do
      [ -n "$n" ] || continue
      m=0; [[ $n =~ ^($re)$ ]] || m=$?
      case "$m" in
        0) confirmed="$(_tf_identity "$p")" || { rc=$?; { [ "$rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && break; return 2; }
           [ "$identity_rc" -eq 0 ] || return 2
           [ "$identity" = "$confirmed" ] || return 2
           printf "%s\t%s\n" "$p" "$identity"; break ;;
        1) ;;
        *) return 2 ;;
      esac
    done
  done
  return 0
}
_tf_quiet() { # usuario ERE → rc 0 SOLO si no queda ningún proceso del agente (error de enumeración = NO quieto)
  local m
  m="$(_tf_agent_scan "$1" "$2")" || return 1
  [ -z "$m" ]
}
_tf_kill_wait() { # usuario ERE [timeout_s=12] [PID-protegidos-extra] → 0 limpio · 1 timeout con agente vivo · 3 error
  local u="$1" re="$2" to="${3:-12}" extra="${4:-}" prot m p end identity current tab rc changed=0
  prot="$(_tf_prot "$u")" || return 3
  prot=" $prot $extra "
  m="$(_tf_agent_scan "$u" "$re")" || return 3
  tab="$(printf "\t")"
  while IFS="$tab" read -r p identity; do
    [ -n "$p" ] || continue
    case "$prot" in *" $p "*) continue ;; esac
    # Recalcular protecciones y acreditar la misma encarnación inmediatamente antes de la señal.
    prot="$(_tf_prot "$u")" || return 3
    prot=" $prot $extra "
    case "$prot" in *" $p "*) continue ;; esac
    current="$(_tf_identity "$p")" || { rc=$?; { [ "$rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && continue; current=""; }
    if [ -z "$identity" ] || [ "$current" != "$identity" ]; then
      printf "quiesce: PID %s cambió o no es legible; sin señal\n" "$p" >&2
      changed=1; continue
    fi
    kill -9 "$p" 2>/dev/null || true
  done <<< "$m"
  [ "$changed" -eq 0 ] || return 3
  end=$(( $(date +%s) + to ))
  while :; do
    m="$(_tf_agent_scan "$u" "$re")" || return 3
    [ -z "$m" ] && return 0
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.5
  done
}
TF_PROC_EOF
# <<< TF-PROC-SNIPPET

# Mata TODOS los procesos del AGENTE <ejecutable> del usuario <cuser> en el carril <n> y ESPERA (poll con
# timeout) a que no quede ninguno. rc 0 = el carril quedó sin ese agente; rc 1 = algún agente sobrevive al
# timeout (el caller NO debe relanzar: el alias entraría en la TUI vieja); rc 3 = error de enumeración
# (fail-closed: NO se declara limpio). Reemplaza el `pgrep|head -1`+`sleep` fijo (CR #549).
# TAL-8042: casa el EJECUTABLE (basename de argv[0] o comm), JAMÁS la línea de comandos: el viejo patrón
# sobre el argv completo alcanzaba `~/.codex`, `--agent codex`, `tee codex.log` y al lector de stdout del
# propio MOVE. <ejecutable> es un NOMBRE de binario (`codex`, `claude`), no un patrón (inválido → rc 3).
# Protegidos (jamás se les envía señal): ancestros, grupo y sesión del shell que corre el kill + los PID
# espacio-separados de <extra_excl> (declaración EXPLÍCITA del caller); un protegido que SÍ es el agente
# cuenta como VIVO (rc 1: falla cerrado). Mismo snippet que `am_ep_quiesce` (copia idéntica, ver arriba).
tc_kill_wait() { # carril ejecutable cuser [timeout_s=12] [extra_excl_pids]
  local n="$1" exe="$2" u="$3" to="${4:-12}" excl="${5:-}"
  [[ "$exe" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || { tc_err "tc_kill_wait: ejecutable inválido '$exe' (se espera un nombre de binario, no un patrón)"; return 3; }
  incus exec "$n" -- bash -c "$TC_PROC_SNIPPET
_tf_kill_wait \"\$1\" \"\$2\" \"\$3\" \"\$4\"; exit \$?" _ "$u" "$exe" "$to" "$excl"
}

# Confirmación destructiva: exige re-teclear exactamente el texto esperado.
# Uso: tc_confirm_exact "/dev/sdX" "Escribe el device exacto para FORMATEAR"
tc_confirm_exact() {
  local expected="$1" msg="$2" got
  read -rp "  $msg ($expected): " got
  [ "$got" = "$expected" ]
}

# ===========================================================================
# [TAL-2630] Verificación de IDENTIDAD/PERFIL por canal (defensa en profundidad)
# ---------------------------------------------------------------------------
# El "perfil" de un canal (produccion | mergeador | runner) es GROUND-TRUTH
# DECLARADA (no se infiere de la presencia del secreto — eso sería circular):
#   - mapa de escrow $SECRET_DIR/channel-profiles.list  (líneas `canal=perfil`)
#   - overrides ad-hoc por entorno TC_MERGEADOR_CHANNELS / TC_RUNNER_CHANNELS
# Contra esa expectativa se VALIDA la credencial EFECTIVA presente (fail-closed):
# identidad md5 del env operacional + rutas de auth canónicas — NUNCA grep de
# texto del árbol del repo (el checkout contiene `sbp_`/`cr-`/`CODERABBIT_API_KEY`
# como catálogo/código: `assets/creds.manifest`, `push-carril-env.sh`, `.env.example`).
# Contrato de secretos: nunca se imprime un valor; los md5 se calculan DENTRO del
# contenedor y solo cruza el digest hex (patrón de refresh-claude-auth.sh).
# ===========================================================================

# Fichero-mapa de perfiles de ESTA fábrica (en su SECRET_DIR, por-fábrica).
tc_channel_profiles_file() { printf '%s/channel-profiles.list' "$SECRET_DIR"; }

# ¿está <word> en la lista <list> separada por espacios/saltos? (membresía exacta)
_tc_word_in() {
  local w="$1" list="${2:-}" x
  for x in $list; do [ "$x" = "$w" ] && return 0; done
  return 1
}

# Perfil DECLARADO en el mapa para <canal> (vacío si no está). Parseo textual
# estricto: primera línea `^<canal>=<perfil>`, sin `source`/`eval`. Un perfil
# fuera del enum se emite tal cual (el llamador lo trata como inválido).
_tc_profile_from_map() {
  local ch="$1" f line v
  f="$(tc_channel_profiles_file)"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    case "$line" in "$ch="*) v="${line#*=}"; v="${v%%[[:space:]]*}"; printf '%s' "$v"; return 0;; esac
  done < "$f"
  return 0
}

# Perfil ESPERADO de <canal>: combina mapa + overrides de entorno con resolución de conflictos
# FAIL-CLOSED. Emite:
#   `invalid`    — perfil corrupto en el mapa o perfiles DISTINTOS declarados por >1 fuente;
#   `undeclared` — sin declaración alguna (ni mapa ni override): NO se asume `produccion` (produccion
#                  es lenient con gh/claude/codex bajo /home/$CUSER, así que un runner sin declarar
#                  pasaría con esos artefactos bajo /home/runner) → el llamador EXIGE declaración explícita;
#   produccion|mergeador|piloto|runner — la declaración única ([TAL-5142] `piloto` = canal de LAB A2A,
#                  MISMAS reglas de verificación que `mergeador`).
# El intake y el rollout siembran TODOS los canales (incl. los de producción) en channel-profiles.list.
tc_expected_profile() {
  local ch="$1" mapv asserted=""
  mapv="$(_tc_profile_from_map "$ch")"
  case "$mapv" in
    ''|produccion|mergeador|piloto|runner) ;;
    *) printf 'invalid'; return 0;;   # perfil corrupto en el mapa → fail-closed
  esac
  # La declaración EXPLÍCITA del mapa participa en el conflicto SEA CUAL SEA su valor (incl.
  # `produccion`): así `mapa=produccion` + `override=mergeador` colisiona → invalid, y un canal de
  # producción con credencial colada no se "reclasifica" silenciosamente.
  [ -n "$mapv" ] && asserted="$asserted $mapv"
  _tc_word_in "$ch" "${TC_MERGEADOR_CHANNELS:-}" && asserted="$asserted mergeador"
  _tc_word_in "$ch" "${TC_RUNNER_CHANNELS:-}"    && asserted="$asserted runner"
  # perfiles DISTINTOS asertados por >1 fuente → conflicto → invalid (fail-closed)
  local uniq; uniq="$(printf '%s\n' $asserted | sort -u | grep -c .)"
  if [ "$uniq" -gt 1 ]; then printf 'invalid'; return 0; fi
  if [ "$uniq" -eq 1 ]; then printf '%s' "$(printf '%s\n' $asserted | sort -u | head -1)"; return 0; fi
  printf 'undeclared'   # sin declaración → fail-closed (el llamador lo trata como FALLO)
}

# Canales de ESTA fábrica realmente presentes en Incus (ground-truth de EXISTENCIA).
# Acotado por MACHINE_NUM (no todo el PREFIX del host: cada fábrica tiene su config).
# rc≠0 = no se pudo enumerar (incus caído / MACHINE_NUM vacío) → el llamador FALLA cerrado.
tc_list_real_channels() {
  [ -n "${MACHINE_NUM:-}" ] || return 1
  local out filtered rc
  out="$(incus list -f csv -c n 2>/dev/null)" || return 1
  # grep rc: 0 = hay matches · 1 = sin matches (fábrica vacía, legítimo) · >1 = ERROR (regex/pipe) →
  # FAIL-CLOSED (NO `|| true`, que convertiría un error en "enumeración vacía exitosa" y verify.sh
  # podría declarar "no hay contenedores" y OMITIR todo el gate).
  filtered="$(printf '%s\n' "$out" | sed 's/,.*//' | grep -E "^${PREFIX}${MACHINE_NUM}[0-9]+$")"; rc=$?
  [ "$rc" -le 1 ] || return 1
  printf '%s' "$filtered"
  return 0
}

# Conjunto ESPERADO por config (para reconciliar contra los reales), acotado a la
# fábrica: 1..COUNT ∪ basenames de env del escrow ∪ canales del mapa/overrides.
# rc≠0 = el filtro de scope falló (error de grep) → el llamador FALLA cerrado (no reconciliar contra
# un conjunto esperado incompleto).
tc_expected_channel_set() {
  local raw filtered rc
  raw="$( { [ -n "${COUNT:-}" ] && tc_channels 2>/dev/null
    local f b line
    for f in "$SECRET_DIR"/env/*.env; do [ -e "$f" ] || continue; b="$(basename "$f" .env)"; printf '%s\n' "$b"; done
    f="$(tc_channel_profiles_file)"
    if [ -f "$f" ]; then while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue;; esac
      printf '%s\n' "${line%%=*}"
    done < "$f"; fi
    printf '%s\n' ${TC_MERGEADOR_CHANNELS:-} ${TC_RUNNER_CHANNELS:-}; } )"
  # grep rc: 0 matches · 1 sin matches (legítimo) · >1 error → FAIL-CLOSED (sin `|| true`).
  filtered="$(printf '%s\n' "$raw" | sort -u | grep -E "^${PREFIX}${MACHINE_NUM}[0-9]+$")"; rc=$?
  [ "$rc" -le 1 ] || return 1
  printf '%s' "$filtered"
  return 0
}

# Ruta del env operacional (el que el tokens-loader del .bashrc auto-exporta) en <home>.
_tc_op_env_path() { printf '%s/%s/%s' "$1" "$REPO_DIR" "$ENV_DEST"; }

# ¿Existe (y es no vacío) el fichero canónico <path> en el canal? 0 sí · 1 no · 2 error(fail-closed).
_tc_file_present() {
  incus exec "$1" -- test -s "$2" 2>/dev/null
  case $? in 0) return 0;; 1) return 1;; *) return 2;; esac
}

# Homes reales del contenedor (/home/* + /root) por RUTA (no texto). Salida separada por espacios.
# rc≠0 = no se pudo enumerar (contenedor caído / ls con error) → el llamador FALLA cerrado.
_tc_homes() {
  local ch="$1" users u out="/root"
  users="$(incus exec "$ch" -- ls /home 2>/dev/null)" || return 1
  for u in $users; do out="$out /home/$u"; done
  printf '%s' "$out"
}

# ¿Asignación EFECTIVA (no comentada, valor no vacío que casa <valregex>, tolerando UNA comilla
# envolvente KEY="…"/'…') de <KEY> en el env operacional del canal bajo /home/$CUSER? Se inspecciona
# SOLO ese fichero (no el árbol) → docs/plantillas del repo excluidas por construcción.
# rc: 0 presente(efectiva) · 1 ausente · 2 error/ilegible (FAIL-CLOSED — el llamador lo trata como BAD).
tc_env_assignment() {
  local ch="$1" key="$2" vre="$3" f; f="$(_tc_op_env_path "/home/$CUSER")"
  # test -e con rc explícito: 1 = sin fichero (ausente) · >1 = error de inspección → 2 (fail-closed),
  # NUNCA colapsar el error en "ausente" (fail-open).
  incus exec "$ch" -- test -e "$f" 2>/dev/null
  case $? in 1) return 1;; 0) ;; *) return 2;; esac
  incus exec "$ch" -- grep -Eq "^${key}=[\"']?${vre}" "$f"
  case $? in 0) return 0;; 1) return 1;; *) return 2;; esac
}

# IDENTIDAD GIT del canal — user.name Y user.email deben ser EXACTAMENTE la expansión de las
# plantillas del manifiesto ({channel} = nombre del contenedor). Vacío, distinto, plantillas sin
# definir o error de inspección ⇒ FALLO (fail-closed). Aplica a canales que COMMITEAN (producción
# y mergeador); los runners conservan su invariante LIMPIO.
tc_verify_git_identity() {
  local ch="$1" want_name want_mail eff_name eff_mail
  [ -n "${TF_CHANNEL_GIT_NAME_TMPL:-}" ] && [ -n "${TF_CHANNEL_GIT_EMAIL_TMPL:-}" ] || return 1
  want_name="${TF_CHANNEL_GIT_NAME_TMPL//\{channel\}/$ch}"
  want_mail="${TF_CHANNEL_GIT_EMAIL_TMPL//\{channel\}/$ch}"
  eff_name="$(incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.name' 2>/dev/null || true)"
  eff_mail="$(incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.email' 2>/dev/null || true)"
  [ "$eff_name" = "$want_name" ] && [ "$eff_mail" = "$want_mail" ]
}

# IDENTIDAD del env — SIEMPRE evaluable (sin ruta de salto), FAIL-CLOSED en ambos sentidos:
#   escrow presente → el contenedor DEBE tener su env operacional y md5 coincidir;
#   escrow ausente  → el contenedor NO debe tener env operacional (nada que empujar).
# Error de inspección del contenedor → FALLO.
tc_verify_env_identity() {
  local ch="$1" envf dst hmd5 cmd5 chas
  envf="$SECRET_DIR/env/$ch.env"
  dst="$(_tc_op_env_path "/home/$CUSER")"
  incus exec "$ch" -- test -e "$dst" 2>/dev/null
  case $? in 0) chas=yes;; 1) chas=no;; *) return 1;; esac   # error → fail-closed
  if [ -s "$envf" ]; then
    [ "$chas" = yes ] || return 1                            # escrow existe pero el canal no lo tiene
    hmd5="$(md5sum "$envf" 2>/dev/null | awk '{print $1}')"; [ -n "$hmd5" ] || return 1
    cmd5="$(incus exec "$ch" -- md5sum "$dst" 2>/dev/null | awk '{print $1}')"; [ -n "$cmd5" ] || return 1
    [ "$hmd5" = "$cmd5" ]
  else
    [ "$chas" = no ]                                          # sin escrow → el canal tampoco debe traerlo
  fi
}

# ¿Sesión CR canónica (~/.coderabbit/auth.json) en ALGÚN home real? 0 sí · 1 no · 2 error(fail-closed).
_tc_cr_session_anywhere() {
  local ch="$1" homes home; homes="$(_tc_homes "$ch")" || return 2
  for home in $homes; do
    _tc_file_present "$ch" "$home/.coderabbit/auth.json"
    case $? in 0) return 0;; 2) return 2;; esac
  done
  return 1
}

# ¿Asignación EFECTIVA sensible (sbp_/cr-, con comilla envolvente tolerada) en ALGÚN .env.local del
# contenedor (cualquier home)? 0 sí · 1 no · 2 error(fail-closed). Solo mira ficheros $ENV_DEST reales
# (no el árbol del repo: creds.manifest/push-carril-env.sh/.env.example no casan).
_tc_sensitive_env_anywhere() {
  local ch="$1" homes home found envf; homes="$(_tc_homes "$ch")" || return 2
  for home in $homes; do
    found="$(incus exec "$ch" -- find "$home" -path "*/$ENV_DEST" -type f 2>/dev/null)" || return 2
    for envf in $found; do
      incus exec "$ch" -- grep -Eq "^(SUPABASE_ACCESS_TOKEN=[\"']?sbp_|CODERABBIT_API_KEY=[\"']?cr-)" "$envf"
      case $? in 0) return 0;; 1) ;; *) return 2;; esac
    done
  done
  return 1
}

# PRODUCCIÓN: sin sbp_/CR EFECTIVA ni sesión CR canónica en TODO el contenedor (cualquier home real,
# incl. /home/runner y /root — así un canal de perfil producción con credencial colada en OTRO home se
# caza, y un runner sin declarar que caiga al default producción no pasa por la puerta de atrás). FAIL-CLOSED.
tc_prod_no_sensitive() {
  local ch="$1" r
  _tc_cr_session_anywhere "$ch"; r=$?; [ "$r" -eq 1 ] || return 1   # 0 presente / 2 error → BAD
  _tc_sensitive_env_anywhere "$ch"; r=$?; [ "$r" -eq 1 ] || return 1
  return 0
}

# MERGEADOR: IDENTIDAD de la sesión CR (md5 del .apiKey del auth.json == md5 de la CODERABBIT_API_KEY
# del escrow, des-citada). El apiKey se hashea DENTRO del contenedor; solo cruza el digest. FAIL-CLOSED.
tc_verify_cr_identity() {
  local ch="$1" envf key hmd5 cmd5 authp
  envf="$SECRET_DIR/env/$ch.env"
  authp="/home/$CUSER/.coderabbit/auth.json"
  key="$(grep -m1 '^CODERABBIT_API_KEY=' "$envf" 2>/dev/null | cut -d= -f2-)"
  # des-citado idéntico a push-carril-env.sh (una capa de "…" o '…')
  key="${key%\"}"; key="${key#\"}"; key="${key%\'}"; key="${key#\'}"
  [ -n "$key" ] || return 1
  hmd5="$(printf '%s' "$key" | md5sum | awk '{print $1}')"
  # jq -j (sin salto de línea) para casar el printf '%s' del host; md5 dentro del contenedor.
  cmd5="$(incus exec "$ch" -- sh -c 'jq -j ".apiKey // empty" "$1" 2>/dev/null | md5sum | cut -d" " -f1' _ "$authp" 2>/dev/null)"
  [ -n "$cmd5" ] || return 1
  [ "$hmd5" = "$cmd5" ]
}

# MERGEADOR completitud: sbp_ EFECTIVA presente en el env operacional (bajo /home/$CUSER).
tc_mergeador_has_sbp() {
  tc_env_assignment "$1" SUPABASE_ACCESS_TOKEN 'sbp_[A-Za-z0-9]'
  [ $? -eq 0 ]                                # solo 0(presente) pasa; 1(ausente) y 2(error) → FALLO
}

# ¿Algún artefacto de auth canónico (CR/claude/codex/gh) en ALGÚN home? 0 sí · 1 no · 2 error.
_tc_any_auth_artifact() {
  local ch="$1" homes home rel; homes="$(_tc_homes "$ch")" || return 2
  for home in $homes; do
    for rel in .coderabbit/auth.json .claude/.credentials.json .codex/auth.json .config/gh/hosts.yml; do
      _tc_file_present "$ch" "$home/$rel"; case $? in 0) return 0;; 2) return 2;; esac
    done
  done
  return 1
}

# ¿Algún .env.local con CUALQUIER asignación no vacía (cualquier credencial/config) en ALGÚN home?
# 0 sí · 1 no · 2 error. Para runner: "cero credenciales" ⇒ ningún env operacional con contenido.
_tc_any_env_assignment() {
  local ch="$1" homes home found envf; homes="$(_tc_homes "$ch")" || return 2
  for home in $homes; do
    found="$(incus exec "$ch" -- find "$home" -path "*/$ENV_DEST" -type f 2>/dev/null)" || return 2
    for envf in $found; do
      incus exec "$ch" -- grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.' "$envf"
      case $? in 0) return 0;; 1) ;; *) return 2;; esac
    done
  done
  return 1
}

# RUNNER: CERO credencial en TODO el contenedor (cualquier home real, incl. /home/runner y /root).
# Reutiliza el scanner SELLADO del motor si su entrypoint está disponible (hook TC_CRED_SCANNER —
# reutilización preferente, ref 08); si no, fallback container-wide por rutas canónicas + ausencia de
# CUALQUIER asignación en los .env.local. Cualquier error de inspección → FAIL-CLOSED.
tc_runner_clean() {
  local ch="$1" r
  if [ -n "${TC_CRED_SCANNER:-}" ]; then
    incus exec "$ch" -- bash "$TC_CRED_SCANNER" >/dev/null 2>&1; return $?
  fi
  _tc_any_auth_artifact "$ch"; r=$?; [ "$r" -eq 1 ] || return 1   # 0 presente / 2 error → BAD
  _tc_any_env_assignment "$ch"; r=$?; [ "$r" -eq 1 ] || return 1
  return 0
}
