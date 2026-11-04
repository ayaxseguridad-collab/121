#!/usr/bin/env bash
# sync-package.sh — propagación y paridad del NÚCLEO del paquete de skills de fábrica
# (plan v4 §4-bis, sellado rondas 2-4 + condiciones GO r4). HERRAMIENTA ÚNICA: el mismo
# binario propaga (--apply) y verifica (--check); las exclusiones de overlay se derivan
# MECÁNICAMENTE del manifiesto (parser único lib-package.sh) — jamás listas a mano,
# jamás metacaracteres (charset cerrado M3; el '*' de familia lo añade ESTA herramienta).
#
# Overlays: NI se copian NI se borran, en ninguna dirección. La paridad es del NÚCLEO.
#
# --apply sobre árbol de producto (…/.claude/skills) EXIGE --authority y corre en DOS FASES:
#   FASE 1 (cero rsync): p1 autoridad parseada · p2 origin del repo destino == autoridad
#   · p3 overlays exactos requeridos PRESENTES · p4 repo-identity.conf VÁLIDO vs autoridad.
#   FASE 2: transferencias + auto re---check. Cualquier fallo de fase 1 → rc 2 con CERO rsync.
#
# --migrate-identity: genera el repo-identity.conf del destino GOBERNADO POR LA AUTORIDAD
#   (GO r4: TCO_REPO_DIR = basename del slug normalizado de TF_REPO_URL, JAMÁS TF_REPO_DIR).
#   legado==autoridad → escribe conf (rc 0) · legado≠autoridad → rc 3 (ADJUDICACIÓN del lead,
#   sin escribir nada) · precondición → rc 2.
#   GREENFIELD (TAL-8037): sin conf previo Y sin identidad legada (el core ya no trae defaults) NO hay
#   nada que comparar con la autoridad: la identidad nace SOLO de un --approved COMPLETO y ligado al
#   proyecto de la autoridad (si falta una clave aprobada → rc 3, nada escrito). Un legado con
#   identidad ajena a la autoridad sigue siendo rc 3.
#
# rc: 0 OK · 1 drift/verificación fallida (--check, re-check post-apply) · 2 precondición
#     (fail-fast, cero side-effects) · 3 adjudicación requerida (--migrate-identity).
# Uso: sync-package.sh --from <src-skills> --to <dst-skills> (--check|--apply) [--authority <conf>]
#      sync-package.sh --migrate-identity --to <dst-skills> --authority <conf> [--approved <conf-adjudicado>]
#      sync-package.sh --authority-info <conf> | --self-test | --help
# --approved: fragmento data-only con la adjudicación del lead para ESE destino, LIGADO a la
#   autoridad (PKG_IDENTITY_PROJECT obligatorio y == TF_PROJECT) + las claves no derivables:
#   TCO_REPO_STACK, TCO_ANEXO_FILE, TCO_SUPABASE_REF, TCO_LINEAR_INPROGRESS_STATE,
#   TCO_LINEAR_INREVIEW_STATE, TCO_POSTMERGE_CMD, TCO_HOST_ENV_REL, TORC_HOST_ENV_REL
#   (+ TCO_TF_MANIFEST opcional, ruta absoluta). Con TCO_REPO_STACK=ninguno (sin backend gestionado)
#   TCO_SUPABASE_REF no se exige.
#   Sin él (o incompleto/placeholder/ajeno), la migración de un destino nuevo → rc 3.
set -euo pipefail
trap 'printf "ERROR: fallo imprevisto del sincronizador (línea %s)\n" "$LINENO" >&2; exit 2' ERR
SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-package.sh
. "$SC_DIR/lib-package.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; }  # cabecera completa, sin cortes [M1 P0-3]

# [Ronda P0-3, B1] VALIDACIÓN SEMÁNTICA ÚNICA de la identidad TCO — la MISMA para migración
# nueva, rama idempotente y p4 (la divergencia entre rutas permitía identidad inválida con
# verde). rc 1 = identidad inválida (el caller mapea: migración→3, p4→2); estructural → die2.
validar_identidad_tco() { # ctx dst base stack anexo supa inprog inrev postmerge envrel
  local ctx="$1" dst="$2" base="$3" stack="$4" anexo="$5" supa="$6" inprog="$7" inrev="$8" postmerge="$9" envrel="${10}"
  pkg_validate_identidad_formatos "$stack" "$supa" "$inprog" "$inrev" "$ctx" || return 1
  pkg_es_placeholder "$postmerge" && { printf 'ADJUDICACION INVALIDA (%s): TCO_POSTMERGE_CMD es un marcador de pendiente\n' "$ctx" >&2; return 1; }
  case "$anexo" in
    references/anexo-*.md) : ;;
    *) printf 'ADJUDICACION INVALIDA (%s): TCO_ANEXO_FILE fuera del patrón references/anexo-*.md (%s)\n' "$ctx" "$anexo" >&2; return 1 ;;
  esac
  [ -f "$dst/talent-channel-operation/$anexo" ] || { printf 'ADJUDICACION INVALIDA (%s): el anexo no existe en el árbol (%s)\n' "$ctx" "$anexo" >&2; return 1; }
  pkg_validate_env_rel "$envrel" "$ctx"
  [ -f "$base/$envrel" ] || { printf 'ADJUDICACION INVALIDA (%s): TCO_HOST_ENV_REL no existe bajo el HOME estable (%s/%s)\n' "$ctx" "$base" "$envrel" >&2; return 1; }
  return 0
}

es_producto() { case "$1" in */.claude/skills) return 0;; *) return 1;; esac; }
repo_root_de() { local d="$1"; d="${d%/.claude/skills}"; printf '%s' "$d"; }

# Exclusiones ANCLADAS del miembro $1 (una por línea) — datos ya validados por charset.
excludes_de() {
  local m="$1" e
  for e in ${PKG_OVERLAY_EXACT[@]+"${PKG_OVERLAY_EXACT[@]}"}; do
    [ "${e%%:*}" = "$m" ] && printf -- '--exclude=/%s\n' "${e#*:}"
  done
  for e in ${PKG_OVERLAY_PREFIX[@]+"${PKG_OVERLAY_PREFIX[@]}"}; do
    [ "${e%%:*}" = "$m" ] && printf -- '--exclude=/%s*\n' "${e#*:}"
  done
  return 0
}

# --check: dry-run itemizado del núcleo. Drift u overlay exacto requerido ausente → rc 1.
do_check() {
  local SRC="$1" DST="$2" rc=0 m out e ruta
  pkg_parse_manifest "$SRC/skill-creator/assets/package.manifest"
  for m in "${PKG_MEMBERS[@]}"; do
    local -a exc=()
    while IFS= read -r e; do [ -n "$e" ] && exc+=("$e"); done < <(excludes_de "$m")
    out="$(rsync -rcln --perms --delete --out-format='%i %n' ${exc[@]+"${exc[@]}"} "$SRC/$m/" "$DST/$m/" 2>&1)" || pkg_die2 "rsync falló en --check de $m: $out"
    if [ -n "$out" ]; then rc=1; printf 'DRIFT %s:\n%s\n' "$m" "$out"; fi
  done
  for e in ${PKG_OVERLAY_EXACT[@]+"${PKG_OVERLAY_EXACT[@]}"}; do
    m="${e%%:*}"; ruta="${e#*:}"
    if [ ! -f "$DST/$m/$ruta" ]; then rc=1; printf 'FAIL %s overlay-requerido-AUSENTE — %s\n' "$m" "$ruta"; fi
  done
  if [ "$rc" -eq 0 ]; then printf 'PARIDAD-NUCLEO: OK (cero drift; overlays requeridos presentes)\n'; fi
  return "$rc"
}

# FASE 1 del --apply: preflight COMPLETO. Cualquier fallo → pkg_die2 (rc 2, CERO rsync).
preflight_apply() {
  local SRC="$1" DST="$2" AUTH="$3" e m ruta reporoot origin slug_origin
  pkg_parse_manifest "$SRC/skill-creator/assets/package.manifest"
  if es_producto "$DST"; then
    [ -n "$AUTH" ] || pkg_die2 "--apply sobre árbol de producto EXIGE --authority (manifiesto del proyecto)"
    pkg_parse_authority "$AUTH"                                                          # p1
    reporoot="$(repo_root_de "$DST")"
    origin="$(git -C "$reporoot" remote get-url origin 2>/dev/null)" || pkg_die2 "p2: sin git origin en $reporoot"
    slug_origin="$(pkg_norm_repo_url "$origin")" || pkg_die2 "p2: origin no normalizable ($origin)"
    [ "$slug_origin" = "$AUTH_SLUG" ] || pkg_die2 "p2: origin del destino ($slug_origin) != autoridad ($AUTH_SLUG) — STOP"
  fi
  for e in ${PKG_OVERLAY_EXACT[@]+"${PKG_OVERLAY_EXACT[@]}"}; do                          # p3
    m="${e%%:*}"; ruta="${e#*:}"
    [ -f "$DST/$m/$ruta" ] || pkg_die2 "p3: overlay exacto requerido AUSENTE en destino: $m/$ruta (migrar identidad ANTES de aplicar)"
  done
  local tiene_tco=no tiene_torc=no mm
  for mm in "${PKG_MEMBERS[@]}"; do
    case "$mm" in
      talent-channel-operation) tiene_tco=yes ;;
      talent-orchestrator) tiene_torc=yes ;;
    esac
  done
  if es_producto "$DST" && [ "$tiene_tco" = yes ]; then                                   # p4
    # [B1-P0] Conf de channel-operation: SET COMPLETO (las 9 claves censadas) + PROCEDENCIA.
    local conf="$DST/talent-channel-operation/scripts/repo-identity.conf" k vn
    pkg_parse_identity_conf "$conf" || pkg_die2 "p4: repo-identity.conf de channel-operation ausente/ilegible"
    [ "$PKGID_PKG_IDENTITY_PROJECT" = "$AUTH_PROJECT" ] || pkg_die2 "p4: conf de channel-operation con procedencia de OTRO proyecto (${PKGID_PKG_IDENTITY_PROJECT:-sin-procedencia} != $AUTH_PROJECT) — un conf copiado de otro repo NO vale"
    for k in TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD; do
      vn="PKGID_$k"
      pkg_clave_tco_obligatoria "$k" "${PKGID_TCO_REPO_STACK:-}" || continue   # stack=ninguno: sin TCO_SUPABASE_REF
      [ -n "${!vn:-}" ] || pkg_die2 "p4: clave de identidad AUSENTE en el conf ($k) — las 8 claves censadas son obligatorias (adjudicadas, jamás heredadas a ciegas)"
    done
    [ "$PKGID_TCO_REPO_SLUG" = "$AUTH_SLUG" ] || pkg_die2 "p4: TCO_REPO_SLUG ($PKGID_TCO_REPO_SLUG) != autoridad ($AUTH_SLUG)"
    [ "$PKGID_TCO_REPO_DIR" = "$AUTH_REPO_DIR" ] || pkg_die2 "p4: TCO_REPO_DIR ($PKGID_TCO_REPO_DIR) != basename de la autoridad ($AUTH_REPO_DIR)"
    # [Ronda P0-3, B1] La MISMA validación semántica completa que migración nueva/idempotente
    # (formatos + denylist + anexo canónico existente + env existente) — identidad inválida
    # jamás llega a la primera llamada de rsync.
    local base_p4; base_p4="$(cd "${PKG_HOST_HOME:-$HOME}" && pwd)"
    validar_identidad_tco "p4" "$DST" "$base_p4" "$PKGID_TCO_REPO_STACK" "$PKGID_TCO_ANEXO_FILE" "$PKGID_TCO_SUPABASE_REF" "$PKGID_TCO_LINEAR_INPROGRESS_STATE" "$PKGID_TCO_LINEAR_INREVIEW_STATE" "$PKGID_TCO_POSTMERGE_CMD" "$PKGID_TCO_HOST_ENV_REL" \
      || pkg_die2 "p4: identidad de channel-operation fuera del contrato (ver detalle arriba)"
  fi
  if es_producto "$DST" && [ "$tiene_torc" = yes ]; then
    # [B2-P0] Conf del orquestador: parseo + procedencia + ruta estable (NUNCA aceptar por presencia).
    local conf2="$DST/talent-orchestrator/scripts/repo-identity.conf"
    pkg_parse_identity_conf "$conf2" || pkg_die2 "p4: repo-identity.conf del orquestador ausente/ilegible"
    [ "$PKGID_PKG_IDENTITY_PROJECT" = "$AUTH_PROJECT" ] || pkg_die2 "p4: conf del orquestador con procedencia de OTRO proyecto (${PKGID_PKG_IDENTITY_PROJECT:-sin-procedencia} != $AUTH_PROJECT)"
    pkg_validate_env_rel "$PKGID_TORC_HOST_ENV_REL" "p4"
    # [B3 ronda P0-2] Revalidar EXISTENCIA del env del orquestador ANTES del primer rsync —
    # sin esto, un núcleo verde dejaría al orquestador inoperable (promesa preflight rota).
    local base_p4b; base_p4b="$(cd "${PKG_HOST_HOME:-$HOME}" && pwd)"
    [ -f "$base_p4b/$PKGID_TORC_HOST_ENV_REL" ] || pkg_die2 "p4: TORC_HOST_ENV_REL no existe bajo el HOME estable ($base_p4b/$PKGID_TORC_HOST_ENV_REL)"
  fi
  return 0
}

do_apply() {
  local SRC="$1" DST="$2" AUTH="$3" m e
  preflight_apply "$SRC" "$DST" "$AUTH"        # FASE 1 — completa ANTES del primer rsync
  printf 'PREFLIGHT: OK — arranca la FASE 2 (transferencias)\n'
  for m in "${PKG_MEMBERS[@]}"; do             # FASE 2
    local -a exc=()
    while IFS= read -r e; do [ -n "$e" ] && exc+=("$e"); done < <(excludes_de "$m")
    mkdir -p "$DST/$m"
    rsync -rcl --perms --delete ${exc[@]+"${exc[@]}"} "$SRC/$m/" "$DST/$m/" || pkg_die2 "rsync falló aplicando $m"
  done
  printf 'APPLY: transferencias completas — re-check automático\n'
  local rc=0; do_check "$SRC" "$DST" || rc=$?
  return "$rc"
}

# --migrate-identity: legado → conf GOBERNADO POR AUTORIDAD (rc 0/2/3).
legacy_get() { # key file → default del patrón : "${KEY:=valor}" (vacío si no hay fichero o no hay default)
  local key="$1" f="$2"
  [ -f "$f" ] || return 0
  sed -nE 's/^: "\$\{'"$key"':=([^}]*)\}".*$/\1/p' "$f" | head -1
}
# [B1-P0 + ronda P0-2] Las claves NO DERIVABLES son ADJUDICADAS vía --approved (fragmento
# data-only aprobado por el lead POR destino), JAMÁS auto-copiadas del legado — el legado
# puede portar drift del fundador (caso real: DEFI heredó el TCO_SUPABASE_REF de TA).
# El --approved queda LIGADO A LA AUTORIDAD: debe declarar PKG_IDENTITY_PROJECT==AUTH_PROJECT
# (un approved de Academy alimentando una migración DEFI se rechaza — jamás se «lava» con la
# procedencia del destino). STACK y ANEXO también son adjudicados (tampoco derivan del URL).
PKG_ADJUDICADAS_TCO="TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL"
PKG_OPCIONALES_TCO="TCO_TF_MANIFEST"   # se escriben SOLO si vienen aprobadas (no se exigen)
cargar_approved() { # $1 archivo aprobado → AP_<clave> + AP_PROJECT; sin archivo → vacías
  local f="$1" k vn
  AP_PROJECT=""
  for k in $PKG_ADJUDICADAS_TCO $PKG_OPCIONALES_TCO TORC_HOST_ENV_REL; do printf -v "AP_$k" '%s' ""; done
  [ -n "$f" ] || return 0
  pkg_parse_identity_conf "$f" || pkg_die2 "--approved ilegible ($f)"
  AP_PROJECT="${PKGID_PKG_IDENTITY_PROJECT:-}"
  for k in $PKG_ADJUDICADAS_TCO $PKG_OPCIONALES_TCO TORC_HOST_ENV_REL; do
    vn="PKGID_$k"; printf -v "AP_$k" '%s' "${!vn:-}"
  done
  return 0
}

do_migrate() {
  local DST="$1" AUTH="$2" APPROVED="$3" rc_parcial=0
  es_producto "$DST" || pkg_die2 "--migrate-identity: --to debe ser un árbol de producto (…/.claude/skills)"
  [ -n "$AUTH" ] || pkg_die2 "--migrate-identity EXIGE --authority"
  pkg_parse_authority "$AUTH"
  local reporoot origin slug_origin
  reporoot="$(repo_root_de "$DST")"
  origin="$(git -C "$reporoot" remote get-url origin 2>/dev/null)" || pkg_die2 "sin git origin en $reporoot"
  slug_origin="$(pkg_norm_repo_url "$origin")" || pkg_die2 "origin no normalizable ($origin)"
  [ "$slug_origin" = "$AUTH_SLUG" ] || pkg_die2 "autoridad ($AUTH_SLUG) != origin real ($slug_origin) — revisar QUÉ manifiesto se pasó"
  cargar_approved "$APPROVED"
  # [Ronda P0-2, B1] Ligadura approved↔autoridad: sin proyecto o de OTRO proyecto → rc 3.
  if [ -n "$APPROVED" ]; then
    if [ -z "$AP_PROJECT" ]; then
      printf 'ADJUDICACION REQUERIDA: --approved SIN PKG_IDENTITY_PROJECT — el fragmento aprobado debe declarar su proyecto (ligadura a la autoridad).\n' >&2
      return 3
    fi
    if [ "$AP_PROJECT" != "$AUTH_PROJECT" ]; then
      printf 'ADJUDICACION REQUERIDA: --approved pertenece a OTRO proyecto (%s != %s) — un aprobado ajeno no se «lava» con la procedencia del destino. NADA escrito.\n' "$AP_PROJECT" "$AUTH_PROJECT" >&2
      return 3
    fi
  fi
  local base_est; base_est="$(cd "${PKG_HOST_HOME:-$HOME}" && pwd)"
  local legacy="$DST/talent-channel-operation/scripts/00-config.sh"
  local conf="$DST/talent-channel-operation/scripts/repo-identity.conf"
  if [ -f "$conf" ]; then
    # Idempotente = VALIDACIÓN COMPLETA (jamás aceptar por presencia): mismas reglas que p4.
    pkg_parse_identity_conf "$conf" || pkg_die2 "conf existente ilegible"
    local k vn incompleto=""
    for k in TCO_REPO_DIR TCO_REPO_SLUG $PKG_ADJUDICADAS_TCO; do
      vn="PKGID_$k"
      pkg_clave_tco_obligatoria "$k" "${PKGID_TCO_REPO_STACK:-}" || continue   # stack=ninguno: sin TCO_SUPABASE_REF
      [ -n "${!vn:-}" ] || incompleto="$incompleto $k"
    done
    if [ "$PKGID_TCO_REPO_SLUG" != "$AUTH_SLUG" ] || [ "$PKGID_TCO_REPO_DIR" != "$AUTH_REPO_DIR" ] \
       || [ "${PKGID_PKG_IDENTITY_PROJECT:-}" != "$AUTH_PROJECT" ] || [ -n "$incompleto" ]; then
      printf 'ADJUDICACION REQUERIDA: conf existente inválido (proyecto=%s slug=%s dir=%s; faltan:%s)\n' \
        "${PKGID_PKG_IDENTITY_PROJECT:-∅}" "$PKGID_TCO_REPO_SLUG" "$PKGID_TCO_REPO_DIR" "${incompleto:- ninguna}" >&2
      return 3
    fi
    if ! validar_identidad_tco "conf existente" "$DST" "$base_est" "$PKGID_TCO_REPO_STACK" "$PKGID_TCO_ANEXO_FILE" "$PKGID_TCO_SUPABASE_REF" "$PKGID_TCO_LINEAR_INPROGRESS_STATE" "$PKGID_TCO_LINEAR_INREVIEW_STATE" "$PKGID_TCO_POSTMERGE_CMD" "$PKGID_TCO_HOST_ENV_REL"; then
      return 3
    fi
    printf 'MIGRACION: conf de channel-operation existente VALIDO (idempotente, validación semántica COMPLETA)\n'
  else
    # Precondición: el destino ES una instalación del paquete (contiene el skill) — jamás se crean directorios ni conf en otro sitio.
    [ -f "$legacy" ] || pkg_die2 "sin legado ($legacy) y sin conf: destino no inicializado (¿no es una instalación del paquete?)"
    # GREENFIELD (TAL-8037): sin conf y sin identidad legada (legacy_get vacío: el core ya no trae
    # defaults) no hay nada que comparar con la autoridad — la identidad sale SOLO del --approved
    # completo (abajo). Con un legado que SÍ declara identidad, se compara como siempre (S07).
    local l_slug l_dir
    l_slug="$(legacy_get TCO_REPO_SLUG "$legacy")"; l_dir="$(legacy_get TCO_REPO_DIR "$legacy")"
    if { [ -n "$l_slug" ] || [ -n "$l_dir" ]; } && { [ "$l_slug" != "$AUTH_SLUG" ] || [ "$l_dir" != "$AUTH_REPO_DIR" ]; }; then
      { printf 'ADJUDICACION REQUERIDA (legado != autoridad) — NADA escrito:\n'
        printf '  legado:    slug=%s dir=%s\n' "$l_slug" "$l_dir"
        printf '  autoridad: slug=%s dir=%s (proyecto=%s)\n' "$AUTH_SLUG" "$AUTH_REPO_DIR" "$AUTH_PROJECT"
        printf '  El conf debe nacer DE LA AUTORIDAD tras el fallo adjudicado por el lead.\n'; } >&2
      return 3
    fi
    # TODAS las claves no derivables (stack/anexo incluidos) vienen de --approved; el legado
    # se muestra SOLO como candidato, jamás se escribe.
    local faltantes="" a av
    for a in $PKG_ADJUDICADAS_TCO; do
      av="AP_$a"
      pkg_clave_tco_obligatoria "$a" "${AP_TCO_REPO_STACK:-}" || continue   # stack=ninguno: sin TCO_SUPABASE_REF
      [ -n "${!av:-}" ] || faltantes="$faltantes $a"
    done
    if [ -n "$faltantes" ]; then
      { printf 'ADJUDICACION REQUERIDA: faltan claves aprobadas:%s — NADA escrito.\n' "$faltantes"
        if [ -n "$l_slug$l_dir" ]; then   # candidatos solo si hay legado (en greenfield no hay nada que sugerir)
          printf '  Candidatos del LEGADO (verificar por repo; pueden portar drift del fundador):\n'
          for a in $PKG_ADJUDICADAS_TCO; do printf '    %s=%s\n' "$a" "$(legacy_get "$a" "$legacy")"; done
        fi
        printf '  Pasa los valores aprobados por la instancia vía --approved <archivo>.\n'; } >&2
      return 3
    fi
    # [Ronda P0-3] Validación semántica ÚNICA (la misma de idempotente y p4) sobre la adjudicación.
    if ! validar_identidad_tco "--approved" "$DST" "$base_est" "$AP_TCO_REPO_STACK" "$AP_TCO_ANEXO_FILE" "$AP_TCO_SUPABASE_REF" "$AP_TCO_LINEAR_INPROGRESS_STATE" "$AP_TCO_LINEAR_INREVIEW_STATE" "$AP_TCO_POSTMERGE_CMD" "$AP_TCO_HOST_ENV_REL"; then
      return 3
    fi
    { printf '# repo-identity.conf — identidad POR REPO (data-only; el core no lleva defaults de identidad)\n'
      printf '# Generado por sync-package.sh --migrate-identity con autoridad %s\n' "$(basename "$AUTH")"
      printf 'PKG_IDENTITY_PROJECT=%s\n' "$AUTH_PROJECT"
      printf 'TCO_REPO_DIR=%s\n'  "$AUTH_REPO_DIR"
      printf 'TCO_REPO_SLUG=%s\n' "$AUTH_SLUG"
      for a in $PKG_ADJUDICADAS_TCO $PKG_OPCIONALES_TCO; do av="AP_$a"; [ -n "${!av:-}" ] && printf '%s=%s\n' "$a" "${!av}"; done
      true
    } > "$conf"
    pkg_parse_identity_conf "$conf" || pkg_die2 "conf recién escrito no parsea (bug)"
    [ "$PKGID_TCO_REPO_SLUG" = "$AUTH_SLUG" ] && [ "$PKGID_PKG_IDENTITY_PROJECT" = "$AUTH_PROJECT" ] || pkg_die2 "assert post-migración: conf != autoridad (bug)"
    printf 'MIGRACION: conf de channel-operation escrito y VALIDADO (autoridad %s + claves adjudicadas ligadas)\n' "$AUTH_PROJECT"
  fi
  migrar_conf_orquestador "$DST" || rc_parcial=$?
  return "$rc_parcial"
}

# [B2-P0] Identidad del orquestador: TORC_HOST_ENV_REL viene EXCLUSIVAMENTE de --approved
# (autoridad estable adjudicada) — JAMÁS derivada del checkout físico de la migración
# (un worktree/copia de ensayo mintaría una ruta transitoria). Validación: estructural
# (lib) + EXISTENCIA bajo el HOME estable + procedencia del proyecto en el conf.
migrar_conf_orquestador() {
  local DST="$1" base conf2
  base="$(cd "${PKG_HOST_HOME:-$HOME}" && pwd)"
  conf2="$DST/talent-orchestrator/scripts/repo-identity.conf"
  if [ -f "$conf2" ]; then
    # Conf existente: VALIDAR, nunca aceptar por presencia.
    pkg_parse_identity_conf "$conf2" || pkg_die2 "conf del orquestador ilegible"
    if [ "${PKGID_PKG_IDENTITY_PROJECT:-}" != "$AUTH_PROJECT" ]; then
      printf 'ADJUDICACION REQUERIDA: conf del orquestador con procedencia de OTRO proyecto (%s != %s)\n' \
        "${PKGID_PKG_IDENTITY_PROJECT:-∅}" "$AUTH_PROJECT" >&2
      return 3
    fi
    pkg_validate_env_rel "$PKGID_TORC_HOST_ENV_REL" "migración"
    if [ ! -f "$base/$PKGID_TORC_HOST_ENV_REL" ]; then
      printf 'ADJUDICACION REQUERIDA: TORC_HOST_ENV_REL no existe bajo el HOME estable (%s/%s) — ¿ruta de worktree/copia?\n' \
        "$base" "$PKGID_TORC_HOST_ENV_REL" >&2
      return 3
    fi
    printf 'MIGRACION: conf del orquestador existente VALIDO (procedencia + ruta estable)\n'
    return 0
  fi
  if [ -z "${AP_TORC_HOST_ENV_REL:-}" ]; then
    printf 'ADJUDICACION REQUERIDA: falta TORC_HOST_ENV_REL aprobada (--approved) — NADA escrito. JAMÁS se deriva del checkout.\n' >&2
    return 3
  fi
  pkg_validate_env_rel "$AP_TORC_HOST_ENV_REL" "migración"
  if [ ! -f "$base/$AP_TORC_HOST_ENV_REL" ]; then
    printf 'ADJUDICACION REQUERIDA: la ruta aprobada no existe bajo el HOME estable (%s/%s) — ruta transitoria o errónea.\n' \
      "$base" "$AP_TORC_HOST_ENV_REL" >&2
    return 3
  fi
  mkdir -p "$DST/talent-orchestrator/scripts"
  { printf '# repo-identity.conf — identidad del orquestador (data-only, D13; overlay por repo)\n'
    printf '# Generado por sync-package.sh --migrate-identity (valor ADJUDICADO vía --approved)\n'
    printf 'PKG_IDENTITY_PROJECT=%s\n' "$AUTH_PROJECT"
    printf 'TORC_HOST_ENV_REL=%s\n' "$AP_TORC_HOST_ENV_REL"; } > "$conf2"
  printf 'MIGRACION: conf del orquestador escrito y VALIDADO (ruta estable aprobada)\n'
  return 0
}

do_authority_info() {
  pkg_parse_authority "$1"
  printf 'proyecto=%s\nslug=%s\nrepo_dir=%s\nurl=%s\n' "$AUTH_PROJECT" "$AUTH_SLUG" "$AUTH_REPO_DIR" "$AUTH_REPO_URL"
}

# --- Self-test (34 fixtures + S35-S42 de TAL-8037 (greenfield/TCO_TF_MANIFEST/stack ninguno): 12 sellados r4 + split una-mutación + S14-S24 ronda P0-1 +
#     S25-S29 ronda P0-2 + S30-S34 ronda P0-3: validación semántica ÚNICA en las 3 rutas) ---
ST_PASS=0; ST_FAIL=0
ok()   { ST_PASS=$((ST_PASS+1)); printf 'ok %s\n' "$1"; }
falla(){ ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL %s%s\n' "$1" "${2:+ — $2}"; }
assert_rc() { local want="$1" name="$2"; shift 2; local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else falla "$name" "esperado rc=$want obtenido rc=$got"; fi; }
tree_hash() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 ); }

mk_src() { # árbol origen mini (3 miembros) con manifiesto+overlays y plantillas
  local R="$1"
  mkdir -p "$R/skill-creator/assets" "$R/skill-creator/scripts" \
           "$R/talent-channel-operation/scripts" "$R/talent-channel-operation/references" \
           "$R/talent-orchestrator/scripts"
  { printf 'version=1.0.0\nmin_invariants=1\nmember=skill-creator\nmember=talent-channel-operation\nmember=talent-orchestrator\n'
    printf 'overlay=talent-channel-operation:scripts/repo-identity.conf\n'
    printf 'overlay=talent-channel-operation:scripts/otro-overlay.conf\n'
    printf 'overlay-prefix=talent-channel-operation:references/anexo-\n'
    printf 'overlay=talent-orchestrator:scripts/repo-identity.conf\n'; } > "$R/skill-creator/assets/package.manifest"
  printf '# SKILL src\n' > "$R/skill-creator/SKILL.md"
  { printf '#!/usr/bin/env bash\n# core común\nnucleo_v1() { :; }\n# BLOQUE_COMUN_TAL3266\n'; } > "$R/talent-channel-operation/scripts/00-config.sh"
  chmod 755 "$R/talent-channel-operation/scripts/00-config.sh"
  printf 'doc core\n' > "$R/talent-channel-operation/references/otro.md"
  printf '# plantilla baseline del motor\nPKG_IDENTITY_PROJECT=plantilla\nTCO_REPO_DIR=PLANTILLA\n' > "$R/talent-channel-operation/scripts/repo-identity.conf"
  printf '# plantilla otro\n' > "$R/talent-channel-operation/scripts/otro-overlay.conf"
  printf 'anexo plantilla\n' > "$R/talent-channel-operation/references/anexo-plantilla.md"
  printf '# core orquestador\n' > "$R/talent-orchestrator/scripts/core.sh"
  printf '# plantilla baseline\nPKG_IDENTITY_PROJECT=plantilla\nTORC_HOST_ENV_REL=PLANTILLA/.env.local\n' > "$R/talent-orchestrator/scripts/repo-identity.conf"
}

UUID_A="11111111-2222-3333-4444-555555555555"; UUID_B="66666666-7777-8888-9999-aaaaaaaaaaaa"
conf_tco_mini() { # $1 destino-archivo — conf VÁLIDO completo (9 claves + procedencia) del proyecto mini
  { printf 'PKG_IDENTITY_PROJECT=mini\nTCO_REPO_DIR=Repo-Mini\nTCO_REPO_SLUG=org-x/Repo-Mini\nTCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-mini.md\n'
    printf 'TCO_SUPABASE_REF=refminiadjudicadoxx\nTCO_LINEAR_INPROGRESS_STATE=%s\nTCO_LINEAR_INREVIEW_STATE=%s\n' "$UUID_A" "$UUID_B"
    printf "TCO_POSTMERGE_CMD=echo 'post-merge mini'\nTCO_HOST_ENV_REL=Repo-Mini/.env.local\n"; } > "$1"
}
conf_torc_mini() { # $1 destino-archivo
  printf 'PKG_IDENTITY_PROJECT=mini\nTORC_HOST_ENV_REL=Repo-Mini-orq/.env.local\n' > "$1"
}
approved_mini() { # $1 destino-archivo — fragmento adjudicado completo del proyecto mini (LIGADO)
  { printf 'PKG_IDENTITY_PROJECT=mini\nTCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-mini.md\n'
    printf 'TCO_SUPABASE_REF=refminiadjudicadoxx\nTCO_LINEAR_INPROGRESS_STATE=%s\nTCO_LINEAR_INREVIEW_STATE=%s\n' "$UUID_A" "$UUID_B"
    printf "TCO_POSTMERGE_CMD=echo 'post-merge mini'\nTCO_HOST_ENV_REL=Repo-Mini/.env.local\nTORC_HOST_ENV_REL=Repo-Mini-orq/.env.local\n"; } > "$1"
}
mk_dst_producto() { # $1 raíz-repo $2 origin-url → crea repo git + .claude/skills espejo del src (núcleo)
  local RR="$1" URL="$2"
  mkdir -p "$RR"; git -C "$RR" init -q
  git -C "$RR" remote add origin "$URL"
  mkdir -p "$RR/.claude/skills"
}

self_test() {
  local T; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  local ME="${BASH_SOURCE[0]}" SRC="$T/src"
  mk_src "$SRC"
  local FIX="$SC_DIR/../tests/fixtures"

  # Autoridades sintéticas de ensayo
  printf 'TF_PROJECT="mini"\nTF_REPO_URL="https://github.com/org-x/Repo-Mini.git"\n' > "$T/auth-mini.conf"
  printf 'TF_PROJECT="tlo"\nTF_REPO_URL="https://github.com/te-talentland/Talent-Land-Online.git"\n' > "$T/auth-tlo.conf"
  # HOME estable de ensayo (los envs adjudicados DEBEN existir bajo él — p4/migración lo exigen)
  local HOGAR="$T/hogar"; mkdir -p "$HOGAR/Repo-Mini" "$HOGAR/Repo-Mini-orq"
  printf 'LINEAR_API_KEY=x\n' > "$HOGAR/Repo-Mini/.env.local"
  printf 'LINEAR_API_KEY=x\n' > "$HOGAR/Repo-Mini-orq/.env.local"
  local APPROVED="$T/approved-mini.conf"; approved_mini "$APPROVED"

  # dst gold producto: núcleo idéntico + overlays PROPIOS + conf válido vs auth-mini
  local D1="$T/d1"; mk_dst_producto "$D1" "https://github.com/org-x/Repo-Mini.git"
  local DS1="$D1/.claude/skills"
  cp -R "$SRC/skill-creator" "$DS1/skill-creator"
  mkdir -p "$DS1/talent-channel-operation/scripts" "$DS1/talent-channel-operation/references" "$DS1/talent-orchestrator/scripts"
  cp "$SRC/talent-channel-operation/scripts/00-config.sh" "$DS1/talent-channel-operation/scripts/"
  cp "$SRC/talent-channel-operation/references/otro.md" "$DS1/talent-channel-operation/references/"
  cp "$SRC/talent-orchestrator/scripts/core.sh" "$DS1/talent-orchestrator/scripts/"
  conf_tco_mini "$DS1/talent-channel-operation/scripts/repo-identity.conf"
  conf_torc_mini "$DS1/talent-orchestrator/scripts/repo-identity.conf"
  printf '# otro propio\n' > "$DS1/talent-channel-operation/scripts/otro-overlay.conf"
  printf 'anexo mini propio\n' > "$DS1/talent-channel-operation/references/anexo-mini.md"
  assert_rc 0 S01-gold-check bash "$ME" --from "$SRC" --to "$DS1" --check

  # S02 drift de núcleo
  local D2="$T/d2"; cp -R "$D1" "$D2"; printf 'drift\n' >> "$D2/.claude/skills/talent-channel-operation/references/otro.md"
  assert_rc 1 S02-drift-nucleo bash "$ME" --from "$SRC" --to "$D2/.claude/skills" --check

  # S03 regresión refactor: núcleo ATRASADO (sin bloque común) + conf propio → apply propaga y preserva
  local D3="$T/d3"; cp -R "$D1" "$D3"; local DS3="$D3/.claude/skills"
  command grep -v 'BLOQUE_COMUN_TAL3266' "$SRC/talent-channel-operation/scripts/00-config.sh" > "$DS3/talent-channel-operation/scripts/00-config.sh"
  chmod 755 "$DS3/talent-channel-operation/scripts/00-config.sh"   # mutación ÚNICA: solo el bloque, no el modo
  local sha_conf_pre sha_conf_post
  sha_conf_pre="$(sha256sum "$DS3/talent-channel-operation/scripts/repo-identity.conf" | cut -d' ' -f1)"
  if PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$DS3" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1; then
    sha_conf_post="$(sha256sum "$DS3/talent-channel-operation/scripts/repo-identity.conf" | cut -d' ' -f1)"
    if command grep -q 'BLOQUE_COMUN_TAL3266' "$DS3/talent-channel-operation/scripts/00-config.sh" \
       && [ "$sha_conf_pre" = "$sha_conf_post" ] \
       && bash "$ME" --from "$SRC" --to "$DS3" --check >/dev/null 2>&1; then
      ok "S03-regresion-refactor (bloque propagado + conf byte-idéntico + check 0)"
    else falla S03-regresion-refactor "post-condiciones"; fi
  else falla S03-regresion-refactor "apply rc!=0"; fi

  # S04 pérdida de bit ejecutable en núcleo
  local D4="$T/d4"; cp -R "$D1" "$D4"; chmod 644 "$D4/.claude/skills/talent-channel-operation/scripts/00-config.sh"
  assert_rc 1 S04-exec-bit bash "$ME" --from "$SRC" --to "$D4/.claude/skills" --check

  # S05 el prefijo excluye SOLO su familia: anexos propios intactos, otro.md SÍ se actualiza
  local D5="$T/d5"; cp -R "$D1" "$D5"; local DS5="$D5/.claude/skills"
  printf 'anexo-a propio\n' > "$DS5/talent-channel-operation/references/anexo-a.md"
  printf 'anexo-b propio\n' > "$DS5/talent-channel-operation/references/anexo-b.md"
  printf 'VIEJO\n' > "$DS5/talent-channel-operation/references/otro.md"
  local sha_a sha_b
  sha_a="$(sha256sum "$DS5/talent-channel-operation/references/anexo-a.md" | cut -d' ' -f1)"
  sha_b="$(sha256sum "$DS5/talent-channel-operation/references/anexo-b.md" | cut -d' ' -f1)"
  if PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$DS5" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 \
     && [ "$(sha256sum "$DS5/talent-channel-operation/references/anexo-a.md" | cut -d' ' -f1)" = "$sha_a" ] \
     && [ "$(sha256sum "$DS5/talent-channel-operation/references/anexo-b.md" | cut -d' ' -f1)" = "$sha_b" ] \
     && command grep -q 'doc core' "$DS5/talent-channel-operation/references/otro.md"; then
    ok "S05-prefijo-solo-familia (anexos intactos + otro.md actualizado)"
  else falla S05-prefijo-solo-familia; fi

  # S06 overlay exacto preservado tras apply (mutación única: conf distinto del de plantilla)
  local D6="$T/d6"; cp -R "$D1" "$D6"; local DS6="$D6/.claude/skills"
  local sha6_pre; sha6_pre="$(sha256sum "$DS6/talent-channel-operation/scripts/otro-overlay.conf" | cut -d' ' -f1)"
  if PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$DS6" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 \
     && [ "$(sha256sum "$DS6/talent-channel-operation/scripts/otro-overlay.conf" | cut -d' ' -f1)" = "$sha6_pre" ]; then
    ok "S06-overlay-exacto-preservado"
  else falla S06-overlay-exacto-preservado; fi

  # Shim fake-rsync (patrón fake-incus de la casa): registra invocaciones; NUNCA debe correr
  local SHIM="$T/shim"; mkdir -p "$SHIM"
  # shellcheck disable=SC2016  # las comillas simples son DELIBERADAS: el shim debe recibir los literales
  printf '#!/usr/bin/env bash\necho "$@" >> "${FAKE_RSYNC_LOG:?}"\nexit 0\n' > "$SHIM/rsync"; chmod 755 "$SHIM/rsync"

  # S07 negativo con legado AJENO: legado con identidad de OTRO repo + origin distinto → migrate rc 3 sin conf;
  #     apply sin conf → rc 2; en ambos: CERO rsync + árbol byte-intacto
  printf 'TF_PROJECT="otro"\nTF_REPO_URL="https://github.com/org-y/Repo-Otro.git"\n' > "$T/auth-otro.conf"
  local D7="$T/d7"; mk_dst_producto "$D7" "https://github.com/org-y/Repo-Otro.git"
  local DS7="$D7/.claude/skills"; mkdir -p "$DS7/talent-channel-operation/scripts" "$DS7/talent-channel-operation/references"
  # shellcheck disable=SC2016  # literal deliberado: fixture de un 00-config LEGADO (pre-refactor)
  { printf '#!/usr/bin/env bash\n: "${TCO_REPO_DIR:=Repo-Legado}"\n: "${TCO_REPO_SLUG:=org-x/Repo-Legado}"\n: "${TCO_REPO_STACK:=supabase}"\n: "${TCO_ANEXO_FILE:=references/anexo-legado.md}"\n# core…\n'; } > "$DS7/talent-channel-operation/scripts/00-config.sh"
  printf 'anexo legado heredado\n' > "$DS7/talent-channel-operation/references/anexo-legado.md"
  cp -R "$SRC/skill-creator" "$DS7/skill-creator"
  local h7_pre log7="$T/rsync7.log"; h7_pre="$(tree_hash "$DS7")"
  local rc7a=0 rc7b=0
  FAKE_RSYNC_LOG="$log7" PATH="$SHIM:$PATH" bash "$ME" --migrate-identity --to "$DS7" --authority "$T/auth-otro.conf" >/dev/null 2>&1 || rc7a=$?
  FAKE_RSYNC_LOG="$log7" PATH="$SHIM:$PATH" bash "$ME" --from "$SRC" --to "$DS7" --apply --authority "$T/auth-otro.conf" >/dev/null 2>&1 || rc7b=$?
  if [ "$rc7a" -eq 3 ] && [ "$rc7b" -eq 2 ] && [ ! -s "$log7" ] && [ "$(tree_hash "$DS7")" = "$h7_pre" ] \
     && [ ! -f "$DS7/talent-channel-operation/scripts/repo-identity.conf" ]; then
    ok "S07-negativo-legado-ajeno (migrate rc=3, apply rc=2, fake-rsync=0 llamadas, árbol intacto, sin conf)"
  else falla S07-negativo-legado-ajeno "rc7a=$rc7a rc7b=$rc7b log=$([ -s "$log7" ] && echo con-llamadas || echo vacío)"; fi

  # S08 apply con overlay exacto requerido AUSENTE → rc 2 + cero rsync + árbol intacto
  local D8="$T/d8"; cp -R "$D1" "$D8"; local DS8="$D8/.claude/skills"
  rm "$DS8/talent-channel-operation/scripts/otro-overlay.conf"
  local h8_pre log8="$T/rsync8.log" rc8=0; h8_pre="$(tree_hash "$DS8")"
  FAKE_RSYNC_LOG="$log8" PATH="$SHIM:$PATH" bash "$ME" --from "$SRC" --to "$DS8" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc8=$?
  if [ "$rc8" -eq 2 ] && [ ! -s "$log8" ] && [ "$(tree_hash "$DS8")" = "$h8_pre" ]; then
    ok "S08-overlay-ausente (rc=2, fake-rsync=0, árbol intacto)"
  else falla S08-overlay-ausente "rc=$rc8"; fi

  # S09 positivo DEFI: legado==autoridad + claves ADJUDICADAS vía --approved → confs completos; apply verde
  mk_legacy_mini() { # $1 raíz-repo — destino con legado mini pre-refactor
    mk_dst_producto "$1" "https://github.com/org-x/Repo-Mini.git"
    local DS="$1/.claude/skills"; mkdir -p "$DS/talent-channel-operation/scripts" "$DS/talent-channel-operation/references"
    # shellcheck disable=SC2016  # literal deliberado: fixture de un 00-config LEGADO (pre-refactor)
    { printf '#!/usr/bin/env bash\n: "${TCO_REPO_DIR:=Repo-Mini}"\n: "${TCO_REPO_SLUG:=org-x/Repo-Mini}"\n: "${TCO_REPO_STACK:=supabase}"\n: "${TCO_ANEXO_FILE:=references/anexo-mini.md}"\n'; } > "$DS/talent-channel-operation/scripts/00-config.sh"
    printf 'anexo mini\n' > "$DS/talent-channel-operation/references/anexo-mini.md"
    printf '# otro propio\n' > "$DS/talent-channel-operation/scripts/otro-overlay.conf"
    cp -R "$SRC/skill-creator" "$DS/skill-creator"
  }
  local D9="$T/d9"; mk_legacy_mini "$D9"; local DS9="$D9/.claude/skills"
  local rc9=0
  PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$DS9" --authority "$T/auth-mini.conf" --approved "$APPROVED" >/dev/null 2>&1 || rc9=$?
  if [ "$rc9" -eq 0 ] \
     && command grep -q '^PKG_IDENTITY_PROJECT=mini$' "$DS9/talent-channel-operation/scripts/repo-identity.conf" \
     && command grep -q '^TCO_REPO_SLUG=org-x/Repo-Mini$' "$DS9/talent-channel-operation/scripts/repo-identity.conf" \
     && command grep -q '^TCO_SUPABASE_REF=refminiadjudicadoxx$' "$DS9/talent-channel-operation/scripts/repo-identity.conf" \
     && command grep -q '^TCO_HOST_ENV_REL=Repo-Mini/.env.local$' "$DS9/talent-channel-operation/scripts/repo-identity.conf" \
     && command grep -q '^TORC_HOST_ENV_REL=Repo-Mini-orq/.env.local$' "$DS9/talent-orchestrator/scripts/repo-identity.conf" \
     && command grep -q '^PKG_IDENTITY_PROJECT=mini$' "$DS9/talent-orchestrator/scripts/repo-identity.conf" \
     && PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$DS9" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1; then
    ok "S09-positivo-DEFI (confs completos de AMBOS skills, claves adjudicadas, apply verde)"
  else falla S09-positivo-DEFI "rc=$rc9"; fi

  # S10/S11 CONDICIÓN GO r4: autoridad sobre fixtures de manifiestos completos (como datos, sin source)
  local out10 out11
  out10="$(bash "$ME" --authority-info "$FIX/manifiesto-real-academy.conf" 2>&1)" || falla S10-academy "rc"
  if printf '%s' "$out10" | command grep -q '^slug=org-ejemplo/Academia-Ejemplo-2.0$' \
     && printf '%s' "$out10" | command grep -q '^repo_dir=Academia-Ejemplo-2.0$' \
     && printf '%s' "$out10" | command grep -q '^proyecto=academy$'; then
    ok "S10-autoridad-academy-COMPLETA (repo_dir=Academia-Ejemplo-2.0 ≠ TF_REPO_DIR='Academia Ejemplo 2026')"
  else falla S10-autoridad-academy-COMPLETA "$out10"; fi
  out11="$(bash "$ME" --authority-info "$FIX/manifiesto-real-atlas-mx.conf" 2>&1)" || falla S11-atlas "rc"
  if printf '%s' "$out11" | command grep -q '^slug=te-talentland/talent-land-atlas-mx$' \
     && printf '%s' "$out11" | command grep -q '^repo_dir=talent-land-atlas-mx$'; then
    ok "S11-autoridad-atlas-REAL (repo_dir=talent-land-atlas-mx ≠ TF_REPO_DIR='Talent Land Atlas MX')"
  else falla S11-autoridad-atlas-REAL "$out11"; fi

  # S12 autoridad con TF_REPO_URL duplicada → rc 2 · S13 URL malformada → rc 2
  { cat "$T/auth-mini.conf"; printf 'TF_REPO_URL="https://github.com/otro/repo.git"\n'; } > "$T/auth-dup.conf"
  assert_rc 2 S12-autoridad-duplicada bash "$ME" --authority-info "$T/auth-dup.conf"
  printf 'TF_PROJECT="x"\nTF_REPO_URL="ftp://malformada"\n' > "$T/auth-mal.conf"
  assert_rc 2 S13-autoridad-malformada bash "$ME" --authority-info "$T/auth-mal.conf"

  # ---- Ronda P0-1 [B1/B2/M1]: adjudicación, orquestador estable, anti-override, comillas ----
  # S14 migrate SIN --approved → rc 3, cero rsync, árbol intacto (claves adjudicadas jamás del legado)
  local D14="$T/d14"; mk_legacy_mini "$D14"
  local h14 log14="$T/rsync14.log" rc14=0; h14="$(tree_hash "$D14/.claude/skills")"
  FAKE_RSYNC_LOG="$log14" PATH="$SHIM:$PATH" PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D14/.claude/skills" --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc14=$?
  if [ "$rc14" -eq 3 ] && [ ! -s "$log14" ] && [ "$(tree_hash "$D14/.claude/skills")" = "$h14" ] \
     && [ ! -f "$D14/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" ]; then
    ok "S14-migrate-sin-approved (rc=3, cero rsync, árbol intacto, sin conf)"
  else falla S14-migrate-sin-approved "rc=$rc14"; fi
  # S15 approved INCOMPLETO (una sola clave) → rc 3
  local D15="$T/d15"; mk_legacy_mini "$D15"
  printf 'TCO_SUPABASE_REF=refminiadjudicado\n' > "$T/approved-incompleto.conf"
  assert_rc 3 S15-approved-incompleto env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D15/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-incompleto.conf"
  # S16 apply con conf1 SIN TCO_POSTMERGE_CMD (post-merge perdido) → rc 2 + cero rsync + intacto
  local D16="$T/d16"; cp -R "$D1" "$D16"
  sed -i '/^TCO_POSTMERGE_CMD=/d' "$D16/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  local h16 log16="$T/rsync16.log" rc16=0; h16="$(tree_hash "$D16/.claude/skills")"
  FAKE_RSYNC_LOG="$log16" PATH="$SHIM:$PATH" PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$D16/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc16=$?
  if [ "$rc16" -eq 2 ] && [ ! -s "$log16" ] && [ "$(tree_hash "$D16/.claude/skills")" = "$h16" ]; then
    ok "S16-conf-sin-postmerge (rc=2, cero rsync, árbol intacto)"
  else falla S16-conf-sin-postmerge "rc=$rc16"; fi
  # S17 conf1 con procedencia de OTRO proyecto → apply rc 2
  local D17="$T/d17"; cp -R "$D1" "$D17"
  sed -i 's/^PKG_IDENTITY_PROJECT=mini$/PKG_IDENTITY_PROJECT=academy/' "$D17/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  assert_rc 2 S17-conf-tco-de-otro-proyecto env PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$D17/.claude/skills" --apply --authority "$T/auth-mini.conf"
  # S18 conf2 (orquestador) de OTRO proyecto (el «conf de TA dentro de DEFI») → apply rc 2
  local D18="$T/d18"; cp -R "$D1" "$D18"
  sed -i 's/^PKG_IDENTITY_PROJECT=mini$/PKG_IDENTITY_PROJECT=academy/' "$D18/.claude/skills/talent-orchestrator/scripts/repo-identity.conf"
  assert_rc 2 S18-conf-torc-de-otro-proyecto env PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$D18/.claude/skills" --apply --authority "$T/auth-mini.conf"
  # S19 approved con TORC de ruta transitoria (no existe bajo el HOME estable) → rc 3
  local D19="$T/d19"; mk_legacy_mini "$D19"
  { command grep -v '^TORC_HOST_ENV_REL=' "$APPROVED"; printf 'TORC_HOST_ENV_REL=d19/.env.local\n'; } > "$T/approved-transitorio.conf"
  assert_rc 3 S19-torc-ruta-transitoria env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D19/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-transitorio.conf"
  # S20 conf TCO válido + conf TORC AUSENTE → apply rc 2 (p3) + cero rsync + intacto
  local D20="$T/d20"; cp -R "$D1" "$D20"
  rm "$D20/.claude/skills/talent-orchestrator/scripts/repo-identity.conf"
  local h20 log20="$T/rsync20.log" rc20=0; h20="$(tree_hash "$D20/.claude/skills")"
  FAKE_RSYNC_LOG="$log20" PATH="$SHIM:$PATH" bash "$ME" --from "$SRC" --to "$D20/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc20=$?
  if [ "$rc20" -eq 2 ] && [ ! -s "$log20" ] && [ "$(tree_hash "$D20/.claude/skills")" = "$h20" ]; then
    ok "S20-torc-ausente (rc=2 en p3, cero rsync, árbol intacto)"
  else falla S20-torc-ausente "rc=$rc20"; fi
  # S21/S22 core REAL anti-override de estación (B1): el 00-config refactorizado del paquete CON un conf
  # NEUTRO al lado (la distribución ya no trae conf de casa; el del fixture es el de conf_tco_mini)
  local CORE_REAL="$SC_DIR/../../talent-channel-operation" T21="$T/core21" SDN
  SDN="$(mktemp -d)"; mkdir -p "$T21"; cp -R "$CORE_REAL" "$T21/skill"
  conf_tco_mini "$T21/skill/scripts/repo-identity.conf"
  local rc21=0 rc22=0 dir22=""
  SECRET_DIR="$SDN" TCO_REPO_DIR="Otro-Repo" bash -c ". '$T21/skill/scripts/00-config.sh'" >/dev/null 2>&1 || rc21=$?
  if [ "$rc21" -eq 1 ]; then ok "S21-override-estacion-divergente (rc=1: identidad mixta cortada)"
  else falla S21-override-estacion-divergente "rc=$rc21"; fi
  dir22="$(SECRET_DIR="$SDN" bash -c ". '$T21/skill/scripts/00-config.sh' && printf %s \"\$TCO_REPO_DIR\"" 2>/dev/null)" || rc22=$?
  if [ "$rc22" -eq 0 ] && [ "$dir22" = "Repo-Mini" ]; then ok "S22-control-sin-override (rc=0, DIR==conf neutro)"
  else falla S22-control-sin-override "rc=$rc22 dir=$dir22"; fi
  rm -rf "$SDN"
  # S23/S24 [M1] comillas desbalanceadas en la autoridad → rc 2 (una mutación por fixture)
  printf 'TF_PROJECT="x"\nTF_REPO_URL="https://github.com/org/repo.git\n' > "$T/auth-quote-url.conf"
  assert_rc 2 S23-url-comilla-sin-cierre bash "$ME" --authority-info "$T/auth-quote-url.conf"
  printf 'TF_PROJECT="x\nTF_REPO_URL="https://github.com/org/repo.git"\n' > "$T/auth-quote-project.conf"
  assert_rc 2 S24-project-comilla-sin-cierre bash "$ME" --authority-info "$T/auth-quote-project.conf"

  # ---- Ronda P0-2 [B1/B2/B3]: ligadura approved↔autoridad, placeholders, envs en p4 ----
  # S25 approved de OTRO proyecto (Academy→DEFI, la clase «lavado») → rc 3 sin conf
  local D25="$T/d25"; mk_legacy_mini "$D25"
  { printf 'PKG_IDENTITY_PROJECT=academy\n'; command grep -v '^PKG_IDENTITY_PROJECT=' "$APPROVED"; } > "$T/approved-ajeno.conf"
  local rc25=0
  PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D25/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-ajeno.conf" >/dev/null 2>&1 || rc25=$?
  if [ "$rc25" -eq 3 ] && [ ! -f "$D25/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" ]; then
    ok "S25-approved-de-otro-proyecto (rc=3, sin conf — no se lava con la procedencia del destino)"
  else falla S25-approved-de-otro-proyecto "rc=$rc25"; fi
  # S26 approved con marcador PENDIENTE-* → rc 3 sin conf (un placeholder no es adjudicación)
  local D26="$T/d26"; mk_legacy_mini "$D26"
  sed 's/^TCO_SUPABASE_REF=.*/TCO_SUPABASE_REF=PENDIENTE-ADJUDICACION-X/' "$APPROVED" > "$T/approved-placeholder.conf"
  local rc26=0
  PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D26/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-placeholder.conf" >/dev/null 2>&1 || rc26=$?
  if [ "$rc26" -eq 3 ] && [ ! -f "$D26/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" ]; then
    ok "S26-approved-placeholder (rc=3, sin conf)"
  else falla S26-approved-placeholder "rc=$rc26"; fi
  # S27 [B3] conf TORC válido pero su env BORRADO del HOME estable → apply rc 2 + cero rsync + intacto
  local D27="$T/d27"; cp -R "$D1" "$D27"
  local HOGAR27="$T/hogar27"; cp -R "$HOGAR" "$HOGAR27"; rm "$HOGAR27/Repo-Mini-orq/.env.local"
  local h27 log27="$T/rsync27.log" rc27=0; h27="$(tree_hash "$D27/.claude/skills")"
  FAKE_RSYNC_LOG="$log27" PATH="$SHIM:$PATH" PKG_HOST_HOME="$HOGAR27" bash "$ME" --from "$SRC" --to "$D27/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc27=$?
  if [ "$rc27" -eq 2 ] && [ ! -s "$log27" ] && [ "$(tree_hash "$D27/.claude/skills")" = "$h27" ]; then
    ok "S27-torc-env-borrado (rc=2 en p4, cero rsync, árbol intacto)"
  else falla S27-torc-env-borrado "rc=$rc27"; fi
  # S28 [B2] env del COORDINADOR (TCO_HOST_ENV_REL) borrado → apply rc 2 + cero rsync + intacto
  local D28="$T/d28"; cp -R "$D1" "$D28"
  local HOGAR28="$T/hogar28"; cp -R "$HOGAR" "$HOGAR28"; rm "$HOGAR28/Repo-Mini/.env.local"
  local h28 log28="$T/rsync28.log" rc28=0; h28="$(tree_hash "$D28/.claude/skills")"
  FAKE_RSYNC_LOG="$log28" PATH="$SHIM:$PATH" PKG_HOST_HOME="$HOGAR28" bash "$ME" --from "$SRC" --to "$D28/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc28=$?
  if [ "$rc28" -eq 2 ] && [ ! -s "$log28" ] && [ "$(tree_hash "$D28/.claude/skills")" = "$h28" ]; then
    ok "S28-tco-env-borrado (rc=2 en p4, cero rsync, árbol intacto)"
  else falla S28-tco-env-borrado "rc=$rc28"; fi
  # S29 [B2] core real: env propio ausente, HOME existente y otra instancia presente/ausente.
  # Ambas variantes exigen rc 1, token vacío y diagnóstico de la ruta propia adjudicada.
  # Toda mención del HOME sintético debe ser esa ruta exacta, sin depender de nombres ajenos.
  # Límite: no se instrumentan accesos; un fallback silencioso queda fuera de esta prueba.
  local CORE29="$SC_DIR/../../talent-channel-operation" T29="$T/core29" SDN29
  SDN29="$(mktemp -d)"; mkdir -p "$T29"; cp -R "$CORE29" "$T29/skill"
  conf_tco_mini "$T29/skill/scripts/repo-identity.conf"
  printf 'anexo mini\n' > "$T29/skill/references/anexo-mini.md"
  local HOGAR29="$T29/hogar" AJENA29="$T29/hogar/Instancia-Ajena" TOKEN29='SINTETICO-AJENO'
  local PROPIA29; PROPIA29="$HOGAR29/$(sed -n 's/^TCO_HOST_ENV_REL=//p' "$T29/skill/scripts/repo-identity.conf")"
  local rc29 out29 variante29 fixture29 resto29 rutas29 propia29 fallos29=0
  mkdir -p "$AJENA29"
  printf 'LINEAR_API_KEY=%s\n' "$TOKEN29" > "$AJENA29/.env.local"
  for variante29 in presente ausente; do
    fixture29=0; rc29=0
    [ "$variante29" != ausente ] || rm -rf "$AJENA29"
    # La presencia es parte del contrato: retirar el fichero no puede dar un falso verde.
    if [ -d "$HOGAR29" ] && [ ! -e "$HOGAR29/Repo-Mini/.env.local" ]; then
      if [ "$variante29" = presente ]; then
        [ -r "$AJENA29/.env.local" ] && command grep -Fxq "LINEAR_API_KEY=$TOKEN29" "$AJENA29/.env.local" && fixture29=1
      elif [ ! -e "$AJENA29" ]; then fixture29=1; fi
    fi
    out29="$(SECRET_DIR="$SDN29" HOST_HOME="$HOGAR29" bash -c '
      unset LINEAR_API_KEY TCO_HOST_ENV
      . "$1" && tco_load_tokens
      rc=$?; printf "LK=%s\n" "${LINEAR_API_KEY:-VACIA}"; exit "$rc"
    ' _ "$T29/skill/scripts/00-config.sh" 2>&1)" || rc29=$?
    resto29="$out29"; rutas29=1; propia29=0
    while [[ "$resto29" == *"$HOGAR29"* ]]; do
      resto29="$HOGAR29${resto29#*"$HOGAR29"}"
      if [[ "$resto29" != "$PROPIA29"* ]]; then rutas29=0; break; fi
      resto29="${resto29#"$PROPIA29"}"
      # Fin de ruta en el diagnóstico: fin de texto, espacio, comilla o paréntesis de cierre.
      # No basta un prefijo propio: .env.local-extra o .env.local/otra también son ajenos.
      if [[ ! "$resto29" =~ ^($|[[:space:]\"\'\)]) ]]; then rutas29=0; break; fi
      propia29=1
    done
    if [ "$fixture29" -eq 1 ] && [ "$rc29" -eq 1 ] \
       && [ "$rutas29" -eq 1 ] && [ "$propia29" -eq 1 ] \
       && printf '%s\n' "$out29" | command grep -Fxq 'LK=VACIA' \
       && ! printf '%s' "$out29" | command grep -Fq -- "$TOKEN29" \
       && ! printf '%s' "$out29" | command grep -Fq -- "$AJENA29"; then
      printf 'S29-ajena-%s: rc=1, fixture válido, token NO cargado, solo ruta propia adjudicada\n' "$variante29"
    else
      falla "S29-ajena-$variante29" "rc=$rc29 fixture=$fixture29 rutas=$rutas29 propia=$propia29"
      fallos29=$((fallos29+1))
    fi
  done
  if [ "$fallos29" -eq 0 ]; then
    ok "S29-load-tokens-sin-fallback-fundador (rc=1, token NO cargado, sin ruta de otra instancia)"
  fi
  rm -rf "$SDN29"

  # ---- Ronda P0-3 [B1]: la rama IDEMPOTENTE y p4 comparten la validación semántica única ----
  # S30 idempotente: postmerge = placeholder → rc 3
  local D30="$T/d30"; cp -R "$D1" "$D30"
  sed -i "s|^TCO_POSTMERGE_CMD=.*|TCO_POSTMERGE_CMD=PENDIENTE-ADJUDICACION|" "$D30/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  assert_rc 3 S30-idem-postmerge-placeholder env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D30/.claude/skills" --authority "$T/auth-mini.conf"
  # S31 idempotente: anexo fuera de formato → rc 3
  local D31="$T/d31"; cp -R "$D1" "$D31"
  sed -i 's|^TCO_ANEXO_FILE=.*|TCO_ANEXO_FILE=SKILL.md|' "$D31/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  assert_rc 3 S31-idem-anexo-fuera-de-formato env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D31/.claude/skills" --authority "$T/auth-mini.conf"
  # S32 idempotente: anexo canónico pero INEXISTENTE → rc 3
  local D32="$T/d32"; cp -R "$D1" "$D32"
  sed -i 's|^TCO_ANEXO_FILE=.*|TCO_ANEXO_FILE=references/anexo-no-existe.md|' "$D32/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  assert_rc 3 S32-idem-anexo-inexistente env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D32/.claude/skills" --authority "$T/auth-mini.conf"
  # S33 idempotente: env TCO inexistente bajo el HOME estable → rc 3
  local D33="$T/d33"; cp -R "$D1" "$D33"
  sed -i 's|^TCO_HOST_ENV_REL=.*|TCO_HOST_ENV_REL=No-Existe/.env.local|' "$D33/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  assert_rc 3 S33-idem-env-tco-inexistente env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D33/.claude/skills" --authority "$T/auth-mini.conf"
  # S34 p4: TCO_ANEXO_FILE=SKILL.md (el repro del auditor) → apply rc 2 + cero rsync + intacto
  local D34="$T/d34"; cp -R "$D1" "$D34"
  sed -i 's|^TCO_ANEXO_FILE=.*|TCO_ANEXO_FILE=SKILL.md|' "$D34/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"
  local h34 log34="$T/rsync34.log" rc34=0; h34="$(tree_hash "$D34/.claude/skills")"
  FAKE_RSYNC_LOG="$log34" PATH="$SHIM:$PATH" PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$D34/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1 || rc34=$?
  if [ "$rc34" -eq 2 ] && [ ! -s "$log34" ] && [ "$(tree_hash "$D34/.claude/skills")" = "$h34" ]; then
    ok "S34-p4-anexo-fuera-de-formato (rc=2, cero rsync, árbol intacto — repro del auditor cerrado)"
  else falla S34-p4-anexo-fuera-de-formato "rc=$rc34"; fi


  # ---- TAL-8037: greenfield (sin legado ni conf), TCO_TF_MANIFEST, stack=ninguno ----
  mk_greenfield() { # $1 raíz-repo — destino con el core SIN defaults de identidad + el anexo adjudicado, sin conf
    mk_dst_producto "$1" "https://github.com/org-x/Repo-Mini.git"
    local DS="$1/.claude/skills"; mkdir -p "$DS/talent-channel-operation/scripts" "$DS/talent-channel-operation/references" "$DS/talent-orchestrator/scripts"
    cp "$SRC/talent-channel-operation/scripts/00-config.sh" "$DS/talent-channel-operation/scripts/"
    cp "$SRC/talent-orchestrator/scripts/core.sh" "$DS/talent-orchestrator/scripts/"
    cp "$SRC/talent-channel-operation/references/otro.md" "$DS/talent-channel-operation/references/"
    printf 'anexo mini\n' > "$DS/talent-channel-operation/references/anexo-mini.md"
    printf '# otro propio\n' > "$DS/talent-channel-operation/scripts/otro-overlay.conf"
    cp -R "$SRC/skill-creator" "$DS/skill-creator"
  }
  local D35="$T/d35"; mk_greenfield "$D35"; local DS35="$D35/.claude/skills" rc35g=0
  PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$DS35" --authority "$T/auth-mini.conf" --approved "$APPROVED" >/dev/null 2>&1 || rc35g=$?
  if [ "$rc35g" -eq 0 ] \
     && command grep -q '^TCO_REPO_SLUG=org-x/Repo-Mini$' "$DS35/talent-channel-operation/scripts/repo-identity.conf" \
     && command grep -q '^TORC_HOST_ENV_REL=Repo-Mini-orq/.env.local$' "$DS35/talent-orchestrator/scripts/repo-identity.conf" \
     && PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$DS35" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1; then
    ok "S35-greenfield-approved-completo (rc=0, confs de ambos skills, apply verde)"
  else falla S35-greenfield-approved-completo "rc=$rc35g"; fi
  # S36 greenfield sin UNA clave aprobada → rc 3 'faltan claves aprobadas', nada escrito
  local D36="$T/d36"; mk_greenfield "$D36"; local rc36g=0 err36
  command grep -v '^TCO_POSTMERGE_CMD=' "$APPROVED" > "$T/approved-sin-postmerge.conf"
  err36="$(PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D36/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-sin-postmerge.conf" 2>&1 >/dev/null)" || rc36g=$?
  if [ "$rc36g" -eq 3 ] && printf '%s' "$err36" | command grep -q 'faltan claves aprobadas' && printf '%s' "$err36" | command grep -q 'TCO_POSTMERGE_CMD' \
     && [ ! -f "$D36/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" ]; then
    ok "S36-greenfield-falta-una-clave (rc=3 'faltan claves aprobadas', sin conf)"
  else falla S36-greenfield-falta-una-clave "rc=$rc36g"; fi
  # S37 greenfield con approved de OTRO proyecto → rc 3, sin conf
  local D37="$T/d37"; mk_greenfield "$D37"
  assert_rc 3 S37-greenfield-approved-de-otro-proyecto env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D37/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-ajeno.conf"
  # S38 TCO_TF_MANIFEST ABSOLUTA en el approved → se escribe en el conf y el parser la acepta · S39 relativa → rc 2
  local D38="$T/d38"; mk_greenfield "$D38"
  { cat "$APPROVED"; printf 'TCO_TF_MANIFEST=/ruta/abs/manifiesto.conf\n'; } > "$T/approved-manifest-abs.conf"
  if PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D38/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-manifest-abs.conf" >/dev/null 2>&1 \
     && command grep -q '^TCO_TF_MANIFEST=/ruta/abs/manifiesto.conf$' "$D38/.claude/skills/talent-channel-operation/scripts/repo-identity.conf"; then
    ok "S38-tf-manifest-absoluta-aceptada (parser + escrito en el conf)"
  else falla S38-tf-manifest-absoluta-aceptada; fi
  local D39="$T/d39"; mk_greenfield "$D39"
  { cat "$APPROVED"; printf 'TCO_TF_MANIFEST=manifiestos/relativa.conf\n'; } > "$T/approved-manifest-rel.conf"
  assert_rc 2 S39-tf-manifest-relativa-rechazada env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D39/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-manifest-rel.conf"
  # S40 stack=ninguno SIN TCO_SUPABASE_REF → rc 0 (no se exige), conf sin la clave, apply (p4) verde · S41 ninguno con un ref real → rc 3
  local D40="$T/d40"; mk_greenfield "$D40"
  sed -e 's/^TCO_REPO_STACK=.*/TCO_REPO_STACK=ninguno/' -e '/^TCO_SUPABASE_REF=/d' "$APPROVED" > "$T/approved-ninguno.conf"
  if PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D40/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-ninguno.conf" >/dev/null 2>&1 \
     && command grep -q '^TCO_REPO_STACK=ninguno$' "$D40/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" \
     && ! command grep -q '^TCO_SUPABASE_REF=' "$D40/.claude/skills/talent-channel-operation/scripts/repo-identity.conf" \
     && PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D40/.claude/skills" --authority "$T/auth-mini.conf" >/dev/null 2>&1 \
     && PKG_HOST_HOME="$HOGAR" bash "$ME" --from "$SRC" --to "$D40/.claude/skills" --apply --authority "$T/auth-mini.conf" >/dev/null 2>&1; then
    ok "S40-stack-ninguno-sin-supabase-ref (migrate rc=0, conf sin ref, idempotente, apply p4 verde)"
  else falla S40-stack-ninguno-sin-supabase-ref; fi
  local D41="$T/d41"; mk_greenfield "$D41"
  sed -e 's/^TCO_REPO_STACK=.*/TCO_REPO_STACK=ninguno/' "$APPROVED" > "$T/approved-ninguno-con-ref.conf"
  assert_rc 3 S41-stack-ninguno-con-ref-real-rechazado env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D41/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-ninguno-con-ref.conf"
  # S43 [m5] greenfield en un destino que NO es una instalación del paquete (sin el skill) → rc 2, nada creado
  local D43="$T/d43"; mk_dst_producto "$D43" "https://github.com/org-x/Repo-Mini.git"; local h43; h43="$(tree_hash "$D43/.claude")"
  assert_rc 2 S43-greenfield-destino-sin-skill env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D43/.claude/skills" --authority "$T/auth-mini.conf" --approved "$APPROVED"
  [ "$(tree_hash "$D43/.claude")" = "$h43" ] && ok "S43b-destino-sin-skill-intacto (nada creado)" || falla S43b-destino-sin-skill-intacto
  # S42 stack fuera del enum → rc 3
  local D42="$T/d42"; mk_greenfield "$D42"
  sed -e 's/^TCO_REPO_STACK=.*/TCO_REPO_STACK=inventado/' "$APPROVED" > "$T/approved-stack-raro.conf"
  assert_rc 3 S42-stack-fuera-de-enum env PKG_HOST_HOME="$HOGAR" bash "$ME" --migrate-identity --to "$D42/.claude/skills" --authority "$T/auth-mini.conf" --approved "$T/approved-stack-raro.conf"

  printf 'SELFTEST: PASS=%s FAIL=%s\n' "$ST_PASS" "$ST_FAIL"
  [ $((ST_PASS+ST_FAIL)) -ge 44 ] || { printf 'SELFTEST: guard — corrieron %s casos (<44)\n' $((ST_PASS+ST_FAIL)) >&2; exit 1; }
  [ "$ST_FAIL" -eq 0 ] || exit 1
  exit 0
}

# --- CLI -------------------------------------------------------------------------------------
FROM=""; TO=""; MODE=""; AUTH=""; APPROVED=""
case "${1:-}" in
  --help) usage; exit 0 ;;
  --self-test) [ $# -eq 1 ] || pkg_die2 "--self-test no admite otras flags"; self_test ;;
  --authority-info) [ $# -eq 2 ] || pkg_die2 "--authority-info <conf>"; do_authority_info "$2"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || pkg_die2 "--from sin valor"; FROM="$2"; shift 2 ;;
    --to)   [ $# -ge 2 ] || pkg_die2 "--to sin valor";   TO="$2";   shift 2 ;;
    --authority) [ $# -ge 2 ] || pkg_die2 "--authority sin valor"; AUTH="$2"; shift 2 ;;
    --approved)  [ $# -ge 2 ] || pkg_die2 "--approved sin valor";  APPROVED="$2"; shift 2 ;;
    --check|--apply|--migrate-identity)
      [ -z "$MODE" ] || pkg_die2 "modo duplicado"; MODE="${1#--}"; shift ;;
    *) pkg_die2 "flag desconocida: $1" ;;
  esac
done
command -v rsync >/dev/null 2>&1 || pkg_die2 "dependencia ausente: rsync"
[ -n "$MODE" ] || pkg_die2 "falta modo: --check | --apply | --migrate-identity"
# Los rc legítimos 1/3 de los modos NO deben caer en el trap ERR (que los convertiría en 2):
RC=0
case "$MODE" in
  check)
    [ -d "${FROM:-/nx}" ] || pkg_die2 "--from inválido"; [ -d "${TO:-/nx}" ] || pkg_die2 "--to inválido"
    do_check "$(cd "$FROM" && pwd)" "$(cd "$TO" && pwd)" || RC=$? ;;
  apply)
    [ -d "${FROM:-/nx}" ] || pkg_die2 "--from inválido"; [ -d "${TO:-/nx}" ] || pkg_die2 "--to inválido"
    do_apply "$(cd "$FROM" && pwd)" "$(cd "$TO" && pwd)" "$AUTH" || RC=$? ;;
  migrate-identity)
    [ -d "${TO:-/nx}" ] || pkg_die2 "--to inválido"
    do_migrate "$(cd "$TO" && pwd)" "$AUTH" "$APPROVED" || RC=$? ;;
esac
exit "$RC"
