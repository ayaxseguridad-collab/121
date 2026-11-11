#!/usr/bin/env python3
"""crear_issue_desde_sentry.py — monta el body issue-craft de un grupo Sentry
y (con --apply) crea la issue en Linear. TAL-5157 §B4/§B7.

DISEÑO (decisión CEO, opción B): un grupo Sentry recién observado NO tiene
causa raíz probada — una herramienta no puede auto-fabricarla. Por eso el
generador NO produce un body plano inventado: COPIA la plantilla real de
`talent-issue-craft` para el tipo pedido (default `spike-auditoria`, "para
un grupo sin causa clara" — B4), rellena TODO lo que es objetivamente
derivable de Sentry (shortId, permalink, release, ventana, volumen, culprit),
y donde el campo exige JUICIO HUMANO (preguntas del barrido a investigar,
decisiones selladas, hipótesis de causa/hallazgos) inserta un marcador
`JUICIO-OPERADOR` VISIBLE que además reutiliza el token de residuo
`` `<sha>` `` del gate `audit-issue` (chequeo B6-sin-residuo): si el operador
lo deja tal cual, el gate REVIENTA mecánicamente — no es un placeholder
plausible que pueda colarse. Ver SKILL.md §"Por qué ciertos campos quedan
sin rellenar" para la razón de frontera.

CONTRATO DE SEGURIDAD:
  * `--dry-run` es el DEFAULT: sin `--apply` NO crea nada.
  * Gate fail-closed ANTES de crear: `issue_craft_helper.ts --action audit-issue
    --min-score 70` debe salir 0.
  * Dedupe fail-closed ANTES de crear: si existe una issue por shortId o título
    normalizado → NO crea, imprime el delta y para.
  * `issueCreate`/`commentCreate` NO son idempotentes → JAMÁS retry-with-backoff
    (duplicaría issues). La API key va sin `Bearer`.
  * Ningún token en argv/logs. Solo LECTURA de Sentry.

Los 9 campos del body y las labels/IDs viven en references/04-contrato-de-issue.md.
El Vigía triagea ANTES (sentry_triage + references/02) y pasa aquí el --tipo/--variant.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# scripts/ -> talent-sentry-guard/ -> skills/ (la carpeta de skills es la misma en el paquete,
# `<raíz>/skills/`, y en una instalación, `<repo>/.claude/skills/`): las rutas de issue-craft
# cuelgan de ella, nunca de un `.claude/` supuesto (C9). Si no existen, die() nombra la ruta.
SKILL_DIR = Path(__file__).resolve().parents[1]
SKILLS_DIR = SKILL_DIR.parent
ISSUE_CRAFT_DIR = SKILLS_DIR / "talent-issue-craft"
TEMPLATES_DIR = ISSUE_CRAFT_DIR / "templates"
AUDIT_HELPER = ISSUE_CRAFT_DIR / "scripts/issue_craft_helper.ts"
# Raíz desde la que se leen las rutas del cuerpo generado: el repo (si la skill vive en
# `.claude/skills/`) o la raíz del paquete (si vive en `skills/`).
REPO_ROOT = SKILLS_DIR.parent.parent if SKILLS_DIR.parent.name == ".claude" else SKILLS_DIR.parent
# tsx SIEMPRE por el envoltorio (versión exacta del lock, >= 72 h de edad); jamás tsx a secas por npx (issue 9564).
TSX_SH = REPO_ROOT / "scripts/tsx.sh"


def ruta_skill(relativa: str) -> str:
    """Ruta de un fichero de ESTA skill relativa a REPO_ROOT, para los comandos del cuerpo."""
    return (SKILL_DIR / relativa).relative_to(REPO_ROOT).as_posix()


TEMPLATE_FILES = {
    "spike-auditoria": TEMPLATES_DIR / "08-spike-auditoria.md",
    "fix": TEMPLATES_DIR / "02-fix.md",
    "chore": TEMPLATES_DIR / "04-chore.md",
}

# Matriz sellada REAL (issue_craft_helper.ts TYPE_MATRIX) — el tipo "spike"
# con variant "auditoria" NO EXISTE; el token único es "spike-auditoria"/"none".
TYPE_MATRIX: dict[str, set[str]] = {
    "fix": {"none", "seguridad", "sev1", "seguridad+sev1"},
    "chore": {"none", "doc-vivo"},
    "spike-auditoria": {"none"},
}

# kind:* por --tipo (T07, revisor #2165, hallazgos [1]/[5]). DEBE cubrir cada
# clave de TYPE_MATRIX — crear_en_linear() muere si `tipo` no está aquí, en
# vez de crear la issue SIN kind:* (el defecto real: antes `.get(tipo)`
# devolvía None en silencio para un tipo no mapeado, y el `if kind else []`
# de más abajo lo trataba como "no hace falta kind", no como "invariante
# roto"). Amplía este dict ANTES de amplíar TYPE_MATRIX con un tipo nuevo.
KIND_POR_TIPO: dict[str, str] = {
    "fix": "kind:fix",
    "chore": "kind:chore",
    "spike-auditoria": "kind:spike",
}

# statsPeriod para el comando de inventario SUGERIDO en el body (T07, revisor
# #2165, hallazgo [3]). NO reutiliza `--ventana` (criterio de cierre E/D/5A,
# default "3h" — un parámetro semánticamente distinto): sentry_triage.py solo
# acepta "24h"/"14d" (STATS_PERIOD_CONTRATO, sentry_triage.py:143) y rechaza
# cualquier otro valor con die(). Antes, `construir_body_spike` embebía
# `--since {ventana}` — con el default real ("3h"), el comando que el propio
# body le decía al lector que corriera MORÍA al ejecutarse.
INVENTARIO_STATS_PERIOD = "24h"

# Token de residuo del gate audit-issue (B6-sin-residuo, PLACEHOLDER_RESIDUE en
# issue_craft_helper.ts). Reutilizado a propósito como marcador de juicio: si
# sobrevive en el body final, el gate falla SIEMPRE — no depende de que este
# script adivine bien qué cuenta como "contenido real".
RESIDUO_GATE = "`<sha>`"

# Marcador de IDENTIDAD (BLOQ2 TAL-5157). El generador lo emite con el shortId/release/
# tipo consultados; con --body-file, main() RECHAZA fail-closed si no casa con los
# argumentos de la invocación. Cierra la brecha: un body VÁLIDO de OTRO grupo (que pasa
# audit-issue, porque audit valida ESTRUCTURA, no coherencia) NO puede deduplicar ni crear
# con los datos de este grupo. release/short_id/tipo no llevan espacios → key=value simple.
IDENTITY_MARKER_RE = re.compile(r"<!--\s*sentry-guard-identity\s+(.*?)\s*-->")


def identity_marker(short_id: str, release: str, tipo: str) -> str:
    return f"<!-- sentry-guard-identity short_id={short_id} release={release} type={tipo} -->"


def parse_identity(body: str) -> dict | None:
    """Extrae el marcador de identidad del body (o None si ausente)."""
    m = IDENTITY_MARKER_RE.search(body)
    if not m:
        return None
    ident: dict = {}
    for tok in m.group(1).split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            ident[k] = v
    return ident


def enforce_identity(body: str, short_id: str, release: str, tipo: str) -> None:
    """VINCULACIÓN DE IDENTIDAD (BLOQ2 TAL-5157). Fail-closed: si el body reutilizado
    (--body-file) no lleva marcador, o su short_id/release/tipo no casan con los argumentos
    con los que se consulta Sentry / se deduplica / se crea, ABORTA. Sin esto, un body válido
    de OTRO grupo pasaría audit-issue (que valida ESTRUCTURA, no coherencia) y crearía o
    eludiría el dedupe con datos cruzados. Función aislada: el harness la muta para acreditar
    que el guard es load-bearing."""
    ident = parse_identity(body)
    if ident is None:
        die("--body-file sin marcador sentry-guard-identity: no puedo acreditar que el body "
            "corresponde a --short-id/--release/--tipo. Regenera con --dry-run (que ya lo "
            "incluye) y edítalo. Rechazado fail-closed (BLOQ2 TAL-5157).")
    desajustes = []
    if ident.get("short_id") != short_id:
        desajustes.append(f"short_id: body={ident.get('short_id')!r} != --short-id={short_id!r}")
    if ident.get("release") != release:
        desajustes.append(f"release: body={ident.get('release')!r} != --release-vivo={release!r}")
    if ident.get("type") != tipo:
        desajustes.append(f"type: body={ident.get('type')!r} != --tipo={tipo!r}")
    if desajustes:
        die("--body-file NO corresponde a la invocación (identidad cruzada) — se rechaza para "
            "no crear/deduplicar con datos de otro grupo: " + "; ".join(desajustes)
            + " (BLOQ2 TAL-5157).")


def die(msg: str, code: int = 1) -> None:
    print(f"crear_issue: {msg}", file=sys.stderr)
    sys.exit(code)


def clave_team() -> str:
    """Clave del team Linear de la INSTANCIA (TAL-8037): jamás un default de casa. FAIL-CLOSED: env
    TF_LINEAR_TEAM_KEY → línea TF_LINEAR_TEAM_KEY= del manifiesto TF_MANIFEST (ruta absoluta, leída como
    DATO, sin ejecutarla) → die() nombrando la variable. Formato ^[A-Z][A-Z0-9]{0,9}$ (también el del env)."""
    key = os.environ.get("TF_LINEAR_TEAM_KEY", "").strip()
    if not key:
        mf = os.environ.get("TF_MANIFEST", "").strip()
        if mf:
            if not mf.startswith("/"):
                die(f"TF_MANIFEST debe ser ruta ABSOLUTA ({mf})")
            p = Path(mf)
            if p.is_file():
                for ln in p.read_text().splitlines():
                    m = re.match(r'^TF_LINEAR_TEAM_KEY=(?:"([^"]*)"|([^\s"#]*))', ln)
                    if m:
                        key = (m.group(1) if m.group(1) is not None else m.group(2)).strip()
    if not key:
        die("TF_LINEAR_TEAM_KEY sin resolver: ni la variable de entorno ni la línea TF_LINEAR_TEAM_KEY= "
            "del manifiesto (TF_MANIFEST) — fail-closed, jamás se asume una clave")
    if not re.fullmatch(r"[A-Z][A-Z0-9]{0,9}", key):
        die(f"TF_LINEAR_TEAM_KEY inválida ('{key}'): se espera ^[A-Z][A-Z0-9]{{0,9}}$")
    return key


def env_requerido(nombre: str) -> str:
    val = os.environ.get(nombre, "").strip()
    if not val:
        die(f"config ausente: {nombre} obligatorio por entorno")
    return val


def leer_authorization(hdr_path: Path) -> str:
    if not hdr_path.is_file():
        die(f"header-file ausente: {hdr_path}")
    if oct(hdr_path.stat().st_mode & 0o777) != "0o600":
        die(f"header-file con permisos inseguros (se exige 0o600): {hdr_path}")
    lineas = [ln for ln in hdr_path.read_text().splitlines() if ln.strip()]
    if len(lineas) != 1 or not lineas[0].startswith("Authorization: "):
        die("header-file con contenido inesperado (una línea 'Authorization: <valor>')")
    return lineas[0][len("Authorization: "):]


def fetch_grupo_sentry(org: str, short_id: str, authorization: str) -> dict:
    """Grupo Sentry por shortId (read-only). Sin retry infinito; falla claro.

    Hallazgo del texto CR-CLI (corridas 2 y 3), medido y confirmado real:
    MISMO bug ya cerrado en `verificar_cese.py::resolver_issue_id` (hallazgo
    8, ronda 1 de este bounce) pero presente sin corregir en este fichero
    HERMANO — dos claves `query=` en la misma query string
    (`is:unresolved` + `short_id`), construcción rota, cuál gana no está
    verificado. `shortIdLookup=1` es búsqueda EXACTA por shortId; no se
    combina con filtro de estado por la misma razón que en `verificar_cese`
    (el grupo puede necesitar encontrarse aunque ya esté resuelto)."""
    url = (f"https://sentry.io/api/0/organizations/{urllib.parse.quote(org, safe='')}/issues/"
           f"?shortIdLookup=1&query={urllib.parse.quote(short_id, safe='')}")
    req = urllib.request.Request(url)
    req.add_header("Authorization", authorization)
    req.add_header("User-Agent", "talent-sentry-guard-crear/1")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        die(f"sentry: HTTP {e.code}")
    except (urllib.error.URLError, TimeoutError) as e:
        die(f"sentry: inalcanzable ({e})")
    grupos = [g for g in data if g.get("shortId") == short_id] if isinstance(data, list) else []
    if not grupos:
        die(f"sentry: no encontré el grupo shortId={short_id}")
    return grupos[0]


def marcador(tipo: str, variant: str) -> str:
    if tipo not in TYPE_MATRIX:
        die(f"type={tipo} no está en la matriz sellada (válidos: {sorted(TYPE_MATRIX)})")
    if variant not in TYPE_MATRIX[tipo]:
        die(f"combinación type={tipo} variant={variant} inválida (variantes válidas: {sorted(TYPE_MATRIX[tipo])})")
    return f"<!-- issue-craft:v1 type={tipo} variant={variant} madurez=despachable -->"


def juicio(etiqueta: str) -> str:
    """Marcador VISIBLE de campo de juicio humano. Lleva el token de residuo
    del gate: si el operador lo deja tal cual, `audit-issue` falla en B6."""
    return (
        f"⚠ JUICIO-OPERADOR [{etiqueta}] — el generador no puede fabricar esto "
        f"con juicio humano; completar antes de --apply {RESIDUO_GATE}"
    )


def sub1(texto: str, viejo: str, nuevo: str, etiqueta: str) -> str:
    """Reemplaza EXACTAMENTE una aparición. Si la plantilla cambió y el
    conteo no es 1, falla fuerte — nunca produce un body silenciosamente mal
    formado (las plantillas de talent-issue-craft son de OTRO skill, fuera de
    este alcance; su deriva se detecta, no se absorbe en silencio)."""
    n = texto.count(viejo)
    if n != 1:
        die(
            f"la plantilla cambió: {n} apariciones de {etiqueta!r} (se esperaba "
            f"exactamente 1) — construir_body necesita revisión manual"
        )
    return texto.replace(viejo, nuevo, 1)


def cargar_plantilla(tipo: str) -> str:
    """Copia el cuerpo de la plantilla real de talent-issue-craft, sin su
    marcador propio (ponemos el nuestro) ni los 2 comentarios de autoría de
    plantilla (líneas 2-3), ni el bloque EJEMPLO GOLD final (guía de autoría,
    no contenido de issue)."""
    ruta = TEMPLATE_FILES.get(tipo)
    if ruta is None or not ruta.is_file():
        die(f"plantilla ausente para type={tipo}: {ruta}")
    lineas = ruta.read_text().split("\n")
    if len(lineas) < 4 or not lineas[0].startswith("<!-- issue-craft:v1"):
        die(f"plantilla {ruta} no tiene la forma esperada (marcador en línea 1)")
    if not (lineas[1].startswith("<!-- Plantilla") and lineas[2].startswith("<!-- Defaults del tracker")):
        die(f"plantilla {ruta}: las líneas 2-3 no son los comentarios de autoría esperados — revisar cargar_plantilla")
    cuerpo = "\n".join(lineas[3:])
    idx = cuerpo.find("<!-- EJEMPLO GOLD CONDENSADO")
    if idx == -1:
        die(f"plantilla {ruta} no trae el bloque EJEMPLO GOLD CONDENSADO esperado — revisar")
    return cuerpo[:idx].rstrip() + "\n"


def resolver_baseline_sha() -> str:
    """Best-effort: HEAD corto del repo (dato real de redacción, no de Sentry).
    Si no se puede resolver, el propio caller decide el fallback JUICIO."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--short=8", "HEAD"],
            cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def campos_sentry(g: dict) -> dict:
    """Todo lo objetivamente derivable del grupo Sentry — sin juicio."""
    first_release = ((g.get("firstRelease") or {}).get("version")) or "(sin release asociado en Sentry)"
    return {
        "titulo": g.get("title") or "(sin título)",
        "short_id": g.get("shortId") or "?",
        "permalink": g.get("permalink") or "?",
        "culprit": g.get("culprit") or "(sin culprit — ver stack en el permalink)",
        "count": g.get("count", "?"),
        "user_count": g.get("userCount", "?"),
        "first_seen": g.get("firstSeen") or "?",
        "last_seen": g.get("lastSeen") or "?",
        "first_release": first_release,
    }


def bloque_datos_sentry(c: dict, release_vivo: str, ventana: str) -> str:
    """Sección fija, la MISMA para los 3 tipos: cubre los campos 1-3 del
    contrato (references/04) que SÍ son derivables de la API de Sentry."""
    return (
        "## Datos del grupo Sentry (auto-generado por crear_issue_desde_sentry.py)\n\n"
        f"- shortId: `{c['short_id']}` · permalink: {c['permalink']}\n"
        f"- fingerprint efectivo: revisar `src/lib/sentry-fingerprint.ts` si el culprit coincide con una regla registrada\n"
        f"- primera release donde apareció: `{c['first_release']}` · release vivo al redactar: `{release_vivo}`\n"
        f"- firstSeen: `{c['first_seen']}` · lastSeen: `{c['last_seen']}` (ISO Z — convertir a CDMX al redactar)\n"
        f"- count: `{c['count']}` · userCount: `{c['user_count']}`\n"
        f"- culprit/transaction: `{c['culprit']}`\n"
        f"- criterio de cierre E/D/5A: 0 eventos nuevos del grupo en `{ventana}` posteriores al release "
        "del fix, cifra exacta vía `verificar_cese.py` — nunca adjetivos\n"
    )


def construir_body_spike(g: dict, release_vivo: str, ventana: str, hoy: str, sha: str) -> str:
    c = campos_sentry(g)
    j_preguntas = juicio("preguntas-del-barrido")
    j_decision = juicio("decisiones-selladas")
    j_causa = juicio("causa/hallazgos")

    cuerpo = cargar_plantilla("spike-auditoria")
    cuerpo = sub1(
        cuerpo,
        "# {Auditar/Investigar} {qué superficie o pregunta} ({dónde})",
        f"# Investigar {c['titulo']} (Sentry {c['short_id']})",
        "título",
    )
    cuerpo = sub1(
        cuerpo,
        "[2-4 frases: qué incertidumbre o riesgo motiva el barrido, quién consumirá los hallazgos, qué fase o decisión desbloquea.]",
        f"Grupo Sentry sin bucket conocido (o con conteo/impacto que rompe su baseline): "
        f"count={c['count']}, userCount={c['user_count']}. Consumen el hallazgo el Vigía "
        "(clasificación futura en `references/03-buckets-y-baselines.md`) y quien redacte el fix/chore hijo.",
        "contexto",
    )
    cuerpo = sub1(
        cuerpo,
        "**Origen**: [link adjunto — incidente / hallazgo de revisión / decisión con fecha. El detalle de la decisión vive AQUÍ.]",
        f"**Origen**: grupo Sentry `{c['short_id']}` — {c['permalink']}",
        "origen",
    )
    cuerpo = sub1(cuerpo, "## Baseline verificado (AAAA-MM-DD)", f"## Baseline verificado ({hoy})", "fecha baseline")
    cuerpo = sub1(
        cuerpo, "- Rama/commit de referencia: `<sha>`",
        f"- Rama/commit de referencia: `{sha}`" if sha else f"- Rama/commit de referencia: {juicio('baseline-repo')}",
        "sha baseline",
    )
    cuerpo = sub1(
        cuerpo,
        "  - `[comando que demuestra el estado actual de la superficie]` → [salida esperada]",
        f"  - `bash {ruta_skill('scripts/sentry_doctor.sh')} --solo-fuentes` "
        f"(o abrir el permalink) → grupo `{c['short_id']}` activo, count={c['count']}, userCount={c['user_count']}",
        "arranque verificado",
    )
    cuerpo = sub1(
        cuerpo,
        "  - `[comando de estado limpio del árbol]` → [vacío — contra esto se mide la frontera diff-cero]",
        "  - `git status --porcelain` → vacío — contra esto se mide la frontera diff-cero",
        "estado limpio",
    )
    cuerpo = sub1(
        cuerpo,
        "- `[ruta/del/area-a-auditar]` — [qué es] (extracto mínimo abajo)\n  > [3-8 líneas literales]",
        f"- `{c['culprit']}` — área señalada por el culprit de Sentry (extracto mínimo abajo)\n  > {j_causa}",
        "anclas",
    )
    cuerpo = sub1(
        cuerpo,
        "- `[ruta/de/reporte-de-spike-previo]` — el formato de entregable a REPLICAR, si existe",
        "- (sin spike previo citado — si el dedupe de Linear encuentra uno, enlazarlo aquí antes de redactar)",
        "ancla reporte previo",
    )
    cuerpo = sub1(
        cuerpo,
        "- ❌ [superficie vecina excluida] → [issue destino]",
        "- ❌ Ninguna exclusión adicional declarada — solo la frontera diff-cero de arriba",
        "fuera de alcance",
    )
    cuerpo = sub1(
        cuerpo,
        "| Umbral de severidad que amerita issue hija | [p. ej. 🔴 siempre; 🟡 solo si cabe en un vehículo ya abierto] | [persona] | [fecha] |",
        f"| Umbral de severidad que amerita issue hija | {j_decision} | — | — |",
        "decisión sellada 1",
    )
    cuerpo = sub1(
        cuerpo,
        "| Regla de agrupación de hallazgos | por VEHÍCULO de implementación: mismos archivos = misma issue | [persona] | [fecha] |",
        f"| Regla de agrupación de hallazgos | por VEHÍCULO de implementación: mismos archivos = misma issue | {j_decision} | {j_decision} |",
        "decisión sellada 2",
    )
    cuerpo = sub1(
        cuerpo,
        "| Prioridad de remediación de las hijas | [responsable] | al leer el reporte | No | las hijas nacen sin prioridad final |",
        "| Prioridad de remediación de las hijas | quien lea el reporte | al leer el reporte | No | las hijas nacen sin prioridad final |",
        "decisión diferida",
    )
    cuerpo = sub1(
        cuerpo,
        "([comentario del tracker | `ruta/del/reporte.md` si el perfil aloja reportes en el árbol])",
        "(comentario en la propia issue Linear — este skill no aloja reportes en el árbol)",
        "artefactos",
    )
    cuerpo = sub1(
        cuerpo,
        "- TODO el árbol de trabajo (el barrido es de solo lectura) — lo prueba: `[comando de estado del árbol]` → vacío al entregar",
        "- TODO el árbol de trabajo (el barrido es de solo lectura) — lo prueba: `git status --porcelain` → vacío al entregar",
        "invariante árbol",
    )
    cuerpo = sub1(
        cuerpo,
        "- Entornos reales intocados: si el barrido ejecuta algo, SOLO lecturas idempotentes [contra el entorno que el perfil permita]",
        "- Entornos reales intocados: si el barrido ejecuta algo, SOLO lecturas idempotentes contra Sentry/Supabase/Railway (mismo contrato de `sentry_doctor.sh`)",
        "invariante entornos",
    )
    cuerpo = sub1(
        cuerpo,
        "- [pieza ya verificada] — evidencia: [issue/PR/reporte previo con fecha]",
        f"- {j_causa} — evidencia: (issue/PR/reporte previo si el dedupe de Linear encuentra uno)",
        "baseline confirmado",
    )
    cuerpo = sub1(
        cuerpo,
        "- [comportamiento que parece defecto pero es decisión registrada] — registrado en: [link a la decisión]",
        f"- {j_causa} — registrado en: (revisar `references/06-gotchas.md` antes de reportar como hallazgo nuevo)",
        "baseline no-hallazgo",
    )
    cuerpo = sub1(
        cuerpo,
        "Inventario DINÁMICO por comando — nunca conteos fijos: `[comando find/grep que enumera las unidades a auditar]` → ≈N unidades al planificar; re-correr al arrancar y auditar la lista VIVA.",
        "Inventario DINÁMICO por comando — nunca conteos fijos: "
        f"`python3 {ruta_skill('scripts/sentry_triage.py')} --since {INVENTARIO_STATS_PERIOD} --json` "
        f"→ el grupo `{c['short_id']}` y sus vecinos SIN-CLASIF al planificar; re-correr al arrancar.",
        "inventario dinámico",
    )
    cuerpo = sub1(cuerpo, "1. [Pregunta 1 — cerrada y verificable sobre CADA unidad del inventario]", f"1. {j_preguntas}", "pregunta 1")
    cuerpo = sub1(cuerpo, "2. [Pregunta 2]", f"2. {j_preguntas}", "pregunta 2")
    cuerpo = sub1(
        cuerpo, "3. [Pregunta 3 — cada respuesta con evidencia path:línea o salida de comando]",
        f"3. {j_preguntas}", "pregunta 3",
    )
    cuerpo = sub1(
        cuerpo,
        "- [ ] Las [N] preguntas del barrido respondidas con evidencia (path:línea o salida de comando por respuesta)",
        "- [ ] Las 3 preguntas del barrido respondidas con evidencia (path:línea o salida de comando por respuesta)",
        "DoD preguntas",
    )
    cuerpo = sub1(
        cuerpo,
        "- [ ] Diff-cero verificado literalmente: `[comando de estado del árbol]` → [vacío / solo el reporte]",
        "- [ ] Diff-cero verificado literalmente: `git status --porcelain` → vacío / solo el reporte",
        "DoD diff-cero",
    )
    cuerpo = sub1(
        cuerpo,
        "- Conocimiento previo a cargar: [guías del repo sobre la superficie auditada + reporte de spike previo si existe]",
        f"- Conocimiento previo a cargar: `{ruta_skill('references/02-taxonomia-triage.md')}` "
        "+ `06-gotchas.md` + reporte de spike previo del mismo bucket si el dedupe lo encontró",
        "brief conocimiento",
    )
    cuerpo = sub1(
        cuerpo,
        "- Patrón a REPLICAR: [formato del reporte previo] (prohibido inventar formato nuevo)",
        "- Patrón a REPLICAR: la sección \"Formato del entregable\" de esta misma issue (prohibido inventar formato nuevo)",
        "brief patrón",
    )
    cuerpo = sub1(
        cuerpo, "  Destinatario de la escalada: [el declarado en el perfil del repo].",
        "  Destinatario de la escalada: el CEO/lead vía comentario en esta misma issue Linear.",
        "brief escalada",
    )
    cuerpo = sub1(
        cuerpo, '- Checks adicionales de ESTA issue: [lista o "ninguno"]',
        "- Checks adicionales de ESTA issue: ninguno", "checks adicionales",
    )
    cuerpo = sub1(
        cuerpo,
        "- Checks requeridos: [el de estado limpio del árbol — no hay build: no hay diff de código]",
        "- Checks requeridos: `git status --porcelain` limpio al entregar — no hay build, no hay diff de código",
        "checks requeridos",
    )
    cuerpo = sub1(
        cuerpo,
        "- Post-cierre: la priorización de las issues hijas queda con [responsable] (decisión diferida, no bloquea)",
        "- Post-cierre: la priorización de las issues hijas queda con quien lea el reporte (decisión diferida, no bloquea)",
        "post-cierre",
    )

    datos = bloque_datos_sentry(c, release_vivo, ventana)
    cuerpo = sub1(cuerpo, "## Contexto y origen", f"{datos}\n## Contexto y origen", "inserción datos Sentry")
    return cuerpo


def construir_body_fix(g: dict, variant: str, release_vivo: str, ventana: str, hoy: str, sha: str) -> str:
    c = campos_sentry(g)
    j = juicio("causa/hallazgos")
    j_dec = juicio("decisiones-selladas")

    cuerpo = cargar_plantilla("fix")
    cuerpo = sub1(cuerpo, "# {Imperativo} {qué} ({dónde})", f"# Corregir {c['titulo']} (Sentry {c['short_id']})", "título")
    cuerpo = sub1(
        cuerpo,
        "[2-4 frases: qué defecto se corrige, a quién le duele hoy, qué valor entrega cerrarlo.]",
        f"Grupo Sentry `{c['short_id']}` con count={c['count']}, userCount={c['user_count']}. {j}",
        "contexto",
    )
    cuerpo = sub1(
        cuerpo,
        "**Origen**: [link adjunto — reporte de usuario / hallazgo de revisión / alerta de monitoreo, con fecha. El detalle vive AQUÍ.]",
        f"**Origen**: grupo Sentry `{c['short_id']}` — {c['permalink']}",
        "origen",
    )
    cuerpo = sub1(cuerpo, "## Baseline verificado (AAAA-MM-DD)", f"## Baseline verificado ({hoy})", "fecha baseline")
    cuerpo = sub1(
        cuerpo, "- Rama/commit de referencia: `<sha>`",
        f"- Rama/commit de referencia: `{sha}`" if sha else f"- Rama/commit de referencia: {juicio('baseline-repo')}",
        "sha baseline",
    )
    cuerpo = sub1(
        cuerpo,
        "| [p. ej. estrategia de corrección, ventana de despliegue] | [valor] | [persona] | [fecha] |",
        f"| estrategia de corrección | {j_dec} | — | — |",
        "decisión sellada",
    )
    cuerpo = sub1(
        cuerpo, "- **Observado**: [comportamiento real LITERAL — mensaje de error / salida / captura, con fecha; en sev1: timestamp exacto]",
        f"- **Observado**: `{c['titulo']}` (culprit: `{c['culprit']}`) — {c['count']} eventos, {c['user_count']} usuarios. {j}",
        "observado",
    )
    cuerpo = sub1(
        cuerpo, "- [mecánica exacta: qué línea/condición produce el síntoma y por qué]", f"- {j}", "causa raíz mecánica",
    )
    cuerpo = sub1(
        cuerpo, "- Prueba: [experimento que la confirma — alterar la condición cambia el síntoma de forma predecible]",
        f"- Prueba: {j}", "causa raíz prueba",
    )
    cuerpo = sub1(
        cuerpo, "- Fix propuesto: [cambio mínimo que elimina la causa raíz]", f"- Fix propuesto: {j}", "fix propuesto",
    )
    cuerpo = sub1(
        cuerpo, "- `[comando que enumera TODAS las instancias de la clase]` → [listado literal + conteo]",
        f"- {j} (comando + listado de todas las instancias de la clase)", "inventario clase",
    )

    datos = bloque_datos_sentry(c, release_vivo, ventana)
    cuerpo = sub1(cuerpo, "## Contexto y origen", f"{datos}\n## Contexto y origen", "inserción datos Sentry")
    return cuerpo


def construir_body_chore(g: dict, variant: str, release_vivo: str, ventana: str, hoy: str, sha: str) -> str:
    c = campos_sentry(g)
    j = juicio("causa/hallazgos")
    j_dec = juicio("decisiones-selladas")

    cuerpo = cargar_plantilla("chore")
    cuerpo = sub1(cuerpo, "# {Imperativo} {qué} ({dónde})", f"# Curar ruido: {c['titulo']} (Sentry {c['short_id']})", "título")
    cuerpo = sub1(
        cuerpo,
        "[2-4 frases: qué mantenimiento/infraestructura es, por qué ahora, qué destraba.]",
        f"Grupo Sentry `{c['short_id']}` clasificado como ruido (S4, `references/02-taxonomia-triage.md`). {j}",
        "contexto",
    )
    cuerpo = sub1(
        cuerpo,
        "**Origen**: [link adjunto — deuda registrada / cambio de entorno / decisión con fecha. El detalle vive AQUÍ.]",
        f"**Origen**: grupo Sentry `{c['short_id']}` — {c['permalink']}",
        "origen",
    )
    cuerpo = sub1(cuerpo, "## Baseline verificado (AAAA-MM-DD)", f"## Baseline verificado ({hoy})", "fecha baseline")
    cuerpo = sub1(
        cuerpo, "- Rama/commit de referencia: `<sha>`",
        f"- Rama/commit de referencia: `{sha}`" if sha else f"- Rama/commit de referencia: {juicio('baseline-repo')}",
        "sha baseline",
    )
    cuerpo = sub1(
        cuerpo,
        "  - `[comando que muestra el estado actual del artefacto]` → [salida esperada]",
        "  - `git status --porcelain` → vacío (estado limpio antes de empezar)",
        "arranque verificado",
    )
    cuerpo = sub1(
        cuerpo,
        "| [p. ej. versión objetivo, política elegida] | [valor] | [persona] | [fecha] |",
        f"| filtro de curación (gotcha #3: nunca `ignoreErrors`, siempre `beforeSend` con igualdad exacta) | {j_dec} | — | — |",
        "decisión sellada",
    )
    cuerpo = sub1(
        cuerpo, "- `[path:línea @ commit]` — extracto literal del estado actual que motiva el cambio:\n  > [2-6 líneas del artefacto tal como está HOY]",
        f"- {j} — extracto literal del estado actual que motiva el cambio:\n  > (pegar el bloque `beforeSend`/`instrumentation-client.ts` relevante)",
        "evidencia",
    )
    cuerpo = sub1(
        cuerpo,
        "- [números, no \"es mejor práctica\": minutos ahorrados por corrida, fallos/mes que desaparecen, pasos manuales eliminados, tamaño reducido]",
        f"- {j} (cuántos eventos/mes desaparecen del ruido — cifra, no adjetivo)",
        "beneficio",
    )
    cuerpo = sub1(
        cuerpo,
        "| `[ruta 1]` | [qué se cambia exactamente] |\n| `[ruta 2]` | [qué se cambia exactamente] |",
        f"| `src/sentry.server.config.ts` o `src/instrumentation-client.ts` | {j} |",
        "cambios por archivo",
    )

    datos = bloque_datos_sentry(c, release_vivo, ventana)
    cuerpo = sub1(cuerpo, "## Contexto y origen", f"{datos}\n## Contexto y origen", "inserción datos Sentry")
    return cuerpo


def construir_body(g: dict, tipo: str, variant: str, release_vivo: str, ventana: str) -> str:
    hoy = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    sha = resolver_baseline_sha()
    if tipo == "spike-auditoria":
        cuerpo = construir_body_spike(g, release_vivo, ventana, hoy, sha)
    elif tipo == "fix":
        cuerpo = construir_body_fix(g, variant, release_vivo, ventana, hoy, sha)
    elif tipo == "chore":
        cuerpo = construir_body_chore(g, variant, release_vivo, ventana, hoy, sha)
    else:
        die(f"type={tipo} sin generador de body implementado")
        raise  # unreachable
    # Identidad al FINAL (comentario HTML inerte para audit-issue; el operador edita los
    # campos JUICIO del medio, no esta línea). Si la borra → parse_identity None → die.
    ident = identity_marker(g.get("shortId") or "?", release_vivo, tipo)
    return f"{marcador(tipo, variant)}\n\n{cuerpo}\n\n{ident}\n"


def correr_audit(body_path: Path) -> subprocess.CompletedProcess:
    """Gate fail-closed: audit-issue --min-score 70 debe salir 0."""
    if not AUDIT_HELPER.is_file():
        die(f"gate audit-issue ausente: {AUDIT_HELPER}")
    if not TSX_SH.is_file():
        die(f"envoltorio de tsx ausente: {TSX_SH}")
    try:
        r = subprocess.run(
            ["bash", str(TSX_SH), str(AUDIT_HELPER), "--action", "audit-issue",
             "--file", str(body_path), "--min-score", "70"],
            cwd=str(AUDIT_HELPER.parent.parent), capture_output=True, text=True, timeout=120,
        )
    except FileNotFoundError:
        die("bash/npx no disponible — no puedo correr el gate audit-issue")
    except subprocess.TimeoutExpired:
        die("audit-issue excedió el timeout")
    print(r.stdout, file=sys.stderr)
    return r


def linear_gql(api_key: str, query: str, variables: dict | None = None, *, retry: bool) -> dict:
    """POST a la API de Linear. La key va SIN 'Bearer'. `retry` SOLO para
    lecturas — jamás para issueCreate/commentCreate (no son idempotentes)."""
    payload = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        "https://api.linear.app/graphql", data=payload,
        headers={"Authorization": api_key, "Content-Type": "application/json",
                 "User-Agent": "talent-sentry-guard-crear/1"},
        method="POST",
    )
    intentos = 3 if retry else 1
    ultimo = None
    for i in range(intentos):
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
            if "errors" in data:
                die(f"linear: errores GraphQL ({data['errors']})")
            return data["data"]
        except urllib.error.HTTPError as e:
            ultimo = e
            if not retry:
                die(f"linear: HTTP {e.code} (create NO se reintenta — no es idempotente)")
        except Exception as e:  # noqa: BLE001
            ultimo = e
            if not retry:
                die(f"linear: fallo de red en un create — NO se reintenta ({e})")
        import time as _t
        _t.sleep(2 * (i + 1))
    die(f"linear: lectura inalcanzable tras {intentos} intentos ({ultimo})")
    raise  # unreachable


# Tope duro de páginas por conexión (MENOR, T07 v6, hallazgo H4): un bug de
# paginación en cualquier lado (cursor que no avanza, servidor que repite
# hasNextPage=true) no debe colgar el proceso en un bucle sin fin — muere
# fail-closed señalando el propio tope. 20 páginas × 50 = 1000 nodos, muy
# por encima de cualquier team real hoy (78 labels / 9 states).
TOPE_PAGINAS_CONEXION = 20


def paginar_conexion_team(api_key: str, team_id: str, campo: str) -> dict:
    """Pagina una conexión `team.<campo>` (labels o states) completa por
    nombre→id, UNA conexión por request. Linear pagina las conexiones a 50
    por defecto (MAJOR, T07 v5, revisor #2165): leer solo la primera página
    deja fuera del mapa CUALQUIER nodo más allá de la 50 — el camino normal
    de un workspace real (medido en vivo: team TAL, 78 labels/2 páginas), no
    un caso de borde. Generalizado a CUALQUIER conexión del team, no solo
    `labels` (MENOR, T07 v6, hallazgo H3): `states` tiene la MISMA forma
    paginada y hoy tiene 9 filas (latente, sin disparar aún, misma clase).

    UNA conexión por request, nunca dos combinadas (MEDIDO en vivo, T07 v6):
    pedir `states` Y `labels` con `pageInfo` en la MISMA query midió
    complexity=12060 contra un tope de 10000 de la API real — "Query too
    complex", rc≠0. Cada conexión sola con `pageInfo` midió 6060; separarlas
    en requests independientes las deja con margen (~40%) en vez de justo en
    el borde de romperse otra vez cuando el team crezca un poco más.
    `after: null` en la primera llamada es idéntico a omitirlo (verificado
    en vivo) — mismo query para la página 1 y las siguientes, sin cebado
    aparte."""
    items: dict[str, str] = {}
    cursor: str | None = None
    paginas = 0
    while True:
        paginas += 1
        if paginas > TOPE_PAGINAS_CONEXION:
            die(f"linear: team.{campo} supera el tope de {TOPE_PAGINAS_CONEXION} páginas "
                f"sin agotar hasNextPage — probable bug de paginación (cursor que no avanza), "
                f"fail-closed en vez de bucle sin fin")
        d = linear_gql(api_key, f"""
          query($id:String!, $after:String){{ team(id:$id){{ {campo}(first:50, after:$after){{
            nodes{{ id name }} pageInfo{{ hasNextPage endCursor }} }} }} }}
        """, variables={"id": team_id, "after": cursor}, retry=True)
        pagina = d["team"][campo]
        items.update({n["name"]: n["id"] for n in pagina["nodes"]})
        if not pagina["pageInfo"].get("hasNextPage"):
            return items
        cursor = pagina["pageInfo"].get("endCursor")


def crear_en_linear(g: dict, body: str, tipo: str, sev_label: str | None, api_key: str) -> str:
    """issueCreate real — UNA sola llamada, SIN retry. Resuelve team/labels/state
    en vivo (nada de UUIDs hardcodeados que caducan). Devuelve el identifier."""
    clave = clave_team()   # TAL-8037: la clave del team es de la INSTANCIA (TF_LINEAR_TEAM_KEY), fail-closed
    d = linear_gql(api_key, """
      query($k:String!) { teams(filter:{key:{eq:$k}}){ nodes{ id name } } }
    """, variables={"k": clave}, retry=True)
    equipos = d.get("teams", {}).get("nodes", [])
    if not equipos:
        die(f"linear: no resolví el team {clave} en vivo")
    team_id = equipos[0]["id"]
    estados = paginar_conexion_team(api_key, team_id, "states")
    state_id = estados.get("Triage") or estados.get("Backlog") or estados.get("Todo")
    labels_por_nombre = paginar_conexion_team(api_key, team_id, "labels")
    # Resolución tipo→kind FAIL-CLOSED (T07, revisor #2165): `tipo` ya pasó por
    # TYPE_MATRIX en enforce_identity()/argparse, pero KIND_POR_TIPO es un
    # segundo mapa MANUAL — nada los mantiene sincronizados salvo revisión de
    # diff. Un tipo sin entrada aquí muere ANTES de tocar Linear, en vez de
    # crear la issue sin kind:* en silencio (el defecto real de antes).
    if tipo not in KIND_POR_TIPO:
        die(f"linear: tipo={tipo!r} sin kind:* en KIND_POR_TIPO — invariante roto, "
            f"añade la entrada antes de crear issues de este tipo (válidos: {sorted(KIND_POR_TIPO)})")
    kind = KIND_POR_TIPO[tipo]
    # OBLIGATORIAS: CLAUDE.md regla 21 exige vertical/* en toda issue; actor/ai
    # y kind:* son invariantes de diseño de ESTE script (siempre en TYPE_MATRIX).
    # Ausentes en vivo → NO se crea la issue (antes: solo aviso en stderr y
    # seguía adelante sin ellas — NO-GO #MAYOR-5, TAL-5157 r11). sev_label SÍ
    # es opcional por diseño (flag --sev-label default=None): queda best-effort.
    obligatorias = ["vertical/academy", "actor/ai", kind]
    faltantes = [n for n in obligatorias if n not in labels_por_nombre]
    if faltantes:
        die(f"linear: labels OBLIGATORIAS ausentes en vivo, no creo la issue sin ellas: {faltantes}")
    label_ids = [labels_por_nombre[n] for n in obligatorias]
    if sev_label:
        if sev_label in labels_por_nombre:
            label_ids.append(labels_por_nombre[sev_label])
        else:
            print(f"linear: aviso — sev-label {sev_label!r} no encontrada en vivo, omitida (opcional)", file=sys.stderr)

    mut = """
      mutation($t:String!,$team:String!,$desc:String!,$state:String,$labels:[String!]){
        issueCreate(input:{title:$t, teamId:$team, description:$desc, stateId:$state, labelIds:$labels}){
          success issue{ identifier url } } }
    """
    variables = {"t": g.get("title", "(sin título)")[:250], "team": team_id,
                 "desc": body, "state": state_id, "labels": label_ids}
    res = linear_gql(api_key, mut, variables, retry=False)  # SIN retry: no idempotente
    issue = res.get("issueCreate", {}).get("issue")
    if not res.get("issueCreate", {}).get("success") or not issue:
        die("linear: issueCreate no devolvió éxito")
    return f"{issue['identifier']} {issue['url']}"


def dedupe_linear(short_id: str, titulo: str, api_key: str) -> list[dict]:
    """Busca en Linear por shortId Y por título normalizado — dos búsquedas
    independientes, unidas por identifier (references/04:82-89). `short_id`
    es siempre truthy (arg required): un `q = short_id or titulo` NUNCA cae
    al título — NO-GO #MAYOR-4, TAL-5157 r11. Fail-closed: si cualquiera de
    las dos consultas falla, no se crea nada.

    CRITICAL (T07 v4, revisor #2165, hallazgo [8]): un cerrado (Done/Canceled)
    NO cuenta como duplicado — la consulta lo excluye por `state.type` (nin
    completed/canceled, no por `name`: los nombres de estado son
    personalizables por workspace, el `type` es el enum fijo de Linear). Sin
    esto, un incidente que se REPITE tras cerrarse la primera vez nunca
    vuelve a abrir issue: el dedupe lo confunde con el cierre anterior para
    siempre. Los DOS sentidos de esta ley son opuestos y NINGUNO cede al
    otro: un cerrado no bloquea la creación (se relaja AQUÍ), pero un fallo
    de la propia consulta SIGUE bloqueando la creación (fail-closed, sin
    cambio — ver los `die()` de abajo)."""
    query = {
        "query": "query($q:String!){ issues(filter:{searchableContent:{contains:$q}, "
        'state:{type:{nin:["completed","canceled"]}}}, first:10){ '
        "nodes{ identifier title state{name} } } }",
    }
    encontrados: dict[str, dict] = {}
    terminos = [t for t in (short_id, titulo.strip()) if t]
    for termino in terminos:
        req = urllib.request.Request(
            "https://api.linear.app/graphql",
            data=json.dumps({**query, "variables": {"q": termino}}).encode(),
            headers={"Authorization": api_key, "Content-Type": "application/json",
                     "User-Agent": "talent-sentry-guard-crear/1"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
        except Exception as e:  # fail-closed: si no puedo deduplicar, NO creo
            die(f"dedupe: no pude consultar Linear por {termino!r} ({e}) — fail-closed, no se crea nada")
        if "errors" in data:
            die(f"dedupe: Linear devolvió errores para {termino!r} ({data['errors']}) — fail-closed")
        for nodo in data.get("data", {}).get("issues", {}).get("nodes", []):
            encontrados[nodo["identifier"]] = nodo
    return list(encontrados.values())


def main() -> int:
    ap = argparse.ArgumentParser(description="Monta y (con --apply) crea la issue de un grupo Sentry.")
    ap.add_argument("--short-id", required=True, help="shortId del grupo Sentry (ACADEMIA-EJEMPLO-2-0-XX)")
    ap.add_argument("--tipo", default="spike-auditoria", choices=sorted(TYPE_MATRIX),
                    help="default spike-auditoria (B4: para un grupo sin causa clara)")
    ap.add_argument("--variant", default="none", help="según --tipo — ver TYPE_MATRIX")
    ap.add_argument("--release-vivo", required=True, help="<SENTRY_RELEASE_PREFIX>@<sha8> vivo AL REDACTAR (dato de redacción, no auto-derivable)")
    ap.add_argument("--ventana", default="3h", help="ventana E/D/5A del criterio de cierre")
    ap.add_argument("--sev-label", default=None, help="label sev:* exacta ya decidida por el Vigía (references/02) — opcional")
    ap.add_argument("--dry-run", action="store_true", default=True, help="(DEFAULT) no crea nada")
    ap.add_argument("--apply", dest="dry_run", action="store_false",
                    help="crea la issue de verdad (tras audit + dedupe limpios)")
    ap.add_argument(
        "--body-file", default=None,
        help="usa este body EN VEZ de generarlo — es el ciclo que promete SKILL.md "
             "(Quick Start #4): --dry-run genera el body con marcadores JUICIO-OPERADOR y "
             "conserva el temporal; el operador lo completa y re-invoca con "
             "--apply --body-file <ese temporal editado>. Sin esta opción, --apply "
             "regenera el body desde cero (marcadores incluidos) y el gate audit-issue "
             "vuelve a fallar siempre (NO-GO #2, TAL-5157 r11).",
    )
    args = ap.parse_args()

    if args.variant not in TYPE_MATRIX.get(args.tipo, set()):
        die(f"--variant {args.variant} inválida para --tipo {args.tipo} (válidas: {sorted(TYPE_MATRIX[args.tipo])})")

    org = env_requerido("SENTRY_ORG")
    hdr = Path(os.environ.get("SENTRY_HDR", str(Path.home() / ".vigia-sentry" / "hdr")))
    api_key = env_requerido("LINEAR_API_KEY")

    authorization = leer_authorization(hdr)
    g = fetch_grupo_sentry(org, args.short_id, authorization)
    if args.body_file:
        body_file_path = Path(args.body_file)
        if not body_file_path.is_file():
            die(f"--body-file no existe: {body_file_path}")
        body = body_file_path.read_text()
        if not body.strip():
            die(f"--body-file vacío: {body_file_path}")
        # VINCULACIÓN DE IDENTIDAD (BLOQ2 TAL-5157): el body reutilizado DEBE corresponder
        # al grupo/release/tipo con los que se consulta Sentry, se deduplica y se crea.
        enforce_identity(body, args.short_id, args.release_vivo, args.tipo)
    else:
        body = construir_body(g, args.tipo, args.variant, args.release_vivo, args.ventana)

    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
        body_path = Path(f.name)
    try:
        r = correr_audit(body_path)
    finally:
        if args.dry_run:
            print(f"(borrador del gate conservado para inspección: {body_path})", file=sys.stderr)
        else:
            body_path.unlink(missing_ok=True)
    if r.returncode != 0:
        die(f"audit-issue FALLÓ (exit {r.returncode}) — el body no es despachable; no se crea nada (esperado si quedan marcadores JUICIO-OPERADOR sin completar)")

    dups = dedupe_linear(args.short_id, g.get("title", ""), api_key)
    if dups:
        print("DEDUPE: ya existe issue para este grupo → NO se crea. Comentar el delta en:", file=sys.stderr)
        for d in dups:
            print(f"  {d['identifier']} [{d['state']['name']}] {d['title']}", file=sys.stderr)
        return 2

    if args.dry_run:
        print("=== DRY-RUN (default): body listo, audit OK, dedupe limpio. NO se creó nada. ===")
        print(body)
        print("\n(para crear de verdad: re-ejecutar con --apply)")
        return 0

    ident = crear_en_linear(g, body, args.tipo, args.sev_label, api_key)
    print(f"CREADA: {ident}")
    print("Recuerda: el Vigía NO cierra la issue (lo hace `closes TAL-N` del PR) "
          "ni marca Resolved en Sentry sin orden del CEO.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
