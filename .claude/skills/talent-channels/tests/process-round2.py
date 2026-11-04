"""Desaparición e incertidumbre en las tres copias; solo dentro del arnés."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

skills = Path(__file__).resolve().parents[2]
mode = sys.argv[1]
failures = 0
for relative in ("talent-channels/scripts/lib.sh", "talent-channels/scripts/auth-move-lib.sh",
                 "talent-channel-operation/scripts/lib.sh"):
    snippet = (skills / relative).read_text().split("<<'TF_PROC_EOF' || true\n", 1)[1].split("\nTF_PROC_EOF", 1)[0]
    with tempfile.TemporaryDirectory() as tmp:
        ready, change = Path(tmp) / "ready", Path(tmp) / "change"
        fixture = '''import ctypes, sys, time
from pathlib import Path
ctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)
Path(sys.argv[1]).touch()
while not Path(sys.argv[2]).exists(): time.sleep(.005)
if sys.argv[3] not in ("gone", "scan_gone", "zombie", "scan_zombie"): time.sleep(60)
'''
        process = subprocess.Popen([sys.executable, "-c", fixture, str(ready), str(change), mode],
                                   start_new_session=True)
        try:
            for _ in range(200):
                if ready.exists():
                    break
                time.sleep(.01)
            assert ready.exists(), "fixture no arrancó"
            if mode in ("gone", "scan_gone"):
                threading.Thread(target=process.wait, daemon=True).start()
            env = dict(os.environ, TEST_PID=str(process.pid), TEST_CHANGE=str(change), TEST_MODE=mode)
            code = snippet + '''
pgrep() { echo "$TEST_PID"; }
kill() { echo "SENAL $*"; command kill "$@"; }
finish_process() {
  touch "$TEST_CHANGE"
  for ((i=0;i<200;i++)); do
    if [[ "$TEST_MODE" = *zombie ]]; then
      line="$(cat "/proc/$TEST_PID/stat")"
      rest="${line##*) }"
      [ "${rest%% *}" = Z ] && return 0
    else
      [ ! -d "/proc/$TEST_PID" ] && return 0
    fi
    sleep .01
  done
  return 1
}
'''
            if mode in ("scan_gone", "scan_zombie"):
                # Salida normal justo antes de la segunda lectura de identidad del escáner.
                code += '''
read() {
  local rc=0
  builtin read "$@" || rc=$?
  if [ "${!#}" = c ] && [ ! -e "$TEST_CHANGE" ]; then
    finish_process || return 2
  fi
  return "$rc"
}
'''
            else:
                code += '''
eval "$(declare -f _tf_agent_scan | sed '1s/_tf_agent_scan/_tf_original_scan/')"
_tf_agent_scan() {
  local snapshot
  snapshot="$(_tf_original_scan "$@")" || return
  if [ ! -e "$TEST_CHANGE" ]; then
'''
                code += '    finish_process || return 2\n' if mode in ("gone", "zombie") else '    touch "$TEST_CHANGE"\n'
                code += '  fi\n  printf "%s\\n" "$snapshot"\n}\n'
            if mode == "unreadable":
                code += '''
eval "$(declare -f _tf_identity | sed '1s/_tf_identity/_tf_original_identity/')"
_tf_identity() { [ ! -e "$TEST_CHANGE" ] || return 2; _tf_original_identity "$@"; }
'''
            if mode == "reuse_stat":
                code += '''
cat() {
  if [ "$1" = "/proc/$TEST_PID/stat" ] && [ -e "$TEST_CHANGE" ]; then
    command cat "$@" | awk '{$22=$22+100; print}'
  else command cat "$@"; fi
}
'''
            code += '_tf_kill_wait "$(id -u)" codex 0; echo rc=$?\n'
            result = subprocess.run(["bash", "-c", code], env=env, text=True,
                                    capture_output=True, timeout=12)
            expected = 0 if mode in ("gone", "scan_gone", "zombie", "scan_zombie") else 3
            if mode in ("zombie", "scan_zombie"):
                # Comprobar el difunto real antes de poll/wait, que lo recogerían.
                state = Path(f"/proc/{process.pid}/stat").read_text().rsplit(") ", 1)[1].split()[0]
                assert state == "Z", (relative, mode, state)
                print(f"ESTADO={state} PROC=presente {relative} {mode}")
            assert f"rc={expected}" in result.stdout and "SENAL" not in result.stdout, (relative, result.stdout, result.stderr)
            assert (process.poll() is None) == (expected == 3), (relative, mode, result.stdout, result.stderr)
            print(f"OK {relative} {mode} rc={expected} sin señal")
        except AssertionError as error:
            failures += 1
            print(f"FAIL {relative} {mode}: {error}")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
sys.exit(1 if failures else 0)
