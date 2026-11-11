# 04 — Contrato de creación de issues

> Fuente: TAL-5157 §B4 (contrato) + §B5 (E/D/5A y cierre). Leer antes de crear
> o comentar CUALQUIER issue. `crear_issue_desde_sentry.py` implementa este
> contrato; el humano lo revisa antes del `--apply`.

## Autoridad (supersede el «NO crea issues» de la ref 10)

El Vigía CREA la issue él mismo para **S0-S2** y para el **chore de curación
de ruido**. Para **S3** propone y espera `SENTRY-CONSULTA-*` (no crea sin
adjudicación). Esto cierra el hueco de hoy (las creaba el CEO a mano:
TAL-5127, TAL-5119). El Vigía **nunca cierra** la issue (lo hace `closes
ABC-N` del PR, regla 21); nunca ignora grupos y marca `Resolved` solo con `resolver_ficha.py` y sus tres pruebas verificadas en la misma corrida.

## Skill obligatorio y tipos (matriz sellada de 14 — NO se inventa un tipo)

`talent-issue-craft` obligatorio. **No existe** un tipo `incident`: la matriz
ya tiene `fix|sev1`, `fix|seguridad`, `fix|seguridad+sev1`, `fix|none`,
`chore|none` y `spike-auditoria` (investigación diff-cero de un grupo sin
causa clara). Marcador en el body:
`<!-- issue-craft:v1 type=… variant=… madurez=despachable -->`.

**Gate fail-closed (antes de crear):**
`bash <raíz-del-repo>/scripts/tsx.sh scripts/issue_craft_helper.ts --action audit-issue --file <borrador>.md --min-score 70`
→ exige `exit 0`. Sin `exit 0` no se despacha. Tras crear, `--issue ABC-N`
para acreditar el gate operativo.

## Los 9 campos obligatorios del body (núcleo Vigía, sobre el núcleo issue-craft)

1. **`shortId`** Sentry (`PRODUCTO-XX`) + URL permanente del grupo +
   **fingerprint efectivo** si hay regla en `src/lib/sentry-fingerprint.ts`.
2. **`release`** (`producto@<sha8>`) donde apareció + release vivo al
   redactar.
3. **`firstSeen`/`lastSeen`** (ISO Z **y** CDMX), **`count`**, **`userCount`**.
4. **`tags`**: `environment`, `transaction`/culprit, `source` (literal de
   `safePlay()`/telemetría deliberada si aplica), `runtime`.
5. **Frames in-app** del stack (rutas `src/…`, no chunks hasheados) o nota
   explícita de sourcemaps rotos.
6. **Hipótesis de causa citando código** (`fichero:línea`) — nunca «parece
   que».
7. **Reproducción**: pasos, o el bloque **SQL read-only** que evidencia el
   impacto en datos, o «no reproducible: solo prod» + qué instrumentación
   falta.
8. **Criterio de cierre E/D/5A**: *Error apagado / Deploy identificado /
   verificado en prod* — cifra exacta de eventos nuevos del grupo en la
   ventana ≥N h **posterior al release del fix**, con el sha del release.
   «0 eventos en 3h30m» (patrón real TAL-4725), nunca adjetivos.
9. **Superficie sensible** (commerce/pagos · auth/RLS · migraciones ·
   LLM/costes · seguridad · credenciales) — determina si va SOLO (fuera de
   tren) y si exige GO del lead.

## Labels e IDs (Linear, regla 21)

- **Initiative**: `Producto Ejemplo` (`00000000-0000-4000-8000-000000000005`).
- **Project**: por afinidad (ejemplo: `Lanzamiento del Producto` / `Producto
  MVP` `<uuid-adjudicado>`).
- **Labels**: `vertical/academy` (obligatorio) + `kind:fix`|`kind:chore`|`kind:spike`
  (los tres tipos que `crear_issue_desde_sentry.py` puede emitir, vía
  `KIND_POR_TIPO`) + `actor/ai` + `sev:` (`sev:capital`/`sev:bloqueante`/`sev:degradado`/
  `sev:cosmetico` — familia del contrato). `area:*` **debe verificarse en la instancia** (`area:payments`
  `<uuid-adjudicado>`, `area:db` `<uuid-adjudicado>`, `area:auth` `<uuid-adjudicado>`, `area:ops`
  `<uuid-adjudicado>`, `area:portal` `<uuid-adjudicado>`, `area:performance` `<uuid-adjudicado>`)
  aunque `linear-skill` lo declare `out_of_contract`; **la mayoría están
  duplicados ABC/BUG → elegir el UUID del team de la issue, nunca uno
  arbitrario**. **No existe** `kind:security`. `actor:needs-review` va con
  **DOS PUNTOS** (CLAUDE.md regla 6 lo escribe con barra — divergencia real).
- **IDs de ejemplo, sintéticos** (adjudicar los reales en la configuración de la instancia): team ABC
  `00000000-0000-4000-8000-000000000002` · `In Progress`
  `00000000-0000-4000-8000-000000000003` · `In Review`
  `00000000-0000-4000-8000-000000000006` · project `Producto MVP`
  `<uuid-adjudicado>`. `Backlog`/`Todo`/`Triage`/`Done` **no tienen UUID fiable** →
  resolver en vivo con `team(id){states{nodes{id name type}}}`.

## Peculiaridades de la API de Linear (el skill las trae)

- La API key personal va **sin** `Bearer` en `Authorization`.
- `issueCreate`/`commentCreate` **NO son idempotentes → jamás envolverlas en
  retry-with-backoff** (duplicaría issues).
- El rate limit devuelve **HTTP 400** con `extensions.code === "RATELIMITED"`;
  `searchIssues` capado a **30 req/min**.

## Dedupe ANTES de crear (obligatorio, fail-closed)

1. Buscar en Linear por el `shortId` y por el título normalizado
   (`issues(filter:{searchableContent:{contains:…}})`).
2. Cruzar contra el set del ciclo (`KNOWN-BENIGN`/`WATCH`/issues en vuelo del
   expediente, `03-…`).
3. Si existe → **comentar el delta** (conteo/ventana/release) y **PARAR**;
   añadir tag `linear:ABC-N` en el grupo Sentry. Cero issue nueva.

**Precedente vivo**: TAL-5102 nació duplicada de TAL-5101 por saltarse el
paso (1). El dedupe no es opcional. Riesgo residual conocido (dedupe→create no
es atómico; mitigado por diseño serial de una sola torre) — documentado, no
fingido resuelto (gotcha #11 del SKILL).

## E/D/5A y cierre (B5) — lo hace `verificar_cese.py`

1. Watcher de release: pollea `railway status --json` / el `release` en Sentry
   hasta que el sha del fix esté LIVE. Si el deploy queda en `NEEDS_APPROVAL`,
   se canta al CEO — **no se aprueba**.
2. Con el release vivo, cuenta eventos NUEVOS del grupo en la ventana declarada
   y sella `SENTRY-VERIFICA-<KEY>-OK` con la **cifra**, o `-CONSULTA` si no
   cesó.
3. El Vigía NO cierra la issue: Linear pasa a Done por `closes ABC-N` del PR.
4. `resolver_ficha.py` verifica en esta corrida: PR fundido a main con
   `closes <CLAVE-N>` y descripción de esa issue de Linear que cita el
   shortId exacto; release del merge LIVE en Sentry, sin estado conocido
   de Railway contrario al éxito; sello previo `SENTRY-VERIFICA-<CLAVE-N>-OK`
   con release exacto y cifra cero. Reaplica ventana transcurrida, conteo
   sin paginación capada y filtro start/end comprobado por conducta.
5. Sin `--apply`, imprime `RESOLVERÍA`, sin PUT ni sello. Con `--apply`,
   header-file `SENTRY_HDR_RESOLVER` 0600 distinto del de lectura, un único
   PUT `{"status":"resolved"}` y sello `VIGIA-RESUELTA-<shortId>-<sha7>`
   mediante `bus-sellar.sh --rol`. Un fallo del PUT no reintenta ni sella.
   Si ya estaba resuelta, no hace PUT; rc 3 del sello repetido es ya sellado.
   Si el sellador falla después del PUT, comunica fallo: volver a ejecutar
   exige las mismas pruebas y permite completar el sello sin otro PUT.

Defaults vigentes: sha7 del commit de fusión en main; pruebas 1 y 2 leídas
de fuentes primarias y copiadas en la nota, prueba 3 además registrada en
el bus; cuerpo sin statusDetails; token de escritura emitido por el CEO
en el ensayo. Nunca ignora, comenta en Sentry ni cierra issues de Linear.

## Default-deny (cero decisiones abiertas sin régimen)

Si una decisión no se puede sellar Y no hay un default seguro con
dueño+disparador, NO se crea la issue: se enruta a `spike-auditoria` (si hay
algo que investigar) o se sella `SENTRY-CONSULTA-<X>`. La tabla de decisiones
diferidas del borrador NUNCA lleva un `¿Bloquea? = SÍ`: si algo bloquea de
verdad, la issue no se crea todavía.
