#!/usr/bin/env bash
# check-doctrina-cola-coherente.sh — TAL-5172, rebote v8 (CR de M2 sobre v7, hallazgo [3]: C2 NO
# reprodujo la contradicción citada por M2. Verificado independientemente (esta misma sesión):
# SKILL.md líneas 38-39 y 90 mencionan «cola de 2» siempre junto a "SUPERSEDED"/"superseded" en la
# MISMA línea, y la única otra aparición del texto parecido (línea 351, "dos canales, dos
# encargos") es evidencia de staleness del plan-gate en DOS episodios separados, no una afirmación
# de profundidad de cola — no es la misma frase ni el mismo tema. NO se reescribe doctrina que ya
# está bien. El entregable es el ORÁCULO que impediría que la contradicción real apareciera si
# algún día se reintrodujera.
#
# Clase, en una línea (encargo v8 de C2): LA DOCTRINA DE COLA NO SE CONTRADICE A SÍ MISMA.
#
# ES LÉXICO, A PROPÓSITO: busca menciones de "cola de 2" / "cola-de-2" que NO llevan, en la MISMA
# línea, un marcador de historicidad (supersed*, caduc*, histór*/histor*, deprecad*, retirad*,
# obsolet*). Si existe al menos una mención VIGENTE (sin marcador) de "cola de 2" Y, en el mismo
# documento, también existe una afirmación de "un encargo por canal" / "1 encargo por canal",
# ambas son contradictorias entre sí y el check falla ruidoso.
#
# EL GATE REAL es su propia corrección como detector:
#   bash check-doctrina-cola-coherente.sh --self-test
# control POSITIVO SINTÉTICO: doc que afirma "cola de 2" SIN marcador de histórico Y "un encargo
# por canal" a la vez -> DEBE cazarse. control NEGATIVO: mismo patrón que el SKILL.md real hoy
# ("cola de 2" siempre acompañada de "superseded" en la misma línea) -> cero.
#
# LÍMITE CORREGIDO (medido, v9, CR de M2 confirmado por C2): `hist[oó]ric` fallaba en minúscula
# ("histórica" no casaba). Causa: el awk vigente en esta flota es mawk, byte-orientado — `[oó]` no
# es "la letra o o la letra ó" sino una clase de BYTES {o, 0xC3, 0xB3} (los dos bytes UTF-8 de 'ó'
# tratados como alternativas SUELTAS), y esos dos bytes nunca aparecen SUELTOS en "histórico": solo
# aparecen JUNTOS como el carácter 'ó'. Verificado: `awk '{print (tolower($0) ~ /hist[oó]ric/)}'`
# sobre "histórica" da 0 (no casa) bajo mawk. Dirección del fallo: FALSO POSITIVO, no fail-open —
# una línea que SÍ está marcada como histórica deja de reconocerse como tal y dispara una
# CONTRADICCION que no es real (ensucia, no abre la puerta). Fix verificado por M2: alternación
# explícita de las dos secuencias de bytes UTF-8, `hist(o|\303\263|\303\223)ric` (\303\263 = 'ó',
# \303\223 = 'Ó' — tolower() de mawk tampoco convierte 'Ó'→'ó' por ser no-ASCII, así que hacen
# falta las DOS alternativas). Lección del propio M2 sobre su primer intento de control: una línea
# de prueba que casa por OTRA palabra ("retirad") además de por el acento no aísla la variable —
# el self-test de abajo usa fixtures que llevan "histórico" como ÚNICO marcador, ninguna otra
# palabra de la lista.
#
# ALCANCE DEL BARRIDO (medido, v8): el sweep excluye `CHANGELOG.md` por diseño. Un changelog es
# un registro HISTÓRICO por género — "## 6.30 — Cola de 2..." afirma un hecho DEL PASADO ("esto se
# introdujo en 6.30"), no un estado VIGENTE, y por eso no necesita anotación "superseded" junto a
# cada mención para ser verdadero. Aplicar este heurístico sin excepción a CHANGELOG.md producía
# falsos positivos (líneas 139/166/279 de este skill) que no son la clase que este check persigue
# — la clase es doctrina VIGENTE contradictoria, no una entrada de historial fechada. Mismo
# tratamiento que los ADRs: inmutables, no se “corrigen” con este check.
#
# Uso:
#   bash check-doctrina-cola-coherente.sh --self-test         # verifica el propio detector (el gate real)
#   bash check-doctrina-cola-coherente.sh [--root <dir>]       # barrido de .md, informativo, exit 0/1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- El detector, aislado en una función. Stdout: líneas "COLA-DE-2 SIN MARCA HISTORICA: ..." por
#     cada mención vigente encontrada, y una línea final "CONTRADICCION" si además el documento
#     afirma "un encargo por canal" en algún sitio. Nunca falla por sí misma. ---
_cola_contradiction_scan() { # <fichero>
  local f="$1"
  awk '
    function tolow(s) { return tolower(s) }
    {
      lc = tolow($0)
      if (lc ~ /cola de 2|cola-de-2/) {
        if (lc ~ /supersed|caduc|hist(o|\303\263|\303\223)ric|deprecad|retirad|obsolet/) {
          # marcado como histórico en la MISMA línea: no cuenta como afirmación vigente.
        } else {
          cola2_vigente = 1
          print "COLA-DE-2 SIN MARCA HISTORICA: " FILENAME ":" NR ": " $0
        }
      }
      if (lc ~ /un encargo por canal|1 encargo por canal/) {
        un_encargo = 1
      }
    }
    END {
      if (cola2_vigente && un_encargo) print "CONTRADICCION"
    }
  ' "$f"
}

# --- --self-test: control positivo + control negativo sobre el MISMO _cola_contradiction_scan. ---
_self_test() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # CONTROL POSITIVO — "cola de 2" vigente (sin marca histórica) Y "un encargo por canal" a la
  # vez. DEBE cazarse.
  cat > "$tmp/positivo.md" <<'EOF'
Doctrina vigente: mantenemos cola de 2 encargos activos por canal para paralelismo.
Cada canal procesa un encargo por canal en la ronda actual.
EOF

  # CONTROL NEGATIVO — mismo patrón que SKILL.md real: "cola de 2" siempre junto a "superseded"
  # en la misma línea. NO debe cazarse.
  cat > "$tmp/negativo.md" <<'EOF'
La «cola de 2» que introdujo la versión anterior queda SUPERSEDED por la vigente: un encargo por canal.
EOF

  # CONTROL NEGATIVO [acento, minúscula] — v9, CR de M2. "histórica" (con tilde) como ÚNICO
  # marcador de historicidad — SIN "supersed"/"caduc"/"retirad"/"deprecad"/"obsolet" en la misma
  # línea, para AISLAR la variable (lección del propio M2: su primer intento medía "retirad", no
  # el acento). Bajo el bug de v8 esta línea NO se reconocía como histórica -> CONTRADICCION
  # falsa. NO debe cazarse tras el fix.
  cat > "$tmp/negativo-tilde-minuscula.md" <<'EOF'
La cola de 2 es una referencia histórica de la versión anterior. Hoy es un encargo por canal.
EOF

  # CONTROL NEGATIVO [acento, mayúscula] — misma aislación, con "HISTÓRICO" en mayúsculas: tras
  # tolower() en mawk queda "histÓrico" (la Ó no-ASCII no se convierte), ejercitando la SEGUNDA
  # alternativa de bytes del fix (\303\223). NO debe cazarse tras el fix.
  cat > "$tmp/negativo-tilde-mayuscula.md" <<'EOF'
La cola de 2 es HISTÓRICO. Hoy es un encargo por canal.
EOF

  local pos_out neg_out neg_tilde_min_out neg_tilde_may_out
  local pos_contra neg_contra neg_tilde_min_contra neg_tilde_may_contra
  pos_out="$(_cola_contradiction_scan "$tmp/positivo.md")"
  neg_out="$(_cola_contradiction_scan "$tmp/negativo.md")"
  neg_tilde_min_out="$(_cola_contradiction_scan "$tmp/negativo-tilde-minuscula.md")"
  neg_tilde_may_out="$(_cola_contradiction_scan "$tmp/negativo-tilde-mayuscula.md")"
  pos_contra="$(printf '%s\n' "$pos_out" | grep -c '^CONTRADICCION$' || true)"
  neg_contra="$(printf '%s\n' "$neg_out" | grep -c '^CONTRADICCION$' || true)"
  neg_tilde_min_contra="$(printf '%s\n' "$neg_tilde_min_out" | grep -c '^CONTRADICCION$' || true)"
  neg_tilde_may_contra="$(printf '%s\n' "$neg_tilde_may_out" | grep -c '^CONTRADICCION$' || true)"

  local fail=0
  if [ "${pos_contra:-0}" -lt 1 ]; then
    echo "SELF-TEST FALLO: control POSITIVO no marcó CONTRADICCION — el detector nunca dispara, es decoración." >&2
    fail=1
  else
    echo "self-test positivo: OK (contradicción real cazada)"
  fi
  if [ "${neg_contra:-0}" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO marcó CONTRADICCION sobre un doc coherente (esperado 0) — el detector dispara siempre, es decoración." >&2
    fail=1
  else
    echo "self-test negativo: OK (0 contradicciones sobre doc coherente, como se esperaba)"
  fi
  if [ "${neg_tilde_min_contra:-0}" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO [acento minúscula] marcó CONTRADICCION — 'histórica' no se reconoce como marca de historicidad (TAL-5172 v9)." >&2
    fail=1
  else
    echo "self-test negativo [acento minúscula]: OK (0 contradicciones, 'histórica' reconocida)"
  fi
  if [ "${neg_tilde_may_contra:-0}" -ne 0 ]; then
    echo "SELF-TEST FALLO: control NEGATIVO [acento mayúscula] marcó CONTRADICCION — 'HISTÓRICO' no se reconoce como marca de historicidad (TAL-5172 v9)." >&2
    fail=1
  else
    echo "self-test negativo [acento mayúscula]: OK (0 contradicciones, 'HISTÓRICO' reconocida)"
  fi
  return "$fail"
}

# --- Barrido real: todos los .md bajo --root. ---
_sweep() {
  local root="$1"
  local total=0
  local f out
  while IFS= read -r f; do
    out="$(_cola_contradiction_scan "$f")"
    [ -n "$out" ] || continue
    printf '%s\n' "$out" | grep -v '^CONTRADICCION$' || true
    if printf '%s\n' "$out" | grep -q '^CONTRADICCION$'; then
      total=$((total+1))
      echo "CONTRADICCION en $f"
    fi
  done < <(find "$root" -name '*.md' -type f ! -name 'CHANGELOG.md' 2>/dev/null | sort)
  echo
  echo "TOTAL documentos contradictorios: $total"
  [ "$total" -eq 0 ]
}

mode=check
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

[ -n "$root" ] || root="$(cd "$HERE/.." && pwd)"   # default: este skill
[ -d "$root" ] || { echo "no existe el directorio: $root" >&2; exit 2; }

if _sweep "$root"; then
  exit 0
else
  exit 1
fi
