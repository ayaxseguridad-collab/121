#!/usr/bin/env python3
"""Doble de `gh` para test-parte-guardia.sh (se envuelve con gh_contrato.py --envolver: gh 2.45.0).
Sirve $PARTE_DOBLE_DIR/<superficie>.out; `<superficie>.rc` + `<superficie>.err` simulan un fallo. Nunca abre red."""
import os
import sys

D = os.environ["PARTE_DOBLE_DIR"]
ep = sys.argv[-1]
sup = None
for nombre, ruta in (("dependabot", "dependabot/alerts"), ("code-scanning", "code-scanning/alerts"),
                     ("secret-scanning", "secret-scanning/alerts"), ("advisories", "security-advisories")):
    if "/" + ruta + "?" in ep:
        sup = nombre
if sup is None:
    sys.stderr.write("endpoint inesperado\n")
    sys.exit(9)
rc_f = os.path.join(D, sup + ".rc")
if os.path.exists(rc_f):
    sys.stderr.write(open(os.path.join(D, sup + ".err")).read())
    sys.exit(int(open(rc_f).read()))
sys.stdout.write(open(os.path.join(D, sup + ".out")).read())
