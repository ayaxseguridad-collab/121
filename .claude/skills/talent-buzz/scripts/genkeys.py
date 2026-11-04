#!/usr/bin/env python3
"""Genera identidades Nostr (secp256k1, BIP340 x-only) para el equipo Buzz.

Uso:
    python3 genkeys.py --out keys.json [--members owner,fenix,_relay]

Reglas de seguridad (lecciones rodadas):
- Se NIEGA a sobrescribir un keys.json existente: ese archivo es la unica
  copia de las identidades del equipo. Borralo a mano si de verdad quieres
  regenerar TODO (y asume que las identidades viejas mueren).
- El archivo nace con permisos 0600, no se corrigen despues.
- Importar este modulo NO genera nada: todo vive bajo __main__.
"""
import argparse
import hashlib  # noqa: F401  (parity con la implementacion de referencia)
import json
import os
import secrets

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _inv(a, m):
    return pow(a, m - 2, m)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1) * _inv(2 * y1, P) % P
    else:
        lam = (y2 - y1) * _inv(x2 - x1, P) % P
    x3 = (lam * lam - x1 - x2) % P
    return (x3, (lam * (x1 - x3) - y1) % P)


def _mul(k, point):
    r = None
    while k:
        if k & 1:
            r = _add(r, point)
        point = _add(point, point)
        k >>= 1
    return r


CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _polymod(values):
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if ((b >> i) & 1) else 0
    return chk


def _hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _bech32_encode(hrp, data):
    polymod = _polymod(_hrp_expand(hrp) + data + [0] * 6) ^ 1
    chk = [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
    return hrp + "1" + "".join(CHARSET[d] for d in data + chk)


def _convertbits(data, frombits, tobits):
    acc, bits, ret = 0, 0, []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def keypair():
    """Par (priv_hex, pub_hex) con pubkey x-only par (BIP340)."""
    while True:
        sk = secrets.randbits(256)
        if 1 <= sk < N:
            break
    x, y = _mul(sk, G)
    if y % 2 == 1:
        sk = N - sk
        x, y = _mul(sk, G)
    return f"{sk:064x}", f"{x:064x}"


def entry(priv_hex, pub_hex):
    return {
        "private_key": priv_hex,
        "public_key": pub_hex,
        "nsec": _bech32_encode("nsec", _convertbits(bytes.fromhex(priv_hex), 8, 5)),
        "npub": _bech32_encode("npub", _convertbits(bytes.fromhex(pub_hex), 8, 5)),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="ruta del keys.json a crear")
    ap.add_argument("--members", default="owner,fenix,_relay",
                    help="lista separada por comas (defecto: owner,fenix,_relay)")
    args = ap.parse_args()

    path = os.path.abspath(args.out)
    if os.path.exists(path):
        raise SystemExit(
            f"ABORTADO: {path} ya existe. keys.json es la unica copia de las "
            "identidades: borralo a mano si de verdad quieres regenerar TODO.")

    members = [m.strip() for m in args.members.split(",") if m.strip()]
    if not members:
        raise SystemExit("ABORTADO: lista de miembros vacia")

    out = {}
    for m in members:
        sk, pk = keypair()
        out[m] = entry(sk, pk)

    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(out, f, indent=2)
    print(f"claves generadas en {path} (0600)")
    for m, kp in out.items():
        print(f"  {m}: pub {kp['public_key']}")


if __name__ == "__main__":
    main()
