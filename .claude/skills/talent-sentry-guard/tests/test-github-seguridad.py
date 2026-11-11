#!/usr/bin/env python3
"""C1-C9 de github_seguridad.py y de las rutas de crear_issue_desde_sentry.py, con fuentes sintéticas.

El doble de `gh` es un ejecutable envuelto por gh_contrato.envolver (gh 2.45.0): un argv fuera del
contrato revienta el caso. Linear se simula por urllib. Ningún caso usa red, GitHub ni Linear reales.
Cada guarda nueva tiene su mutante: ROJO con el defecto, VERDE al revertir.
El secreto sintético y los tokens de prueba se buscan en TODA la salida: 0 apariciones.
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
SCRIPTS = SKILL / "scripts"
SKILLS = SKILL.parent
ROOT = HERE.parents[2]
FIX = HERE / "fixtures/github"
REPO = "org-ejemplo/repo-ejemplo"
TOKEN = "ghp_TOKENSINTETICO0123456789"
LINEAR_KEY = "lin_api_SINTETICA0123456789"
SECRETO = "SECRETO-SINTETICO-ZZ9QX7-NO-REAL"
SECRETOS = (TOKEN, LINEAR_KEY, SECRETO)
PASS = FAIL = 0
NO_EJECUTADOS = 0
MODULOS = {}


def cargar(path, nombre):
    spec = importlib.util.spec_from_file_location(nombre, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[nombre] = m
    spec.loader.exec_module(m)
    return m


gs = cargar(SCRIPTS / "github_seguridad.py", "github_seguridad")
contrato = cargar(ROOT / "tests/fixtures/instalacion/gh_contrato.py", "gh_contrato")


class Respuesta:
    def __init__(self, body):
        self.body = body

    def read(self):
        return json.dumps(self.body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


GH_CUERPO = '''#!@PY@
import json, os, sys
D = os.path.dirname(os.path.abspath(sys.argv[0]))
with open(os.path.join(D, "argv.log"), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "token": os.environ.get("GH_TOKEN")}) + "\\n")
ep = sys.argv[-1]
sup = None
for nombre, ruta in (("dependabot", "dependabot/alerts"), ("code-scanning", "code-scanning/alerts"),
                     ("secret-scanning", "secret-scanning/alerts"), ("advisories", "security-advisories")):
    if "/" + ruta + "?" in ep:
        sup = nombre
if sup is None:
    sys.stderr.write("endpoint inesperado\\n")
    sys.exit(9)
rc_f = os.path.join(D, sup + ".rc")
rc = int(open(rc_f).read()) if os.path.exists(rc_f) else 0
if rc:
    sys.stderr.write(open(os.path.join(D, sup + ".err")).read())
    sys.exit(rc)
sys.stdout.write(open(os.path.join(D, sup + ".out")).read())
'''

DATOS = {s: json.loads((FIX / f"{s}.json").read_text()) for s in gs.SUPERFICIES_VALIDAS}


class Entorno:
    """Directorio de trabajo con doble de gh, header-file, cursor y estado de Linear."""

    def __init__(self, td):
        self.t = Path(td)
        self.bin = self.t / "bin"
        self.bin.mkdir(parents=True)
        (self.t / "home").mkdir()
        self.hdr = self.t / "hdr"
        self.hdr.write_text("Authorization: Bearer " + TOKEN + "\n")
        self.hdr.chmod(0o600)
        self.cursor = self.t / "cursor.json"
        gh = self.bin / "gh"
        gh.write_text(GH_CUERPO.replace("@PY@", sys.executable))
        gh.chmod(0o700)
        contrato.envolver(gh)
        self.ponr(copy.deepcopy(DATOS))
        self.linear = {}
        self.extra_env = {}

    def ponr(self, datos, fallos=None):
        """datos: {superficie: lista|texto}; fallos: {superficie: (rc, stderr)}."""
        for s in gs.SUPERFICIES_VALIDAS:
            for ext in (".out", ".rc", ".err"):
                (self.bin / (s + ext)).unlink(missing_ok=True)
            v = datos.get(s, [])
            (self.bin / (s + ".out")).write_text(v if isinstance(v, str) else json.dumps(v))
        for s, (rc, err) in (fallos or {}).items():
            (self.bin / (s + ".rc")).write_text(str(rc))
            (self.bin / (s + ".err")).write_text(err)

    def env(self):
        e = {"GITHUB_SEC_REPO": REPO, "GITHUB_SEC_HDR": str(self.hdr), "GITHUB_SEC_CURSOR": str(self.cursor),
             "LINEAR_API_KEY": LINEAR_KEY, "TF_LINEAR_TEAM_KEY": "ABC", "HOME": str(self.t / "home"),
             "PATH": str(self.bin) + os.pathsep + os.defpath}
        e.update(self.extra_env)
        return {k: v for k, v in e.items() if v is not None}

    def log_gh(self):
        f = self.bin / "argv.log"
        return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


def linear_doble(estado):
    def urlopen(req, **kwargs):
        assert req.full_url == "https://api.linear.app/graphql" and req.get_method() == "POST", req.full_url
        assert req.get_header("Authorization") == LINEAR_KEY
        d = json.loads(req.data)
        q, v = d["query"], d.get("variables", {})
        estado.setdefault("peticiones", []).append(d)
        if "searchableContent" in q:
            estado.setdefault("busquedas", []).append(v["q"])
            if estado.get("busqueda_falla"):
                raise urllib.error.URLError("red caida")
            return Respuesta({"data": {"issues": {"nodes": estado.get("dups", lambda t: [])(v["q"])}}})
        if "teams(filter" in q:
            return Respuesta({"data": {"teams": {"nodes": [{"id": "T1", "name": "Equipo"}]}}})
        pag = {"hasNextPage": False, "endCursor": None}
        if "states(first" in q:
            return Respuesta({"data": {"team": {"states": {"nodes": [{"id": "E1", "name": "Triage"}], "pageInfo": pag}}}})
        if "labels(first" in q:
            nombres = ("vertical/academy", "actor/ai", "kind:fix", "kind:chore")
            nodos = [{"id": f"L{i}", "name": n} for i, n in enumerate(nombres)]
            return Respuesta({"data": {"team": {"labels": {"nodes": nodos, "pageInfo": pag}}}})
        if "issueCreate" in q:
            estado.setdefault("creates", []).append(d)
            if estado.get("create_error"):
                raise urllib.error.HTTPError(req.full_url, 500, "error", {}, None)
            return Respuesta({"data": {"issueCreate": {"success": True,
                                                       "issue": {"identifier": "ABC-1", "url": "https://example.invalid/ABC-1"}}}})
        raise AssertionError("consulta Linear inesperada: " + q[:60])
    return urlopen


def completado(rc):
    return subprocess.CompletedProcess(["audit"], rc, "audit-doble\n", "")


def correr(en, argv, modulo=gs, audit_rc=0, ci_mod=None):
    """Ejecuta modulo.main() con el entorno de `en`. Devuelve (rc, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    modulo._OCULTOS.clear()      # estado de proceso: cada invocación parte limpia, como un proceso nuevo
    ci_real = ci_mod or modulo.ci
    with mock.patch.dict(os.environ, en.env(), clear=True), mock.patch.object(sys, "argv", ["github_seguridad.py"] + argv), \
            mock.patch("urllib.request.urlopen", side_effect=linear_doble(en.linear)), \
            mock.patch.object(ci_real, "correr_audit", return_value=completado(audit_rc)), \
            mock.patch("time.sleep", return_value=None), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        if ci_mod is not None:
            with mock.patch.object(modulo, "ci", ci_mod):
                rc = salir(modulo.main)
        else:
            rc = salir(modulo.main)
    return rc, out.getvalue(), err.getvalue()


def salir(fn):
    try:
        return fn()
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 1


def escrituras(en):
    """Registro de argv de gh: debe ser SOLO lectura, sin token en argv."""
    for reg in en.log_gh():
        a = reg["argv"]
        assert a[:1] == ["api"] and "--method" in a and a[a.index("--method") + 1] == "GET", a
        assert not {"-f", "-F", "--field", "--raw-field", "--input", "-X"} & set(a), a
        assert TOKEN not in " ".join(a), "token en argv"
        assert reg["token"] == TOKEN, "el token debe viajar por GH_TOKEN"
    return len(en.log_gh())


def sin_fugas(*textos):
    for t in textos:
        for s in SECRETOS:
            assert s not in t, "fuga de credencial o secreto"


def barrer(en, extra=None, **kw):
    rc, out, err = correr(en, (extra or []) + ["--json"], **kw)
    return rc, (json.loads(out) if out.strip().startswith("{") else None), out, err


def esperar(nombre, condicion):
    global PASS, FAIL
    try:
        condicion()
        print(f"PASS {nombre}")
        PASS += 1
    except (Exception, SystemExit) as e:  # noqa: BLE001
        print(f"FAIL {nombre}: {type(e).__name__}: {e}")
        FAIL += 1


# ── casos ──────────────────────────────────────────────────────────────────────────────────────
def c1_secret():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, j, out, err = barrer(en)
        assert rc == 0, (rc, err)
        s7 = [x for x in j["nuevos"] if x["superficie"] == "secret-scanning"]
        assert len(s7) == 1 and s7[0]["nivel"] == "S1" and s7[0]["sello"] == "SENTRY-URGENTE-GH-SS-7", s7
        assert (s7[0]["tipo"], s7[0]["variante"]) == ("fix", "seguridad")
        ss = [r for r in en.log_gh() if "secret-scanning/alerts" in r["argv"][-1]]
        assert ss and "hide_secret=true" in ss[0]["argv"][-1], "la petición debe llevar hide_secret=true"
        sin_fugas(out, err, en.cursor.read_text())
        assert escrituras(en) == 4


def c1_cuerpo_sin_secreto():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, out, err = correr(en, ["--crear-issue", "secret-scanning:7"])
        assert rc == 0, (rc, err)
        assert "type=fix variant=seguridad" in out and "Clave de ejemplo" in out
        assert "vigia-github-identity superficie=secret-scanning id=7 repo=" + REPO in out
        sin_fugas(out, err)
        for p in re.findall(r"borrador conservado para inspección: ([^\s)]+)", err):
            sin_fugas(Path(p).read_text())
            Path(p).unlink()


def c2_nuevos_y_escala():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, j, _, _ = barrer(en)
        ids = sorted((x["superficie"], x["id"]) for x in j["nuevos"])
        assert ids == [("advisories", "GHSA-mmmm-nnnn-oooo"), ("code-scanning", "4"), ("dependabot", "1"),
                       ("dependabot", "2"), ("secret-scanning", "7")], ids
        niveles = {(x["superficie"], x["id"]): x["nivel"] for x in j["nuevos"]}
        assert niveles[("dependabot", "1")] == "S1" and niveles[("code-scanning", "4")] == "S2"
        assert niveles[("advisories", "GHSA-mmmm-nnnn-oooo")] == "S2" and niveles[("dependabot", "2")] == "S3"
        assert j["total_abiertas"] == 7 and j["escala"] == [] and j["no_vigiladas"] == []
        assert set(j) == {"superficies", "nuevos", "escala", "no_vigiladas", "total_abiertas"}
        # segundo barrido idéntico: silencio
        rc, j, out, _ = barrer(en)
        assert j["nuevos"] == [] and j["escala"] == []
        rc, out, _ = correr(en, [])
        assert rc == 0 and out.strip() == "", out
        # sube la severidad de dependabot #2 (medium -> critical) -> ESCALA
        d = copy.deepcopy(DATOS)
        d["dependabot"][1]["security_advisory"]["severity"] = "critical"
        d["dependabot"][1]["security_vulnerability"]["severity"] = "critical"
        en.ponr(d)
        rc, j, _, _ = barrer(en)
        esc = [x for x in j["escala"] if x["motivo"] == "severidad"]
        assert len(esc) == 1 and (esc[0]["antes"], esc[0]["ahora"]) == ("S3", "S1"), j["escala"]
        # crece el número de abiertas (alerta S4 nueva): ESCALA por abiertas
        d["dependabot"].append(copy.deepcopy(d["dependabot"][2]))
        d["dependabot"][-1]["number"] = 20
        d["dependabot"][-1]["security_advisory"]["ghsa_id"] = "GHSA-zzzz-zzzz-zzzz"
        en.ponr(d)
        rc, j, _, _ = barrer(en)
        ab = [x for x in j["escala"] if x["motivo"] == "abiertas"]
        assert len(ab) == 1 and ab[0]["superficie"] == "dependabot" and (ab[0]["antes"], ab[0]["ahora"]) == (3, 4), j["escala"]
        assert j["nuevos"] == [], "una S4 nueva no se lista como novedad"


def c3_s4_contada_no_listada():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, j, out, _ = barrer(en)
        assert j["superficies"]["dependabot"]["por_nivel"]["S4"] == 1
        assert j["superficies"]["code-scanning"]["por_nivel"]["S4"] == 1
        assert not any(x["nivel"] == "S4" for x in j["nuevos"])
        rc, out, err = correr(en, ["--crear-issue", "dependabot:S4"])
        assert rc == 0, err
        assert "type=chore variant=none" in out and "menor-ejemplo" in out and "id=S4" in out
        assert "paquete-ejemplo" not in out, "el chore agrupado solo recoge las S4"
        for p in re.findall(r"borrador conservado para inspección: ([^\s)]+)", err):
            Path(p).unlink()


def c4_fallos():
    casos = [
        ("403", (1, "gh: Dependabot alerts are disabled for this repository. (HTTP 403)"), "SUPERFICIE-NO-VIGILADA dependabot"),
        ("404", (1, "gh: Not Found (HTTP 404)"), "SUPERFICIE-NO-VIGILADA dependabot"),
        ("401", (1, "gh: Bad credentials (HTTP 401)"), "FUENTE-FALLIDA dependabot"),
        ("red", (1, "error connecting to api.github.com"), "FUENTE-FALLIDA dependabot"),
    ]
    for nombre, (rc_gh, err_gh), esperado in casos:
        with tempfile.TemporaryDirectory() as td:
            en = Entorno(td)
            en.ponr(copy.deepcopy(DATOS), {"dependabot": (rc_gh, err_gh)})
            rc, out, err = correr(en, ["--json"])
            assert rc == 3 and esperado in err and out.strip() == "", (nombre, rc, out, err)
            assert not en.cursor.exists(), "un fallo no persiste cursor"
    for nombre, cuerpo in (("objeto", "{}"), ("json roto", "[{"), ("vacío", ""), ("elementos no objeto", "[1,2]")):
        with tempfile.TemporaryDirectory() as td:
            en = Entorno(td)
            d = copy.deepcopy(DATOS)
            d["code-scanning"] = cuerpo
            en.ponr(d)
            rc, out, err = correr(en, ["--json"])
            assert rc == 3 and "FUENTE-FALLIDA code-scanning" in err and out.strip() == "", (nombre, rc, err)
    with tempfile.TemporaryDirectory() as td:   # gh ausente
        en = Entorno(td)
        (en.t / "vacio").mkdir()
        en.extra_env["PATH"] = str(en.t / "vacio")     # sin gh en el PATH, ni el del sistema
        rc, out, err = correr(en, [])
        assert rc == 3 and "FUENTE-FALLIDA" in err
    with tempfile.TemporaryDirectory() as td:   # superficie fuera de la lista: impresa SIEMPRE como no vigilada
        en = Entorno(td)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "dependabot,code-scanning,secret-scanning"
        rc, out, err = correr(en, [])
        assert rc == 0 and "NO VIGILADAS" in out and "advisories" in out, out
        rc, out, err = correr(en, [])    # silencio de novedades, pero la no vigilada sigue impresa
        assert "NO VIGILADAS" in out and "GITHUB-SEGURIDAD" not in out, out
        assert not any("security-advisories" in r["argv"][-1] for r in en.log_gh())


def c5_paginacion():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        d = copy.deepcopy(DATOS)
        pagina1 = d["dependabot"][:2]
        pagina2 = [d["dependabot"][1], d["dependabot"][2]]      # #2 duplicada entre páginas
        d["dependabot"] = json.dumps(pagina1) + "\n" + json.dumps(pagina2)
        en.ponr(d)
        rc, j, _, err = barrer(en)
        assert rc == 0 and j["superficies"]["dependabot"]["abiertas"] == 3, (rc, err)
        assert all("--paginate" in r["argv"] for r in en.log_gh())
    with tempfile.TemporaryDirectory() as td:    # tope por elementos
        en = Entorno(td)
        d = copy.deepcopy(DATOS)
        d["dependabot"] = [dict(copy.deepcopy(DATOS["dependabot"][0]), number=n) for n in range(1, 6)]
        en.ponr(d)
        with mock.patch.object(gs, "TOPE_PAGINAS", 1), mock.patch.object(gs, "POR_PAGINA", 3):
            rc, out, err = correr(en, ["--json"])
        assert rc == 3 and "tope" in err and out.strip() == "", (rc, err)
    with tempfile.TemporaryDirectory() as td:    # tope por páginas
        en = Entorno(td)
        d = copy.deepcopy(DATOS)
        d["advisories"] = "\n".join(json.dumps([]) for _ in range(3))
        en.ponr(d)
        with mock.patch.object(gs, "TOPE_PAGINAS", 2):
            rc, out, err = correr(en, ["--json"])
        assert rc == 3 and "tope" in err, (rc, err)


def dups_por_marcador(term):
    if "vigia-github-identity" in term:
        return [{"identifier": "ABC-9", "title": "otra cosa", "state": {"name": "Todo"}}]
    return []


def c6_dedupe(modulo=gs):
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:1")
        en.linear["dups"] = dups_por_marcador
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo],
                              modulo=modulo)
        assert rc == 2 and "DEDUPE" in err and "ABC-9" in err, (rc, err)
        assert not en.linear.get("creates"), "con el marcador ya en una issue no cerrada no se crea"
        assert any("vigia-github-identity superficie=dependabot id=1 repo=" + REPO in b for b in en.linear["busquedas"])
    with tempfile.TemporaryDirectory() as td:    # por título normalizado
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:1")
        en.linear["dups"] = lambda t: ([{"identifier": "ABC-8", "title": "t", "state": {"name": "Todo"}}]
                                       if t.startswith("Corregir alerta de dependabot 1") else [])
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo],
                              modulo=modulo)
        assert rc == 2 and not en.linear.get("creates"), (rc, err)


def cuerpo_completado(en, spec, modulo=gs):
    """Body del dry-run con los marcadores JUICIO-OPERADOR completados (lo que hace el operador)."""
    rc, out, err = correr(en, ["--crear-issue", spec], modulo=modulo)
    assert rc == 0, err
    ruta = re.findall(r"borrador conservado para inspección: ([^\s)]+)", err)[-1]
    texto = Path(ruta).read_text()
    texto = re.sub(r"⚠ JUICIO-OPERADOR \[[^\]]+\][^\n]*?`<sha>`", "Completado por la prueba (ver ruta/ejemplo.txt)", texto)
    Path(ruta).write_text(texto)
    en.linear.clear()
    return ruta


def c7_fallos_de_creacion():
    with tempfile.TemporaryDirectory() as td:    # consulta de dedupe fallida
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:1")
        en.linear["busqueda_falla"] = True
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo])
        assert rc != 0 and not en.linear.get("creates"), (rc, err)
    with tempfile.TemporaryDirectory() as td:    # audit-issue distinto de 0
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:1")
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo], audit_rc=1)
        assert rc != 0 and "audit-issue FALLÓ" in err and not en.linear.get("creates"), (rc, err)
        assert not en.linear.get("busquedas"), "sin audit verde no se consulta ni se crea"
    with tempfile.TemporaryDirectory() as td:    # body sin completar: el gate real exige completarlo
        en = Entorno(td)
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply"], audit_rc=1)
        assert rc != 0 and not en.linear.get("creates")


def c7_create_sin_reintento(modulo=gs, ci_mod=None):
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:1")
        en.linear["create_error"] = True
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo],
                              modulo=modulo, ci_mod=ci_mod)
        assert rc != 0, (rc, err)
        assert len(en.linear.get("creates", [])) == 1, f"issueCreate se reintentó: {len(en.linear.get('creates', []))}"


def c7_creacion_ok():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "secret-scanning:7")
        rc, out, err = correr(en, ["--crear-issue", "secret-scanning:7", "--apply", "--body-file", cuerpo])
        assert rc == 0 and "CREADA: ABC-1" in out, (rc, out, err)
        assert len(en.linear["creates"]) == 1
        desc = en.linear["creates"][0]["variables"]["desc"]
        assert "vigia-github-identity superficie=secret-scanning id=7 repo=" + REPO in desc
        sin_fugas(out, err, json.dumps(en.linear["creates"]), desc)


def c8_dry_run_por_defecto():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1"])
        assert rc == 0 and "DRY-RUN" in out and "NO se creó nada" in out, (rc, out)
        assert not en.linear.get("creates")
        ruta = re.findall(r"borrador conservado para inspección: ([^\s)]+)", err)[-1]
        assert Path(ruta).is_file(), "el temporal se conserva"
        assert "JUICIO-OPERADOR" in out, "el generador no fabrica juicio humano"
        Path(ruta).unlink()


def c8_identidad_cruzada():
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        cuerpo = cuerpo_completado(en, "dependabot:2")       # body de OTRA alerta
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo])
        assert rc != 0 and "marcador de identidad" in err and not en.linear.get("creates"), (rc, err)


def c_config():
    with tempfile.TemporaryDirectory() as td:
        for nombre, cambio in (
            ("repo ausente", lambda en: en.extra_env.update(GITHUB_SEC_REPO=None)),
            ("repo inválido", lambda en: en.extra_env.update(GITHUB_SEC_REPO="sin-barra")),
            ("superficie inválida", lambda en: en.extra_env.update(GITHUB_SEC_SUPERFICIES="dependabot,inventada")),
            ("header 0644", lambda en: en.hdr.chmod(0o644)),
            ("header ausente", lambda en: en.hdr.unlink()),
            ("header otra cabecera", lambda en: (en.hdr.write_text("X-Otra: 1\n"), en.hdr.chmod(0o600))),
        ):
            en = Entorno(Path(td) / re.sub(r"\W", "_", nombre))
            cambio(en)
            rc, out, err = correr(en, [])
            assert rc == 1 and not en.log_gh(), (nombre, rc, err)
            sin_fugas(out, err)


def c_solo_lectura_en_codigo():
    fuente = (SCRIPTS / "github_seguridad.py").read_text()
    for prohibido in ('"POST"', '"PATCH"', '"PUT"', '"DELETE"', '"--input"', '"-f"', '"-F"', "--field"):
        assert prohibido not in fuente, prohibido


def cadenas(dato):
    """Todas las cadenas de una estructura decodificada (claves incluidas)."""
    if isinstance(dato, str):
        yield dato
    elif isinstance(dato, dict):
        for k, v in dato.items():
            yield from cadenas(k)
            yield from cadenas(v)
    elif isinstance(dato, (list, tuple)):
        for x in dato:
            yield from cadenas(x)


def formas(secreto):
    """El literal y sus representaciones saneada (una línea) y escapada como JSON."""
    return {secreto, " ".join(secreto.split()), gs.limpio(secreto, len(secreto) + 1),
            json.dumps(secreto)[1:-1], json.dumps(secreto, ensure_ascii=False)[1:-1]}


def sin_secreto(secreto, etiqueta, *textos):
    for t in textos:
        for forma in formas(secreto):
            assert forma not in t, f"fuga ({etiqueta}): {forma!r} en {t[:160]!r}"


SECRETOS_RESIDUALES = (
    ("comillas y barra", 'SINTETICO-\\-"-FIN'),
    ("multilínea", "SINTETICO-INICIO\nSEGUNDA-LINEA"),
    ("corto (3)", "XYZ"),
    ("muy corto (2)", "zq"),
    ("ASCII largo", "SINTETICO-ASCII-LARGO"),
    ("backticks y marcador HTML", "SIN`TE<!--TI-->CO"),
)


def regresion_secreto(secreto, modulo=gs):
    """El `secret` reflejado en un campo no confiable (secret_type_display_name) no sale por NINGÚN canal:
    stdout (texto y JSON decodificado), stderr, cursor, borrador, título y body de issueCreate, búsquedas de
    dedupe y todo el tráfico a Linear, comprobado sobre el literal Y sobre sus formas saneada y escapada."""
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        datos = copy.deepcopy(DATOS)
        alerta = datos["secret-scanning"][0]
        alerta["secret"] = secreto
        alerta["secret_type_display_name"] = secreto
        en.ponr(datos)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
        # 1) barrido JSON: texto y estructura decodificada
        rc, out, err = correr(en, ["--json"], modulo=modulo)
        assert rc == 0, err
        decod = json.loads(out)
        sin_secreto(secreto, "json texto", out, err)
        sin_secreto(secreto, "json decodificado", *cadenas(decod))
        sin_secreto(secreto, "cursor", en.cursor.read_text())
        # 2) barrido de texto
        rc, out, err = correr(en, [], modulo=modulo)
        assert rc == 0, err
        sin_secreto(secreto, "stdout texto", out, err)
        # 3) dry-run: stdout, stderr y borrador conservado
        rc, out, err = correr(en, ["--crear-issue", "secret-scanning:7"], modulo=modulo)
        assert rc == 0, err
        sin_secreto(secreto, "dry-run", out, err)
        rutas = re.findall(r"borrador conservado para inspección: ([^\s)]+)", err)
        assert rutas
        for ruta in rutas:
            sin_secreto(secreto, "borrador", Path(ruta).read_text())
        # 4) apply: payload de issueCreate (título y descripción) y todo el tráfico a Linear
        cuerpo = cuerpo_completado(en, "secret-scanning:7", modulo=modulo)
        sin_secreto(secreto, "borrador completado", Path(cuerpo).read_text())
        rc, out, err = correr(en, ["--crear-issue", "secret-scanning:7", "--apply", "--body-file", cuerpo], modulo=modulo)
        assert rc == 0, (rc, err)
        creates = en.linear.get("creates", [])
        assert len(creates) == 1, len(creates)
        sin_secreto(secreto, "stdout apply", out, err)
        v = creates[0]["variables"]
        sin_secreto(secreto, "título de issueCreate", v["t"])
        sin_secreto(secreto, "descripción de issueCreate", v["desc"])
        for peticion in en.linear["peticiones"]:
            sin_secreto(secreto, "tráfico a Linear (texto)", json.dumps(peticion))
            sin_secreto(secreto, "tráfico a Linear (decodificado)", *cadenas(peticion))
        for q in en.linear.get("busquedas", []):
            sin_secreto(secreto, "búsqueda de dedupe", q)
        assert "[OCULTO]" in v["t"] or "[OCULTO]" in v["desc"], "el valor debe aparecer enmascarado, no omitido"
        escrituras(en)


def c_secretos_variantes(modulo=gs):
    for nombre, secreto in SECRETOS_RESIDUALES:
        try:
            regresion_secreto(secreto, modulo)
        except AssertionError as e:
            raise AssertionError(f"{nombre}: {e}") from None


def contiene_forma(secreto, texto):
    return any(f in texto for f in formas(secreto))


def c_creacion_cruzada(modulo=gs):
    """El secreto de secret scanning se refleja en Dependabot; se crea la issue de Dependabot con ambas
    declaradas. El registro de TODAS las superficies debe ocurrir antes de construir o emitir la creación."""
    secreto = "CREDENCIAL-CRUZADA-SINTETICA"
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        datos = copy.deepcopy(DATOS)
        datos["secret-scanning"][0]["secret"] = secreto
        datos["dependabot"][0]["security_advisory"]["summary"] = secreto
        en.ponr(datos)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "dependabot,secret-scanning"
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1"], modulo=modulo)
        assert rc == 0, ("dry-run", rc, err)
        rutas = re.findall(r"borrador conservado para inspección: ([^\s)]+)", err)
        assert rutas, "sin borrador: etapa no ejecutada"
        sin_secreto(secreto, "cruzada: stdout/stderr del dry-run", out, err)
        sin_secreto(secreto, "cruzada: borrador", *[Path(p).read_text() for p in rutas])
        cuerpo = cuerpo_completado(en, "dependabot:1", modulo=modulo)
        en.linear.clear()
        rc, out, err = correr(en, ["--crear-issue", "dependabot:1", "--apply", "--body-file", cuerpo], modulo=modulo)
        assert rc == 0, ("apply", rc, err)
        creates = en.linear.get("creates", [])
        assert len(creates) == 1, len(creates)
        sin_secreto(secreto, "cruzada: stdout/stderr del apply", out, err)
        sin_secreto(secreto, "cruzada: payload de issueCreate", json.dumps(creates), *cadenas(creates))
        sin_secreto(secreto, "cruzada: tráfico a Linear", *cadenas(en.linear.get("peticiones", [])))
        escrituras(en)


CLAVES_JSON = {"superficies", "nuevos", "escala", "no_vigiladas", "total_abiertas"}


def c_secretos_cortos_no_alteran_decisiones(modulo=gs):
    """Secretos de 1, 2 y 3 caracteres que colisionan con `state` ('open') y con las claves del JSON: la
    alerta SIGUE contando como abierta (jamás «0 alertas» con rc 0), el esquema conserva sus cinco claves y
    el vocabulario cerrado, y los textos libres salen enmascarados."""
    for secreto in ("e", "op", "pen"):
        with tempfile.TemporaryDirectory() as td:
            en = Entorno(td)
            en.ponr({"secret-scanning": [dict(DATOS["secret-scanning"][0], secret=secreto)]})
            en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
            rc, out, err = correr(en, ["--json"], modulo=modulo)
            assert rc == 0, (secreto, rc, err)
            doc = json.loads(out)
            assert set(doc) == CLAVES_JSON, (secreto, sorted(doc))
            assert set(doc["superficies"]) == {"secret-scanning"} and doc["no_vigiladas"] == [
                "dependabot", "code-scanning", "advisories"], (secreto, doc["superficies"], doc["no_vigiladas"])
            assert doc["superficies"]["secret-scanning"]["abiertas"] == 1, (secreto, doc["superficies"])
            assert doc["total_abiertas"] == 1 and len(doc["nuevos"]) == 1, (secreto, doc)
            n = doc["nuevos"][0]
            assert (n["superficie"], n["id"], n["nivel"], n["severidad"], n["tipo"], n["variante"]) == (
                "secret-scanning", "7", "S1", "secret", "fix", "seguridad"), (secreto, n)
            cur = json.loads(en.cursor.read_text())
            assert cur["superficies"]["secret-scanning"]["total"] == 1, (secreto, cur)
            for libre in (n["titulo"], n["url"]):
                assert secreto not in libre, (secreto, "texto libre sin enmascarar", libre)
            # el informe de texto también cuenta la alerta
            rc, out, err = correr(en, [], modulo=modulo)
            assert rc == 0, (secreto, rc, err)
            en.cursor.unlink()
            rc, out, err = correr(en, [], modulo=modulo)
            assert rc == 0 and "GITHUB-SEGURIDAD" in out and "abiertas=1" in out, (secreto, out, err)
            escrituras(en)


def c_colision_con_identidad(modulo=gs):
    """Si el secreto coincide con el identificador de una alerta abierta no se puede exponer sin alterar el
    contrato: aborta con rc != 0, sin informe y sin persistir cursor (jamás calma falsa)."""
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        en.ponr({"secret-scanning": [dict(DATOS["secret-scanning"][0], secret="7")]})
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
        rc, out, err = correr(en, ["--json"], modulo=modulo)
        assert rc == 3 and out.strip() == "" and not en.cursor.exists(), (rc, out, err)
        assert "FUENTE-FALLIDA secret-scanning" in err and "identificador" in err, err


def c_error_reflejado_del_helper(modulo=gs):
    """El cuerpo de un error de Linear que refleja el secreto (dedupe_linear -> die) no se imprime: pasa por
    el mismo enmascarado. Se conserva el fallo (rc != 0) y no se crea nada."""
    global linear_doble
    secreto = "CREDENCIAL-ERROR-SINTETICA"
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        datos = copy.deepcopy(DATOS)
        datos["secret-scanning"][0]["secret"] = secreto
        en.ponr(datos)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
        anterior = linear_doble
        linear_doble = lambda estado: lambda req, **kw: Respuesta({"errors": [{"message": secreto}]})  # noqa: E731
        try:
            rc, out, err = correr(en, ["--crear-issue", "secret-scanning:7"], modulo=modulo)
        finally:
            linear_doble = anterior
        assert rc != 0, (rc, err)
        assert "dedupe" in err and "fail-closed" in err, "el fallo del helper debe seguir siendo explícito"
        sin_secreto(secreto, "error del helper", out, err)
        assert not en.linear.get("creates")
        for p in re.findall(r"borrador conservado para inspección: ([^\s)]+)", err):
            Path(p).unlink(missing_ok=True)


def c9_rutas():
    # 1) instalación en skills/ SIN .claude/
    with tempfile.TemporaryDirectory() as td:
        raiz = Path(td).resolve() / "paquete"
        copiar_skills(raiz / "skills")
        (raiz / "scripts").mkdir(); (raiz / "scripts/tsx.sh").write_text("")   # el envoltorio de tsx vive en <raíz>/scripts (issue 9564)
        m = cargar(raiz / "skills/talent-sentry-guard/scripts/crear_issue_desde_sentry.py", "ci_paquete")
        assert m.TSX_SH == raiz / "scripts/tsx.sh"
        assert m.TEMPLATES_DIR == raiz / "skills/talent-issue-craft/templates"
        assert m.AUDIT_HELPER == raiz / "skills/talent-issue-craft/scripts/issue_craft_helper.ts"
        assert m.cargar_plantilla("fix").startswith("# {Imperativo}") or "# {Imperativo}" in m.cargar_plantilla("fix")
        body = m.construir_body({"shortId": "ABC-1", "title": "t"}, "spike-auditoria", "none", "app@12345678", "3h")
        for esperado in ("skills/talent-sentry-guard/scripts/sentry_doctor.sh",
                         "skills/talent-sentry-guard/scripts/sentry_triage.py",
                         "skills/talent-sentry-guard/references/02-taxonomia-triage.md"):
            assert "`" + esperado in body or " " + esperado in body, esperado
        assert ".claude/skills" not in body
        with mock.patch("subprocess.run", return_value=completado(0)) as run, contextlib.redirect_stderr(io.StringIO()):
            m.correr_audit(Path(td) / "x.md")
        assert run.call_args.kwargs["cwd"] == str(raiz / "skills/talent-issue-craft"), run.call_args
    # 2) instalación en .claude/skills/ (el layout histórico)
    with tempfile.TemporaryDirectory() as td:
        raiz = Path(td).resolve() / "repo"
        copiar_skills(raiz / ".claude/skills")
        m = cargar(raiz / ".claude/skills/talent-sentry-guard/scripts/crear_issue_desde_sentry.py", "ci_claude")
        assert m.REPO_ROOT == raiz and m.TEMPLATES_DIR.is_dir() and m.AUDIT_HELPER.is_file() and m.TSX_SH == raiz / "scripts/tsx.sh"
        body = m.construir_body({"shortId": "ABC-1", "title": "t"}, "spike-auditoria", "none", "app@12345678", "3h")
        assert ".claude/skills/talent-sentry-guard/scripts/sentry_doctor.sh" in body
    # 3) sin issue-craft: die nombrando la ruta
    with tempfile.TemporaryDirectory() as td:
        raiz = Path(td).resolve() / "paquete"
        copiar_skills(raiz / "skills", con_issue_craft=False)
        m = cargar(raiz / "skills/talent-sentry-guard/scripts/crear_issue_desde_sentry.py", "ci_sin_craft")
        for fn, ruta in ((lambda: m.cargar_plantilla("fix"), m.TEMPLATES_DIR / "02-fix.md"),
                         (lambda: m.correr_audit(Path(td) / "x.md"), m.AUDIT_HELPER)):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = salir(fn)
            assert rc == 1 and str(ruta) in err.getvalue(), (rc, err.getvalue())


def copiar_skills(destino, con_issue_craft=True):
    shutil.copytree(SCRIPTS, destino / "talent-sentry-guard/scripts",
                    ignore=shutil.ignore_patterns("__pycache__", "test-*"))
    if con_issue_craft:
        shutil.copytree(SKILLS / "talent-issue-craft", destino / "talent-issue-craft",
                        ignore=shutil.ignore_patterns("examples", "references", "__pycache__"))


def c_audit_real():
    """El body con los marcadores completados pasa audit-issue (rc 0). Motor: `npx tsx` (base declarada) o,
    si no está, node con --experimental-transform-types cuando el node del entorno lo soporta; sin ninguno
    de los dos, NO EJECUTADO con motivo y contado aparte (nunca PASS)."""
    global NO_EJECUTADOS
    helper = SKILLS / "talent-issue-craft/scripts/issue_craft_helper.ts"
    cwd = str(helper.parent.parent)

    def motor():
        with tempfile.TemporaryDirectory() as td:
            sonda = Path(td) / "sonda.md"
            sonda.write_text("<!-- issue-craft:v1 type=chore variant=none madurez=despachable -->\n\n# Sonda\n")
            for prefijo in (["npx", "--no-install", "tsx"], ["node", "--experimental-transform-types", "--no-warnings"]):
                if not shutil.which(prefijo[0]):
                    continue
                r = subprocess.run(prefijo + [str(helper), "--action", "audit-issue", "--file", str(sonda)],
                                   capture_output=True, text=True, cwd=cwd)
                if "--- resumen ---" in r.stdout or "[DURO" in r.stdout:    # el motor arrancó (aunque dé FAIL)
                    return prefijo
        return None

    prefijo = motor()
    if prefijo is None:
        NO_EJECUTADOS += 1
        print("NO-EJECUTADO audit-issue real: ni tsx ni node con transform-types disponibles en esta base (motivo declarado, contado aparte)")
        return

    def caso(spec):
        with tempfile.TemporaryDirectory() as td:
            en = Entorno(td)
            cuerpo = cuerpo_completado(en, spec)
            r = subprocess.run(prefijo + [str(helper), "--action", "audit-issue", "--file", cuerpo],
                               capture_output=True, text=True, cwd=cwd)
            assert r.returncode == 0, r.stdout[-800:]
    for spec in ("dependabot:1", "secret-scanning:7", "code-scanning:4", "advisories:GHSA-mmmm-nnnn-oooo",
                 "dependabot:2", "dependabot:S4"):
        esperar(f"audit-issue real ({prefijo[0]}) sobre el body completado de {spec}", lambda s=spec: caso(s))


# ── mutantes ───────────────────────────────────────────────────────────────────────────────────
def mutante(ruta, original, reemplazo, nombre, cargar_ci_real=True):
    pares = original if isinstance(original, list) else [(original, reemplazo)]
    fuente = Path(ruta).read_text()
    for o, r in pares:
        assert fuente.count(o) == 1, f"{nombre}: el original aparece {fuente.count(o)} veces: {o[:60]!r}"
        fuente = fuente.replace(o, r)
    m = types.ModuleType(nombre)
    m.__file__ = str(ruta)
    exec(compile(fuente, str(ruta), "exec"), m.__dict__)
    return m


def probar_mutante(numero, descripcion, caso_verde, caso_mutado):
    """caso_verde() debe pasar con el original; caso_mutado() debe FALLAR con el defecto."""
    global PASS, FAIL
    try:
        caso_verde()
        try:
            caso_mutado()
        except AssertionError:
            pass
        else:
            raise AssertionError("el mutante no puso ROJO su caso")
        caso_verde()
        print(f"PASS MUTANTE-{numero}: {descripcion}: original VERDE; defecto ROJO; revertido VERDE")
        PASS += 1
    except Exception as e:  # noqa: BLE001
        print(f"FAIL MUTANTE-{numero}: {descripcion}: {type(e).__name__}: {e}")
        FAIL += 1


def main():
    esperar("C1 secret scanning S1, hide_secret, sin fugas, solo GET", c1_secret)
    esperar("C1 body de secret sin el valor del secreto", c1_cuerpo_sin_secreto)
    esperar("C2 NUEVOS la primera vez, silencio después, ESCALA por severidad y por abiertas", c2_nuevos_y_escala)
    esperar("C3 S4 contada y no listada; chore agrupado", c3_s4_contada_no_listada)
    esperar("C4 superficie desactivada, 401, red, no lista, gh ausente: rc 3, nunca 0 alertas", c4_fallos)
    esperar("C5 paginación sin duplicados y con tope fail-closed", c5_paginacion)
    esperar("C6 dedupe por marcador y por título: rc 2 sin crear", c6_dedupe)
    esperar("C7 dedupe caído o audit distinto de 0: no crea", c7_fallos_de_creacion)
    esperar("C7 issueCreate no se reintenta", c7_create_sin_reintento)
    esperar("C7 creación correcta desde un body completado", c7_creacion_ok)
    esperar("C8 dry-run por defecto: imprime, conserva el temporal, no crea", c8_dry_run_por_defecto)
    esperar("C8 body de otra alerta (identidad cruzada) rechazado", c8_identidad_cruzada)
    esperar("config: repo/superficies/header inválidos mueren antes de llamar a gh", c_config)
    esperar("invariante: ninguna escritura posible en el código", c_solo_lectura_en_codigo)
    esperar("C9 rutas de issue-craft en skills/, en .claude/skills/ y ausentes", c9_rutas)
    c_audit_real()

    gh = SCRIPTS / "github_seguridad.py"
    probar_mutante(1, "retirar hide_secret", c1_secret, lambda: c1_secret_con(mutante(
        gh, '"state=open&per_page=100&hide_secret=true"', '"state=open&per_page=100"', "mut_hide")))
    probar_mutante(2, "retirar el dedupe por marcador", c6_dedupe, lambda: c6_dedupe(mutante(
        gh, 'dups = ci.dedupe_linear(termino_identidad(superficie, ident, repo) + " -->", titulo, api_key)',
        'dups = ci.dedupe_linear(titulo, titulo, api_key)', "mut_dedupe")))
    ci_ruta = SCRIPTS / "crear_issue_desde_sentry.py"
    ci_mut = mutante(ci_ruta, "res = linear_gql(api_key, mut, variables, retry=False)",
                     "res = linear_gql(api_key, mut, variables, retry=True)", "mut_ci_retry")
    probar_mutante(3, "reintentar issueCreate", c7_create_sin_reintento, lambda: c7_create_sin_reintento(ci_mod=ci_mut))
    # Confidencialidad: se enmascara la SALIDA (título, URL, detalle, payload, helpers), nunca los datos con
    # los que se cuenta y se decide.
    esperar("secretos con comillas, barra, multilínea, 1-3 caracteres y backticks: 0 fugas en todos los canales",
            c_secretos_variantes)
    esperar("creación cruzada: el secreto de otra superficie declarada no sale (borrador y payload)", c_creacion_cruzada)
    esperar("secretos de 1-3 caracteres que colisionan con state y claves: la alerta sigue abierta y el esquema íntegro",
            c_secretos_cortos_no_alteran_decisiones)
    esperar("secreto que coincide con el identificador: rc 3, sin informe ni cursor", c_colision_con_identidad)
    esperar("error de Linear que refleja el secreto: no se imprime y el fallo se conserva", c_error_reflejado_del_helper)
    ant_registro = ('    for forma in {valor, " ".join(valor.split()), limpio(valor, len(valor) + 1),\n'
                    '                  json.dumps(valor)[1:-1], json.dumps(valor, ensure_ascii=False)[1:-1]}:')
    despues_de_sanear = [   # comportamiento antiguo: solo el literal (mínimo 4) y sobre el texto ya saneado
        ('    return ocultar(limpio(ocultar(str(valor if valor is not None else "")), tope))',
         '    return ocultar(limpio(str(valor if valor is not None else ""), tope))'),
        ("if not isinstance(valor, str) or not valor:", "if not isinstance(valor, str) or len(valor) < 4:"),
        (ant_registro, "    for forma in {valor}:"),
    ]
    mut_a = mutante(gh, despues_de_sanear, None, "mut_despues")
    probar_mutante(5, "enmascarar DESPUÉS de sanear, solo el literal", c_secretos_variantes,
                   lambda: c_secretos_variantes(mut_a))
    sin_titulo = [      # el título deja de enmascararse; el resto sí
        ('        return exponer(a.get("secret_type_display_name") or a.get("secret_type") or "secreto expuesto")',
         '        return limpio(a.get("secret_type_display_name") or a.get("secret_type") or "secreto expuesto")'),
    ]
    mut_b = mutante(gh, sin_titulo, None, "mut_titulo")
    probar_mutante(6, "quitar el enmascarado del título", c_secretos_variantes, lambda: c_secretos_variantes(mut_b))
    mut_c = mutante(gh, "no «sin alertas».\n    actual, fallos = barrer(repo, superficies, token)\n",
                    "no «sin alertas».\n    actual, fallos = barrer(repo, [superficie], token)\n", "mut_otras_superficies")
    probar_mutante(7, "crear sin registrar las otras superficies declaradas", c_creacion_cruzada,
                   lambda: c_creacion_cruzada(mut_c))
    mut_d = mutante(gh, "        if not es_abierta(superficie, a):\n            continue\n        ident = identidad(superficie, a)",
                    "        if not es_abierta(superficie, {k: (ocultar(v) if isinstance(v, str) else v) for k, v in a.items()}):\n"
                    "            continue\n        ident = identidad(superficie, a)", "mut_estado_enmascarado")
    probar_mutante(8, "enmascarar el estado antes de decidir si está abierta", c_secretos_cortos_no_alteran_decisiones,
                   lambda: c_secretos_cortos_no_alteran_decisiones(mut_d))
    mut_e = mutante(gh, '                print(ocultar(buf.getvalue()), end="", file=destino)',
                    '                print(buf.getvalue(), end="", file=destino)', "mut_helper_sin_mascara")
    probar_mutante(9, "imprimir la salida del helper sin enmascarar", c_error_reflejado_del_helper,
                   lambda: c_error_reflejado_del_helper(mut_e))
    print(f"RESULTADO: PASS={PASS} FAIL={FAIL} NO-EJECUTADOS-MOTIVADOS={NO_EJECUTADOS}")
    return int(FAIL > 0)


def c1_secret_con(modulo):
    """Mismo caso C1 contra un módulo mutado: la petición ya no lleva hide_secret."""
    with tempfile.TemporaryDirectory() as td:
        en = Entorno(td)
        rc, out, err = correr(en, ["--json"], modulo=modulo)
        ss = [r for r in en.log_gh() if "secret-scanning/alerts" in r["argv"][-1]]
        assert ss and "hide_secret=true" in ss[0]["argv"][-1], "la petición debe llevar hide_secret=true"


if __name__ == "__main__":
    sys.exit(main())
