# cr-finding-normalize.jq — normaliza un registro crudo del CR-CLI al shape del findings JSONL
# accionable de scripts/cr-review.sh (TAL-2610). Consumido por cr-review.sh (jq -f) y por el test
# unit tests/unit/cr-review-finding-normalize.test.ts (mismo filtro real → sin drift jq↔test).
#
# Entrada: un stream de objetos JSON del CLI (--agent), un objeto por registro. Salida: un objeto
# normalizado por CADA finding critical|major TRIAGEABLE (con cuerpo de texto real). Los registros
# que no son findings, los de severidad menor y los findings SIN texto extraíble NO emiten nada.
#
# Schemas soportados:
#   0.6.4 — texto en .title/.description, líneas en .lineStart/.lineEnd.
#   0.6.5 — texto en .codegenInstructions (o .comment/.suggestions), archivo en .fileName, líneas
#           embebidas en el texto como "around lines N - M"; .title/.description/.lineStart salen null.
#
# INVARIANTES (auditoría del plan TAL-2610):
#  · Solo TRIAGEABLES: un finding critical|major sin cuerpo textual real NO se emite → cr-review.sh
#    detecta normalized < blockers y falla-cerrado (un textless-phantom nunca se cuela como parseado).
#  · Rango de líneas como UNA unidad: lineStart/lineEnd salen SIEMPRE del mismo origen — ambos de los
#    campos directos, o ambos del texto (regex anclada a "around lines N - M"); nunca híbrido.
#  · "" y los valores no-string cuentan como AUSENCIA (no como valor) en todos los fallbacks.

# Coalesce estricto: emite $v solo si tras RECORTAR whitespace queda contenido real; si no, empty
# (ausencia). Recorta ANTES de comparar contra "" (M-02 síntesis r1): un cuerpo formado solo por
# espacios/tabs/newlines es un phantom, NO texto — no debe pasar el gate de triageabilidad ni contar
# para la paridad. Los valores no-string cuentan como AUSENCIA (se descartan aquí).
def s($v): ($v // "")
  | if type == "string" then (gsub("^\\s+|\\s+$"; "")) else "" end
  | if . != "" then . else empty end;

# Primer candidato no vacío de una lista, o null. (El array recoge solo los que `s` dejó pasar.)
def first_of(cands): (cands | .[0]) // null;

# Normaliza UN valor para la MATERIA de la huella (`fpMaterial`): strings recortados (vacío→null);
# valores NO-string (p.ej. suggestions como array/objeto) se CONSERVAN tal cual — `fp_of` los
# serializa con `tojson` (M-01 síntesis r1: incluir non-string en vez de descartarlos). null→null.
def norm_txt($v): ($v // null)
  | if type == "string" then (gsub("^\\s+|\\s+$"; "") | if . == "" then null else . end) else . end;

select(.type == "finding")
| select(((.severity // .level // "") | ascii_downcase) | test("critical|major"))
# Cuerpo real del finding — todas las fuentes textuales conocidas, .comment incluido.
| ([ s(.description), s(.comment), s(.codegenInstructions), s(.suggestions) ] | .[0]) as $body
# Gate de triageabilidad: sin cuerpo textual real, no se emite (fail-closed por paridad).
| select($body != null)
# Rango de líneas como unidad. Directo si hay .lineStart; si no, del texto con regex anclada.
| (
    if (.lineStart != null)
    then { ls: .lineStart, le: (.lineEnd // .lineStart) }
    else (
      ( ($body | capture("around lines?\\s+(?<a>[0-9]+)\\s*[-–—]\\s*(?<b>[0-9]+)"; "i")) // {} ) as $range
      | ( ($body | capture("around lines?\\s+(?<a>[0-9]+)"; "i")) // {} ) as $single
      | if ($range.a != null)
        then { ls: ($range.a | tonumber), le: ($range.b | tonumber) }
        elif ($single.a != null)
        then { ls: ($single.a | tonumber), le: ($single.a | tonumber) }
        else { ls: null, le: null }
        end
    )
    end
  ) as $lines
| {
    severity: (.severity // .level),
    file: first_of([ s(.fileName), s(.file) ]),
    lineStart: $lines.ls,
    lineEnd: $lines.le,
    title: first_of([ s(.title), ($body | split("\n") | map(select(. != "")) | (.[0] // empty)), s(.fileName) ]),
    description: $body,
    prompt: first_of([ s(.prompt), s(.codegenInstructions), s(.comment), s(.suggestions) ]),
    category: .category,
    # MATERIA de la huella (M-01 síntesis r1): TODAS las fuentes textuales, no solo la primera que
    # `description`/`prompt` colapsan. Dos findings idénticos salvo por codegenInstructions/suggestions
    # (con igual description+prompt) colapsaban a la misma huella → una deuda aceptada suprimía otro
    # finding materialmente distinto (falso GO). `fp_of` (cr-review.sh) hashea ESTE array vía tojson
    # (injectivo, serializa suggestions no-string). NO se persiste en el historial sanitizado (lleva
    # snippets); vive en el findings JSONL accionable (que ya lleva description/prompt) para que
    # --accept-debt reproduzca la MISMA huella.
    fpMaterial: [ norm_txt(.description), norm_txt(.comment), norm_txt(.codegenInstructions), norm_txt(.suggestions), norm_txt(.prompt) ]
  }
