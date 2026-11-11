"""Identidad con lanzadores alias; transporte local y procesos propios dentro del arnés."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

scripts = Path(__file__).resolve().parent.parent / "scripts"
mode, entry = sys.argv[1:3]
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    remote = root / "remote"
    remote.mkdir()
    cwd = root / "cwd"
    cwd.mkdir()
    collision = mode.startswith(("builtin_", "function_"))
    name = "claude" if mode == "alias_claude" else "codex"
    if collision:
        name = "printf" if mode.startswith("builtin_") else "x"
    executable = remote / name
    shutil.copyfile(shutil.which("python3"), executable)
    executable.chmod(0o755)
    # PATH cerrado: ningún lanzador o agente instalado en el runner puede suplir el fixture.
    for utility in ("bash", "cat", "readlink", "pgrep", "mktemp", "mv", "grep", "sleep", "rm", "timeout", "stat"):
        (remote / utility).symlink_to(shutil.which(utility))
    # El pane del fixture no lo acreditó ninguna sonda de lanzamiento: el transporte da el pid y el id estable con la forma
    # real `%N`, sin la vida del servidor, así que no hay fichero de acreditación que buscar y la identidad de solo lectura
    # resuelve en su propia shell. El doble
    # rechaza cualquier orden de tmux, incluida una ventana nueva o un servidor propio (`tmux -L`): la lectura no abre
    # ventanas ni toca panes, ni lee opciones de tmux.
    (remote / "tmux").write_text('#!/bin/bash\n'
                                 'case "${1:-}" in\n'
                                 '  *) exit 1 ;;\n'
                                 'esac\nexit 0\n')
    (remote / "tmux").chmod(0o755)
    cli = name + "-root"
    setup = ""
    if collision:
        executable.rename(cwd / name)
        executable = cwd / name
        if mode.endswith("_declared"):
            cli = name
        if mode.startswith("function_"):
            setup = "x() { :; }; export -f x; "
    if mode == "absolute":
        cli = str(executable)
    elif mode == "launcher_file":
        launcher = remote / cli
        executable.rename(launcher)
        executable = launcher
        # Si se invierte la prioridad, este homónimo derivado no acredita el proceso.
        shutil.copyfile(shutil.which("sleep"), remote / name)
        (remote / name).chmod(0o755)
    elif mode == "missing_both":
        cli = "absent-root"
    assert mode in ("alias_claude", "alias_codex", "absolute", "launcher_file", "missing_both",
                    "builtin_derived", "function_derived", "builtin_declared", "function_declared")
    if collision:
        assert not (remote / name).exists() and executable.parent == cwd
    if mode.startswith("alias_"):
        assert not (remote / cli).exists() and (remote / name).is_file()
    if mode == "missing_both":
        assert not (remote / cli).exists() and not (remote / "absent").exists()
    process = subprocess.Popen([str(executable), "-c", "import time; time.sleep(60)"],
                               start_new_session=True)
    try:
        shim = root / "shim"
        shim.mkdir()
        transport = shim / "incus"
        transport.write_text('''#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
[ "$#" -gt 1 ] || exit 2
shift
case "$1" in
  # tmux real: el pid y, si el formato lo pide, el id estable con su forma `%N` (el del índice del destino).
  *display-message*'#{pane_id}'*)
    i=0; case "$1" in *".1' "*) i=1 ;; esac
    printf '%s %%%s\\n' "$TEST_PID" "$i" ;;
  *display-message*) printf '%s\\n' "$TEST_PID" ;;
  *) cd "$TEST_CWD" || exit 2; SETUP_PLACEHOLDER PATH="$TEST_REMOTE_PATH" exec /bin/bash -c "$1" ;;
esac
'''.replace("SETUP_PLACEHOLDER", setup))
        transport.chmod(0o755)
        env = dict(os.environ, PATH=str(shim) + ":/usr/bin:/bin",
                   TEST_REMOTE_PATH=str(remote), TEST_PID=str(process.pid), TEST_CWD=str(cwd))
        if entry == "reader":
            command = ["/bin/bash", str(scripts.parent.parent / "talent-ceo/scripts/leer-auditor.sh"),
                       "fixture", "v:0.1", "fixture", cli]
        else:
            assert entry == "operation"
            code = f'. {shlex.quote(str(scripts / "lib.sh"))}\n'
            code += 'tco_container() { echo fixture; }; TCO_CUSER=fixture\n'
            code += '_tco_pane_agent_exes 01 v:0.1 "$1"\n'
            command = ["/bin/bash", "-c", code, "fixture", cli]
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
        rejected = mode == "missing_both" or collision
        expected_rc = 2 if rejected else 0
        expected_name = "" if rejected else name + "\n"
        assert result.returncode == expected_rc, f"{entry}/{mode}: esperado rc={expected_rc}: {result}"
        # Tras el nombre acreditado, la identidad añade `real=<ruta real esperada>` e `ino=<dispositivo:inodo>` (R-04 y H-02:
        # topología sobre ejecutables reales).
        names = "".join(line + "\n" for line in result.stdout.splitlines() if not line.startswith(("real=", "ino=")))
        assert names == expected_name, f"{entry}/{mode}: identidad inesperada: {result}"
        assert process.poll() is None, "el lector alteró el proceso del fixture"
        print(f"OK {entry}/{mode} rc={result.returncode} identidad={result.stdout.strip() or 'vacia'}")
        if entry == "operation":
            code = f'. {shlex.quote(str(scripts / "lib.sh"))}\n'
            code += 'tco_container() { echo fixture; }; TCO_CUSER=fixture\n'
            code += 'tco_pane_dev() { echo v:0.0; }; tco_pane_audit() { echo v:0.1; }\n'
            code += 'TCO_DEV_CLI="$1"; TCO_AUDIT_CLI="$1"; TCO_AUDIT_TOPOLOGY=mismo-adversarial\n'
            code += 'TCO_PANE_IDENT_WAIT=0; tco_pane_identity_preflight 01\n'
            result = subprocess.run(["/bin/bash", "-c", code, "fixture", cli],
                                    env=env, text=True, capture_output=True, timeout=10)
            # Ley del lead (7-nov): la topología `mismo-adversarial` ya no existe, así que el mismo ejecutable como dev y
            # como auditor PARA siempre (rc 1, nada acreditado), sea cual sea la identidad del proceso del pane.
            assert result.returncode == 1, f"preflight/{mode}: {result}"
            assert result.stdout == "", f"preflight/{mode}: acreditación inesperada: {result}"
            assert process.poll() is None, "el preflight alteró el proceso del fixture"
            print(f"OK preflight/{mode} rc={result.returncode}")
    finally:
        process.kill()
        process.wait()
