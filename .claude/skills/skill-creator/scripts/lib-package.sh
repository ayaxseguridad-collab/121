#!/usr/bin/env bash
# shellcheck disable=SC2034  # esta lib EXPORTA variables (PKG_*/AUTH_*/PKGID_*) que consumen
#                            # validate-package.sh y sync-package.sh — no son "unused".
# lib-package.sh — parser ÚNICO del paquete de skills de fábrica (gramática compartida
# por validate-package.sh y sync-package.sh: cero deriva entre validador y sincronizador).
#
# Contrato (plan v4, rondas 1-4 de auditoría):
#   - Los archivos de datos (package.manifest, manifiestos de proyecto TF_*, repo-identity.conf)
#     se leen SIEMPRE como DATOS: jamás `source` sobre entradas.
#   - rc 2 = precondición/malformación (fail-fast vía pkg_die2). El llamador define rc 1.
#   - LC_ALL=C, `command grep` (nunca la función ugrep), ERE POSIX ([0-9], jamás \d).
#   - Charset cerrado para rutas/prefijos de overlay: ^[A-Za-z0-9._/-]+$ (anti-metacaracteres
#     de rsync: * ? [ ] { } ! \ espacio quedan FUERA por construcción — hallazgo M3).
#   - Autoridad de identidad: TF_REPO_URL normalizado → slug owner/repo; TCO_REPO_DIR =
#     basename del slug (JAMÁS TF_REPO_DIR, que es la carpeta de la matriz — GO r4 condición 1).
#
# Este archivo se `source`a desde los binarios del paquete (código propio versionado, no datos).

export LC_ALL=C

pkg_die2() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# --- Rechazo de bytes problemáticos en archivos de DATOS (BOM/CRLF/NUL → rc 2) ------------
# No se promete validación UTF-8 completa: solo estos tres venenos concretos.
pkg_reject_bom_crlf_nul() {
  local f="$1" etiqueta="$2" cr head3
  [ -f "$f" ] || pkg_die2 "$etiqueta: archivo ausente ($f)"
  head3="$(head -c 3 -- "$f" | od -An -tx1 | tr -d ' \n')"
  [ "$head3" = "efbbbf" ] && pkg_die2 "$etiqueta: BOM detectado"
  cr="$(printf '\r')"
  if command grep -q "$cr" -- "$f"; then pkg_die2 "$etiqueta: terminadores CRLF detectados"; fi
  # NUL: comparación de longitudes (un $(printf '\0') en un patrón se DESCARTA en la
  # sustitución de comandos → patrón vacío = falso match universal; por eso tr|wc).
  local n_tot n_sin
  n_tot="$(head -c 1048576 -- "$f" | wc -c)"; n_sin="$(head -c 1048576 -- "$f" | tr -d '\0' | wc -c)"
  [ "$n_tot" -eq "$n_sin" ] || pkg_die2 "$etiqueta: byte NUL detectado"
  return 0
}

# ¿Archivo binario? (NUL en el primer MiB) — para targets de Capa B. rc 0 = binario.
pkg_es_binario() {
  local f="$1" n_tot n_sin
  n_tot="$(head -c 1048576 -- "$f" | wc -c)"; n_sin="$(head -c 1048576 -- "$f" | tr -d '\0' | wc -c)"
  [ "$n_tot" -ne "$n_sin" ]
}

# --- Gramática cerrada de package.manifest -------------------------------------------------
# Líneas válidas: vacía · #comentario col0 · version=X.Y.Z (exact. 1) · min_invariants=N≥1
# (exact. 1) · member=nombre (≥1, sin dups, ^[a-z0-9][a-z0-9-]*$) · overlay=<member>:<ruta>
# · overlay-prefix=<member>:<prefijo>. Cualquier otra forma → rc 2 con número de línea.
# Salida: PKG_VERSION PKG_MIN_INV PKG_MEMBERS[] PKG_OVERLAY_EXACT[] PKG_OVERLAY_PREFIX[]
# (overlays como "member:ruta"). skill-creator debe pertenecer a members (coherencia D2).
pkg_parse_manifest() {
  local mf="$1" ln=0 line v m ruta entry
  PKG_VERSION="" ; PKG_MIN_INV="" ; PKG_MEMBERS=() ; PKG_OVERLAY_EXACT=() ; PKG_OVERLAY_PREFIX=()
  pkg_reject_bom_crlf_nul "$mf" "package.manifest"
  local seen_members=":" seen_overlays=":"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    case "$line" in
      "") continue ;;
      "#"*) continue ;;
      version=*)
        [ -n "$PKG_VERSION" ] && pkg_die2 "manifest L$ln: version= duplicada"
        v="${line#version=}"
        printf '%s' "$v" | command grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || pkg_die2 "manifest L$ln: version malformada ($v)"
        PKG_VERSION="$v" ;;
      min_invariants=*)
        [ -n "$PKG_MIN_INV" ] && pkg_die2 "manifest L$ln: min_invariants= duplicada"
        v="${line#min_invariants=}"
        printf '%s' "$v" | command grep -Eq '^[1-9][0-9]*$' || pkg_die2 "manifest L$ln: min_invariants inválido ($v — cero prohibido: anti-vacuo)"
        PKG_MIN_INV="$v" ;;
      member=*)
        v="${line#member=}"
        printf '%s' "$v" | command grep -Eq '^[a-z0-9][a-z0-9-]*$' || pkg_die2 "manifest L$ln: member malformado ($v)"
        case "$seen_members" in *":$v:"*) pkg_die2 "manifest L$ln: member duplicado ($v)";; esac
        seen_members="$seen_members$v:"
        PKG_MEMBERS+=("$v") ;;
      overlay=*|overlay-prefix=*)
        entry="${line#overlay}"; entry="${entry#-prefix}"; entry="${entry#=}"
        m="${entry%%:*}"; ruta="${entry#*:}"
        [ "$m" = "$entry" ] && pkg_die2 "manifest L$ln: overlay sin separador ':'"
        pkg_validate_overlay_path "$ruta" "manifest L$ln"
        case "$seen_members" in *":$m:"*) : ;; *) pkg_die2 "manifest L$ln: overlay de member no declarado ($m — declarar member= ANTES)";; esac
        case "$seen_overlays" in *":$line:"*) pkg_die2 "manifest L$ln: overlay duplicado";; esac
        seen_overlays="$seen_overlays$line:"
        case "$line" in
          overlay=*) PKG_OVERLAY_EXACT+=("$m:$ruta") ;;
          *)         PKG_OVERLAY_PREFIX+=("$m:$ruta") ;;
        esac ;;
      *) pkg_die2 "manifest L$ln: línea fuera de la gramática cerrada" ;;
    esac
  done < "$mf"
  [ -n "$PKG_VERSION" ] || pkg_die2 "manifest: falta version="
  [ -n "$PKG_MIN_INV" ] || pkg_die2 "manifest: falta min_invariants="
  [ "${#PKG_MEMBERS[@]}" -ge 1 ] || pkg_die2 "manifest: cero members"
  case "$seen_members" in *":skill-creator:"*) : ;; *) pkg_die2 "manifest: skill-creator no es member (el archivo que define el paquete quedaría fuera del contrato)";; esac
  return 0
}

# Charset CERRADO de rutas/prefijos de overlay (M3): literales sin metacaracteres.
pkg_validate_overlay_path() {
  local ruta="$1" ctx="$2"
  [ -n "$ruta" ] || pkg_die2 "$ctx: ruta de overlay vacía"
  printf '%s' "$ruta" | command grep -Eq '^[A-Za-z0-9._/-]+$' || pkg_die2 "$ctx: ruta de overlay fuera del charset cerrado [A-Za-z0-9._/-] ($ruta)"
  case "$ruta" in
    /*) pkg_die2 "$ctx: ruta de overlay absoluta ($ruta)" ;;
    *//*) pkg_die2 "$ctx: ruta de overlay con '//' ($ruta)" ;;
  esac
  printf '%s' "$ruta" | command grep -Eq '(^|/)\.\.?(/|$)' && pkg_die2 "$ctx: componente ./.. prohibido en overlay ($ruta)"
  return 0
}

# --- Ruta REL estable del env del repo (identidad del orquestador) [B2-P0] ------------------
# Estructural: relativa, sin traversal, sin backslash, termina en /.env.local. La ESTABILIDAD
# (existencia bajo el HOME real, jamás un checkout transitorio) la verifica la migración.
pkg_validate_env_rel() {
  local v="$1" ctx="$2"
  [ -n "$v" ] || pkg_die2 "$ctx: TORC_HOST_ENV_REL vacío"
  case "$v" in
    /*) pkg_die2 "$ctx: TORC_HOST_ENV_REL absoluta ($v)" ;;
    *"\\"*) pkg_die2 "$ctx: TORC_HOST_ENV_REL con backslash ($v)" ;;
    */.env.local) : ;;
    *) pkg_die2 "$ctx: TORC_HOST_ENV_REL debe terminar en /.env.local ($v)" ;;
  esac
  printf '%s' "$v" | command grep -Eq '(^|/)\.\.?(/|$)' && pkg_die2 "$ctx: componente ./.. en TORC_HOST_ENV_REL ($v)"
  return 0
}

# --- Normalización de URL de repo → slug owner/repo (sellada, ERE POSIX) -------------------
# Acepta https://github.com/o/r(.git)(/), git@github.com:o/r(.git), ssh://git@github.com/o/r(.git).
# Cualquier otra forma → rc 2 del llamador (devuelve vacío + rc 1 aquí).
pkg_norm_repo_url() {
  local url="$1" slug
  slug="$(printf '%s' "$url" | sed -E -e 's#^https://github\.com/##' -e 's#^ssh://git@github\.com/##' -e 's#^git@github\.com:##' -e 's#\.git/?$##' -e 's#/$##')"
  if printf '%s' "$slug" | command grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    printf '%s' "$slug"; return 0
  fi
  return 1
}

# --- Parser de AUTORIDAD (manifiesto de proyecto TF_* del motor) — como DATOS ---------------
# Extrae SOLO TF_REPO_URL y TF_PROJECT; tolera el resto de líneas (claves TF_* legítimas,
# comentarios de continuación, etc.). Duplicado o malformación de las claves de autoridad → 2.
# Deriva: AUTH_SLUG (owner/repo normalizado) · AUTH_REPO_DIR (basename del slug — GO r4:
# JAMÁS TF_REPO_DIR) · AUTH_PROJECT. JAMÁS `source`.
pkg_parse_authority() {
  local af="$1" ln=0 line raw
  AUTH_PROJECT="" ; AUTH_REPO_URL="" ; AUTH_SLUG="" ; AUTH_REPO_DIR=""
  [ -f "$af" ] || pkg_die2 "autoridad: manifiesto de proyecto ausente ($af)"
  pkg_reject_bom_crlf_nul "$af" "autoridad $(basename "$af")"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    case "$line" in
      TF_REPO_URL=*)
        [ -n "$AUTH_REPO_URL" ] && pkg_die2 "autoridad L$ln: TF_REPO_URL duplicada"
        raw="$(pkg_strip_tf_value "${line#TF_REPO_URL=}")"
        [ -n "$raw" ] || pkg_die2 "autoridad L$ln: TF_REPO_URL vacía"
        AUTH_REPO_URL="$raw" ;;
      TF_PROJECT=*)
        [ -n "$AUTH_PROJECT" ] && pkg_die2 "autoridad L$ln: TF_PROJECT duplicada"
        raw="$(pkg_strip_tf_value "${line#TF_PROJECT=}")"
        [ -n "$raw" ] || pkg_die2 "autoridad L$ln: TF_PROJECT vacía"
        AUTH_PROJECT="$raw" ;;
      *) : ;;  # tolerado: el manifiesto real trae muchas claves TF_* y comentarios
    esac
  done < "$af"
  [ -n "$AUTH_REPO_URL" ] || pkg_die2 "autoridad: falta TF_REPO_URL en $(basename "$af")"
  [ -n "$AUTH_PROJECT" ]  || pkg_die2 "autoridad: falta TF_PROJECT en $(basename "$af")"
  AUTH_SLUG="$(pkg_norm_repo_url "$AUTH_REPO_URL")" || pkg_die2 "autoridad: TF_REPO_URL malformada ($AUTH_REPO_URL)"
  # shellcheck disable=SC2034  # salida pública de la lib (la consumen validate/sync)
  AUTH_REPO_DIR="${AUTH_SLUG#*/}"
  return 0
}

# Valor de una clave TF_ bajo gramática CERRADA [M1-P0]: o comillas dobles BALANCEADAS
# (con comentario posterior permitido) o token pelado sin espacios/comillas/#.
# Comilla desbalanceada o basura tras el cierre → rc 2 (fail-closed, jamás fail-open).
pkg_strip_tf_value() {
  local v="$1" resto
  case "$v" in
    '"'*)
      resto="${v#\"}"
      case "$resto" in
        *'"'*) : ;;
        *) pkg_die2 "autoridad: comilla sin cierre en el valor ($v)" ;;
      esac
      local dentro="${resto%%\"*}" cola="${resto#*\"}"
      # tras el cierre solo se admite vacío o comentario (espacios + #...)
      cola="${cola#"${cola%%[! ]*}"}"
      case "$cola" in ''|'#'*) : ;; *) pkg_die2 "autoridad: contenido inesperado tras la comilla de cierre ($v)" ;; esac
      case "$dentro" in *'"'*) pkg_die2 "autoridad: comillas anidadas en el valor ($v)" ;; esac
      printf '%s' "$dentro" ;;
    *)
      v="${v%%#*}"; v="${v%"${v##*[! ]}"}"
      case "$v" in *'"'*|*' '*) pkg_die2 "autoridad: valor sin comillas con comilla/espacio embebido ($v)" ;; esac
      printf '%s' "$v" ;;
  esac
}

# --- Gramática cerrada de repo-identity.conf (data-only, KEY=VALUE) -------------------------
# Claves permitidas (unión de los skills con identidad; el CONSUMIDOR exige las suyas):
#   PKG_IDENTITY_PROJECT (procedencia: TF_PROJECT de la autoridad con la que se migró — un conf
#   copiado de OTRO repo falla p4 aunque sus claves parseen) · TCO_REPO_DIR TCO_REPO_SLUG
#   TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE
#   TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL TORC_HOST_ENV_REL
#   TCO_TF_MANIFEST (opcional; ruta ABSOLUTA del manifiesto de fábrica de la instancia — TAL-8037)
# Clave desconocida / duplicada / valor vacío → rc 2. Variables resultado: PKGID_<clave>.
PKG_IDENTITY_KEYS="PKG_IDENTITY_PROJECT TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL TORC_HOST_ENV_REL TCO_TF_MANIFEST"

# [Ronda P0-2] Denylist CERRADA de marcadores de pendiente: un placeholder NUNCA es un valor
# adjudicado — publicar un paquete «operacionalmente incompleto» con apply verde es la clase B1.
# [TAL-8037/n2] El marcador del repo-identity.conf.example: SOLO el valor COMPLETO PENDIENTE-<CLAVE> (anclado, mayúsculas).
# Lo usan los cargadores runtime y validate-package --estado instancia (una instancia no puede conservar el marcador de la
# plantilla, pero sí valores legítimos como `todo` o `pendiente-app`). pkg_es_placeholder, más ancha, queda SOLO para la
# adjudicación (sync-package: un fragmento --approved con TBD/TODO/PLACEHOLDER* sigue siendo inválido) — contrato intacto.
pkg_es_marcador_example() { [[ $1 =~ ^PENDIENTE-[A-Z][A-Z0-9_]*$ ]]; }
pkg_es_placeholder() { case "$1" in PENDIENTE-*|pendiente-*|TBD|tbd|TODO|todo|PLACEHOLDER*|placeholder*) return 0 ;; *) return 1 ;; esac; }

# Formatos de las claves adjudicadas (ronda P0-2): UUID v4-like para estados Linear; ref
# Supabase [a-z0-9]{15,30} si stack=supabase; literal cerrado 'no-aplica' si stack=convex;
# stack=ninguno (sin backend gestionado, TAL-8037): TCO_SUPABASE_REF NO se exige — si viene,
# solo vale el literal 'no-aplica' (un ref real con stack=ninguno es una adjudicación incoherente).
pkg_validate_uuid() {
  printf '%s' "$1" | command grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}
# ¿La clave $1 de la adjudicación TCO es OBLIGATORIA con el stack $2? Solo TCO_SUPABASE_REF se relaja (stack=ninguno).
pkg_clave_tco_obligatoria() { [ "$1" = TCO_SUPABASE_REF ] && [ "$2" = ninguno ] && return 1; return 0; }
pkg_validate_identidad_formatos() { # stack supa inprog inrev ctx → die2 en malformato; rc 1 = adjudicación inválida (caller decide 3)
  local stack="$1" supa="$2" inprog="$3" inrev="$4" ctx="$5" v
  for v in "$stack" "$supa" "$inprog" "$inrev"; do
    pkg_es_placeholder "$v" && { printf 'ADJUDICACION INVALIDA (%s): marcador de pendiente (%s) — un placeholder no es un valor adjudicado\n' "$ctx" "$v" >&2; return 1; }
  done
  case "$stack" in supabase|convex|ninguno) : ;; *) printf 'ADJUDICACION INVALIDA (%s): TCO_REPO_STACK fuera del enum supabase|convex|ninguno (%s)\n' "$ctx" "$stack" >&2; return 1 ;; esac
  case "$stack" in
    supabase)
      printf '%s' "$supa" | command grep -Eq '^[a-z0-9]{15,30}$' || { printf 'ADJUDICACION INVALIDA (%s): TCO_SUPABASE_REF no casa el formato de ref (%s)\n' "$ctx" "$supa" >&2; return 1; } ;;
    convex)
      [ "$supa" = "no-aplica" ] || { printf 'ADJUDICACION INVALIDA (%s): con stack=convex TCO_SUPABASE_REF debe ser el literal no-aplica (%s)\n' "$ctx" "$supa" >&2; return 1; } ;;
    ninguno)
      { [ -z "$supa" ] || [ "$supa" = "no-aplica" ]; } || { printf 'ADJUDICACION INVALIDA (%s): con stack=ninguno TCO_SUPABASE_REF no se exige y, si viene, debe ser el literal no-aplica (%s)\n' "$ctx" "$supa" >&2; return 1; } ;;
  esac
  pkg_validate_uuid "$inprog" || { printf 'ADJUDICACION INVALIDA (%s): TCO_LINEAR_INPROGRESS_STATE no es UUID (%s)\n' "$ctx" "$inprog" >&2; return 1; }
  pkg_validate_uuid "$inrev"  || { printf 'ADJUDICACION INVALIDA (%s): TCO_LINEAR_INREVIEW_STATE no es UUID (%s)\n' "$ctx" "$inrev" >&2; return 1; }
  return 0
}
# Ruta del manifiesto de fábrica de la instancia (TCO_TF_MANIFEST): ABSOLUTA, sin ./.. (la lee el despacho como DATO).
pkg_validate_tf_manifest_path() {
  local v="$1" ctx="$2"
  case "$v" in
    /*) : ;;
    *) pkg_die2 "$ctx: TCO_TF_MANIFEST debe ser ruta ABSOLUTA ($v)" ;;
  esac
  case "$v" in *"\\"*) pkg_die2 "$ctx: TCO_TF_MANIFEST con backslash ($v)" ;; esac
  printf '%s' "$v" | command grep -Eq '(^|/)\.\.?(/|$)' && pkg_die2 "$ctx: componente ./.. en TCO_TF_MANIFEST ($v)"
  return 0
}
pkg_parse_identity_conf() {
  local cf="$1" ln=0 line k v seen=":"
  # shellcheck disable=SC2034  # salidas públicas de la lib (las consumen validate/sync)
  PKGID_PKG_IDENTITY_PROJECT=""
  # shellcheck disable=SC2034
  PKGID_TCO_REPO_DIR=""; PKGID_TCO_REPO_SLUG=""; PKGID_TCO_REPO_STACK=""; PKGID_TCO_ANEXO_FILE=""
  # shellcheck disable=SC2034
  PKGID_TCO_SUPABASE_REF=""; PKGID_TCO_LINEAR_INPROGRESS_STATE=""; PKGID_TCO_LINEAR_INREVIEW_STATE=""
  # shellcheck disable=SC2034
  PKGID_TCO_POSTMERGE_CMD=""; PKGID_TCO_HOST_ENV_REL=""; PKGID_TORC_HOST_ENV_REL=""; PKGID_TCO_TF_MANIFEST=""
  [ -f "$cf" ] || return 1   # ausencia: la adjudica el llamador (FAIL 1 en check, rc 2 en apply)
  pkg_reject_bom_crlf_nul "$cf" "repo-identity.conf"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    case "$line" in
      ""|"#"*) continue ;;
      *=*)
        k="${line%%=*}" ; v="${line#*=}"
        case " $PKG_IDENTITY_KEYS " in
          *" $k "*) : ;;
          *) pkg_die2 "repo-identity.conf L$ln: clave desconocida ($k)" ;;
        esac
        case "$seen" in *":$k:"*) pkg_die2 "repo-identity.conf L$ln: clave duplicada ($k)";; esac
        seen="$seen$k:"
        [ -n "$v" ] || pkg_die2 "repo-identity.conf L$ln: valor vacío para $k"
        [ "$k" = TCO_TF_MANIFEST ] && pkg_validate_tf_manifest_path "$v" "repo-identity.conf L$ln"
        printf -v "PKGID_$k" '%s' "$v" ;;
      *) pkg_die2 "repo-identity.conf L$ln: línea fuera de la gramática (KEY=VALUE)" ;;
    esac
  done < "$cf"
  return 0
}
