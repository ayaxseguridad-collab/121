#!/usr/bin/env python3
"""Generador de dobles para test-parte-guardia.sh (datos sintéticos, sin red).

  generar.py <dir> --grupos N [--nuevos K] [--nuevos-hace-min M] [--gh A] [--gh-nuevos J] [--estado-previo SEG]

Escribe en <dir>:
  date-<n>.json / freq-<n>.json  páginas de 100 grupos de Sentry (freq ordena por eventos: los conocidos llevan 500). Los K
                                 últimos grupos son NUEVOS: 141 eventos y firstSeen = ahora - M min (fecha fija si M se omite);
                                 quedan en la segunda página de AMBAS ordenaciones, como el caso del 14-sep.
  dependabot.out ...             las cuatro superficies de GitHub para el doble de gh: A alertas de dependabot en páginas
                                 de 100 (listas JSON concatenadas, como `gh api --paginate`); 1 de cada 10 es medium
                                 (S3, cuenta como conocida si hay estado previo); las J últimas son high (S2, nuevas);
                                 un secret scanning con valor sintético (jamás debe salir por ninguna salida).
  (--reflejo T)                  T aparece en el título y en el enlace de los K grupos nuevos (prueba de credencial reflejada);
                                 --reflejo-en titulo|enlace|ambos elige dónde y --partir N la rompe con un salto de línea tras N caracteres.
  estado.json                   (solo con --estado-previo) el estado del parte anterior, hace SEG segundos, que conoce
                                 todos los grupos salvo los K nuevos y todas las alertas S1-S3 salvo las J nuevas.
Determinista: sin M, ninguna fecha depende del reloj (la línea base de carga es idéntica byte a byte).
"""
import argparse
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--grupos", type=int, default=0)
ap.add_argument("--nuevos", type=int, default=0)
ap.add_argument("--nuevos-hace-min", type=int, default=None)
ap.add_argument("--gh", type=int, default=0)
ap.add_argument("--gh-nuevos", type=int, default=0)
ap.add_argument("--estado-previo", type=int, default=None)
ap.add_argument("--reflejo", default="", help="texto (un token sintético) que se refleja en el título y el enlace de los grupos nuevos")
ap.add_argument("--reflejo-en", choices=("titulo", "enlace", "ambos"), default="ambos")
ap.add_argument("--partir", type=int, default=0, help="parte --reflejo con un salto de línea tras N caracteres (la fuente rompe la credencial)")
a = ap.parse_args()
REFLEJO = (a.reflejo[:a.partir] + "\n" + a.reflejo[a.partir:]) if a.partir and a.reflejo else a.reflejo
d = Path(a.dir)
d.mkdir(parents=True, exist_ok=True)

FIJA_ANTIGUA = "2026-09-14T09:00:00+00:00"
FIJA_NUEVA = "2026-09-14T17:20:00+00:00"
nueva_fs = FIJA_NUEVA if a.nuevos_hace_min is None else (
    datetime.now(timezone.utc) - timedelta(minutes=a.nuevos_hace_min)).isoformat()


def grupo(i, nuevo):
    return {"id": f"G{i:05d}", "shortId": f"PROY-{i}",
            "title": (f"fallo nuevo {i} tras el despliegue" + (f" {REFLEJO}" if REFLEJO and a.reflejo_en in ("titulo", "ambos") else ""))
            if nuevo else f"error conocido {i}",
            "culprit": f"app/ruta{i}", "count": "141" if nuevo else "500", "userCount": "7" if nuevo else "0",
            "firstSeen": nueva_fs if nuevo else FIJA_ANTIGUA, "lastSeen": nueva_fs,
            "permalink": f"https://example.invalid/g{i}" + (f"?t={REFLEJO}" if REFLEJO and nuevo and a.reflejo_en in ("enlace", "ambos") else "")}


grupos = [grupo(i, i > a.grupos - a.nuevos) for i in range(1, a.grupos + 1)]
for sort, orden in (("date", grupos), ("freq", sorted(grupos, key=lambda g: -int(g["count"])))):
    for n, ini in enumerate(range(0, max(len(orden), 1), 100), start=1):
        (d / f"{sort}-{n}.json").write_text(json.dumps(orden[ini:ini + 100]))


def alerta(i, nuevo):
    sev = "high" if nuevo else ("medium" if i % 10 == 0 else "low")
    return {"number": i, "state": "open", "created_at": "2026-10-01T10:00:00Z",
            "html_url": f"https://example.invalid/repo-ejemplo/security/dependabot/{i}",
            "dependency": {"package": {"ecosystem": "npm", "name": f"paquete-{i}"}, "manifest_path": "package-lock.json"},
            "security_advisory": {"ghsa_id": "GHSA-aaaa-bbbb-cccc", "summary": f"vulnerabilidad {i}", "severity": sev},
            "security_vulnerability": {"severity": sev}}


alertas = [alerta(i, i > a.gh - a.gh_nuevos) for i in range(1, a.gh + 1)]
paginas = [alertas[i:i + 100] for i in range(0, max(len(alertas), 1), 100)]
(d / "dependabot.out").write_text("\n".join(json.dumps(p) for p in paginas))
(d / "code-scanning.out").write_text("[]")
(d / "advisories.out").write_text("[]")
(d / "secret-scanning.out").write_text(json.dumps([{
    "number": 1, "state": "open", "created_at": "2026-10-01T10:00:00Z",
    "html_url": "https://example.invalid/repo-ejemplo/security/secret-scanning/1",
    "secret_type": "clave_ejemplo", "secret_type_display_name": "Clave de ejemplo",
    "secret": "SECRETO-SINTETICO-ZZ9QX7-NO-REAL"}]))

if a.estado_previo is not None:
    conocidos_gh = ["secret-scanning:1"] + [f"dependabot:{x['number']}" for x in alertas
                                            if x["security_advisory"]["severity"] == "medium"]
    (d / "estado.json").write_text(json.dumps({
        "version": 1, "instant_epoch": int(time.time()) - a.estado_previo, "instant": "previo",
        "sentry_ids": sorted(g["id"] for g in grupos if not g["title"].startswith("fallo nuevo")),
        "github_ids": sorted(conocidos_gh)}))
