#!/usr/bin/env bash
# runner-clean.sh — Higiene de un runner sellado tras cada suite (TAL-6809).
#
# ── EL CASO QUE ESTO EXISTE PARA CERRAR ─────────────────────────────────────────────────────────
# Un runner compiló el MISMO árbol cinco veces en verde y falló a la sexta sin una sola señal de
# disco (df -h), memoria ni corrupción — porque nada de eso mide INODOS. Un filesystem puede tener
# espacio de sobra y agotar sus inodos igual (muchos ficheros pequeños: worktrees, node_modules,
# residuos de `/tmp/local-gates/*`), y `df -h` no lo ve.
#
# ── LA REGLA QUE NO SE NEGOCIA: NUNCA TOCA RESTOS AJENOS ────────────────────────────────────────
# Un runner puede compartir máquina/filesystem con OTRA estación (perfil §runners `estacion=`
# distinto por fila). Antes de `rm` cualquier cosa, se comprueba la PROPIEDAD (uid) del recurso
# contra el usuario que corre este script — un residuo de otro dueño se REPORTA, nunca se borra.
# Esto es intencional aunque parezca conservador: un `rm -rf` que acierta el 99% de las veces y
# borra trabajo ajeno la vez que falla es peor que no limpiar esa vez.
#
# ── QUÉ HACE, EN ORDEN ───────────────────────────────────────────────────────────────────────────
#   1. Worktrees git rancios: `git worktree list` sobre el repo del runner, poda los que ya no
#      tienen directorio (`git worktree prune`, no destructivo: solo limpia METADATA huérfana) y
#      reporta (sin tocar) cualquier worktree cuyo directorio exista pero NO sea propiedad del uid
#      que corre este script.
#   2. Residuos de `/tmp/local-gates/*` y `/tmp/tal2288-*`: se borran SOLO si son propiedad del uid
#      actual; el resto se reporta como ajeno, nunca se borra.
#   3. Volúmenes Docker huérfanos (dangling): `docker volume prune` sobre el socket ROOTLESS del
#      propio usuario runner (nunca el daemon root del host — ver 08-runners-del-mergeador.md
#      §Contrato del perfil, el runner NO pertenece al grupo docker). Un runner sin docker rootless
#      configurado no falla: se reporta SKIP, no error.
#   4. Umbral de inodos: `df -iP` sobre el filesystem que contiene `$RUNNER_HOME`, comparado contra
#      `--umbral-inodos` (default 85). Emite SIEMPRE la línea de formato FIJO `RC_INODES <maquina>
#      <pct_usado> <umbral>` a stdout — el consumo de esa línea en el parte de guardia es contrato
#      con `talent-coordination` (TAL-6808); este script solo la EMITE, nunca la publica él mismo
#      en ningún canal (eso sigue sin construir). Sí tiene un consumidor interno en este repo:
#      `scripts/seal-suite.sh` (`rc_clean_runner()`) la extrae de la salida de este script y la
#      reimprime en su propio log de higiene — no es el contrato con `talent-coordination`.
#
# Uso: runner-clean.sh [--runner-home <dir>] [--maquina <nombre>] [--umbral-inodos <pct>] [--dry-run]
# rc: 0 = corrió completo (incluida la rama "0 restos que limpiar", que es un verde legítimo,
#     nunca "no corrí") · 1 = algún paso no pudo completarse (se nombra cuál) · 2 = precondición.
# Sourceable para tests con RC_NO_MAIN=1 (expone los predicados puros rc_*).
set -uo pipefail
export LC_ALL=C

RC_UMBRAL_DEFECTO=85
RC_RUNNER_HOME_DEFECTO="${HOME:-/home/runner}"

# rc_es_propio <ruta> — rc 0 si <ruta> es propiedad del UID que corre este script; rc 1 si es de
# otro dueño; rc 2 si no se pudo determinar (ruta inexistente o `stat` falló) — un "no sé de quién
# es" NUNCA se trata como "es mío": por eso el default de esta función es NEGATIVO (rc 1/2, no 0).
rc_es_propio() {
  local ruta="$1" uid_ruta
  uid_ruta="$(stat -c '%u' "$ruta" 2>/dev/null)" || return 2
  [ "$uid_ruta" = "$(id -u)" ]
}

# rc_worktrees_rancios <repo> <dry_run> — poda metadata huérfana (git worktree prune, siempre
# seguro: no borra directorios, solo la referencia a los que ya no existen) y REPORTA — sin tocar—
# cualquier worktree cuyo directorio exista pero no sea del uid actual.
# Emite una línea `WT_AJENO <ruta>` por cada worktree ajeno encontrado (para que el llamador lo
# cuente si quiere) y no falla por encontrarlos: un worktree ajeno es un dato, no un error de esta
# función.
rc_worktrees_rancios() {
  local repo="$1" dry="$2"
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || { echo "rc_worktrees_rancios: '$repo' no es un repo git" >&2; return 1; }
  if [ "$dry" = 1 ]; then
    git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print "  (dry-run) podaría metadata huérfana si aplica: "$0}'
  else
    git -C "$repo" worktree prune -v 2>&1 | sed 's/^/  /'
  fi
  local linea ruta
  while IFS= read -r linea; do
    case "$linea" in
      worktree\ *)
        ruta="${linea#worktree }"
        [ -d "$ruta" ] || continue   # ya podado o inexistente: nada que reportar
        if ! rc_es_propio "$ruta"; then
          printf 'WT_AJENO %s\n' "$ruta"
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  return 0
}

# rc_limpia_tmp <patron_glob> <dry_run> — borra SOLO lo que es propiedad del uid actual; el resto
# se cuenta y se reporta con `TMP_AJENO <ruta>`, nunca se toca. Devuelve por stdout el recuento
# `LIMPIADOS <n>` y `AJENOS <n>` (además de las líneas TMP_AJENO individuales) para que el
# llamador pueda resumir sin re-parsear.
rc_limpia_tmp() {
  local patron="$1" dry="$2" limpiados=0 ajenos=0 f
  # Sin nullglob: un patrón sin coincidencias expande al literal (p.ej. "/tmp/tal2288-*") como
  # ÚNICO elemento — el guard `[ -e "$f" ]` de abajo lo descarta sin tratarlo como un fichero real
  # llamado literalmente así. No se toca `shopt` global: este script puede ser sourced por tests.
  local -a candidatos=()
  # shellcheck disable=SC2206
  candidatos=( $patron )
  for f in "${candidatos[@]}"; do
    [ -e "$f" ] || continue
    if rc_es_propio "$f"; then
      if [ "$dry" = 1 ]; then
        echo "  (dry-run) borraría: $f"
      else
        rm -rf -- "$f" && limpiados=$((limpiados + 1))
      fi
    else
      ajenos=$((ajenos + 1))
      printf 'TMP_AJENO %s\n' "$f"
    fi
  done
  printf 'LIMPIADOS %s\n' "$limpiados"
  printf 'AJENOS %s\n' "$ajenos"
  return 0
}

# rc_docker_dangling <dry_run> — prune de volúmenes dangling SOLO contra el socket rootless propio
# (nunca el daemon root: el runner no pertenece al grupo docker, ver cabecera). Si no hay socket
# rootless configurado, SKIP explícito — no es un fallo de este script, es un runner sin ese
# subsistema montado.
rc_docker_dangling() {
  local dry="$1" sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
  if [ ! -S "$sock" ]; then
    echo "  docker rootless: SKIP (sin socket en $sock)"
    return 0
  fi
  if [ "$dry" = 1 ]; then
    DOCKER_HOST="unix://$sock" docker volume ls -f dangling=true --format '  (dry-run) podaría: {{.Name}}' 2>&1
  else
    DOCKER_HOST="unix://$sock" docker volume prune -f 2>&1 | sed 's/^/  /'
  fi
}

# rc_umbral_inodos <dir> <umbral_pct> — SIEMPRE emite `RC_INODES <maquina> <pct> <umbral>` (la
# máquina la decide el llamador con --maquina; aquí solo se recibe ya resuelta). rc 0 con el dato
# publicado siempre — el UMBRAL SUPERADO no es un rc de esta función (eso lo decide quien consuma
# la línea, p.ej. el parte de guardia); esta función solo MIDE y PUBLICA, fail-closed en la medida
# misma (si `df -iP` no rinde, publica -1 explícito, nunca inventa un porcentaje).
# [Acta 1 v3, NO MEDIDO señalado: el caso real que motiva esto — %IUse alto — nunca se ejercitaba,
# solo un filesystem ocioso] `RC_DF_BIN` (default `df`) es un seam deliberado: un test puede
# apuntarlo a un binario `df` señuelo que responda con salida `-iP` sintética de %IUse alto/cercano
# al umbral, sin necesitar agotar inodos de verdad en el filesystem del sandbox.
rc_umbral_inodos() {
  local dir="$1" umbral="$2" maquina="$3" linea pct df_bin="${RC_DF_BIN:-df}"
  linea="$("$df_bin" -iP "$dir" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')"
  case "$linea" in ''|*[!0-9]*) pct=-1;; *) pct="$linea";; esac
  printf 'RC_INODES %s %s %s\n' "$maquina" "$pct" "$umbral"
}

rc_main() {
  local runner_home="$RC_RUNNER_HOME_DEFECTO" maquina="$(hostname 2>/dev/null || echo desconocida)" \
        umbral="$RC_UMBRAL_DEFECTO" dry=0
  while [ $# -gt 0 ]; do case "$1" in
    --runner-home)    runner_home="${2:-}"; shift 2 || return 2;;
    --maquina)        maquina="${2:-}"; shift 2 || return 2;;
    --umbral-inodos)  umbral="${2:-}"; shift 2 || return 2;;
    --dry-run)        dry=1; shift;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; return 0;;
    *) printf 'runner-clean: flag desconocido: %s\n' "$1" >&2; return 2;;
  esac; done
  case "$umbral" in ''|*[!0-9]*) printf 'runner-clean: --umbral-inodos debe ser numérico\n' >&2; return 2;; esac
  [ -d "$runner_home" ] || { printf 'runner-clean: --runner-home no existe: %s\n' "$runner_home" >&2; return 2; }

  local fallos=0

  echo "== 1. Worktrees git rancios =="
  if [ -d "$runner_home/repo" ]; then
    rc_worktrees_rancios "$runner_home/repo" "$dry" || fallos=$((fallos + 1))
  else
    echo "  (sin $runner_home/repo — nada que podar)"
  fi

  # (TAL-7421) RC_TMP_ROOT solo lo fija una suite de prueba; en producción nadie la fija y vale /tmp.
  # Contrato: ruta absoluta sin espacios, tabuladores, saltos de línea ni *, ?, [ o \, porque el
  # patrón se expande sin comillas (candidatos=( $patron )): los blancos la parten, los comodines la
  # expanden y la barra invertida escapa el carácter siguiente. Lo garantiza quien la fija.
  local tmp_root="${RC_TMP_ROOT:-/tmp}"
  echo "== 2. Residuos $tmp_root/local-gates* y $tmp_root/tal2288-* (solo propios) =="
  rc_limpia_tmp "$tmp_root/local-gates*" "$dry"
  rc_limpia_tmp "$tmp_root/tal2288-*" "$dry"

  echo "== 3. Volúmenes Docker huérfanos (rootless propio) =="
  # [Acta 1 v2, MAYOR] rc_docker_dangling calculaba el rc correcto (pipefail SÍ protege su propia
  # tubería, verificado por el auditor con un docker señuelo que falla de verdad) — el bug real es
  # que esta llamada lo tiraba entero, a diferencia de rc_worktrees_rancios arriba. Un fallo real
  # de limpieza Docker (daemon rootless caído, permisos rotos) ahora SÍ tumba runner-clean.sh.
  rc_docker_dangling "$dry" || fallos=$((fallos + 1))

  echo "== 4. Umbral de inodos =="
  rc_umbral_inodos "$runner_home" "$umbral" "$maquina"

  [ "$fallos" -eq 0 ]
}

if [ -z "${RC_NO_MAIN-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  rc_main "$@"; exit $?
fi
