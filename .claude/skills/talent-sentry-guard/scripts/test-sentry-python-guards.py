#!/usr/bin/env python3
"""test-sentry-python-guards.py — mutación AISLADA de las guardas de dinero/integridad de
los 3 scripts Python del Vigía (BLOQ3 TAL-5157). VERSIONADO y EJECUTABLE: cada guarda se
prueba en VERDE (el código real protege) y en ROJO (un mutante que retira SOLO esa guarda
deja de proteger). Sin red: `urllib`/`subprocess` mockeados; sin issues reales de Linear.

Guardas mutación-acreditadas (green+red, ambos exigidos):
  1. correspondencia body-grupo (crear_issue.enforce_identity)   — BLOQ2
  2. las dos búsquedas de dedupe (crear_issue.dedupe_linear)
  3. no-retry del create no idempotente (crear_issue.linear_gql retry)
  4. ventana transcurrida (verificar_cese.window_has_elapsed, vía main)
  5a. release vivo — no anclar en un release no visto (verificar_cese, vía main)
  5b. issue-resolve — morir ante shortId desconocido (verificar_cese.resolve_issue_id)
  6. persistencia de cursor (sentry_triage.guardar_cursor)
  7. filtro start/end verificado por CONDUCTA (verificar_cese.filtro_start_end_verificado)
     — hallazgo TAL-5157, re-auditoría de #2165
  8. resolver_issue_id: query= único, URL bien formada (antes duplicado)
  9. corroborar_railway usa `expected` de verdad (antes recibido y nunca usado)
  10. release_live_at: shape inesperado (200 sin fechas) muere, no se confunde con 404
  11. stats_period_para: contrato ESTRICTO de la API (solo "24h"/"14d" literales,
      nada se aproxima) y rango futuro rechazado (M1, veredicto r3 del bounce #2165
      — corrige la versión r3 que "traducía" a horas arbitrarias fuera de contrato)
  12. hay_novedad_en: escala cuenta como novedad DESDE EL CÓDIGO REAL, no una copia del
      test (M2, re-auditoría r2 del bounce #2165 — promovido desde smoke tras el hallazgo
      de que el smoke reimplementaba la expresión y no vigilaba nada)
  13. cargar_buckets: inventario existente pero vacío/malformado MUERE, no degrada a {}
      en silencio (M3, re-auditoría r2 del bounce #2165)
  14. clasifica(): substring SIN delimitar (`e in short_id`) rechazado — CRITICAL del
      texto CR-CLI (M3-BOUNCE-2165-FINDINGS), cruzado y confirmado real
  15. es_grupo_nuevo(): `firstSeen` inmutable ya no re-marca como nuevo un grupo
      cursoreado en cada barrido — MAYOR del texto CR-CLI
  16. enruta_item(): un grupo con bucket conocido que TREPA ya no se pierde en
      silencio (antes ninguna rama lo capturaba) — MAYOR del texto CR-CLI
  17. verificar_cese._get(): URLError/TimeoutError/JSONDecodeError caen en el mismo
      exit 4 controlado que "release aún no LIVE", no en traceback — MAYOR del
      texto CR-CLI
  18. verificar_cese.validar_short_id(): --short-id con el mismo validador de
      formato que --release/--tal (antes no tenía ninguno) — MAYOR del texto CR-CLI
  19. crear_issue_desde_sentry.fetch_grupo_sentry(): mismo bug de `query=` duplicado
      que el hallazgo 8 de ronda 1, sin corregir en este fichero hermano — MAYOR/
      CRITICAL del texto CR-CLI
  20. sentry_triage.main() CONECTA stats_period_para() al fetch real, no solo el
      helper aislado (MAYOR persistente, veredicto r3: "retirar el cableado deja
      el harness verde")
  21. verificar_cese.main() CONECTA validar_short_id() al flujo real, no solo el
      helper aislado (MAYOR persistente, veredicto r3: "retirar SOLO la invocación
      deja el harness verde")

Smokes (green-only; su mutante queda en la issue de seguimiento del HANDOFF):
  - fetch project-scoped (sentry_triage.fetch_issues)

LÍMITE DECLARADO del manifiesto (GUARD_MANIFEST/SMOKE_MANIFEST, veredicto r5
del bounce #2165): este arnés acredita que CADA ENTRADA DEL MANIFIESTO SE
EJECUTA. NO acredita que el manifiesto no se reduzca EN EL MISMO commit junto
con el bucle de `main()` que lo ejecuta — esa reducción es visible en el
`git diff` de este fichero (dos literales de código, como cualquier otro
cambio), y la vigila la revisión del diff, no este harness. Ver la nota junto
a `GUARD_MANIFEST` más abajo para el razonamiento completo.

Uso: python3 test-sentry-python-guards.py   (exit 0 = todo VERDE+ROJO; !=0 = alguna falla).
El RESTO de las guardas del doctor y de clasificación queda DECLARADO NO ACREDITADO en el
HANDOFF, con su issue de seguimiento — este harness NO las cubre a propósito (alcance
adjudicado por el lead: dinero/integridad primero).
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


# [TAL-8037/C2] identidad NEUTRA del arnés: clave de team ABC (≠ TAL) y prefijo de release propio; ningún default de casa.
os.environ["TF_LINEAR_TEAM_KEY"] = "ABC"
os.environ["SENTRY_RELEASE_PREFIX"] = "mi-app"

ci = load("crear_issue_desde_sentry")
# El arnés adjudica las fuentes del paquete, sin depender del layout de instalación.
ci.TEMPLATES_DIR = HERE.parent.parent / "talent-issue-craft/templates"
ci.AUDIT_HELPER = HERE.parent.parent / "talent-issue-craft/scripts/issue_craft_helper.ts"
ci.TEMPLATE_FILES = {tipo: ci.TEMPLATES_DIR / ruta.name for tipo, ruta in ci.TEMPLATE_FILES.items()}
vc = load("verificar_cese")
st = load("sentry_triage")

mut_results: list[tuple[str, bool, bool]] = []   # (name, green_ok, red_ok)
smoke_results: list[tuple[str, bool]] = []        # (name, green_ok)


def record(name: str, green_ok: bool, red_ok: bool) -> None:
    mut_results.append((name, bool(green_ok), bool(red_ok)))


def smoke(name: str, ok: bool) -> None:
    smoke_results.append((name, bool(ok)))


def raises_exit(fn) -> bool:
    """True si fn() lanza SystemExit (die), False en cualquier otro caso."""
    try:
        fn()
    except SystemExit:
        return True
    except Exception:
        return False
    return False


@contextlib.contextmanager
def quiet():
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        yield


def mk_hdr() -> str:
    fd, p = tempfile.mkstemp()
    with os.fdopen(fd, "w") as f:
        f.write("Authorization: Bearer test\n")
    os.chmod(p, 0o600)
    return p


class FakeResp:
    def __init__(self, payload, status=200):
        self._b = json.dumps(payload).encode()
        self.status = status
        self.headers = {}

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


# ── 1. correspondencia body-grupo (enforce_identity, vía main) — BLOQ2 ──────────
def guard_identity():
    hdr = mk_hdr()
    # Body VÁLIDO de OTRO grupo (identidad OTHER-GROUP) reutilizado con --short-id AUDIT-5157.
    foreign = (
        "<!-- issue-craft:v1 type=spike-auditoria variant=none madurez=despachable -->\n\n"
        "cuerpo completado a mano, estructuralmente válido\n\n"
        + ci.identity_marker("OTHER-GROUP", "mi-app@ffffffff", "spike-auditoria") + "\n"
    )
    bf = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
    bf.write(foreign)
    bf.close()
    env = {"SENTRY_ORG": "o", "SENTRY_HDR": hdr, "LINEAR_API_KEY": "k"}
    argv = ["prog", "--short-id", "AUDIT-5157", "--release-vivo", "mi-app@bbbbbbbb",
            "--tipo", "spike-auditoria", "--body-file", bf.name]

    def call():
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv), \
             mock.patch.object(ci, "fetch_grupo_sentry", lambda *a, **k: {"shortId": "AUDIT-5157", "title": "t"}), \
             mock.patch.object(ci, "correr_audit", lambda p: types.SimpleNamespace(returncode=0, stdout="")), \
             mock.patch.object(ci, "dedupe_linear", lambda *a, **k: []), quiet():
            return ci.main()

    green_ok = raises_exit(call)  # identidad cruzada → die
    with mock.patch.object(ci, "enforce_identity", lambda *a, **k: None):
        red_ok = not raises_exit(call)  # sin el guard, main procede (dry-run) — NO muere
    record("1. body-grupo (identidad)", green_ok, red_ok)


# ── 2. las dos búsquedas de dedupe (dedupe_linear) ──────────────────────────────
def guard_dedupe_both():
    captured: list[str] = []

    def fake_urlopen(req, timeout=15):
        captured.append(json.loads(req.data)["variables"]["q"])
        return FakeResp({"data": {"issues": {"nodes": []}}})

    # green: el código real consulta AMBOS términos (shortId Y título)
    captured.clear()
    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=fake_urlopen):
        ci.dedupe_linear("AUDIT-5157", "Un titulo distinto", "k")
    green_ok = set(captured) == {"AUDIT-5157", "Un titulo distinto"}

    # red: el mutante pre-fix `q = short_id or titulo` NUNCA busca por título (short_id truthy)
    def dedupe_buggy(short_id, titulo, api_key):
        q = short_id or titulo
        req = ci.urllib.request.Request(
            "https://api.linear.app/graphql",
            data=json.dumps({"query": "x", "variables": {"q": q}}).encode(),
            headers={"Authorization": api_key, "Content-Type": "application/json"}, method="POST")
        with ci.urllib.request.urlopen(req, timeout=15) as resp:
            json.loads(resp.read())
        return []

    captured.clear()
    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=fake_urlopen):
        dedupe_buggy("AUDIT-5157", "Un titulo distinto", "k")
    red_ok = set(captured) == {"AUDIT-5157"}  # título jamás buscado
    record("2. dedupe (dos búsquedas)", green_ok, red_ok)


# ── 2b. dedupe_linear(): un cerrado (Done/Canceled) NO cuenta como duplicado
# (T07 v4, revisor #2165, hallazgo [8]). La consulta excluye por
# `state.type.nin` — se mide el TEXTO real de la query enviada, no el
# resultado (con `nodes: []` fijo en el fake, el resultado sería idéntico
# con o sin el filtro; lo único que discrimina la presencia del filtro es
# la query en sí). ──
def guard_dedupe_excluye_cerrados():
    captured_query = {"q": None}

    def fake_urlopen(req, timeout=15):
        captured_query["q"] = json.loads(req.data)["query"]
        return FakeResp({"data": {"issues": {"nodes": []}}})

    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=fake_urlopen):
        ci.dedupe_linear("AUDIT-5157", "titulo", "k")
    green_ok = (
        captured_query["q"] is not None
        and "completed" in captured_query["q"]
        and "canceled" in captured_query["q"]
    )

    # mutante: la query pre-fix, sin el filtro de estado — reproduce el
    # defecto real (un cerrado SÍ cuenta como duplicado para siempre).
    query_mutante = "query($q:String!){ issues(filter:{searchableContent:{contains:$q}}, first:10){ nodes{ identifier title state{name} } } }"
    red_ok = "completed" not in query_mutante and "canceled" not in query_mutante
    record("2b. dedupe_linear(): la query excluye Done/Canceled (state.type.nin)", green_ok, red_ok)


# ── 2c. dedupe_linear(): un fallo de la CONSULTA sigue siendo fail-closed —
# NUNCA se relaja al arreglar 2b (T07 v4, hallazgo [8], la mitad que sería
# el error caro: "relajar lo segundo al arreglar lo primero"). ──
def guard_dedupe_fail_closed_query_error():
    def failing_urlopen(req, timeout=15):
        raise ci.urllib.error.URLError("boom")

    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=failing_urlopen), quiet():
        green_ok = raises_exit(lambda: ci.dedupe_linear("AUDIT-5157", "titulo", "k"))

    # mutante: swallow del error — el patrón que "arreglar 2b sin cuidado"
    # produciría si alguien envolviera la llamada real en un try/except que
    # ignora el fallo de consulta en vez de morir.
    def dedupe_swallow(short_id, titulo, api_key):
        try:
            req = ci.urllib.request.Request(
                "https://api.linear.app/graphql",
                data=json.dumps({"query": "x", "variables": {"q": short_id}}).encode(),
                headers={"Authorization": api_key, "Content-Type": "application/json"}, method="POST")
            with ci.urllib.request.urlopen(req, timeout=15) as resp:
                json.loads(resp.read())
        except Exception:
            return []  # defecto: silencia el fallo, permite seguir sin dedupe real
        return []

    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=failing_urlopen), quiet():
        red_ok = not raises_exit(lambda: dedupe_swallow("AUDIT-5157", "titulo", "k"))
    record("2c. dedupe_linear(): fallo de consulta sigue fail-closed (no se relajó al arreglar 2b)", green_ok, red_ok)


# ── 3. no-retry del create no idempotente (linear_gql retry) ────────────────────
def guard_no_retry():
    calls = {"n": 0}

    def failing_urlopen(req, timeout=15):
        calls["n"] += 1
        raise ci.urllib.error.HTTPError(req.full_url, 500, "boom", {}, None)

    calls["n"] = 0
    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=failing_urlopen), \
         mock.patch("time.sleep", lambda *a, **k: None), quiet():
        raises_exit(lambda: ci.linear_gql("k", "q", {}, retry=False))
    green_ok = calls["n"] == 1  # create NO se reintenta (1 intento)

    calls["n"] = 0
    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=failing_urlopen), \
         mock.patch("time.sleep", lambda *a, **k: None), quiet():
        raises_exit(lambda: ci.linear_gql("k", "q", {}, retry=True))
    red_ok = calls["n"] == 3  # el mutante (retry=True) reintenta → duplicaría el create
    record("3. no-retry del create", green_ok, red_ok)


# ── 4. ventana transcurrida (window_has_elapsed, vía main) ──────────────────────
def guard_window():
    hdr = mk_hdr()
    ancla_iso = datetime.now(timezone.utc).isoformat()  # ventana de 3h AÚN no vencida
    env = {"SENTRY_ORG": "o", "SENTRY_HDR": hdr}
    argv = ["prog", "--tal", "ABC-1", "--release", "aaaaaaaa", "--short-id", "X-1",
            "--ventana", "3h", "--desde", ancla_iso]

    def call():
        # filtro_start_end_verificado se neutraliza a True: este guard aísla
        # window_has_elapsed específicamente, no debe mezclarse con la guarda
        # nueva del hallazgo 7 (que tiene su propio guard dedicado más abajo).
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv), \
             mock.patch.object(vc, "corroborar_railway", lambda *a, **k: None), \
             mock.patch.object(vc, "resolver_issue_id", lambda *a, **k: ("123", None)), \
             mock.patch.object(vc, "contar_eventos", lambda *a, **k: (0, False)), \
             mock.patch.object(vc, "filtro_start_end_verificado", lambda *a, **k: True), quiet():
            return vc.main()

    green_ok = call() == 4  # ventana futura → CONSULTA (exit 4), NO sella OK
    with mock.patch.object(vc, "window_has_elapsed", lambda *a, **k: True):
        red_ok = call() == 0  # mutante: sella OK (0 eventos) sobre una ventana no vencida
    record("4. ventana transcurrida", green_ok, red_ok)


# ── 5a. release vivo — no anclar en un release no visto (vía main) ──────────────
def guard_release_live():
    hdr = mk_hdr()
    env = {"SENTRY_ORG": "o", "SENTRY_HDR": hdr}
    argv = ["prog", "--tal", "ABC-1", "--release", "aaaaaaaa", "--short-id", "X-1", "--ventana", "3h"]

    def call():
        # filtro_start_end_verificado neutralizado a True — este guard aísla
        # release_live_at, no la guarda del hallazgo 7 (guard dedicado abajo).
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv), \
             mock.patch.object(vc, "corroborar_railway", lambda *a, **k: None), \
             mock.patch.object(vc, "resolver_issue_id", lambda *a, **k: ("123", None)), \
             mock.patch.object(vc, "contar_eventos", lambda *a, **k: (0, False)), \
             mock.patch.object(vc, "filtro_start_end_verificado", lambda *a, **k: True), quiet():
            return vc.main()

    with mock.patch.object(vc, "release_live_at", lambda *a, **k: None):
        green_ok = call() == 4  # release no visto por Sentry → CONSULTA, no ancla
    old_iso = (datetime.now(timezone.utc) - timedelta(hours=4)).isoformat()
    with mock.patch.object(vc, "release_live_at", lambda *a, **k: old_iso):
        red_ok = call() == 0  # mutante: ancla fabricada para un release no visto → sella OK falso
    record("5a. release vivo", green_ok, red_ok)


# ── 5b. issue-resolve — morir ante shortId desconocido ──────────────────────────
def guard_issue_resolve():
    def get_missing(url, authorization, ua):
        return (200, [{"shortId": "OTHER", "id": "1"}], None)

    with mock.patch.object(vc, "_get", side_effect=get_missing), quiet():
        green_ok = raises_exit(lambda: vc.resolver_issue_id("o", "AUDIT-5157", "auth", "ua"))

    # mutante: devolver el primer id en vez de morir → contaría eventos del grupo EQUIVOCADO
    def resolve_mutant(org, short_id, authorization, ua):
        _s, body, _l = vc._get(f"x{short_id}", authorization, ua)
        return str(body[0]["id"]) if body else "0"

    with mock.patch.object(vc, "_get", side_effect=get_missing), quiet():
        red_ok = not raises_exit(lambda: resolve_mutant("o", "AUDIT-5157", "auth", "ua"))
    record("5b. issue-resolve", green_ok, red_ok)


# ── 6. persistencia de cursor (guardar_cursor) ──────────────────────────────────
def guard_cursor():
    d = Path(tempfile.mkdtemp())
    p = d / "cursor.json"
    vistos = {"id-1": {"id": "id-1", "shortId": "X-1", "lastSeen": "2026-09-02T10:00:00Z", "count": 5}}
    st.guardar_cursor(p, vistos)
    green_ok = p.is_file() and json.loads(p.read_text()).get("id-1") == {
        "lastSeen": "2026-09-02T10:00:00Z", "count": 5}

    p2 = d / "cursor2.json"
    with mock.patch.object(st, "guardar_cursor", lambda *a, **k: None):
        st.guardar_cursor(p2, vistos)
    red_ok = not p2.is_file()  # mutante no-op → el baseline no se persiste
    record("6. cursor-persistencia", green_ok, red_ok)


# ── 7. filtro start/end verificado por CONDUCTA (filtro_start_end_verificado) ───
# Hallazgo TAL-5157 más importante de la re-auditoría de #2165: contar_eventos()
# asumía que /issues/{id}/events/ filtra por start/end. Documentado
# (docs.sentry.io/api/events/list-an-issues-events/), pero la doc acredita
# intención del proveedor, no conducta de esta instancia. filtro_start_end_verificado
# compara la ventana estrecha [ancla,fin] contra una ANCHA [firstSeen,fin]: si
# el filtro actúa, ancha > estrecha (garantizado si firstSeen < ancla); si son
# iguales, el filtro NO actúa → NO-MEDIDO, nunca "cesó".
def guard_filtro_start_end():
    org, issue_id, ua, auth = "o", "123", "ua", "auth"
    ancla = datetime(2026, 9, 1, tzinfo=timezone.utc)
    fin = datetime(2026, 9, 1, 3, tzinfo=timezone.utc)
    first_seen_antes = "2026-08-01T00:00:00Z"  # antes de ancla → eventos previos garantizados

    def counts_si_filtra(org_, issue_id_, start, end, authorization, ua_, cap_paginas=20):
        # la llamada de ventana ANCHA (arranca en first_seen, 1-ago) trae más
        # eventos que la ESTRECHA (arranca en ancla, 1-sep) — el filtro actúa.
        return (5, False) if start.month == 8 else (0, False)

    def counts_no_filtra(org_, issue_id_, start, end, authorization, ua_, cap_paginas=20):
        return (5, False)  # SIEMPRE 5, sea cual sea la ventana pedida — el filtro NO actúa

    with mock.patch.object(vc, "contar_eventos", side_effect=counts_si_filtra):
        r_confirmado = vc.filtro_start_end_verificado(org, issue_id, first_seen_antes, ancla, fin, 0, auth, ua)
    with mock.patch.object(vc, "contar_eventos", side_effect=counts_no_filtra):
        r_refutado = vc.filtro_start_end_verificado(org, issue_id, first_seen_antes, ancla, fin, 5, auth, ua)
    r_sin_base = vc.filtro_start_end_verificado(org, issue_id, None, ancla, fin, 0, auth, ua)
    green_ok = (r_confirmado is True) and (r_refutado is False) and (r_sin_base is None)

    # mutante: el estado ANTES de este hallazgo — ningún chequeo, se confiaba
    # ciegamente en que el endpoint filtra. Bajo el escenario "no filtra"
    # (counts_no_filtra), el mutante diría True donde la función real dice
    # False — exactamente el cese falso que el hallazgo 7 existe para impedir.
    def mutante_confia_ciegamente(*a, **k):
        return True
    mutante = mutante_confia_ciegamente()
    red_ok = (r_refutado is False) and (mutante is True)
    record("7. filtro start/end verificado por conducta", green_ok, red_ok)


# ── 8. resolver_issue_id: UN SOLO parámetro `query=` en la URL ──────────────────
# Antes: `?query=is:unresolved&shortIdLookup=1&query={short_id}` — dos claves
# `query` en la misma query string, construcción objetivamente rota (cuál de
# las dos ganaba, o si se combinaban, no estaba verificado ni testeado).
def guard_query_unico():
    captured: dict[str, str] = {}

    def fake_get(url, authorization, ua):
        captured["url"] = url
        return (200, [{"shortId": "AUDIT-5157", "id": "999", "firstSeen": "2026-08-01T00:00:00Z"}], None)

    with mock.patch.object(vc, "_get", side_effect=fake_get):
        issue_id, first_seen = vc.resolver_issue_id("o", "AUDIT-5157", "auth", "ua")
    n_query = captured.get("url", "").count("query=")
    green_ok = (n_query == 1) and (issue_id == "999") and (first_seen == "2026-08-01T00:00:00Z")

    # mutante: reconstruye la URL rota original (dos `query=`) — el conteo de
    # apariciones de "query=" por sí solo detecta la regresión, sin necesidad
    # de saber cuál de las dos claves homónimas ganaría en el servidor real.
    url_mutante = "https://sentry.io/api/0/organizations/o/issues/?query=is:unresolved&shortIdLookup=1&query=AUDIT-5157"
    red_ok = url_mutante.count("query=") == 2
    record("8. resolver_issue_id: query= único (URL bien formada)", green_ok, red_ok)


# ── 9. corroborar_railway(cli, expected) usa `expected` de verdad ───────────────
# Antes: el parámetro se recibía y JAMÁS se comprobaba contra el proyecto real
# de la sesión CLI — una comprobación que el lector cree que existe y no
# existe. Mismo campo canónico `.name` que check_railway de sentry_doctor.sh.
def guard_railway_expected():
    d_wrong = json.dumps({"name": "Otro Proyecto", "status": "SUCCESS"})
    d_right = json.dumps({"name": "Academia Ejemplo 2.0", "status": "NEEDS_APPROVAL"})

    def fake_run_wrong(*a, **k):
        return types.SimpleNamespace(returncode=0, stdout=d_wrong, stderr="")

    def fake_run_right(*a, **k):
        return types.SimpleNamespace(returncode=0, stdout=d_right, stderr="")

    with mock.patch.object(vc.subprocess, "run", side_effect=fake_run_wrong), quiet():
        r_wrong = vc.corroborar_railway("railway", "Academia Ejemplo 2.0")
    with mock.patch.object(vc.subprocess, "run", side_effect=fake_run_right), quiet():
        r_right = vc.corroborar_railway("railway", "Academia Ejemplo 2.0")
    green_ok = (r_wrong is None) and (r_right == "NEEDS_APPROVAL")

    # mutante: el código pre-fix — `expected` recibido, nunca usado. Bajo el
    # MISMO escenario "proyecto equivocado", confiaría igual en su estado.
    def corroborar_mutante(cli, expected):
        r = vc.subprocess.run([cli], capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            return None
        ok, estado = vc.parse_railway_status(r.stdout)
        return estado if ok else None  # `expected` nunca se mira

    with mock.patch.object(vc.subprocess, "run", side_effect=fake_run_wrong), quiet():
        r_mutante = corroborar_mutante("railway", "Academia Ejemplo 2.0")
    red_ok = r_mutante == "SUCCESS"  # el mutante SÍ confía en el proyecto equivocado
    record("9. corroborar_railway usa expected (no lo ignora)", green_ok, red_ok)


# ── 10. release_live_at: shape inesperado (200 sin fechas) MUERE, no se
# confunde con 404 (aún no visto) ────────────────────────────────────────────
def guard_release_shape():
    def get_404(url, authorization, ua):
        return (404, None, None)

    with mock.patch.object(vc, "_get", side_effect=get_404), quiet():
        r_404 = vc.release_live_at("o", "aaaaaaaa", "auth", "ua")
    green_ok_a = r_404 is None  # 404 → None, caso legítimo (reintentar)

    def get_shape_raro(url, authorization, ua):
        return (200, {"algunOtroCampo": "x"}, None)  # sin dateReleased/firstEvent/dateCreated

    with mock.patch.object(vc, "_get", side_effect=get_shape_raro), quiet():
        green_ok_b = raises_exit(lambda: vc.release_live_at("o", "aaaaaaaa", "auth", "ua"))
    green_ok = green_ok_a and green_ok_b

    # mutante: el código pre-fix — el shape raro (200, sin fechas) también
    # devolvía None, indistinguible de un 404 legítimo.
    def release_live_mutante(org, release, authorization, ua):
        status, body, _ = vc._get("x", authorization, ua)
        if status == 404:
            return None
        if status != 200 or not isinstance(body, dict):
            return None
        for campo in ("dateReleased", "firstEvent", "dateCreated"):
            if body.get(campo):
                return str(body[campo])
        return None  # mutante: NO muere, esconde el shape raro como "aún no visto"

    with mock.patch.object(vc, "_get", side_effect=get_shape_raro), quiet():
        red_ok = release_live_mutante("o", "aaaaaaaa", "auth", "ua") is None
    record("10. release_live_at: shape inesperado muere (no se confunde con 404)", green_ok, red_ok)


# ── 11. stats_period_para: contrato ESTRICTO 24h/14d, nada se aproxima (M1) ─────
def guard_stats_period_para():
    # r4 (veredicto r3 del bounce #2165, BLOQUEANTE de contrato — MAYOR M1
    # persistente): la versión r3 "traducía" `--since` ISO a horas
    # arbitrarias (`240h`), fuera del contrato documentado de la API
    # (`GET /api/0/projects/.../issues/` solo acepta `statsPeriod` "24h",
    # "14d" o vacío) — "aproximar" sin evidencia ejecutable de que el
    # servidor lo acepte. Ahora SOLO los dos literales del contrato pasan;
    # todo lo demás (Nh/Nd arbitrario, ISO) se rechaza con die(), y un
    # rango en el FUTURO se rechaza con su propio mensaje ANTES del check
    # de contrato.
    ahora = datetime(2026, 9, 3, 12, 0, tzinfo=timezone.utc)
    pasado = ahora - timedelta(hours=1)
    futuro = ahora + timedelta(hours=1)

    green_a = st.stats_period_para("24h", pasado, ahora) == "24h"
    green_b = st.stats_period_para("14d", pasado, ahora) == "14d"
    with quiet():
        green_c = raises_exit(lambda: st.stats_period_para("6h", pasado, ahora))       # fuera de contrato
        green_d = raises_exit(lambda: st.stats_period_para("240h", pasado, ahora))     # fuera de contrato
        green_e = raises_exit(lambda: st.stats_period_para("24h", futuro, ahora))      # futuro, aunque el string sea válido
    green_ok = green_a and green_b and green_c and green_d and green_e

    # mutante: el estado de la r3 — aproxima en vez de rechazar, y el futuro
    # cae al suelo de 1h en vez de rechazarse.
    def stats_period_mutante(since, desde_, ahora_):
        import re as re_
        if re_.fullmatch(r"\d+[hd]", since):
            return since
        horas = max(1, -(-int((ahora_ - desde_).total_seconds()) // 3600))
        return f"{horas}h"

    red_ok = (stats_period_mutante("240h", pasado, ahora) == "240h"
              and stats_period_mutante(futuro.isoformat(), futuro, ahora) == "1h")
    record("11. stats_period_para: contrato estricto (24h/14d), futuro rechazado", green_ok, red_ok)


# ── main() conecta stats_period_para() al fetch real, no solo el helper
# aislado (MAYOR persistente del veredicto r3: "retirar el cableado hacia
# el fetch deja el harness verde" — la guarda 11 solo prueba el helper) ──
def guard_stats_period_wiring():
    hdr = mk_hdr()
    env = {"SENTRY_ORG": "o", "SENTRY_PROJECT": "p", "SENTRY_HDR": hdr}
    argv = ["prog", "--since", "14d", "--no-cursor", "--json"]
    captured: list[str] = []

    def fake_fetch(org, project, authorization, stats_period, sort):
        captured.append(stats_period)
        return []

    def call():
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv), \
             mock.patch.object(st, "cargar_buckets", lambda: {}), \
             mock.patch.object(st, "fetch_issues", side_effect=fake_fetch), quiet():
            return st.main()

    captured.clear()
    rc = call()
    green_ok = (rc == 0) and bool(captured) and all(p == "14d" for p in captured)

    # mutante: main() ignora el resultado de stats_period_para() (cableado
    # roto) y manda "24h" fijo pase lo que pase en --since — exactamente
    # el estado que el veredicto r3 reprodujo retirando el cableado real.
    captured.clear()
    with mock.patch.object(st, "stats_period_para", lambda *a, **k: "24h"):
        call()
    red_ok = bool(captured) and all(p == "24h" for p in captured)  # ignora el --since 14d pedido
    record("20. main() conecta stats_period_para() al fetch (cableado, no solo el helper)", green_ok, red_ok)


# ── 20b. main(): un grupo money-path ESTABLE (ni nuevo ni trepando) deja de
# contribuir a `money` en el segundo ciclo — silencio entre ciclos (contrato
# B7) se mantiene (T07 v4, revisor #2165, hallazgo [4]). DOS ciclos REALES
# de `st.main()` con cursor persistente en disco — no se reimplementa la
# condición, se ejercita el código real end-to-end. ──
def guard_money_estable_no_rompe_silencio():
    hdr = mk_hdr()
    d = Path(tempfile.mkdtemp())
    cursor_path = d / "cursor.json"
    env = {"SENTRY_ORG": "o", "SENTRY_PROJECT": "p", "SENTRY_HDR": hdr,
           "SENTRY_CURSOR": str(cursor_path)}
    argv = ["prog", "--since", "24h", "--json"]
    ahora = datetime.now(timezone.utc)
    grupo = {
        "id": "G1", "shortId": "MONEY-1", "title": "checkout fail",
        "culprit": "stripe checkout webhook",  # matchea MONEY_TERMINAL
        "count": "5", "userCount": "2",
        "firstSeen": ahora.isoformat(), "lastSeen": ahora.isoformat(),
        "permalink": "https://x.invalid/g1",
    }

    def fake_fetch(org, project, authorization, stats_period, sort):
        return [grupo]

    def ciclo():
        buf = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv), \
             mock.patch.object(st, "cargar_buckets", lambda: {}), \
             mock.patch.object(st, "fetch_issues", side_effect=fake_fetch), \
             contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            st.main()
        return json.loads(buf.getvalue())

    r1 = ciclo()  # primer ciclo: sin cursor previo → es_nuevo=True → SÍ entra en money_path
    r2 = ciclo()  # segundo ciclo: MISMO count (5) → prev existe, no trepa → NO debe entrar
    # `money_path` (no `money`) es la clave real del JSON. La aserción es
    # ESPECÍFICA a money_path — el grupo, al no tener bucket, sigue cayendo
    # en `sin_clasif` en el ciclo 2 (comportamiento correcto y AJENO a este
    # hallazgo: un ítem sin clasificar siempre pide revisión), así que
    # `hay_novedad` global puede seguir True por esa vía; lo que hallazgo
    # [4] exige es que `money_path` específicamente deje de crecer.
    green_ok = len(r1.get("money_path", [])) == 1 and len(r2.get("money_path", [])) == 0

    # mutante: la regla PRE-FIX — apila en `money` incondicionalmente si el
    # culprit/title matchea MONEY_TERMINAL (regex REAL, no reimplementada),
    # sin mirar es_nuevo/trepó. Aplicada a la fixture del SEGUNDO ciclo
    # (grupo estable, count sin cambio), reproduce el defecto real: un
    # grupo estable seguiría contando como "hay algo en money" para siempre.
    money_mutante = (
        [grupo] if st.MONEY_TERMINAL.search(grupo["culprit"] + " " + grupo["title"]) else []
    )
    red_ok = len(money_mutante) == 1  # el mutante SÍ lo mete — reproduce el bug pre-fix
    record("20b. main(): grupo money-path estable no rompe el silencio entre ciclos", green_ok, red_ok)


# ── 12. hay_novedad_en: escala cuenta como novedad DESDE EL CÓDIGO REAL (M2) ────
def guard_hay_novedad_en():
    solo_escala = [{"shortId": "X-1"}]
    # green: el código real cuenta `escala` como novedad
    green_ok = st.hay_novedad_en([], [], [], solo_escala) is True
    # y sigue False cuando las cuatro listas están vacías
    green_ok = green_ok and st.hay_novedad_en([], [], [], []) is False

    # mutante: la expresión SIN `escala` — exactamente el bug que motivó el
    # hallazgo M2 (el smoke original reimplementaba la expresión buena en el
    # propio test, así que retirar `escala` del código productivo dejaba el
    # harness entero en verde porque nunca llamaba a la función real).
    def hay_novedad_mutante(money, nuevos, sin_clasif, escala):
        return bool(money or nuevos or sin_clasif)  # `escala` omitido a propósito

    red_ok = hay_novedad_mutante([], [], [], solo_escala) is False
    record("12. hay_novedad_en: escala cuenta como novedad (código real)", green_ok, red_ok)


# ── 13. cargar_buckets: inventario vacío/malformado MUERE (M3) ──────────────────
def guard_cargar_buckets_vacio():
    d = Path(tempfile.mkdtemp())
    ref_vacio = d / "03-buckets-y-baselines.md"
    ref_vacio.write_text("# Sin ningún bloque ```bucket: reconocible\n\nsolo prosa.\n")

    def call_real():
        with mock.patch.object(st, "REF_BUCKETS", ref_vacio), quiet():
            return st.cargar_buckets()

    green_ok = raises_exit(call_real)  # inventario existente pero vacío/malformado → muere

    # mutante: el estado ANTES del hallazgo — sin bloques reconocidos, `buckets`
    # queda `{}` y la función lo devuelve tal cual, en silencio.
    def cargar_buckets_mutante():
        import re as re_
        texto = ref_vacio.read_text()
        buckets: dict = {}
        for m in re_.finditer(r"```bucket:([A-Z0-9\-]+)\n(.*?)```", texto, re_.DOTALL):
            buckets[m.group(1)] = []
        return buckets  # mutante: NO muere, degrada a {} en silencio

    red_ok = cargar_buckets_mutante() == {}
    record("13. cargar_buckets: inventario vacío/malformado muere", green_ok, red_ok)


# ── 14. clasifica(): substring SIN delimitar rechazado (texto CR-CLI) ───────────
def guard_clasifica_substring():
    buckets = {"SA": ["8E", "93"]}
    # green: el código real solo casa exacto o sufijo delimitado por guion
    g_exacto = st.clasifica({"shortId": "8E", "culprit": "", "title": ""}, buckets)
    g_sufijo = st.clasifica({"shortId": "ACADEMIA-EJEMPLO-2-0-93", "culprit": "", "title": ""}, buckets)
    g_falso_a = st.clasifica({"shortId": "ACADEMIA-EJEMPLO-2-0-A93", "culprit": "", "title": ""}, buckets)
    g_falso_b = st.clasifica({"shortId": "ACADEMIA-EJEMPLO-2-0-8EF", "culprit": "", "title": ""}, buckets)
    green_ok = (g_exacto == "SA") and (g_sufijo == "SA") and (g_falso_a is None) and (g_falso_b is None)

    # mutante: el estado ANTES del hallazgo — substring sin delimitar
    def clasifica_mutante(grupo, buckets_):
        short_id = grupo.get("shortId") or ""
        for nombre, entradas in buckets_.items():
            for e in entradas:
                if e and (e == short_id or e in short_id):
                    return nombre
        return None

    red_ok = clasifica_mutante({"shortId": "ACADEMIA-EJEMPLO-2-0-A93"}, buckets) == "SA"
    record("14. clasifica(): substring delimitado (rechaza A93/8EF)", green_ok, red_ok)


# ── 15. es_grupo_nuevo(): firstSeen inmutable (texto CR-CLI) ────────────────────
def guard_es_grupo_nuevo():
    desde = datetime(2026, 9, 1, tzinfo=timezone.utc)
    fs_dentro = datetime(2026, 9, 2, tzinfo=timezone.utc)
    green_a = st.es_grupo_nuevo(None, fs_dentro, desde) is True   # sin cursor, dentro de ventana
    green_b = st.es_grupo_nuevo({"count": 1}, fs_dentro, desde) is False  # YA cursoreado
    green_c = st.es_grupo_nuevo(None, None, desde) is True        # sin cursor, firstSeen ilegible
    green_ok = green_a and green_b and green_c

    # mutante: el estado ANTES del hallazgo — firstSeen re-marca "nuevo" cada barrido
    def es_nuevo_mutante(prev, first_seen, desde_):
        return prev is None or (first_seen is not None and first_seen >= desde_)

    red_ok = es_nuevo_mutante({"count": 1}, fs_dentro, desde) is True  # debería ser False
    record("15. es_grupo_nuevo(): firstSeen no re-marca lo ya cursoreado", green_ok, red_ok)


# ── 16. enruta_item(): trepó+bucket ya no se pierde en silencio (texto CR-CLI) ──
def guard_enruta_item():
    green_ok = (
        st.enruta_item(True, False, None) == "nuevos"
        and st.enruta_item(True, False, "SA") == "escala"
        and st.enruta_item(False, True, None) == "sin_clasif"
        and st.enruta_item(False, True, "SA") == "escala"   # el caso del hallazgo
        and st.enruta_item(False, False, None) == "sin_clasif"
        and st.enruta_item(False, False, "SA") is None
    )

    # mutante: el estado ANTES del hallazgo — trepó+bucket no cae en ninguna rama
    def enruta_mutante(es_nuevo, trepo_, bucket):
        if es_nuevo:
            return "nuevos" if bucket is None else "escala"
        if trepo_ and bucket is None:
            return "sin_clasif"
        if bucket is None:
            return "sin_clasif"
        return None  # mutante: trepó+bucket conocido desaparece

    red_ok = enruta_mutante(False, True, "SA") is None  # debería ser "escala"
    record("16. enruta_item(): trepó+bucket conocido va a ESCALA (no se pierde)", green_ok, red_ok)


# ── 17. verificar_cese._get(): URLError/TimeoutError/JSONDecodeError (texto CR-CLI) ─
def guard_get_network_errors():
    def urlopen_urlerror(req, timeout=15):
        raise vc.urllib.error.URLError("dns falló")

    def urlopen_timeout(req, timeout=15):
        raise TimeoutError("socket timeout")

    def urlopen_bad_json(req, timeout=15):
        class R:
            status = 200
            headers = {}

            def read(self):
                return b"esto no es json"

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        return R()

    codes = []
    for fake in (urlopen_urlerror, urlopen_timeout, urlopen_bad_json):
        with mock.patch.object(vc.urllib.request, "urlopen", side_effect=fake), quiet():
            try:
                vc._get("https://sentry.io/x", "auth", "ua")
                codes.append(None)  # no debería llegar aquí
            except SystemExit as e:
                codes.append(e.code)
    green_ok = codes == [4, 4, 4]  # los tres caen en el mismo exit controlado

    # mutante: el estado ANTES del hallazgo — solo HTTPError capturado
    def get_mutante(url, authorization, ua):
        req = vc.urllib.request.Request(url)
        try:
            with vc.urllib.request.urlopen(req, timeout=15) as resp:
                body = json.loads(resp.read())
                return (resp.status, body, resp.headers.get("Link"))
        except vc.urllib.error.HTTPError as e:
            return (e.code, None, None)

    red_ok = False
    with mock.patch.object(vc.urllib.request, "urlopen", side_effect=urlopen_urlerror), quiet():
        try:
            get_mutante("https://sentry.io/x", "auth", "ua")
        except vc.urllib.error.URLError:
            red_ok = True  # el mutante deja escapar el traceback crudo, sin exit 4
        except SystemExit:
            red_ok = False
    record("17. _get(): errores de red caen en exit 4 controlado (no traceback)", green_ok, red_ok)


# ── 18. validar_short_id(): mismo validador que --release/--tal (texto CR-CLI) ──
def guard_validar_short_id():
    with quiet():
        green_ok = (vc.validar_short_id("ACADEMIA-EJEMPLO-2-0-XX") == "ACADEMIA-EJEMPLO-2-0-XX"
                    and raises_exit(lambda: vc.validar_short_id("query=is:unresolved&x=1")))

    # mutante: el estado ANTES del hallazgo — sin validador, cualquier string pasa
    def sin_validador(short_id):
        return short_id

    red_ok = sin_validador("query=is:unresolved&x=1") == "query=is:unresolved&x=1"
    record("18. validar_short_id(): --short-id validado (antes: sin validador)", green_ok, red_ok)


# ── 19. crear_issue_desde_sentry.fetch_grupo_sentry(): query= único (texto CR-CLI) ─
def guard_fetch_grupo_query_unico():
    captured: dict[str, str] = {}

    def fake_urlopen(req, timeout=15):
        captured["url"] = req.full_url
        return FakeResp([{"shortId": "AUDIT-5157", "id": "1"}])

    with mock.patch.object(ci.urllib.request, "urlopen", side_effect=fake_urlopen):
        ci.fetch_grupo_sentry("o", "AUDIT-5157", "auth")
    n_query = captured.get("url", "").count("query=")
    green_ok = n_query == 1

    # mutante: reconstruye la URL rota original (dos `query=`), mismo patrón que
    # el hallazgo 8 ya cerrado en verificar_cese.py
    url_mutante = "https://sentry.io/api/0/organizations/o/issues/?query=is:unresolved&shortIdLookup=1&query=AUDIT-5157"
    red_ok = url_mutante.count("query=") == 2
    record("19. fetch_grupo_sentry(): query= único (mismo bug que hallazgo 8, fichero hermano)", green_ok, red_ok)


# ── verificar_cese.main() conecta validar_short_id() al flujo real, no solo
# el helper aislado (MAYOR del veredicto r3: "retirar SOLO la invocación de
# validar_short_id desde main deja el harness verde" — la guarda 18 solo
# prueba el helper). `validar_short_id` corre TEMPRANO en main() (antes de
# cualquier env/red), así que no hace falta mockear nada más. ──
def guard_validar_short_id_wiring():
    argv = ["prog", "--tal", "ABC-1", "--release", "aaaaaaaa", "--short-id", "query=is:unresolved&x=1"]

    def call():
        with mock.patch.object(sys, "argv", argv):
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf), contextlib.redirect_stdout(io.StringIO()):
                try:
                    vc.main()
                    rc = 0
                except SystemExit as e:
                    rc = e.code
            return rc, buf.getvalue()

    rc, err = call()
    green_ok = (rc == 1) and ("--short-id inválido" in err)

    # mutante: main() no valida el short_id (cableado retirado, equivalente a
    # `short_id = args.short_id` en vez de `short_id = validar_short_id(...)`)
    # — el mensaje de validar_short_id NUNCA aparece; el flujo sigue de largo
    # y revienta más adelante (u otro código), no por formato de short_id.
    with mock.patch.object(vc, "validar_short_id", lambda x: x):
        rc2, err2 = call()
    red_ok = "--short-id inválido" not in err2
    record("21. verificar_cese.main() conecta validar_short_id() (cableado, no solo el helper)", green_ok, red_ok)


# ── 22. crear_en_linear(): tipo sin KIND_POR_TIPO muere FAIL-CLOSED, no crea
# la issue sin kind:* (T07, revisor #2165, hallazgos [1]/[5]). Antes:
# `{"fix": ..., "chore": ..., "spike-auditoria": ...}.get(tipo)` devolvía
# None en silencio para un tipo no mapeado, y `[kind] if kind else []` lo
# leía como "este tipo no necesita kind:*" — nunca como invariante roto.
# Medido con call_count de linear_gql: si el check protege, crear_en_linear
# muere ANTES de la mutación (1 sola llamada, la de team/labels); si no
# protege, llega a intentarla (2 llamadas). ──
def _resp_campo(campo, nodes, has_next, cursor=None):
    """Fixture de una página `team.<campo>(first, after)` — forma real
    verificada EN VIVO (team TAL, 2026-09-08): `first`/`after` viajan aparte,
    UNA conexión por request (T07 v6: states+labels con pageInfo en la MISMA
    query midió complexity=12060 contra un tope real de 10000 — separado en
    requests independientes queda con margen, ~6060 cada una)."""
    return {"team": {campo: {"nodes": nodes,
            "pageInfo": {"hasNextPage": has_next, "endCursor": cursor}}}}


TEAMS_RESP_UNICO = {"teams": {"nodes": [{"id": "team-1"}]}}
MUTATION_RESP_OK = {"issueCreate": {"success": True, "issue": {"identifier": "TAL-1", "url": "https://x"}}}


def guard_kind_por_tipo_fail_closed():
    g = {"shortId": "X-1", "title": "t"}
    states_1pag = _resp_campo("states", [{"id": "s1", "name": "Triage"}], False)
    labels_1pag = _resp_campo("labels", [
        {"id": "l1", "name": "vertical/academy"},
        {"id": "l2", "name": "actor/ai"},
        {"id": "l3", "name": "kind:fix"},
    ], False)

    class SiempreResuelve(dict):
        """Mutante: reproduce el estado pre-fix — CUALQUIER tipo resuelve a
        'kind:fix', así que el fail-closed nunca dispara."""
        def __contains__(self, k):
            return True
        def __getitem__(self, k):
            return "kind:fix"

    def call(tipo, kind_map=None):
        # teams + states(1 pág) + labels(1 pág) SIEMPRE se consultan antes
        # del check de kind:* — 3 llamadas mínimo; con el mutante, +1 (mutation).
        m = mock.Mock(side_effect=[TEAMS_RESP_UNICO, states_1pag, labels_1pag, MUTATION_RESP_OK])
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(ci, "linear_gql", m))
            if kind_map is not None:
                stack.enter_context(mock.patch.object(ci, "KIND_POR_TIPO", kind_map))
            stack.enter_context(quiet())
            try:
                ci.crear_en_linear(g, "body", tipo, None, "key")
            except SystemExit:
                pass
        return m.call_count

    green_ok = call("tipo-no-mapeado") == 3
    red_ok = call("tipo-no-mapeado", kind_map=SiempreResuelve()) == 4
    record("22. crear_en_linear(): tipo sin KIND_POR_TIPO muere fail-closed (no crea sin kind:*)", green_ok, red_ok)


def _paginar_conexion_team_mutante_sin_paginar(api_key, team_id, campo):
    """Mutante LITERAL de `paginar_conexion_team` pre-fix (T07 v5): UNA sola
    llamada a `linear_gql`, ignora `pageInfo` por completo. A diferencia del
    fixture-only de la ronda anterior (H2, T07 v6: "un brazo rojo que no
    ejecuta el sujeto no es un brazo rojo"), esta función SÍ llama al
    `linear_gql` mockeado — ejecuta la MISMA forma de request que el código
    real, solo que nunca sigue el cursor."""
    d = ci.linear_gql(api_key, "query FALSO de una sola página", variables={"id": team_id, "after": None}, retry=True)
    return {n["name"]: n["id"] for n in d["team"][campo]["nodes"]}


def guard_labels_paginadas():
    """MAJOR T07 v5 + H2 MENOR T07 v6 (par cruzado): team.labels pagina a 50
    por defecto — medido EN VIVO, 2026-09-08: 78 labels/2 páginas,
    vertical/academy + kind:fix en la SEGUNDA. H2: el brazo rojo de la ronda
    anterior no ejecutaba el sujeto (tautología sobre su propio fixture) —
    ahora el rojo llama a un mutante que SÍ invoca `linear_gql` (mockeado),
    reproduciendo la forma real pre-fix, no solo re-computando un dict."""
    g = {"shortId": "X-1", "title": "t"}
    states_1pag = _resp_campo("states", [{"id": "s1", "name": "Triage"}], False)
    labels_pag1 = _resp_campo("labels", [{"id": "l1", "name": "actor/ai"}], True, "cursor-1")
    labels_pag2 = _resp_campo("labels", [
        {"id": "l2", "name": "vertical/academy"},
        {"id": "l3", "name": "kind:fix"},
    ], False)

    # green: el código REAL (paginar_conexion_team, ejecutado dentro de
    # crear_en_linear) sigue pageInfo hasta agotarlo — call_count == 5:
    # teams + states(1 pág) + labels(pág1) + labels(pág2) + mutation.
    m = mock.Mock(side_effect=[TEAMS_RESP_UNICO, states_1pag, labels_pag1, labels_pag2, MUTATION_RESP_OK])
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(ci, "linear_gql", m))
        stack.enter_context(quiet())
        exit_ocurrio = False
        try:
            ci.crear_en_linear(g, "body", "fix", None, "key")
        except SystemExit:
            exit_ocurrio = True
    green_ok = (exit_ocurrio is False) and (m.call_count == 5)

    # red: el MUTANTE (arriba) SÍ ejecuta linear_gql mockeado, contra el
    # MISMO team de 2 páginas — como ignora pageInfo, solo ve la página 1 y
    # vertical/academy + kind:fix deben quedar AUSENTES.
    m_red = mock.Mock(side_effect=[labels_pag1])
    with mock.patch.object(ci, "linear_gql", m_red):
        labels_mutante = _paginar_conexion_team_mutante_sin_paginar("key", "team-1", "labels")
    red_ok = (m_red.call_count == 1) and ("vertical/academy" not in labels_mutante) \
        and ("kind:fix" not in labels_mutante) and ("actor/ai" in labels_mutante)

    record("22b. crear_en_linear(): team.labels sigue pageInfo/endCursor completo "
           "antes de resolver vertical/academy y kind:fix", green_ok, red_ok)


def guard_states_paginadas():
    """MENOR T07 v6, hallazgo H3: `paginar_conexion_team` es genérico — la
    MISMA clase de bug (leer solo la 1ª página) aplica a `states`, no solo a
    `labels`. Latente hoy (9 states, 1 sola página real), pero la guarda NO
    depende de que crezca: fuerza 2 páginas en el mock, igual que 22b."""
    g = {"shortId": "X-1", "title": "t"}
    states_pag1 = _resp_campo("states", [{"id": "s1", "name": "Backlog"}], True, "cursor-s1")
    states_pag2 = _resp_campo("states", [{"id": "s2", "name": "Triage"}], False)
    labels_1pag = _resp_campo("labels", [
        {"id": "l1", "name": "vertical/academy"},
        {"id": "l2", "name": "actor/ai"},
        {"id": "l3", "name": "kind:fix"},
    ], False)

    m = mock.Mock(side_effect=[TEAMS_RESP_UNICO, states_pag1, states_pag2, labels_1pag, MUTATION_RESP_OK])
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(ci, "linear_gql", m))
        stack.enter_context(quiet())
        exit_ocurrio = False
        try:
            ci.crear_en_linear(g, "body", "fix", None, "key")
        except SystemExit:
            exit_ocurrio = True
    # green: 5 llamadas (teams + states x2 + labels + mutation) y no murió.
    green_ok = (exit_ocurrio is False) and (m.call_count == 5)

    m_red = mock.Mock(side_effect=[states_pag1])
    with mock.patch.object(ci, "linear_gql", m_red):
        states_mutante = _paginar_conexion_team_mutante_sin_paginar("key", "team-1", "states")
    red_ok = (m_red.call_count == 1) and ("Triage" not in states_mutante) and ("Backlog" in states_mutante)

    record("22c (H3). paginar_conexion_team(): states sigue pageInfo igual que labels "
           "(misma clase, latente hoy con 9 filas)", green_ok, red_ok)


def _paginar_conexion_team_mutante_sin_tope(api_key, team_id, campo):
    """Mutante LITERAL de `paginar_conexion_team` SIN el `if paginas >
    TOPE_PAGINAS_CONEXION: die()` (H4 pre-fix): el bucle sigue mientras
    `hasNextPage` sea true, sin límite propio — contra un servidor que
    repite el mismo cursor para siempre, esto nunca termina por sí solo."""
    items: dict[str, str] = {}
    cursor = None
    while True:
        d = ci.linear_gql(api_key, "query FALSA sin tope", variables={"id": team_id, "after": cursor}, retry=True)
        pagina = d["team"][campo]
        items.update({n["name"]: n["id"] for n in pagina["nodes"]})
        if not pagina["pageInfo"].get("hasNextPage"):
            return items
        cursor = pagina["pageInfo"].get("endCursor")


def guard_tope_paginas_conexion():
    """MENOR T07 v6, hallazgo H4: un bug de paginación (cursor que no
    avanza, servidor que repite hasNextPage=true) no debe colgar el proceso
    en un bucle sin fin. `TOPE_PAGINAS_CONEXION` corta con `die()` fail-closed.
    Fixture: 10 páginas idénticas con `hasNextPage=true` (simula un servidor
    que repite el mismo cursor para siempre; en prod sería infinito de verdad,
    aquí acotado porque `mock.Mock` necesita una lista finita)."""
    pagina_infinita = _resp_campo("labels", [{"id": "lx", "name": "x"}], True, "siempre-el-mismo-cursor")
    N_PAGINAS_FIXTURE = 10

    # green: el código REAL, con el tope bajado a 3 (sin tocar la constante
    # de producción), debe morir fail-closed en la página 4 — mucho antes de
    # agotar las 10 disponibles.
    m_green = mock.Mock(side_effect=[pagina_infinita] * N_PAGINAS_FIXTURE)
    exit_ocurrio = False
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(ci, "linear_gql", m_green))
        stack.enter_context(mock.patch.object(ci, "TOPE_PAGINAS_CONEXION", 3))
        stack.enter_context(quiet())
        try:
            ci.paginar_conexion_team("key", "team-1", "labels")
        except SystemExit:
            exit_ocurrio = True
    green_ok = exit_ocurrio and (m_green.call_count == 3)  # murió sin pedir una 4ª página

    # red: el MUTANTE (sin tope alguno) contra el MISMO fixture finito de 10
    # páginas — como no tiene cap propio, consume las 10 disponibles y pide
    # una 11ª: `StopIteration` sin capturar (no `SystemExit`). Confirma que
    # SIN el tope, esto no se detiene por sí solo — solo por agotar el mock
    # (en producción, un servidor real repitiendo el cursor no se agotaría
    # nunca: sería el bucle sin fin real que H4 señala).
    m_red = mock.Mock(side_effect=[pagina_infinita] * N_PAGINAS_FIXTURE)
    murio_por_stopiteration = False
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(ci, "linear_gql", m_red))
        stack.enter_context(quiet())
        try:
            _paginar_conexion_team_mutante_sin_tope("key", "team-1", "labels")
        except StopIteration:
            murio_por_stopiteration = True
        except SystemExit:
            murio_por_stopiteration = False
    red_ok = murio_por_stopiteration and (m_red.call_count == N_PAGINAS_FIXTURE + 1)

    record("22d (H4). paginar_conexion_team(): tope de páginas corta fail-closed "
           "un bucle que no agota hasNextPage", green_ok, red_ok)


# ── 23. construir_body_spike(): el --since del inventario SUGERIDO siempre
# está en STATS_PERIOD_CONTRATO, nunca reusa --ventana (T07, revisor #2165,
# hallazgo [3]). --ventana es el criterio de cierre E/D/5A (default "3h"),
# semánticamente distinto del statsPeriod de sentry_triage.py (solo
# "24h"/"14d" — STATS_PERIOD_CONTRATO). Antes, el body sugería
# `--since {ventana}`: con el default real, el comando que el propio issue
# le decía al lector que corriera MORÍA (die()) al ejecutarse. ──
def guard_inventario_since_valido():
    import re as re_
    g = {"shortId": "AUDIT-1", "title": "t"}

    with quiet():
        cuerpo = ci.construir_body_spike(g, "mi-app@aaaaaaaa", "3h", "2026-09-08", "deadbeef")
    m = re_.search(r"--since (\S+)", cuerpo)
    since_embebido = m.group(1) if m else None
    green_ok = since_embebido is not None and since_embebido in st.STATS_PERIOD_CONTRATO

    # mutante: reproduce el defecto real — INVENTARIO_STATS_PERIOD con el
    # valor de `ventana` (criterio E/D/5A) en vez de un statsPeriod válido.
    with mock.patch.object(ci, "INVENTARIO_STATS_PERIOD", "3h"), quiet():
        cuerpo_mutante = ci.construir_body_spike(g, "mi-app@aaaaaaaa", "3h", "2026-09-08", "deadbeef")
    m2 = re_.search(r"--since (\S+)", cuerpo_mutante)
    since_mutante = m2.group(1) if m2 else None
    red_ok = since_mutante is not None and since_mutante not in st.STATS_PERIOD_CONTRATO
    record("23. construir_body_spike(): --since embebido siempre en STATS_PERIOD_CONTRATO", green_ok, red_ok)


# ── Smokes (green-only; mutante en la issue de seguimiento) ──────────────────────
def smoke_project_scoped():
    captured = {}

    def fake(req, timeout=15):
        captured["url"] = req.full_url
        return FakeResp([])

    with mock.patch.object(st.urllib.request, "urlopen", side_effect=fake):
        st.fetch_issues("org", "proj", "auth", "24h", "date")
    smoke("project-scoped (fetch_issues)",
          captured.get("url", "").startswith("https://sentry.io/api/0/projects/org/proj/issues/"))


# MANIFIESTO INDEPENDIENTE (veredicto r4 del bounce #2165, MAYOR): antes, el
# total reportado (`len(mut_results)`/`len(smoke_results)`) se derivaba del
# MISMO listado que `main()` iteraba para ejecutar — retirar un nombre de la
# tupla de abajo borraba a la vez su ejecución Y el elemento contado, así que
# el conteo se auto-confirmaba sin acreditar que la guarda siguiera
# registrada. El auditor lo probó retirando las 23 entradas UNA A UNA sobre
# copia de `git archive HEAD`: las 23 dieron exit 0.
#
# Este manifiesto es un LITERAL SEPARADO del bucle de `main()` (dos listas
# textualmente distintas en el fichero) — retirar un nombre SOLO de la tupla
# que `main()` recorre (sin tocar este manifiesto) dispara la comparación de
# abajo y enrojece, porque el manifiesto sigue exigiendo esa entrada.
#
# LÍMITE DECLARADO (veredicto r5 del bounce #2165, MAYOR 1 — elegido (b) de
# las dos salidas legítimas ofrecidas, "acotar y declarar" en vez de "anclar
# fuera del artefacto"): este arnés acredita que CADA ENTRADA DEL MANIFIESTO
# SE EJECUTA. NO acredita que el manifiesto no se reduzca EN EL MISMO commit
# junto con el bucle que lo ejecuta — el auditor probó que retirar una guarda
# de la tupla Y su string de este manifiesto A LA VEZ (23/23 combinaciones)
# deja el harness verde, con un conteo más bajo pero SIN rojo. Perseguir esa
# recursión (un manifiesto que vigile a este manifiesto, y otro que vigile a
# ese) no termina nunca y sería tan decorativo como ninguno. Esta reducción
# SÍ es visible por otra vía: `GUARD_MANIFEST`/`SMOKE_MANIFEST` son literales
# EN ESTE FICHERO — cualquier commit que los reduzca aparece en su `git diff`
# como cualquier otro cambio de código; esa visibilidad la vigila la revisión
# del diff, no este harness. Una afirmación acotada y verdadera vale más que
# una ancha y falsa.
# ── 31. TAL-8037: la clave del team Linear y el prefijo de release son de la INSTANCIA ──
def guard_clave_team_instancia():
    """validar_tal (verificar_cese) y la query de team (crear_issue) usan TF_LINEAR_TEAM_KEY, jamás un TAL
    fijo. VERDE: con clave ABC, ABC-1 pasa y TAL-1 muere; sin clave (ni env ni manifiesto) muere nombrando la
    variable; la query del team viaja con la clave de la instancia. ROJO: el mutante pre-fix (clave de casa
    fija, `clave_team` -> "TAL") acepta TAL-1 y consulta el team TAL."""
    def sin_clave(fn):
        env = {k: v for k, v in os.environ.items() if k not in ("TF_LINEAR_TEAM_KEY", "TF_MANIFEST")}
        err = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(err):
            muere = raises_exit(fn)
        return muere and "TF_LINEAR_TEAM_KEY" in err.getvalue()

    def llamada_team(modulo, mutante=False):
        m = mock.Mock(side_effect=[{"teams": {"nodes": []}}])
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(modulo, "linear_gql", m))
            if mutante:
                stack.enter_context(mock.patch.object(modulo, "clave_team", lambda: "TAL"))
            stack.enter_context(quiet())
            try:
                modulo.crear_en_linear({"shortId": "X-1", "title": "t"}, "body", "fix", None, "key")
            except SystemExit:
                pass
        return (m.call_args.kwargs.get("variables") or {}).get("k") if m.call_args else None

    verde = (vc.validar_tal("ABC-1") == "ABC-1"
             and raises_exit(lambda: vc.validar_tal("TAL-1"))
             and sin_clave(lambda: vc.validar_tal("ABC-1"))
             and sin_clave(lambda: ci.clave_team())
             and llamada_team(ci) == "ABC")
    with mock.patch.object(vc, "clave_team", lambda: "TAL"), quiet():
        mutante_acepta_tal = vc.validar_tal("TAL-1") == "TAL-1"
    rojo = mutante_acepta_tal and llamada_team(ci, mutante=True) == "TAL"
    record("31. clave del team Linear = TF_LINEAR_TEAM_KEY de la instancia (validar_tal + query de team), jamás TAL fijo", verde, rojo)


def guard_release_prefijo_instancia():
    """El prefijo del release de Sentry es SENTRY_RELEASE_PREFIX (obligatorio, charset cerrado), sin marca por defecto."""
    ok = vc.release_nombre("aaaaaaaa") == "mi-app@aaaaaaaa"
    env = {k: v for k, v in os.environ.items() if k != "SENTRY_RELEASE_PREFIX"}
    err = io.StringIO()
    with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(err):
        sin_prefijo_muere = raises_exit(lambda: vc.release_nombre("aaaaaaaa"))
    with mock.patch.dict(os.environ, {"SENTRY_RELEASE_PREFIX": "a b"}), quiet():
        invalido_muere = raises_exit(lambda: vc.release_nombre("aaaaaaaa"))
    smoke("release_nombre: prefijo de la instancia, obligatorio y con charset cerrado (sin marca por defecto)",
          ok and sin_prefijo_muere and "SENTRY_RELEASE_PREFIX" in err.getvalue() and invalido_muere)


GUARD_MANIFEST = (
    "guard_identity", "guard_dedupe_both", "guard_no_retry", "guard_window",
    "guard_release_live", "guard_issue_resolve", "guard_cursor",
    "guard_filtro_start_end", "guard_query_unico", "guard_railway_expected",
    "guard_release_shape", "guard_stats_period_para", "guard_hay_novedad_en",
    "guard_cargar_buckets_vacio", "guard_clasifica_substring",
    "guard_es_grupo_nuevo", "guard_enruta_item", "guard_get_network_errors",
    "guard_validar_short_id", "guard_fetch_grupo_query_unico",
    "guard_stats_period_wiring", "guard_validar_short_id_wiring",
    "guard_kind_por_tipo_fail_closed", "guard_inventario_since_valido",
    "guard_dedupe_excluye_cerrados", "guard_dedupe_fail_closed_query_error",
    "guard_money_estable_no_rompe_silencio", "guard_labels_paginadas",
    "guard_states_paginadas", "guard_tope_paginas_conexion",
    "guard_clave_team_instancia",
)
SMOKE_MANIFEST = ("smoke_project_scoped", "guard_release_prefijo_instancia")


def main() -> int:
    ran_guards: list[str] = []
    for g in (guard_identity, guard_dedupe_both, guard_no_retry, guard_window,
              guard_release_live, guard_issue_resolve, guard_cursor,
              guard_filtro_start_end, guard_query_unico, guard_railway_expected,
              guard_release_shape, guard_stats_period_para, guard_hay_novedad_en,
              guard_cargar_buckets_vacio, guard_clasifica_substring,
              guard_es_grupo_nuevo, guard_enruta_item, guard_get_network_errors,
              guard_validar_short_id, guard_fetch_grupo_query_unico,
              guard_stats_period_wiring, guard_validar_short_id_wiring,
              guard_kind_por_tipo_fail_closed, guard_inventario_since_valido,
              guard_dedupe_excluye_cerrados, guard_dedupe_fail_closed_query_error,
              guard_money_estable_no_rompe_silencio, guard_labels_paginadas,
              guard_states_paginadas, guard_tope_paginas_conexion,
              guard_clave_team_instancia):
        ran_guards.append(g.__name__)
        try:
            g()
        except (Exception, SystemExit) as e:  # un guard que aborta sigue siendo FAIL
            record(f"{g.__name__} (EXCEPCIÓN: {e})", False, False)
    ran_smokes: list[str] = []
    for s in (smoke_project_scoped, guard_release_prefijo_instancia):
        ran_smokes.append(s.__name__)
        try:
            s()
        except (Exception, SystemExit) as e:
            smoke(f"{s.__name__} (EXCEPCIÓN: {e})", False)

    print("== Guardas mutación-acreditadas (green = protege; red = el mutante rompe) ==")
    all_ok = True
    for name, green_ok, red_ok in mut_results:
        ok = green_ok and red_ok
        all_ok = all_ok and ok
        print(f"  [{'PASS' if ok else 'FALLO'}] {name}  (green={'OK' if green_ok else 'X'}, red={'OK' if red_ok else 'X'})")
    print("== Smokes (green-only) ==")
    for name, ok in smoke_results:
        all_ok = all_ok and ok
        print(f"  [{'PASS' if ok else 'FALLO'}] {name}")

    # Verificación del manifiesto: ¿lo que REALMENTE se ejecutó coincide con
    # lo que el manifiesto EXIGE? Si una guarda desapareció de la tupla de
    # arriba (o se coló una no declarada), esto enrojece aquí — no en el
    # conteo, que ya no puede auto-confirmarse.
    guards_faltantes = sorted(set(GUARD_MANIFEST) - set(ran_guards))
    guards_inesperadas = sorted(set(ran_guards) - set(GUARD_MANIFEST))
    smokes_faltantes = sorted(set(SMOKE_MANIFEST) - set(ran_smokes))
    smokes_inesperadas = sorted(set(ran_smokes) - set(SMOKE_MANIFEST))
    print("== Manifiesto (independiente del bucle que se ejecuta) ==")
    if guards_faltantes or guards_inesperadas or smokes_faltantes or smokes_inesperadas:
        all_ok = False
        if guards_faltantes:
            print(f"  [FALLO] guardas del manifiesto NUNCA ejecutadas: {guards_faltantes}")
        if guards_inesperadas:
            print(f"  [FALLO] guardas ejecutadas SIN estar en el manifiesto: {guards_inesperadas}")
        if smokes_faltantes:
            print(f"  [FALLO] smokes del manifiesto NUNCA ejecutados: {smokes_faltantes}")
        if smokes_inesperadas:
            print(f"  [FALLO] smokes ejecutados SIN estar en el manifiesto: {smokes_inesperadas}")
    else:
        print(f"  [PASS] {len(ran_guards)}/{len(GUARD_MANIFEST)} guardas + "
              f"{len(ran_smokes)}/{len(SMOKE_MANIFEST)} smokes — coincide exacto con el manifiesto")

    # LÍMITE en la salida VISIBLE, no solo en comentario (veredicto r6 del
    # bounce #2165, MAYOR: "el consumidor de stdout no puede distinguir
    # cobertura intacta de contrato reducido sin abrir el fuente o el
    # HANDOFF"). La MISMA línea que afirma "TODO VERDE" es la que tiene que
    # acotar lo que esa afirmación NO cubre — un límite que el consumidor no
    # lee no acota la afirmación que el consumidor sí lee.
    LIMITE_MANIFIESTO = ("no acredita que GUARD_MANIFEST/SMOKE_MANIFEST no se hayan "
                          "reducido junto con el bucle en el mismo commit")

    print()
    if all_ok:
        print(f"RESULTADO: TODO VERDE — {len(GUARD_MANIFEST)} guardas mutación-acreditadas + "
              f"{len(SMOKE_MANIFEST)} smokes (manifiesto verificado; {LIMITE_MANIFIESTO}).")
        return 0
    print("RESULTADO: FALLO — alguna guarda no protege (green), su mutante no rompe (red), "
          "o el manifiesto no coincide con lo ejecutado.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
