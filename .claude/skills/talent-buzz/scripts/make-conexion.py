#!/usr/bin/env python3
"""Genera el runbook de conexion del equipo INYECTANDO las claves al vuelo.

El runbook resultante CONTIENE CLAVES PRIVADAS: nace 0600 y no se versiona
jamas (leccion rodada: un doc de onboarding con claves en claro es una fuga
esperando a ser compartida). Este generador es lo que se versiona; el runbook
se regenera cuando haga falta y se destruye despues de usarlo.

Uso:
    python3 make-conexion.py --keys keys.json --relay-url ws://HOST \
        [--out CONEXION.md] [--channels "#general=UUID,#agentes=UUID"]
"""
import argparse
import json
import os


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--relay-url", required=True)
    ap.add_argument("--out", default="CONEXION.md")
    ap.add_argument("--channels", default="")
    args = ap.parse_args()

    with open(args.keys) as f:
        keys = json.load(f)

    lines = [
        "# CONEXION del equipo Buzz",
        "",
        "> ⚠️ ESTE ARCHIVO CONTIENE CLAVES PRIVADAS. Permisos 0600, no se versiona,",
        "> no se comparte por canales inseguros, y se destruye tras el onboarding.",
        "",
        f"Relay: `{args.relay_url}`",
    ]
    if args.channels:
        pretty = " · ".join(
            f"`{name.strip()}` = `{uuid.strip()}`"
            for name, _, uuid in (c.partition("=") for c in args.channels.split(","))
            if uuid.strip())
        lines.append(f"Canales: {pretty}")
    lines.append("")

    for member, kp in keys.items():
        if member.startswith("_"):
            continue  # la identidad del relay no se reparte
        lines += [
            f"## {member}",
            "",
            "```bash",
            f"export BUZZ_RELAY_URL={args.relay_url}",
            f"export BUZZ_PRIVATE_KEY={kp['nsec']}",
            "```",
            "",
            f"npub: `{kp['npub']}`",
            "",
        ]

    # O_NOFOLLOW: el runbook lleva claves privadas — sin el, un symlink plantado
    # en args.out redirigiria la escritura a un fichero del atacante.
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    # El modo de os.open solo aplica AL CREAR: si el archivo ya existia con
    # permisos laxos, O_TRUNC los conservaria. Se fuerzan siempre.
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines))
    print(f"runbook generado en {args.out} (0600) — destruyelo tras el onboarding")


if __name__ == "__main__":
    main()
