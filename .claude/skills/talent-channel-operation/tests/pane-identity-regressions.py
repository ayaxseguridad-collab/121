"""Preflight real con transporte local y procesos propios, siempre dentro del arnés."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

scripts = Path(__file__).resolve().parent.parent / "scripts"
mode = sys.argv[1]


def tmux_shim(root):
    """PATH con un doble de tmux para la sonda de resolución (ventana temporal de la MISMA sesión, `tmux new-window`):
    ejecuta el comando de la sonda con la shell por defecto y el PATH del cliente, como tmux real, y da el id del pane
    temporal. Así el caso no depende del tmux de la máquina. Una sonda con servidor propio (`tmux -L`) se rechaza."""
    shim = Path(root) / "shim-tmux"
    shim.mkdir()
    (shim / "tmux").write_text('#!/bin/bash\n'
                               'case "${1:-}" in\n'
                               '  new-window) /bin/bash -c "${*: -1}" >/dev/null 2>&1; printf "%%92\\n" ;;\n'
                               '  kill-pane) : ;;\n'
                               '  list-panes) printf "%%0|bash\\n" ;;\n'
                               '  *) exit 1 ;;\n'
                               'esac\nexit 0\n')
    (shim / "tmux").chmod(0o755)
    return f"{shim}:{os.environ['PATH']}"
if mode in ('capture_node', 'capture_node_foreign'):
    # Árbol /proc doblado para Node; enumerador y resolutor reales, sin Node instalado.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        agent, node = root/'claude', root/'node'
        for path in (agent, node):
            path.write_text('fixture\n')
            path.chmod(0o755)
        for pid, exe in ((100, '/bin/bash'), (101, node)):
            directory = root/'proc'/str(pid)
            directory.mkdir(parents=True)
            (directory/'stat').write_text(str(pid)+' (fixture) S 0 0\n')
            (directory/'exe').symlink_to(exe)
        script = agent if mode == 'capture_node' else root/'ajeno'
        if not script.exists():
            script.write_text('fixture ajeno\n')
        (root/'proc/101/cmdline').write_bytes(b'node\0'+str(script).encode()+b'\0')
        code = r'''
. "$SC/00-config.sh"; . "$SC/lib.sh"
TCO_DEV_CLI="$NODE_AGENT"; TCO_TMUX=v
TCO_PANE_CLI_VERSION_CMD='printf "2.1.288 (Claude Code)\n"'
tco_container() { echo fixture; }
incus() {
  local code="${*: -1}"
  # tmux real: el pid y, si el formato lo pide, el id estable con su forma `%N` (sin la vida del servidor: sin acreditación).
  case "$code" in *display-message*'#{pane_id}'*) echo '100 %0'; return;; *display-message*) echo 100; return;; esac
  if [[ "$code" == *PANE_IDENTITY* ]]; then return 2; fi
  code="${code//\/proc\//$NODE_ROOT\/proc\/}"
  bash -c "$code"
}
command() {
  if [ "$1" = -v ] && [[ "$2" = node || "$2" = nodejs ]]; then echo "$NODE_ROOT/node"
  else builtin command "$@"; fi
}
pgrep() { [ "$2" != 100 ] || echo 101; }
export -f command pgrep
_tco_pane_cli_version 01 v:.0
'''
        env = dict(os.environ, PATH=tmux_shim(root), SC=str(scripts), NODE_ROOT=str(root), NODE_AGENT=str(agent),
                   TCO_REPO_DIR='producto', TCO_REPO_SLUG='org-example/producto', TCO_REPO_STACK='ninguno',
                   TCO_ANEXO_FILE='references/anexo-ejemplo.md', TCO_HOST_ENV_REL='ejemplo/entorno.conf',
                   TCO_LINEAR_INPROGRESS_STATE='11111111-2222-3333-4444-555555555555',
                   TCO_LINEAR_INREVIEW_STATE='66666666-7777-8888-9999-aaaaaaaaaaaa')
        result = subprocess.run(['bash', '-c', code], env=env, text=True, capture_output=True, timeout=10)
        expected = 0 if mode == 'capture_node' else 1
        assert result.returncode == expected, result
        if not expected:
            assert result.stdout.strip() == 'claude:2.1.288', result
        print('OK '+mode+' rc='+str(result.returncode))
    sys.exit(0)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    declared = root / "declared/codex"
    declared.parent.mkdir()
    shutil.copyfile(shutil.which("python3"), declared)
    declared.chmod(0o755)
    actual = declared
    args = ["codex", "-c", "import time; time.sleep(60)"]
    if mode in ("spoof", "shell"):
        actual = Path("/bin/sleep" if mode == "spoof" else "/bin/bash")
        args = ["codex", "60"] if mode == "spoof" else ["bash", "-c", "while :; do sleep 60; done"]
    elif mode == "homonym":
        actual = root / "other/codex"
        actual.parent.mkdir()
        shutil.copyfile(declared, actual)
        actual.chmod(0o755)
    elif mode in ("wrapper", "interpreter", "wrong_script", "capture_interpreter", "capture_wrong_script"):
        binary = declared.read_bytes()
        declared.write_text("import time\ntime.sleep(60)\n")
        actual = Path(shutil.which("python3"))
        script = declared
        if mode in ("wrong_script", "capture_wrong_script"):
            script = root / "other/codex"
            script.parent.mkdir()
            shutil.copyfile(declared, script)
        if mode == "wrapper":
            declared.write_bytes(binary)
            script = root / "wrapper/codex"
            script.parent.mkdir()
            script.write_text('import ctypes, time\nctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)\ntime.sleep(60)\n')
        args = [str(actual), str(script)]
    dev = subprocess.Popen(["sleep", "60"], executable="/bin/sleep", start_new_session=True)
    audit = subprocess.Popen(args, executable=actual, start_new_session=True)
    try:
        time.sleep(.1)
        assert dev.poll() is None and audit.poll() is None, "fixture no arrancó"
        cli = str(declared)
        if mode == "empty_cli":
            cli = ""
        if mode == "invalid_cli":
            cli = str(root / "missing")
        env = dict(os.environ, PATH=tmux_shim(root), TEST_DEV=str(dev.pid), TEST_AUD=str(audit.pid), TEST_DECL_CLI=cli,
                   TCO_DEV_CLI="/bin/sleep", TCO_AUDIT_CLI=cli,
                   TCO_AUDIT_TOPOLOGY="distinto", TCO_PANE_IDENT_WAIT="0")
        if not (scripts / "repo-identity.conf").exists():
            neutral = dict(TCO_REPO_DIR="Repo-Neutro", TCO_REPO_SLUG="org-neutra/Repo-Neutro",
                           TCO_REPO_STACK="ninguno", TCO_ANEXO_FILE="references/anexo-neutro.md",
                           TCO_LINEAR_INPROGRESS_STATE="00000000-0000-4000-8000-000000000007",
                           TCO_LINEAR_INREVIEW_STATE="00000000-0000-4000-8000-000000000008",
                           TCO_HOST_ENV_REL="Repo-Neutro/.env.local")
            for key, value in neutral.items():
                env.setdefault(key, value)
        transport = '''
tco_container() { echo fixture; }
incus() {
  while [ "$1" != -c ]; do shift; done
  shift
  local code="$1"; shift
  if [[ "$code" == *display-message* ]]; then
    # tmux real: el pid y, si el formato lo pide, el id estable con su forma `%N` (sin la vida del servidor: ninguna
    # acreditación que buscar). Un pane sin pid (empty_pane) no da nada.
    local p=$TEST_AUD i=%1
    if [[ "$code" == *'.0'* ]]; then p=$TEST_DEV i=%0; fi
    if [ -z "$p" ]; then echo
    elif [[ "$code" == *'#{pane_id}'* ]]; then echo "$p $i"
    else echo "$p"
    fi
  else
    bash -c "$code" "$@"
  fi
}
'''
        if mode == "empty_pane":
            env["TEST_AUD"] = ""
        code = f'. {shlex.quote(str(scripts / "00-config.sh"))}; . {shlex.quote(str(scripts / "lib.sh"))}\n' + transport
        code += 'TCO_DEV_CLI=/bin/sleep; TCO_AUDIT_CLI="$TEST_DECL_CLI"; TCO_PANE_IDENT_WAIT=0; TCO_AUDIT_TOPOLOGY=distinto\n'
        if mode in ("vanished_stat", "vanished_exe", "unreadable_stat", "unreadable_exe"):
            # Dobles heredados por el shell remoto; ningún PID ajeno se modifica.
            code += '''
pgrep() {
  if [ "$2" = "$TEST_DEV" ]; then echo 999999999; return 0; fi
  return 1
}
cat() {
  if [ "$TEST_RACE" = unreadable_stat ] && [ "$1" = "/proc/$TEST_DEV/stat" ]; then return 1; fi
  if [ "$TEST_RACE" = vanished_exe ] && [ "$1" = /proc/999999999/stat ]; then echo '999999999 (fixture) S 1'; return 0; fi
  command cat "$@"
}
readlink() {
  if [ "$TEST_RACE" = unreadable_exe ] && [ "$2" = "/proc/$TEST_DEV/exe" ]; then return 1; fi
  command readlink "$@"
}
export -f pgrep cat readlink
'''
            env["TEST_RACE"] = mode
        if mode in ("retry_dev", "retry_audit", "never_dev", "never_audit", "wrong_after_retry"):
            env["TEST_COUNTER"] = str(root / "counter")
            env["TEST_RACE"] = mode
            code += '''
TCO_PANE_IDENT_WAIT=4
sleep() { :; }
_tco_pane_agent_exes() {
  local n=0
  if [[ "$TEST_RACE" == *audit ]]; then
    [[ "$2" == *.0 ]] && { echo sleep; echo real=/fx/sleep; return 0; }
  else
    [[ "$2" == *.1 ]] && { echo codex; echo real=/fx/codex; return 0; }
  fi
  [ ! -f "$TEST_COUNTER" ] || read -r n < "$TEST_COUNTER"
  n=$((n + 1)); echo "$n" > "$TEST_COUNTER"
  # Incluso la salida correcta de una enumeración parcial debe rechazarse.
  if [ "$TEST_RACE" != wrong_after_retry ]; then
    if [[ "$2" == *.0 ]]; then echo sleep; echo real=/fx/sleep; else echo codex; echo real=/fx/codex; fi
  fi
  [[ "$TEST_RACE" == never_* ]] && return 2
  [ "$n" -le 2 ] && return 2
  if [ "$TEST_RACE" = wrong_after_retry ]; then echo other; return 0; fi
  return 0
}
'''
        if mode == "partial":
            code += '_tco_pane_agent_exes() { case "$2" in *.0) echo sleep; return 2;; *) echo codex; return 0;; esac; }\n'
        if mode == "audit_partial":
            code += '_tco_pane_agent_exes() { case "$2" in *.0) echo sleep; return 0;; *) echo codex; return 2;; esac; }\n'
        if mode.startswith('capture_'):
            code += "TCO_PANE_CLI_VERSION_CMD='printf \"codex-cli 0.1.0\\n\"'; echo READY_PREFLIGHT; _tco_pane_cli_version 01 v:.1\n"
        else:
            code += "echo READY_PREFLIGHT; tco_pane_identity_preflight 01\n"
        result = subprocess.run(["bash", "-c", code], env=env, text=True,
                                capture_output=True, timeout=10)
        expected = 0 if mode in ("legitimate", "interpreter", "vanished_stat", "vanished_exe", "retry_dev", "retry_audit", "capture_interpreter") else 1
        assert "READY_PREFLIGHT" in result.stdout, f"{mode}: no llegó al preflight: {result.stderr}"
        assert result.returncode == expected, f"{mode}: esperado rc={expected}: {result}"
        if mode in ("retry_dev", "retry_audit", "never_dev", "never_audit", "wrong_after_retry"):
            assert (root / "counter").read_text().strip() == "3", result
        if mode in ("never_dev", "never_audit"):
            assert "incompleta o ilegible" in result.stderr and "3 intentos" in result.stderr, result
        if mode == "wrong_after_retry":
            assert "NO ejecuta" in result.stderr, result
        if mode == 'capture_interpreter':
            assert 'codex:0.1.0' in result.stdout and 'python3:' not in result.stdout
        print(f"OK {mode} rc={result.returncode}")
        if mode in ("never_dev", "never_audit", "wrong_after_retry"):
            print(result.stderr.strip())
    finally:
        for process in (dev, audit):
            process.kill()
            process.wait()
