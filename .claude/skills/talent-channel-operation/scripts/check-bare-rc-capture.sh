#!/usr/bin/env bash
# check-bare-rc-capture.sh — TAL-5172, orden CEO (v7): CHECK, no arreglo. Barre el UNIVERSO de
# scripts .sh del paquete de skills buscando una FORMA concreta, la misma que aparecio TRES veces
# en un solo dia en tres piezas distintas (PR-B: return muerto en el subshell de una tuberia; T05:
# flock ; _rc=$? bajo set -e; T04: is-ancestor ; rc=$? bajo set -euo pipefail — un solo dia, una
# sola causa, tres canales):
#
#   comando DESNUDO (sin `||`, sin ser la condicion de un `if`/`while`/`until`, sin `set +e`
#   acotado alrededor) seguido, en la linea SIGUIENTE no vacia/no comentario, de una referencia a
#   `$?`.
#
# Bajo `set -e` (o cualquier variante -eu/-euo pipefail), si ese comando termina con un `rc` NO
# CERO que es un RESULTADO LEGITIMO (no un fallo del script — "no es ancestro", "no se pudo tomar
# el lock", etc.), `set -e` mata la ejecucion ANTES de que la linea siguiente lea `$?`: el codigo
# que interpreta ese `rc` queda MUERTO, nunca se ejecuta con el valor que dice interpretar.
#
# ES LEXICO, A PROPOSITO (M2, TAL-5172 v7): no hay un parser de bash aqui, solo un heuristico de
# dos lineas. Por eso esto es un REPORT de CANDIDATOS, nunca un recuento de fallos confirmados
# (`--check` SIEMPRE sale 0 salvo error de uso): cada candidato se mira contra su fichero (¿tiene
# `set -e` propio? es riesgo por defecto salvo intencion explicita) y contra su llamador (un
# fichero SIN `set -e` propio es seguro a solas pero arriesgado si un caller con `set -e` lo
# fuentea/ejecuta) — arreglar los 21 a ciegas manda a "arreglar" lo que no esta roto.
#
# EL GATE REAL de este script es su PROPIA correccion como detector, no el estado del paquete:
#   bash check-bare-rc-capture.sh --self-test
# monta un control POSITIVO SINTETICO (tiene la forma; DEBE cazarse) y un control NEGATIVO con
# las TRES formas seguras (`|| rc=$?` · `if cmd; then` · `set +e` acotado; NINGUNA debe cazarse).
# Sale 1 si el detector falla cualquiera de los dos controles — un detector que nunca dispara y
# uno que dispara siempre son igual de inutiles sin ambos.
#
# Uso:
#   bash check-bare-rc-capture.sh --self-test          # verifica el propio detector (el gate real)
#   bash check-bare-rc-capture.sh [--root <dir>]        # barrido de candidatos, informativo, exit 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- El detector, aislado en una función para que --self-test y el barrido real usen EL MISMO
#     código (nunca una reimplementación paralela que un cambio aquí podría dejar de proteger). ---
# Stdout por candidato: "<línea-comando>:<línea-$?>" (números 1-based). Nunca falla por sí mismo
# (fail-closed lo decide el llamador, no la función).
_bare_rc_capture_scan() { # <fichero>
  local f="$1"
  awk '
    function is_blank_or_comment(s) { return (s ~ /^[[:space:]]*$/ || s ~ /^[[:space:]]*#/) }
    function is_structural(s) {
      # palabras clave de estructura, no comandos: no cuentan como "bare" ni rompen la cadena
      # de análisis (el else/then/fi de un if ya evaluado no es un comando nuevo que pueda
      # matar el script bajo set -e).
      return (s ~ /^[[:space:]]*(then|else|elif|fi|do|done|esac|\{|\})[[:space:]]*;?[[:space:]]*(then)?[[:space:]]*$/)
    }
    function sets_lenient(s)  { return (s ~ /^[[:space:]]*set[[:space:]]+\+[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)/) }
    function sets_strict(s)   { return (s ~ /^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)/) }
    function is_guard_line(s) {
      # línea que YA neutraliza set -e para el comando que trae: || ... , if/while/until como
      # cabecera, o un ajuste explícito de set +e/-e en la misma línea.
      return (s ~ /\|\|/ || s ~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/ \
              || sets_lenient(s) || sets_strict(s))
    }
    function is_plain_assignment(s) {
      # var=literal (o var=$var, var="texto") sin sustitución de comando: no puede fallar de
      # forma que le importe a set -e — no cuenta como "comando desnudo" que arriesgue $?.
      return (s ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\+?=/ && s !~ /\$\(/ && s !~ /`/)
    }
    function is_bare_candidate(s) {
      if (is_blank_or_comment(s)) return 0
      if (is_structural(s)) return 0
      if (is_guard_line(s)) return 0
      if (is_plain_assignment(s)) return 0
      if (s ~ /\$\?/) return 0
      return 1
    }
    {
      lines[NR] = $0
    }
    END {
      prev_bare = 0
      prev_ln = 0
      lenient = 0   # dentro de un bloque set +e ... set -e: nada puede matar el script aquí
      for (i = 1; i <= NR; i++) {
        s = lines[i]
        if (is_blank_or_comment(s)) continue
        if (sets_lenient(s)) { lenient = 1; prev_bare = 0; prev_ln = i; continue }
        if (sets_strict(s))  { lenient = 0; prev_bare = 0; prev_ln = i; continue }
        if (is_structural(s)) continue   # no cuenta como línea, no rompe prev_bare
        if (!lenient && prev_bare && (s ~ /\$\?/)) {
          print prev_ln ":" i
        }
        prev_bare = lenient ? 0 : is_bare_candidate(s)
        prev_ln = i
      }
    }
  ' "$f"
}

# --- --self-test: control positivo + control negativo sobre el MISMO _bare_rc_capture_scan. ---
_self_test() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # CONTROL POSITIVO — tiene la forma exacta de los tres hallazgos reales de hoy. DEBE cazarse.
  cat > "$tmp/positivo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git merge-base --is-ancestor "$sha" "$rama" 2>/dev/null
rc=$?
case "$rc" in
  0) echo ok ;;
esac
EOF

  # CONTROL NEGATIVO — las TRES formas seguras. NINGUNA debe cazarse.
  cat > "$tmp/negativo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# forma segura 1: || rc=$? en la MISMA línea
comando_uno || rc=$?
# forma segura 2: el comando es la condición de un if
if comando_dos; then
  rc=0
else
  rc=$?
fi
# forma segura 3: set +e acotado alrededor del comando
set +e
comando_tres
rc=$?
set -e
EOF

  local pos_hits neg_hits
  pos_hits="$(_bare_rc_capture_scan "$tmp/positivo.sh" | wc -l | tr -d ' ')"
  neg_hits="$(_bare_rc_capture_scan "$tmp/negativo.sh" | wc -l | tr -d ' ')"

  local fail=0
  if [ "$pos_hits" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO no se cazó (0 candidatos; se esperaba >=1) — el detector nunca dispara, es decoración." >&2
    fail=1
  else
    echo "self-test positivo: OK ($pos_hits candidato(s) cazado(s), esperado >=1)"
  fi
  if [ "$neg_hits" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO cazó $neg_hits candidato(s) sobre las TRES formas seguras (esperado 0) — el detector dispara siempre, es decoración." >&2
    fail=1
  else
    echo "self-test negativo: OK (0 candidatos sobre las 3 formas seguras, como se esperaba)"
  fi
  return "$fail"
}

# Extrae cada bloque ```bash / ```sh de un .md a un fichero temporal propio y devuelve, por
# fichero temporal, "linea-de-inicio-del-fence-en-el-.md<TAB>tmpfile". El hallazgo motivador de
# este check (T04, 04-protocolo-auditoria.md) vive DENTRO de un fence de doc, no en un .sh — un
# barrido que solo mirara *.sh no habría cazado su propio caso fundador.
_extract_md_fences() { # <fichero.md>
  local f="$1"
  awk -v outdir="$2" '
    BEGIN { infence=0; n=0 }
    /^[[:space:]]*```(bash|sh)[[:space:]]*$/ && !infence {
      infence=1; n++; startline=NR+1; outfile = outdir "/fence" n ".sh"; print startline"\t"outfile
      next
    }
    /^[[:space:]]*```[[:space:]]*$/ && infence { infence=0; next }
    infence { print > outfile }
  ' "$f"
}

# --- Barrido real: universo de .sh + fences bash/sh en .md bajo --root. ---
_sweep() {
  local root="$1"
  local total=0 con_sete=0 sin_sete=0
  local f hits ln1 ln2 file_has_sete
  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  # 1) Scripts .sh reales.
  while IFS= read -r f; do
    hits="$(_bare_rc_capture_scan "$f" || true)"
    [ -n "$hits" ] || continue
    if grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$f"; then file_has_sete=1; else file_has_sete=0; fi
    while IFS=: read -r ln1 ln2; do
      [ -n "$ln1" ] || continue
      total=$((total+1))
      if [ "$file_has_sete" -eq 1 ]; then
        con_sete=$((con_sete+1))
        echo "CANDIDATO [.sh][set-e-propio: SÍ, riesgo por defecto] $f:$ln1 -> \$? leído en :$ln2"
      else
        sin_sete=$((sin_sete+1))
        echo "CANDIDATO [.sh][set-e-propio: NO, seguro a solas / riesgo si un caller con set -e lo fuentea] $f:$ln1 -> \$? leído en :$ln2"
      fi
    done <<< "$hits"
  done < <(find "$root" -name '*.sh' -type f 2>/dev/null | sort)

  # 2) Bloques ```bash / ```sh dentro de .md — cada fence es un contexto independiente (mismo
  #    tratamiento que un fichero .sh propio: su propio set -e, si lo declara).
  local mdf fencedir entry startline tmpfile
  while IFS= read -r mdf; do
    fencedir="$(mktemp -d --tmpdir="$tmpdir")"
    _extract_md_fences "$mdf" "$fencedir" > "$fencedir/.index"
    [ -s "$fencedir/.index" ] || continue
    while IFS=$'\t' read -r startline tmpfile; do
      [ -f "$tmpfile" ] || continue
      hits="$(_bare_rc_capture_scan "$tmpfile" || true)"
      [ -n "$hits" ] || continue
      if grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$tmpfile"; then file_has_sete=1; else file_has_sete=0; fi
      while IFS=: read -r ln1 ln2; do
        [ -n "$ln1" ] || continue
        total=$((total+1))
        real_ln1=$((startline + ln1 - 1))
        real_ln2=$((startline + ln2 - 1))
        if [ "$file_has_sete" -eq 1 ]; then
          con_sete=$((con_sete+1))
          echo "CANDIDATO [.md fence][set-e-propio: SÍ, riesgo por defecto] $mdf:$real_ln1 -> \$? leído en :$real_ln2"
        else
          sin_sete=$((sin_sete+1))
          echo "CANDIDATO [.md fence][set-e-propio: NO, seguro a solas / riesgo si un caller con set -e lo fuentea] $mdf:$real_ln1 -> \$? leído en :$real_ln2"
        fi
      done <<< "$hits"
    done < "$fencedir/.index"
  done < <(find "$root" -name '*.md' -type f 2>/dev/null | sort)

  echo
  echo "TOTAL candidatos: $total (con set -e propio: $con_sete · sin set -e propio: $sin_sete)"
  echo "Recordatorio (M2, TAL-5172 v7): esto es COTA SUPERIOR DE CANDIDATOS por método lexico,"
  echo "NO recuento de fallos confirmados. Cada uno se mira contra su fichero y su llamador antes"
  echo "de tocar nada — no se arregla a ciegas."
}

mode=sweep
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) mode=self-test ;;
    --root) root="${2:?--root requiere argumento}"; shift ;;
    *) echo "argumento no reconocido: $1 (uso: --self-test | --root <dir>)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$mode" = "self-test" ]; then
  _self_test
  exit $?
fi

[ -n "$root" ] || root="$(cd "$HERE/../.." && pwd)"   # default: <repo>/.claude/skills
[ -d "$root" ] || { echo "no existe el directorio: $root" >&2; exit 2; }
_sweep "$root"
exit 0
