"""Doble de urlopen de Sentry para test-parte-guardia.sh. Se carga SOLO por PYTHONPATH en la prueba.

Sin PARTE_DOBLE_DIR no hace nada. Sirve $PARTE_DOBLE_DIR/<sort>-<n>.json (n = cursor, 1 por defecto) con
`Link: …rel="next"; results="true"` mientras exista la página siguiente; `sentry.fallo` (un código HTTP) hace
fallar toda petición. Nunca abre un socket: cualquier URL fuera del endpoint de issues de Sentry es un error.
"""
import os
import urllib.error
import urllib.parse
import urllib.request

_D = os.environ.get("PARTE_DOBLE_DIR")


class _Resp:
    def __init__(self, cuerpo, link):
        self._b, self.status = cuerpo, 200
        self.headers = {"Link": link} if link else {}

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _urlopen(req, timeout=15):
    url = req.full_url
    with open(os.path.join(_D, "sentry-peticiones.log"), "a") as f:
        f.write(url + "\n")
    if not url.startswith("https://sentry.io/api/0/projects/"):
        raise urllib.error.URLError("destino fuera del endpoint de Sentry")
    fallo = os.path.join(_D, "sentry.fallo")
    if os.path.exists(fallo):
        raise urllib.error.HTTPError(url, int(open(fallo).read()), "doble", {}, None)
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    sort, n = q.get("sort", ["date"])[0], int(q.get("cursor", ["1"])[0])
    pagina = os.path.join(_D, f"{sort}-{n}.json")
    if not os.path.exists(pagina):
        raise urllib.error.URLError("sin datos en el doble")
    hay_mas = os.path.exists(os.path.join(_D, f"{sort}-{n + 1}.json"))
    link = f'<{url.split("?")[0]}?query=is:unresolved&sort={sort}&cursor={n + 1}>; rel="next"; results="true"' if hay_mas else None
    return _Resp(open(pagina, "rb").read(), link)


if _D:
    urllib.request.urlopen = _urlopen
