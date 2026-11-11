#!/usr/bin/env bash
# nombre-sesion.sh — Nombre de ARRANQUE de la sesión claude de un pane (talent-ceo, issue 8571).
#
# Repo-agnóstico, token-only, sin MCP. Solo lectura: `ps` (tabla de procesos) y `/proc/<pid>/cmdline`.
#
# Uso:
#   nombre-sesion.sh --observado PID…            # imprime SOLO el valor tras --name / -n
#   nombre-sesion.sh --verificar ESPERADO PID…   # compara con ESPERADO; emite OK|FALLA|NOVERIF nombre ESPERADO
#   nombre-sesion.sh --help
#
# PID… son los pids de pane (`tmux list-panes -F '#{pane_pid}'`): se busca entre ellos y sus
# descendientes el proceso `claude`.
#
# rc: 0 = nombre leído (o igual al esperado)
#     1 = no hay nombre acreditable; stderr lleva UNA palabra:
#         SIN-PROCESO     ningún descendiente cuyo ejecutable (comm) sea `claude`
#         SIN-NOMBRE      el `claude` elegido no lleva --name/-n como argumento propio, o no trae valor
#         NOMBRE-INVALIDO el valor (el argumento siguiente, COMPLETO) no cumple [A-Za-z0-9_-]{1,64}
#         NOMBRE-DISTINTO (solo --verificar) lleva esperado=… observado=…
#     2 = no verificable (uso incorrecto, `ps` ausente o sin respuesta, argv ilegible o vacío,
#         RAIZ-PROC-NO-PERMITIDA): nunca es verde
#
# ── POR QUÉ EL PROCESO SE ELIGE POR `comm` ─────────────────────────────────────────────────────
# Un patrón sobre la LÍNEA DE COMANDOS casa a quien MENCIONA «claude --name ceo» (un `bash -c`, un
# `grep`, un editor), no a quien lo ES: así un proceso ajeno acreditaría el nombre de una torre
# que no lo lleva. El ejecutable (`comm`) manda —misma regla que `doctor.sh`, `descendientes_comm`—
# y SOLO del pid ya elegido se lee el argv. Es el nombre de ARRANQUE: un `/rename` en caliente no
# aparece en el argv y esta herramienta no lo acredita.
#
# ── POR QUÉ EL ARGV SE LEE DE /proc/<pid>/cmdline Y NO DE `ps -o args=` ───────────────────────
# `ps -o args=` aplana el argv con espacios y pierde los límites de los argumentos: `--name "ceo otro"`
# se vería como el nombre `ceo`, y un prompt «explica --name ceo» como una opción. `cmdline` separa
# los argumentos con NUL: `--name` / `-n` solo cuenta como opción si es un argumento propio, y su valor
# es el argumento siguiente, entero (`--name=valor` en un único argumento NO cuenta). Tras `--` nada es
# opción. Lectura vacía, imposible o incompleta (sin NUL final): rc 2.
# TF_PROC_ROOT existe solo para que las pruebas inyecten una raíz y solo se acepta bajo el directorio
# temporal (`${TMPDIR:-/tmp}`, resueltos `..` y enlaces, nunca igual a él ni `/` ni `/proc`); cualquier otro
# valor da rc 2 con RAIZ-PROC-NO-PERMITIDA. En producción no se define y la raíz es /proc.
#
# Del argv jamás se imprime nada más que el valor del nombre ya validado.
set -uo pipefail
export LC_ALL=C

NOMBRE_RE='^[A-Za-z0-9_-]{1,64}$'

uso() {
  sed -n '6,10p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# elegir_claude PID… — imprime el pid del `claude` (por comm) descendiente de los pids raíz (o
# ellos mismos) más cercano a la raíz; a igual profundidad, el de pid menor.
# rc 0 = elegido · 1 = ninguno · 2 = `ps` no responde.
elegir_claude() {
  local tabla elegido
  tabla="$(ps -e -o pid=,ppid=,comm= 2>/dev/null)" || return 2
  [ -n "$tabla" ] || return 2
  elegido="$(printf '%s\n' "$tabla" | TA_ROOTS="$*" awk '
    BEGIN { n = split(ENVIRON["TA_ROOTS"], r, /[ \n]+/); for (i = 1; i <= n; i++) if (r[i] != "") raiz[r[i]] = 1 }
    {
      pid = $1; par[pid] = $2; c = ""
      for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i
      com[pid] = c
    }
    END {
      mejor = ""; prof = 1000
      for (p in com) {
        if (com[p] != "claude") continue
        q = p; d = 0
        while (q != "" && d < 64) {
          if (q in raiz) { if (d < prof || (d == prof && p + 0 < mejor + 0)) { prof = d; mejor = p }; break }
          q = par[q]; d++
        }
      }
      if (mejor != "") print mejor
    }')" || return 2
  [ -n "$elegido" ] || return 1
  printf '%s\n' "$elegido"
}

# leer_nombre PID — deja en OBS_NOMBRE el valor del argumento que sigue a --name / -n en el argv de
# ESE pid, con los límites de los argumentos (cmdline separado por NUL). Primera aparición; tras `--`
# nada cuenta. rc 0 = valor · 1 = SIN-NOMBRE o NOMBRE-INVALIDO (en OBS_CAUSA) · 2 = argv ilegible/vacío.
leer_nombre() {
  local raiz="$RAIZ_PROC" toks=() i=0 valor='' visto=0 resto=''
  [ -f "$raiz/$1/cmdline" ] && [ -r "$raiz/$1/cmdline" ] || return 2
  # Cada argumento termina en NUL. Un último fragmento sin NUL puede ser una lectura truncada: el registro
  # está incompleto y se rechaza ANTES de buscar el nombre. Sin NUL alguno (representación plana) también.
  while IFS= read -r -d '' resto; do toks+=("$resto"); done < "$raiz/$1/cmdline" 2>/dev/null
  [ -z "$resto" ] || return 2
  [ "${#toks[@]}" -gt 0 ] || return 2
  while [ "$i" -lt "${#toks[@]}" ]; do
    case "${toks[$i]}" in
      --) break ;;
      --name|-n)
        visto=1
        valor="${toks[$((i + 1))]-}"
        case "$valor" in -*) valor='' ;; esac
        break ;;
    esac
    i=$((i + 1))
  done
  if [ "$visto" -eq 0 ] || [ -z "$valor" ]; then OBS_CAUSA=SIN-NOMBRE; return 1; fi
  if [[ ! $valor =~ $NOMBRE_RE ]]; then OBS_CAUSA=NOMBRE-INVALIDO; return 1; fi
  OBS_NOMBRE="$valor"
}

# observar PID… — rc 0 (OBS_NOMBRE) · rc 1 (OBS_CAUSA = SIN-PROCESO|SIN-NOMBRE|NOMBRE-INVALIDO) · rc 2.
OBS_NOMBRE=''; OBS_CAUSA=''; RAIZ_PROC=/proc

# raiz_proc — imprime la raíz de /proc que se usará. Sin TF_PROC_ROOT es /proc. Con TF_PROC_ROOT (aunque
# esté vacía) su `realpath -e` debe quedar ESTRICTAMENTE dentro de `realpath -e "${TMPDIR:-/tmp}"` (nunca
# igual) y no puede ser `/`, `/proc` ni colgar de `/proc`; `..` y enlaces ya vienen resueltos. rc 1 si no.
raiz_proc() {
  local pedida real base
  if [ -z "${TF_PROC_ROOT+x}" ]; then printf '/proc\n'; return 0; fi
  pedida="$TF_PROC_ROOT"
  [[ $pedida == /* ]] || return 1
  real="$(realpath -e -- "$pedida" 2>/dev/null)" || return 1
  base="$(realpath -e -- "${TMPDIR:-/tmp}" 2>/dev/null)" || return 1
  case "$real" in /|/proc|/proc/*) return 1 ;; esac
  case "$base" in /|/proc|/proc/*) return 1 ;; esac
  case "$real" in "$base"/*) ;; *) return 1 ;; esac
  printf '%s\n' "$real"
}

observar() {
  local pid rc
  RAIZ_PROC="$(raiz_proc)" || { OBS_CAUSA=RAIZ-PROC-NO-PERMITIDA; return 2; }
  command -v ps >/dev/null 2>&1 || { OBS_CAUSA=NO-VERIFICABLE; return 2; }
  pid="$(elegir_claude "$@")"; rc=$?
  case "$rc" in
    0) ;;
    1) OBS_CAUSA=SIN-PROCESO; return 1 ;;
    *) OBS_CAUSA=NO-VERIFICABLE; return 2 ;;
  esac
  leer_nombre "$pid"; rc=$?
  [ "$rc" -ne 2 ] || OBS_CAUSA=NO-VERIFICABLE
  return "$rc"
}

pids_ok() { # PID… — cada argumento ENTERO es un entero positivo (sin saltos de línea) y hay al menos uno
  local p
  [ $# -gt 0 ] || return 1
  for p in "$@"; do [[ $p =~ ^[1-9][0-9]*$ ]] || return 1; done
}

main() {
  local esperado rc
  case "${1-}" in
    --observado)
      shift
      pids_ok "$@" || uso
      observar "$@"; rc=$?
      if [ "$rc" -eq 0 ]; then printf '%s\n' "$OBS_NOMBRE"; else printf '%s\n' "$OBS_CAUSA" >&2; fi
      exit "$rc" ;;
    --verificar)
      shift
      [ $# -ge 2 ] || uso
      esperado="$1"; shift
      [[ $esperado =~ $NOMBRE_RE ]] || uso
      pids_ok "$@" || uso
      observar "$@"; rc=$?
      case "$rc" in
        0)
          if [ "$OBS_NOMBRE" = "$esperado" ]; then
            printf 'OK nombre %s\n' "$esperado"; exit 0
          fi
          printf 'NOMBRE-DISTINTO esperado=%s observado=%s\n' "$esperado" "$OBS_NOMBRE" >&2
          printf 'FALLA nombre %s\n' "$esperado"; exit 1 ;;
        1)
          printf '%s\n' "$OBS_CAUSA" >&2
          printf 'FALLA nombre %s\n' "$esperado"; exit 1 ;;
        *)
          printf '%s\n' "${OBS_CAUSA:-NO-VERIFICABLE}" >&2
          printf 'NOVERIF nombre %s\n' "$esperado"; exit 2 ;;
      esac ;;
    --help|-h) sed -n '6,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) uso ;;
  esac
}

main "$@"
