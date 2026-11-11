#!/usr/bin/env bash
# reconciliar.sh — reconciliación INDEPENDIENTE del medidor (talent-medidor, F1).
#
# Recalcula con `jq` —otra implementación, que no comparte código con el extractor— los tokens de
# salida por sesión con la MISMA unidad contable (una fila por respuesta: Claude message.id,
# Codex response_id; entre registros de la misma respuesta gana el de mayor timestamp y, sin
# timestamp, el último del fichero) y los compara con lo que hay en la DB.
#
# Uso:  reconciliar.sh
#   Lee las mismas raíces y la misma DB que el recolector (TALENT_MEDIDOR_CLAUDE_DIR,
#   TALENT_MEDIDOR_CODEX_DIR, TALENT_MEDIDOR_DB, con sus mismos defectos).
#   Imprime una línea por sesión (`sesion=… jq=… db=… dif=…`) y al final
#   `SESIONES=<n> CUADRAN=<k>` y `DIFERENCIA=<suma de |jq - db|>`.
#   rc 0 si DIFERENCIA=0 · rc 1 si hay diferencia · rc 2 si falta jq, python3 o la DB.
#
# Límite declarado: jq no aplica la validación de forma del extractor. Un registro rechazado por
# forma (p. ej. un modelo con forma de correo) cuenta aquí y no en la DB: aparece como diferencia,
# que es exactamente lo que tiene que pasar — la cifra publicada no puede perder uso en silencio.
set -uo pipefail
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { echo "reconciliar: jq ausente" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "reconciliar: python3 ausente" >&2; exit 2; }

claude_dir="${TALENT_MEDIDOR_CLAUDE_DIR:-$HOME/.claude/projects}"
codex_dir="${TALENT_MEDIDOR_CODEX_DIR:-$HOME/.codex/sessions}"
db="${TALENT_MEDIDOR_DB:-$HOME/.local/state/talent-medidor/medidor.db}"
[ -f "$db" ] || { echo "reconciliar: DB ausente" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Solo líneas COMPLETAS: la última sin '\n' puede estar a medio escribir (misma regla que el cursor).
completas() {
  if [ -n "$(tail -c1 -- "$1")" ]; then sed '$d' -- "$1"; else cat -- "$1"; fi
}

# Una fila [sesion, unidad, ts, fichero, linea, out] por registro con uso, en el orden del fichero.
n=0
while IFS= read -r -d '' f; do
  n=$((n + 1))
  completas "$f" | jq -R -c --argjson fidx "$n" '
    (fromjson? // empty) | select(type == "object")
    | select(.type == "assistant" and (.message | type) == "object"
             and (.message.usage | type) == "object" and .message.id != null)
    | [.sessionId, .message.id, (.timestamp // ""), $fidx, input_line_number,
       (.message.usage.output_tokens // 0)]' >> "$tmp/filas.jsonl" || exit 2
done < <(find "$claude_dir" -type f -name '*.jsonl' -print0 2>/dev/null | sort -z)
while IFS= read -r -d '' f; do
  n=$((n + 1))
  completas "$f" | jq -R -c --argjson fidx "$n" '
    (fromjson? // empty) | select(type == "object")
    | select(.type == "token_usage_record" and (.payload | type) == "object"
             and (.payload.usage | type) == "object" and .payload.response_id != null)
    | [.payload.session_id, .payload.response_id, (.timestamp // ""), $fidx, input_line_number,
       (.payload.usage.output_tokens // 0)]' >> "$tmp/filas.jsonl" || exit 2
done < <(find "$codex_dir" -type f -name '*.jsonl' -print0 2>/dev/null | sort -z)
touch "$tmp/filas.jsonl"

# Una unidad por (sesion, unidad): la de mayor [ts, fichero, línea]; luego Σ out por sesión.
jq -s -r '
  group_by([.[0], .[1]]) | map(max_by([.[2], .[3], .[4]]))
  | group_by(.[0]) | map("\(.[0][0])\t\(map(.[5]) | add)") | .[]' "$tmp/filas.jsonl" > "$tmp/jq.tsv" || exit 2

python3 -B - "$db" > "$tmp/db.tsv" <<'PY' || exit 2
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for s, total in con.execute("SELECT session_id, sum(out_tok) FROM usage_raw GROUP BY session_id ORDER BY session_id"):
    print("%s\t%d" % (s, total))
PY

python3 -B - "$tmp/jq.tsv" "$tmp/db.tsv" <<'PY'
import sys
def leer(ruta):
    d = {}
    with open(ruta, encoding="utf-8") as fh:
        for linea in fh:
            s, v = linea.rstrip("\n").split("\t")
            d[s] = int(v)
    return d
a, b = leer(sys.argv[1]), leer(sys.argv[2])
dif_total = cuadran = 0
for s in sorted(set(a) | set(b)):
    x, y = a.get(s, 0), b.get(s, 0)
    dif_total += abs(x - y)
    cuadran += x == y
    print("sesion=%s jq=%d db=%d dif=%d" % (s, x, y, x - y))
print("SESIONES=%d CUADRAN=%d" % (len(set(a) | set(b)), cuadran))
print("DIFERENCIA=%d" % dif_total)
sys.exit(0 if dif_total == 0 else 1)
PY
