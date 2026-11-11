#!/usr/bin/env python3
"""C1-C9 con fuentes sintéticas y mutaciones del cableado de las tres pruebas.

El doble de gh es un ejecutable envuelto por gh_contrato.envolver. Todas las
peticiones urllib atraviesan un doble cerrado; ningún caso puede usar red.
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts/resolver_ficha.py"
ROOT = HERE.parents[2]
FIXTURE = json.loads((HERE / "fixtures/resolver/fuentes.json").read_text())
TOKENS = ("lectura-secreto-sintetico", "escritura-secreto-sintetico", "linear-secreto-sintetico")
PASS = FAIL = 0


def cargar(path, nombre):
    spec = importlib.util.spec_from_file_location(nombre, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[nombre] = m
    spec.loader.exec_module(m)
    return m


rf = cargar(SCRIPT, "resolver_ficha")
contrato = cargar(ROOT / "tests/fixtures/instalacion/gh_contrato.py", "gh_contrato")


class Respuesta:
    def __init__(self, body, status=200):
        self.body, self.status, self.headers = body, status, {}

    def read(self):
        return json.dumps(self.body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def caso(nombre, cambios=None, modulo=rf, aplicar=True, config=None):
    datos = copy.deepcopy(FIXTURE)
    opciones = {}
    if cambios:
        cambios(datos, opciones)
    consultas, puts, sellos, peticiones = [], [], [], []
    out, err = io.StringIO(), io.StringIO()
    run_real = subprocess.run
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        hdr, wr, bus = t / "lectura", t / "escritura", t / "bus"
        hdr.write_text("Authorization: Bearer " + TOKENS[0] + "\n")
        wr.write_text("Authorization: Bearer " + TOKENS[1] + "\n")
        hdr.chmod(0o600)
        wr.chmod(0o600)
        bus.write_text(datos["bus"])
        gh = t / "gh"
        # El body JSON es dato en un fichero, nunca interpolado en shell.
        (t / "gh.json").write_text(json.dumps(datos["gh"]))
        if opciones.get("gh_no_json"):
            (t / "gh.json").write_text("respuesta plana")
        gh.write_text('#!/bin/bash\ncat "${0%/*}/gh.json"\n')
        gh.chmod(0o700)
        contrato.envolver(gh)
        env = {"SENTRY_ORG": "org-ejemplo", "SENTRY_RELEASE_PREFIX": "producto",
               "TF_LINEAR_TEAM_KEY": "ABC", "TA_BUS": str(bus), "LINEAR_API_KEY": TOKENS[2],
               "SENTRY_HDR": str(hdr), "SENTRY_HDR_RESOLVER": str(wr),
               "PATH": str(t) + os.pathsep + os.defpath,
               "SENTRY_DOCTOR_RAILWAY_EXPECTED": "producto-ejemplo"}
        if config:
            config(env, hdr, wr)

        def run(argv, **kwargs):
            consultas.append(argv)
            if argv[0] == "gh":
                if opciones.get("gh_ausente"):
                    raise FileNotFoundError()
                if opciones.get("gh_fuera"):
                    argv = argv + ["--inventado"]
                return run_real(argv, **kwargs)
            if argv[0] == "railway":
                return subprocess.CompletedProcess(argv, 0, json.dumps(datos["railway"]), "")
            if argv[:2] == ["bash", str(modulo.SELLADOR)]:
                sellos.append(argv)
                assert len(puts) == (0 if datos["sentry"]["status"] == "resolved" else 1)
                return subprocess.CompletedProcess(argv, opciones.get("sello_rc", 0), "", TOKENS[1])
            raise AssertionError("subprocess inesperado")

        def urlopen(req, **kwargs):
            url, metodo = req.full_url, req.get_method()
            peticiones.append((metodo, url))
            if metodo == "PUT":
                puts.append(req)
                assert req.data == b'{"status":"resolved"}'
                assert req.get_header("Authorization") == "Bearer " + TOKENS[1]
                assert req.get_header("User-agent") == modulo.UA
                if "put_error" in opciones:
                    code = opciones["put_error"]
                    if code == "red":
                        raise urllib.error.URLError(TOKENS[1])
                    raise urllib.error.HTTPError(url, code, TOKENS[1], {}, None)
                return Respuesta({"id": "123", "status": "resolved"})
            if url == "https://api.linear.app/graphql":
                assert metodo == "POST"
                assert req.get_header("Authorization") == TOKENS[2]
                assert json.loads(req.data)["variables"] == {"id": "ABC-42"}
                return Respuesta(datos["linear"])
            assert metodo == "GET" and req.get_header("Authorization") == "Bearer " + TOKENS[0]
            if "/releases/" in url:
                return Respuesta(datos["release"], opciones.get("release_http", 200))
            if "/events/" in url:
                ancho = "start=2020-01-01" in url
                eventos = [ {"id": "evento-previo"} ] if ancho else []
                if opciones.get("eventos"):
                    eventos = [{"id": "evento-nuevo"}]
                if opciones.get("filtro_roto"):
                    eventos = []
                if opciones.get("capado"):
                    r = Respuesta([])
                    r.headers = {"Link": '<'+url+'>; rel="next"; results="true"'}
                    return r
                return Respuesta(eventos)
            if "shortIdLookup=1" in url:
                return Respuesta([datos["sentry"]])
            if url.endswith("/issues/123/"):
                return Respuesta(datos["sentry"])
            raise AssertionError("URL inesperada")

        argv = [str(SCRIPT), "--short-id", "PRODUCTO-X1", "--tal", "ABC-42", "--rol", "vigia"]
        if aplicar:
            argv.append("--apply")
        argv.extend(opciones.get("args", []))
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(sys, "argv", argv), \
                mock.patch("subprocess.run", side_effect=run), \
                mock.patch("urllib.request.urlopen", side_effect=urlopen), \
                mock.patch.object(modulo.ci, "linear_gql", wraps=modulo.ci.linear_gql) as gql, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = modulo.main()
        assert all(not call.kwargs or call.kwargs.get("retry") is True for call in gql.call_args_list)
    texto = out.getvalue() + err.getvalue() + repr(sellos)
    assert not any(token in texto for token in TOKENS), "fuga de credencial"
    return rc, len(puts), len(sellos), out.getvalue(), err.getvalue(), len(consultas) + len(peticiones)


def comprobar(nombre, esperado, cambios=None, **kw):
    global PASS, FAIL
    try:
        r = caso(nombre, cambios, **kw)
        assert r[:3] == esperado, repr(r)
        if nombre.startswith("PRUEBA-"):
            assert nombre[:8] in r[4], repr(r)
        if nombre == "C2":
            assert r[3].startswith("RESOLVERÍA PRODUCTO-X1")
        if nombre.startswith("C8"):
            assert r[5] == 0, "consulta anterior a validación"
        print(f"PASS {nombre}: rc={r[0]} PUT={r[1]} sello={r[2]}")
        PASS += 1
    except Exception as e:
        print(f"FAIL {nombre}: {e}")
        FAIL += 1


def opcion(clave, valor=True):
    return lambda d, o: o.update({clave: valor})


NEGATIVOS = [
    ("PRUEBA-1 sin fundir", lambda d, o: d["gh"][0].update(mergedAt=None)),
    ("PRUEBA-1 otra rama", lambda d, o: d["gh"][0].update(baseRefName="develop")),
    ("PRUEBA-1 fixes", lambda d, o: d["gh"][0].update(body="fixes ABC-42")),
    ("PRUEBA-1 resolves", lambda d, o: d["gh"][0].update(body="resolves ABC-42")),
    ("PRUEBA-1 sin cita", lambda d, o: d["linear"]["data"]["issue"].update(description="Otro grupo")),
    ("PRUEBA-1 cita parcial", lambda d, o: d["linear"]["data"]["issue"].update(description="PRODUCTO-X12")),
    ("PRUEBA-1 clave parcial", lambda d, o: d["gh"][0].update(body="closes ABC-420")),
    ("PRUEBA-1 ambigua", lambda d, o: d["gh"].append(copy.deepcopy(d["gh"][0]))),
    ("PRUEBA-2 no LIVE", opcion("release_http", 404)),
    ("PRUEBA-2 aprobación", lambda d, o: d["railway"]["latestDeployment"].update(status="NEEDS_APPROVAL")),
    ("PRUEBA-2 fallo", lambda d, o: d["railway"]["latestDeployment"].update(status="FAILED")),
    ("PRUEBA-2 en curso", lambda d, o: d["railway"]["latestDeployment"].update(status="DEPLOYING")),
    ("PRUEBA-3 sin sello", lambda d, o: d.update(bus="")),
    ("PRUEBA-3 CONSULTA", lambda d, o: d.update(bus=d["bus"].replace("-OK]", "-CONSULTA]"))),
    ("PRUEBA-3 NO-MEDIDO", lambda d, o: d.update(bus=d["bus"].replace("-OK]", "-NO-MEDIDO]"))),
    ("PRUEBA-3 otra issue", lambda d, o: d.update(bus=d["bus"].replace("ABC-42", "ABC-43"))),
    ("PRUEBA-3 otro release", lambda d, o: d.update(bus=d["bus"].replace("12345678", "abcdef12"))),
    ("PRUEBA-3 eventos", opcion("eventos")),
    ("PRUEBA-3 cifra bus", lambda d, o: d.update(bus=d["bus"].replace("eventos_nuevos=0", "eventos_nuevos=1"))),
    ("PRUEBA-3 filtro roto", opcion("filtro_roto")),
    ("PRUEBA-3 capado", opcion("capado")),
    ("PRUEBA-3 ventana", lambda d, o: d["release"].update(dateReleased="2099-01-01T00:00:00Z")),
    ("PRUEBA-3 cabecera falsa", lambda d, o: d.update(bus="nota " + d["bus"])),
]


def mutante(original, reemplazo, numero):
    source = SCRIPT.read_text()
    assert source.count(original) == 1
    source = source.replace(original, reemplazo)
    m = types.ModuleType(f"mutante_{numero}")
    m.__file__ = str(SCRIPT)
    exec(compile(source, str(SCRIPT), "exec"), m.__dict__)
    return m


def main():
    global PASS, FAIL
    comprobar("C1", (0, 1, 1))
    comprobar("C2", (0, 0, 0), aplicar=False)
    comprobar("C2 escritura ausente", (0, 0, 0), aplicar=False,
              config=lambda e, h, w: e.pop("SENTRY_HDR_RESOLVER"))
    comprobar("PRUEBA-1 credencial reflejada", (3, 0, 0),
              lambda d, o: d.update(linear={"errors": [{"message": TOKENS[2]}]}))
    for nombre, cambio in NEGATIVOS:
        comprobar(nombre, (3, 0, 0), cambio)
    for estado in (401, 403, 500, "red"):
        comprobar(f"C6 {estado}", (3, 1, 0), opcion("put_error", estado))
    comprobar("C7", (0, 0, 1), lambda d, o: (d["sentry"].update(status="resolved"), o.update(sello_rc=3)))
    comprobar("C7 sello nuevo", (0, 0, 1), lambda d, o: d["sentry"].update(status="resolved"))
    comprobar("sellador falla", (2, 1, 1), opcion("sello_rc", 2))
    for variable in ("SENTRY_ORG", "SENTRY_RELEASE_PREFIX", "TF_LINEAR_TEAM_KEY", "TA_BUS",
                     "LINEAR_API_KEY", "SENTRY_HDR", "SENTRY_HDR_RESOLVER"):
        # SENTRY_HDR tiene ruta default; HOME sintético fuerza ausencia sin leer el host.
        def quitar(e, h, w, var=variable):
            e.pop(var)
            e["HOME"] = str(h.parent)
        comprobar("C8 falta " + variable, (2, 0, 0), config=quitar)
    for nombre in ("lectura", "escritura"):
        comprobar("C8 modo " + nombre, (2, 0, 0),
                  config=lambda e, h, w, n=nombre: (h if n == "lectura" else w).chmod(0o644))
    comprobar("C8 mismo header", (2, 0, 0), config=lambda e, h, w: e.update(SENTRY_HDR_RESOLVER=str(h)))
    for clave in ("gh_ausente", "gh_fuera", "gh_no_json"):
        comprobar("C9 " + clave, (3, 0, 0), opcion(clave))
    comprobar("Railway desconocido", (0, 1, 1),
              lambda d, o: d["railway"].update(latestDeployment={"status": "DESCONOCIDO"}))
    comprobar("ventana cero", (2, 0, 0), opcion("args", ["--ventana", "0h"]))
    mutaciones = [
        ("pr = prueba_1(args.tal, args.short_id, key)", "pr = " + repr(FIXTURE["gh"][0]), NEGATIVOS[2]),
        ("ancla = prueba_2(org, sha, auth)", "ancla = vc.parse_iso('2020-01-03T00:00:00Z')", NEGATIVOS[8]),
        ("issue_id = prueba_3(bus, args.tal, release, org, args.short_id, ancla, args.ventana, auth)",
         "issue_id = '123'", NEGATIVOS[12]),
    ]
    for numero, (original, reemplazo, (nombre, cambio)) in enumerate(mutaciones, 1):
        try:
            green = caso(nombre, cambio)[:3] == (3, 0, 0)
            red = caso(nombre, cambio, modulo=mutante(original, reemplazo, numero))[:3] == (0, 1, 1)
            reverted = caso(nombre, cambio)[:3] == (3, 0, 0)
            assert green and red and reverted
            print(f"PASS MUTANTE-{numero}: original rc=3 PUT=0; defecto rc=0 PUT=1 ROJO; revertido rc=3 PUT=0 VERDE")
            PASS += 1
        except Exception as e:
            print(f"FAIL MUTANTE-{numero}: {e}")
            FAIL += 1
    print(f"RESULTADO: PASS={PASS} FAIL={FAIL}")
    return int(FAIL > 0)


if __name__ == "__main__":
    sys.exit(main())
