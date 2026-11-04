"""El lector contrasta permisos y propietarios reales, sin sustituir stat."""
import os
from pathlib import Path
import subprocess
import tempfile
import contextlib
import io
import stat
import sys
from unittest.mock import patch


def main():
    reader = Path(__file__).resolve().parents[1]/'scripts/leer-acreditacion.sh'
    with tempfile.TemporaryDirectory(prefix='propietarios-') as td:
        parent = Path(td)
        parent.chmod(0o755)
        base = parent/'estado'
        directory = base/'acreditacion'
        directory.mkdir(parents=True, mode=0o700)
        base.chmod(0o700)
        file = directory/'CEO.estado'

        def query(path):
            result = subprocess.run(['/bin/bash', str(reader), 'CEO'],
                                    env={'HOME': td, 'PATH': '/usr/bin:/bin', 'TA_BUS_STATE_DIR': str(path)},
                                    capture_output=True, text=True)
            return result.returncode, result.stdout.strip()

        assert query(base) == (0, 'AUSENTE')
        for value in ('NO_ACREDITADO', 'ACREDITADO'):
            file.write_text(value+'\n')
            file.chmod(0o600)
            assert query(base) == (0, value)
        for mode in (0o775, 0o757):
            parent.chmod(mode)
            assert query(base)[0] == 2
        parent.chmod(0o755)
        # .local 775 con grupo privado es válido como antecesor superior al estado.
        local = parent/'.local'
        private_base = local/'state/talent-ceo'
        private_acc = private_base/'acreditacion'
        private_acc.mkdir(parents=True, mode=0o700)
        local.chmod(0o775)
        (local/'state').chmod(0o755)
        private_base.chmod(0o700)
        private_file = private_acc/'CEO.estado'
        private_file.write_text('ACREDITADO\n')
        private_file.chmod(0o600)
        assert local.stat().st_gid == os.getgid()
        assert query(private_base) == (0, 'ACREDITADO')
        print('antecesor .local 775 con grupo propio: PASS')
        linked = parent/'enlace'
        linked.symlink_to(base, target_is_directory=True)
        assert query(linked)[0] == 2
        for path in (base, directory, file):
            original = path.stat().st_mode & 0o777
            for mode in (original | 0o020, original | 0o002):
                path.chmod(mode)
                assert query(base)[0] == 2, (path, oct(mode))
            path.chmod(original)
        superior = parent/'superior'
        superior.symlink_to(parent, target_is_directory=True)
        assert query(superior/'estado')[0] == 2
        # Fuera del home también se rechazan enlaces superiores hasta la raíz.
        result = subprocess.run(['/bin/bash', str(reader), 'CEO'],
                                env={'HOME': str(parent/'otro-home'), 'PATH': '/usr/bin:/bin',
                                     'TA_BUS_STATE_DIR': str(superior/'estado')})
        assert result.returncode == 2
        # El home y lo situado por encima se excluyen de la comprobación de enlaces.
        result = subprocess.run(['/bin/bash', str(reader), 'CEO'],
                                env={'HOME': str(superior), 'PATH': '/usr/bin:/bin',
                                     'TA_BUS_STATE_DIR': str(superior/'estado')}, capture_output=True, text=True)
        assert (result.returncode, result.stdout.strip()) == (0, 'ACREDITADO')
        print('enlaces superiores y modos compartidos: PASS')
        # Carrera sincronizada: sustituir la ruta tras fstat, antes de leer el descriptor.
        file.write_text('NO_ACREDITADO\n')
        substitute = parent/'sustituto'
        substitute.write_text('ACREDITADO\n')
        source = reader.read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        real_fstat = os.fstat
        replaced = []
        def replace_after_stat(fd):
            info = real_fstat(fd)
            if stat.S_ISREG(info.st_mode) and not replaced:
                file.unlink()
                file.symlink_to(substitute)
                replaced.append(True)
            return info
        output = io.StringIO()
        with patch.object(os, 'fstat', replace_after_stat), patch.object(sys, 'argv', ['lector', str(base), 'CEO']), \
                patch.dict(os.environ, {'HOME': td}), contextlib.redirect_stdout(output):
            exec(compile(source, str(reader), 'exec'), {})
        assert replaced and file.is_symlink() and output.getvalue() == 'NO_ACREDITADO\n'
        print('carrera-sustitucion: PASS (ruta sustituida; descriptor original leído)')
        file.unlink()
        file.symlink_to('/dev/null')
        assert query(base)[0] == 2
        # /usr es root y seguro en el runner: demuestra el rc rojo antiguo sin chown.
        root_parent = Path('/usr')
        assert root_parent.stat().st_uid == 0 and not root_parent.stat().st_mode & 0o022
        absent = root_parent/('estado-prueba-'+parent.name)
        assert not absent.exists()
        assert query(absent) == (0, 'AUSENTE')
        if os.getuid() != 0:
            assert query(Path('/'))[0] == 2
            print('base igual al padre root ajeno: PASS')
        else:
            print('base igual al padre root ajeno: NO EJECUTADO (UID 0 es su propietario)')
    print('propietarios reales: PASS (padre root ausente, estados propios y rechazos)')


if __name__ == '__main__':
    main()
