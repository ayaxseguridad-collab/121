#!/usr/bin/env bash
# validate-manifest.sh — Valida un MANIFIESTO del motor talent-factory (TAL-2296).
#
# Un manifiesto declara qué consume una fábrica del motor: el proyecto (TF_PROJECT), el repo objetivo
# (TF_REPO_URL) y el conjunto de claves que la fábrica usa. Este validador standalone comprueba, SIN
# ejecutar el manifiesto (nunca `source`/`eval` — mismo contrato que tc_load_intake_conf):
#   1) formato: solo líneas KEY=value con KEY en [A-Za-z][A-Za-z0-9_]* (blancas/comentario '#' se ignoran);
#      cualquier otra línea → RECHAZO (fail-closed). NB: la KEY admite minúsculas en el sufijo — el
#      manifiesto real las usa (p.ej. TF_GATE_CMD_typecheck / TF_GATE_CMD_db_guards: el gate-id va en
#      minúscula). Restringir a [A-Z] rechazaría el academy.conf real (verificado por el smoke de §13).
#   2) claves DUPLICADAS → RECHAZO (una fábrica no puede consumir dos valores de la misma clave).
#   3) claves consumidas REQUERIDAS presentes y NO vacías (TF_PROJECT y TF_REPO_URL siempre; + las de
#      --require K1,K2,…).
#   4) coincidencia: si se pasa --project/--repo, TF_PROJECT/TF_REPO_URL del manifiesto deben COINCIDIR
#      (comparando el valor SIN sus comillas shell envolventes).
#
# El validador vive en ESTE skill (talent-channels), no dentro del motor: se ejecuta contra la ruta
# del manifiesto — `validate-manifest.sh <ruta-al-manifiesto>` — durante el intake/retarget de una
# fábrica. No asume estar instalado en talent-factory.
#
# Uso:  validate-manifest.sh <manifiesto> [--project P] [--repo R] [--require K1,K2,...]
# Sourceable para tests con VM_NO_MAIN=1 (expone los predicados puros vm_*).
# shellcheck shell=bash
set -uo pipefail

# --- predicados puros (testeables) -----------------------------------------
# Líneas malformadas: NO blancas/comentario y que NO casan KEY=value con KEY válida. Emite cada una.
vm_malformed() {
  local f="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|[[:space:]]*'#'*|'#'*) continue;; esac
    printf '%s' "$line" | grep -qE '^[A-Za-z][A-Za-z0-9_]*=' && continue
    printf '%s\n' "$line"
  done < "$f"
}
# Claves (en orden de aparición) de las líneas KEY=value válidas.
vm_keys() {
  local f="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|[[:space:]]*'#'*|'#'*) continue;; esac
    printf '%s' "$line" | grep -qE '^[A-Za-z][A-Za-z0-9_]*=' || continue
    printf '%s\n' "${line%%=*}"
  done < "$f"
}
# Claves duplicadas (una por línea).
vm_dupes() { vm_keys "$1" | sort | uniq -d; }
# Valor de la PRIMERA aparición de <key> (vacío si ausente), con las comillas shell ENVOLVENTES
# normalizadas: los manifiestos reales del motor citan los valores (TF_PROJECT="academy",
# TF_REPO_URL="https://…"); sin normalizar, la comparación --project/--repo nunca casaría.
vm_get() {
  local f="$1" key="$2" line v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*)
      v="${line#*=}"
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}";;   # "valor" → valor
        \'*\') v="${v#\'}"; v="${v%\'}";;   # 'valor' → valor
      esac
      printf '%s' "$v"; return 0;;
    esac
  done < "$f"
  return 0
}
# rc 0 si <key> está presente con valor NO vacío.
vm_has() { local v; v="$(vm_get "$1" "$2")"; [ -n "$v" ]; }

# Decisión completa. Emite UN token de resultado; rc 0 solo si OK.
#   vm_validate <file> <proj-esperado|""> <repo-esperado|""> <require-csv|"">
vm_validate() {
  local f="$1" proj="${2:-}" repo="${3:-}" reqcsv="${4:-}" bad dup req k
  [ -f "$f" ] && [ -r "$f" ] || { echo "ABORT:no-legible"; return 1; }
  bad="$(vm_malformed "$f")"
  [ -z "$bad" ] || { echo "ABORT:malformado"; return 1; }
  dup="$(vm_dupes "$f")"
  [ -z "$dup" ] || { echo "ABORT:duplicado $(printf '%s' "$dup" | paste -sd, -)"; return 1; }
  # requeridas: TF_PROJECT y TF_REPO_URL siempre + las de --require. El manifiesto real declara el
  # repo objetivo como TF_REPO_URL (academy.conf), no TF_REPO.
  req="TF_PROJECT TF_REPO_URL"
  [ -n "$reqcsv" ] && req="$req $(printf '%s' "$reqcsv" | tr ',' ' ')"
  for k in $req; do
    vm_has "$f" "$k" || { echo "ABORT:falta $k"; return 1; }
  done
  [ -z "$proj" ] || [ "$(vm_get "$f" TF_PROJECT)" = "$proj" ]  || { echo "ABORT:project-mismatch"; return 1; }
  [ -z "$repo" ] || [ "$(vm_get "$f" TF_REPO_URL)" = "$repo" ] || { echo "ABORT:repo-mismatch"; return 1; }
  echo "OK"
  return 0
}

# --- main (CLI) -------------------------------------------------------------
vm_main() {
  local manifest="" proj="" repo="" reqcsv=""
  while [ $# -gt 0 ]; do case "$1" in
    --project) proj="$2"; shift 2;;
    --repo)    repo="$2"; shift 2;;
    --require) reqcsv="$2"; shift 2;;
    -h|--help) echo "uso: validate-manifest.sh <manifiesto> [--project P] [--repo R] [--require K1,K2,...]"; return 0;;
    -*) echo "ERROR: flag desconocido: $1" >&2; return 2;;
    *)  [ -z "$manifest" ] && manifest="$1" || { echo "ERROR: manifiesto ya especificado ('$manifest')" >&2; return 2; }; shift;;
  esac; done
  [ -n "$manifest" ] || { echo "ERROR: falta el manifiesto. uso: validate-manifest.sh <manifiesto> [--project P] [--repo R] [--require K1,K2,...]" >&2; return 2; }
  local res
  res="$(vm_validate "$manifest" "$proj" "$repo" "$reqcsv")"; local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "✅ manifiesto válido: $manifest"
  else
    echo "❌ manifiesto INVÁLIDO ($manifest): $res" >&2
  fi
  return "$rc"
}

[ "${VM_NO_MAIN:-0}" = "1" ] || vm_main "$@"
