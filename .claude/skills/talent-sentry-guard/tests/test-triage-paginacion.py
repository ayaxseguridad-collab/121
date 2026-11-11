#!/usr/bin/env python3
"""C9 — sentry_triage.fetch_issues sigue el cursor de Sentry (Link rel="next"; results="true").

Sin red: urlopen es un doble en memoria. Cada guarda lleva su mutante (ROJO con el defecto, VERDE al revertir).
Casos: dos páginas sin duplicados · sin results="true" no sigue · tope de páginas (die) · 20 páginas exactas OK ·
destino fuera del endpoint (el token no viaja) · bucle · el caso del 14-sep por main() con --json --grupos.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
spec = importlib.util.spec_from_file_location("sentry_triage", SCRIPTS / "sentry_triage.py")
st = importlib.util.module_from_spec(spec)
sys.modules["sentry_triage"] = st
spec.loader.exec_module(st)

ORG, PROY = "org-ejemplo", "proy-ejemplo"
BASE = f"https://sentry.io/api/0/projects/{ORG}/{PROY}/issues/"
PASS = FAIL = 0


class Resp:
    def __init__(self, payload, link=None):
        self._b = json.dumps(payload).encode()
        self.status = 200
        self.headers = {"Link": link} if link else {}

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


_T = datetime.now(timezone.utc)                      # fechas relativas al reloj de la corrida
ANTES = (_T - timedelta(hours=9)).isoformat()
HACE40 = (_T - timedelta(minutes=40)).isoformat()


def grupo(i, count="3", first=ANTES):
    return {"id": f"G{i:04d}", "shortId": f"PROY-{i}", "title": f"error conocido {i}", "culprit": f"app/r{i}",
            "count": count, "userCount": "0", "firstSeen": first, "lastSeen": _T.isoformat(),
            "permalink": f"https://x.invalid/g{i}"}


def link(n, results="true"):
    return f'<{BASE}?query=is:unresolved&cursor={n}>; rel="next"; results="{results}"; cursor="{n}"'


def servidor(paginas, ultimo_results="false", destino=None):
    """paginas: lista de listas. Pide N -> paginas[N-1]; Link al siguiente salvo en la última."""
    pedidas = []

    def urlopen(req, timeout=15):
        pedidas.append(req.full_url)
        n = int(req.full_url.split("cursor=")[1].split("&")[0]) if "cursor=" in req.full_url else 1
        if n > len(paginas):
            return Resp([], None)       # página inexistente: vacía y sin Link
        sig = link(n + 1) if n < len(paginas) else (link(n + 1, ultimo_results) if ultimo_results else None)
        if destino and sig:
            sig = sig.replace(BASE, destino)
        return Resp(paginas[n - 1], sig)

    return urlopen, pedidas


def url_valida(url):
    return st.url_siguiente_valida(url, ORG, PROY)


def barrer(urlopen, fetch=None):
    """(resultado|None, pedidas): None si fetch_issues terminó con die()."""
    with mock.patch.object(st.urllib.request, "urlopen", side_effect=urlopen), \
         contextlib.redirect_stderr(io.StringIO()):
        try:
            return (fetch or st.fetch_issues)(ORG, PROY, "Authorization: Bearer TOKEN-SINTETICO", "24h", "date")
        except SystemExit:
            return None


def caso(nombre, ok):
    global PASS, FAIL
    print(("PASS " if ok else "FAIL ") + nombre)
    PASS, FAIL = (PASS + 1, FAIL) if ok else (PASS, FAIL + 1)


def mutante(nombre, ok):
    """El mutante debe poner ROJO el caso: ok=True significa que el caso falló bajo el defecto."""
    caso("MUTANTE " + nombre + " -> el caso se pone rojo", ok)


# ── C9 dos páginas: sigue hasta agotar, sin duplicados ──
p1 = [grupo(i) for i in range(1, 101)]
p2 = [grupo(100)] + [grupo(i) for i in range(101, 151)]      # G0100 repetido entre páginas
u, pedidas = servidor([p1, p2])
r = barrer(u)
caso("C9 dos páginas: 150 grupos únicos y 2 peticiones",
     r is not None and len({g["id"] for g in r}) == 150 and len(r) == 150 and len(pedidas) == 2)
u, _ = servidor([p1, p2])
with mock.patch.object(st, "parse_next_cursor", lambda _l: None):
    r_mut = barrer(u)
mutante("retirar el seguimiento de Link", r_mut is not None and len(r_mut) == 100)

# ── sin results="true" no sigue ──
u, pedidas = servidor([p1, p2])
u0 = u


def sin_results(req, timeout=15):
    resp = u0(req, timeout)
    if "Link" in resp.headers:
        resp.headers = {"Link": resp.headers["Link"].replace('results="true"', 'results="false"')}
    return resp


r = barrer(sin_results)
caso('C9 Link con results="false": no sigue (100 grupos)', r is not None and len(r) == 100)
u, _ = servidor([p1, p2])
with mock.patch.object(st, "parse_next_cursor", lambda l: (l.split("<")[1].split(">")[0] if l else None)):
    r_mut = barrer(sin_results)
mutante('ignorar results="true"', r_mut is not None and len(r_mut) == 150)

# ── tope de páginas: 20 exactas OK, 21 = die ──
veinte = [[grupo(p * 100 + i) for i in range(100)] for p in range(20)]
u, pedidas = servidor(veinte)
r = barrer(u)
caso("C9 20 páginas (2.000 grupos) con la última sin results: OK", r is not None and len(r) == 2000 and len(pedidas) == 20)
u, pedidas = servidor(veinte, ultimo_results="true")
r = barrer(u)
caso("C9 más de 20 páginas: die, sin lista truncada y sin pedir la 21", r is None and len(pedidas) == 20)
u, pedidas = servidor(veinte, ultimo_results="true")
with mock.patch.object(st, "TOPE_PAGINAS", 10_000), mock.patch.object(st.time, "sleep", lambda _s: None):
    # sin tope el servidor se queda sin página 21: el defecto se manifiesta como lista ilimitada o error del doble
    try:
        r_mut = barrer(u)
    except IndexError:
        r_mut = "sin-tope"
mutante("retirar el tope de páginas", r_mut is not None)

# ── destino fuera del endpoint del proyecto: el token no viaja ──
u, pedidas = servidor([p1, p2], destino="https://otro.example.invalid/api/0/projects/x/issues/")
r = barrer(u)
caso("C9 Link a otro host: die y una sola petición (el token no sale)", r is None and len(pedidas) == 1)

# Intentos de salto que EMPIEZAN por el endpoint del proyecto (el prefijo no los distingue) o lo imitan:
# cada uno debe morir con UNA sola petición (la segunda llevaría el token a otra ruta).
BASE_OTRO = f"https://sentry.io/api/0/projects/{ORG}/otro-proyecto/issues/"
SALTOS = (
    ("../ hacia otro proyecto", BASE + "../../otro-proyecto/issues/"),
    ("../ hacia otra organización", BASE + "../../../../otra-org/otro-proyecto/issues/"),
    ("segmentos extra", BASE + "extra/segmentos/"),
    ("./ y // intercalados", BASE + ".//"),
    ("../ codificado (%2e%2e)", BASE + "%2e%2e/%2e%2e/otro-proyecto/issues/"),
    ("barra codificada (%2f)", BASE + "..%2f..%2fotro-proyecto/issues/"),
    ("otro proyecto de la misma organización", BASE_OTRO),
    ("usuario en la URL (sentry.io@otro host)", "https://sentry.io@otro.example.invalid/api/0/projects/%s/%s/issues/" % (ORG, PROY)),
    ("puerto distinto", f"https://sentry.io:8443/api/0/projects/{ORG}/{PROY}/issues/"),
    ("http en claro", f"http://sentry.io/api/0/projects/{ORG}/{PROY}/issues/"),
)
for nombre, destino in SALTOS:
    u, pedidas = servidor([p1, p2], destino=destino)
    r = barrer(u)
    caso(f"C9 salto «{nombre}»: die y una sola petición", r is None and len(pedidas) == 1)
caso("C9 control: la URL exacta del proyecto (con query y cursor) sigue la paginación",
     url_valida(f"{BASE}?query=is:unresolved&sort=date&cursor=2"))
caso("C9 la ruta exacta con /issues (sin barra final) no es el endpoint", not url_valida(BASE.rstrip("/") + "?cursor=2"))


def con_fuente_mutada(origen, destino_txt):
    """Copia del módulo con UN cambio; ejecuta fetch_issues contra el último servidor y devuelve las peticiones."""
    fuente = (SCRIPTS / "sentry_triage.py").read_text()
    mut = fuente.replace(origen, destino_txt)
    assert mut != fuente, "el mutante no se aplicó"
    ns = {"__file__": str(SCRIPTS / "sentry_triage.py"), "__name__": "sentry_triage_mut"}
    exec(compile(mut, "sentry_triage_mut", "exec"), ns)
    return ns


# mutante 1: sin ninguna comprobación del destino
u, pedidas = servidor([p1, p2], destino="https://otro.example.invalid/api/0/projects/x/issues/")
ns = con_fuente_mutada("if not url_siguiente_valida(siguiente, org, project):", "if False:")
with mock.patch.object(st.urllib.request, "urlopen", side_effect=u), contextlib.redirect_stderr(io.StringIO()):
    try:
        ns["fetch_issues"](ORG, PROY, "Authorization: x", "24h", "date")
    except SystemExit:
        pass
mutante("aceptar un destino fuera del endpoint", len(pedidas) >= 2)

# mutante 2: la guarda anterior (prefijo): acepta los saltos por ../ y por segmentos extra
ns = con_fuente_mutada("if not url_siguiente_valida(siguiente, org, project):", "if not siguiente.startswith(base):")
for nombre, destino in SALTOS[:4]:
    u, pedidas = servidor([p1, p2], destino=destino)
    with mock.patch.object(st.urllib.request, "urlopen", side_effect=u), contextlib.redirect_stderr(io.StringIO()):
        try:
            ns["fetch_issues"](ORG, PROY, "Authorization: x", "24h", "date")
        except SystemExit:
            pass
    mutante(f"guarda por prefijo (acepta «{nombre}»)", len(pedidas) >= 2)

# ── bucle: la página siguiente repite una ya leída ──
def bucle(req, timeout=15):
    return Resp(p1[:3], link(1))


r = barrer(bucle)
caso("C9 página repetida: die (bucle)", r is None)

# ── el caso del 14-sep por main(): la novedad está en la segunda página ──
nuevo = grupo(999, count="141", first=HACE40)
nuevo["shortId"], nuevo["title"] = "PROY-NUEVO", "fallo nuevo tras el despliegue"
pag2 = [nuevo] + [grupo(i) for i in range(101, 151)]
td = Path(tempfile.mkdtemp())
hdr = td / "hdr"
hdr.write_text("Authorization: Bearer TOKEN-SINTETICO\n")
hdr.chmod(0o600)
cursor = td / "cursor.json"
cursor.write_text(json.dumps({g["id"]: {"lastSeen": g["lastSeen"], "count": 3} for g in p1}))
env = {"SENTRY_ORG": ORG, "SENTRY_PROJECT": PROY, "SENTRY_HDR": str(hdr), "SENTRY_CURSOR": str(cursor)}


def correr(urlopen, *flags):
    buf = io.StringIO()
    with mock.patch.dict(os.environ, env), mock.patch.object(sys, "argv", ["sentry_triage.py", "--since", "24h", *flags]), \
         mock.patch.object(st, "cargar_buckets", lambda: {"CONOCIDO": ["re:error conocido"]}), \
         mock.patch.object(st.urllib.request, "urlopen", side_effect=urlopen), contextlib.redirect_stdout(buf):
        rc = st.main()
    return rc, json.loads(buf.getvalue())


u, _ = servidor([p1, pag2])
rc, res = correr(u, "--json", "--grupos")
caso("14-sep: el grupo de la segunda página sale como NUEVO y hay novedad",
     rc == 0 and res["hay_novedad"] and [i["shortId"] for i in res["nuevos"]] == ["PROY-NUEVO"])
caso("--grupos: total_unresolved cuenta todas las páginas (151) y lista cada grupo una vez",
     res["total_unresolved"] == 151 and len(res["grupos"]) == 151 and len({g["id"] for g in res["grupos"]}) == 151)
u, _ = servidor([p1, pag2])
_, res_sin = correr(u, "--json")
caso("sin --grupos el JSON conserva sus claves de siempre", "grupos" not in res_sin and "total_unresolved" not in res_sin)
with contextlib.redirect_stderr(io.StringIO()):
    try:
        with mock.patch.dict(os.environ, env), mock.patch.object(sys, "argv", ["sentry_triage.py", "--grupos"]):
            st.main()
        rc_uso = 0
    except SystemExit as e:
        rc_uso = e.code
caso("--grupos sin --json: error de uso (rc 2)", rc_uso == 2)

print(f"RESULTADO: PASS={PASS} FAIL={FAIL}")
sys.exit(0 if FAIL == 0 else 1)
