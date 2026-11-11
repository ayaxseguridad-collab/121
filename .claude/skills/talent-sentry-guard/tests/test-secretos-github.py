#!/usr/bin/env python3
"""Sonda PERMANENTE de confidencialidad de github_seguridad.py (INV-SG-011).

Reproduce la sonda del revisor: el `secret` de una alerta de secret scanning se refleja en un campo no
confiable (`secret_type_display_name`), que entra en el título de la issue. Cuatro variantes del valor:
comillas y barra, multilínea, corto (3 caracteres) y ASCII. Por cada una se mide:
  1. barrido --json: stdout, stderr, JSON DECODIFICADO (incluido el título de NUEVOS) y cursor;
  2. dry-run de --crear-issue: stdout, stderr y body del borrador;
  3. --apply: título y body del payload de issueCreate y todo el tráfico a Linear (texto y decodificado).
Cada comprobación busca el literal Y sus formas saneada (una línea, sin backticks) y escapada como JSON.
Solo dobles (gh por gh_contrato, Linear por urllib): ninguna red, ningún GitHub ni Linear reales.
Salida: una línea por comprobación y `RESULTADO: FALLOS_CONFIDENCIALIDAD=<n>`; rc 0 solo con n = 0.
"""
import copy
import importlib.util
import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("test_github_seguridad", HERE / "test-github-seguridad.py")
t = importlib.util.module_from_spec(spec)
sys.modules["test_github_seguridad"] = t
spec.loader.exec_module(t)

VARIANTES = (
    ("especial_JSON", 'SINTETICO-\\-"-FIN'),
    ("multilinea", "SINTETICO-INICIO\nSEGUNDA-LINEA"),
    ("corto", "XYZ"),
    ("ASCII", "SINTETICO-ASCII"),
)
fallos = 0
comprobaciones = 0


def medir(nombre, etapa, secreto, *textos):
    """Una línea por comprobación; cuenta una fuga si alguna forma del secreto aparece en algún texto."""
    global fallos, comprobaciones
    comprobaciones += 1
    try:
        t.sin_secreto(secreto, etapa, *textos)
        fuga = 0
    except AssertionError as e:
        fuga = 1
        print(f"  detalle: {e}")
    fallos += fuga
    print(f"{nombre}: {etapa} fuga={fuga}")


def exigir(nombre, etapa, condicion, detalle=""):
    """Una etapa que no se ejecuta o que no sale con el rc esperado es un FALLO, nunca un silencio."""
    global fallos, comprobaciones
    comprobaciones += 1
    fallos += int(not condicion)
    print(f"{nombre}: {etapa} {'ok' if condicion else 'FALLO'} {detalle}".rstrip())


def escenario(nombre, funcion):
    """Escenario del test de regresión (cruzada, secretos cortos, colisión, error del helper)."""
    global fallos, comprobaciones
    comprobaciones += 1
    try:
        funcion()
        print(f"{nombre}: ok")
    except AssertionError as e:
        fallos += 1
        print(f"{nombre}: FALLO {str(e)[:300]}")


def variante(nombre, secreto):
    global fallos
    with tempfile.TemporaryDirectory() as td:
        en = t.Entorno(td)
        datos = copy.deepcopy(t.DATOS)
        alerta = datos["secret-scanning"][0]
        alerta["secret"] = secreto
        alerta["secret_type_display_name"] = secreto
        en.ponr(datos)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"

        rc, out, err = t.correr(en, ["--json"])
        exigir(nombre, "barrido --json rc=0", rc == 0, f"(rc={rc})")
        decod = json.loads(out) if rc == 0 and out.strip() else {}
        medir(nombre, f"json(rc={rc}): stdout, stderr y cursor", secreto, out, err,
              en.cursor.read_text() if en.cursor.exists() else "")
        medir(nombre, "json decodificado (titulo de NUEVOS incluido)", secreto, *t.cadenas(decod))

        rc, out, err = t.correr(en, ["--crear-issue", "secret-scanning:7"])
        rutas = re.findall(r"borrador conservado para inspección: ([^\s)]+)", err)
        medir(nombre, f"dry-run(rc={rc}): stdout y stderr", secreto, out, err)
        medir(nombre, "dry-run: body del borrador", secreto, *[Path(p).read_text() for p in rutas])
        exigir(nombre, "dry-run rc=0", rc == 0, f"(rc={rc})")
        exigir(nombre, "dry-run dejó borrador (la etapa de apply se ejecuta)", bool(rutas))
        if not rutas:
            return

        cuerpo = rutas[0]
        texto = re.sub(r"⚠ JUICIO-OPERADOR \[[^\]]+\][^\n]*?`<sha>`", "Completado por la sonda", Path(cuerpo).read_text())
        Path(cuerpo).write_text(texto)
        en.linear.clear()
        rc, out, err = t.correr(en, ["--crear-issue", "secret-scanning:7", "--apply", "--body-file", cuerpo])
        creates = en.linear.get("creates", [])
        medir(nombre, f"apply(rc={rc}, issueCreate={len(creates)}): stdout y stderr", secreto, out, err)
        medir(nombre, "apply: titulo del payload de issueCreate", secreto, *[c["variables"]["t"] for c in creates])
        medir(nombre, "apply: body del payload de issueCreate", secreto, *[c["variables"]["desc"] for c in creates])
        medir(nombre, "apply: todo el tráfico a Linear (texto y decodificado)", secreto,
              *[json.dumps(p) for p in en.linear.get("peticiones", [])],
              *[c for p in en.linear.get("peticiones", []) for c in t.cadenas(p)])
        exigir(nombre, "apply rc=0 y exactamente un issueCreate", rc == 0 and len(creates) == 1,
               f"(rc={rc}, creates={len(creates)})")
        for p in rutas:
            Path(p).unlink(missing_ok=True)
        t.escrituras(en)       # solo GET, token por entorno
        print(f"{nombre}: escrituras_GitHub=0")


def crear_con_retorno(secreto, doble=None):
    """--apply con el secreto registrado y, opcionalmente, un doble de Linear que cambia su respuesta de
    éxito. Devuelve (rc, stdout, stderr, issueCreate enviados): el retorno de la creación es un dato externo."""
    with tempfile.TemporaryDirectory() as td:
        en = t.Entorno(td)
        datos = copy.deepcopy(t.DATOS)
        datos["secret-scanning"][0]["secret"] = secreto
        en.ponr(datos)
        en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
        cuerpo = t.cuerpo_completado(en, "secret-scanning:7")
        anterior = t.linear_doble
        if doble:
            t.linear_doble = doble(anterior)
        try:
            rc, out, err = t.correr(en, ["--crear-issue", "secret-scanning:7", "--apply", "--body-file", cuerpo])
        finally:
            t.linear_doble = anterior
        Path(cuerpo).unlink(missing_ok=True)
        return rc, out, err, en.linear.get("creates", [])


def c_retorno_identificador():
    """El identificador que devuelve Linear (ABC-1) es un secreto registrado: no sale en claro."""
    rc, out, err, creates = crear_con_retorno("ABC-1")
    assert rc == 0 and len(creates) == 1, (rc, len(creates), err)
    t.sin_secreto("ABC-1", "retorno de crear_en_linear (identificador)", out, err)


def c_retorno_url():
    """El secreto viaja dentro de la URL que devuelve Linear: no sale en claro."""
    secreto = "CREDENCIAL-RETORNO-SINTETICA"

    def con_url(original):
        def doble(estado):
            base = original(estado)

            def urlopen(req, **kw):
                r = base(req, **kw)
                if "issueCreate" in json.loads(req.data)["query"]:
                    r.body["data"]["issueCreate"]["issue"]["url"] = "https://example.invalid/" + secreto
                return r
            return urlopen
        return doble
    rc, out, err, creates = crear_con_retorno(secreto, con_url)
    assert rc == 0 and len(creates) == 1, (rc, len(creates), err)
    t.sin_secreto(secreto, "retorno de crear_en_linear (URL)", out, err)


def con_secreto_en_titulo_y_url(td, secreto):
    """Entorno cuya alerta lleva el secreto registrado en el título y en la URL (textos libres de GitHub)."""
    en = t.Entorno(td)
    datos = copy.deepcopy(t.DATOS)
    alerta = datos["secret-scanning"][0]
    alerta["secret"] = secreto
    alerta["secret_type_display_name"] = secreto
    alerta["html_url"] = "https://example.invalid/alerta/" + secreto
    en.ponr(datos)
    en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
    return en


def c_crudo_informe_texto():
    """Sumidero crudo de imprimir_informe (emitir): el título y la URL de la alerta salen enmascarados."""
    for secreto in ("CREDENCIAL-INFORME-SINTETICA", "XYZ"):
        with tempfile.TemporaryDirectory() as td:
            en = con_secreto_en_titulo_y_url(td, secreto)
            rc, out, err = t.correr(en, [])
            assert rc == 0 and "GITHUB-SEGURIDAD" in out and "[OCULTO]" in out, (secreto, rc, out, err)
            t.sin_secreto(secreto, "informe de texto", out, err)


def c_crudo_json():
    """Sumidero crudo del JSON de --json: el esquema se conserva y los textos libres salen enmascarados."""
    for secreto in ("CREDENCIAL-JSON-SINTETICA", "XYZ"):
        with tempfile.TemporaryDirectory() as td:
            en = con_secreto_en_titulo_y_url(td, secreto)
            rc, out, err = t.correr(en, ["--json"])
            assert rc == 0, (secreto, rc, err)
            doc = json.loads(out)
            assert set(doc) == t.CLAVES_JSON and "[OCULTO]" in out, (secreto, sorted(doc))
            t.sin_secreto(secreto, "JSON del barrido", out, err, *t.cadenas(doc))


def c_crudo_dryrun_body():
    """Sumidero crudo del body del dry-run: título, URL y texto del operador (--body-file) enmascarados."""
    secreto = "CREDENCIAL-BORRADOR-SINTETICA"
    with tempfile.TemporaryDirectory() as td:
        en = con_secreto_en_titulo_y_url(td, secreto)
        cuerpo = Path(t.cuerpo_completado(en, "secret-scanning:7"))
        cuerpo.write_text(cuerpo.read_text() + f"\nNota del operador: {secreto}\n")
        rc, out, err = t.correr(en, ["--crear-issue", "secret-scanning:7", "--body-file", str(cuerpo)])
        for p in [cuerpo, *map(Path, re.findall(r"borrador conservado para inspección: ([^\s)]+)", err))]:
            p.unlink(missing_ok=True)
        assert rc == 0 and "DRY-RUN" in out and "[OCULTO]" in out, (rc, out, err)
        t.sin_secreto(secreto, "body del dry-run", out, err)


def entorno_con_repo(td, secreto, repo):
    """Alerta abierta cuyo secreto registrado se compara con el nombre del repositorio configurado."""
    en = t.Entorno(td)
    datos = copy.deepcopy(t.DATOS)
    datos["secret-scanning"][0]["secret"] = secreto
    en.ponr(datos)
    en.extra_env["GITHUB_SEC_SUPERFICIES"] = "secret-scanning"
    en.extra_env["GITHUB_SEC_REPO"] = repo
    return en


CAMINOS_REPO = (
    ("informe de texto", []),
    ("informe JSON", ["--json"]),
    ("crear-issue dry-run", ["--crear-issue", "secret-scanning:7"]),
    ("crear-issue apply", ["--crear-issue", "secret-scanning:7", "--apply", "--body-file", "/inexistente/borrador.md"]),
)


def c_repo_colisiona(secreto, repo):
    """El nombre del repositorio (cabecera del informe, body y marcador de identidad) no puede emitirse si un
    secreto registrado es igual a él o está contenido en él: rc 3, sin informe, sin borrador, sin cursor y
    sin tráfico a Linear. El nombre y el secreto no aparecen en ninguna salida."""
    for camino, argv in CAMINOS_REPO:
        with tempfile.TemporaryDirectory() as td:
            en = entorno_con_repo(td, secreto, repo)
            rc, out, err = t.correr(en, argv)
            assert rc == 3, (camino, rc, out, err)
            assert out.strip() == "", (camino, "informe emitido", out)
            assert "borrador conservado" not in err, (camino, "borrador creado", err)
            assert not en.cursor.exists(), (camino, "cursor persistido")
            assert not en.linear, (camino, "tráfico a Linear", list(en.linear))
            assert "FUENTE-FALLIDA repositorio" in err, (camino, err)
            t.sin_secreto(secreto, camino, out, err)
            t.sin_secreto(repo, camino, out, err)


def c_repo_igual_corto():
    c_repo_colisiona("a/b", "a/b")                 # 3 caracteres: igual al nombre completo, aborta igual


def c_repo_igual_largo():
    c_repo_colisiona("org-ejemplo/repo-secreto", "org-ejemplo/repo-secreto")


def c_repo_contenido_largo():
    c_repo_colisiona("SECRETO-REPO-SINTETICO", "org-ejemplo/SECRETO-REPO-SINTETICO")


def c_repo_contenido_corto():
    """Secreto de 1-3 caracteres contenido en el nombre del repo (N = 4): coincidencia de texto. La alerta
    se cuenta y el rc es 0 en el informe de texto, el JSON y el dry-run; nunca «0 alertas»."""
    for secreto, repo in (("e", "org-ejemplo/repo-ejemplo"), ("XYZ", "org-ejemplo/repo-XYZ")):
        for camino, argv in CAMINOS_REPO[:3]:
            with tempfile.TemporaryDirectory() as td:
                en = entorno_con_repo(td, secreto, repo)
                rc, out, err = t.correr(en, argv)
                assert rc == 0, (secreto, camino, rc, err)
                if argv == []:
                    assert "abiertas=1" in out, (secreto, out)
                elif argv == ["--json"]:
                    doc = json.loads(out)
                    assert set(doc) == t.CLAVES_JSON and doc["total_abiertas"] == 1, (secreto, doc)
                    assert len(doc["nuevos"]) == 1, (secreto, doc)
                else:
                    assert "DRY-RUN" in out or "[OCULTO]-RUN" in out, (secreto, out)
                for p in re.findall(r"borrador conservado para inspección: ([^\s)]+)", err):
                    Path(p).unlink(missing_ok=True)


def c_repo_sin_colision():
    """Negativo: un repositorio que no coincide con ningún secreto sigue dando rc 0 y el informe completo,
    con el repositorio íntegro en la cabecera y en el body del dry-run."""
    repo = "org-ejemplo/repo-limpio"
    for camino, argv in CAMINOS_REPO[:3]:
        with tempfile.TemporaryDirectory() as td:
            en = entorno_con_repo(td, "CREDENCIAL-SIN-COLISION-SINTETICA", repo)
            rc, out, err = t.correr(en, argv)
            assert rc == 0, (camino, rc, err)
            if argv == []:
                assert f"GITHUB-SEGURIDAD repo={repo} abiertas=1" in out, out
            elif argv == ["--json"]:
                assert set(json.loads(out)) == t.CLAVES_JSON, out
            else:
                assert f"vigia-github-identity superficie=secret-scanning id=7 repo={repo}" in out, out
            t.sin_secreto("CREDENCIAL-SIN-COLISION-SINTETICA", camino, out, err)
            for p in re.findall(r"borrador conservado para inspección: ([^\s)]+)", err):
                Path(p).unlink(missing_ok=True)


for nombre, secreto in VARIANTES:
    variante(nombre, secreto)
escenario("creacion_cruzada (CREDENCIAL-CRUZADA-SINTETICA, borrador y payload)", t.c_creacion_cruzada)
escenario("secretos_cortos 1-3 caracteres (state y claves JSON: sigue abierta, esquema íntegro)",
          t.c_secretos_cortos_no_alteran_decisiones)
escenario("colision_con_identidad (rc 3, sin informe ni cursor)", t.c_colision_con_identidad)
escenario("error_reflejado_del_helper (CREDENCIAL-ERROR-SINTETICA)", t.c_error_reflejado_del_helper)
escenario("retorno_de_la_creacion: identificador devuelto = secreto (ABC-1)", c_retorno_identificador)
escenario("retorno_de_la_creacion: secreto dentro de la URL devuelta", c_retorno_url)
escenario("crudo informe de texto (emitir): titulo y URL = secreto", c_crudo_informe_texto)
escenario("crudo JSON del barrido: titulo y URL = secreto, esquema intacto", c_crudo_json)
escenario("crudo body del dry-run: titulo, URL y texto del operador = secreto", c_crudo_dryrun_body)
escenario("repo igual al secreto, corto (3): rc 3 en texto, JSON, dry-run y apply", c_repo_igual_corto)
escenario("repo igual al secreto, largo: rc 3 en texto, JSON, dry-run y apply", c_repo_igual_largo)
escenario("secreto largo contenido en el repo: rc 3 en texto, JSON, dry-run y apply", c_repo_contenido_largo)
escenario("secreto corto (<4) contenido en el repo: rc 0 y la alerta se cuenta", c_repo_contenido_corto)
escenario("repo sin colision (rc 0 e informe completo)", c_repo_sin_colision)
# 4 variantes x (8 mediciones + 4 exigencias de etapa) + 14 escenarios: si falta una etapa, esto falla.
ESPERADAS = 4 * 12 + 14
exigir("conjunto", f"se ejecutaron todas las etapas (comprobaciones={comprobaciones}, esperadas={ESPERADAS})",
       comprobaciones == ESPERADAS)
print(f"comprobaciones={comprobaciones}")
print(f"RESULTADO: FALLOS_CONFIDENCIALIDAD={fallos}")
sys.exit(int(fallos > 0))
