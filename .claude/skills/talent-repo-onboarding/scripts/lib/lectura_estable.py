#!/usr/bin/env python3
"""Lectura ESTABLE de GitHub tras escribir (`gh api`, solo GET).

Justo después de una escritura, GitHub puede servir respuestas de réplicas distintas y alternar
nuevo → viejo → nuevo durante unos segundos: una relectura única, o dos seguidas, no garantizan nada.
Este helper lee hasta tener LECTURAS_ESTABLES lecturas SEGUIDAS iguales a lo pedido, separadas
INTERVALO_S segundos. Una lectura distinta pone la cuenta a cero. Al llegar a TOPE_S se rinde con un
mensaje claro. No ablanda nada: quien llama sigue evaluando la ÚLTIMA respuesta como antes.

Módulo (lo usa instalacion/scripts/proteccion.py):
    leer_estable(leer, esperado, endpoint) -> (estable, ultima, mensaje)
    `leer()` devuelve la respuesta ya parseada; sus errores (gh, JSON) se propagan sin reintentar.

CLI (la usa scripts/verify-repo-parity.sh en modo en vivo):
    python3 lectura_estable.py ENDPOINT ESPERADO_JSON
    stdout: la ÚLTIMA respuesta leída, tal cual; si gh falla, su salida (stdout y stderr).
    stderr: el mensaje si no se estabiliza o si la respuesta no es JSON.
    rc: RC_ESTABLE 0 · RC_USO 2 · RC_GH 3 · RC_NO_PARSEABLE 4 · RC_INESTABLE 5.

Reloj y espera: `_ahora` y `_dormir` son funciones del módulo y las pruebas las sustituyen. En la CLI,
LECTURA_ESTABLE_RELOJ=simulado cambia SOLO el espaciado: avanza un reloj virtual en vez de dormir.
El criterio (lecturas seguidas, reinicio de la cuenta y tope) es el mismo. Cualquier otro valor no
vacío es un error de uso: un modo desconocido no se ignora.

Solo biblioteca estándar de Python 3.
"""
import json
import os
import subprocess
import sys
import time

LECTURAS_ESTABLES = 3   # lecturas SEGUIDAS iguales a lo pedido
INTERVALO_S = 5         # segundos entre lecturas
TOPE_S = 60             # segundos como máximo desde la primera lectura
# Termina aunque el reloj no avance: como mucho, las lecturas que caben en el tope.
MAX_LECTURAS = TOPE_S // INTERVALO_S + 1
GH_TIMEOUT_S = 30       # tope de cada `gh api`

RC_ESTABLE = 0
RC_USO = 2
RC_GH = 3
RC_NO_PARSEABLE = 4
RC_INESTABLE = 5
RELOJ_VARIABLE = 'LECTURA_ESTABLE_RELOJ'


def _ahora():
    return time.monotonic()


def _dormir(segundos):
    time.sleep(segundos)


def matches(actual, expected):
    """¿`actual` contiene `expected`? Subconjunto recursivo y estricto en tipos.

    `restrictions` nula o ausente cuenta igual. Un booleano esperado frente a un objeto lee su `enabled`
    (así devuelve GitHub los ajustes de protección).
    """
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            (k == 'restrictions' and v is None and k not in actual) or
            (k in actual and matches(actual[k], v)) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(
            matches(x, y) for x, y in zip(actual, expected))
    if isinstance(expected, bool) and isinstance(actual, dict):
        actual = actual.get('enabled')
    return type(actual) is type(expected) and actual == expected


def mensaje_no_estable(endpoint, lecturas, segundos, seguidas, mejor):
    return ('lectura de GitHub sin estabilizar en lo pedido: '+endpoint+'; la racha más larga fue de '+
            str(mejor)+' de '+str(LECTURAS_ESTABLES)+' lecturas seguidas iguales a lo pedido (la última: '+
            str(seguidas)+'), en '+str(lecturas)+' lecturas y '+str(segundos)+' s (tope '+str(TOPE_S)+' s). '
            'GitHub puede tardar en propagar un cambio recién escrito: puede repetir la fase. '
            'Si vuelve a fallar, compare la última respuesta con lo pedido.')


def leer_estable(leer, esperado, endpoint):
    """Lee hasta LECTURAS_ESTABLES lecturas seguidas iguales a `esperado` o hasta el tope."""
    inicio = _ahora()
    lecturas = seguidas = mejor = 0
    while True:
        ultima = leer()
        lecturas += 1
        if matches(ultima, esperado):
            seguidas += 1
        else:
            seguidas = 0
        mejor = max(mejor, seguidas)
        if seguidas >= LECTURAS_ESTABLES:
            return True, ultima, ''
        if lecturas >= MAX_LECTURAS or _ahora() - inicio + INTERVALO_S > TOPE_S:
            return False, ultima, mensaje_no_estable(endpoint, lecturas, int(_ahora() - inicio), seguidas, mejor)
        _dormir(INTERVALO_S)


class _FalloGh(Exception):
    pass


class _NoParseable(Exception):
    pass


def _reloj_simulado():
    estado = {'t': 0.0}

    def ahora():
        return estado['t']

    def dormir(segundos):
        estado['t'] += segundos
    return ahora, dormir


def main(argv):
    global _ahora, _dormir
    # El endpoint va como UN argumento de `gh api` (sin --method: solo GET); no puede ser una opción.
    if len(argv) != 2 or not argv[0] or argv[0].startswith('-'):
        print('uso: lectura_estable.py ENDPOINT ESPERADO_JSON (solo GET de gh api)', file=sys.stderr)
        return RC_USO
    endpoint = argv[0]
    try:
        esperado = json.loads(argv[1])
    except ValueError:
        esperado = None
    if not isinstance(esperado, dict) or not esperado:
        print('lectura estable: lo pedido debe ser un objeto JSON no vacío', file=sys.stderr)
        return RC_USO
    reloj = os.environ.get(RELOJ_VARIABLE, '')
    if reloj not in ('', 'simulado'):
        print('lectura estable: '+RELOJ_VARIABLE+' solo admite «simulado» (pruebas)', file=sys.stderr)
        return RC_USO
    if reloj == 'simulado':
        _ahora, _dormir = _reloj_simulado()
        print('AVISO: lectura estable con reloj simulado (solo pruebas): las lecturas no se espacian',
              file=sys.stderr)
    cruda = ['']

    def leer():
        try:
            p = subprocess.run(['gh', 'api', endpoint], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, timeout=GH_TIMEOUT_S)
        except (OSError, subprocess.TimeoutExpired):
            raise _FalloGh('gh api '+endpoint+': no ejecutable o sin respuesta en '+str(GH_TIMEOUT_S)+' s\n') from None
        if p.returncode:
            raise _FalloGh((p.stdout or '')+(p.stderr or ''))
        cruda[0] = p.stdout
        try:
            return json.loads(p.stdout)
        except ValueError:
            raise _NoParseable() from None

    try:
        estable, _, mensaje = leer_estable(leer, esperado, endpoint)
    except _FalloGh as exc:
        sys.stdout.write(str(exc))
        return RC_GH
    except _NoParseable:
        sys.stdout.write(cruda[0])
        print('lectura estable: respuesta no parseable de GitHub: '+endpoint, file=sys.stderr)
        return RC_NO_PARSEABLE
    sys.stdout.write(cruda[0])
    if not estable:
        print(mensaje, file=sys.stderr)
        return RC_INESTABLE
    return RC_ESTABLE


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
