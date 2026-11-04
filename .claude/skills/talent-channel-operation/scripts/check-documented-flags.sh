#!/usr/bin/env bash
# check-documented-flags.sh — TAL-5172, rebote v8 (CR de M2 sobre v7, hallazgo [1] verificado por
# C2: REAL pero mas estrecho de lo dicho). check-bare-rc-capture.sh documentaba en su cabecera de
# uso un flag (`--scope-only-report`) que el bucle de argumentos NUNCA parseaba: caia al `*)` y
# fallaba ruidoso (eso ya estaba bien — la mitad "falla ruidoso" de la clase ya se cumplia), pero
# la cabecera prometia algo que no existia. Clase, en una linea (encargo v8 de C2): TODO FLAG
# DOCUMENTADO EXISTE.
#
# ES LEXICO, A PROPOSITO: compara los tokens `--flag` citados en el bloque de comentario "# Uso:"
# de un script contra los tokens `--flag` que aparecen como patrones de un `case ... esac` en el
# MISMO fichero. Un flag documentado que no aparece como patron del case es una promesa rota.
#
# LIMITE CONOCIDO (medido, v8): solo reconoce flags parseados via patron de CASE-ARM
# (`--foo)`/`--foo|--bar)`). Un flag parseado via comparacion `if [ "$1" = --foo ]` (sin case) NO
# se detecta como "parseado" y sale como falso positivo — ejemplo real: audit-gate.sh --parse-only
# (linea 171, `if [ "${1:-}" = --parse-only ]`), NO es una promesa rota, es un limite del metodo
# lexico. COTA SUPERIOR DE CANDIDATOS, igual que check-bare-rc-capture.sh: cada candidato se
# verifica a mano contra el fichero antes de tocar nada.
#
# EL GATE REAL es su propia correccion como detector (mismo patron que check-bare-rc-capture.sh):
#   bash check-documented-flags.sh --self-test
# control POSITIVO SINTETICO: cabecera que promete un flag inexistente DEBE cazarse.
# control NEGATIVO: cabecera y case coherentes -> cero.
#
# Uso:
#   bash check-documented-flags.sh --self-test          # verifica el propio detector (el gate real)
#   bash check-documented-flags.sh [--root <dir>]        # barrido de candidatos, informativo, exit 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- El detector, aislado en una función. Stdout: un flag "prometido pero no parseado" por línea.
#     Nunca falla por sí mismo (fail-closed lo decide el llamador, no la función). ---
_documented_flags_scan() { # <fichero>
  local f="$1"
  awk '
    BEGIN { in_uso = 0 }
    # Bloque de cabecera de uso: desde la línea que contiene "# Uso:" (o "# Usage:", variante en
    # inglés por si algún script del paquete usa esa palabra) hasta la primera línea que deja de
    # ser comentario `#`.
    /^#[[:space:]]*(Uso|Usage)[[:space:]]*:/ { in_uso = 1; next }
    in_uso && $0 !~ /^#/ { in_uso = 0 }
    in_uso {
      line = $0
      while (match(line, /--[A-Za-z][A-Za-z0-9-]*/)) {
        tok = substr(line, RSTART, RLENGTH)
        documented[tok] = 1
        line = substr(line, RSTART + RLENGTH)
      }
    }
    # Patrones de `case` para flags: líneas tipo `  --foo|--bar)` o `  --foo)` — puede haber
    # varios flags separados por "|" en el mismo patrón.
    /^[[:space:]]*--[A-Za-z0-9|-]*\)/ {
      line = $0
      while (match(line, /--[A-Za-z][A-Za-z0-9-]*/)) {
        tok = substr(line, RSTART, RLENGTH)
        parsed[tok] = 1
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END {
      for (tok in documented) {
        if (!(tok in parsed)) print tok
      }
    }
  ' "$f"
}

# --- --self-test: control positivo + control negativo sobre el MISMO _documented_flags_scan. ---
_self_test() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # CONTROL POSITIVO — la cabecera promete un flag (--fantasma) que el case NUNCA parsea. DEBE
  # cazarse.
  cat > "$tmp/positivo.sh" <<'EOF'
#!/usr/bin/env bash
# Uso:
#   bash positivo.sh --self-test
#   bash positivo.sh --root <dir> --fantasma
set -euo pipefail
mode=sweep
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) mode=self-test ;;
    --root) root="${2:?}"; shift ;;
    *) echo "argumento no reconocido: $1" >&2; exit 2 ;;
  esac
  shift
done
EOF

  # CONTROL NEGATIVO — cabecera y case coherentes (mismos flags en ambos lados). NINGUNO debe
  # cazarse.
  cat > "$tmp/negativo.sh" <<'EOF'
#!/usr/bin/env bash
# Uso:
#   bash negativo.sh --self-test
#   bash negativo.sh [--root <dir>]
set -euo pipefail
mode=sweep
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) mode=self-test ;;
    --root) root="${2:?}"; shift ;;
    *) echo "argumento no reconocido: $1" >&2; exit 2 ;;
  esac
  shift
done
EOF

  local pos_hits neg_hits
  pos_hits="$(_documented_flags_scan "$tmp/positivo.sh" | wc -l | tr -d ' ')"
  neg_hits="$(_documented_flags_scan "$tmp/negativo.sh" | wc -l | tr -d ' ')"

  local fail=0
  if [ "$pos_hits" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO no se cazó (0 flags fantasma; se esperaba >=1) — el detector nunca dispara, es decoración." >&2
    fail=1
  else
    echo "self-test positivo: OK ($pos_hits flag(s) fantasma cazado(s), esperado >=1)"
  fi
  if [ "$neg_hits" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO cazó $neg_hits flag(s) sobre una cabecera coherente (esperado 0) — el detector dispara siempre, es decoración." >&2
    fail=1
  else
    echo "self-test negativo: OK (0 flags fantasma sobre cabecera/case coherentes, como se esperaba)"
  fi
  return "$fail"
}

# --- Barrido real: todos los .sh bajo --root. ---
_sweep() {
  local root="$1"
  local total=0
  local f hits
  while IFS= read -r f; do
    hits="$(_documented_flags_scan "$f" || true)"
    [ -n "$hits" ] || continue
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      total=$((total+1))
      echo "CANDIDATO $f: cabecera promete '$tok', el case no lo parsea"
    done <<< "$hits"
  done < <(find "$root" -name '*.sh' -type f 2>/dev/null | sort)
  echo
  echo "TOTAL candidatos: $total"
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
