#!/usr/bin/env python3
"""Resuelve una ficha solo tras verificar PR, deploy y cese en esta corrida.

Sin --apply solo consulta. El token de escritura se lee exclusivamente con
--apply, desde un header-file 0600 distinto del de lectura. Ningún error de
fuente imprime respuestas crudas ni credenciales. El PUT no se reintenta.
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
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SELLADOR = HERE.parent.parent / "talent-ceo/scripts/bus-sellar.sh"
UA = "talent-sentry-guard-resolver/1"


def cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, HERE / f"{nombre}.py")
    modulo = importlib.util.module_from_spec(spec)
    sys.modules[nombre] = modulo
    spec.loader.exec_module(modulo)
    return modulo


vc = cargar("verificar_cese")
ci = cargar("crear_issue_desde_sentry")


class Rechazo(Exception):
    def __init__(self, mensaje, rc=3):
        super().__init__(mensaje)
        self.rc = rc


def exigir(condicion, mensaje, rc=3):
    if not condicion:
        raise Rechazo(mensaje, rc)


def fuente(etiqueta, funcion, *args, **kwargs):
    """Las bibliotecas heredadas pueden imprimir errores con cuerpos remotos.

    Encapsular su diagnóstico evita filtrar secretos incluso si una fuente
    los refleja; la etiqueta conserva cuál prueba no pudo demostrarse.
    """
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return funcion(*args, **kwargs)
    except (Exception, SystemExit):
        raise Rechazo(f"{etiqueta} fuente no verificable") from None


def requerida(nombre):
    valor = os.environ.get(nombre, "").strip()
    exigir(bool(valor), f"config ausente: {nombre}", 2)
    return valor


def header(nombre, ruta):
    exigir(ruta.is_absolute() and ruta.is_file() and not ruta.is_symlink(),
           f"{nombre}: header-file regular absoluto obligatorio", 2)
    exigir(ruta.stat().st_mode & 0o777 == 0o600, f"{nombre}: permisos deben ser 0600", 2)
    try:
        lineas = ruta.read_text().splitlines()
    except (OSError, UnicodeError):
        raise Rechazo(f"{nombre}: header-file ilegible", 2) from None
    exigir(len(lineas) == 1 and lineas[0].startswith("Authorization: ") and
           bool(lineas[0][15:].strip()) and
           not any(ord(c) < 32 or ord(c) == 127 for c in lineas[0]),
           f"{nombre}: formato Authorization inválido", 2)
    return lineas[0][15:]


def configurar(args):
    org = requerida("SENTRY_ORG")
    prefijo = requerida("SENTRY_RELEASE_PREFIX")
    exigir(re.fullmatch(r"[A-Za-z0-9._-]+", org), "SENTRY_ORG inválida", 2)
    exigir(re.fullmatch(r"[A-Za-z0-9._-]+", prefijo), "SENTRY_RELEASE_PREFIX inválida", 2)
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            clave = vc.clave_team()
    except (Exception, SystemExit):
        raise Rechazo("TF_LINEAR_TEAM_KEY sin resolver o inválida", 2) from None
    bus = Path(requerida("TA_BUS"))
    exigir(bus.is_absolute() and bus.is_file(), "TA_BUS debe ser fichero absoluto legible", 2)
    try:
        bus.read_text()
    except (OSError, UnicodeError):
        raise Rechazo("TA_BUS ilegible", 2) from None
    key = requerida("LINEAR_API_KEY")
    lectura = Path(os.environ.get("SENTRY_HDR", str(Path.home() / ".vigia-sentry/hdr")))
    auth = header("SENTRY_HDR", lectura)
    escritura = None
    if args.apply:
        ruta = Path(requerida("SENTRY_HDR_RESOLVER"))
        exigir(ruta.is_absolute() and ruta.is_file(), "SENTRY_HDR_RESOLVER ausente", 2)
        exigir(not ruta.samefile(lectura), "SENTRY_HDR_RESOLVER debe ser distinto de SENTRY_HDR", 2)
        escritura = header("SENTRY_HDR_RESOLVER", ruta)
    exigir(re.fullmatch(rf"{re.escape(clave)}-\d+", args.tal), "--tal inválido", 2)
    exigir(re.fullmatch(r"[A-Z0-9][A-Z0-9-]*", args.short_id), "--short-id inválido", 2)
    exigir(len(f"VIGIA-RESUELTA-{args.short_id}-1234567") <= 64, "--short-id excede marcador", 2)
    exigir(re.fullmatch(r"[A-Za-z0-9_-]{1,32}", args.rol), "--rol inválido", 2)
    exigir(re.fullmatch(r"[1-9][0-9]*[hd]", args.ventana), "--ventana debe ser positiva Nh/Nd", 2)
    return org, bus, key, auth, escritura


def prueba_1(tal, short_id, key):
    argv = ["gh", "pr", "list", "--state", "merged", "--base", "main", "--search", tal,
            "--json", "number,body,mergeCommit,mergedAt,baseRefName"]
    try:
        resultado = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        exigir(resultado.returncode == 0, "PRUEBA-1 gh rechazó la consulta")
        prs = json.loads(resultado.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise Rechazo("PRUEBA-1 gh ausente o salida no JSON") from None
    exigir(isinstance(prs, list), "PRUEBA-1 lista de PR inválida")
    patron = re.compile(rf"\bcloses\s+{re.escape(tal)}\b(?![\w-])", re.I)
    candidatos = []
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        merge = pr.get("mergeCommit")
        sha = merge.get("oid") if isinstance(merge, dict) else None
        if (pr.get("baseRefName") == "main" and isinstance(pr.get("mergedAt"), str)
                and vc._parse_iso_safe(pr["mergedAt"]) is not None
                and isinstance(pr.get("body"), str) and patron.search(pr["body"])
                and isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                and type(pr.get("number")) is int and pr["number"] > 0):
            candidatos.append(pr)
    exigir(len(candidatos) == 1, "PRUEBA-1 se exige un PR inequívoco fundido a main con closes")
    data = fuente("PRUEBA-1", ci.linear_gql, key,
                  "query($id:String!){issue(id:$id){identifier description}}",
                  {"id": tal}, retry=True)
    issue = data.get("issue") if isinstance(data, dict) else None
    exigir(isinstance(issue, dict) and issue.get("identifier") == tal and
           isinstance(issue.get("description"), str) and
           re.search(rf"(?<![A-Z0-9-]){re.escape(short_id)}(?![A-Z0-9-])", issue["description"]),
           "PRUEBA-1 la issue de Linear no cita el shortId exacto")
    return candidatos[0]


def prueba_2(org, sha, auth):
    ancla_iso = fuente("PRUEBA-2", vc.release_live_at, org, sha[:8], auth, UA)
    exigir(ancla_iso is not None, "PRUEBA-2 release aún no LIVE")
    ancla = fuente("PRUEBA-2", vc.parse_iso, ancla_iso)
    estado = fuente("PRUEBA-2", vc.corroborar_railway,
                    os.environ.get("SENTRY_DOCTOR_RAILWAY_CLI", "railway"),
                    os.environ.get("SENTRY_DOCTOR_RAILWAY_EXPECTED"))
    conocidos = {"NEEDS_APPROVAL", "FAILED", "CRASHED", "REMOVED", "CANCELED", "CANCELLED",
                 "QUEUED", "WAITING", "INITIALIZING", "BUILDING", "DEPLOYING", "SKIPPED", "SLEEPING"}
    exigir(estado not in conocidos, "PRUEBA-2 Railway no terminó con éxito")
    if estado != "SUCCESS":
        print("PRUEBA-2 Railway sin corroboración; ancla verificada en Sentry", file=sys.stderr)
    return ancla


def prueba_3(bus, tal, release, org, short_id, ancla, ventana, auth):
    marcador = f"SENTRY-VERIFICA-{tal}-OK"
    try:
        lineas = bus.read_text().splitlines()
    except (OSError, UnicodeError):
        raise Rechazo("PRUEBA-3 TA_BUS ilegible") from None
    valido = False
    for linea in lineas:
        m = re.fullmatch(r"\S+ \[rol: [A-Za-z0-9_-]{1,32}\] \[marcador: " +
                         re.escape(marcador) + r"\] (.+)", linea)
        if not m:
            continue
        campos = re.findall(r"\b(release|eventos_nuevos)=([^\s]+)", m[1])
        if (campos.count(("release", release)) == 1 and
                campos.count(("eventos_nuevos", "0")) == 1 and len(campos) == 2):
            valido = True
    exigir(valido, "PRUEBA-3 falta sello OK con release exacto y eventos_nuevos=0")
    td = vc.parse_ventana(ventana)
    exigir(vc.window_has_elapsed(ancla, td, datetime.now(timezone.utc)),
           "PRUEBA-3 ventana aún no transcurrida")
    issue_id, first_seen = fuente("PRUEBA-3", vc.resolver_issue_id, org, short_id, auth, UA)
    exigir(re.fullmatch(r"[0-9]+", issue_id), "PRUEBA-3 id de Sentry inválido")
    fin = ancla + td
    count, capado = fuente("PRUEBA-3", vc.contar_eventos, org, issue_id, ancla, fin, auth, UA)
    exigir(count == 0 and not capado, "PRUEBA-3 eventos nuevos o cuenta capada")
    filtro = fuente("PRUEBA-3", vc.filtro_start_end_verificado,
                    org, issue_id, first_seen, ancla, fin, count, auth, UA)
    exigir(filtro is True, "PRUEBA-3 filtro start/end no verificado")
    return issue_id


def aplicar(org, issue_id, auth):
    url = f"https://sentry.io/api/0/organizations/{org}/issues/{issue_id}/"
    req = urllib.request.Request(url, data=b'{"status":"resolved"}', method="PUT",
                                 headers={"Authorization": auth, "User-Agent": UA,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            exigir(200 <= resp.status < 300, "PUT rechazado")
            body = json.loads(resp.read())
            exigir(isinstance(body, dict) and body.get("id") == issue_id and
                   body.get("status") == "resolved", "PUT sin confirmación de resolución")
    except Rechazo:
        raise
    except Exception:
        raise Rechazo("PUT falló; no se reintenta ni se sella") from None


def ejecutar(args):
    org, bus, key, auth, escritura = configurar(args)
    pr = prueba_1(args.tal, args.short_id, key)
    sha = pr["mergeCommit"]["oid"]
    ancla = prueba_2(org, sha, auth)
    release = vc.release_nombre(sha[:8])
    issue_id = prueba_3(bus, args.tal, release, org, args.short_id, ancla, args.ventana, auth)
    nota = (f"pr={pr['number']} merge={sha} release={release} "
            f"eventos_nuevos=0 ventana={args.ventana}")
    if not args.apply:
        print(f"RESOLVERÍA {args.short_id} {nota}")
        return 0
    status, grupo, _ = fuente("PRUEBA-3", vc._get,
                             f"https://sentry.io/api/0/organizations/{org}/issues/{issue_id}/", auth, UA)
    exigir(status == 200 and isinstance(grupo, dict) and grupo.get("id") == issue_id and
           grupo.get("shortId") == args.short_id and grupo.get("status") in {"resolved", "unresolved"},
           "PRUEBA-3 estado del grupo no verificable")
    resuelta = grupo["status"] == "resolved"
    if not resuelta:
        aplicar(org, issue_id, escritura)
    marcador = f"VIGIA-RESUELTA-{args.short_id}-{sha[:7]}"
    try:
        r = subprocess.run(["bash", str(SELLADOR), "--marcador", marcador,
                            "--rol", args.rol, "--nota", nota],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        raise Rechazo("resuelta en Sentry; sellador no disponible") from None
    exigir(r.returncode == 0 or (resuelta and r.returncode == 3),
           "resuelta en Sentry; sello rechazado", r.returncode or 3)
    print(f"{'YA RESUELTA' if resuelta else 'RESUELTA'} {args.short_id} {marcador} {nota}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--short-id", required=True)
    ap.add_argument("--tal", required=True)
    ap.add_argument("--rol", required=True)
    ap.add_argument("--ventana", default="3h")
    modo = ap.add_mutually_exclusive_group()
    modo.add_argument("--apply", action="store_true")
    modo.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    try:
        return ejecutar(args)
    except Rechazo as e:
        print(f"resolver_ficha: {e}", file=sys.stderr)
        return e.rc
    except (Exception, SystemExit):
        print("resolver_ficha: fuente o configuración no verificable", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
