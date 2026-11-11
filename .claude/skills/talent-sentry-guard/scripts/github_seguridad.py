#!/usr/bin/env python3
"""github_seguridad.py — el Vigía vigila las alertas de seguridad de GitHub.

Barrido de SOLO LECTURA de cuatro superficies del repositorio declarado
(`GITHUB_SEC_REPO`): Dependabot, code scanning, secret scanning y advisories.
Clasifica cada alerta abierta con la escala S0-S4 de `references/02-taxonomia-triage.md`,
imprime NUEVOS / ESCALA contra un cursor propio (`~/.vigia-github/cursor.json`) y, con
`--crear-issue <superficie>:<id>`, monta el body issue-craft y (con `--apply`) crea la
issue en Linear reutilizando el dedupe fail-closed de `crear_issue_desde_sentry.py`.

Contrato de acceso (references/05): token por header-file 0600 (`GITHUB_SEC_HDR`), pasado a
`gh` por el ENTORNO del subproceso (`GH_TOKEN`), jamás en argv. Solo `gh api --method GET`:
ninguna escritura en GitHub (descartar, cerrar, comentar alertas) existe en este fichero.
Identidad del repo y superficies por ENTORNO, sin default de marca (invariante 25e).

Límites duros:
  * El valor de un `secret` de GitHub JAMÁS sale por stdout, stderr, body, sello ni log: la
    petición lleva `hide_secret=true`, el campo se descarta al leer y cualquier aparición
    se enmascara en toda la salida (defensa en profundidad).
  * Una superficie declarada que no responde con una lista (403/404, 401, red caída, JSON
    roto, tope de páginas) es un FALLO de la fuente (rc 3), jamás «0 alertas».
  * `issueCreate` no se reintenta nunca; si el dedupe no puede consultar Linear, no crea.

Códigos de salida: 0 ok · 1 config/uso/gate (die) · 2 dedupe: ya existe issue · 3 fallo de fuente.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

SUPERFICIES_VALIDAS = ("dependabot", "code-scanning", "secret-scanning", "advisories")

# superficie -> (ruta bajo /repos/{repo}/, query, prefijo del sello). `hide_secret=true` es OBLIGATORIO
# en secret scanning: sin él la respuesta trae el valor del secreto.
ENDPOINTS = {
    "dependabot": ("dependabot/alerts", "state=open&per_page=100", "GH-DEP"),
    "code-scanning": ("code-scanning/alerts", "state=open&per_page=100", "GH-CS"),
    "secret-scanning": ("secret-scanning/alerts", "state=open&per_page=100&hide_secret=true", "GH-SS"),
    "advisories": ("security-advisories", "per_page=100", "GH-ADV"),
}

ACCEPT = "Accept: application/vnd.github+json"
API_VERSION = "X-GitHub-Api-Version: 2022-11-28"

# Tope duro de páginas (de 100): superado, el barrido muere fail-closed en vez de truncar en silencio.
TOPE_PAGINAS = 20
POR_PAGINA = 100

# severidad GitHub -> nivel S. Tabla por defecto (decisión diferida, ratifica el CEO): ante duda la más alta.
NIVEL_POR_SEVERIDAD = {
    "critical": 1, "high": 2, "error": 2,
    "medium": 3, "moderate": 3,
    "low": 4, "note": 4, "warning": 4,
}
NIVEL_DESCONOCIDA = 1   # severidad ausente o fuera de la tabla -> la más alta (fail-closed)

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ID_RE = re.compile(r"^(?:[0-9]+|GHSA(?:-[a-z0-9]{4}){3}|S4)$")

_OCULTOS: set[str] = set()


MASCARA = "[OCULTO]"


def registrar_oculto(valor: object) -> None:
    """Todo valor registrado se enmascara en CUALQUIER salida del proceso, con cualquier longitud
    (incluidos los de 1-3 caracteres) y también en sus formas transformadas: saneada a una línea y
    escapada como JSON, que son las que cambian el literal al sanear o serializar."""
    if not isinstance(valor, str) or not valor:
        return
    for forma in {valor, " ".join(valor.split()), limpio(valor, len(valor) + 1),
                  json.dumps(valor)[1:-1], json.dumps(valor, ensure_ascii=False)[1:-1]}:
        if forma:
            _OCULTOS.add(forma)


def ocultar(texto: str) -> str:
    """Una sola pasada (alternancia, las más largas primero): lo ya enmascarado no se vuelve a tocar."""
    if not _OCULTOS:
        return texto
    patron = "|".join(re.escape(v) for v in sorted(_OCULTOS, key=len, reverse=True))
    return re.sub(patron, MASCARA, texto)


# Longitud mínima (N) para que un secreto CONTENIDO en el nombre del repositorio aborte con rc 3. Los secretos
# reales de secret scanning son largos; uno de 1-3 caracteres contenido en el nombre es una coincidencia de
# texto (como con `state` o las claves del JSON): la alerta se cuenta y el rc es 0. Un secreto IGUAL al
# nombre completo del repositorio aborta con cualquier longitud.
LONGITUD_MIN_SECRETO_EN_REPO = 4


def repo_colisiona_con_secreto(repo: str) -> bool:
    return repo in _OCULTOS or any(len(v) >= LONGITUD_MIN_SECRETO_EN_REPO and v in repo for v in _OCULTOS)


def exponer(valor: object, tope: int = 200) -> str:
    """Representación SALIENTE de un texto no confiable de GitHub (título, URL, detalle): se enmascara
    antes y después de sanear, para que el saneado (saltos de línea, backticks) no oculte el literal.
    Los datos con los que se cuenta y se decide (state, identidad, severidad) NO pasan por aquí."""
    return ocultar(limpio(ocultar(str(valor if valor is not None else "")), tope))


def salida(texto: str = "", fichero=None, crudo: bool = False) -> None:
    """`crudo=True` imprime tal cual: para documentos cuyo texto fijo (claves JSON, plantilla del body) no
    puede alterarse por una coincidencia de un secreto corto; sus valores ya salen enmascarados de `exponer`."""
    print(texto if crudo else ocultar(texto), file=fichero or sys.stdout)


@contextlib.contextmanager
def helper_enmascarado():
    """Todo lo que un helper importado imprime (errores, abortos, salida del gate) pasa por `ocultar`.
    Conserva el SystemExit (rc) y no toca los gates del helper."""
    ant_o, ant_e = sys.stdout, sys.stderr
    buf_o, buf_e = io.StringIO(), io.StringIO()
    sys.stdout, sys.stderr = buf_o, buf_e
    try:
        yield
    finally:
        sys.stdout, sys.stderr = ant_o, ant_e
        for buf, destino in ((buf_o, ant_o), (buf_e, ant_e)):
            if buf.getvalue():
                print(ocultar(buf.getvalue()), end="", file=destino)


def die(msg: str, code: int = 1) -> None:
    salida(f"github_seguridad: {msg}", sys.stderr)
    sys.exit(code)


class FuenteFallida(Exception):
    """Una superficie no devolvió una lista válida: nunca equivale a «0 alertas»."""


class NoVigilada(FuenteFallida):
    """403/404 de la superficie: desactivada o sin permiso."""


class ColisionSecreto(FuenteFallida):
    """Un secreto coincide con el identificador de una alerta: enmascararlo rompería el contrato."""


def cargar_ci():
    spec = importlib.util.spec_from_file_location(
        "crear_issue_desde_sentry", HERE / "crear_issue_desde_sentry.py")
    m = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("crear_issue_desde_sentry", m)
    spec.loader.exec_module(m)
    return m


ci = cargar_ci()


# ── configuración y credenciales ───────────────────────────────────────────────────────────────
def env_requerido(nombre: str) -> str:
    val = os.environ.get(nombre, "").strip()
    if not val:
        die(f"config ausente: {nombre} obligatorio por entorno (sin default de marca)")
    return val


def leer_token(hdr_path: Path) -> str:
    """Token del header-file 0600 (una línea 'Authorization: Bearer <token>'). Nunca se imprime."""
    if not hdr_path.is_file():
        die(f"header-file ausente: {hdr_path}")
    if oct(hdr_path.stat().st_mode & 0o777) != "0o600":
        die(f"header-file con permisos inseguros (se exige 0o600): {hdr_path}")
    lineas = [ln for ln in hdr_path.read_text().splitlines() if ln.strip()]
    if len(lineas) != 1 or not lineas[0].startswith("Authorization: "):
        die("header-file con contenido inesperado (una línea 'Authorization: <valor>')")
    valor = lineas[0][len("Authorization: "):].strip()
    m = re.fullmatch(r"(?:Bearer|token)\s+(\S+)", valor)
    if not m:
        die("header-file con esquema inesperado (se espera 'Bearer <token>')")
    registrar_oculto(m.group(1))
    return m.group(1)


def superficies_declaradas() -> list[str]:
    bruto = os.environ.get("GITHUB_SEC_SUPERFICIES", "").strip()
    if not bruto:
        return list(SUPERFICIES_VALIDAS)
    nombres = [n.strip() for n in bruto.split(",") if n.strip()]
    desconocidas = [n for n in nombres if n not in SUPERFICIES_VALIDAS]
    if desconocidas or not nombres:
        die(f"GITHUB_SEC_SUPERFICIES inválida ({bruto!r}); válidas: {', '.join(SUPERFICIES_VALIDAS)}")
    return [n for n in SUPERFICIES_VALIDAS if n in nombres]


# ── lectura de GitHub (solo GET) ───────────────────────────────────────────────────────────────
def parsear_paginas(texto: str) -> list[dict]:
    """`gh api --paginate` emite una lista (páginas fusionadas) o varias listas concatenadas."""
    dec = json.JSONDecoder()
    i, n, valores, items = 0, len(texto), 0, []
    while True:
        while i < n and texto[i].isspace():
            i += 1
        if i >= n:
            break
        try:
            val, i = dec.raw_decode(texto, i)
        except ValueError:
            raise FuenteFallida("la respuesta no es JSON válido") from None
        if not isinstance(val, list):
            raise FuenteFallida("la respuesta no es una lista (shape inesperado)")
        valores += 1
        items.extend(val)
    if valores == 0:
        raise FuenteFallida("respuesta vacía")
    if valores > TOPE_PAGINAS or len(items) > TOPE_PAGINAS * POR_PAGINA:
        raise FuenteFallida(f"supera el tope de {TOPE_PAGINAS} páginas: probable paginación sin fin")
    if not all(isinstance(x, dict) for x in items):
        raise FuenteFallida("la lista contiene elementos que no son objetos")
    return items


def gh_listar(repo: str, superficie: str, token: str) -> list[dict]:
    ruta, query, _ = ENDPOINTS[superficie]
    argv = ["gh", "api", "--method", "GET", "--paginate", "-H", ACCEPT, "-H", API_VERSION,
            f"repos/{repo}/{ruta}?{query}"]
    env = dict(os.environ)
    env["GH_TOKEN"] = token          # el token viaja por entorno, jamás por argv
    env["GH_PROMPT_DISABLED"] = "1"
    env.pop("GITHUB_TOKEN", None)
    try:
        r = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=180)
    except FileNotFoundError:
        raise FuenteFallida("gh no está disponible") from None
    except subprocess.TimeoutExpired:
        raise FuenteFallida("gh excedió el timeout") from None
    if r.returncode != 0:
        # Solo se extrae el código HTTP; el texto crudo de gh nunca se reenvía.
        m = re.search(r"HTTP (\d{3})", r.stderr or "")
        codigo = m.group(1) if m else None
        if codigo in ("403", "404"):
            raise NoVigilada(f"HTTP {codigo} (superficie desactivada o sin permiso)")
        if codigo == "401":
            raise FuenteFallida("HTTP 401 (credencial inválida)")
        raise FuenteFallida(f"gh falló (rc={r.returncode}{', HTTP ' + codigo if codigo else ''})")
    return parsear_paginas(r.stdout)


# ── normalización y clasificación ──────────────────────────────────────────────────────────────
def ob(dato, *claves):
    for c in claves:
        if not isinstance(dato, dict):
            return None
        dato = dato.get(c)
    return dato


def limpio(valor: object, tope: int = 200) -> str:
    """Texto de GitHub = dato no confiable: una línea, sin marcadores HTML ni backticks."""
    t = re.sub(r"[\x00-\x1f\x7f]+", " ", str(valor if valor is not None else ""))
    t = t.replace("<!--", "").replace("-->", "").replace("`", "'")
    return " ".join(t.split())[:tope]


def nivel_de(severidad: object) -> int | None:
    if not isinstance(severidad, str):
        return None
    return NIVEL_POR_SEVERIDAD.get(severidad.strip().lower())


def nivel_alerta(superficie: str, a: dict) -> tuple[int, str]:
    """Devuelve (nivel S, severidad textual). Tabla por defecto, ante duda la más alta."""
    if superficie == "secret-scanning":
        return 1, "secret"
    if superficie == "dependabot":
        candidatas = [ob(a, "security_advisory", "severity"), ob(a, "security_vulnerability", "severity")]
    elif superficie == "code-scanning":
        candidatas = [ob(a, "rule", "security_severity_level"), ob(a, "rule", "severity")]
        # security_severity_level manda; la severidad de la regla solo si no hay nivel de seguridad
        if nivel_de(candidatas[0]) is not None:
            candidatas = candidatas[:1]
    else:
        candidatas = [a.get("severity")]
    conocidas = [(nivel_de(s), str(s).strip().lower()) for s in candidatas if nivel_de(s) is not None]
    if not conocidas:
        return NIVEL_DESCONOCIDA, "desconocida"
    return min(conocidas)


def es_abierta(superficie: str, a: dict) -> bool:
    if superficie == "advisories":
        return a.get("state") != "closed"      # triage / draft / published siguen pidiendo acción
    return a.get("state", "open") == "open"


def identidad(superficie: str, a: dict) -> str:
    if superficie == "advisories":
        ident = a.get("ghsa_id")
        if not isinstance(ident, str) or not ID_RE.fullmatch(ident):
            raise FuenteFallida("advisory sin ghsa_id válido")
        return ident
    num = a.get("number")
    if not isinstance(num, int) or isinstance(num, bool) or num < 0:
        raise FuenteFallida("alerta sin número válido")
    return str(num)


def titulo_de(superficie: str, a: dict) -> str:
    """Título SALIENTE: cada texto no confiable pasa por `exponer` antes de componerse."""
    if superficie == "dependabot":
        return limpio(f"{exponer(ob(a, 'dependency', 'package', 'name') or 'paquete')}: "
                      f"{exponer(ob(a, 'security_advisory', 'summary') or 'vulnerabilidad en dependencia')}")
    if superficie == "code-scanning":
        return limpio(f"{exponer(ob(a, 'rule', 'id') or 'regla')} en "
                      f"{exponer(ob(a, 'most_recent_instance', 'location', 'path') or 'ruta no indicada')}")
    if superficie == "secret-scanning":
        return exponer(a.get("secret_type_display_name") or a.get("secret_type") or "secreto expuesto")
    return exponer(a.get("summary") or "advisory de seguridad")


def detalle_de(superficie: str, a: dict) -> dict[str, str]:
    """Campos derivables de la alerta. NUNCA incluye `secret`."""
    if superficie == "dependabot":
        campos = {
            "paquete": ob(a, "dependency", "package", "name"),
            "ecosistema": ob(a, "dependency", "package", "ecosystem"),
            "manifiesto": ob(a, "dependency", "manifest_path"),
            "ghsa": ob(a, "security_advisory", "ghsa_id"),
            "cve": ob(a, "security_advisory", "cve_id"),
            "rango vulnerable": ob(a, "security_vulnerability", "vulnerable_version_range"),
            "versión parcheada": ob(a, "security_vulnerability", "first_patched_version", "identifier"),
        }
    elif superficie == "code-scanning":
        loc = ob(a, "most_recent_instance", "location") or {}
        campos = {
            "regla": ob(a, "rule", "id"),
            "herramienta": ob(a, "tool", "name"),
            "ubicación": f"{loc.get('path', '')}:{loc.get('start_line', '')}" if loc else None,
        }
    elif superficie == "secret-scanning":
        campos = {"tipo de secreto": a.get("secret_type_display_name") or a.get("secret_type"),
                  "validez": a.get("validity")}
    else:
        campos = {"ghsa": a.get("ghsa_id"), "cve": a.get("cve_id"), "estado": a.get("state")}
    campos["creada"] = a.get("created_at")
    return {k: exponer(v) for k, v in campos.items() if v not in (None, "")}


def normalizar(superficie: str, crudas: list[dict]) -> list[dict]:
    """Descarta `secret` ANTES de cualquier otro uso, deduplica y deja solo las abiertas.
    Estado, identidad y severidad se deciden con los valores ORIGINALES; solo las representaciones
    salientes (título, URL, detalle) se enmascaran. Si un secreto coincide con el identificador de una
    alerta abierta, exponerlo cambiaría el contrato: aborta (ColisionSecreto) sin informe ni cursor."""
    vistos: dict[str, dict] = {}
    for a in crudas:
        registrar_oculto(a.pop("secret", None))
    for a in crudas:
        if not es_abierta(superficie, a):
            continue
        ident = identidad(superficie, a)
        if ident in vistos:
            continue
        if ocultar(ident) != ident:
            raise ColisionSecreto("un secreto coincide con el identificador de una alerta abierta: "
                                  "enmascararlo alteraría el contrato; no se emite informe ni cursor")
        nivel, sev = nivel_alerta(superficie, a)
        vistos[ident] = {
            "superficie": superficie, "id": ident, "nivel": nivel, "severidad": sev,
            "titulo": titulo_de(superficie, a), "url": exponer(a.get("html_url") or "", 300),
            "detalle": detalle_de(superficie, a),
        }
    return sorted(vistos.values(), key=lambda x: (x["nivel"], x["id"]))


def sello_de(superficie: str, ident: str, nivel: int) -> str | None:
    """Propuesta de sello (lo sella el operador). Sin familia nueva: reutiliza URGENTE/CONSULTA."""
    if nivel >= 4:
        return None
    familia = "SENTRY-URGENTE" if nivel == 1 else "SENTRY-CONSULTA"
    return f"{familia}-{ENDPOINTS[superficie][2]}-{ident}"


def tipo_de(nivel: int) -> tuple[str, str]:
    return ("fix", "seguridad") if nivel <= 2 else ("chore", "none")


def item_salida(it: dict, motivo: str, antes: object = None) -> dict:
    tipo, variante = tipo_de(it["nivel"])
    return {
        "superficie": it["superficie"], "id": it["id"], "nivel": f"S{it['nivel']}",
        "severidad": it["severidad"], "titulo": it["titulo"], "url": it["url"],
        "sello": sello_de(it["superficie"], it["id"], it["nivel"]),
        "tipo": tipo, "variante": variante, "motivo": motivo,
        "antes": antes, "ahora": f"S{it['nivel']}",
    }


def comparar(actual: dict[str, list[dict]], cursor: dict) -> tuple[list[dict], list[dict]]:
    """NUEVOS: alerta S1-S3 no vista antes. ESCALA: sube la severidad de una ya vista, o crece el
    número de abiertas de la superficie. S4 se cuenta pero no se lista como novedad."""
    nuevos, escala = [], []
    previo = cursor.get("superficies", {}) if isinstance(cursor, dict) else {}
    for sup, items in actual.items():
        prev = previo.get(sup)
        vistos = prev.get("items", {}) if isinstance(prev, dict) else {}
        for it in items:
            antes = vistos.get(it["id"])
            if antes is None:
                if it["nivel"] <= 3:
                    nuevos.append(item_salida(it, "nuevo"))
            elif isinstance(antes, int) and it["nivel"] < antes:
                escala.append(item_salida(it, "severidad", f"S{antes}"))
        if isinstance(prev, dict) and len(items) > int(prev.get("total", 0) or 0):
            escala.append({
                "superficie": sup, "id": None, "nivel": None, "severidad": None,
                "titulo": f"crece el número de alertas abiertas de {sup}", "url": "",
                "sello": None, "tipo": None, "variante": None, "motivo": "abiertas",
                "antes": int(prev.get("total", 0) or 0), "ahora": len(items),
            })
    return nuevos, escala


# ── cursor propio ──────────────────────────────────────────────────────────────────────────────
def cargar_cursor(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        d = json.loads(path.read_text())
    except json.JSONDecodeError:
        die(f"cursor.json existe pero no parsea: {path}")
    if not isinstance(d, dict):
        die(f"cursor.json con forma inesperada: {path}")
    return d


def guardar_cursor(path: Path, previo: dict, actual: dict[str, list[dict]]) -> None:
    sup = dict(previo.get("superficies", {})) if isinstance(previo, dict) else {}
    for nombre, items in actual.items():
        sup[nombre] = {"total": len(items), "items": {it["id"]: it["nivel"] for it in items}}
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps({"version": 1, "superficies": sup}, ensure_ascii=False))
    tmp.replace(path)


# ── barrido ────────────────────────────────────────────────────────────────────────────────────
def barrer(repo: str, superficies: list[str], token: str) -> tuple[dict[str, list[dict]], list[str]]:
    """Devuelve (alertas por superficie, fallos). Un fallo NUNCA se interpreta como cero alertas."""
    actual: dict[str, list[dict]] = {}
    fallos: list[str] = []
    crudas: dict[str, list[dict]] = {}
    for sup in superficies:
        try:
            crudas[sup] = gh_listar(repo, sup, token)
        except NoVigilada as e:
            fallos.append(f"SUPERFICIE-NO-VIGILADA {sup}: {e}")
        except FuenteFallida as e:
            fallos.append(f"FUENTE-FALLIDA {sup}: {e}")
    # Todos los secretos se registran ANTES de procesar ninguna superficie: el valor de una alerta de
    # secret scanning puede reflejarse en el texto de otra superficie leída antes.
    for lista in crudas.values():
        for a in lista:
            registrar_oculto(a.get("secret"))
    # El nombre del repositorio va en la cabecera del informe, en el body y en el marcador de identidad
    # (que no se enmascara: es la clave del dedupe). Si un secreto registrado es el nombre o (con N o más
    # caracteres) está contenido en él, no se puede emitir sin alterar ese contrato: aborta (rc 3) sin
    # informe, borrador ni cursor.
    if repo_colisiona_con_secreto(repo):
        fallos.append("FUENTE-FALLIDA repositorio: un secreto registrado coincide con el nombre del repositorio "
                      "o está contenido en él: enmascararlo alteraría el contrato; no se emite informe, "
                      "borrador ni cursor")
        return {}, fallos
    for sup, lista in crudas.items():
        try:
            actual[sup] = normalizar(sup, lista)
        except FuenteFallida as e:
            fallos.append(f"FUENTE-FALLIDA {sup}: {e}")
    return actual, fallos


def resumen_por_nivel(items: list[dict]) -> dict[str, int]:
    return {f"S{n}": sum(1 for i in items if i["nivel"] == n) for n in (1, 2, 3, 4)}


def informe_json(actual: dict[str, list[dict]], nuevos: list[dict], escala: list[dict],
                 no_vigiladas: list[str]) -> dict:
    return {
        "superficies": {s: {"abiertas": len(i), "por_nivel": resumen_por_nivel(i)} for s, i in actual.items()},
        "nuevos": nuevos, "escala": escala, "no_vigiladas": no_vigiladas,
        "total_abiertas": sum(len(i) for i in actual.values()),
    }


def imprimir_informe(repo: str, actual: dict[str, list[dict]], nuevos: list[dict], escala: list[dict],
                     no_vigiladas: list[str]) -> None:
    # Texto fijo + ids + vocabulario cerrado + campos ya enmascarados por `exponer`: se imprime tal cual
    # (un secreto corto no puede alterar las etiquetas del informe).
    def emitir(texto: str) -> None:
        salida(texto, crudo=True)

    if nuevos or escala:
        total = sum(len(i) for i in actual.values())
        emitir(f"GITHUB-SEGURIDAD repo={repo} abiertas={total}")
        for sup, items in actual.items():
            n = resumen_por_nivel(items)
            emitir(f"  {sup}: {len(items)} (S1={n['S1']} S2={n['S2']} S3={n['S3']} S4={n['S4']})")

        def bloque(titulo: str, lista: list[dict]) -> None:
            if not lista:
                return
            emitir(f"\n=== {titulo} ({len(lista)}) ===")
            for it in lista:
                if it["motivo"] == "abiertas":
                    emitir(f"  [{it['superficie']}] abiertas {it['antes']} -> {it['ahora']}")
                    continue
                extra = f" (antes {it['antes']})" if it["motivo"] == "severidad" else ""
                emitir(f"  [{it['nivel']}] {it['superficie']}#{it['id']}{extra} — {it['titulo'][:80]} — {it['url']}")
                if it["sello"]:
                    emitir(f"        sello propuesto: {it['sello']} · issue {it['tipo']}/{it['variante']}")

        bloque("NUEVOS", nuevos)
        bloque("ESCALA", escala)
    if no_vigiladas:
        emitir("NO VIGILADAS (fuera de GITHUB_SEC_SUPERFICIES): " + ", ".join(no_vigiladas))


# ── creación de issue ──────────────────────────────────────────────────────────────────────────
def marcador_identidad(superficie: str, ident: str, repo: str) -> str:
    return f"<!-- {termino_identidad(superficie, ident, repo)} -->"


def termino_identidad(superficie: str, ident: str, repo: str) -> str:
    """Texto buscable del marcador (con el cierre ` -->` en la búsqueda para no casar prefijos)."""
    return f"vigia-github-identity superficie={superficie} id={ident} repo={repo}"


def bloque_datos(repo: str, items: list[dict]) -> str:
    lineas = ["## Datos de la alerta de GitHub (auto-generado por github_seguridad.py)\n"]
    for it in items:
        lineas.append(f"- {it['superficie']} `{it['id']}` · {it['nivel_txt']} ({it['severidad']}) · {it['titulo']}"
                      f" · {it['url']}")
        for k, v in it["detalle"].items():
            lineas.append(f"  - {k}: `{v}`")
    lineas.append(f"- repositorio: `{repo}` · criterio de cierre: la alerta pasa a no abierta en GitHub "
                  "(cifra exacta del barrido, nunca adjetivos)")
    return "\n".join(lineas) + "\n"


def construir_body(repo: str, superficie: str, ident: str, items: list[dict]) -> tuple[str, str, str, str]:
    """Devuelve (body, tipo, variante, título). Rellena lo derivable; el juicio queda en JUICIO-OPERADOR."""
    agrupado = ident == "S4"
    nivel = 4 if agrupado else min(i["nivel"] for i in items)
    tipo, variante = tipo_de(nivel)
    hoy = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    sha = ci.resolver_baseline_sha()
    j = ci.juicio("causa/hallazgos")
    j_dec = ci.juicio("decisiones-selladas")
    datos_items = [dict(i, nivel_txt=f"S{i['nivel']}") for i in items]
    datos = bloque_datos(repo, datos_items)
    primero = items[0]
    sha_txt = f"`{sha}`" if sha else ci.juicio("baseline-repo")
    cmd_gh = f"gh api --method GET repos/{repo}/{ENDPOINTS[superficie][0]}?{ENDPOINTS[superficie][1]}"
    arranque = f"`{cmd_gh}` (solo lectura)"
    # Ficheros que señala la alerta (manifiesto o ubicación): lo único «tocado» que es derivable.
    rutas = sorted({v for i in items for k, v in i["detalle"].items() if k in ("manifiesto", "ubicación") and v})[:5]
    artefactos = ("\n".join(f"- `{r}` — fichero señalado por la alerta; el diff no sale de esta lista" for r in rutas)
                  if rutas else f"- {ci.juicio('artefactos-tocados')}")
    ids = ", ".join(i["id"] for i in items[:10])
    invariante = (f"- El resto de alertas abiertas de {superficie} no cambian de estado — lo prueba: "
                  f"`{cmd_gh}` → solo desaparece(n) {ids}")
    referencia = f"- {j_dec} — referencia: (PR o commit de la decisión, si existe)"
    if tipo == "fix":
        titulo = f"Corregir alerta de {superficie} {ident}: {primero['titulo']}"[:250]
        cuerpo = ci.cargar_plantilla("fix")
        pasos = [
            ("# {Imperativo} {qué} ({dónde})", f"# {titulo}", "título"),
            ("[2-4 frases: qué defecto se corrige, a quién le duele hoy, qué valor entrega cerrarlo.]",
             f"Alerta abierta de {superficie} en `{repo}` (S{primero['nivel']}, "
             f"severidad {primero['severidad']}). {j}", "contexto"),
            ("**Origen**: [link adjunto — reporte de usuario / hallazgo de revisión / alerta de monitoreo, con fecha. El detalle vive AQUÍ.]",
             f"**Origen**: alerta de {superficie} `{ident}` — {primero['url']}", "origen"),
            ("## Baseline verificado (AAAA-MM-DD)", f"## Baseline verificado ({hoy})", "fecha baseline"),
            ("- Rama/commit de referencia: `<sha>`", f"- Rama/commit de referencia: {sha_txt}", "sha baseline"),
            ("  - `[comando que reproduce el estado actual]` → [salida que evidencia el defecto HOY]",
             f"  - {arranque} → la alerta `{ident}` figura abierta", "arranque verificado"),
            ("| [p. ej. estrategia de corrección, ventana de despliegue] | [valor] | [persona] | [fecha] |",
             f"| estrategia de corrección | {j_dec} | — | — |", "decisión sellada"),
            ("- **Observado**: [comportamiento real LITERAL — mensaje de error / salida / captura, con fecha; en sev1: timestamp exacto]",
             f"- **Observado**: {primero['titulo']} ({primero['severidad']}). {j}", "observado"),
            ("- [mecánica exacta: qué línea/condición produce el síntoma y por qué]", f"- {j}", "causa raíz mecánica"),
            ("- Prueba: [experimento que la confirma — alterar la condición cambia el síntoma de forma predecible]",
             f"- Prueba: {j}", "causa raíz prueba"),
            ("- Fix propuesto: [cambio mínimo que elimina la causa raíz]", f"- Fix propuesto: {j}", "fix propuesto"),
            ("- `[comando que enumera TODAS las instancias de la clase]` → [listado literal + conteo]",
             f"- {j} (comando + listado de todas las instancias de la clase)", "inventario clase"),
            ("- [paths que el fix modifica — el diff no sale de esta lista]", artefactos, "artefactos tocados"),
            ("- [comportamiento correcto vecino al defecto que queda INTACTO] — lo prueba: [suite/spec concreta]",
             invariante, "invariante"),
            ("- [decisión ya integrada que el fix respeta] — referencia: [PR/commit]", referencia, "referencia"),
        ]
    else:
        agrup = f"{len(items)} alertas de baja severidad de {superficie}" if agrupado else f"la alerta {ident} de {superficie}"
        titulo = (f"Triar {agrup} ({repo})")[:250]
        cuerpo = ci.cargar_plantilla("chore")
        pasos = [
            ("# {Imperativo} {qué} ({dónde})", f"# {titulo}", "título"),
            ("[2-4 frases: qué mantenimiento/infraestructura es, por qué ahora, qué destraba.]",
             f"Alertas abiertas de {superficie} en `{repo}` clasificadas S{nivel} (`references/02-taxonomia-triage.md`). {j}", "contexto"),
            ("**Origen**: [link adjunto — deuda registrada / cambio de entorno / decisión con fecha. El detalle vive AQUÍ.]",
             f"**Origen**: barrido de {superficie} de `{repo}` — {primero['url']}", "origen"),
            ("## Baseline verificado (AAAA-MM-DD)", f"## Baseline verificado ({hoy})", "fecha baseline"),
            ("- Rama/commit de referencia: `<sha>`", f"- Rama/commit de referencia: {sha_txt}", "sha baseline"),
            ("  - `[comando que muestra el estado actual del artefacto]` → [salida esperada]",
             f"  - {arranque} → las alertas listadas figuran abiertas", "arranque verificado"),
            ("| [p. ej. versión objetivo, política elegida] | [valor] | [persona] | [fecha] |",
             f"| política para estas alertas (corregir, aceptar con motivo o descartar por el dueño) | {j_dec} | — | — |",
             "decisión sellada"),
            ("- `[path:línea @ commit]` — extracto literal del estado actual que motiva el cambio:\n  > [2-6 líneas del artefacto tal como está HOY]",
             f"- {j} — extracto literal del estado actual que motiva el cambio:\n  > (pegar la alerta tal como figura hoy en GitHub)",
             "evidencia"),
            ("- [números, no \"es mejor práctica\": minutos ahorrados por corrida, fallos/mes que desaparecen, pasos manuales eliminados, tamaño reducido]",
             f"- {j} (cuántas alertas abiertas desaparecen — cifra, no adjetivo)", "beneficio"),
            ("| `[ruta 1]` | [qué se cambia exactamente] |\n| `[ruta 2]` | [qué se cambia exactamente] |",
             f"| {rutas[0] if rutas else 'a determinar'} | {j} |",
             "cambios por archivo"),
            ("- [configs, scripts, docs, pipelines que se modifican]", artefactos, "artefactos tocados"),
            ("- [comportamiento operativo que sigue IGUAL tras el chore] — lo prueba: [check/suite concreta]",
             invariante, "invariante"),
            ("- [decisión ya integrada que se respeta] — referencia: [PR/commit]", referencia, "referencia"),
            ("- [ ] `[comando]` → [salida esperada que demuestra el cambio — cobertura 1:1 con \"Cambios por archivo\"]",
             f"- [ ] `{cmd_gh}` → {ids} ya no figura(n) abierta(s)", "DoD comando"),
            ("| [cada checkbox] | salida literal sobre el commit final / captura / run de checks |",
             "| Las alertas ya no figuran abiertas | salida literal del barrido tras el cambio |", "evidencia de cierre"),
        ]
    for viejo, nuevo, etiqueta in pasos:
        cuerpo = ci.sub1(cuerpo, viejo, nuevo, etiqueta)
    cuerpo = ci.sub1(cuerpo, "## Contexto y origen", f"{datos}\n## Contexto y origen", "inserción datos GitHub")
    body = f"{ci.marcador(tipo, variante)}\n\n{cuerpo}\n\n{marcador_identidad(superficie, ident, repo)}\n"
    return body, tipo, variante, titulo


def exigir_identidad(body: str, superficie: str, ident: str, repo: str) -> None:
    """Un --body-file ajeno (otra alerta u otro repo) no puede deduplicar ni crear con estos datos."""
    esperado = marcador_identidad(superficie, ident, repo)
    if esperado not in body:
        die("--body-file sin el marcador de identidad esperado "
            f"({termino_identidad(superficie, ident, repo)}): rechazado fail-closed")


def crear_issue(args, repo: str, superficies: list[str], token: str) -> int:
    m = re.fullmatch(r"([a-z-]+):([A-Za-z0-9-]+)", args.crear_issue)
    if not m or m.group(1) not in SUPERFICIES_VALIDAS or not ID_RE.fullmatch(m.group(2)):
        die(f"--crear-issue espera <superficie>:<id> con superficie en {SUPERFICIES_VALIDAS} (recibido {args.crear_issue!r})")
    superficie, ident = m.group(1), m.group(2)
    if superficie not in superficies:
        die(f"la superficie {superficie} no está en GITHUB_SEC_SUPERFICIES: no vigilada")
    api_key = env_requerido("LINEAR_API_KEY")
    registrar_oculto(api_key)
    # Se leen y registran los secretos de TODAS las superficies declaradas antes de construir o emitir
    # nada: el valor de una alerta de secret scanning puede reflejarse en el texto de otra superficie.
    # Un fallo de cualquier fuente declarada sigue siendo un fallo explícito (rc 3), no «sin alertas».
    actual, fallos = barrer(repo, superficies, token)
    if fallos:
        for f in fallos:
            salida(f, sys.stderr)
        return 3
    abiertas = actual[superficie]
    if ident == "S4":
        items = [i for i in abiertas if i["nivel"] == 4]
    else:
        items = [i for i in abiertas if i["id"] == ident]
    if not items:
        die(f"no hay alerta abierta {superficie}:{ident}")
    with helper_enmascarado():     # die() de plantillas/sub1 del helper: su salida pasa por `ocultar`
        body, tipo, variante, titulo = construir_body(repo, superficie, ident, items)
    # Título y body generados ya salen enmascarados (`exponer` en sus fuentes); el texto fijo de la plantilla
    # y el marcador de identidad no se tocan, para que un secreto corto no altere la semántica.
    if args.body_file:
        ruta = Path(args.body_file)
        if not ruta.is_file() or not ruta.read_text().strip():
            die(f"--body-file ausente o vacío: {ruta}")
        body = ruta.read_text()
        exigir_identidad(body, superficie, ident, repo)
        marca = marcador_identidad(superficie, ident, repo)
        body = marca.join(ocultar(p) for p in body.split(marca))   # texto del operador: se enmascara salvo el marcador
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
        body_path = Path(f.name)
    try:
        if args.dry_run:
            try:
                with helper_enmascarado():
                    r = ci.correr_audit(body_path)
                if r.returncode != 0:
                    salida("aviso: audit-issue ≠ 0 (esperado hasta completar los JUICIO-OPERADOR)", sys.stderr)
            except SystemExit:
                salida("aviso: audit-issue no pudo ejecutarse; se exige antes de --apply", sys.stderr)
        else:
            with helper_enmascarado():
                r = ci.correr_audit(body_path)
            if r.returncode != 0:
                die(f"audit-issue FALLÓ (exit {r.returncode}) — el body no es despachable; no se crea nada "
                    "(esperado si quedan marcadores JUICIO-OPERADOR sin completar)")
    finally:
        if args.dry_run:
            salida(f"(borrador conservado para inspección: {body_path})", sys.stderr)
        else:
            body_path.unlink(missing_ok=True)

    # Dedupe fail-closed: marcador de identidad Y título normalizado, issues no cerradas.
    with helper_enmascarado():     # errores/abortos del helper (cuerpo de un error de Linear incluido) enmascarados
        dups = ci.dedupe_linear(termino_identidad(superficie, ident, repo) + " -->", titulo, api_key)
    if dups:
        salida("DEDUPE: ya existe issue para esta alerta → NO se crea. Comentar el delta en:", sys.stderr)
        for d in dups:
            salida(f"  {d['identifier']} [{d['state']['name']}] {d['title']}", sys.stderr)
        return 2
    if args.dry_run:
        salida("=== DRY-RUN (default): body listo, dedupe limpio. NO se creó nada. ===")    # texto fijo: sin crudo
        salida(body, crudo=True)     # único crudo: plantilla + marcador intactos; sus valores ya salen de `exponer`/`ocultar`
        salida("\n(para crear de verdad: completar los JUICIO-OPERADOR y re-ejecutar con --apply --body-file <borrador>)")
        return 0
    with helper_enmascarado():
        creada = ci.crear_en_linear({"title": titulo}, body, tipo, None, api_key)
    salida(f"CREADA: {creada}")     # identificador y URL los devuelve Linear: dato externo, se enmascara
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Barrido de seguridad de GitHub (solo lectura).")
    ap.add_argument("--json", action="store_true", help="salida JSON para el watcher")
    ap.add_argument("--no-cursor", action="store_true", help="ignora el cursor (lectura y escritura)")
    ap.add_argument("--crear-issue", metavar="SUPERFICIE:ID", default=None,
                    help="monta (y con --apply crea) la issue de una alerta; <superficie>:S4 agrupa las S4")
    ap.add_argument("--dry-run", action="store_true", default=True, help="(DEFAULT) no crea nada")
    ap.add_argument("--apply", dest="dry_run", action="store_false", help="crea la issue de verdad")
    ap.add_argument("--body-file", default=None, help="body ya completado (con el marcador de identidad)")
    args = ap.parse_args()

    repo = env_requerido("GITHUB_SEC_REPO")
    if not REPO_RE.fullmatch(repo):
        die(f"GITHUB_SEC_REPO inválido ({repo!r}): se espera owner/nombre")
    superficies = superficies_declaradas()
    no_vigiladas = [s for s in SUPERFICIES_VALIDAS if s not in superficies]
    hdr = Path(os.environ.get("GITHUB_SEC_HDR", str(Path.home() / ".vigia-github" / "hdr")))
    token = leer_token(hdr)

    if args.crear_issue:
        return crear_issue(args, repo, superficies, token)

    cursor_path = Path(os.environ.get("GITHUB_SEC_CURSOR", str(Path.home() / ".vigia-github" / "cursor.json")))
    cursor = {} if args.no_cursor else cargar_cursor(cursor_path)
    actual, fallos = barrer(repo, superficies, token)
    if fallos:
        for f in fallos:
            salida(f, sys.stderr)
        if no_vigiladas:
            salida("NO VIGILADAS (fuera de GITHUB_SEC_SUPERFICIES): " + ", ".join(no_vigiladas), sys.stderr)
        return 3     # sin cursor y sin informe parcial: un fallo no se lee como calma
    nuevos, escala = comparar(actual, cursor)
    if not args.no_cursor:
        guardar_cursor(cursor_path, cursor, actual)
    if args.json:
        # JSON: las claves contractuales y el vocabulario cerrado no se tocan; los valores libres ya salen
        # enmascarados desde `exponer`. Nunca se enmascara el documento serializado.
        salida(json.dumps(informe_json(actual, nuevos, escala, no_vigiladas), ensure_ascii=False, indent=2),
               crudo=True)
        return 0
    imprimir_informe(repo, actual, nuevos, escala, no_vigiladas)
    return 0


if __name__ == "__main__":
    sys.exit(main())
