#!/usr/bin/env bash
# test-distill-findings-mutants.sh — 34 mutantes de producción sobre COPIAS del destilador (y de la
# referencia que documenta la métrica). Por mutante: la restauración sale de una copia hecha ANTES de
# mutar (cmp rc 0 contra el original), el caso afectado debe dar ROJO por su aserción (rc 1 y una línea
# `FAIL caso <id>:`) y VERDE (rc 0) al restaurar. Un mutante que no se puede aplicar o cuyo rojo no
# viene de una aserción cuenta como no medido y rompe el resultado.
# Línea final: casos=<n> mutantes=<n> rojos_por_asercion=<n> verdes_restaurado=<n> no_medidos=<n>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_ORIG="$HERE/../scripts/distill-findings.sh"
MD_ORIG="$HERE/../references/05-canales-de-refactorizacion.md"
TEST="$HERE/test-distill-findings.sh"
for f in "$SCRIPT_ORIG" "$MD_ORIG" "$TEST"; do [ -f "$f" ] || { echo "falta $f" >&2; exit 2; }; done
command -v python3 >/dev/null 2>&1 || { echo "falta python3" >&2; exit 2; }
W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT

# id:caso:artefacto (script | md)
MUTANTES="m1a:1:script m1b:1:script m1c:1:script m1d:1:script m2a:2:script m2b:2:script
m3a:3:script m3b:3:script m3c:3:script m3d:3:script m3e:3:script m3f:3:script m3g:3:script m3h:3:script
m4a:4:script m4b:4:script m5:5:script m6:6:script
m7-correo:7a:script m7-telefono:7b:script m7-token:7c:script m7-cuerpo:7d:script
m7-cabecera:7e:script m7-financiero:7f:script m7-secreto:7g:script m7-motivo:7h:script
m8a:8:script m8b:8:script m9:9:md m10a:10a:script m10b:10b:script m10c:10c:script m10d:10d:script m10e:10d:script"

CASOS_TEST="$(sed -n 's/^CASOS="\(.*\)"$/\1/p' "$TEST")"
[ -n "$CASOS_TEST" ] || { echo "no pude leer CASOS de $TEST" >&2; exit 2; }

# Aplica las sustituciones EXACTAS de un mutante (cada trozo debe aparecer una sola vez).
aplicar() { # $1 fichero · $2 id
  python3 -I - "$1" "$2" <<'PY'
import pathlib
import sys

path, mid = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
s = p.read_text()
SAN = {
    "correo": '''gsub("[a-z0-9._%+-]+@[a-z0-9][a-z0-9.-]*\\\\.[a-z]{2,}"; "redactado-correo"; "i")''',
    "cabecera": '''gsub("(authorization|proxy-authorization|x-api-key|set-cookie|cookie)\\\\s*:\\\\s*((bearer|basic)\\\\s+)?[^\\\\s]+"; "redactado-cabecera"; "i")''',
    "secreto": '''gsub("(password|passwd|pwd|secret|api[_-]?key|private[_-]?key|token)\\\\s*[=:]\\\\s*[^\\\\s]+"; "redactado-secreto"; "i")''',
    "token": '''gsub("(gh[pousr]_|github_pat_|sbp_|sk-ant-|sk-|lin_api_|phc_|sntrys_|xox[abprs]-)[a-z0-9_-]{8,}|eyj[a-z0-9_-]+\\\\.[a-z0-9_-]+\\\\.[a-z0-9_-]+|[a-z0-9]{32,}"; "redactado-token"; "i")''',
    "financiero": '''gsub("(?<![0-9])[0-9]{13,19}(?![0-9])|(?<![0-9])[0-9]{4}([ -][0-9]{4}){3}(?![0-9])"; "redactado-financiero")''',
    "telefono": '''gsub("(?<![0-9])\\\\+?[0-9]{7,12}(?![0-9])"; "redactado-telefono")''',
}
M = {
    # caso 1: conteo por registro / por run / known-debt como ocurrencia / sin precedencia
    "m1a": [("( [$best[].vehicle] | unique ) as $veh", "( [$g[].vehicle] ) as $veh")],
    "m1b": [("( [$best[].vehicle] | unique ) as $veh", "( [$g[] | .run_id] | unique ) as $veh")],
    "m1c": [('printf \'%s\' "$HIST" > "$TMP/hist.json"; printf \'%s\' "$FIN" > "$TMP/fin.json"',
             'printf \'%s\' "$HIST" > "$TMP/hist.json"; printf \'%s\' "$FIN" | jq -c --argjson k "$KD" \'. + [$k[] | {severity, file, lineStart, lineEnd, title, category: "other", fp, run_id: "kd"}]\' > "$TMP/fin.json"')],
    "m1d": [("(map(.rank) | min) as $r", "(map(.rank) | max) as $r")],
    # caso 2: identidad por fp / rama sin resolver a PR
    "m2a": [("{candidate_key: $km[0][(.kk | @base64)]}", "{candidate_key: .fp}")],
    "m2b": [('  [ -z "$num" ] || BRMAP="$(printf \'%s\' "$BRMAP" | jq -c --arg b "$br" --arg n "$num" \'. + {($b): $n}\')"', "  :")],
    # caso 3: title_stem y file_class
    "m3a": [('  | gsub("[0-9]+"; "")\n', "")],
    "m3b": [('  | gsub("(^|\\\\s)[^\\\\s]*/[^\\\\s]*"; " ")\n', "")],
    "m3c": [('  | gsub("[\\u0027\\"\\u2018\\u2019\\u201c\\u201d]"; "")\n', "")],
    "m3d": [('  | gsub("`"; "")\n', "")],
    "m3e": [("(.title | stem | san) as $s", '("") as $s')],
    "m3f": [("(.file | file_class) as $fc", "(.file) as $fc")],
    "m3g": [('jq -r \'[.vista[] | "### [" + .ultima_vez[0:10] + "] " + .title_stem + "\\n\\n"',
             'jq -r --slurpfile o "$TMP/occ.json" \'[.vista[] | "### [" + .ultima_vez[0:10] + "] " + (. as $c | $o[0].occ | map(select(.stem == $c.title_stem)) | .[0].title) + "\\n\\n"')],
    "m3h": [('(.count | tostring) + " vehículos): " + .title_stem)})',
             '(.count | tostring) + " vehículos): " + (. as $c | $o[0].occ | map(select(.stem == $c.title_stem)) | .[0].title))})')],
    # caso 4: ruido
    "m4a": [('test("^(critical|major)$");', 'test("^(critical|major|minor)$");')],
    "m4b": [("select(.thread_id != null) | ", "")],
    # caso 5: el lector del App con el flag de fuentes agregadas
    "m5": [('salida="$("$FETCH" "$REPO" "$n" 2>/dev/null)"', 'salida="$("$FETCH" "$REPO" "$n" --sources all 2>/dev/null)"')],
    # caso 6: leer saltando lineas rotas
    "m6": [("  jq -s -c '.' \"$1\" 2>/dev/null\n", "  jq -R -s -c 'split(\"\\n\") | map(fromjson?)' \"$1\" 2>/dev/null\n")],
    # caso 7: una regla del saneador por clase, persistir el cuerpo, el texto crudo del error
    "m7-correo": [(SAN["correo"], ".")],
    "m7-telefono": [(SAN["telefono"], ".")],
    "m7-token": [(SAN["token"], ".")],
    "m7-cabecera": [(SAN["cabecera"], ".")],
    "m7-financiero": [(SAN["financiero"], ".")],
    "m7-secreto": [(SAN["secreto"], ".")],
    "m7-cuerpo": [
        ("ts: ($he.ts // $mt), fp: (.fp // \"\"), category: .category, file: .file, title: .title}",
         "ts: ($he.ts // $mt), fp: (.fp // \"\"), category: .category, file: .file, title: .title, desc: .description}"),
        ("{src, rank, run_id, ts, fp, title, clase: $c,", "{src, rank, run_id, ts, fp, title, desc, clase: $c,"),
        ("clase: $g[0].clase, title_stem: $g[0].stem,", "clase: $g[0].clase, title_stem: ($g[0].stem + \" \" + ($g[0].desc // \"\")),"),
    ],
    "m7-motivo": [
        ('mv -T -- "$tmp" "$1" 2>/dev/null || return 1', 'ERRRAW="$(mv -T -- "$tmp" "$1" 2>&1)" || return 1'),
        ('atomico "$OUT" "$CONTENT" || fallar 4 persist_fallido "$VEH_ULT"', 'atomico "$OUT" "$CONTENT" || fallar 4 "$ERRRAW" "$VEH_ULT"'),
    ],
    # caso 8: watermark antes del persist / temporal sin limpiar
    "m8a": [('''  atomico "$OUT" "$CONTENT" || fallar 4 persist_fallido "$VEH_ULT"
  if [ "$FULL" = 1 ] && [ -n "$MAXTS" ] && [[ "$MAXTS" > "$WM" ]]; then
    atomico "$WATERMARK" "$(jq -n -c --arg w "$MAXTS" '{watermark: $w}')" || fallar 4 persist_fallido "$VEH_ULT"
  fi
''', '''  if [ "$FULL" = 1 ] && [ -n "$MAXTS" ] && [[ "$MAXTS" > "$WM" ]]; then
    atomico "$WATERMARK" "$(jq -n -c --arg w "$MAXTS" '{watermark: $w}')" || fallar 4 persist_fallido "$VEH_ULT"
  fi
  atomico "$OUT" "$CONTENT" || fallar 4 persist_fallido "$VEH_ULT"
''')],
    "m8b": [("trap limpiar EXIT\n", ":\n")],
    # caso 9: contar toda aparicion del token (se aplica a la referencia .md)
    "m9": [("grep -cE '^# ✅ M[0-9]+ MERGED #[0-9]+' \"$FLOCK\"", "grep -c 'MERGED' \"$FLOCK\""),
           ("grep -cE '^# 🔴 BOUNCED #[0-9]+' \"$FLOCK\"", "grep -c 'BOUNCED' \"$FLOCK\"")],
    # caso 10: modos
    "m10a": [('if [ "$DRY" = 0 ]; then', "if true; then")],
    "m10b": [('(if $pr == "" then . else map(select(.vehicle == $pr)) end)', ".")],
    "m10c": [('map(select($since == "" or .ts >= $since))', "map(.)")],
    "m10d": [("| .[0:$limit] | map(.v) )", "| map(.v) )")],
    "m10e": [('[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || uso', '[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || LIMIT=50')],
}
for old, new in M[mid]:
    n = s.count(old)
    if n != 1:
        print("no aplicable: el trozo aparece %d veces: %r" % (n, old[:70]))
        sys.exit(3)
    s = s.replace(old, new, 1)
p.write_text(s)
PY
}

N=0; ROJOS=0; VERDES=0; NOMED=0; COBERTURA=""
for spec in $MUTANTES; do
  id="${spec%%:*}"; resto="${spec#*:}"; caso="${resto%%:*}"; art="${resto#*:}"
  N=$((N + 1)); COBERTURA="$COBERTURA $caso"
  d="$W/$id"; mkdir -p "$d"
  if [ "$art" = md ]; then orig="$MD_ORIG"; ext=md; else orig="$SCRIPT_ORIG"; ext='sh'; fi
  cp "$orig" "$d/previo.$ext"; cp "$orig" "$d/mutado.$ext"
  cmp -s "$d/previo.$ext" "$orig"; cmp_previo=$?
  msg="$(aplicar "$d/mutado.$ext" "$id" 2>&1)"; rc_aplicar=$?
  cmp -s "$d/mutado.$ext" "$d/previo.$ext"; cmp_difiere=$?
  if [ "$cmp_previo" != 0 ] || [ "$rc_aplicar" != 0 ] || [ "$cmp_difiere" != 1 ]; then
    NOMED=$((NOMED + 1)); printf 'MUTANTE %s caso=%s NO MEDIDO: cmp_previo=%s aplicar_rc=%s %s\n' "$id" "$caso" "$cmp_previo" "$rc_aplicar" "$msg"; continue
  fi
  chmod +x "$d/mutado.$ext" "$d/previo.$ext" 2>/dev/null || true
  if [ "$art" = md ]; then
    DISTILL_METRICA_MD="$d/mutado.md" bash "$TEST" --solo "$caso" > "$d/rojo.log" 2>&1; rc_rojo=$?
    DISTILL_METRICA_MD="$d/previo.md" bash "$TEST" --solo "$caso" > "$d/verde.log" 2>&1; rc_verde=$?
  else
    DISTILL_SCRIPT="$d/mutado.sh" bash "$TEST" --solo "$caso" > "$d/rojo.log" 2>&1; rc_rojo=$?
    DISTILL_SCRIPT="$d/previo.sh" bash "$TEST" --solo "$caso" > "$d/verde.log" 2>&1; rc_verde=$?
  fi
  asercion="$(grep -m 1 "^  FAIL caso $caso: " "$d/rojo.log" || true)"
  if [ "$rc_rojo" = 1 ] && [ -n "$asercion" ]; then ROJOS=$((ROJOS + 1)); else NOMED=$((NOMED + 1)); fi
  if [ "$rc_verde" = 0 ]; then VERDES=$((VERDES + 1)); else NOMED=$((NOMED + 1)); fi
  printf 'MUTANTE %s caso=%s cmp_previo=%s rojo_rc=%s verde_rc=%s\n' "$id" "$caso" "$cmp_previo" "$rc_rojo" "$rc_verde"
  printf '    aserción roja: %s\n' "${asercion:-NINGUNA}"
  cmp -s "$d/previo.$ext" "$orig"; printf '    cmp_restaurado=%s\n' "$?"
  diff <(cat "$d/previo.$ext") <(cat "$d/mutado.$ext") | head -n 20 | sed 's/^/    diff: /'
done

# Cada caso del test debe tener al menos un mutante nombrado; los casos cubiertos se cuentan sin repetir.
CUBIERTOS="$(printf '%s\n' $COBERTURA | sort -u | wc -l | tr -d ' ')"
for c in $CASOS_TEST; do
  case " $COBERTURA " in *" $c "*) ;; *) echo "caso sin mutante nombrado: $c" >&2; NOMED=$((NOMED + 1)) ;; esac
done
printf 'casos=%s mutantes=%s rojos_por_asercion=%s verdes_restaurado=%s no_medidos=%s\n' "$CUBIERTOS" "$N" "$ROJOS" "$VERDES" "$NOMED"
[ "$NOMED" -eq 0 ] && [ "$ROJOS" -eq "$N" ] && [ "$VERDES" -eq "$N" ]
