# Capturas y controles del CLI actual

idle.txt: recorte de g4-vigia-c1, primer canal v.0.
busy.txt: recorte de g4-vigia-c1, primera torre ocupada.
plan.txt: recorte de g8-vigia-c1, canal tras /effort.
triplicated.txt: recorte de g4-vigia-c1, canal v.0 a las 15:52:02Z.
survey-rating.txt: recorte de g8-vigia-c1, canal v.0 a las 16:04:28Z.
Se sustituyen únicamente usuario, repositorio e identificador aleatorio por datos neutros.
Se preservan sangría, espacio inseparable y carácter de sustitución en el borde.

wrapped-two.txt y wrapped-three.txt son controles derivados: una copia íntegra
del relay con dos o tres líneas. La captura original triplicada contiene copias
parciales; no se presenta como tres envíos íntegros.
g6-panes solo aporta dimensiones y diagnósticos, no una captura del compositor.

Los controles de confianza, picker, aviso y redibujado de la suite son
sintéticos. En g4–g11 consultados no se conserva una captura completa de esos
estados; el descarte de la encuesta con 0 está documentado en g10. No se da de alta un par
en TCO_PANE_CALIBRATED con un juego real incompleto.

La variable CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY se verificó por lectura del
código embebido en binarios locales 2.1.283 y 2.1.289: el control de aparición
devuelve false cuando está definida. El ajuste feedbackSurveyRate también figura
en el esquema (0–1). No estaba disponible el binario mínimo 2.1.280; su soporte
no se da por verificado. La encuesta sigue clasificada como modal y se descarta
con 0, mecanismo documentado por el ensayo.
El texto de rating «How is Claude doing this session? (optional)» también se
verificó en el código embebido de 2.1.289; se incluye como control de texto,
sin presentarlo como una captura del panel.

transcript-interrumpido-ch11.jsonl (1.7.4f, CLI 2.1.304): registros SANEADOS del JSONL
del dev de ch11 en el ensayo 174e, en su orden real (agent-name, attachment, user). Conserva
`type`, marcas de tiempo y la forma de `message.content` (array con un elemento `text` =
«[Request interrupted by user]»); `jq` solo lee esos campos. Sin más contenido del transcript.
transcript-humano-cadena.jsonl: control. La forma del prompt humano (`type=user`, `content` como
STRING, sin isMeta) se midió en transcripts locales del CLI vigente leyendo SOLO type, tipo de
`content` y claves; el texto es un literal neutro ≤40 caracteres, no el del transcript.
