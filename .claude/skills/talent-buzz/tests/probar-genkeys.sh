#!/usr/bin/env bash
# genkeys.py: 0600 de nacimiento, nsec/npub coherentes, y NEGATIVA a sobrescribir.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GK="$DIR/../scripts/genkeys.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0

python3 "$GK" --out "$TMP/keys.json" --members "owner,fenix,_relay" >/dev/null

perms=$(stat -c '%a' "$TMP/keys.json")
if [ "$perms" = "600" ]; then echo "OK  permisos 0600 de nacimiento"; else echo "FALLO permisos: $perms"; fallos=$((fallos+1)); fi

if GK_DIR="$(dirname "$GK")" python3 - "$TMP/keys.json" <<'EOF'
import json, os, sys
sys.path.insert(0, os.environ["GK_DIR"])
import genkeys  # el import NO genera nada (guard __main__): eso tambien se prueba aqui

CHARSET = genkeys.CHARSET

def bech32_decode(bech):
    pos = bech.rfind("1")
    hrp, data = bech[:pos], bech[pos + 1:]
    values = [CHARSET.index(c) for c in data]
    # checksum
    assert genkeys._polymod(genkeys._hrp_expand(hrp) + values) == 1, f"checksum invalido en {bech}"
    return hrp, bytes(genkeys._convertbits(values[:-6], 5, 8)[:32])

keys = json.load(open(sys.argv[1]))
assert set(keys) == {"owner", "fenix", "_relay"}, sorted(keys)
for m, kp in keys.items():
    assert len(kp["private_key"]) == 64 and len(kp["public_key"]) == 64
    # bech32 decodifica (checksum valido) y coincide byte a byte con el hex
    hrp, raw = bech32_decode(kp["nsec"])
    assert hrp == "nsec" and raw.hex() == kp["private_key"], f"{m}: nsec != private_key"
    hrp, raw = bech32_decode(kp["npub"])
    assert hrp == "npub" and raw.hex() == kp["public_key"], f"{m}: npub != public_key"
    # la pubkey deriva DE VERDAD de la privada (BIP340 x-only, y par)
    sk = int(kp["private_key"], 16)
    x, y = genkeys._mul(sk, genkeys.G)
    assert y % 2 == 0, f"{m}: la clave privada no esta normalizada a y par"
    assert f"{x:064x}" == kp["public_key"], f"{m}: public_key no deriva de private_key"
EOF
then
  echo "OK  estructura, bech32 y coherencia criptografica"
else
  echo "FALLO coherencia criptografica"; fallos=$((fallos+1))
fi

if python3 "$GK" --out "$TMP/keys.json" --members owner >/dev/null 2>&1; then
  echo "FALLO: sobrescribio un keys.json existente"; fallos=$((fallos+1))
else
  echo "OK  se niega a sobrescribir keys.json existente"
fi

if [ "$fallos" -eq 0 ]; then echo "probar-genkeys: TODO OK"; else echo "probar-genkeys: $fallos fallos"; exit 1; fi
