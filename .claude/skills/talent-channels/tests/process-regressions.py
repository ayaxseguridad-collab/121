"""Regresiones de procesos propios; ejecutar exclusivamente dentro del arnés."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

scripts = Path(__file__).resolve().parent.parent / "scripts"
source = (scripts / "lib.sh").read_text()
snippet = source.split("<<'TF_PROC_EOF' || true\n", 1)[1].split("\nTF_PROC_EOF", 1)[0]
mode = sys.argv[1]

def bash(code, env=None):
    return subprocess.run(["bash", "-c", code], env=env, text=True,
                          capture_output=True, timeout=12)

if mode == "heredoc":
    tests = (scripts.parent / "tests/run-tests.sh").read_text()
    fragment = tests.split("run_t25d()", 1)[1].split("run_t25d;", 1)[0]
    assert re.search(r"<<'CODEX'", fragment), "R06: delimitador sin comillas"
    assert "AM_TEST_CODEX_COUNT" in fragment, "R06: falta ruta por entorno"
elif mode == "pipe":
    cli = (scripts / "auth-move.sh").read_text()
    prelude = cli.split("    # TAL-8042 (FAB-OBS-002)", 1)[1].split("    set +e", 1)[0]
    # Ejecuta las sentencias reales del preámbulo; la señal alcanza solo este hijo.
    code = "# TAL-8042 (FAB-OBS-002)" + prelude + '\nkill -PIPE "$$"; echo protegido'
    result = bash(code)
    assert result.returncode == 0 and "protegido" in result.stdout, result
elif mode == "self":
    result = bash(snippet + '''
printf "%s" self8042 > "/proc/$$/comm"
pgrep() { printf "%s\\n" "$$"; }
kill() { echo "SENAL $*"; }
_tf_kill_wait "$(id -u)" self8042 0
echo "rc=$?"
''')
    assert "rc=1" in result.stdout and "SENAL" not in result.stdout, result
else:
    names = {"newline": "codex\nvecino", "leading": " codex",
             "trailing": "codex ", "comm": "codex", "exec": "codex", "reuse": "codex"}
    with tempfile.TemporaryDirectory() as tmp:
        ready = Path(tmp) / "ready"
        change = Path(tmp) / "change"
        fixture = '''import ctypes, os, sys, time
from pathlib import Path
ctypes.CDLL(None).prctl(15, sys.argv[1].encode(), 0, 0, 0)
Path(sys.argv[2]).touch()
while not Path(sys.argv[3]).exists(): time.sleep(.01)
os.execv("/bin/sleep", ["sleep", "60"])
'''
        process = subprocess.Popen([sys.executable, "-c", fixture, names[mode], str(ready), str(change)],
                                   start_new_session=True)
        try:
            for _ in range(200):
                if ready.exists():
                    break
                time.sleep(.01)
            assert ready.exists(), "fixture no arrancó"
            env = dict(os.environ, TEST_PID=str(process.pid), TEST_CHANGE=str(change))
            code = snippet + '\npgrep() { echo "$TEST_PID"; }\n'
            if mode == "exec":
                code += '''
eval "$(declare -f _tf_agent_scan | sed '1s/_tf_agent_scan/_tf_scan_original/')"
_tf_agent_scan() {
  local snapshot
  snapshot="$(_tf_scan_original "$@")" || return
  if [ ! -e "$TEST_CHANGE" ]; then
    touch "$TEST_CHANGE"
    for ((i=0;i<200;i++)); do
      [ "$(readlink "/proc/$TEST_PID/exe")" = /usr/bin/sleep ] && break
      sleep .01
    done
  fi
  printf "%s\\n" "$snapshot"
}
'''
            if mode == "reuse":
                # Identidad listada de otra encarnación del mismo PID: cambia solo starttime.
                code += '''
if declare -F _tf_identity >/dev/null; then
  eval "$(declare -f _tf_agent_scan | sed '1s/_tf_agent_scan/_tf_scan_original/')"
  _tf_agent_scan() {
    local snapshot p identity
    snapshot="$(_tf_scan_original "$@")" || return
    while IFS=$'\\t' read -r p identity; do
      [ -n "$p" ] || continue
      printf "%s\\t%s%s\\n" "$p" "0" "$identity"
    done <<< "$snapshot"
  }
fi
'''
            code += '_tf_kill_wait "$(id -u)" codex 0; echo "rc=$?"\n'
            result = bash(code, env)
            time.sleep(.05)
            alive = process.poll() is None
            if mode == "comm":
                assert not alive and "rc=0" in result.stdout, result
            else:
                assert alive, f"{mode}: señaló un proceso ajeno: {result}"
                if mode in ("exec", "reuse"):
                    assert "rc=3" in result.stdout, result
                else:
                    assert "rc=0" in result.stdout, result
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
print(f"OK {mode}")
