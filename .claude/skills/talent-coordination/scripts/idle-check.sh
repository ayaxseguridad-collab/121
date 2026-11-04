#!/usr/bin/env bash
# idle-check.sh — Clasificación verificable del estado de un pane tmux del coordinador.
#
# Cierra el agujero de TAL-5141: los sweeps confundían "atascado con texto sin enviar" con "ocioso",
# y grepear el último prompt de una captura marcaba canales como parados leyendo historial ya procesado.
# La detección de ESTADO se ancla SIEMPRE a la región actual del composer, nunca al scrollback.
#
# CORRECCIÓN POST-CERO×2 (demo AC-2 sobre TUI real, TAL-5141): la versión anterior anclaba el composer
# por el GLIFO literal de esquina (╭…╰). El TUI real de producción dibuja el composer con reglas
# horizontales PLANAS (sin esquinas) — el ancla por glifo se perdía incluso con el composer genuinamente
# vacío, y `--relay-ready` devolvía "no listo" en vez de decir "no puedo ver el composer". Ahora el
# ancla es por CLASE de trazo (cualquier tirada larga de caracteres de borde/caja, sea cual sea el
# estilo) + POSICIÓN respecto al cursor de entrada real (❯), no por un carácter fijo — ver ic_anchor().
# Y el resultado "no pude localizar el composer" ya NO se disfraza de "no está listo": se distingue
# como NO-MEDIDO (rc 2), un estado propio.
#
# Uso:
#   idle-check.sh <target>                 -> IDLE-REAL (6 condiciones, ventana 300 s) para el sweep
#   idle-check.sh --relay-ready <target>   -> idle estable INSTANTÁNEO para relay (sin macro-300 s)
#   idle-check.sh --classify               -> lee una captura por stdin y emite el token de estado (PURO)
#
# <target>:
#   canal-NN | ch-NN | chNN   -> contenedor ${TC_PREFIX}NN, sesión ${TC_TMUX}, pane ${TC_DEV_PANE} (vía incus)
#   torre-<actor>             -> tmux del host, sesión torre-<actor>, pane .0
#   host:<sesion>[.<pane>]    -> tmux del host directo (aislable con TC_TMUX_L; lo usa el selftest)
#
# Tokens/rc de estado (--classify, PURO): IDLE-CANDIDATO 0 · BUSY 1 · UNKNOWN 2 (NO-MEDIDO: no localicé
#   el composer, no es un veredicto de "ocupado") · MENU-ABIERTO 10 · COMPOSER-CON-TEXTO-SIN-ENVIAR 11.
# Prefijos de --relay-ready: READY · NOT-READY:<motivo> (rc 1, composer LOCALIZADO y no listo) ·
#   NO-MEDIDO:<motivo> (rc 2, NO localicé el composer o falló la captura — nunca se trata como "no
#   listo": el llamador debe decidir aparte, no asumir que puede reintentar como si fuera ocupado).
#
# Se puede SOURCEAR desde relay.sh: solo define funciones; la CLI corre únicamente al ejecutarse.

set -euo pipefail

# --- Configuración (overrides por entorno; nunca credenciales) ---
: "${TC_PREFIX:=vibe-channel-}"                 # contenedor = ${TC_PREFIX}NN
: "${TC_TMUX:=v}"                               # sesión tmux del canal
: "${TC_DEV_PANE:=.0}"                          # pane de desarrollo del canal
: "${TC_CUSER:=vivecoder}"                      # usuario dentro del contenedor
: "${TC_TMUX_L:=}"                              # socket 'tmux -L' del host (aislamiento del selftest)
: "${TC_CAP_LINES:=400}"                        # ventana AMPLIA para búsquedas de entrega/contenido
: "${TC_STATUS_TAIL:=8}"                        # SOLO diagnóstico (relay.sh imprime esta cola en un
                                                 # error) — NO participa en ninguna decisión de estado
: "${TC_BUSY_LOOKBACK:=2}"                      # CON CORNER: las N líneas INMEDIATAMENTE anteriores al
                                                 # borde superior — subido de 1 a 2 (pasada fresca r14
                                                 # NO-GO): la captura de campo real es DE DOS LÍNEAS
                                                 # ("✶ Sock-hopping…" + su línea de pie "⎿ Tip: …"), y con
                                                 # ventana=1 la línea que toca el borde es la de PIE, que
                                                 # por sí sola no lleva la señal — la señal real quedaba
                                                 # fuera de la ventana. Sigue siendo adyacencia ESTRICTA
                                                 # (nunca una ventana de scrollback arbitraria), solo más
                                                 # ancha que antes; ver ic_detect_busy_from.
: "${TC_MICRO_N:=3}"                            # capturas de micro-continuidad (N>=3)
: "${TC_MICRO_GAP:=2}"                          # segundos entre capturas de micro-continuidad
: "${TC_IDLE_WINDOW:=300}"                      # ventana macro de estaticidad (segundos), no 600
: "${TC_STATE_DIR:=${HOME}/.cache/talent-coordination/idle}"  # estado persistido del sweep
# El pie que acompaña a un indicador BUSY real ("⎿ Tip: …") se reconoce por ESTRUCTURA DE CAMPOS
# (ic_is_pie_line: glifo no alfanumérico + 2º campo EXACTAMENTE "Tip:"), no por una variable de config
# con una subcadena — el texto del tip ROTA (verificado con capturas reales distintas: "Tip: Control
# this session…", "Tip: Use /btw to ask a quick side question…") y una subcadena "contiene Tip:" dejaba
# colar cualquier línea que MENCIONE la palabra (hallazgo MAYOR de la pasada r15, caso `fake_tip_chain`).
: "${TC_MENU_REGEX:=Would you like to proceed\?|Enter to select|Do you want to}"  # firmas COMPUESTAS de menú
: "${TC_QUEUED_REGEX:=Press up to edit queued messages}"  # cola: mensaje encolado sin enviar
# Pies de menú REALES verificados en vivo (TAL-5141, demo AC-2): un menú de confirmación de herramienta
# usa "Esc to cancel · Tab to amend · ctrl+e to explain", no "shift+tab"/"Enter to select" — ninguno de
# los dos hacía match, así que la cadena-intacta SIN-CORNER (ic_chain_intact_from) se rompía en el pie y
# el candidato se descartaba pese a que el título SÍ era señal real. Enumerado explícito porque el texto
# de pie es copy de producto (no hay una "clase" estructural que lo generalice, a diferencia del borde).
: "${TC_MENU_FOOTER_HINT_REGEX:=Esc to cancel|Tab to amend|ctrl\+e to explain}"
# TC_SHELL_ECHO_RE excluye candidatos que luzcan como un comando de shell CITANDO la señal (p. ej.
# `$ echo "Would you like to proceed?"`) — hallazgo del auditor: un regex de subcadena sin esta guarda
# confunde una cita dentro de un comando con la señal real. Asignación en dos pasos (no `${VAR:=$'...'}`
# anidado: esa forma rompe el parser de bash con esta combinación de comillas).
if [ -z "${TC_SHELL_ECHO_RE:-}" ]; then
  TC_SHELL_ECHO_RE=$'\\$[[:space:]]|echo[[:space:]]*["\x27]'
fi
# TC_BORDER_LINE_REGEX: alternancia de UN carácter de trazo/caja por rama — NUNCA una clase de corchetes
# con VARIOS caracteres multibyte a la vez ([│┃║...]). Verificado en vivo (mawk 1.3.4, esta caja):
# `[│┃║]` deja de casar el propio │ (byte-a-byte, no carácter-a-carácter, con múltiples secuencias UTF-8
# de 3 bytes en el mismo corchete) — un corchete con UN solo multibyte SÍ funciona ([❯>] es seguro), pero
# combinar varios no. Por eso cada carácter de trazo va en su propia alternativa; el fallback ASCII
# (=_~*#-) sí puede compartir corchete porque es de 1 byte cada uno. TC_BORDER_MIN_COUNT (no un
# cuantificador `{n,}` sobre el grupo: verificado que mawk 1.3.4 IGNORA `{n,}` aplicado a un grupo
# `(...)` — "a-b" con un único guion daba MATCH contra `(...){8,}`, silencioso — el conteo real se hace
# con gsub() en ic_anchor, no con un regex de intervalo) exige varias apariciones, no necesariamente
# consecutivas, para que un título corto embebido (p. ej. rama de git) no rompa la cuenta.
: "${TC_BORDER_LINE_REGEX:=─|═|━|┄|┉|┈|╌|╍|│|┃|║|╭|╮|╰|╯|┌|┐|└|┘|[=_~*#-]}"
: "${TC_BORDER_MIN_COUNT:=3}"                   # mínimo de caracteres de clase-borde en la línea (gsub).
                                                 # 3 = la caja más angosta estructuralmente posible
                                                 # (esquina+regla+esquina, p.ej. "╭─╮") — el piso real, no
                                                 # un número arbitrario; el chrome real de producción trae
                                                 # cientos, así que el piso solo importa para no aceptar
                                                 # una línea con 1-2 guiones sueltos en prosa normal.
: "${TC_PROMPT_LINE_REGEX:=^[[:space:]]*(│|┃|║)?[[:space:]]*(❯|>)[[:space:]]}"  # cursor de entrada REAL
                                                 # del composer (cursor+espacio). '(❯|>)' es CLASE, no un
                                                 # glifo único: el unicode ❯ del TUI real y el '>' ASCII
                                                 # que ya usaban fixtures/otros detectores del propio
                                                 # fichero (ic_detect_pending_region ya los trataba
                                                 # equivalentes) — como bracket [❯>] es UN solo multibyte
                                                 # + ASCII, es seguro (no cae en el bug de arriba), pero se
                                                 # deja en forma de grupo por uniformidad con el borde
                                                 # vertical. '(│|┃|║)?' tolera un borde vertical IZQUIERDO
                                                 # opcional antes del cursor — una caja con lados (estilo
                                                 # antiguo) lo lleva, una regla plana sin lados (TUI real
                                                 # de hoy) no; ambas deben anclar igual ('?' sobre grupo SÍ
                                                 # funciona en mawk, a diferencia de '{n,}'). El TUI real
                                                 # separa el cursor del texto con NBSP, normalizado antes
                                                 # de matchear — ver ic_anchor.
: "${TC_MENU_OPTION_LINE_REGEX:=^[[:space:]]*(│|┃|║)?[[:space:]]*(❯|>)[[:space:]]*[0-9]+\.}"  # "❯/> N."
                                                 # = opción de menú, MISMO cursor pero otro significado: se
                                                 # excluye explícitamente de contar como línea de composer
: "${TC_TAIL_CHROME:=14}"                       # líneas finales donde se busca el chrome del composer
: "${TC_SHELL_COMM_RE:=^(sh|bash|zsh|-bash|dash|tmux|less|more|pager)$}"  # shells/envoltorios transitorios
: "${TC_MICRO_N_MIN:=3}"                        # piso NO-NEGOCIABLE de N (rechaza overrides por debajo)

tc_err() { printf 'idle-check: %s\n' "$1" >&2; }

# --- Higiene de ANSI + espacios especiales ---
# NBSP (U+00A0, 0xC2 0xA0) → espacio ASCII normal: si la clase [[:space:]] lo reconoce como espacio
# depende del locale de forma FRÁGIL (verificado empíricamente: la MISMA shell puede clasificarlo
# distinto según la vía exacta de resolución del locale) — un composer con SOLO un NBSP (placeholder de
# cursor real en algunos TUI) podía darse por "con texto" (pending falso) en unos contextos y no en
# otros. Normalizar ÚNICAMENTE en el predicado de vacío/blanco (ic_detect_pending_region) — NUNCA en
# ic_strip_dim/ic_strip_ansi de forma global: esas dos alimentan tambien ic_composer_contains, cuyo
# contrato es comparación LITERAL byte-exacta del texto enviado (hallazgo del auditor: normalizar ahí
# hace que un NBSP real en el texto no coincida consigo mismo, y que una alteración espacio↔NBSP pase
# como "literal exacto" — justo lo que ese invariante existe para detectar).
ic_norm_nbsp() { sed 's/\xc2\xa0/ /g'; }
# Quita los tramos DIM (sugerencias grises del arnés) y luego todo el ANSI restante: deja el texto REAL,
# byte-exacto (SIN normalizar NBSP — lo consume ic_composer_contains para comparación literal).
ic_strip_dim() { sed -E 's/\x1b\[2m[^\x1b]*(\x1b\[0?m)?//g; s/\x1b\[[0-9;]*[a-zA-Z]//g'; }
# Quita todo el ANSI (para anclar bordes y matchear texto de estado sin ruido de escapes). Byte-exacto.
ic_strip_ansi() { sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*(\x07|\x1b\\)//g'; }

# --- Anclaje del composer por CLASE de borde + POSICIÓN relativa al cursor real (no por un glifo fijo) ---
# Emite "top bot" (1-indexado) o rc!=0 si no encuentra el chrome completo. Opera sobre captura SIN ANSI.
#
# Diseño (TAL-5141, post-demo AC-2 sobre TUI real): localiza primero la línea del CURSOR de entrada real
# (❯+espacio, EXCLUYENDO explícitamente "❯ N." de menú), la más reciente dentro de la ventana
# TC_TAIL_CHROME; el borde superior/inferior es la línea de CLASE-borde más cercana por encima/debajo de
# ese cursor, sea cual sea el carácter de trazo que use hoy el TUI. Ya NO exige una línea de footer
# literal: enumerar el texto de cada modo ("bypass permissions"/"manual mode on"/…) es la MISMA
# fragilidad de "por string" que tenía el borde por glifo; la ventana TC_TAIL_CHROME + la posición EXACTA
# respecto al cursor real ya acotan el falso positivo sin necesitar esa tercera pierna.
ic_anchor() { # (stdin = captura sin ANSI)
  ic_norm_nbsp | IC_BORDER_RE="$TC_BORDER_LINE_REGEX" IC_PROMPT_RE="$TC_PROMPT_LINE_REGEX" \
      IC_MENU_RE="$TC_MENU_OPTION_LINE_REGEX" awk -v tailn="$TC_TAIL_CHROME" -v minc="$TC_BORDER_MIN_COUNT" '
    BEGIN { borderre=ENVIRON["IC_BORDER_RE"]; promptre=ENVIRON["IC_PROMPT_RE"]; menure=ENVIRON["IC_MENU_RE"] }
    function is_border(line,    c, n) { c = line; n = gsub(borderre, "", c); return n >= minc }
    { l[NR]=$0 }
    END {
      start = (NR > tailn) ? NR - tailn + 1 : 1
      prompt=0
      for (i=NR; i>=start; i--) {
        if (l[i] ~ promptre && l[i] !~ menure) { prompt=i; break }
      }
      if (!prompt) exit 2
      top=0
      for (i=prompt-1; i>=start; i--) { if (is_border(l[i])) { top=i; break } }
      bot=0
      for (i=prompt+1; i<=NR; i++)    { if (is_border(l[i])) { bot=i; break } }
      if (top && bot && top < prompt && prompt < bot) { print top, bot; exit 0 }
      exit 2
    }'
}

# ¿Toda línea desde <start> (inclusive) hasta el FINAL REAL es compatible con <compat_regex> o está en
# blanco? PURO. Reemplaza la idea de "distancia con tolerancia" (hallazgo del auditor: una tolerancia de
# N líneas admite exactamente N líneas de contenido INCOMPATIBLE — p. ej. un prompt `$` — entre la señal
# y el final, y eso NO prueba que la señal siga vigente). Con cadena intacta, CUALQUIER línea ajena a la
# estructura del diálogo/cola/indicador rompe la cadena y descarta la señal como cita vieja, sea cual sea
# su distancia al final.
ic_chain_intact_from() { # <start_line> <compat_regex>  (stdin)
  local start="$1" re="$2"
  IC_CHAIN_RE="$re" awk -v s="$start" '
    BEGIN { re=ENVIRON["IC_CHAIN_RE"] }
    NR>=s {
      if ($0 ~ re) next
      if ($0 ~ /^[[:space:]]*$/) next
      # Línea de puro adorno de borde (misma CLASE que TC_BORDER_LINE_REGEX, sin contenido): decorativa,
      # no señal — una cita vieja no coincidiría con esto por azar en esa posición exacta.
      if ($0 ~ /^[[:space:]]*[─═━┄┉┈╌╍│┃║╭╮╰╯┌┐└┘]+[[:space:]]*$/) next
      bad=1
    }
    END { exit (bad ? 1 : 0) }
  '
}

# Busca, de la línea MÁS RECIENTE a la MÁS ANTIGUA, una que matchee <signal_regex> (y NO luzca como un
# comando/prompt de shell CITANDO la señal, p. ej. `$ echo "Would you like to proceed?"` — TC_SHELL_ECHO_RE)
# cuya cadena desde ahí hasta el final REAL sea intacta con <compat_regex>. Dos hallazgos del auditor en
# uno: (a) una coincidencia HISTÓRICA anterior, con contenido roto detrás, no debe ocultar una coincidencia
# REAL posterior — probar candidatos de atrás hacia adelante hasta que uno valide; (b) una línea que solo
# CITA la señal dentro de un comando no es una candidata válida, aunque la contenga como subcadena.
ic_find_live_signal() { # <signal_regex> <compat_regex>  (stdin sin ANSI)
  local sig="$1" compat="$2" cap lines candidate
  cap="$(cat)"
  lines="$(printf '%s\n' "$cap" | IC_SIGNAL_RE="$sig" IC_GUARD_RE="$TC_SHELL_ECHO_RE" awk '
    BEGIN { re=ENVIRON["IC_SIGNAL_RE"]; guard=ENVIRON["IC_GUARD_RE"] }
    $0 ~ re && $0 !~ guard { print NR }
  ')"
  [ -n "$lines" ] || return 1
  for candidate in $(printf '%s\n' "$lines" | sort -rn); do
    printf '%s\n' "$cap" | ic_chain_intact_from "$candidate" "$compat" && return 0
  done
  return 1
}

# ¿Menú abierto AHORA? CON CORNER: firma en la región>=top (ZONA SEGURA, ya excluye transcript por
# construcción, sea cual sea el tamaño del pane). SIN CORNER: ic_find_live_signal prueba candidatos
# (línea COMPLETA con título o ❯N.) de la MÁS RECIENTE hacia atrás, exigiendo la cadena INTACTA (solo
# título/opción-con-o-sin-cursor/footer de selección/blanco) hasta el final REAL desde cada candidato —
# un diálogo que sustituye el composer es SIEMPRE lo último renderizado; cualquier línea ajena (aunque
# sea un solo prompt) descarta ESE candidato, pero uno más reciente puede seguir siendo válido.
ic_menu_open() { # (stdin sin ANSI)
  local cap anchor top region sig compat
  cap="$(cat)"
  if anchor="$(printf '%s\n' "$cap" | ic_anchor)"; then
    top="${anchor%% *}"
    region="$(printf '%s\n' "$cap" | awk -v t="$top" 'NR>=t')"
    printf '%s\n' "$region" | grep -qiE "$TC_MENU_REGEX" && return 0
    printf '%s\n' "$region" | grep -qE '^[[:space:]]*❯[[:space:]]*[0-9]+\.' && return 0
    return 1
  fi
  # Candidatos: título ANCLADO a línea COMPLETA (inicio Y fin — rechaza tanto "$ echo \"Would you
  # like...\"" como "Would you like...? (citado)": un regex de subcadena sin ancla de fin cuenta
  # cualquier sufijo como señal real, hallazgo del auditor) o ❯N. (ya anclado a inicio por construcción;
  # el resto de la línea de opción es contenido esperado, no se ancla a fin). mawk maneja mal '?' sobre ❯
  # multibyte — alternancia explícita, sin cuantificador sobre el glifo, en vez de un opcional.
  sig="^[[:space:]]*(${TC_MENU_REGEX})[[:space:]]*\$|^[[:space:]]*❯[[:space:]]*[0-9]+\."
  compat="${TC_MENU_REGEX}|^[[:space:]]*❯[[:space:]]*[0-9]+\.[[:space:]]|^[[:space:]]*[0-9]+\.[[:space:]]|Enter to select|shift\+tab|${TC_MENU_FOOTER_HINT_REGEX}"
  printf '%s\n' "$cap" | ic_find_live_signal "$sig" "$compat"
}

# ¿Cola (texto encolado sin enviar) AHORA? Mismo principio que ic_menu_open.
ic_queue_pending() { # (stdin sin ANSI)
  local cap anchor top region sig
  cap="$(cat)"
  if anchor="$(printf '%s\n' "$cap" | ic_anchor)"; then
    top="${anchor%% *}"
    region="$(printf '%s\n' "$cap" | awk -v t="$top" 'NR>=t')"
    printf '%s\n' "$region" | grep -qiE "$TC_QUEUED_REGEX"
    return $?
  fi
  # Línea COMPLETA (inicio Y fin) — mismo principio que el título de menú: un sufijo/prefijo ajeno en la
  # misma línea la descarta como candidata, no solo el contenido en líneas posteriores.
  sig="^[[:space:]]*${TC_QUEUED_REGEX}[[:space:]]*\$"
  printf '%s\n' "$cap" | ic_find_live_signal "$sig" "$TC_QUEUED_REGEX"
}

# BUSY: estructural, nunca ventana absoluta. CON CORNER: lookback de TC_BUSY_LOOKBACK (hoy 2) líneas
# INMEDIATAMENTE antes de `top` — subido de 1 a 2 porque el frame real observado en campo es de DOS
# líneas (indicador + su pie "Tip: …", ver ic_is_pie_line). LIMITACIÓN RECONOCIDA: un snapshot ÚNICO
# nunca puede *probar* vigencia — solo el cambio entre muestras (micro-continuidad, ya usada en
# ic_relay_ready) lo hace. Más la región>=bot (ZONA SEGURA, pie del composer) con la misma estructura
# por campos. SIN CORNER: escaneo propio de la línea MÁS RECIENTE hacia atrás con cadena intacta hasta
# el final REAL (mismo principio que menú/cola, ver ic_detect_busy_from).
# ¿Es <línea> un estado BUSY vivo? Por ESTRUCTURA DE CAMPOS (separados por espacio), no por glifo ni por
# posición fina de bytes junto a un carácter multibyte. Dividir por campos es SEGURO porque el separador
# (espacio ASCII 0x20) nunca es ambiguo frente a una secuencia UTF-8 (ningún byte de continuación UTF-8
# vale 0x20) — a diferencia de un regex que intente anclar posiciones justo DESPUÉS de un glifo
# multibyte, que puede fragmentar sus propios bytes en mawk 1.3.4 (verificado en vivo: un diseño así
# dejó de casar el propio caso real que decía proteger — hallazgo de la pasada fresca r14, NO-GO).
# Contrato (bilateral: identifica lo vivo Y rechaza lo que se le parece, mismo hallazgo r14): 1er campo
# (glifo) NO puramente alfanumérico; 2º campo TERMINA en elipsis ("..."/"…") — SIN exigir nada más
# detrás en ESE campo (una cita/bullet con la elipsis muchas palabras después, p. ej. "> Sock-hopping
# through the results and thinking more...", nunca tiene la elipsis pegada al 2º campo, así que no
# casa); y lo que queda tras el 2º campo está vacío o es EXACTAMENTE el cierre paréntesis-con-duración
# ya conocido — un sufijo ajeno detrás del paréntesis (p. ej. "(citado)") rompe la coincidencia.
# ¿Es <línea> el PIE estructural que acompaña a un indicador BUSY (p. ej. "⎿ Tip: …")? Por CAMPOS: 1er
# campo EXACTAMENTE el glifo de pie "⎿", 2º campo EXACTAMENTE "Tip:" — identidad de CAMPO Y de GLIFO,
# no solo posición (hallazgo MAYOR de la pasada r16: "anclado" con solo "1er campo no alfanumérico"
# significa POSICIÓN, no IDENTIDAD ESTRUCTURAL — deja pasar "> Tip:", "┃ Tip:", "• Tip:", "? Tip:", que
# son citas/bullets/pies de Markdown reales, no el pie real del indicador). El glifo "⎿" es la ÚNICA
# forma observada en las tres capturas reales distintas de este frame (glifos de BUSY distintos —
# "✶ Sock-hopping…", "* Bootstrapping…" — comparten SIEMPRE el mismo pie "⎿ Tip: …"): no es un catálogo
# del glifo de BUSY (eso rota y está prohibido enumerar, ver ic_is_busy_line) — es UN único glifo
# estructural estable, evidenciado en campo, no supuesto.
ic_is_pie_line() { # (stdin = una línea, sin ANSI)
  awk '
    function is_pie(line,    n, f, i, start) {
      n = split(line, f, /[[:space:]]+/)
      start = 0
      for (i = 1; i <= n; i++) { if (f[i] != "") { start = i; break } }
      if (!start) return 0
      if (f[start] != "⎿") return 0
      return (start+1 <= n && f[start+1] == "Tip:") ? 1 : 0
    }
    { exit (is_pie($0) ? 0 : 1) }
    END { if (NR == 0) exit 1 }
  '
}

# ¿Es <línea> un estado BUSY vivo? Recibe la línea SIGUIENTE (hacia el composer/hacia el final real)
# como argumento — puede ser cadena vacía si no hay ninguna. DISEÑO ESTRUCTURAL (MAYOR de la pasada r17:
# "tu predicado sigue siendo un catálogo, más largo cada vez, en vez de una clase estructural" — r15
# enumeró glifos de BUSY, r16 corrigió eso pero dejó una lista de glifos de PROSA a excluir, r17 mostró
# que esa lista también es un catálogo sin fin, CommonMark siempre tiene un marcador más: `-`, `+`,
# listas ordenadas "N."/"N)", em-dash…). SIN listas de exclusión de prosa: el DEFAULT es EXIGIR el pie
# anclado real (ic_is_pie_line, glifo "⎿") para CUALQUIER glifo — positivo o desconocido, rotativo o no
# — salvo los DOS glifos con IDENTIDAD POSITIVA DEMOSTRADA por una captura real que los muestra formando
# un frame de UNA SOLA LÍNEA (duración/contador, sin pie adyacente): "●" y "✢" (ver selftest, tests
# reales sin pie). Todo lo demás — incluido "*", bullet Markdown real Y glifo de BUSY real observado a
# la vez, y CUALQUIER marcador de prosa futuro no enumerado — cae por defecto en "exige pie", cerrando
# la clase entera de una vez en vez de perseguir el próximo carácter.
#   (A) SIN paréntesis (p. ej. "✶ Sock-hopping…"): SIEMPRE exige el pie ANCLADO adyacente (ic_is_pie_line,
#       NUNCA una función embebida duplicada — un mismo predicado con dos sedes diverge, hallazgo r16).
#   (B) CON un único paréntesis bien formado: exige un CAMPO COMPLETO (no subcadena — "(sha5sum)" no
#       puede colar por la subcadena "5s" que lleva dentro, hallazgo r16) que sea una duración
#       (`Ns`/`Nms`/`NmNs` sin espacio) o un contador con flecha (`↓`/`↑` + campo que empiece por
#       dígito) — Y, salvo que el glifo esté en el par positivamente demostrado ("●"/"✢"), TAMBIÉN
#       exige el pie anclado adyacente, exactamente igual que la forma sin paréntesis.
ic_is_busy_line() { # <línea_siguiente_o_vacía>  (stdin = línea a evaluar, sin ANSI)
  local nextline="${1:-}" pie_next=0
  if [ -n "$nextline" ] && printf '%s' "$nextline" | ic_is_pie_line; then pie_next=1; fi
  awk -v pie_next="$pie_next" '
    function is_busy(line,    n, f, i, start, glyph, word, rest, j, interior, toks, nt, k, dur_ok, arrow_ok) {
      n = split(line, f, /[[:space:]]+/)
      start = 0
      for (i = 1; i <= n; i++) { if (f[i] != "") { start = i; break } }
      if (!start) return 0
      glyph = f[start]
      if (glyph ~ /^[[:alnum:]]+$/) return 0
      word = (start+1 <= n) ? f[start+1] : ""
      if (word == "" || word !~ /(\.\.\.|…)$/) return 0
      rest = ""
      for (j = start+2; j <= n; j++) rest = rest (rest=="" ? "" : " ") f[j]
      if (rest == "") return pie_next
      if (rest !~ /^\([^()]*\)$/) return 0
      interior = substr(rest, 2, length(rest) - 2)
      nt = split(interior, toks, /[[:space:]]+/)
      dur_ok = 0
      # Token COMPLETO (anclado ^...$), no subcadena ("sha5sum" no puede colar por "5s" dentro,
      # hallazgo r16). Tres formas, cada una anclada a fin de token: "Ns" (segundos, "29s"), "Nms"
      # (milisegundos, unidad literal pegada, "50ms") y "NmMs" minutos+segundos SIN espacio ("1m3s",
      # formato documentado por el sistema fuente) — distinto de "12m 49s" CON espacio, que ya llegan
      # como dos tokens separados y cada uno se evalúa solo ("49s" ya matchea la forma simple).
      for (k = 1; k <= nt; k++) { if (toks[k] ~ /^[0-9]+(s|ms|m[0-9]+s)$/) { dur_ok = 1; break } }
      arrow_ok = 0
      for (k = 1; k < nt; k++) {
        if ((toks[k] == "↓" || toks[k] == "↑") && toks[k+1] ~ /^[0-9]/) { arrow_ok = 1; break }
      }
      if (!(dur_ok || arrow_ok)) return 0
      if (glyph == "●" || glyph == "✢") return 1
      return pie_next
    }
    { exit (is_busy($0) ? 0 : 1) }
    # Línea VACÍA (sin newline final, p. ej. `printf %s ""`) -> awk lee CERO registros, el bloque de
    # arriba nunca corre, y el exit status "natural" de awk (0 = éxito) se leería como "BUSY" por
    # error — hallazgo propio, verificado con el fixture real del selftest. END fuerza rc=1 (no-busy)
    # cuando no hubo ningún registro que clasificar.
    END { if (NR == 0) exit 1 }
  '
}

ic_detect_busy_from() { # (stdin sin ANSI)
  local cap anchor top bot lookback region i n arr line nxt
  cap="$(cat)"
  if anchor="$(printf '%s\n' "$cap" | ic_anchor)"; then
    top="${anchor%% *}"; bot="${anchor##* }"
    lookback="$(printf '%s\n' "$cap" | awk -v t="$top" -v n="$TC_BUSY_LOOKBACK" 'NR<t && NR>=t-n')"
    if [ -n "$lookback" ] && ! printf '%s\n' "$lookback" | grep -qE "$TC_SHELL_ECHO_RE"; then
      mapfile -t arr <<< "$lookback"
      for (( i=0; i<${#arr[@]}; i++ )); do
        nxt="${arr[$((i+1))]:-}"
        printf '%s' "${arr[$i]}" | ic_is_busy_line "$nxt" && return 0
      done
    fi
    # ZONA SEGURA: desde el borde INFERIOR hacia abajo (pie), nunca desde `top` — el interior del
    # composer (entre top y bot) es contenido de usuario/placeholder, no un indicador de estado; un
    # placeholder atenuado que termina en "..." (p. ej. "escribe...") empieza tras el borde vertical `│`
    # (un símbolo válido para el chequeo de cabecera) y podía leerse como BUSY por error si se escaneaba
    # el interior — hallazgo propio, verificado con el fixture real del selftest. MISMA firma por línea.
    region="$(printf '%s\n' "$cap" | awk -v b="$bot" 'NR>=b')"
    mapfile -t arr <<< "$region"
    for (( i=0; i<${#arr[@]}; i++ )); do
      nxt="${arr[$((i+1))]:-}"
      printf '%s' "${arr[$i]}" | ic_is_busy_line "$nxt" && return 0
    done
    return 1
  fi
  # SIN CORNER: busca de la línea MÁS RECIENTE hacia atrás una que sea BUSY por estructura (excluyendo
  # candidatos que luzcan como un comando citando la señal, p. ej. `$ echo "..."`), pasándole la línea
  # SIGUIENTE real (para la forma sin paréntesis, que exige el pie anclado ahí mismo), y exige que la
  # cadena hasta el final real esté intacta — tolera blanco y el pie ANCLADO (ic_is_pie_line, no una
  # subcadena "Tip:" suelta); cualquier otra línea rompe la cadena y descarta el candidato como cita
  # vieja, sea cual sea su distancia al final.
  n="$(printf '%s\n' "$cap" | wc -l)"
  for (( i=n; i>=1; i-- )); do
    line="$(printf '%s\n' "$cap" | sed -n "${i}p")"
    printf '%s' "$line" | grep -qE "$TC_SHELL_ECHO_RE" && continue
    nxt=""
    [ "$i" -lt "$n" ] && nxt="$(printf '%s\n' "$cap" | sed -n "$((i+1))p")"
    printf '%s' "$line" | ic_is_busy_line "$nxt" || continue
    if printf '%s\n' "$cap" | awk -v s="$((i+1))" '
        function is_pie(line,    n, f, i, start) {
          n = split(line, f, /[[:space:]]+/)
          start = 0
          for (i = 1; i <= n; i++) { if (f[i] != "") { start = i; break } }
          if (!start) return 0
          if (f[start] != "⎿") return 0
          return (start+1 <= n && f[start+1] == "Tip:") ? 1 : 0
        }
        NR>=s {
          if ($0 ~ /^[[:space:]]*$/) next
          if (is_pie($0)) next
          bad=1
        }
        END { exit (bad ? 1 : 0) }'; then
      return 0
    fi
  done
  return 1
}

# PENDING: contenido REAL no-dim dentro de la región del composer (por CONTENIDO, jamás por el glifo ❯).
# Debe evaluarse DESPUÉS de menú. Recibe cap_e (con ANSI) y las líneas top/bot ya calculadas.
ic_detect_pending_region() { # top bot  (stdin = captura -e)
  local top="$1" bot="$2"
  [ "$top" -gt 0 ] && [ "$bot" -gt "$top" ] || return 1
  awk -v t="$top" -v b="$bot" 'NR>t && NR<b' \
    | ic_strip_dim \
    | ic_norm_nbsp \
    | sed -E 's/[│╭╮╰╯─❯>]//g' \
    | grep -q '[^[:space:]]'
}

# TRI-ESTADO del composer — NUNCA colapsar "sin chrome anclable" en "vacío" (eso fue el hallazgo del
# auditor: una captura sin CORNER localizable NO prueba que el texto se consumió). Devuelve:
#   CON-TEXTO 0 · VACIO 1 (estructural, CORNER localizado y sin contenido) · AMBIGUO 2 (sin CORNER —
#   jamás confirma entrega).
ic_composer_state() { # (stdin = captura -e)
  local cap_e cap_plain anchor top bot
  cap_e="$(cat)"
  cap_plain="$(printf '%s' "$cap_e" | ic_strip_ansi)"
  if ! anchor="$(printf '%s\n' "$cap_plain" | ic_anchor)"; then
    echo AMBIGUO; return 2
  fi
  top="${anchor%% *}"; bot="${anchor##* }"
  if printf '%s\n' "$cap_e" | ic_detect_pending_region "$top" "$bot"; then
    echo CON-TEXTO; return 0
  fi
  echo VACIO; return 1
}

# ¿Aparece <texto> LITERAL dentro de la región del composer (por CORNER, no "algún texto")? rc0 solo si
# el texto EXACTO está presente; rc2 si no hay CORNER anclable (AMBIGUO — el llamador nunca lo trata como
# confirmación).
ic_composer_contains() { # <texto>  (stdin = captura -e)
  local expected="$1" cap_e cap_plain anchor top bot region
  cap_e="$(cat)"
  cap_plain="$(printf '%s' "$cap_e" | ic_strip_ansi)"
  anchor="$(printf '%s\n' "$cap_plain" | ic_anchor)" || return 2
  top="${anchor%% *}"; bot="${anchor##* }"
  region="$(printf '%s\n' "$cap_e" | awk -v t="$top" -v b="$bot" 'NR>t && NR<b' | ic_strip_dim)"
  printf '%s' "$region" | grep -qF -- "$expected"
}

# --- Clasificación pura de una captura del viewport ACTUAL (stdin = captura -e) ---
# Orden ESTRICTO: ENCOLADO -> MENÚ -> PENDING -> BUSY -> IDLE-CANDIDATO. Imprime token, rc = código.
# ic_menu_open/ic_queue_pending son la FUENTE ÚNICA del límite anti-scrollback — ic_classify y relay.sh
# las comparten para no divergir en dos implementaciones del mismo límite.
ic_classify() {
  local cap_e cap_plain anchor top bot
  cap_e="$(cat)"
  [ -n "$cap_e" ] || { echo UNKNOWN; return 2; }
  cap_plain="$(printf '%s' "$cap_e" | ic_strip_ansi)"

  if printf '%s\n' "$cap_plain" | ic_queue_pending; then echo COMPOSER-CON-TEXTO-SIN-ENVIAR; return 11; fi
  if printf '%s\n' "$cap_plain" | ic_menu_open;    then echo MENU-ABIERTO;                  return 10; fi

  if anchor="$(printf '%s\n' "$cap_plain" | ic_anchor)"; then
    # CON CORNER: además de queued/menú (ya evaluados arriba sobre la región correcta), PENDING por
    # contenido real en la caja del composer.
    top="${anchor%% *}"; bot="${anchor##* }"
    if printf '%s\n' "$cap_e" | ic_detect_pending_region "$top" "$bot"; then
      echo COMPOSER-CON-TEXTO-SIN-ENVIAR; return 11
    fi
    if printf '%s\n' "$cap_plain" | ic_detect_busy_from; then echo BUSY; return 1; fi
    echo IDLE-CANDIDATO; return 0
  fi

  # SIN CORNER anclable: no hay límite estructural del composer, así que SOLO señales POSITIVAS
  # inequívocas cuentan (queued/menú ya evaluados arriba, exigiendo cadena INTACTA hasta el final real —
  # ic_chain_intact_from, nunca una ventana o tolerancia de distancia). Ante cualquier otra ambigüedad →
  # UNKNOWN. NUNCA IDLE-CANDIDATO sin composer estructural localizado (hallazgo del auditor: pantalla no
  # calibrada/shell/redraw estático no es "candidato a idle").
  if printf '%s\n' "$cap_plain" | ic_detect_busy_from; then echo BUSY; return 1; fi
  echo UNKNOWN; return 2
}

# --- Árbol de procesos: ¿hay trabajo vivo bajo el residente del pane? ---
# PURO y testeable. Contrato EXACTO (hallazgo del auditor): excluye SOLO el PID residente en sí —
# CUALQUIER descendiente vivo del residente (a cualquier profundidad, sea el comm que sea: bash, watch,
# cat, tail, sleep, npm…) cuenta como TRABAJO. NO se filtra por nombre de comando: un gate/watcher/tail
# vivo bajo el residente NO puede leerse como "sin trabajo" solo porque su comm parezca transitorio.
ic_tree_has_worker_from() { # resident_pid  (stdin = tuplas "pid ppid comm")
  awk -v root="$1" '
    { ppid[$1]=$2 }
    END {
      n=0; queue[n++]=root; seen[root]=1; worker=0
      for (h=0; h<n && !worker; h++) {
        cur=queue[h]
        for (i in ppid) {
          if (ppid[i]==cur && !seen[i]) { seen[i]=1; queue[n++]=i; worker=1 }
        }
      }
      exit (worker ? 0 : 1)
    }'
}

# --- Resolución de target -> transporte (host tmux vs incus) ---
TC_MODE=""; TC_CONTAINER=""; TC_SESSPANE=""; TC_TMUX_CMD=()
_tc_resolve() { # <target>
  local t="$1" nn actor sess pane
  case "$t" in
    host:*)
      t="${t#host:}"
      [[ "$t" =~ ^[A-Za-z0-9._-]+$ ]] || { tc_err "target host inválido: $1"; return 2; }
      sess="${t%.*}"; pane="${t#"$sess"}"
      TC_MODE="host"; TC_SESSPANE="${sess}${pane:-.0}"
      TC_TMUX_CMD=(tmux); [ -n "$TC_TMUX_L" ] && TC_TMUX_CMD+=(-L "$TC_TMUX_L")
      ;;
    torre-*)
      actor="${t#torre-}"
      [[ "$actor" =~ ^[A-Za-z0-9._-]+$ ]] || { tc_err "actor de torre inválido: $1"; return 2; }
      TC_MODE="host"; TC_SESSPANE="torre-${actor}.0"
      TC_TMUX_CMD=(tmux); [ -n "$TC_TMUX_L" ] && TC_TMUX_CMD+=(-L "$TC_TMUX_L")
      ;;
    canal-*|ch-*|ch[0-9]*)
      nn="${t#canal-}"; nn="${nn#ch-}"; nn="${nn#ch}"
      [[ "$nn" =~ ^[0-9]+$ ]] || { tc_err "id de canal inválido: $1"; return 2; }
      # TC_TMUX/TC_DEV_PANE son overrides de entorno: validados aquí ADEMÁS del paso posicional
      # (defensa en profundidad, no la única barrera — ver _tc_cap_e/_tc_send_key).
      [[ "$TC_TMUX" =~ ^[A-Za-z0-9._-]+$ ]] || { tc_err "TC_TMUX inválido: $TC_TMUX"; return 2; }
      [[ "$TC_DEV_PANE" =~ ^\.[0-9]+$ ]] || { tc_err "TC_DEV_PANE inválido: $TC_DEV_PANE"; return 2; }
      TC_MODE="incus"; TC_CONTAINER="${TC_PREFIX}${nn}"; TC_SESSPANE="${TC_TMUX}:${TC_DEV_PANE}"
      ;;
    *) tc_err "target no reconocido: $1"; return 2 ;;
  esac
  # Return EXPLÍCITO: sin esto, el rc de la función es el del ÚLTIMO comando ejecutado en la rama —
  # en host:*/torre-*, ese último comando es `[ -n "$TC_TMUX_L" ] && ...`, que da rc 1 cuando
  # TC_TMUX_L está VACÍO (su valor normal en producción, fuera del selftest). Sin este return, TODA
  # resolución exitosa de host:/torre- fallaba silenciosamente (hallazgo BLOQUEANTE del auditor).
  return 0
}

# Captura del viewport ACTUAL (con ANSI) — para detección de ESTADO (anti-scrollback).
# TC_SESSPANE viaja SIEMPRE como POSICIONAL al shell remoto (nunca interpolado en la cadena de -c):
# defensa EN PROFUNDIDAD junto a la validación por regex de TC_TMUX/TC_DEV_PANE en _tc_resolve — el
# posicional es la barrera que no depende de que ningún override futuro conserve esa validación.
# shellcheck disable=SC2016
_tc_cap_e() {
  case "$TC_MODE" in
    host)  "${TC_TMUX_CMD[@]}" capture-pane -t "$TC_SESSPANE" -p -e -J 2>/dev/null ;;
    incus) incus exec "$TC_CONTAINER" -- su - "$TC_CUSER" -c \
             'tmux capture-pane -t "$1" -p -e -J' _ "$TC_SESSPANE" 2>/dev/null ;;
  esac
}

# Captura con ventana AMPLIA (scrollback TC_CAP_LINES) — para confirmar ENTREGA/contenido que ya scrolleó.
# shellcheck disable=SC2016
_tc_cap_wide() {
  case "$TC_MODE" in
    host)  "${TC_TMUX_CMD[@]}" capture-pane -t "$TC_SESSPANE" -p -e -J -S "-$TC_CAP_LINES" 2>/dev/null ;;
    incus) incus exec "$TC_CONTAINER" -- su - "$TC_CUSER" -c \
             'tmux capture-pane -t "$1" -p -e -J -S "-$2"' _ "$TC_SESSPANE" "$TC_CAP_LINES" 2>/dev/null ;;
  esac
}

# shellcheck disable=SC2016
_tc_pane_pid() {
  case "$TC_MODE" in
    host)  "${TC_TMUX_CMD[@]}" display-message -p -t "$TC_SESSPANE" '#{pane_pid}' 2>/dev/null ;;
    incus) incus exec "$TC_CONTAINER" -- su - "$TC_CUSER" -c \
             'tmux display-message -p -t "$1" "#{pane_pid}"' _ "$TC_SESSPANE" 2>/dev/null ;;
  esac
}

_tc_ps() { # tuplas "pid ppid comm"
  case "$TC_MODE" in
    host)  ps -eo pid=,ppid=,comm= 2>/dev/null ;;
    incus) incus exec "$TC_CONTAINER" -- ps -eo pid=,ppid=,comm= 2>/dev/null ;;
  esac
}

# ¿Trabajo vivo bajo el residente del pane? Identifica el residente ESTRUCTURALMENTE (sin nombrar
# productos/CLIs, ver Regla 6): pane_pid es el residente si NO es un shell envolvente; si lo es (login
# shell del pane), el residente es su primer hijo directo que TAMPOCO es un shell — el proceso que ese
# shell arrancó, sea cual sea (agnóstico de qué CLI/binario es). Con eso resuelto, cualquier descendiente
# del residente cuenta como trabajo (ic_tree_has_worker_from, sin filtro de nombre).
_tc_tree_has_worker() {
  local pid tuples resident child rc=0 pcomm
  pid="$(_tc_pane_pid)" || return 2
  [[ "$pid" =~ ^[0-9]+$ ]] || return 2
  tuples="$(_tc_ps)" || return 2
  [ -n "$tuples" ] || return 2
  pcomm="$(printf '%s\n' "$tuples" | awk -v p="$pid" '$1==p{print $3; exit}')"
  if ! printf '%s' "$pcomm" | grep -qE "$TC_SHELL_COMM_RE"; then
    resident="$pid"
  else
    child="$(printf '%s\n' "$tuples" | IC_COMM_RE="$TC_SHELL_COMM_RE" awk -v p="$pid" 'BEGIN {re=ENVIRON["IC_COMM_RE"]} $2==p && $3 !~ re {print $1; exit}')"
    resident="${child:-$pid}"
  fi
  printf '%s\n' "$tuples" | ic_tree_has_worker_from "$resident" || rc=$?
  return "$rc"   # rc 0 = hay trabajo · 1 = no hay
}

# --- Estado persistido de macro-continuidad (atómico + flock) ---
_tc_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
_tc_state_first_seen() { # slug hash  -> imprime first_seen (epoch), creando/reseteando según cambio observado
  local slug="$1" h="$2" dir="$TC_STATE_DIR" f lock now old_h old_first first tmp
  mkdir -p "$dir"
  f="$dir/${slug}.state"; lock="$dir/${slug}.lock"; now="$(date +%s)"
  exec 9>"$lock"; flock 9
  old_h=""; old_first=""
  if [ -f "$f" ]; then read -r old_h old_first < "$f" || { old_h=""; old_first=""; }; fi
  if [ "$old_h" = "$h" ] && [[ "${old_first:-}" =~ ^[0-9]+$ ]]; then first="$old_first"; else first="$now"; fi
  tmp="$(mktemp "${dir}/.state.XXXXXX")"
  printf '%s\t%s\n' "$h" "$first" > "$tmp"
  mv -f "$tmp" "$f"
  flock -u 9; exec 9>&-
  printf '%s' "$first"
}

# --- RELAY-READY: idle estable INSTANTÁNEO (sin macro-300 s). Para la precondición de relay.sh. ---
# CORRECCIÓN (TAL-5141, post-demo AC-2): antes, CUALQUIER no-éxito de ic_classify (incluido rc 2/UNKNOWN,
# "no localicé el composer") se aplanaba a "NOT-READY:$tok" con rc 1 fijo — un fail-closed SILENCIOSO que
# se leía como "ocupado, prudencia" y en realidad era CEGUERA del instrumento (no vio nada). Ahora rc 2
# de ic_classify (y la falta de captura, que es la misma familia: "no pude mirar") se propaga como
# NO-MEDIDO, un prefijo/rc DISTINTO de NOT-READY — el llamador (relay.sh) ya distingue ambos casos
# (ver su manejo de ready==2) y NO debe tratar "no medido" como "reintentable igual que ocupado".
ic_relay_ready() { # <target>  ; imprime READY | NOT-READY[:motivo] | NO-MEDIDO[:motivo]
  _tc_resolve "$1" || return 2
  { [[ "$TC_MICRO_N" =~ ^[0-9]+$ ]] && [ "$TC_MICRO_N" -ge "$TC_MICRO_N_MIN" ]; } \
    || { tc_err "TC_MICRO_N=$TC_MICRO_N inválido (mínimo $TC_MICRO_N_MIN)"; echo "NO-MEDIDO:config"; return 2; }
  local i cap tok rc prev="" norm
  for (( i=1; i<=TC_MICRO_N; i++ )); do
    cap="$(_tc_cap_e)" || { echo "NO-MEDIDO:sin-captura"; return 2; }
    [ -n "$cap" ] || { echo "NO-MEDIDO:sin-captura"; return 2; }   # captura vacía != composer vacío
    rc=0; tok="$(printf '%s\n' "$cap" | ic_classify)" || rc=$?
    if [ "$rc" -eq 2 ]; then echo "NO-MEDIDO:${tok}"; return 2; fi   # UNKNOWN: no vi el composer, no es "ocupado"
    [ "$rc" -eq 0 ] || { echo "NOT-READY:${tok}"; return 1; }
    norm="$(printf '%s\n' "$cap" | ic_strip_ansi | sed -E 's/[[:space:]]+$//')"
    if [ -n "$prev" ] && [ "$norm" != "$prev" ]; then echo "NOT-READY:cambia"; return 1; fi
    prev="$norm"
    [ "$i" -lt "$TC_MICRO_N" ] && sleep "$TC_MICRO_GAP"
  done
  echo READY; return 0
}

# --- IDLE-REAL: las 6 condiciones (micro + macro 300 s + árbol de procesos). Para el sweep. ---
ic_idle_real() { # <target>  ; imprime el token; rc = código
  local target="$1" rr worker_rc cap norm hash first now
  rr=0; ic_relay_ready "$target" >/dev/null || rr=$?
  if [ "$rr" -eq 2 ]; then echo UNKNOWN; return 2; fi
  if [ "$rr" -ne 0 ]; then
    # No es idle instantáneo: reclasifica para dar el token accionable (busy/menú/pending/…).
    cap="$(_tc_cap_e)" || { echo UNKNOWN; return 2; }
    local rc=0 tok; tok="$(printf '%s\n' "$cap" | ic_classify)" || rc=$?
    [ "$rc" -eq 0 ] && { echo IDLE-PENDIENTE; return 3; }   # estable-instantáneo falló por micro-cambio
    echo "$tok"; return "$rc"
  fi
  worker_rc=0; _tc_tree_has_worker || worker_rc=$?
  if [ "$worker_rc" -eq 0 ]; then echo BUSY; return 1; fi        # hay build/gate vivo -> no idle
  if [ "$worker_rc" -eq 2 ]; then echo UNKNOWN; return 2; fi
  cap="$(_tc_cap_e)" || { echo UNKNOWN; return 2; }
  norm="$(printf '%s\n' "$cap" | ic_strip_ansi | sed -E 's/[[:space:]]+$//')"
  hash="$(printf '%s' "$norm" | cksum | tr -d ' ')"
  first="$(_tc_state_first_seen "$(_tc_slug "$target")" "$hash")"
  now="$(date +%s)"
  if [[ "$first" =~ ^[0-9]+$ ]] && [ "$(( now - first ))" -ge "$TC_IDLE_WINDOW" ]; then
    echo IDLE-REAL; return 0
  fi
  echo IDLE-PENDIENTE; return 3
}

# --- CLI (solo al ejecutar, no al sourcear) ---
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --classify) ic_classify; exit $? ;;
    --relay-ready)
      [ $# -ge 2 ] || { tc_err "uso: idle-check.sh --relay-ready <target>"; exit 2; }
      rc=0; out="$(ic_relay_ready "$2")" || rc=$?; printf '%s\n' "$out"; exit "$rc" ;;
    ""|-h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 2 ;;
    *)
      rc=0; out="$(ic_idle_real "$1")" || rc=$?; printf '%s\n' "$out"; exit "$rc" ;;
  esac
fi
