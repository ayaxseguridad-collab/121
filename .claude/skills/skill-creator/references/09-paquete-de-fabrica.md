# 09 — Paquete de skills de fábrica: doctrina y ratchet (D6)

El paquete (16 miembros, manifiesto en `assets/package.manifest`) es canónico en el MOTOR
`talent-factory` y viaja JUNTO a los repos de producto (`scripts/sync-package.sh`, overlays
por repo intactos; paridad del núcleo = `--check`). La doctrina-como-test vive en
`<skill>/invariants.tsv` y la evalúa `scripts/validate-package.sh` (rc 0/1/2, anti-vacuo).

En `--estado instancia`, los diez invariantes del anexo PROC-M13 del Mergeador
(052/137/138/139/148/318/319/326/345/352) se evalúan contra `TCO_ANEXO_FILE`
solo si `TCO_REPO_STACK=supabase`. Con `ninguno` o `convex` se listan como
`SKIP`, con motivo «PROC-M13 no aplica al stack <x>», separados de PASS/FAIL
y de las invariantes evaluadas (`SKIP-STACK` en el resumen). La identidad se
lee como datos con `pkg_parse_identity_conf`: ausencia de identidad o stack
fuera del enum, incluido vacío, da rc 2. Un MUST sin doctrina en supabase
sigue dando FAIL. En `--estado distribucion` continúa `SKIP-OVERLAY`.
Las suites `proc-m13` y el caso del anexo de `proc13-pointers` siguen la misma
aplicabilidad; los otros tres casos de punteros se evalúan para cualquier stack.

El runner `scripts/run-all-suites.sh` ejecuta la batería completa en serie.
`--solo <id>` reproduce una suite (por ejemplo `--solo validate` desde la
sesión de instalación). `--sin <id>` excluye una suite de la batería completa
y es repetible: `--sin talent-channels` permite comprobar el resto desde una
sesión activa. Cada exclusión se lista como SKIP «excluida por el operador»,
separada de PASS. La guarda de procesos vivos se consulta únicamente si la
selección incluye `talent-channels`; entonces aborta con rc 2 antes de ejecutar
cualquier suite. `--listar` muestra los identificadores disponibles.
El runner exige rc y resultado final sin fallos, y rechaza omisiones ajenas al
contrato de cada fila. Patches exige checkout local con el pin (también worktree)
y ejecuta con `TB_BUZZ_SIN_RED=1`: perder el proveedor es FAIL, sin transporte.
Toda fila con resumen declarado debe emitirlo también con omisiones parciales.
Solo PROC-M13 admite omisión completa sin resumen: una línea explícita y cero asserts.
Antifugas declara `LIMPIO` o el contador de hallazgos; un contador positivo falla
incluso con rc 0. También se declaran los resultados cualitativos de referencia LLM
y total derivado, y el censo final de syntax. Shellcheck solo imprime su inventario
antes del análisis y diagnósticos por error: carece de resultado final; manda su rc.
El censo de syntax no expresa errores: además del censo obligatorio manda su rc.
CEO incluye supervisión y su ronda 3 en el caso `[r16-1]`: conserva los 258 casos
y propaga el rc y autoconteo de la suite de 530 casos. No se duplican en el inventario.

## Regla de ratchet (D6 — «una lección aprendida no se des-aprende en silencio»)

- (a) Toda gotcha/bounce nuevo de clase textual-doctrinal añade su fila en `invariants.tsv`
  EN EL MISMO cambio que toca el skill (gotcha → invariant).
- (b) Borrar o debilitar una fila exige GO explícito del lead + entrada en el CHANGELOG del
  skill citando ese GO (espejo del patrón RATIFICACIONES del motor).
- (c) El diff de `invariants.tsv` es SUPERFICIE SENSIBLE de review: quien viola un MUST_NOT
  podría borrar la fila en el mismo commit — el revisor lo trata como intento de bypass.
- Las filas sobre archivos OVERLAY solo pueden assertar FORMA, jamás identidad por-repo (D13).
- Prohibido el rsync manual del paquete: la herramienta única es `sync-package.sh`
  (exclusiones mecánicas del manifiesto; `--apply` exige `--authority` y preflight dos-fases).

## Alta de un miembro nuevo — procedimiento MEDIDO (precedente del 16.º, TAL-5444)

Para que el 17.º entre sin que nadie tenga que recordar los pasos. Dos clases, y **solo la primera
rompe el gate**: lo demás es coherencia y revisión.

### Gate-enforced (si falta, `validate-package.sh --strict-set` da FAIL)

1. **`assets/package.manifest`** — subir `version=`, añadir `member=<nuevo>` en **posición
   alfabética** y, si el skill lleva overlay, su `overlay=` u `overlay-prefix=`.
2. **`skills/<nuevo>/`** — `SKILL.md`, `invariants.tsv` (mínimo el `min_invariants` del manifiesto),
   `CHANGELOG.md`, y `references/` con los targets que citen sus invariantes.
3. **Los `SKILL.md` de TODOS los miembros** — el marcador «Paquete de fábrica» lleva el conteo y la
   lista completa. El validador **itera todos los `PKG_MEMBERS` dentro de la sección de cada
   miembro**: en cuanto el manifiesto tiene N+1, las N secciones viejas fallan hasta actualizarse.
   *Es el paso que más veces se olvida y el que rompe el gate entero.*
4. **`skill-creator/invariants.tsv`** — ancla anti-recorte `^member=<nuevo>$`, y otra para el
   overlay si lo hay. Sin ellas, un recorte futuro del manifiesto no enrojece.

### Coherencia y revisión (no rompe el gate, pero deja el repo mintiendo)

5. **`README.md` del motor** — tres sitios: la fila `skills/` de la tabla, «Los **N** skills» y la
   línea del manifiesto.
6. **`skill-creator/references/09-paquete-de-fabrica.md`** — el conteo de la cabecera (este fichero).
7. **`skill-creator/CHANGELOG.md`** — entrada del alta con la versión del manifiesto.
8. **`scripts/lib/inventory.sh`** — su comentario cita el número de skills y **queda falso** con uno
   más. No lo exige ningún precedente: se toca porque si no, miente.

### Cómo verificarlo sin fiarse de la lista

```bash
bash skills/skill-creator/scripts/validate-package.sh --strict-set   # rc 0 y "miembros=<N>"

# El conteo esperado se DERIVA del manifiesto; escribirlo a mano es cómo se queda viejo.
esperado="$(grep -c '^member=' skills/skill-creator/assets/package.manifest)"
for f in skills/*/SKILL.md; do
  grep -Fq "de fábrica** ($esperado):" "$f" || echo "DESACTUALIZADO: $f"
done
```

*(Un `grep` del marcador viejo con la letra `N` literal no encuentra nada y da la falsa impresión de
que no queda ninguno: la comprobación tiene que buscar el conteo **correcto** y señalar a quien no
lo tenga, no buscar el incorrecto.)*

**Un `invariants.tsv` se compara por ID y por contenido, nunca por línea entera**: cambiar la
columna de fichero de un invariante lo hace parecer perdido cuando sigue estando. Si un invariante
**se mueve de fichero**, decirlo en el CHANGELOG — quien lo audite después comparará mal.
