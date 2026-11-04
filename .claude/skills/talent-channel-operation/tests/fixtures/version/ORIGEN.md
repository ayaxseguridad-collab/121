# Capturas reales de `--version`

Positivos de la gramática cerrada de la versión del CLI (`references/formas-version.tsv`). Cada `.bin` es el
stdout crudo de `<cli> --version`, sin editar (stderr descartado), capturado el 17-oct-2026.

| fichero | CLI | versión | SHA-256 |
|---|---|---|---|
| `claude--version.bin` | Claude Code | 2.1.301 | `f98cef0381704b555d9188ed0ac009867d71df3478510517617c28f5a5054953` |
| `codex--version.bin` | Codex CLI | 0.162.1 | `1df57fdc934f35bbd09e26308fbbd895698596f3be833ace1027c6bcfd2f81e2` |

`corpus-paridad.tsv` es el corpus COMPARTIDO de la prueba de paridad entre el humo de la instalación y el despacho:
`etiqueta<TAB>cli<TAB>salida<TAB>esperado`. La salida es `@<fichero>` (uno de los `.bin` de esta carpeta) o texto
ASCII imprimible sin barra invertida con bytes `\xHH`; el esperado es `<cli>:<x.y.z>` o `rc1`.
