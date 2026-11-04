#!/usr/bin/env bash
# Consulta restringida de solo lectura, como el usuario del actor. No acepta rutas.
# Uso: leer-acreditacion.sh ROL | --help (rc 0 datos, rc 2 no comprobable).
set -uo pipefail
if [ "${1-}" = --help ]; then sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0; fi
[ $# -eq 1 ] && [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] || exit 2
command -v python3 >/dev/null || exit 2
base="${TA_BUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/talent-ceo}"
# Descriptores anclados: no comprobar una ruta y abrir después otra por sustitución.
python3 - "$base" "$1" <<'PY'
import os
from pathlib import Path
import stat
import sys


def seguro(info, propio=True):
    # 0022: ningún objeto de estado admite escritura de grupo u otros.
    owners = (os.geteuid(),) if propio else (os.geteuid(), 0)
    if info.st_uid not in owners or info.st_mode & 0o022:
        raise ValueError('propietario o modo inseguro')


def consulta():
    base = Path(sys.argv[1])
    home = Path(os.environ['HOME'])
    if not base.is_absolute() or not home.is_absolute() or '..' in base.parts:
        raise ValueError('ruta no absoluta o ambigua')
    target = base/'acreditacion'/(sys.argv[2]+'.estado')
    # Por encima del home se permite la topología del sistema, incluso enlaces.
    anchor = home if base.is_relative_to(home) else Path('/')
    parts = target.relative_to(anchor).parts
    fd = os.open(anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, part in enumerate(parts):
            current = anchor.joinpath(*parts[:index])
            info = os.fstat(fd)
            if current == base.parent:
                seguro(info, propio=False)
            if current in (base, base/'acreditacion'):
                seguro(info)
            leaf = index == len(parts)-1
            try:
                if leaf:
                    # Comprobar la hoja sin seguir enlaces antes de abrirla.
                    candidate = os.stat(part, dir_fd=fd, follow_symlinks=False)
                    if not stat.S_ISREG(candidate.st_mode) or not candidate.st_mode & 0o400:
                        raise ValueError('fichero no regular o ilegible')
                    seguro(candidate)
                child = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC |
                                (os.O_NONBLOCK if leaf else os.O_DIRECTORY), dir_fd=fd)
            except FileNotFoundError:
                print('AUSENTE')
                return
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o400:
            raise ValueError('fichero no regular o ilegible')
        seguro(info)
        # Se lee el mismo descriptor comprobado; una sustitución no cambia el objeto.
        content = os.read(fd, 16)
        for value in (b'ACREDITADO', b'NO_ACREDITADO'):
            if content in (value, value+b'\n'):
                print(value.decode('ascii'))
                return
        print('INVALIDO')
    finally:
        os.close(fd)


try:
    consulta()
except (OSError, ValueError, KeyError):
    sys.exit(2)
PY
rc=$?
[ "$rc" -eq 0 ] && exit 0
exit 2
