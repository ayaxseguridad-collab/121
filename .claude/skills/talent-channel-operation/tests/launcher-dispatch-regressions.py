"""Lanzadores ejecutables del canal: el despacho no depende de alias del .bashrc.

Doble local de `incus` (ejecuta el comando remoto con `bash -c`, sin `.bashrc`, con un PATH cerrado) y de `tmux`
(modela `respawn-pane`: ejecuta su comando con `bash -c` y, si el comando muere con rc >= 126, el pane muere: desaparece
y el vecino pasa a ser el índice 0, salvo que `remain-on-exit` esté activo, y entonces queda muerto con su rc). El doble de
tmux modela también el hecho medido de tmux real: un pane arranca con el PATH del CLIENTE que lo pide, no con el del
entorno global del servidor (`show-environment -g`). La sonda de resolución es un `respawn-pane` en el MISMO pane de
destino y con el mismo `-c` que el lanzamiento (el doble la reconoce por su marcador y deja el pane muerto con
remain-on-exit), así que la shell del pane (`FAKE_SHELL_PATH`, la `default-shell` del doble) se aplica igual a la sonda y
al lanzamiento. Los casos `sonda_*`, `j5_*` con tmux y `vida_remain_local` usan tmux REAL en un servidor privado de la
prueba (`-L` propio y TMUX_TMPDIR temporal), cerrado al acabar. Los bloques de lanzamiento son los REALES de dispatch.sh,
audit-carril.sh y lib.sh, extraídos por ancla de contenido. Los casos `fase_*` prueban que la fase del modelo se guarda y
se lee con la clave LÓGICA del pane aunque el destino sea el `%N` (`fase_tmux_real`, con tmux REAL) y que todo doble de tmux
de las pruebas da el `pane_id` con la forma real `%N` (`fase_dobles_pane_id`). Solo se ejecuta dentro del arnés.

Aislamiento: ningún caso resuelve ni ejecuta un agente REAL del sistema. Los casos que dependían del `/usr/bin:/bin` del sistema
(`dispatch_shell_del_servidor`, `sonda_shell_del_servidor`, `j5_a_shell_cambiada` y `j5_b_cwd_*`) usan un PATH propio del mundo de
prueba SIN agentes (el espejo de `aislamiento_agentes.py`, que lleva sus propias listas); cada mundo tiene un entorno en lista
blanca, un HOME vacío y el tmux real va en un socket propio.

El aislamiento de estas regresiones (sin agentes reales ni credenciales del usuario) solo vale si el proceso se lanza con el
entorno limpio desde fuera: el arnés del paquete (`tests/run-tests.sh`, la batería de F0 por `clean_environment()` de
`fases.py`) o el envoltorio de mutantes. La invocación directa sin entorno limpio queda NO SOPORTADA / NO AISLADA."""
import ast
import hashlib
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
SKILLS = HERE.parent.parent
OP = SKILLS / "talent-channel-operation" / "scripts"
GOLDEN = SKILLS / "talent-channels" / "scripts" / "02-golden.sh"
UTILS = ("bash", "sleep", "rm", "cat", "readlink", "pgrep", "true", "mktemp", "mv", "grep", "env", "timeout", "stat",
         "mkdir", "chmod", "ln", "find", "tr", "cut", "python3")
# Firma de la orden de la sonda dentro de un pane (su marcador vive en el directorio de estado del despacho).
SONDA_FIRMA = "talent-channel-operation/sonda/"

# Los helpers de la guarda viven en un fichero hermano; sin bytecode para no dejar __pycache__ en el paquete.
sys.dont_write_bytecode = True
import aislamiento_agentes  # noqa: E402

AGENTES = ("codex", "codex-root", "claude", "claude-root")
SISTEMA = ("/usr/bin", "/bin")
# Identidad neutra que exige 00-config.sh. Va al diccionario del mundo: la prueba no escribe nunca en os.environ.
IDENTIDAD = {"TF_LINEAR_TEAM_KEY": "ABC", "TCO_REPO_DIR": "Repo-Neutro", "TCO_REPO_SLUG": "org-neutra/Repo-Neutro",
             "TCO_REPO_STACK": "ninguno", "TCO_ANEXO_FILE": "references/anexo-neutro.md",
             "TCO_HOST_ENV_REL": "Repo-Neutro/.env.local",
             "TCO_LINEAR_INPROGRESS_STATE": "00000000-0000-4000-8000-000000000007",
             "TCO_LINEAR_INREVIEW_STATE": "00000000-0000-4000-8000-000000000008"}
HOST_USER = pwd.getpwuid(os.getuid()).pw_name
# --- INICIO bloque de la guarda de testigos: lectura permitida del entorno del proceso, SOLO de este nombre ---
TESTIGO_DIR = os.environ.get("TCO_TESTIGO_DIR")
# --- FIN bloque de la guarda de testigos ---

FAKE_TMUX = """#!/bin/bash
S="$FAKE_STATE"; LOG="$S/tmux.log"
printf '%s\\n' "$*" >> "$LOG"
if [ "${1:-}" = -L ]; then
  # Una sonda con servidor PROPIO no ve la shell ni el entorno del servidor real (R9011j3 H-01): el doble la rechaza.
  echo "doble: tmux -L (servidor propio) no permitido" >&2
  exit 1
fi
sub="${1:-}"; shift
target_of() { local t=""; while [ "$#" -gt 0 ]; do case "$1" in -t) t="$2"; shift 2 ;; *) shift ;; esac; done; printf '%s' "$t"; }
case "$sub" in
  kill-session) rm -f "$S/panes" "$S"/dead.* "$S"/opt.*; exit 0 ;;
  has-session) [ -e "$S/panes" ]; exit $? ;;
  new-session) printf '1\\n' > "$S/panes"; exit 0 ;;
  split-window) printf '2\\n' > "$S/panes"; exit 0 ;;
  set-option)
    # Opción de usuario del PANE (`-p … @tco-…`): se guarda por índice de pane, aparte de remain-on-exit.
    case " $* " in *" @tco-"*) t="$(target_of "$@")"; printf '%s\\n' "${*: -1}" > "$S/opt.${t##*.}"; exit 0 ;; esac
    case " $* " in *" -wu "*) rm -f "$S/remain" ;; *) printf '%s\\n' "${*: -1}" > "$S/remain" ;; esac; exit 0 ;;
  show-options)
    case " $* " in *" @tco-"*) t="$(target_of "$@")"; [ -e "$S/opt.${t##*.}" ] || exit 1; cat "$S/opt.${t##*.}"; exit 0 ;; esac
    [ ! -e "$S/remain" ] || cat "$S/remain"; exit 0 ;;
  show-environment) [ -n "${FAKE_GLOBAL_PATH:-}" ] || exit 1; printf 'PATH=%s\\n' "$FAKE_GLOBAL_PATH"; exit 0 ;;
  display-message)
    # Como tmux 3.4: un destino que no existe da los campos vacíos con rc 0. El id de un pane es `%<índice>`.
    t="$(target_of "$@")"; fmt="${*: -1}"; n=0; [ ! -e "$S/panes" ] || read -r n < "$S/panes" || n=0
    i="${t##*[.%]}"; id=""
    if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "$n" ]; then id="%$i"; fi
    l="${fmt//'#{pane_id}'/$id}"; l="${l//'#{pane_pid}'/}"
    # Vida del servidor (pid y hora de arranque): fija en el doble, un solo servidor.
    l="${l//'#{pid}'/4242}"; l="${l//'#{start_time}'/1700000000}"
    printf '%s\\n' "$l"; exit 0 ;;
  new-window)
    # Ventana temporal de la sonda en la MISMA sesión: la shell del servidor (FAKE_SHELL_PATH) es la misma que la de
    # respawn-pane. Sin sesión, falla como tmux real.
    [ -e "$S/panes" ] || { echo "can't find session" >&2; exit 1; }
    PATH="${FAKE_SHELL_PATH:-$PATH}" /bin/bash -c "${*: -1}" >/dev/null 2>&1
    printf '%%90\\n'; exit 0 ;;
  kill-pane) exit 0 ;;
  list-panes)
    # Responde con el formato que se pida (-F), como tmux real. Una sola ventana (`@0`) en la sesión del destino.
    fmt='#{pane_index} #{pane_dead} #{pane_dead_status}'; tg=""
    while [ "$#" -gt 0 ]; do case "$1" in -F) fmt="$2"; shift 2 ;; -t) tg="$2"; shift 2 ;; *) shift ;; esac; done
    sn="${tg%%:*}"; case "$sn" in ''|%*) sn=v ;; esac
    read -r n < "$S/panes" || n=0
    for ((i = 0; i < n; i++)); do
      d=0; st=""
      if [ -e "$S/dead.$i" ]; then d=1; st="$(cat "$S/dead.$i")"; fi
      l="${fmt//'#{pane_index}'/$i}"; l="${l//'#{pane_dead_status}'/$st}"; l="${l//'#{pane_dead_signal}'/}"
      l="${l//'#{pane_dead}'/$d}"; l="${l//'#{pane_id}'/%$i}"; l="${l//'#{window_name}'/bash}"
      l="${l//'#{session_name}'/$sn}"; l="${l//'#{window_id}'/@0}"
      l="${l//'#{pid}'/4242}"; l="${l//'#{start_time}'/1700000000}"
      printf '%s\\n' "$l"
    done
    exit 0 ;;
  respawn-pane)
    target=""; cmd=""; dir=""
    while [ "$#" -gt 0 ]; do
      case "$1" in -k) shift ;; -t) target="$2"; shift 2 ;; -c) dir="$2"; shift 2 ;; *) cmd="$1"; shift ;; esac
    done
    # El destino es `sesión:.N` o el id estable `%N` (el doble numera los panes por su índice: `%N` = índice N).
    idx="${target##*[.%]}"
    read -r n < "$S/panes" || n=0
    if [ "$idx" -ge "$n" ]; then echo "can't find pane: $idx" >&2; exit 1; fi
    if [[ "$cmd" == *talent-channel-operation/sonda/* ]]; then
      # La sonda corre en el pane (misma shell y mismo -c que el lanzamiento) y deja el pane MUERTO (remain-on-exit) o lo
      # retira. FAKE_SONDA altera su marcador para las pruebas de fallo cerrado; `pane_ausente` retira el pane sin marcador.
      m="${cmd##*\\" \\"}"; m="${m%\\"}"
      rc=0
      if [ "${FAKE_SONDA:-}" = pane_ausente ]; then printf '%s\\n' "$idx" > "$S/panes"; exit 0; fi
      if [ "${FAKE_SONDA:-}" != sin_marcador ]; then
        ( cd -- "${dir:-.}" 2>/dev/null || :; PATH="${FAKE_SHELL_PATH:-$PATH}" /bin/bash -c "$cmd" ) >> "$S/pane-out.log" 2>&1; rc=$?
      fi
      if [ -e "$m" ]; then
        case "${FAKE_SONDA:-}" in
          nonce_distinto) { printf 'N:%s\\n' 00000000000000000000000000000000; grep -v '^N:' "$m"; } > "$m.x" ;;
          ruta_relativa) { grep -v '^T:\\|^FIN' "$m"; printf 'T:bin/claude-root\\nFIN\\n'; } > "$m.x" ;;
          ruta_inexistente) { grep -v '^T:\\|^FIN' "$m"; printf 'T:/no-existe/claude-root\\nFIN\\n'; } > "$m.x" ;;
          permisos) chmod 644 "$m" ;;
        esac
        if [ -e "$m.x" ]; then chmod 600 "$m.x"; mv -f "$m.x" "$m"; fi
      fi
      printf 'SONDA %s rc=%s\\n' "$idx" "$rc" >> "$LOG"
      if [ -e "$S/remain" ]; then printf '%s' "$rc" > "$S/dead.$idx"; else printf '%s\\n' "$((n - 1))" > "$S/panes"; fi
      exit 0
    fi
    ( cd -- "${dir:-.}" 2>/dev/null || :; PATH="${FAKE_SHELL_PATH:-$PATH}" /bin/bash -c "$cmd" ) >> "$S/pane-out.log" 2>&1; rc=$?
    printf 'RESPAWN %s rc=%s\\n' "$idx" "$rc" >> "$LOG"
    rm -f "$S/dead.$idx"
    if [ "$rc" -ge 126 ]; then
      if [ -e "$S/remain" ]; then printf '%s' "$rc" > "$S/dead.$idx"; else printf '%s\\n' "$((n - 1))" > "$S/panes"; fi
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
"""

FAKE_INCUS = """#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
[ "$#" -gt 1 ] || exit 2
shift
case "$1" in
  "tmux display-message -p -t '"*"' '#{pane_pid}"*)
    # Lectura del pid (y del id estable y la vida del servidor) de un pane. Para un destino relativo `.0`/`.1`, el pid es el
    # del proceso propio de la prueba (FAKE_PID_<índice>) si lo hay; el `%N`, la vida (y el pid, si no hay proceso propio)
    # los da el tmux del canal.
    q="'"; t="${1#*-t $q}"; t="${t%%$q*}"
    out="$(cd "${FAKE_CWD:-/}" 2>/dev/null; PATH="$FAKE_REMOTE_PATH" HOME="$FAKE_HOME" /bin/bash -c "$1" 2>/dev/null)"
    read -r a b d _ <<< "$out"
    case "$a" in %*) rp=""; rid="$a"; vida="$b" ;; *) rp="$a"; rid="$b"; vida="$d" ;; esac
    v="$rp"
    case "$t" in *.1) v="${FAKE_PID_1:-$rp}" ;; *.0) v="${FAKE_PID_0:-$rp}" ;; esac
    case "$1" in *"#{pane_id}"*) printf '%s %s %s\\n' "$v" "$rid" "$vida" ;; *) printf '%s\\n' "$v" ;; esac ;;
  *) printf '%s\\0' "$1" >> "$FAKE_STATE/incus.cmd"
     cd "${FAKE_CWD:-/}" || exit 2
     PATH="$FAKE_REMOTE_PATH" HOME="$FAKE_HOME" exec /bin/bash -c "$1" ;;
esac
"""

AGENT = "#!/bin/bash\nexit 0\n"
AGENT_MUERE = "#!/bin/bash\nexit 127\n"
# Agente que sigue vivo y se ACREDITA por identidad (script bajo python3, intérprete admitido: /proc/<pid>/cmdline lleva la
# ruta del script, que es la acreditada). Ignora los flags del lanzador.
AGENT_VIVO = "#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n"
ALIAS_RC = ('alias claude-root="IS_SANDBOX=1 claude --dangerously-skip-permissions"\n'
            'alias codex-root="IS_SANDBOX=1 codex --dangerously-bypass-approvals-and-sandbox"\n')

# Formas prohibidas por la gramática cerrada del CLI (un solo ejecutable): cada una se rechaza con el remedio.
FORMAS = {
    "asignacion": lambda w: "IS_SANDBOX=1 claude-root",
    "env": lambda w: "env claude-root",
    "espacio": lambda w: "claude-root --dangerously-skip-permissions",
    "punto_y_coma": lambda w: "claude-root;touch no-debe-existir",
    "dolar": lambda w: "$HOME/.local/bin/claude-root",
    "comillas": lambda w: "'claude-root'",
    "ruta_relativa": lambda w: "./bin/claude-root",
}
# Contraejemplos medidos por la revisión R9011j2 (R-02) contra la comprobación previa de j2.
CONTRAEJEMPLOS = {
    "bash_env": lambda w: f"BASH_ENV={w.root}/bashenv claude-root",
    "env_path": lambda w: f"env PATH={w.extra} claude-root",
    "env_i": lambda w: "env -i claude-root",
    "path_sin_agente": lambda w: f"PATH={w.extra} claude-root",
}


def write(path, text, mode=0o755):
    path.write_text(text)
    path.chmod(mode)


def launcher_text(agent, flags):
    """Texto del lanzador, generado por la función REAL de 02-golden.sh."""
    code = 'eval "$(sed -n "/^tc_launcher_text()/,/^}/p" "$1")"; tc_launcher_text "$2" "$3"'
    result = subprocess.run(["/bin/bash", "-c", code, "fixture", str(GOLDEN), agent, flags],
                            env=aislamiento_agentes.entorno_minimo(), text=True, capture_output=True, timeout=10)
    assert result.returncode == 0 and result.stdout.startswith("#!"), \
        f"tc_launcher_text no disponible en 02-golden.sh: {result}"
    return result.stdout


def block_between(path, start_marker, end_markers):
    """Bloque que va de la primera línea con `start_marker` hasta la línea del primer marcador final existente."""
    lines = path.read_text().splitlines()
    first = next((i for i, line in enumerate(lines) if line.startswith(start_marker)), None)
    last = None
    for marker in ([end_markers] if isinstance(end_markers, str) else end_markers):
        last = next((i for i, line in enumerate(lines) if marker in line), None)
        if last is not None:
            break
    assert first is not None and last is not None and first < last, f"anclas ausentes en {path.name}"
    return "\n".join(lines[first:last + 1]) + "\n"


class World:
    """Canal ficticio: PATH remoto cerrado, HOME con el alias que `bash -c` jamás lee, tmux y incus dobles. El entorno de todo lo
    que la prueba lanza es una LISTA BLANCA (nunca el del proceso): el PATH del host es el shim de incus más el espejo del sistema
    SIN agentes, y el HOME, el escrow, el HOME del host y los XDG viven vacíos dentro del mundo."""

    def __init__(self, root):
        self.root = Path(root)
        self.remote = self.root / "remote"
        self.extra = self.root / "fuera-del-path"
        self.shim = self.root / "shim"
        self.home = self.root / "home"
        self.state = self.root / "state"
        self.cwd = self.root / "cwd"
        self.home_vacio = self.root / "home-vacio"
        self.host_home = self.root / "host-home"
        self.secret = self.root / "secret"
        self.tmp = self.root / "tmp"
        xdg = {"XDG_CONFIG_HOME": self.root / "xdg-config", "XDG_DATA_HOME": self.root / "xdg-data",
               "XDG_STATE_HOME": self.root / "xdg-state"}
        for d in (self.remote, self.extra, self.shim, self.home, self.state, self.cwd, self.home_vacio, self.host_home,
                  self.secret, self.tmp, *xdg.values()):
            d.mkdir()
        for utility in UTILS:
            (self.remote / utility).symlink_to(shutil.which(utility))
        write(self.remote / "tmux", FAKE_TMUX)
        write(self.shim / "incus", FAKE_INCUS)
        (self.home / ".bashrc").write_text(ALIAS_RC)
        write(self.root / "bashenv", "PATH=\n", 0o644)
        # La sesión del canal existe (dos panes): la sonda resuelve en ella. Los bloques de lanzamiento la recrean.
        (self.state / "panes").write_text("2\n")
        # TEST_REPO es el directorio del clon en el canal (`-c` de la sesión, de la sonda y del lanzamiento).
        self.sistema = self.sistema_sin_agentes()
        # Lista blanca del entorno del mundo (nombres cerrados): la máquina, HOME y escrow dentro del mundo, la identidad
        # neutra y las variables del arnés. El TCO_TESTIGO_DIR del proceso, si viene, pasa por su nombre exacto.
        self.env = {"PATH": f"{self.shim}:{self.sistema}", "TERM": "dumb", "LANG": "C.UTF-8", "HOME": str(self.home_vacio),
                    **{clave: str(ruta) for clave, ruta in xdg.items()},
                    "HOST_HOME": str(self.host_home), "HOST_USER": HOST_USER, "SECRET_DIR": str(self.secret),
                    "TCO_HOST_ENV": str(self.host_home / "Repo-Neutro" / ".env.local"), **IDENTIDAD,
                    "TMPDIR": str(self.tmp), "FAKE_STATE": str(self.state),
                    "FAKE_REMOTE_PATH": str(self.remote), "FAKE_HOME": str(self.home), "FAKE_CWD": str(self.cwd),
                    "TEST_REPO": str(self.cwd), "TCO_PANE_IDENT_WAIT": "0", "TCO_PANE_LIFE_WAIT": "0"}
        # --- INICIO bloque de la guarda de testigos: paso de TCO_TESTIGO_DIR al mundo ---
        if TESTIGO_DIR:
            self.env["TCO_TESTIGO_DIR"] = TESTIGO_DIR
        # --- FIN bloque de la guarda de testigos ---
        aislamiento_agentes.aserto_entorno(self.env, self.root, completo=True)

    def sistema_sin_agentes(self, sistema=SISTEMA):
        """Ruta de un PATH de sistema SIN agentes, propio del mundo: un enlace por cada entrada ejecutable de `sistema` (en
        orden de PATH, inyectable), salvo los agentes, los lanzadores de paquetes de JS y las herramientas que los pueden
        lanzar. Una vez por mundo y por sistema: una segunda llamada devuelve la misma ruta."""
        sistema = tuple(str(d) for d in sistema)
        nombre = "sistema-sin-agentes" if sistema == SISTEMA else "sistema-sin-agentes-" + hashlib.md5(
            ":".join(sistema).encode()).hexdigest()[:8]
        return aislamiento_agentes.espejo(self.root, sistema, nombre=nombre)

    def sistema_con_agentes(self):
        """Espejo del sistema FALSO de las variantes: `sistema-falso-con-agentes` (los cuatro nombres como dobles vivos del
        mundo) y `utilidades` (solo las de UTILS). Ninguno lleva /usr/bin ni /bin. Devuelve la ruta del espejo."""
        falso = self.root / "sistema-falso-con-agentes"
        falso.mkdir()
        self.launchers(where=falso)
        self.agents(where=falso, text=AGENT_VIVO)
        return aislamiento_agentes.espejo(self.root, (str(falso), aislamiento_agentes.utilidades(self.root, UTILS)),
                                          nombre="sistema-con-agentes-espejo")

    def agents(self, where=None, text=AGENT):
        for name in ("claude", "codex"):
            write((where or self.remote) / name, text)

    def launchers(self, where=None, only=None):
        specs = {"claude-root": ("claude", "--dangerously-skip-permissions"),
                 "codex-root": ("codex", "--dangerously-bypass-approvals-and-sandbox")}
        for name, (agent, flags) in specs.items():
            if only is None or name in only:
                destino = where or self.remote
                texto = launcher_text(agent, flags)
                # R8: el texto final y el destino se aseran ANTES de escribir el lanzador (y de cualquier lanzamiento).
                aislamiento_agentes.aserto_lanzador(name, texto, destino, self.root)
                write(destino / name, texto)

    def tmux_log(self):
        path = self.state / "tmux.log"
        return path.read_text() if path.exists() else ""

    def run(self, code, extra_env=None, timeout=60):
        driver = self.root / "driver.sh"
        driver.write_text(code)
        env = dict(self.env, **(extra_env or {}))
        aislamiento_agentes.aserto_entorno(env, self.root, completo=True, inicial=False)
        return subprocess.run(["/bin/bash", str(driver)], env=env, text=True, capture_output=True,
                              timeout=timeout)


PRELUDE = f'''set -uo pipefail
. {shlex.quote(str(OP / "00-config.sh"))}; . {shlex.quote(str(OP / "lib.sh"))}
tco_container() {{ printf fixture; }}; TCO_CUSER=fixture
CARRIL=01; c=fixture; rp="${{TEST_REPO:-/tmp/repo}}"; SOFT=no
tco_repo_path() {{ printf '%s\\n' "${{TEST_REPO:-/tmp/repo}}"; }}
tco_modelos_config() {{ :; }}
'''


def bloque_sin_tokens(nombre, texto):
    """D7: ningún bloque que se extrae de un guion del producto puede cargar los tokens del host."""
    aislamiento_agentes.aserto_sin_carga_de_tokens(texto, nombre)
    return texto


def dispatch_block():
    return bloque_sin_tokens("dispatch_block", block_between(
        OP / "dispatch.sh", "    SESS_OK=no", ["murió o no existe tras lanzarlo", "no pude iniciar los procesos de agente"]))


def audit_block():
    return bloque_sin_tokens("audit_block", block_between(
        OP / "audit-carril.sh", '  sess_res="$(incus exec',
        ["murió o no existe tras lanzarlo", "no pude iniciar el proceso de auditoría"]))


def lanzamientos(world):
    """Órdenes `respawn-pane` que LANZAN (no las de la sonda, que corre en el mismo pane antes de lanzar)."""
    return [line for line in world.tmux_log().splitlines()
            if line.startswith("respawn-pane") and SONDA_FIRMA not in line]


def check_no_h2(result, world):
    """El síntoma de H2 no debe aparecer jamás, ni se debe haber lanzado ningún agente."""
    text = result.stdout + result.stderr
    assert "can't find pane" not in text, f"aparece el síntoma de H2: {text}"
    assert "RESPAWN" not in world.tmux_log() and not lanzamientos(world), \
        f"se lanzó un pane sin lanzador resoluble: {world.tmux_log()}"


def check_gramatica(mode, result, world, prefix="TCO_DEV"):
    """Rechazo por la gramática cerrada: sin lanzar nada y con el remedio (mover los flags a TCO_*_FLAGS)."""
    text = result.stdout + result.stderr
    assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: {result}"
    check_no_h2(result, world)
    assert f"{prefix}_CLI" in text and f"{prefix}_FLAGS" in text and "gramática" in text, \
        f"{mode}: el error no da la gramática ni el remedio ({prefix}_FLAGS): {text}"


def check_pane_muerto(mode, result, text_wanted):
    """La comprobación de vida: el fallo sale claro (CLI, pane, rc y remedio) y nunca como «can't find pane»."""
    text = result.stdout + result.stderr
    assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: {result}"
    assert "can't find pane" not in text, f"{mode}: aparece el síntoma de H2: {text}"
    assert "127" in text and text_wanted in text and "TCO_" in text, f"{mode}: el error no nombra rc, CLI y variable: {text}"


def mode_dispatch(mode):
    # La variante `_sistema_con_agentes` corre el MISMO caso con un sistema FALSO que SÍ lleva los cuatro agentes (dobles del
    # mundo, sin /usr/bin ni /bin): el espejo tiene que quitarlos y el resultado es el mismo.
    con_agentes = mode.endswith("_sistema_con_agentes")
    mode = mode.removesuffix("_sistema_con_agentes")
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        env = {"TCO_DEV_CLI": "claude-root", "TCO_AUDIT_CLI": "codex-root"}
        forma = mode.split("_", 2)[2] if mode.startswith(("dispatch_gramatica_", "dispatch_r02_")) else ""
        if mode == "dispatch_sin_lanzadores":
            pass
        elif mode == "dispatch_con_lanzadores":
            world.launchers()
        elif mode == "dispatch_lanzadores_fuera_del_path":
            world.launchers(world.extra)
        elif mode == "dispatch_lanzador_no_ejecutable":
            world.launchers()
            (world.remote / "claude-root").chmod(0o644)
        elif mode == "dispatch_falta_el_del_auditor":
            world.launchers(only=("claude-root",))
        elif mode == "dispatch_asignacion_path_sin_lanzadores":
            # J-01: los lanzadores existen en el PATH del canal, pero la orden real los lanzaba con OTRO PATH.
            world.launchers()
            env["TCO_DEV_CLI"] = f"PATH={world.extra} claude-root"
        elif mode == "dispatch_asignacion_path_con_lanzadores":
            # Con la gramática cerrada una asignación NO se acepta aunque el PATH asignado sea bueno.
            world.launchers()
            env["TCO_DEV_CLI"] = f"IS_SANDBOX=1 PATH={world.remote} claude-root"
            env["TCO_AUDIT_CLI"] = f"PATH={world.remote}:{world.extra} codex-root"
        elif mode == "dispatch_asignacion_inverificable":
            world.launchers()
            env["TCO_DEV_CLI"] = "PATH=$HOME/bin:$PATH claude-root"
        elif mode.startswith("dispatch_gramatica_") and forma in FORMAS:
            world.launchers()
            env["TCO_DEV_CLI"] = FORMAS[forma](world)
        elif mode == "dispatch_gramatica_auditor_asignacion":
            world.launchers()
            env["TCO_AUDIT_CLI"] = "IS_SANDBOX=1 codex-root"
        elif mode.startswith("dispatch_r02_") and forma in CONTRAEJEMPLOS:
            world.launchers()
            if forma == "path_sin_agente":
                world.launchers(world.extra)
            env["TCO_DEV_CLI"] = CONTRAEJEMPLOS[forma](world)
        elif mode == "dispatch_lanzador_sin_agente":
            # D4 de la revisión: los lanzadores existen, pero el agente al que hacen `exec` no resuelve en el pane.
            world.launchers()
            (world.remote / "claude").unlink()
        elif mode == "dispatch_path_cliente_con_lanzadores":
            # R-05: el PATH del servidor (global) no tiene los lanzadores, el del cliente que lanza el pane sí.
            world.launchers()
            env["FAKE_GLOBAL_PATH"] = str(world.extra)
        elif mode == "dispatch_path_global_con_lanzadores_cliente_sin":
            # R-05 inverso: el global los tiene, el PATH con que arranca el pane (el del cliente) no.
            world.launchers(world.extra)
            env["FAKE_GLOBAL_PATH"] = f"{world.extra}:{world.remote}"
        elif mode == "dispatch_pane_muere_127":
            # Lanzador y agente existen y son ejecutables (la comprobación previa pasa), pero el agente del dev muere con 127.
            world.launchers()
            write(world.remote / "claude", AGENT_MUERE)
        elif mode == "dispatch_shell_del_servidor":
            # H-01 (R9011j3): la shell del servidor tmux fija PATH=/usr/bin:/bin. El pane real no encuentra el lanzador; la
            # sonda debe ver lo mismo y rechazarlo ANTES de respawn-pane (la base lo autorizaba con su servidor propio). El PATH
            # de esa shell es el espejo del sistema SIN agentes: el caso no depende de lo que el sistema tenga instalado.
            espejo = world.sistema_con_agentes() if con_agentes else world.sistema_sin_agentes()
            world.launchers()
            env["FAKE_SHELL_PATH"] = espejo
            # Guarda estática y sonda de resolución ANTES de lanzar nada: lo que el pane vería, con su mismo PATH y entorno.
            aislamiento_agentes.aserto_estatico_s1(env, espejo)
            aislamiento_agentes.sonda_s1(dict(world.env, **env), espejo, str(world.home), world.root)
        else:
            raise AssertionError(mode)
        result = world.run(PRELUDE + dispatch_block() + "echo BLOQUE-OK\n", env)
        text = result.stdout + result.stderr
        if mode in ("dispatch_asignacion_path_sin_lanzadores", "dispatch_asignacion_path_con_lanzadores",
                    "dispatch_asignacion_inverificable", "dispatch_gramatica_auditor_asignacion") \
                or mode.startswith(("dispatch_gramatica_", "dispatch_r02_")):
            check_gramatica(mode, result, world, "TCO_AUDIT" if mode == "dispatch_gramatica_auditor_asignacion" else "TCO_DEV")
            return
        if mode == "dispatch_pane_muere_127":
            check_pane_muerto(mode, result, "claude-root")
            assert "RESPAWN 0 rc=127" in world.tmux_log() and "RESPAWN 1 rc=0" in world.tmux_log(), \
                f"{mode}: el segundo pane debía lanzarse aunque el primero muriera: {world.tmux_log()}"
            return
        if mode in ("dispatch_con_lanzadores", "dispatch_path_cliente_con_lanzadores"):
            assert result.returncode == 0 and "BLOQUE-OK" in result.stdout, f"{mode}: {result}"
            log = world.tmux_log()
            assert log.count("RESPAWN 0 rc=0") == 1 and log.count("RESPAWN 1 rc=0") == 1, f"{mode}: {log}"
            assert "can't find pane" not in text, f"{mode}: {text}"
            return
        assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: {result}"
        check_no_h2(result, world)
        wanted = "codex-root" if mode == "dispatch_falta_el_del_auditor" else "claude-root"
        if mode == "dispatch_lanzador_sin_agente":
            wanted = "claude"
        assert wanted in text and "TCO_" in text, f"{mode}: el error no nombra el lanzador ni la variable: {text}"
        assert "golden" in text, f"{mode}: el error no da el remedio (reprovisionar el golden): {text}"


def mode_audit(mode):
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        cli = "codex-root"
        if mode == "auditoria_con_lanzador":
            world.launchers()
        elif mode == "auditoria_asignacion_path_ajena":
            world.launchers()
            cli = f"PATH={world.extra} codex-root"
        elif mode == "auditoria_gramatica_asignacion":
            world.launchers()
            cli = "IS_SANDBOX=1 codex-root"
        elif mode == "auditoria_pane_muere_127":
            world.launchers()
            write(world.remote / "codex", AGENT_MUERE)
        result = world.run(PRELUDE + audit_block() + "echo BLOQUE-OK\n", {"TCO_AUDIT_CLI": cli})
        text = result.stdout + result.stderr
        if mode == "auditoria_con_lanzador":
            assert result.returncode == 0 and "RESPAWN 0 rc=0" in world.tmux_log(), f"{mode}: {result}"
            return
        if mode in ("auditoria_gramatica_asignacion", "auditoria_asignacion_path_ajena"):
            check_gramatica(mode, result, world, "TCO_AUDIT")
            return
        if mode == "auditoria_pane_muere_127":
            check_pane_muerto(mode, result, "codex-root")
            return
        assert mode == "auditoria_sin_lanzador"
        assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: {result}"
        assert "codex-root" in text and "golden" in text, f"{mode}: {text}"
        check_no_h2(result, world)


def mode_relanzamiento(mode):
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        cli = "codex-root"
        if mode in ("relanzamiento_con_lanzador", "relanzamiento_gramatica_asignacion", "relanzamiento_pane_muere_127"):
            world.launchers()
        if mode == "relanzamiento_gramatica_asignacion":
            cli = "IS_SANDBOX=1 codex-root"
        if mode == "relanzamiento_pane_muere_127":
            write(world.remote / "codex", AGENT_MUERE)
        (world.state / "panes").write_text("2\n")
        stubs = ("sleep() { :; }; tco_wait_tui_ready() { return 0; }; tco_codex_skip_update_and_trust() { return 0; }\n"
                 "tco_relay_file() { return 0; }; tco_cap_pane() { return 0; }\n")
        result = world.run(PRELUDE + stubs + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                           {"TCO_AUDIT_CLI": cli})
        text = result.stdout + result.stderr
        if mode == "relanzamiento_con_lanzador":
            assert "RESPAWN 1 rc=0" in world.tmux_log(), f"{mode}: {result}"
            return
        if mode == "relanzamiento_gramatica_asignacion":
            assert result.returncode == 1, f"{mode}: {result}"
            assert "TCO_AUDIT_CLI" in text and "TCO_AUDIT_FLAGS" in text and "gramática" in text, f"{mode}: {text}"
            check_no_h2(result, world)
            return
        if mode == "relanzamiento_pane_muere_127":
            assert result.returncode == 1, f"{mode}: {result}"
            assert "can't find pane" not in text and "127" in text and "codex-root" in text, f"{mode}: {text}"
            return
        assert mode == "relanzamiento_sin_lanzador"
        assert result.returncode == 1 and "codex-root" in text and "golden" in text, f"{mode}: {result}"
        check_no_h2(result, world)


def mode_preparar(mode):
    """preparar-sesiones.sh también arranca panes (con send-keys): valida la misma gramática antes de tocar nada."""
    assert mode == "preparar_gramatica_asignacion"
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        world.launchers()
        code = (f'set -uo pipefail\n. {shlex.quote(str(OP / "preparar-sesiones.sh"))}\n'
                'tco_container() { printf fixture; }; TCO_CUSER=fixture; tco_modelos_config() { :; }\n'
                'TCO_DEV_CARRILES=01; TCO_TMUX=v\n'
                'tco_lock_acquire() { return 0; }; tco_lock_release() { return 0; }\n'
                'incus() { printf "INCUS\\n" >> "$FAKE_STATE/incus.calls"; return 0; }\n'
                'tco_preparar_sesion 01 --ejecutar\nexit $?\n')
        result = world.run(code, {"TCO_DEV_CLI": "IS_SANDBOX=1 claude-root", "TCO_AUDIT_CLI": "codex-root"})
        text = result.stdout + result.stderr
        assert result.returncode != 0, f"{mode}: {result}"
        assert not (world.state / "incus.calls").exists(), f"{mode}: se tocó el canal antes de validar el CLI"
        assert "TCO_DEV_CLI" in text and "TCO_DEV_FLAGS" in text and "gramática" in text, f"{mode}: {text}"


def respawn_lanzamientos(path):
    """Líneas de código (no comentarios) con el `respawn-pane` que LANZA el agente; la de la sonda no cuenta."""
    lines = path.read_text().splitlines()
    return lines, [i for i, line in enumerate(lines) if "tmux respawn-pane -k" in line
                   and not line.lstrip().startswith("#") and "$orden" not in line]


def mode_orden():
    """Estático: la comprobación previa precede a cada respawn-pane de los tres sitios."""
    for name in ("dispatch.sh", "audit-carril.sh", "lib.sh"):
        lines, respawns = respawn_lanzamientos(OP / name)
        assert respawns, f"{name}: sin respawn-pane de lanzamiento"
        respawn = respawns[0]
        check = max((i for i, line in enumerate(lines[:respawn])
                     if line.lstrip().startswith("tco_launchers_ready ") and not line.lstrip().startswith("#")), default=None)
        assert check is not None and check < respawn, f"{name}: falta tco_launchers_ready antes del respawn-pane"


def mode_j5_orden_estatico():
    """J4-01/J4-02 (R9011j4), estático: en los tres sitios el lanzamiento real ejecuta la ruta que acreditó la sonda (nunca
    el token `$TCO_*_CLI`, que se volvería a resolver por PATH), con el MISMO `-c` que la sonda; remain-on-exit se prepara
    antes de la sonda (el pane queda muerto tras ella), y ninguna sonda abre ventanas (`new-window`)."""
    for name in ("dispatch.sh", "audit-carril.sh", "lib.sh"):
        lines, respawns = respawn_lanzamientos(OP / name)
        assert respawns, f"{name}: sin respawn-pane de lanzamiento"
        for i in respawns:
            line = lines[i]
            assert "$TCO_DEV_CLI" not in line and "$TCO_AUDIT_CLI" not in line, \
                f"{name}:{i + 1}: el lanzamiento vuelve a resolver el token por PATH: {line.strip()}"
            assert " -c '$" in line, f"{name}:{i + 1}: el lanzamiento no lleva el -c del clon: {line.strip()}"
        remain = max((i for i, line in enumerate(lines[:respawns[0]])
                      if line.lstrip().startswith("tco_remain_preparar ")), default=None)
        check = max((i for i, line in enumerate(lines[:respawns[0]])
                     if line.lstrip().startswith("tco_launchers_ready ")), default=None)
        assert remain is not None and check is not None and remain < check, \
            f"{name}: remain-on-exit debe prepararse ANTES de la sonda (el pane queda muerto tras ella)"
    code = [line for line in (OP / "lib.sh").read_text().splitlines() if not line.lstrip().startswith("#")]
    assert not [line for line in code if "new-window" in line], "lib.sh: una sonda vuelve a abrir ventanas"
    sonda = [line for line in code if "tmux respawn-pane -k" in line and "$orden" in line]
    assert len(sonda) == 1 and " -c '$cwd'" in sonda[0], f"lib.sh: la sonda no es un respawn-pane con el -c del lanzamiento: {sonda}"
    # El transporte del código de identidad (citado con %q en la orden de incus) con comillas simples dentro se prueba por
    # EJECUCIÓN en identidad_transporte_comilla_simple; el doble de montaje lo decodifica con bash, ya no con shlex.


def identity_world(tmp, two=False):
    """Mundo con procesos reales: copias de python3 con el nombre del agente (su /proc/PID/exe)."""
    world = World(tmp)
    procs = []
    for index, agent in enumerate(("claude", "codex") if two else ("claude",)):
        binary = world.remote / agent
        shutil.copyfile(shutil.which("python3"), binary)
        binary.chmod(0o755)
        proc = subprocess.Popen([str(binary), "-c", "import time; time.sleep(60)"], env=world.env, start_new_session=True)
        procs.append(proc)
        world.env[f"FAKE_PID_{index}"] = str(proc.pid)
    return world, procs


def mode_identidad(mode):
    with tempfile.TemporaryDirectory() as tmp:
        world, procs = identity_world(tmp, two=mode == "preflight_con_lanzadores_script")
        try:
            code = PRELUDE + '_tco_pane_agent_exes 01 v:.0 "$1"\nexit $?\n'
            if mode == "preflight_con_lanzadores_script":
                world.launchers()
                code = (PRELUDE + 'TCO_DEV_CLI=claude-root; TCO_AUDIT_CLI=codex-root; TCO_AUDIT_TOPOLOGY=distinto\n'
                        'tco_pane_identity_preflight 01\nexit $?\n')
                result = world.run(code)
                assert result.returncode == 0 and "AUDITOR: codex " in result.stdout, f"{mode}: {result}"
                return
            if mode == "identidad_lanzador_script":
                world.launchers(only=("claude-root",))
                expected_rc, expected_out = 0, "claude\n"
            elif mode == "identidad_lanzador_de_otro_agente":
                write(world.remote / "claude-root", '#!/bin/bash\nIS_SANDBOX=1 exec codex --x "$@"\n')
                write(world.remote / "codex", AGENT)
                expected_rc, expected_out = 2, ""
            elif mode == "identidad_lanzador_sin_exec":
                write(world.remote / "claude-root", "#!/bin/bash\necho hola\n")
                expected_rc, expected_out = 0, ""
            elif mode == "identidad_lanzador_destino_ausente":
                write(world.remote / "claude-root", '#!/bin/bash\nIS_SANDBOX=1 exec /nada/claude "$@"\n')
                expected_rc, expected_out = 2, ""
            else:
                raise AssertionError(mode)
            result = world.run(code.replace('"$1"', "claude-root"))
            # La identidad añade `real=<ruta real esperada>` (y `ino=<dispositivo:inodo>`) tras el nombre cuando acredita.
            lines = result.stdout.splitlines()
            names = [line for line in lines if not line.startswith(("real=", "ino="))]
            assert result.returncode == expected_rc and "".join(n + "\n" for n in names) == expected_out, f"{mode}: {result}"
        finally:
            for proc in procs:
                proc.kill()
                proc.wait()


def decode_transport(command):
    """Decodifica la orden remota como la decodificaría bash: una función `bash` intercepta la llamada y vuelca sus
    argumentos, sin ejecutar el cuerpo. Es el método del doble de montaje (infra-real.py), no shlex."""
    result = subprocess.run(["/bin/bash", "-c", 'bash() { printf "%s\\0" "$@"; }; ' + command],
                            env=aislamiento_agentes.entorno_minimo(), capture_output=True, timeout=10)
    assert result.returncode == 0, result
    return [w.decode() for w in result.stdout.split(b"\0")[:-1]]


def first_line(text):
    return text.splitlines()[0] if text else ""


def mode_identidad_ajena(mode):
    """J-02: un destino ajeno con el basename esperado NO se acredita como el agente; el real del golden sí.
    J-03: el código de identidad viaja citado y se EJECUTA con bash también con comillas simples."""
    with tempfile.TemporaryDirectory() as tmp:
        procs = []
        try:
            if mode == "identidad_destino_ruta_canonica":
                world, procs = identity_world(tmp)
                write(world.remote / "claude-root", f'#!/bin/bash\nIS_SANDBOX=1 exec {world.remote}/claude --x "$@"\n')
                result = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.0 claude-root\nexit $?\n')
                assert result.returncode == 0 and first_line(result.stdout) == "claude", f"{mode}: {result}"
                return
            if mode == "identidad_transporte_comilla_simple":
                world, procs = identity_world(tmp)
                world.launchers(only=("claude-root",))
                marker = "# transporte: comilla ' simple y \"dobles\" dentro del código de identidad"
                original = (OP / "lib.sh").read_text()
                anchor = "<<'PANE_IDENTITY' || true\n"
                assert anchor in original, "ancla del heredoc de identidad ausente"
                patched = world.root / "lib-comilla.sh"
                patched.write_text(original.replace(anchor, anchor + marker + "\n", 1))
                prelude = PRELUDE.replace(str(OP / "lib.sh"), str(patched))
                assert str(patched) in prelude
                result = world.run(prelude + '_tco_pane_agent_exes 01 v:.0 claude-root\nexit $?\n')
                assert result.returncode == 0 and first_line(result.stdout) == "claude", f"{mode}: no se ejecutó: {result}"
                logged = (world.state / "incus.cmd").read_bytes().split(b"\0")[:-1]
                words = [decode_transport(c.decode()) for c in logged]
                match = [w for w in words if len(w) >= 6 and w[0] == "-c" and marker in w[1]]
                assert len(match) == 1, f"{mode}: el código con comilla simple no llegó íntegro: {words}"
                assert match[0][2] == "_" and match[0][4:6] == ["claude-root", "claude"], f"{mode}: {match[0][2:]}"
                return
            world = World(tmp)
            world.agents()
            foreign = world.root / "ajeno"
            foreign.mkdir()
            binary = foreign / "claude"
            shutil.copyfile(shutil.which("python3"), binary)
            binary.chmod(0o755)
            sleeper = ["-c", "import time; time.sleep(60)"]
            if mode == "identidad_destino_ajeno_mismo_basename":
                procs.append(subprocess.Popen([str(binary), *sleeper], env=world.env, start_new_session=True))
                world.env["FAKE_PID_0"] = str(procs[0].pid)
                write(world.remote / "claude-root", f'#!/bin/bash\nIS_SANDBOX=1 exec {binary} --x "$@"\n')
                result = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.0 claude-root\nexit $?\n')
                assert result.returncode == 2 and result.stdout == "", f"{mode}: {result}"
            elif mode == "preflight_dos_destinos_ajenos_comunes":
                # Dos lanzadores cuyos destinos llamados claude y codex son el MISMO ejecutable ajeno.
                (foreign / "codex").symlink_to(binary)
                procs.append(subprocess.Popen([str(foreign / "claude"), *sleeper], env=world.env, start_new_session=True))
                procs.append(subprocess.Popen([str(foreign / "codex"), *sleeper], env=world.env, start_new_session=True))
                world.env["FAKE_PID_0"], world.env["FAKE_PID_1"] = (str(p.pid) for p in procs)
                write(world.remote / "claude-root", f'#!/bin/bash\nIS_SANDBOX=1 exec {foreign}/claude --x "$@"\n')
                write(world.remote / "codex-root", f'#!/bin/bash\nIS_SANDBOX=1 exec {foreign}/codex --x "$@"\n')
                result = world.run(PRELUDE + 'TCO_DEV_CLI=claude-root; TCO_AUDIT_CLI=codex-root; '
                                   'TCO_AUDIT_TOPOLOGY=distinto\ntco_pane_identity_preflight 01\nexit $?\n')
                assert result.returncode != 0 and "AUDITOR:" not in result.stdout, f"{mode}: {result}"
            else:
                raise AssertionError(mode)
        finally:
            for proc in procs:
                proc.kill()
                proc.wait()


def mode_identidad_pane(mode):
    """R-01, R-05 y R-04 de la revisión R9011j2 sobre la identidad de los panes."""
    with tempfile.TemporaryDirectory() as tmp:
        procs = []
        try:
            if mode == "identidad_r01_dos_sleep":
                # PATH asignado al CLI hacia un directorio donde `claude` y `codex` son enlaces a /bin/sleep: dos procesos
                # `sleep` se acreditaban como claude y codex con topología «distinto».
                world, procs = identity_world(tmp, two=True)
                world.launchers()
                disfraz = world.root / "disfraz"
                disfraz.mkdir()
                for pid_index, agent in enumerate(("claude", "codex")):
                    (disfraz / agent).symlink_to(shutil.which("sleep"))
                    procs.append(subprocess.Popen([str(disfraz / agent), "120"], executable=str(disfraz / agent),
                                                  env=world.env, start_new_session=True))
                    world.env[f"FAKE_PID_{pid_index}"] = str(procs[-1].pid)
                code = (PRELUDE + f'TCO_DEV_CLI="PATH={disfraz}:{world.remote} claude-root"; '
                        f'TCO_AUDIT_CLI="PATH={disfraz}:{world.remote} codex-root"; TCO_AUDIT_TOPOLOGY=distinto\n'
                        'tco_pane_identity_preflight 01\nexit $?\n')
                result = world.run(code)
                assert result.returncode != 0 and "AUDITOR:" not in result.stdout, f"{mode}: {result}"
                return
            if mode == "identidad_r05_path_del_pane":
                # El PATH global del servidor tmux no tiene los lanzadores; el PATH con que arranca el pane sí.
                world, procs = identity_world(tmp, two=True)
                world.launchers()
                code = (PRELUDE + 'TCO_DEV_CLI=claude-root; TCO_AUDIT_CLI=codex-root; TCO_AUDIT_TOPOLOGY=distinto\n'
                        'tco_pane_identity_preflight 01\nexit $?\n')
                result = world.run(code, {"FAKE_GLOBAL_PATH": str(world.extra)})
                assert result.returncode == 0 and "AUDITOR: codex " in result.stdout, f"{mode}: {result}"
                return
            if mode in ("identidad_r04_mismo_binario_real", "identidad_r04_nombres_declarados"):
                # R-04: nombres distintos (claude/codex) que resuelven al MISMO ejecutable real no son independientes.
                world = World(tmp)
                real = world.root / "unico"
                shutil.copyfile(shutil.which("python3"), real)
                real.chmod(0o755)
                for agent in ("claude", "codex"):
                    (world.remote / agent).symlink_to(real)
                for index in range(2):
                    procs.append(subprocess.Popen([str(real), "-c", "import time; time.sleep(60)"], env=world.env,
                                                  start_new_session=True))
                    world.env[f"FAKE_PID_{index}"] = str(procs[index].pid)
                declared = ("claude", "codex")
                if mode == "identidad_r04_nombres_declarados":
                    declared = (str(world.remote / "claude"), str(world.remote / "codex"))
                code = (PRELUDE + f'TCO_DEV_CLI={declared[0]}; TCO_AUDIT_CLI={declared[1]}; TCO_AUDIT_TOPOLOGY=distinto\n'
                        'tco_pane_identity_preflight 01\nexit $?\n')
                result = world.run(code)
                assert result.returncode != 0 and "AUDITOR:" not in result.stdout, f"{mode}: {result}"
                return
            raise AssertionError(mode)
        finally:
            for proc in procs:
                proc.kill()
                proc.wait()


class RealTmux:
    """tmux REAL en un servidor PRIVADO de la prueba: socket PROPIO dentro del mundo (`-S <mundo>/tmux.sock`), nunca el servidor
    por defecto ni uno de la máquina, sin `TMUX` heredado y con un entorno en lista blanca cuyo PATH es el del mundo (los
    dobles del canal y el espejo del sistema SIN agentes). El `tmux` del PATH remoto es un envoltorio que fuerza ese socket
    (una orden que ya trae su propio `-L` o `-S` se respeta y vive en el mismo mundo). El servidor arranca sin fichero de
    configuración (`-f /dev/null`). `close` mata el servidor y todos los del directorio de sockets y comprueba que no queda
    ninguno vivo."""

    def __init__(self, world):
        self.real = shutil.which("tmux")
        assert self.real, "tmux ausente: la sonda de resolución lo exige (los canales ya lo requieren)"
        self.world = world
        self.sockets = world.root / "tmux-sockets"
        self.sockets.mkdir()
        self.socket = world.root / "tmux.sock"
        world.env["TMUX_TMPDIR"] = str(self.sockets)
        world.env.pop("TMUX", None)
        self.env = dict(world.env, PATH=f"{world.remote}:{world.sistema}", HOME=str(world.home))
        aislamiento_agentes.aserto_entorno(self.env, world.root, completo=True, inicial=False)
        real, sock = shlex.quote(self.real), shlex.quote(str(self.socket))
        (world.remote / "tmux").unlink()
        write(world.remote / "tmux", '#!/bin/bash\nunset TMUX\n'
              f'if [ "${{1:-}}" = -L ] || [ "${{1:-}}" = -S ]; then exec {real} "$@"; fi\nexec {real} -S {sock} "$@"\n')

    def __call__(self, *args):
        return subprocess.run([self.real, "-S", str(self.socket), *args], env=self.env, capture_output=True, text=True,
                              timeout=15)

    def start(self, shell="/bin/bash"):
        result = self("-f", "/dev/null", "new-session", "-d", "-s", "arranque", "-c", str(self.world.cwd), "sleep 600")
        assert result.returncode == 0, f"servidor privado de la prueba: {result}"
        result = self("display-message", "-p", "#{socket_path}")
        assert result.returncode == 0, result
        aislamiento_agentes.aserto_socket_tmux(result.stdout, self.world.root)
        result = self("set-option", "-g", "default-shell", shell)
        assert result.returncode == 0, result

    def session(self, name="v", panes=1, command="sleep 600"):
        result = self("new-session", "-d", "-s", name, "-c", str(self.world.cwd), command)
        assert result.returncode == 0, result
        for _ in range(panes - 1):
            result = self("split-window", "-h", "-t", f"{name}:", "-c", str(self.world.cwd), command)
            assert result.returncode == 0, result

    def session_sonda(self, etiqueta, panes=2, rama_shell_normal=False):
        """La sesión v con la sonda de resolución como PRIMERA orden de sus panes: escribe en el mundo qué resuelven de verdad
        (command -v de los agentes, node y npx con el PATH real del pane) y se lee ANTES de lanzar nada. Todo tiene que ser un
        doble del mundo; solo las dos ramas de shell normal admiten (y anotan) un agente del sistema."""
        ficheros = [self.world.root / f"sonda-pane-{etiqueta}-{pane}.txt" for pane in range(panes)]
        result = self("new-session", "-d", "-s", "v", "-c", str(self.world.cwd), aislamiento_agentes.orden_sonda(ficheros[0]))
        assert result.returncode == 0, result
        for fichero in ficheros[1:]:
            result = self("split-window", "-h", "-t", "v:", "-c", str(self.world.cwd), aislamiento_agentes.orden_sonda(fichero))
            assert result.returncode == 0, result
        # Un fichero de sonda POR PANE: se exigen todos (cada uno con su FIN) antes de seguir.
        return aislamiento_agentes.leer_sondas(ficheros, self.world.root, rama_shell_normal)

    def panes(self, session="v"):
        """Panes REALES de la sesión (índice, id y pid): no deben cambiar por la sonda."""
        result = self("list-panes", "-s", "-t", f"{session}:", "-F",
                      "#{window_index}.#{pane_index}|#{pane_id}|#{pane_pid}|#{window_name}")
        assert result.returncode == 0, result
        return result.stdout

    def sonda_windows(self):
        result = self("list-windows", "-a", "-F", "#{session_name}:#{window_name}")
        return [w for w in result.stdout.split() if ":tco-sonda" in w]

    def close(self):
        self("kill-server")
        sockets = [self.socket, *self.sockets.rglob("*")]
        for socket in sockets:
            if socket.is_socket():
                subprocess.run([self.real, "-S", str(socket), "kill-server"], env=self.env, capture_output=True, timeout=10)
        left = [s for s in sockets if s.is_socket()
                and subprocess.run([self.real, "-S", str(s), "has-session"], env=self.env, capture_output=True,
                                   timeout=10).returncode == 0]
        assert not left, f"queda algún servidor tmux de la prueba vivo: {left}"


def lanza_real(world, tm, cli, index=0):
    """Lanza `cli` POR NOMBRE en el pane v:.<index> como lo lanzaba el despacho de la base (orden por incus, mismo cliente,
    sin `-c`) y devuelve su rc real: es la MEDIDA de lo que ese pane resuelve de verdad."""
    tm("set-option", "-w", "-t", "v:", "remain-on-exit", "on")
    result = world.run(PRELUDE + f"incus exec fixture -- su - fixture -c \"tmux respawn-pane -k -t 'v:.{index}' "
                       f"'CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 {cli}'\"\nexit $?\n")
    assert result.returncode == 0, result
    state, parts = "", []
    for _ in range(30):
        state = tm("list-panes", "-t", "v:", "-F", "#{pane_index}|#{pane_dead}|#{pane_dead_status}").stdout
        parts = next((line for line in state.splitlines() if line.startswith(f"{index}|")), "").split("|")
        if len(parts) == 3 and parts[1] == "1" and parts[2] != "":
            return int(parts[2])
        time.sleep(0.1)
    # Medido con tmux 3.4 (salida e9011j4/sonda-estado): un comando no encontrado bajo una default-shell que hace `exec
    # /bin/bash` deja el pane muerto SIN pane_dead_status (H-04). Entonces el rc real se lee del propio pane.
    # -J une las líneas partidas por el ancho del pane (el mensaje «command not found» se parte en panes estrechos).
    capture = tm("capture-pane", "-p", "-J", "-t", f"v:.{index}").stdout
    if parts[1:2] == ["1"] and "command not found" in " ".join(capture.split()):
        return 127
    if parts[1:2] == ["0"]:
        return 0 # sigue vivo: el agente arrancó
    raise AssertionError(f"el pane real no terminó con su estado completo: {state} {capture!r}")


def relanza(world, cli="codex-root"):
    """El relanzamiento REAL de lib.sh (`tco_codex_relaunch_and_role`) sobre el pane v:.1: sonda, lanzamiento y vida."""
    return world.run(PRELUDE + RELANZAMIENTO_STUBS + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                     {"TCO_AUDIT_CLI": cli})


def orden_del_pane(tm, pane="v:.1"):
    return tm("display-message", "-p", "-t", pane, "#{pane_start_command}").stdout.strip()


def lanzado(antes, despues):
    """¿El pane recibió un LANZAMIENTO? (otra orden que la previa y que no es la de la sonda)."""
    return despues != antes and SONDA_FIRMA not in despues


def check_rechazo_previo(mode, result, tm, antes, cli="codex-root", despues=None):
    """Fallo cerrado ANTES de lanzar: rc != 0, el error nombra el CLI y el remedio, y el pane no recibió el lanzamiento."""
    text = result.stdout + result.stderr
    despues = orden_del_pane(tm) if despues is None else despues
    assert result.returncode != 0, f"{mode}: la comprobación AUTORIZA y el relanzamiento sigue: {result}"
    assert not lanzado(antes, despues) and "murió tras lanzar" not in text, \
        f"{mode}: se lanzó el agente (la comprobación autorizó lo que el pane no puede ejecutar): {despues!r} {text}"
    assert cli in text and "can't find pane" not in text, f"{mode}: mensaje poco claro: {text}"


def mode_sonda_tmux_real():
    """La identidad de SOLO LECTURA con tmux REAL (pane sin ruta acreditada): acredita al agente y no toca ningún pane ni
    abre ventanas."""
    with tempfile.TemporaryDirectory() as tmp:
        world, procs = identity_world(tmp)
        tm = RealTmux(world)
        try:
            world.launchers(only=("claude-root",))
            tm.start()
            tm.session("v")
            before = tm.panes()
            result = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.0 claude-root\nexit $?\n')
            assert result.returncode == 0 and first_line(result.stdout) == "claude", f"sonda_tmux_real: {result}"
            assert f"real={world.remote / 'claude'}" in result.stdout, f"sonda_tmux_real: {result}"
            assert tm.panes() == before, f"sonda_tmux_real: la sonda tocó un pane real: {before} -> {tm.panes()}"
            assert not tm.sonda_windows(), f"sonda_tmux_real: queda una ventana temporal: {tm.sonda_windows()}"
        finally:
            tm.close()
            for proc in procs:
                proc.kill()
                proc.wait()


def otros_panes(tm, pane_index="1"):
    """Panes de la sesión v salvo el de destino (índice, id y pid; sin el nombre de ventana, que tmux renombra solo según
    la orden en curso): la comprobación no puede tocarlos."""
    result = tm("list-panes", "-s", "-t", "v:", "-F", "#{window_index}.#{pane_index}|#{pane_id}|#{pane_pid}")
    assert result.returncode == 0, result
    return [line for line in result.stdout.splitlines() if not line.split("|")[0].endswith(f".{pane_index}")]


def escribe_shell(world, fichero, espejo, prefijo_pwd=False):
    """Shell del servidor tmux de la prueba: fija el PATH del espejo del sistema SIN agentes (citado; en la de `j5_b` con el
    directorio actual delante, que es el objeto del caso) y arranca bash SIN login ni rc con un entorno cerrado: HOME y XDG
    vacíos dentro del mundo. La guarda estática corre ANTES de que nadie la use."""
    ruta = ('"$PWD/bin":' if prefijo_pwd else "") + shlex.quote(espejo)
    write(fichero, "#!/bin/bash\n"
          f"export PATH={ruta}\n"
          f'exec /usr/bin/env -i PATH="$PATH" HOME={shlex.quote(str(world.home_vacio))} '
          f'XDG_CONFIG_HOME={shlex.quote(world.env["XDG_CONFIG_HOME"])} XDG_DATA_HOME={shlex.quote(world.env["XDG_DATA_HOME"])} '
          'TERM=dumb LANG=C.UTF-8 /bin/bash --noprofile --norc "$@"\n')
    aislamiento_agentes.aserto_estatico_shell(fichero, espejo, world.root, str(world.home_vacio), world.env["XDG_CONFIG_HOME"],
                                              world.env["XDG_DATA_HOME"], prefijo_pwd)


def mide_resolucion(world, tm, cli, index, etiqueta):
    """MIDE lo que el pane v:.<index> resuelve para el nombre dado con SU shell, sin ejecutar lo resuelto: un respawn en ese
    pane con la orden de medida (la ruta que da la resolución y su rc, hacia un fichero del mundo). Devuelve (ruta, rc)."""
    fichero = world.root / f"resol-{etiqueta}.txt"
    fichero.unlink(missing_ok=True)
    orden = aislamiento_agentes.orden_medida(cli, fichero, world.root)
    tm("set-option", "-w", "-t", "v:", "remain-on-exit", "on")
    carga = shlex.quote(f"tmux respawn-pane -k -t 'v:.{index}' " + shlex.quote(orden))
    result = world.run(PRELUDE + f"incus exec fixture -- su - fixture -c {carga}\nexit $?\n")
    assert result.returncode == 0, result
    for _ in range(100):
        lineas = fichero.read_text().splitlines() if fichero.exists() else []
        if lineas and lineas[-1].startswith("rc="):
            return (lineas[0] if len(lineas) > 1 else ""), int(lineas[-1][3:])
        time.sleep(0.1)
    raise AssertionError(f"la medida de resolución de {cli} no terminó: {lineas}")


def comprobacion_previa(world, cli):
    """Solo la COMPROBACIÓN PREVIA de la librería sobre el pane v:.1 (la sonda de resolución, sin lanzamiento): imprime la
    ruta del lanzador que acreditó."""
    return world.run(PRELUDE + "tco_panes_fijar_sesion 01 1 || exit 90\n"
                     'read -r pane < <(tco_pane_destino v:.1)\n'
                     'tco_remain_preparar 01 "$pane" || exit 91\n'
                     f'tco_launchers_ready 01 "$rp" TCO_AUDIT_CLI "$pane" {shlex.quote(cli)} || exit 92\n'
                     'printf "LANZADOR=%s\\n" "${_TCO_LANZADOR[$pane]-}"\n')


def aserta_lanzador_del_mundo(world, cli, ruta):
    assert ruta and os.path.realpath(ruta) == os.path.realpath(world.remote / cli), \
        f"la resolución no es el lanzador del mundo: {ruta!r}"


def _control_positivo_s2(world, tm, cli):
    """Control positivo de H-01 en el MISMO servidor, con la shell normal y remain-on-exit global en on. Solo MIDE, no lanza
    ningún agente: la comprobación previa de la librería autoriza y acredita el lanzador del mundo, y el pane resuelve el
    nombre a ese lanzador con rc 0."""
    assert tm("set-option", "-g", "default-shell", "/bin/bash").returncode == 0
    assert tm("set-option", "-g", "remain-on-exit", "on").returncode == 0
    tm("kill-session", "-t", "v")
    tm.session_sonda("2", rama_shell_normal=True)
    result = comprobacion_previa(world, cli)
    acreditado = next((l[len("LANZADOR="):] for l in result.stdout.splitlines() if l.startswith("LANZADOR=")), "")
    assert result.returncode == 0 and not tm.sonda_windows(), f"control: {result} {tm.sonda_windows()}"
    aserta_lanzador_del_mundo(world, cli, acreditado)
    ruta, rc = mide_resolucion(world, tm, cli, 1, "s2")
    assert rc == 0, f"control: el pane no resuelve {cli} (rc {rc})"
    aserta_lanzador_del_mundo(world, cli, ruta)


def mode_sonda_shell_del_servidor(mode=None):
    """H-01 (R9011j3), regresión obligatoria con tmux REAL: un servidor YA configurado con una `default-shell` que fija un PATH
    propio del mundo SIN agentes. El pane real no encuentra el lanzador (127). La comprobación debe resolver lo mismo que ese
    pane y rechazar ANTES de lanzar. Control positivo en el MISMO servidor con la shell normal y `remain-on-exit` global en
    on (solo mide la resolución: un agente real no se ejecuta en una prueba). Pasa por el relanzamiento real de lib.sh
    (comprobación, lanzamiento y vida) sobre el pane v:.1. La variante `_sistema_con_agentes` usa un sistema FALSO que SÍ
    lleva los agentes."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        espejo = world.sistema_con_agentes() if (mode or "").endswith("_sistema_con_agentes") else world.sistema_sin_agentes()
        alterna = world.root / "shell-alterna"
        escribe_shell(world, alterna, espejo)
        aislamiento_agentes.aserto_r11(_control_positivo_s2, comprobacion_previa)
        tm = RealTmux(world)
        try:
            tm.start(str(alterna))
            tm.session_sonda("1")
            otros, antes = otros_panes(tm), orden_del_pane(tm)
            result = relanza(world)
            assert otros_panes(tm) == otros, f"la comprobación tocó otro pane: {otros} -> {otros_panes(tm)}"
            assert not tm.sonda_windows(), f"queda una ventana temporal: {tm.sonda_windows()}"
            check_rechazo_previo("sonda_shell_del_servidor", result, tm, antes)
            assert "golden" in result.stdout + result.stderr, result
            real_rc = lanza_real(world, tm, "codex-root", 1)
            assert real_rc == 127, f"precondición: el pane real debía morir con 127 y dio {real_rc}"
            _control_positivo_s2(world, tm, "codex-root")
        finally:
            tm.close()


def mode_sonda_sesion_ausente():
    """H-01: si la sesión de destino no existe, no se puede resolver en ella: rechazo fail-closed con mensaje claro."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        world.launchers()
        tm = RealTmux(world)
        try:
            tm.start()
            result = relanza(world)
            text = result.stdout + result.stderr
            assert result.returncode != 0, f"sin la sesión de destino la comprobación no puede autorizar: {result}"
            assert "sesión" in text and "'v'" in text, f"mensaje poco claro: {text}"
            assert "RESPAWN" not in text and not tm.sonda_windows(), tm.sonda_windows()
        finally:
            tm.close()


def mode_sonda_colgada():
    """H-01: la sonda no contesta (shell del servidor colgada): tope, rechazo fail-closed, ninguna ventana y ningún otro pane
    tocado."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        world.launchers()
        colgada = world.root / "shell-colgada"
        write(colgada, "#!/bin/bash\nexec sleep 300\n")
        tm = RealTmux(world)
        try:
            tm.start(str(colgada))
            tm.session("v", panes=2)
            otros = otros_panes(tm)
            start = time.monotonic()
            result = relanza(world)
            elapsed = time.monotonic() - start
            text = result.stdout + result.stderr
            assert result.returncode != 0, f"una sonda sin respuesta no puede autorizar: {result}"
            assert elapsed < 30, f"la sonda no respetó su tope: {elapsed:.1f} s"
            assert "sonda" in text and "codex-root" in text, f"mensaje poco claro: {text}"
            assert not tm.sonda_windows(), f"queda una ventana temporal huérfana: {tm.sonda_windows()}"
            assert otros_panes(tm) == otros, f"la sonda tocó otro pane: {otros} -> {otros_panes(tm)}"
        finally:
            tm.close()


def _rama_shell_nueva_s4(world, tm, cli, medida):
    """Rama de un tmux que relanza el pane con la shell NUEVA. Solo MIDE, no lanza ningún agente: el pane resuelve el nombre
    al lanzador del mundo y la comprobación previa de la librería autoriza y acredita ese mismo lanzador."""
    ruta, rc = medida
    assert rc == 0, f"j5_a: la medida de la rama no resuelve (rc {rc})"
    aserta_lanzador_del_mundo(world, cli, ruta)
    fichero = world.root / "sonda-pane-s4-nueva.txt"
    assert tm("respawn-pane", "-k", "-t", "v:.1", aislamiento_agentes.orden_sonda(fichero)).returncode == 0
    aislamiento_agentes.leer_sonda(fichero, world.root, rama_shell_normal=True)
    result = comprobacion_previa(world, cli)
    acreditado = next((l[len("LANZADOR="):] for l in result.stdout.splitlines() if l.startswith("LANZADOR=")), "")
    assert result.returncode == 0 and not tm.sonda_windows(), f"j5_a: el pane resuelve el lanzador y la comprobación lo rechaza: {result}"
    aserta_lanzador_del_mundo(world, cli, acreditado)


def mode_j5_a_shell_cambiada(mode=None):
    """J4-01 A (R9011j4), tmux REAL: la sesión se crea con una shell que fija un PATH propio del mundo SIN agentes y DESPUÉS se
    cambia su `default-shell` a /bin/bash. Una ventana nueva usaría la shell nueva; el pane ya creado conserva la suya y muere
    con 127. La comprobación debe resolver lo MISMO que ese pane (fallo cerrado antes de lanzar), no autorizar. Lo que el pane
    resuelve se MIDE con un respawn y decide la rama: restringida (el caso mide siempre el rechazo previo) o, en un tmux que
    relanza con la shell nueva, la rama de _rama_shell_nueva_s4."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        espejo = world.sistema_con_agentes() if (mode or "").endswith("_sistema_con_agentes") else world.sistema_sin_agentes()
        restringida = world.root / "shell-restringida"
        escribe_shell(world, restringida, espejo)
        aislamiento_agentes.aserto_r11(_rama_shell_nueva_s4, comprobacion_previa)
        tm = RealTmux(world)
        try:
            tm.start(str(restringida))
            tm.session_sonda("1")
            assert tm("set-option", "-t", "v", "default-shell", "/bin/bash").returncode == 0
            medida = mide_resolucion(world, tm, "codex-root", 1, "s4")
            # La medida va ANTES de tomar los invariantes: su respawn no cuenta como lanzamiento.
            otros, antes = otros_panes(tm), orden_del_pane(tm)
            print(f"j5_a: el pane resuelve rc={medida[1]}")
            if medida[1] == 0:
                _rama_shell_nueva_s4(world, tm, "codex-root", medida)
            else:
                result = relanza(world)
                despues = orden_del_pane(tm)
                check_rechazo_previo("j5_a_shell_cambiada", result, tm, antes, despues=despues)
            assert otros_panes(tm) == otros and not tm.sonda_windows(), "j5_a: se tocó otro pane o quedó una ventana"
        finally:
            tm.close()


def mode_j5_b_cwd(mode):
    """J4-01 B (R9011j4), tmux REAL: la shell fija PATH="$PWD/bin:…"; el pane se creó con `-c <repo>` y el cliente corre
    desde <home>, como el `su -` real. Sin lanzadores en <repo>/bin (solo en <home>/bin) la comprobación rechaza ANTES de
    lanzar; con ellos en <repo>/bin autoriza y el agente arranca: resuelve en <repo> igual que el lanzamiento. El resto del PATH
    es un espejo del sistema SIN agentes, propio del mundo; la variante `_sistema_con_agentes` usa un sistema FALSO que SÍ
    lleva los agentes."""
    con_agentes = mode.endswith("_sistema_con_agentes")
    mode = mode.removesuffix("_sistema_con_agentes")
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        bindir = (world.cwd if mode == "j5_b_cwd_con_lanzadores_en_repo" else world.home) / "bin"
        bindir.mkdir()
        world.agents(where=bindir, text=AGENT_VIVO)
        world.launchers(where=bindir)
        espejo = world.sistema_con_agentes() if con_agentes else world.sistema_sin_agentes()
        shell = world.root / "shell-path-por-directorio"
        escribe_shell(world, shell, espejo, prefijo_pwd=True)
        tm = RealTmux(world)
        try:
            tm.start(str(shell))
            tm.session_sonda("1")
            world.env["FAKE_CWD"] = str(world.home)
            otros, antes = otros_panes(tm), orden_del_pane(tm)
            result = relanza(world)
            if mode == "j5_b_cwd_con_lanzadores_en_repo":
                assert result.returncode == 0, f"{mode}: el pane resuelve en <repo> y la comprobación lo rechaza: {result}"
                assert lanzado(antes, orden_del_pane(tm)) and str(bindir / "codex-root") in orden_del_pane(tm), \
                    f"{mode}: no se lanzó la ruta comprobada en <repo>: {orden_del_pane(tm)!r}"
            else:
                check_rechazo_previo(mode, result, tm, antes)
            assert otros_panes(tm) == otros and not tm.sonda_windows(), f"{mode}: se tocó otro pane o quedó una ventana"
        finally:
            tm.close()


def ventanas_por_identidad(tm):
    """Ventanas de la sesión v con SOLO lo que tmux nunca cambia por su cuenta: id, índice, `automatic-rename`, la opción
    `automatic-rename-format` y el nombre de las ventanas con automatic-rename APAGADO. El nombre de una ventana con
    automatic-rename activo (el valor por defecto) no entra: tmux lo cambia por su cuenta, en su propio temporizador y solo
    con actividad del pane, cuando cambia la orden del pane activo, y el relanzamiento la cambia (issue 9011, J8-05: la
    comparación por nombre salía en rojo o en verde según ese temporizador; y tmux puede no llegar a renombrar nunca). Con
    la misma conducta del paquete, el mismo resultado. Lo que hace el paquete sí se ve: una ventana creada, quitada o
    sustituida cambia la lista; un `rename-window` apaga automatic-rename o, si ya estaba apagado, cambia el nombre que se
    compara; cambiar automatic-rename o su formato cambia lo comparado."""
    fmt = "#{window_id}|#{window_index}|#{automatic-rename}|#{automatic-rename-format}|#{?automatic-rename,,#{window_name}}"
    result = tm("list-windows", "-t", "v:", "-F", fmt)
    assert result.returncode == 0 and result.stdout.strip(), f"no pude leer las ventanas de la sesión v: {result}"
    return result.stdout


def mode_j5_hook():
    """J4-02 (R9011j4), tmux REAL: un hook `after-new-window` de la sesión NO se dispara durante la comprobación y el
    lanzamiento, y la ventana activa NO cambia. Dos montajes. «una_ventana»: la sesión del canal solo tiene su ventana; el
    relanzamiento termina (rc 0). «con_auxiliar» (el montaje original de J4-02): la sesión ya tiene otra ventana; desde
    R9011j7 J7-01 el relanzamiento lee el `%N` de una sesión que ya existía y con más de una ventana falla cerrado ANTES de
    tocar nada (rc 1, nada lanzado, el mensaje dice las ventanas y el remedio). En los dos: ni hook, ni cambio de ventana
    (las ventanas se comparan con ventanas_por_identidad: sin el nombre que tmux cambia por su cuenta)."""
    for montaje in ("una_ventana", "con_auxiliar"):
        with tempfile.TemporaryDirectory() as tmp:
            world = World(tmp)
            world.agents(text=AGENT_VIVO)
            world.launchers()
            tm = RealTmux(world)
            try:
                tm.start()
                tm.session("v", panes=2)
                if montaje == "con_auxiliar":
                    assert tm("new-window", "-d", "-t", "v:", "-n", "auxiliar", "sleep 600").returncode == 0
                assert tm("select-window", "-t", "v:0").returncode == 0
                hook_file = world.root / "hook.log"
                hook = "run-shell " + shlex.quote("printf hook >> " + shlex.quote(str(hook_file))) + " ; select-window -t v:1"
                assert tm("set-hook", "-t", "v", "after-new-window", hook).returncode == 0
                # Issue 9011, J8-05: nada aquí espera a que tmux haga algo por su cuenta. El relanzamiento cambia la orden del
                # pane activo y tmux puede renombrar la ventana del canal antes, después o nunca: ventanas_por_identidad no
                # compara ese nombre, así que el veredicto no depende de su temporizador.
                ventanas = ventanas_por_identidad(tm)
                antes = orden_del_pane(tm)
                result = relanza(world)
                activa = tm("display-message", "-p", "-t", "v:", "#{window_index}").stdout.strip()
                text = result.stdout + result.stderr
                print(f"j5_hook {montaje}: rc={result.returncode}", flush=True)
                assert not hook_file.exists(), f"j5_hook {montaje}: se disparó after-new-window: {hook_file.read_text()!r}"
                assert activa == "0", f"j5_hook {montaje}: la ventana activa cambió a {activa}"
                assert ventanas_por_identidad(tm) == ventanas, \
                    f"j5_hook {montaje}: cambiaron las ventanas de la sesión: {ventanas!r} -> {ventanas_por_identidad(tm)!r}"
                if montaje == "una_ventana":
                    assert result.returncode == 0, f"j5_hook {montaje}: {result}"
                else:
                    assert result.returncode != 0 and "rol recargado" not in text, f"j5_hook {montaje}: no falla cerrado: {result}"
                    assert orden_del_pane(tm) == antes, f"j5_hook {montaje}: se tocó el pane: {antes!r} -> {orden_del_pane(tm)!r}"
                    assert "2 ventanas" in text and "cierra las ventanas" in text, f"j5_hook {montaje}: mensaje: {text}"
            finally:
                tm.close()


def mode_j5_identidad_acreditada():
    """La identidad posterior compara /proc/<pid>/exe con la ruta que ACREDITÓ la sonda del lanzamiento, por
    dispositivo:inodo, también desde OTRO proceso (el doctor, --soft): tras lanzar, se renombra el agente y se pone otro
    fichero en su ruta; el proceso del pane sigue siendo el acreditado. Control: un proceso de otro inodo NO se acredita."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        agent = world.remote / "codex"
        shutil.copyfile(shutil.which("python3"), agent)
        agent.chmod(0o755)
        write(world.remote / "codex-root", "#!/bin/bash\nexec codex -c 'import time; time.sleep(60)'\n")
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            result = relanza(world)
            assert result.returncode == 0, f"j5_identidad: el relanzamiento falló: {result}"
            pid = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
            world.env["FAKE_PID_1"] = pid
            agent.rename(world.remote / "codex.anterior")
            shutil.copyfile(shutil.which("python3"), agent)
            agent.chmod(0o755)
            lectura = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.1 codex-root\nexit $?\n')
            assert lectura.returncode == 0 and first_line(lectura.stdout) == "codex", \
                f"j5_identidad: el proceso acreditado por la sonda no se acredita: {lectura}"
            # Control: el pane relanzado a mano con OTRO fichero (otro inodo) no es el acreditado.
            tm("respawn-pane", "-k", "-t", "v:.1", f"{agent} -c 'import time; time.sleep(60)'")
            time.sleep(0.3)
            world.env["FAKE_PID_1"] = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
            lectura = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.1 codex-root\nexit $?\n')
            assert first_line(lectura.stdout) != "codex", f"j5_identidad: se acredita un ejecutable de otro inodo: {lectura}"
        finally:
            tm.close()


def mode_j5_identidad_acreditada_execve():
    """Codex de npm: el lanzador hace `exec codex` y `codex` es el enlace al `bin/codex.js` del paquete `@openai/codex`, que
    hace execve al binario NATIVO. La sonda del relanzamiento acredita codex.js (E:/I: sin cambiar su forma) y el proceso del
    pane acaba siendo el nativo: el relanzamiento REAL (`tco_codex_relaunch_and_role`, que incluye la identidad tras lanzar)
    sale con rc 0, y también la lectura desde OTRO proceso (el doctor, --soft) acredita al pane por el nativo que deriva de
    la ruta acreditada. Control: un proceso de otro inodo, ni codex.js ni el nativo del paquete, NO se acredita."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        write(world.remote / "uname", "#!/bin/bash\necho x86_64\n")
        raiz = world.root / "npm/lib/node_modules/@openai/codex"
        nativo = raiz / "node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
        nativo.parent.mkdir(parents=True)
        (raiz / "bin").mkdir(parents=True)
        shutil.copyfile(shutil.which("python3"), nativo)
        nativo.chmod(0o755)
        (raiz / "package.json").write_text('{\n  "name": "@openai/codex",\n  "version": "0.166.0"\n}\n')
        write(raiz / "bin/codex.js", "#!/usr/bin/env node\n// fixture\n")
        (world.remote / "codex").symlink_to(raiz / "bin/codex.js")
        # `node` doblado: simula `process.execve(nativo, [nativo, ...args])` de codex.js (el proceso pasa a ser el nativo).
        write(world.remote / "node", f'#!/bin/bash\nshift\nexec {shlex.quote(str(nativo))} "$@"\n')
        write(world.remote / "codex-root", "#!/bin/bash\nexec codex -c 'import time; time.sleep(60)'\n")
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            result = relanza(world)
            assert result.returncode == 0, f"j5_identidad_execve: el relanzamiento con execve no se acredita: {result}"
            pid = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
            world.env["FAKE_PID_1"] = pid
            lectura = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.1 codex-root\nexit $?\n')
            assert lectura.returncode == 0 and first_line(lectura.stdout) == "codex", \
                f"j5_identidad_execve: el nativo tras execve no se acredita desde otro proceso: {lectura}"
            # Control: otro fichero (otro inodo, fuera del paquete) en el pane no es el acreditado.
            otro = world.root / "otro/codex"
            otro.parent.mkdir()
            shutil.copyfile(shutil.which("python3"), otro)
            otro.chmod(0o755)
            tm("respawn-pane", "-k", "-t", "v:.1", f"{otro} -c 'import time; time.sleep(60)'")
            time.sleep(0.3)
            world.env["FAKE_PID_1"] = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
            lectura = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.1 codex-root\nexit $?\n')
            assert first_line(lectura.stdout) != "codex", f"j5_identidad_execve: se acredita un binario ajeno: {lectura}"
        finally:
            tm.close()


def mode_j5_binario(mode):
    """El binario cambia ENTRE la sonda y el lanzamiento (bloque real de dispatch.sh): el lanzamiento real no ejecuta otra
    ruta que la comprobada. Symlink: tras la sonda, `claude-root` pasa a apuntar a otro lanzador (v2); se lanza la ruta
    comprobada (v1) y v2 no corre nunca. Renombrado: tras la sonda, el lanzador comprobado se renombra y queda otro
    `claude-root` más adelante en el PATH; no se lanza el otro: la ruta comprobada falta y el pane muere (fallo cerrado)."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        world.launchers(only=("codex-root",))
        log = world.state / "corrio.log"
        if mode == "j5_binario_symlink":
            for version in ("v1", "v2"):
                (world.root / version).mkdir()
            world.launchers(where=world.root / "v1", only=("claude-root",))
            write(world.root / "v2" / "claude-root", f'#!/bin/bash\necho v2 >> "{log}"\nexit 0\n')
            (world.remote / "claude-root").symlink_to(world.root / "v1" / "claude-root")
            cambio = f'ln -sfn {shlex.quote(str(world.root / "v2" / "claude-root"))} {shlex.quote(str(world.remote / "claude-root"))}'
            env = {}
        else:
            world.launchers(only=("claude-root",))
            write(world.extra / "claude-root", f'#!/bin/bash\necho otro >> "{log}"\nexec claude "$@"\n')
            cambio = (f'mv {shlex.quote(str(world.remote / "claude-root"))} '
                      f'{shlex.quote(str(world.remote / "claude-root.renombrado"))}')
            env = {"FAKE_SHELL_PATH": f"{world.remote}:{world.extra}"}
        # El cambio se hace justo DESPUÉS de la comprobación previa y ANTES del lanzamiento real.
        envoltorio = ('eval "_tco_lr_orig() $(declare -f tco_launchers_ready | tail -n +2)"\n'
                      f'tco_launchers_ready() {{ _tco_lr_orig "$@" || return; {cambio}; }}\n')
        result = world.run(PRELUDE + envoltorio + dispatch_block() + "echo BLOQUE-OK\n",
                           dict({"TCO_DEV_CLI": "claude-root", "TCO_AUDIT_CLI": "codex-root"}, **env))
        text = result.stdout + result.stderr
        corrio = log.read_text() if log.exists() else ""
        assert corrio == "", f"{mode}: se lanzó OTRA ruta que la comprobada ({corrio.strip()}): {world.tmux_log()}"
        assert "can't find pane" not in text, f"{mode}: {text}"
        # El pane dev se lanza por su id estable (`%0` en el doble) o, en la base, por `v:.0`.
        lanz = [line for line in lanzamientos(world) if "v:.0" in line or " %0 " in line]
        if mode == "j5_binario_symlink":
            assert result.returncode == 0 and "BLOQUE-OK" in result.stdout, f"{mode}: {result}"
            assert len(lanz) == 1 and str(world.root / "v1" / "claude-root") in lanz[0], \
                f"{mode}: no se lanzó la ruta comprobada: {lanz}"
        else:
            assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: {result}"
            assert "RESPAWN 0 rc=127" in world.tmux_log() and "127" in text, f"{mode}: {world.tmux_log()} {text}"
        marcadores = list((world.home / ".local/state/talent-channel-operation/sonda").glob("sonda.*")) \
            if (world.home / ".local/state").exists() else []
        assert not marcadores, f"{mode}: el marcador de la sonda no se borró tras leerlo: {marcadores}"


def mode_j5_marcador(mode):
    """Marcador de la sonda (bloque real de dispatch.sh): ausente, nonce distinto, ruta relativa, ruta inexistente o
    permisos distintos de 0600 → fallo cerrado ANTES de lanzar, con un mensaje claro, y el marcador no queda."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents()
        world.launchers()
        fallo = mode.split("_", 2)[2]
        result = world.run(PRELUDE + dispatch_block() + "echo BLOQUE-OK\n",
                           {"TCO_DEV_CLI": "claude-root", "TCO_AUDIT_CLI": "codex-root", "FAKE_SONDA": fallo})
        text = result.stdout + result.stderr
        assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, f"{mode}: autoriza: {result}"
        check_no_h2(result, world)
        wanted = {"sin_marcador": "marcador", "nonce_distinto": "nonce", "ruta_relativa": "no es absoluta",
                  "ruta_inexistente": "no existe", "permisos": "permisos"}[fallo]
        assert wanted in text and "claude-root" in text, f"{mode}: mensaje poco claro (esperaba «{wanted}»): {text}"
        estado = world.home / ".local/state/talent-channel-operation/sonda"
        assert not (estado.exists() and list(estado.glob("sonda.*"))), f"{mode}: el marcador no se borró"


def mode_h02(mode):
    """H-02 (R9011j3): dos ENLACES DUROS reales al mismo fichero (rutas distintas, mismo dispositivo:inodo) no son dos
    proveedores; la identidad emite el dispositivo:inodo de la ruta real esperada."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        procs = []
        try:
            claude = world.remote / "claude"
            shutil.copyfile(shutil.which("python3"), claude)
            claude.chmod(0o755)
            sleeper = ["-c", "import time; time.sleep(60)"]
            if mode == "identidad_emite_inodo":
                procs.append(subprocess.Popen([str(claude), *sleeper], env=world.env, start_new_session=True))
                world.env["FAKE_PID_0"] = str(procs[0].pid)
                result = world.run(PRELUDE + '_tco_pane_agent_exes 01 v:.0 claude\nexit $?\n')
                info = claude.stat()
                assert result.returncode == 0 and first_line(result.stdout) == "claude", f"{mode}: {result}"
                assert f"ino={info.st_dev}:{info.st_ino}" in result.stdout.splitlines(), f"{mode}: {result}"
                return
            assert mode == "identidad_h02_enlaces_duros"
            os.link(claude, world.remote / "codex")
            stats = [(world.remote / agent).stat() for agent in ("claude", "codex")]
            assert (stats[0].st_dev, stats[0].st_ino) == (stats[1].st_dev, stats[1].st_ino), "precondición: enlace duro"
            for index, agent in enumerate(("claude", "codex")):
                procs.append(subprocess.Popen([str(world.remote / agent), *sleeper], env=world.env, start_new_session=True))
                world.env[f"FAKE_PID_{index}"] = str(procs[-1].pid)
            code = (PRELUDE + 'TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex; TCO_AUDIT_TOPOLOGY=distinto\n'
                    'tco_pane_identity_preflight 01\nexit $?\n')
            result = world.run(code)
            assert result.returncode != 0 and "AUDITOR:" not in result.stdout, \
                f"{mode}: dos enlaces duros al mismo fichero pasan como 'distinto': {result}"
            assert "MISMO ejecutable real" in result.stderr, f"{mode}: {result}"
            # Control: una COPIA (otro inodo) sí es otro ejecutable real.
            for proc in procs:
                proc.kill()
                proc.wait()
            procs = []
            (world.remote / "codex").unlink()
            shutil.copyfile(claude, world.remote / "codex")
            (world.remote / "codex").chmod(0o755)
            for index, agent in enumerate(("claude", "codex")):
                procs.append(subprocess.Popen([str(world.remote / agent), *sleeper], env=world.env, start_new_session=True))
                world.env[f"FAKE_PID_{index}"] = str(procs[-1].pid)
            result = world.run(code)
            assert result.returncode == 0 and "AUDITOR: codex " in result.stdout, f"{mode} (control copia): {result}"
        finally:
            for proc in procs:
                proc.kill()
                proc.wait()


# El sondeo del rol (`sleep 5`) se salta; las esperas cortas (vida, identidad tras lanzar) son reales. El agente «responde»
# el ACK solo DESPUÉS del relay de ESE relanzamiento (antes del relay no hay ACK que leer).
RELANZAMIENTO_STUBS = ('sleep() { [ "$1" = 5 ] || command sleep "$@"; }; '
                       'tco_wait_tui_ready() { rm -f "$FAKE_STATE/relay.hecho"; return 0; }; '
                       "tco_codex_skip_update_and_trust() { return 0; }\n"
                       'tco_relay_file() { : > "$FAKE_STATE/relay.hecho"; return 0; }; tco_cap_pane() { return 0; }; '
                       'tco_role_ack() { [ -e "$FAKE_STATE/relay.hecho" ]; }\n')


def mode_vida_remain_local():
    """H-03 (R9011j3), tmux REAL: con el global `remain-on-exit off`, la comprobación de vida del relanzamiento deja la
    opción de la ventana EXACTAMENTE como estaba: `on` local sigue `on`, `off` local sigue `off` y sin valor local queda sin
    valor local. La base la borraba siempre con `-wu`."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        tm = RealTmux(world)
        try:
            tm.start()
            assert tm("set-option", "-g", "remain-on-exit", "off").returncode == 0
            for local in ("on", None, "off"):
                tm("kill-session", "-t", "v")
                tm.session("v", panes=2)
                if local:
                    assert tm("set-option", "-w", "-t", "v:", "remain-on-exit", local).returncode == 0
                result = world.run(PRELUDE + RELANZAMIENTO_STUBS + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                                   {"TCO_AUDIT_CLI": "codex-root"})
                after = tm("show-options", "-w", "-t", "v:", "remain-on-exit").stdout.strip()
                wanted = f"remain-on-exit {local}" if local else ""
                assert result.returncode == 0, f"local={local}: el relanzamiento falló: {result}"
                assert after == wanted, f"local={local}: quedó [{after}] y debía quedar [{wanted}]"
                assert tm("show-options", "-g", "remain-on-exit").stdout.strip() == "remain-on-exit off"
                assert not tm.sonda_windows(), tm.sonda_windows()
        finally:
            tm.close()


# Doble de incus para la vida tras lanzar (H-03 y H-04): `list-panes` responde con el formato pedido; el pane 1 sigue la
# secuencia de FAKE_STATE/estados (una línea por lectura, `muerto|rc|señal`; la última se repite).
VIDA_DOBLE = r'''
# La comprobación previa se da por superada y deja la ruta acreditada que lanzaría el pane.
tco_launchers_ready() {
  declare -gA _TCO_ACREDITADO _TCO_LANZADOR 2>/dev/null
  local p
  for p in '%1' 'v:.1'; do _TCO_ACREDITADO[$p]='codex|/fx/codex|1:2'; _TCO_LANZADOR[$p]='/fx/codex-root'; done
  return 0
}
incus() {
  local cmd="${*: -1}" fmt n st d s g l idx v
  printf '%s\n' "$cmd" >> "$FAKE_STATE/vida.log"
  case "$cmd" in
    *display-message*) printf '%%1\n' ;;
    *'#{session_name}'*)
      # La lectura de los `%N` de la sesión (una ventana, dos panes, una vida): no cuenta como lectura del estado de vida.
      printf 'v|@0|0|%%0|4242.1700000000\nv|@0|1|%%1|4242.1700000000\n' ;;
    *list-panes*)
      fmt="${cmd#*-F \'}"; fmt="${fmt%%\'*}"
      n=0; [ ! -f "$FAKE_STATE/lecturas" ] || read -r n < "$FAKE_STATE/lecturas"
      n=$((n + 1)); printf '%s\n' "$n" > "$FAKE_STATE/lecturas"
      st="$(sed -n "${n}p" "$FAKE_STATE/estados")"; [ -n "$st" ] || st="$(tail -n 1 "$FAKE_STATE/estados")"
      for idx in 0 1; do
        d=0; s=''; g=''
        [ "$idx" = 0 ] || IFS='|' read -r d s g <<< "$st"
        l="${fmt//'#{pane_index}'/$idx}"; l="${l//'#{pane_dead_status}'/$s}"; l="${l//'#{pane_dead_signal}'/$g}"
        l="${l//'#{pane_dead}'/$d}"; l="${l//'#{pane_id}'/%$idx}"
        printf '%s\n' "$l"
      done ;;
    *show-options*) [ ! -f "$FAKE_STATE/remain" ] || cat "$FAKE_STATE/remain" ;;
    *'set-option -wu'*) [ -z "${FAKE_RESTAURA_FALLA:-}" ] || return 1; rm -f "$FAKE_STATE/remain" ;;
    *'remain-on-exit '*) v="${cmd#*remain-on-exit }"; v="${v%%[[:space:]]*}"; printf '%s\n' "$v" > "$FAKE_STATE/remain" ;;
  esac
  return 0
}
'''


def mode_vida(mode):
    """H-04 (R9011j3): pane muerto con `pane_dead_status` vacío. Relectura corta y acotada: si llega el rc se informa; si no,
    «estado de salida aún no disponible» (nunca «rc desconocido»); la señal se conserva. H-03: un fallo al restaurar
    `remain-on-exit` se dice, no se ignora."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        states = {"vida_estado_tardio": "1||\n1|127|\n", "vida_estado_nunca": "1||\n", "vida_senal": "1||9\n",
                  "vida_restauracion_falla": "0||\n"}[mode]
        (world.state / "estados").write_text(states)
        extra = {"FAKE_RESTAURA_FALLA": "1"} if mode == "vida_restauracion_falla" else {}
        result = world.run(PRELUDE + RELANZAMIENTO_STUBS + VIDA_DOBLE + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                           dict({"TCO_AUDIT_CLI": "codex-root"}, **extra))
        text = result.stdout + result.stderr
        reads = int((world.state / "lecturas").read_text()) if (world.state / "lecturas").exists() else 0
        assert result.returncode != 0, f"{mode}: {result}"
        assert "desconocido" not in text and "can't find pane" not in text, f"{mode}: {text}"
        if mode == "vida_restauracion_falla":
            assert "restaurar remain-on-exit" in text, f"{mode}: el fallo de restauración no se dice: {text}"
            return
        # El pane se nombra por su id estable (`%1`, el de v:.1), leído una vez al principio del relanzamiento.
        assert "codex-root" in text and ("%1" in text or "v:.1" in text) and "TCO_AUDIT_FLAGS" in text, \
            f"{mode}: sin CLI/pane/remedio: {text}"
        if mode == "vida_estado_tardio":
            assert "rc 127" in text, f"{mode}: {text}"
        elif mode == "vida_estado_nunca":
            assert "estado de salida aún no disponible" in text and "capture-pane" in text, f"{mode}: {text}"
            assert 2 <= reads <= 7, f"{mode}: relecturas no acotadas: {reads}"
        else:
            assert "señal 9" in text, f"{mode}: {text}"


ESTADO_SONDA = Path(".local/state/talent-channel-operation/sonda")


def marcadores(world):
    estado = world.home / ESTADO_SONDA
    return sorted(p.name for p in estado.iterdir()) if estado.exists() else []


def procesos_con(textos):
    """Procesos vivos (no zombis) cuyo cmdline contiene alguno de los textos: los de la sonda colgada de la prueba."""
    vivos = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            cmd = (Path("/proc") / entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            stat = (Path("/proc") / entry / "stat").read_text()
        except OSError:
            continue
        campos = stat.rsplit(")", 1)[-1].split()
        if campos[0] in ("Z", "X"):
            continue
        if any(t in cmd for t in textos):
            vivos.append((entry, campos[1], cmd))
    return vivos


def mode_j6_cuelgue(mode):
    """Condición 1 (R9011j5, cuelgue), tmux REAL y relanzamiento real sobre v:.1. «nunca»: la shell del pane no ejecuta jamás
    la orden de la sonda (exec sleep 300). «tarde»: la ejecuta a los 12 s, después del tope de 10 s. En ambos: el relanzamiento
    falla cerrado con el fallo escrito (FALLO:tope), el árbol de la sonda queda cortado (el pane muerto, ningún proceso suyo
    vivo) y no queda NINGÚN marcador, tampoco cuando la sonda «habría» terminado tarde. Ningún otro pane se toca."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        shell = world.root / "shell-lenta"
        if mode == "j6_cuelgue_nunca":
            write(shell, "#!/bin/bash\nexec sleep 301\n")
            firmas = ("sleep 301",)
        else:
            write(shell, '#!/bin/bash\nsleep 12\nexec /bin/bash "$@"\n')
            firmas = ("sleep 12", str(shell))
        tm = RealTmux(world)
        try:
            tm.start(str(shell))
            tm.session("v", panes=2)
            otros = otros_panes(tm)
            start = time.monotonic()
            result = relanza(world)
            elapsed = time.monotonic() - start
            text = result.stdout + result.stderr
            assert result.returncode != 0, f"{mode}: una sonda sin respuesta no puede autorizar: {result}"
            assert elapsed < 30, f"{mode}: la sonda no respetó su tope: {elapsed:.1f} s"
            assert "tope" in text and "FALLO:tope" in text, f"{mode}: el fallo del tope no quedó escrito y leído: {text}"
            if mode == "j6_cuelgue_tarde":
                # La sonda «tardía» habría escrito su marcador a los 12 s: se espera a que ese momento pase.
                time.sleep(max(0.0, 16.0 - (time.monotonic() - start)))
            estado = tm("list-panes", "-t", "v:", "-F", "#{pane_index}|#{pane_dead}").stdout
            assert "1|1" in estado.splitlines(), f"{mode}: el proceso de la sonda sigue vivo en el pane de destino: {estado!r}"
            # Los otros panes corren con la misma shell lenta: sus procesos (y sus hijos) no son de la sonda.
            destino = tm("display-message", "-p", "-t", "v:.1", "#{pane_id}").stdout.strip()
            ajenos = {pid for pid_id, pid in (l.split() for l in tm("list-panes", "-a", "-F", "#{pane_id} #{pane_pid}")
                                                                   .stdout.splitlines()) if pid_id != destino}
            vivos = [v for v in procesos_con(firmas) if v[0] not in ajenos and v[1] not in ajenos]
            assert not vivos, f"{mode}: quedan procesos del árbol de la sonda: {vivos}"
            assert not marcadores(world), f"{mode}: queda un marcador huérfano: {marcadores(world)}"
            assert otros_panes(tm) == otros, f"{mode}: se tocó otro pane: {otros} -> {otros_panes(tm)}"
        finally:
            tm.close()


def mode_j6_pane_died_hook():
    """Condición 2 / J5-01 (R9011j5), tmux REAL, 8 corridas: sesión v con la ventana 0 (dos panes) y un hook global
    `pane-died` que selecciona la ventana 1. La muerte del pane de la sonda dispara el hook. Vueltas 0-6: la ventana 1 (dos
    panes ajenos con `sleep 600`) la abre el propio hook al dispararse, DESPUÉS de leer el `%N`; el relanzamiento real sobre
    v:.1 debe lanzar SIEMPRE en el pane comprobado (0.1), y ningún pane ajeno muere ni cambia su remain-on-exit. Tras leer el
    `%N` todo va a ESE `%N` (R9011j6 J6-01): rc 0 con el rol recargado en ese pane. Vuelta 7, el montaje original (la ventana
    1 ya existe al empezar): desde R9011j7 J7-01 el relanzamiento lee el `%N` de una sesión que ya existía y, con más de una
    ventana, falla cerrado ANTES de tocar nada (rc 1, ningún pane cambia, nada lanzado)."""
    fmt = "#{window_index}.#{pane_index}|#{pane_id}|#{pane_pid}|#{pane_start_command}"
    disparos = 0
    for vuelta in range(8):
        previa = vuelta == 7
        with tempfile.TemporaryDirectory() as tmp:
            world = World(tmp)
            world.agents(text=AGENT_VIVO)
            world.launchers()
            tm = RealTmux(world)
            try:
                tm.start()
                tm.session("v", panes=2)
                hook_file = world.root / "hook.log"
                aviso = "run-shell " + shlex.quote("printf died >> " + shlex.quote(str(hook_file)))
                if previa:
                    assert tm("new-window", "-d", "-t", "v:", "-n", "otra", "sleep 600").returncode == 0
                    assert tm("split-window", "-d", "-t", "v:1", "sleep 600").returncode == 0
                    assert tm("select-window", "-t", "v:0").returncode == 0
                    hook = aviso + " ; select-window -t v:1"
                else:
                    hook = ("new-window -d -t v: -n otra 'sleep 600' ; split-window -d -t v:1 'sleep 600' ; "
                            + aviso + " ; select-window -t v:1")
                assert tm("set-hook", "-g", "pane-died", hook).returncode == 0
                antes = {l.split("|")[0]: l.split("|", 3) for l in tm("list-panes", "-s", "-t", "v:", "-F", fmt).stdout.splitlines()}
                remain_ajena = tm("show-options", "-w", "-t", "v:1", "remain-on-exit").stdout if previa else None
                result = relanza(world)
                time.sleep(0.5)
                despues = {l.split("|")[0]: l.split("|", 3) for l in tm("list-panes", "-s", "-t", "v:", "-F", fmt).stdout.splitlines()}
                text = result.stdout + result.stderr
                lanzado = [k for k, v in despues.items() if "codex-root" in v[3] and SONDA_FIRMA not in v[3]]
                print(f"j6_hook vuelta {vuelta}: previa={previa} rc={result.returncode} "
                      f"hook={'sí' if hook_file.exists() else 'no'} lanzado_en={lanzado}", flush=True)
                if previa:
                    assert result.returncode != 0 and "rol recargado" not in text, f"j6_hook previa: no falla cerrado: {result}"
                    assert lanzado == [] and despues == antes, f"j6_hook previa: se tocó algún pane: {antes} -> {despues}"
                    assert tm("show-options", "-w", "-t", "v:1", "remain-on-exit").stdout == remain_ajena, \
                        "j6_hook previa: se cambió remain-on-exit de la ventana ajena"
                    assert "2 ventanas" in text and "cierra las ventanas" in text, f"j6_hook previa: mensaje: {text}"
                    continue
                assert lanzado == ["0.1"], f"j6_hook vuelta {vuelta}: se lanzó en {lanzado} (rc={result.returncode}): {despues} {text}"
                assert despues["0.0"][2] == antes["0.0"][2], f"j6_hook vuelta {vuelta}: murió el pane ajeno 0.0"
                if hook_file.exists():
                    ajenos = [k for k in despues if k.startswith("1.")]
                    assert sorted(ajenos) == ["1.0", "1.1"] and all("sleep 600" in despues[k][3] for k in ajenos), \
                        f"j6_hook vuelta {vuelta}: se tocó un pane de la ventana ajena: {despues}"
                assert result.returncode == 0 and "rol recargado" in text, f"j6_hook vuelta {vuelta}: {result}"
                disparos += hook_file.exists()
            finally:
                tm.close()
    assert disparos >= 1, "j6_hook: el hook pane-died no se disparó en ninguna corrida (el caso no se ejercitó)"
    print(f"j6_hook: 7 de 7 en el pane correcto (hook disparado en {disparos} de 7) y la ventana previa falla cerrada")


def mode_j6_mensajes():
    """Condición 3 / J5-03 (R9011j5): para cada rc de la sonda (2: el lanzador no resuelve; 3: el pane desaparece mientras
    corre; 4: marcador con otro nonce), el error dice en UNA línea que el proceso anterior del pane murió, que remain-on-exit
    sigue en on y el remedio («relanza con …» o «restaura con …»)."""
    for caso, env, con_lanzadores in (("rc2", {}, False), ("rc3", {"FAKE_SONDA": "pane_ausente"}, True),
                                      ("rc4", {"FAKE_SONDA": "nonce_distinto"}, True)):
        with tempfile.TemporaryDirectory() as tmp:
            world = World(tmp)
            world.agents()
            if con_lanzadores:
                world.launchers()
            result = world.run(PRELUDE + RELANZAMIENTO_STUBS + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               dict({"TCO_AUDIT_CLI": "codex-root"}, **env))
            text = result.stdout + result.stderr
            assert result.returncode != 0, f"j6_mensajes {caso}: {result}"
            lineas = [l for l in text.splitlines() if "murió" in l.lower() and "remain-on-exit" in l and " on" in l
                      and ("relanza con" in l or "restaura con" in l)]
            assert lineas, f"j6_mensajes {caso}: ninguna línea dice muerte + remain-on-exit on + remedio: {text}"
            print(f"j6_mensajes {caso}: {lineas[0]}", flush=True)


def audit_block_identidad():
    """Bloque REAL de audit-carril.sh hasta la identidad tras lanzar (o, si no existe, hasta la vida)."""
    return bloque_sin_tokens("audit_block_identidad", block_between(
        OP / "audit-carril.sh", '  sess_res="$(incus exec',
        ["no es el agente acreditado por la sonda", "murió o no existe tras lanzarlo"]))


def mode_j6_identidad_lanzada(mode):
    """Condición 4 / J5-04 (R9011j5), tmux REAL: un lanzador cuyo `exec codex` resuelve por PATH a OTRO binario (antepone
    otro directorio al PATH). El relanzamiento real de lib.sh y el bloque real de audit-carril.sh deben fallar cerrados por la
    identidad tras lanzar. Control: el mismo lanzador sin cambiar el PATH pasa."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        for d in (world.remote, world.extra):
            shutil.copyfile(shutil.which("python3"), d / "codex")
            (d / "codex").chmod(0o755)
        vida = "IS_SANDBOX=1 exec codex -c 'import time; time.sleep(60)'\n"
        world.env["TCO_LANZADO_IDENT_WAIT"] = "4"
        tm = RealTmux(world)
        try:
            tm.start()
            for impostor in (False, True):
                cabecera = f'export PATH="{world.extra}:$PATH"\n' if impostor else ""
                write(world.remote / "codex-root", "#!/bin/bash\n" + cabecera + vida)
                tm("kill-session", "-t", "v")
                tm.session("v", panes=2)
                if mode == "j6_identidad_relanzamiento":
                    result = relanza(world)
                else:
                    result = world.run(PRELUDE + audit_block_identidad() + "echo BLOQUE-OK\n", {"TCO_AUDIT_CLI": "codex-root"})
                text = result.stdout + result.stderr
                print(f"{mode} impostor={impostor}: rc={result.returncode}", flush=True)
                if impostor:
                    assert result.returncode != 0 and "BLOQUE-OK" not in result.stdout, \
                        f"{mode}: el lanzador ejecutó OTRO agente y se dio por lanzado: {result}"
                    assert "identidad" in text and "codex-root" in text, f"{mode}: el error no nombra la identidad: {text}"
                else:
                    assert result.returncode == 0, f"{mode} (control): el agente acreditado no pasa la identidad: {result}"
        finally:
            tm.close()


def mode_j6_acreditacion_forjada():
    """Condición 5 / J5-02 (R9011j5), tmux REAL: el proceso del propio pane escribe la opción de tmux `@tco-acreditado` con
    SU ruta y su dispositivo:inodo y hace exec de un impostor. Ni la identidad desde otro proceso (la que usan --soft y el
    preflight) ni el lector del doctor (talent-ceo/leer-auditor.sh) lo acreditan: en un pane acreditado antes por la sonda
    (la acreditación es la del fichero del despacho) y en un pane que ninguna sonda acreditó (solo lectura). Control: el
    agente acreditado por la sonda sí lo acredita el doctor."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        agent = world.remote / "codex"
        shutil.copyfile(shutil.which("python3"), agent)
        agent.chmod(0o755)
        write(world.remote / "codex-root", "#!/bin/bash\nexec codex -c 'import time; time.sleep(60)'\n")
        imp = world.root / "impostor"
        shutil.copyfile(shutil.which("python3"), imp)
        imp.chmod(0o755)
        st = os.stat(imp)
        doctor = SKILLS / "talent-ceo" / "scripts" / "leer-auditor.sh"
        tm = RealTmux(world)

        def lee(pane, index):
            world.env[f"FAKE_PID_{index}"] = tm("display-message", "-p", "-t", pane, "#{pane_pid}").stdout.strip()
            soft = world.run(PRELUDE + f"_tco_pane_agent_exes 01 {pane} codex-root\nexit $?\n")
            doc = world.run(f"bash {shlex.quote(str(doctor))} fixture {pane} fixture codex-root\nexit $?\n")
            return first_line(soft.stdout), first_line(doc.stdout), soft, doc

        try:
            tm.start()
            tm.session("v", panes=2)
            assert relanza(world).returncode == 0, "precondición: el relanzamiento legítimo"
            soft, doc, r1, r2 = lee("v:.1", 1)
            assert soft == "codex" and doc == "codex", f"control: el agente acreditado no se acredita: {r1} {r2}"
            orden = ("tmux set-option -p -t \"$TMUX_PANE\" @tco-acreditado "
                     + shlex.quote(f"codex|{imp}|{st.st_dev}:{st.st_ino}")
                     + " ; exec " + shlex.quote(str(imp)) + " -c 'import time; time.sleep(60)'")
            for pane, index in (("v:.1", 1), ("v:.0", 0)):
                assert tm("respawn-pane", "-k", "-t", pane, orden).returncode == 0
                time.sleep(0.8)
                forjada = tm("show-options", "-p", "-v", "-t", pane, "@tco-acreditado").stdout.strip()
                assert str(imp) in forjada, f"precondición: el pane {pane} no forjó la opción: {forjada!r}"
                soft, doc, r1, r2 = lee(pane, index)
                print(f"j6_forja {pane}: soft={soft!r} doctor={doc!r}", flush=True)
                assert soft != "codex", f"j6_forja {pane}: --soft/preflight acredita al impostor: {r1}"
                assert doc != "codex", f"j6_forja {pane}: el doctor acredita al impostor: {r2}"
        finally:
            tm.close()


def mode_j6_destinos_estaticos():
    """Condiciones 2 y 5, estático: en dispatch.sh, audit-carril.sh y lib.sh cada `respawn-pane` (sonda y lanzamiento) apunta
    al id estable leído una vez (`$P_DEV`, `$P_AUD` o `$pane`), nunca a `$(tco_pane_dev)`/`$(tco_pane_audit)`; ese id se lee
    (tco_pane_id_fijar) antes de remain-on-exit y de la sonda; y ninguna línea de código escribe ni lee `@tco-acreditado`."""
    for name in ("dispatch.sh", "audit-carril.sh", "lib.sh"):
        lines = (OP / name).read_text().splitlines()
        code = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
        respawns = [(i, l) for i, l in code if "tmux respawn-pane -k" in l]
        assert respawns, f"{name}: sin respawn-pane"
        for i, line in respawns:
            assert any(f"-t '{v}'" in line for v in ("$P_DEV", "$P_AUD", "$pane")), \
                f"{name}:{i + 1}: respawn-pane sin el id estable: {line.strip()}"
            assert "$(tco_pane_" not in line, f"{name}:{i + 1}: destino relativo en respawn-pane: {line.strip()}"
        assert not [l for _, l in code if "@tco-acreditado" in l], f"{name}: se escribe o se lee @tco-acreditado"
        if name != "lib.sh":
            fija = min((i for i, l in code if l.lstrip().startswith("tco_pane_id_fijar ")), default=None)
            remain = min((i for i, l in code if l.lstrip().startswith("tco_remain_preparar ")), default=None)
            assert fija is not None and remain is not None and fija < remain, f"{name}: el id estable no se lee antes"
    body = bloque_sin_tokens("relanzamiento_lib", block_between(OP / "lib.sh", "tco_codex_relaunch_and_role() {",
                                                                "codex relanzado + update-skip"))
    # La lectura del id estable de una sesión que ya existía es tco_panes_fijar_sesion (R9011j7 J7-01).
    assert "tco_panes_fijar_sesion" in body and "tco_pane_id_fijar" not in body, \
        "lib.sh: el relanzamiento no lee el id estable con tco_panes_fijar_sesion (sesión que ya existía)"
    assert body.index("tco_panes_fijar_sesion") < body.index("tco_remain_preparar") < body.index("tco_launchers_ready"), \
        "lib.sh: el relanzamiento no lee el id estable antes de remain-on-exit y de la sonda"
    assert "tco_pane_identidad_lanzada" in body, "lib.sh: el relanzamiento no comprueba la identidad tras lanzar"
    audit = (OP / "audit-carril.sh").read_text()
    assert "tco_pane_identidad_lanzada" in audit, "audit-carril.sh: la auditoría no comprueba la identidad tras lanzar"


# ------------------------------------------------------------------------------------------------------------------------
# j7 (R9011j6): tras leer el `%N`, UN ÚNICO destino; el éxito del relanzamiento lo da SOLO lo observado en ESE `%N`.

# Sondas N8 de R9011j6, TAL CUAL (`STUBS_N8` del acta): solo se sustituyen la espera del TUI (3 s, que modela su sondeo real
# de hasta 90 s), el salto de update y el relay; los tres registran el destino que reciben y a qué pane resuelve en ese
# instante. El relay de N8 falla (rc 2).
J7_STUBS_N8 = ('sleep() { [ "$1" = 5 ] || command sleep "$@"; }\n'
               'resuelto() { incus exec fixture -- su - fixture -c "tmux display-message -p -t \'$1\' \'#{pane_id}\'"; }\n'
               'tco_wait_tui_ready() { printf "tui %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; '
               ': > "$FAKE_STATE/tui"; command sleep 3; return 0; }\n'
               'tco_codex_skip_update_and_trust() { printf "skip %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; '
               'return 0; }\n'
               'tco_relay_file() { printf "relay %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; return 2; }\n')
# La captura del ACK (tco_cap_pane) y el ACK (tco_role_ack) son los REALES: este envoltorio solo registra el destino de
# cada captura y a qué pane resuelve, y delega en la real.
J7_CAP_LOG = ('eval "_tco_cap_real() $(declare -f tco_cap_pane | tail -n +2)"\n'
              'tco_cap_pane() { printf "cap %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; '
              '_tco_cap_real "$@"; }\n')
# Relay que ENTREGA: escribe en el pane al que va la respuesta del agente (la línea ROL-AUDITORIA-LISTO). Con él el
# relanzamiento termina bien, y debe hacerlo en el pane lanzado.
J7_RELAY_OK = ('tco_relay_file() { printf "relay %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; '
               'incus exec fixture -- su - fixture -c "tmux send-keys -t \'$2\' -l ROL-AUDITORIA-LISTO '
               '&& tmux send-keys -t \'$2\' Enter"; command sleep 0.5; return 0; }\n')
# Relay que solo registra (no teclea nada): la negativa del `%N` muerto cuenta sus invocaciones.
J7_RELAY_REGISTRA = ('tco_relay_file() { printf "relay %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/relay.log"; '
                     'return 0; }\n')
# Relay que teclea en el pane EXACTAMENTE lo que teclea el relay real (`lee <ruta> <mensaje>` + Enter), sin respuesta del
# agente: su eco no es un ACK.
J7_RELAY_ECO = ('tco_relay_file() { printf "lee /tmp/rol.txt %s" "$5" > "$FAKE_STATE/eco.txt"; '
                'printf "relay %s\\n" "$2" >> "$FAKE_STATE/relay.log"; '
                'incus exec fixture -- su - fixture -c "tmux send-keys -t \'$2\' -l \\"\\$(cat \'$FAKE_STATE/eco.txt\')\\" '
                '&& tmux send-keys -t \'$2\' Enter"; command sleep 0.5; return 0; }\n')


def j7_panes(tm):
    fmt = "#{window_index}.#{pane_index}|#{pane_id}|#{pane_pid}|#{pane_start_command}"
    return {l.split("|")[0]: l.split("|", 3) for l in tm("list-panes", "-s", "-t", "v:", "-F", fmt).stdout.splitlines()}


def j7_log(world):
    path = world.state / "relay.log"
    return path.read_text().splitlines() if path.exists() else []


def j7_ventana(variante, retardo, relay, ventana="durante"):
    """N8 de R9011j6 (`ventana_cambia`), tmux REAL y relanzamiento REAL sobre v:.1. Ventana 0 con dos panes; ventana 1 con
    `sleep 600` y un pane 1 que muestra ROL-AUDITORIA-LISTO. La ventana activa cambia a la 1 DURANTE el flujo: otro cliente
    hace `select-window` en la espera del TUI, o un hook `pane-died` hace `run-shell 'sleep N'` ; `select-window`.
    `ventana="durante"`: la ventana 1 se abre DESPUÉS de leer el `%N` (el cliente al empezar la espera del TUI; el hook al
    dispararse); tras leer el `%N`, TODO (espera, update/trust, relay y captura del ACK) va a ESE `%N` y resuelve a él: 0
    relays a otro pane, 0 ACK leídos de otro pane y 0 éxitos falsos; con el relay de N8 (falla) el relanzamiento falla cerrado
    sin «rol recargado»; con un relay que entrega, termina bien en el pane lanzado. `ventana="previa"` (el montaje de N8 tal
    cual: la ventana 1 ya existe al empezar): desde R9011j7 J7-01 la sesión que ya existía tiene más de una ventana y el
    relanzamiento falla cerrado ANTES de tocar nada: rc 1, 0 pasos, nada lanzado y ningún pane cambia."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            otra = "printf 'ROL-AUDITORIA-LISTO\\n'; exec sleep 600"
            if ventana == "previa":
                assert tm("new-window", "-d", "-t", "v:", "-n", "otra", "sleep 600").returncode == 0
                assert tm("split-window", "-d", "-t", "v:1", otra).returncode == 0
                tm("select-window", "-t", "v:0")
            hilo = None
            parar = threading.Event()
            if variante == "hook":
                abre = "" if ventana == "previa" else \
                    "new-window -d -t v: -n otra 'sleep 600' ; split-window -d -t v:1 \"echo ROL-AUDITORIA-LISTO; exec sleep 600\" ; "
                hook = abre + "run-shell " + shlex.quote(f"sleep {retardo}") + " ; select-window -t v:1"
                assert tm("set-hook", "-g", "pane-died", hook).returncode == 0
            elif variante == "cliente":
                def cambia():
                    fin = time.monotonic() + 60
                    while not (world.state / "tui").exists() and time.monotonic() < fin and not parar.is_set():
                        time.sleep(0.05)
                    if not (world.state / "tui").exists():
                        return
                    if ventana != "previa":
                        tm("new-window", "-d", "-t", "v:", "-n", "otra", "sleep 600")
                        tm("split-window", "-d", "-t", "v:1", otra)
                    time.sleep(retardo)
                    tm("select-window", "-t", "v:1")
                hilo = threading.Thread(target=cambia, daemon=True)
                hilo.start()
            antes = j7_panes(tm)
            stubs = J7_STUBS_N8 + J7_CAP_LOG + (J7_RELAY_OK if relay == "ok" else "")
            result = world.run(PRELUDE + stubs + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               {"TCO_AUDIT_CLI": "codex-root"})
            parar.set()
            if hilo:
                hilo.join(5)
            activa = tm("display-message", "-p", "-t", "v:", "#{window_index}").stdout.strip()
            fin = time.monotonic() + 5
            while variante != "ninguna" and ventana != "previa" and activa != "1" and time.monotonic() < fin:
                time.sleep(0.2)
                activa = tm("display-message", "-p", "-t", "v:", "#{window_index}").stdout.strip()
            despues = j7_panes(tm)
            text = result.stdout + result.stderr
            lanzado = [k for k, v in despues.items() if "codex-root" in v[3] and SONDA_FIRMA not in v[3]]
            id_lanzado = despues["0.1"][1] if "0.1" in despues else "?"
            log = j7_log(world)
            exito = "rol recargado" in text
            for linea in log:
                print("LOG", linea, flush=True)
            print(f"OBSERVACION j7_n8 variante={variante} retardo={retardo} relay={relay} ventana={ventana} "
                  f"rc={result.returncode} lanzado_en={lanzado} id={id_lanzado} exito_declarado={exito} activa={activa}",
                  flush=True)
            if ventana == "previa":
                # Sesión que ya existía con dos ventanas: fallo cerrado ANTES de tocar nada (R9011j7 J7-01).
                assert result.returncode != 0 and not exito, f"j7_n8 previa {variante}: no falla cerrado: {result}"
                assert lanzado == [] and despues == antes, f"j7_n8 previa {variante}: se tocó algún pane: {antes} -> {despues}"
                assert not log, f"j7_n8 previa {variante}: hubo pasos tras la lectura (debía negarse antes): {log}"
                assert "2 ventanas" in text and "cierra las ventanas" in text, f"j7_n8 previa {variante}: mensaje: {text}"
                return
            assert lanzado == ["0.1"], f"j7_n8 {variante}/{retardo}: se lanzó en {lanzado}: {despues} {text}"
            assert despues["0.0"][2] == antes["0.0"][2], f"j7_n8 {variante}/{retardo}: murió el pane ajeno 0.0"
            for k in ("1.0", "1.1"):
                assert k not in despues or k in antes or "codex" not in despues[k][3], \
                    f"j7_n8 {variante}/{retardo}: se lanzó en la ventana abierta durante el flujo: {despues}"
            # UN destino: cada paso posterior a leer el `%N` lo recibe tal cual (no un destino relativo) y resuelve a él.
            otros = [l for l in log if l.split()[1] != id_lanzado or not l.endswith(" -> " + id_lanzado)]
            assert not otros, f"j7_n8 {variante}/{retardo}: pasos dirigidos a otro destino que {id_lanzado}: {otros} {text}"
            if relay == "ok":
                assert result.returncode == 0 and exito, f"j7_n8 {variante}/{retardo}: con el relay entregado: {result}"
                assert [l for l in log if l.startswith("cap ")], f"j7_n8 {variante}/{retardo}: el ACK no se capturó"
            else:
                assert result.returncode != 0 and not exito, \
                    f"j7_n8 {variante}/{retardo}: éxito declarado con el relay fallido: {result}"
            # El cliente cambia de ventana siempre; el hook `pane-died` no siempre se dispara (tmux lo puede saltar si el pane
            # se relanza antes): se exige en al menos una variante con hook (mode_j7_n8).
            if variante == "cliente":
                assert activa == "1", f"j7_n8 {variante}/{retardo}: la ventana no llegó a cambiar (caso no ejercitado)"
            if variante == "hook" and activa == "1":
                J7_HOOK_EJERCITADO.append(retardo)
        finally:
            tm.close()


J7_HOOK_EJERCITADO = []


def j7_todas(nombre, casos):
    """Corre TODAS las variantes (cada una con su tmux privado) y falla al final con la lista de las que fallaron."""
    fallos = []
    for fn, args in casos:
        try:
            fn(*args)
        except AssertionError as error:
            fallos.append(f"{args}: {str(error)[:600]}")
            print(f"FALLO {nombre} {args}: {str(error)[:600]}", flush=True)
    assert not fallos, f"{nombre}: {len(fallos)} de {len(casos)} variantes fallan: {fallos}"
    print(f"{nombre}: {len(casos)} de {len(casos)} variantes en verde", flush=True)


def mode_j7_n8():
    j7_todas("j7_n8", [(j7_ventana, caso) for caso in (
        ("ninguna", 0, "falla"), ("cliente", 0.5, "falla"), ("hook", 1, "falla"), ("hook", 2, "falla"),
        ("hook", 3, "falla"), ("cliente", 0.5, "ok"), ("hook", 2, "ok"),
        ("cliente", 0.5, "ok", "previa"), ("hook", 2, "ok", "previa"))])
    print(f"j7_n8: el hook cambió la ventana en las variantes con sleep {J7_HOOK_EJERCITADO}", flush=True)
    assert J7_HOOK_EJERCITADO, "j7_n8: el hook pane-died no cambió la ventana en ninguna variante (caso no ejercitado)"


def j7_python_como(path):
    shutil.copyfile(shutil.which("python3"), path)
    path.chmod(0o755)


def j7_acred_rancia(variante):
    """N9 de R9011j6 tal cual (`acred_rancia`), tmux REAL: vida 1, el relanzamiento real acredita v:.1; `kill-server`, servidor
    nuevo (el mismo `%N`) y v:.1 arrancado por nombre, sin sonda (como preparar-sesiones), con el agente actualizado (otro
    inodo), el mismo, otro agente o un impostor. Con el fichero de la vida 1 en disco, --soft (`_tco_pane_agent_exes`) y el
    doctor (talent-ceo/leer-auditor.sh) acreditan al agente legítimo y siguen rechazando al impostor."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        for name in ("codex", "claude"):
            j7_python_como(world.remote / name)
        write(world.remote / "codex-root", "#!/bin/bash\nexec codex -c 'import time; time.sleep(60)'\n")
        write(world.remote / "claude-root", "#!/bin/bash\nexec claude -c 'import time; time.sleep(60)'\n")
        acred = world.home / ".local/state/talent-channel-operation/acreditacion"
        doctor = SKILLS / "talent-ceo" / "scripts" / "leer-auditor.sh"
        tm = RealTmux(world)

        def lee(cli):
            world.env["FAKE_PID_1"] = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
            soft = world.run(PRELUDE + f"_tco_pane_agent_exes 01 v:.1 {cli}\nexit $?\n")
            doc = world.run(f"bash {shlex.quote(str(doctor))} fixture v:.1 fixture {cli}\nexit $?\n")
            return first_line(soft.stdout), first_line(doc.stdout)

        try:
            tm.start()
            tm.session("v", panes=2)
            id1 = tm("display-message", "-p", "-t", "v:.1", "#{pane_id}").stdout.strip()
            vida1 = relanza(world)
            assert vida1.returncode == 0, f"j7_n9 {variante}: precondición, el relanzamiento de la vida 1: {vida1}"
            ficheros = sorted(p.name for p in acred.iterdir()) if acred.exists() else []
            assert ficheros, f"j7_n9 {variante}: precondición, la vida 1 no dejó acreditación en disco"
            tm("kill-server")
            if variante == "actualizado":
                nuevo = world.remote / "codex.nuevo"
                j7_python_como(nuevo)
                os.replace(nuevo, world.remote / "codex")
            # El servidor anterior tarda en salir: se reintenta el arranque del nuevo (mismo socket privado).
            for intento in range(10):
                time.sleep(0.5)
                if tm("-f", "/dev/null", "new-session", "-d", "-s", "arranque", "-c", str(world.cwd),
                      "sleep 600").returncode == 0:
                    break
            else:
                raise AssertionError(f"j7_n9 {variante}: no arrancó el servidor nuevo")
            assert tm("set-option", "-g", "default-shell", "/bin/bash").returncode == 0
            tm.session("v", panes=2)
            id2 = tm("display-message", "-p", "-t", "v:.1", "#{pane_id}").stdout.strip()
            assert id1 == id2, f"j7_n9 {variante}: precondición, el servidor nuevo reutiliza el %N ({id1} -> {id2})"
            cli = "claude-root" if variante == "otro_agente" else "codex-root"
            orden = cli
            if variante == "impostor":
                impostor = world.root / "impostor"
                j7_python_como(impostor)
                orden = f"{impostor} -c 'import time; time.sleep(60)'"
            assert tm("respawn-pane", "-k", "-t", "v:.1", orden).returncode == 0
            time.sleep(1.0)
            con = lee(cli)
            for fichero in acred.iterdir():
                fichero.unlink()
            sin = lee(cli)
            print(f"OBSERVACION j7_n9 variante={variante} cli={cli} vida1={ficheros} mismo_id={id1 == id2} "
                  f"CON_FICHERO soft,doctor={con} | SIN_FICHERO soft,doctor={sin}", flush=True)
            if variante == "impostor":
                assert "codex" not in con and "codex" not in sin, f"j7_n9 impostor: se acredita al impostor: {con} {sin}"
            else:
                esperado = "claude" if variante == "otro_agente" else "codex"
                assert con == (esperado, esperado), \
                    f"j7_n9 {variante}: la acreditación rancia de la vida 1 rechaza al agente legítimo: {con}"
                assert sin == (esperado, esperado), f"j7_n9 {variante}: control sin fichero: {sin}"
        finally:
            tm.close()


def mode_j7_n9():
    j7_todas("j7_n9", [(j7_acred_rancia, (variante,)) for variante in ("mismo", "actualizado", "otro_agente", "impostor")])


def j7_muere(skip_real):
    """(CEO) El `%N` lanzado MUERE durante la espera del TUI (tmux REAL, relanzamiento REAL sobre v:.1): rc 1, 0 relays, ni
    una captura del ACK tras el fallo, el mensaje con los tres elementos (el agente lanzado MURIÓ, el estado de
    remain-on-exit y el remedio en una línea) y NUNCA «rol recargado». Con el salto de update/trust sustituido (el fallo lo
    observa el relay) y con el REAL (lo observa él)."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        tm = RealTmux(world)
        muerto = []
        try:
            tm.start()
            tm.session("v", panes=2)

            def mata():
                fin = time.monotonic() + 60
                while not (world.state / "tui").exists() and time.monotonic() < fin:
                    time.sleep(0.05)
                pid = tm("display-message", "-p", "-t", "v:.1", "#{pane_pid}").stdout.strip()
                if pid.isdigit():
                    os.kill(int(pid), signal.SIGKILL)
                    muerto.append(pid)
            hilo = threading.Thread(target=mata, daemon=True)
            hilo.start()
            # Cada sustitución de N8 es UNA línea: se quita la del relay (la sustituye la que solo registra) y, con el salto
            # REAL, la del salto de update/trust.
            partes = J7_STUBS_N8.split("\n")
            stubs = "\n".join(l for l in partes if not l.startswith("tco_relay_file()")
                              and not (skip_real and l.startswith("tco_codex_skip_update_and_trust()")))
            stubs += J7_RELAY_REGISTRA + J7_CAP_LOG
            assert ("tco_codex_skip_update_and_trust()" in stubs) != skip_real, "arnés: sustitución del salto mal construida"
            result = world.run(PRELUDE + stubs + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               {"TCO_AUDIT_CLI": "codex-root"})
            hilo.join(5)
            text = result.stdout + result.stderr
            log = j7_log(world)
            for linea in log:
                print("LOG", linea, flush=True)
            lineas = [l for l in text.splitlines() if "MURIÓ" in l and "remain-on-exit" in l and "relanza con" in l]
            print(f"OBSERVACION j7_muere skip_real={skip_real} rc={result.returncode} muerto={muerto} "
                  f"relays={len([l for l in log if l.startswith('relay ')])} "
                  f"capturas={len([l for l in log if l.startswith('cap ')])} mensaje={lineas[:1]}", flush=True)
            assert muerto, "j7_muere: precondición, el pane lanzado no se pudo matar durante la espera del TUI"
            assert result.returncode != 0, f"j7_muere: el relanzamiento no falla con el %N muerto: {result}"
            assert "rol recargado" not in text, f"j7_muere: «rol recargado» con el %N muerto: {text}"
            assert not [l for l in log if l.startswith("relay ")], f"j7_muere: se relevó el rol a un pane muerto: {log}"
            # La única captura admitida es UNA observación previa al relay (la del salto REAL de update/trust o la que mira si
            # el pane ya mostraba el ACK); ninguna es del sondeo del ACK, que no debe empezar tras el fallo.
            capturas = [l for l in log if l.startswith("cap ")]
            assert len(capturas) <= 1, f"j7_muere: se siguió esperando el ACK tras el fallo: {log}"
            assert lineas, f"j7_muere: ninguna línea dice MURIÓ + remain-on-exit + «relanza con …»: {text}"
            assert "relay rc=0" not in lineas[0], f"j7_muere: el mensaje da por bueno el relay: {lineas[0]}"
            assert ("update/trust rc=2" in lineas[0]) == skip_real, f"j7_muere: el rc del salto no es el observado: {lineas[0]}"
        finally:
            tm.close()


def mode_j7_muere():
    j7_todas("j7_muere", [(j7_muere, (skip_real,)) for skip_real in (False, True)])


def j7_codigo(texto):
    return [(i, l) for i, l in enumerate(texto.splitlines()) if not l.lstrip().startswith("#")]


J7_RELATIVOS = ("$(tco_pane_dev)", "$(tco_pane_audit)", "-t '$TCO_TMUX", '-t "$TCO_TMUX')
J7_LECTURAS = ('tco_pane_destino "$(tco_pane_dev)"', 'tco_pane_destino "$(tco_pane_audit)"')


def mode_j7_censo():
    """Censo permanente (J6-01, J6-03 y N-04), estático: en dispatch.sh y audit-carril.sh, después de la primera lectura del
    `%N` (tco_pane_id_fijar) ninguna línea de código usa un destino relativo (`$(tco_pane_dev)`, `$(tco_pane_audit)` o
    `-t '$TCO_TMUX…'`) salvo para leer el `%N` (tco_pane_id_fijar) o buscar el ya leído (tco_pane_destino); --soft lee
    también el `%N`; en el relanzamiento de lib.sh, después de leerlo, el destino declarado (`$dest`) solo se usa para
    buscarlo; las funciones de lib.sh que el despacho llama después (calibración, modelo del auditor y la versión del CLI)
    van por el `%N` fijado; y `tco_pane_destino_sigue` ya no existe."""
    malos = []
    for name in ("dispatch.sh", "audit-carril.sh"):
        code = j7_codigo((OP / name).read_text())
        # Camino normal: desde la lectura del %N de la sesión recién creada (tco_pane_id_fijar).
        lee = min((i for i, l in code if "tco_pane_id_fijar " in l), default=None)
        assert lee is not None, f"{name}: no lee el %N"
        for i, l in code:
            if i <= lee or "tco_pane_id_fijar " in l:
                continue
            resto = l
            for lectura in J7_LECTURAS:
                resto = resto.replace(lectura, "")
            if any(r in resto for r in J7_RELATIVOS):
                malos.append(f"{name}:{i + 1}: {l.strip()}")
    dispatch = (OP / "dispatch.sh").read_text()
    if dispatch.count('P_DEV="$(tco_pane_destino "$(tco_pane_dev)")"') != 2:
        malos.append("dispatch.sh: el %N no se lee en los dos modos (normal y --soft)")
    # --soft (R9011j7 J7-01): lee el %N UNA vez, con tco_panes_fijar_sesion, ANTES del reciclaje, y se lo pasa; en la rama
    # --soft ningún destino relativo tras esa lectura, y nada vuelve a leer el %N después (tco_pane_id_fijar: solo el normal).
    dl = dispatch.splitlines()
    s0 = next((i for i, l in enumerate(dl) if l.startswith('  if [ "$SOFT" = yes ]; then')), None)
    s1 = next((i for i in range(s0 + 1, len(dl)) if dl[i] == "  else"), None) if s0 is not None else None
    rama = [(i, l) for i, l in enumerate(dl[s0:s1], s0) if not l.lstrip().startswith("#")] if s1 else []
    fija = min((i for i, l in rama if l.lstrip().startswith("tco_panes_fijar_sesion ")), default=None)
    recicla = min((i for i, l in rama if 'tco_recycle_carril "$CARRIL" --soft "$P_DEV" "$P_AUD"' in l), default=None)
    if fija is None or recicla is None or fija > recicla:
        malos.append("dispatch.sh: --soft no lee el %N con tco_panes_fijar_sesion ANTES del reciclaje ni se lo pasa")
    for i, l in rama:
        if fija is None or i <= fija:
            continue
        resto = l
        for lectura in J7_LECTURAS:
            resto = resto.replace(lectura, "")
        if any(r in resto for r in J7_RELATIVOS):
            malos.append(f"dispatch.sh:{i + 1}: (--soft) {l.strip()}")
    if len([l for _, l in j7_codigo(dispatch) if "tco_pane_id_fijar " in l]) != 1:
        malos.append("dispatch.sh: el %N se lee con tco_pane_id_fijar fuera del camino normal (--soft lo relee)")
    lines = (OP / "lib.sh").read_text().splitlines()
    # El reciclaje suave: preflight, reposo y «/clear» por el %N recibido o fijado, nunca por $(tco_pane_dev).
    r0 = next(i for i, l in enumerate(lines) if l.startswith("tco_recycle_carril() {"))
    r1 = next(i for i in range(r0 + 1, len(lines)) if lines[i].startswith('  if [ "${2:-}" = --soft ]; then'))
    r2 = next(i for i in range(r1 + 1, len(lines)) if lines[i] == "  fi")
    suave = [(i, l) for i, l in enumerate(lines[r1:r2], r1) if not l.lstrip().startswith("#")]
    for i, l in suave:
        resto = l
        for lectura in J7_LECTURAS:
            resto = resto.replace(lectura, "")
        if any(r in resto for r in J7_RELATIVOS):
            malos.append(f"lib.sh:{i + 1}: (reciclaje suave) {l.strip()}")
    if not [l for _, l in suave if 'tco_wait_idle "$1" "$p_dev"' in l] \
            or not [l for _, l in suave if '_tco_send_text_submit "$1" "$p_dev" /clear' in l]:
        malos.append("lib.sh: el reciclaje suave no espera ni teclea el /clear por el %N")
    start = next(i for i, l in enumerate(lines) if l.startswith("tco_codex_relaunch_and_role() {"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    body = [(i, l) for i, l in enumerate(lines[start:end + 1], start) if not l.lstrip().startswith("#")]
    lee = min((i for i, l in body if "tco_panes_fijar_sesion " in l), default=None)
    assert lee is not None, "lib.sh: el relanzamiento no lee el %N con tco_panes_fijar_sesion"
    for i, l in body:
        if i <= lee:
            continue
        resto = l.replace('pane="$(tco_pane_destino "$dest")"', "")
        if re.search(r"\$\{?dest\b", resto) or "$(tco_pane_" in resto:
            malos.append(f"lib.sh:{i + 1}: {l.strip()}")
    # tco_ensure_audit_model() ya no está en el censo: desde 4044e1de no toca ningún pane (el auditor es siempre Codex y la función
    # solo rechaza un auditor Claude), así que no hay %N fijado que resolver.
    for fn in ("tco_pane_calibration_preflight() {", "_tco_pane_cli_version() {"):
        s = next(i for i, l in enumerate(lines) if l.startswith(fn))
        e = next(i for i in range(s + 1, len(lines)) if lines[i] == "}")
        texto = "\n".join(l for l in lines[s:e + 1] if not l.lstrip().startswith("#"))
        if "tco_pane_destino" not in texto:
            malos.append(f"lib.sh: {fn} no resuelve el %N fijado")
        if fn != "_tco_pane_cli_version() {":
            resto = texto
            for lectura in J7_LECTURAS:
                resto = resto.replace(lectura, "")
            if any(r in resto for r in J7_RELATIVOS):
                malos.append(f"lib.sh: {fn} usa un destino relativo")
    for name in ("dispatch.sh", "audit-carril.sh", "lib.sh"):
        if [l for _, l in j7_codigo((OP / name).read_text()) if "tco_pane_destino_sigue" in l]:
            malos.append(f"{name}: tco_pane_destino_sigue sigue en el código")
    for m in malos:
        print("CENSO", m, flush=True)
    assert not malos, f"j7_censo: {len(malos)} destinos relativos posteriores a leer el %N"
    print("j7_censo: 0 destinos relativos posteriores a leer el %N")


# Agente acreditado que muestra el token ANTES de recibir el rol (p. ej. una sesión retomada): no es un ACK del relay.
J7_AGENT_ACK_PREVIO = ("#!/usr/bin/env python3\nimport time\nprint('ROL-AUDITORIA-LISTO', flush=True)\ntime.sleep(60)\n")


def j7_eco(caso):
    """«eco»: el relay teclea en el pane exactamente `lee <ruta> <mensaje>` + Enter y ningún agente responde. «previo»: el
    agente lanzado ya muestra ROL-AUDITORIA-LISTO antes del relay (que solo registra). En los dos, nunca «rol recargado»."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO if caso == "eco" else J7_AGENT_ACK_PREVIO)
        world.launchers()
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            stubs = J7_STUBS_N8 + (J7_RELAY_ECO if caso == "eco" else J7_RELAY_REGISTRA) + J7_CAP_LOG
            result = world.run(PRELUDE + stubs + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               {"TCO_AUDIT_CLI": "codex-root"})
            text = result.stdout + result.stderr
            eco = (world.state / "eco.txt").read_text() if (world.state / "eco.txt").exists() else ""
            pantalla = tm("capture-pane", "-p", "-J", "-t", "v:.1").stdout
            print(f"OBSERVACION j7_eco caso={caso} rc={result.returncode} eco={eco!r} "
                  f"relays={len([l for l in j7_log(world) if l.startswith('relay ')])}", flush=True)
            print("PANTALLA", repr(pantalla[-400:]), flush=True)
            if caso == "eco":
                assert eco[:4] == "lee " and eco.split()[-1] in pantalla, f"j7_eco: precondición, el eco no llegó: {eco!r}"
            else:
                assert "ROL-AUDITORIA-LISTO" in pantalla, f"j7_eco previo: precondición, el pane no muestra el token"
                assert not [l for l in j7_log(world) if l.startswith("relay ")], f"j7_eco previo: se relevó igual: {text}"
            assert "rol recargado" not in text, f"j7_eco {caso}: se tomó por ACK algo que no responde al relay: {text}"
            assert result.returncode != 0, f"j7_eco {caso}: {result}"
        finally:
            tm.close()


def mode_j7_eco():
    """El ACK es la RESPUESTA del agente al relay de ESE relanzamiento (references/03): ni el eco del `lee` que teclea el
    relay ni un token que el pane ya mostraba ANTES del relay. tmux REAL, relanzamiento REAL sobre v:.1. Estático: ningún
    mensaje del relay del rol (dispatch.sh, audit-carril.sh y lib.sh) lleva el token, así que su eco no puede acabar en él."""
    malos = [f"{name}:{i + 1}" for name in ("dispatch.sh", "audit-carril.sh", "lib.sh")
             for i, l in j7_codigo((OP / name).read_text()) if "ROL de auditoría" in l and "ROL-AUDITORIA-LISTO" in l]
    print(f"OBSERVACION j7_eco estaticos={malos}", flush=True)
    j7_todas("j7_eco", [(j7_eco, (caso,)) for caso in ("eco", "previo")])
    assert not malos, f"j7_eco: mensajes del relay del rol con el token (su eco acaba en él): {malos}"


# ------------------------------------------------------------------------------------------------------------------------
# j8 (R9011j7): --soft lee el %N UNA vez, ANTES del reciclaje, y, como el relanzamiento, con más de una ventana en una sesión
# que ya existía falla cerrado sin teclear nada (J7-01); el relanzamiento compara la vida del servidor tmux en cada
# observación (J7-02); la identidad tras el ACK tiene su negativa (J7-03).

# Sondas S1 y S3 de R9011j7 TAL CUAL (`sondas-j7.py` del acta): el incus que pasa los posicionales de `su - u -c CMD _ texto`
# a la shell (`_tco_send_text_submit` teclea su texto como `$1`; el doble de incus los descarta) y `resuelto` (a qué
# ventana.pane resuelve un destino en ese instante).
J8_INCUS_SHIM = ('incus() { if [ "$1" = exec ]; then shift; while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done; shift; '
                 'local cmd="$1"; shift; ( cd "$FAKE_CWD" && PATH="$FAKE_REMOTE_PATH" HOME="$FAKE_HOME" /bin/bash -c "$cmd" "$@" ); '
                 'else command incus "$@"; fi; }\n'
                 'resuelto() { incus exec fixture -- su - fixture -c "tmux display-message -p -t \'$1\' \'#{window_index}.#{pane_index}\'"; }\n')
# S1: sustituciones que modelan la PRECONDICIÓN (los panes a los que resuelve el destino son agentes del CLI declarado,
# calibrados, ociosos y con el compositor vacío): el preflight, la espera de reposo y tco_send_ready, que registran a qué pane
# resuelve el destino en ese instante. El envío (`_tco_send_text_submit`: texto, sondeo de eco y submit) es el REAL.
J8_STUBS_SOFT = (J8_INCUS_SHIM +
                 'tco_pane_calibration_preflight() { printf "preflight %s %s\\n" "$(resuelto "$(tco_pane_destino "$(tco_pane_dev)")")" '
                 '"$(resuelto "$(tco_pane_destino "$(tco_pane_audit)")")" >> "$FAKE_STATE/soft.log"; return 0; }\n'
                 'tco_wait_idle() { printf "idle %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/soft.log"; '
                 ': > "$FAKE_STATE/idle"; command sleep 1.5; return 0; }\n'
                 'tco_send_ready() { printf "ready %s -> %s\\n" "$2" "$(resuelto "$2")" >> "$FAKE_STATE/soft.log"; '
                 ': > "$FAKE_STATE/ready"; return 0; }\n'
                 'tco_pane_busy_from() { cat >/dev/null; return 1; }\n'
                 'tco_tui_regions_from() { cat; }\n'
                 'tco_composer_echo_from() { grep -qF -- "$1"; }\n')
# S3: la espera del TUI aguarda a que el hilo de la prueba termine su perturbación (modela su sondeo real de hasta 90 s); el
# salto de update/trust registra; la captura y el ACK son los REALES (el envoltorio solo registra el destino de cada captura).
J8_STUBS_REL = (J8_INCUS_SHIM +
                'sleep() { [ "$1" = 5 ] || command sleep "$@"; }\n'
                'idp() { incus exec fixture -- su - fixture -c "tmux display-message -p -t \'$1\' \'#{pane_id}@#{pid}\'" 2>/dev/null; }\n'
                'tco_wait_tui_ready() { printf "tui %s -> %s\\n" "$2" "$(idp "$2")" >> "$FAKE_STATE/relay.log"; : > "$FAKE_STATE/tui"; '
                'local n=0; while [ ! -e "$FAKE_STATE/perturbado" ] && [ "$n" -lt 200 ]; do command sleep 0.1; n=$((n+1)); done; '
                'command sleep 0.5; return 0; }\n'
                'tco_codex_skip_update_and_trust() { printf "skip %s -> %s\\n" "$2" "$(idp "$2")" >> "$FAKE_STATE/relay.log"; return 0; }\n'
                'eval "_tco_cap_real() $(declare -f tco_cap_pane | tail -n +2)"\n'
                'tco_cap_pane() { printf "cap %s -> %s\\n" "$2" "$(idp "$2")" >> "$FAKE_STATE/relay.log"; _tco_cap_real "$@"; }\n')
# Relay que ENTREGA y cuyo «agente» responde: teclea en el pane al que va la línea ROL-AUDITORIA-LISTO.
J8_RELAY_OK = ('tco_relay_file() { printf "relay %s -> %s\\n" "$2" "$(idp "$2")" >> "$FAKE_STATE/relay.log"; '
               'incus exec fixture -- su - fixture -c "tmux send-keys -t \'$2\' -l ROL-AUDITORIA-LISTO && tmux send-keys -t \'$2\' Enter"; '
               ': > "$FAKE_STATE/relevado"; command sleep 0.5; return 0; }\n')


def j8_lector(rec, etiqueta):
    """Orden de un pane que registra cada LÍNEA que recibe (texto + Enter): el tty en modo canónico hace eco de lo tecleado
    (se ve en la captura) y solo entrega la línea al pulsar Enter."""
    script = f'while IFS= read -r l; do printf "%s\\n" "$l" >> {shlex.quote(str(rec / etiqueta))}; done'
    return "exec bash -c " + shlex.quote(script)


def j8_recibido(rec):
    return {p.name: p.read_text().splitlines() for p in sorted(rec.iterdir())} if rec.exists() else {}


def j8_ventana_1(world, tm, rec):
    """La ventana 1 de la sesión v (dos panes que registran lo que reciben), sin activarla."""
    assert tm("new-window", "-d", "-t", "v:", "-n", "otra", j8_lector(rec, "w1p0")).returncode == 0
    assert tm("split-window", "-d", "-t", "v:1", j8_lector(rec, "w1p1")).returncode == 0


def j8_sesion(world, tm, rec, ventanas):
    """Sesión v: ventana 0 (dev, auditoría) y, con `ventanas=2`, la ventana 1 (otros dos agentes). Los panes registran cada
    línea que reciben. Ventana activa: la 0."""
    assert tm("new-session", "-d", "-s", "v", "-c", str(world.cwd), j8_lector(rec, "w0p0")).returncode == 0
    assert tm("split-window", "-h", "-t", "v:", "-c", str(world.cwd), j8_lector(rec, "w0p1")).returncode == 0
    if ventanas == 2:
        j8_ventana_1(world, tm, rec)
    tm("select-window", "-t", "v:0")
    time.sleep(0.6)


def j8_pantallas(tm):
    out = tm("list-panes", "-s", "-t", "v:", "-F", "#{window_index}.#{pane_index}").stdout.split()
    return {k: tm("capture-pane", "-p", "-J", "-t", f"v:{k}").stdout for k in out}


def j8_lee_log(world, nombre):
    path = world.state / nombre
    return path.read_text().splitlines() if path.exists() else []


def j8_soft(variante, nivel):
    """S1 de R9011j7 (`soft_clear`), tmux REAL. `nivel="funcion"`: `tco_recycle_carril 01 --soft` REAL, como la sonda tal cual
    (sin el `%N`: el reciclaje lo lee él); `nivel="dispatch"`: las LÍNEAS REALES de dispatch.sh --soft (la rama suave hasta el
    reciclaje y el bloque de los panes de después, sin el repo ni el manifiesto) y el `%N` final de `$P_DEV`/`$P_AUD`.
    Variantes con DOS ventanas al empezar (`previa`: la 1 ya es la activa; `cliente_idle`: otro cliente cambia a la 1 durante
    la espera de reposo; `cliente_entre`: entre el texto y el submit): fallo cerrado ANTES de cualquier tecla (rc 1, ningún
    pane recibe nada, ningún «/clear» tecleado sin enviar en ningún pane, 0 pasos del reciclaje y el mensaje con las ventanas
    y el remedio). `durante`: UNA ventana al empezar y otro cliente abre la 1 y la activa durante la espera de reposo: el
    «/clear» y el `%N` final siguen siendo los de la ventana 0. `una_ventana`: el positivo, --soft legítimo."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        rec = world.root / "rec"
        rec.mkdir()
        write(world.remote / "git", "#!/bin/bash\nexit 0\n")  # el reinicio del repo del reciclaje: inocuo en la prueba
        tm = RealTmux(world)
        parar = threading.Event()
        try:
            tm.start()
            j8_sesion(world, tm, rec, 1 if variante in ("durante", "una_ventana") else 2)
            hilo = None
            if variante == "previa":
                tm("select-window", "-t", "v:1")
            elif variante in ("cliente_idle", "cliente_entre", "durante"):
                marca, espera = ("ready", 1.0) if variante == "cliente_entre" else ("idle", 0.3)

                def cambia():
                    fin = time.monotonic() + 60
                    while not (world.state / marca).exists() and time.monotonic() < fin and not parar.is_set():
                        time.sleep(0.05)
                    if not (world.state / marca).exists():
                        return
                    if variante == "durante":
                        j8_ventana_1(world, tm, rec)
                    time.sleep(espera)
                    tm("select-window", "-t", "v:1")
                hilo = threading.Thread(target=cambia, daemon=True)
                hilo.start()
            if nivel == "funcion":
                codigo = (PRELUDE + J8_STUBS_SOFT + "tco_recycle_carril 01 --soft; r=$?\n"
                          'echo "RECICLAJE rc=$r"\nexit $r\n')
            else:
                lineas = (OP / "dispatch.sh").read_text().splitlines()
                a = next(i for i, l in enumerate(lineas) if l.startswith('  if [ "$SOFT" = yes ]; then'))
                b = next(i for i in range(a, len(lineas)) if "recycle suave FALLÓ" in lineas[i])
                c = next(i for i, l in enumerate(lineas) if l.startswith('  if [ "$SOFT" != yes ]; then'))
                d = next(i for i in range(c, len(lineas)) if lineas[i] == "  fi")
                codigo = (PRELUDE + J8_STUBS_SOFT + "SOFT=yes; ISSUE=ABC-1\n" + "\n".join(lineas[a:b + 1]) + "\n  fi\n"
                          + "\n".join(lineas[c:d + 1]) + "\n"
                          'echo "FINAL P_DEV=${P_DEV-}=$(resuelto "${P_DEV-x}") P_AUD=${P_AUD-}=$(resuelto "${P_AUD-x}")"\n')
            result = world.run(codigo, {"TCO_DEV_CLI": "claude-root", "TCO_AUDIT_CLI": "codex-root"})
            parar.set()
            if hilo:
                hilo.join(5)
            time.sleep(0.5)
            text = result.stdout + result.stderr
            log = j8_lee_log(world, "soft.log")
            recibido = j8_recibido(rec)
            pantallas = j8_pantallas(tm)
            activa = tm("display-message", "-p", "-t", "v:", "#{window_index}").stdout.strip()
            final = next((l for l in result.stdout.splitlines() if l.startswith("FINAL ")), "")
            for linea in log:
                print("LOG", linea, flush=True)
            print(f"OBSERVACION j8_soft nivel={nivel} variante={variante} rc={result.returncode} recibido={recibido} "
                  f"activa={activa} {final}", flush=True)
            if variante in ("previa", "cliente_idle", "cliente_entre"):
                assert result.returncode != 0, f"j8_soft {nivel}/{variante}: --soft no falla cerrado con dos ventanas: {text}"
                assert recibido == {}, f"j8_soft {nivel}/{variante}: un pane recibió una línea: {recibido}"
                tecleado = [k for k, v in pantallas.items() if "/clear" in v]
                assert not tecleado, f"j8_soft {nivel}/{variante}: «/clear» tecleado sin enviar en {tecleado}"
                assert not log, f"j8_soft {nivel}/{variante}: el reciclaje llegó a correr (debía negarse antes): {log}"
                assert "2 ventanas" in text and "cierra las ventanas" in text, f"j8_soft {nivel}/{variante}: mensaje: {text}"
                assert "recycle SUAVE hecho" not in text and not final.startswith("FINAL P_DEV=%"), \
                    f"j8_soft {nivel}/{variante}: se dio por hecho: {text}"
                return
            assert result.returncode == 0 and "recycle SUAVE hecho" in text, f"j8_soft {nivel}/{variante}: {text}"
            assert recibido == {"w0p0": ["/clear"]}, f"j8_soft {nivel}/{variante}: el /clear no fue SOLO al pane dev: {recibido}"
            assert log and all(l.startswith(("preflight 0.0 0.1", "idle %", "ready %")) for l in log), \
                f"j8_soft {nivel}/{variante}: un paso no fue por el %N de la ventana 0: {log}"
            assert all(l.endswith(" -> 0.0") for l in log if not l.startswith("preflight")), \
                f"j8_soft {nivel}/{variante}: un paso resolvió a otro pane: {log}"
            if nivel == "dispatch":
                assert re.fullmatch(r"FINAL P_DEV=%\d+=0\.0 P_AUD=%\d+=0\.1", final), \
                    f"j8_soft dispatch/{variante}: el %N final no es el de la ventana 0: {final!r}"
            if variante == "durante":
                assert activa == "1" and "1.0" in pantallas, f"j8_soft {nivel}/durante: la ventana no llegó a cambiar"
        finally:
            parar.set()
            tm.close()


def mode_j8_s1_soft():
    j7_todas("j8_s1_soft", [(j8_soft, (v, "funcion")) for v in ("previa", "cliente_idle", "cliente_entre", "una_ventana")])


def mode_j8_soft_dispatch():
    j7_todas("j8_soft_dispatch", [(j8_soft, (v, "dispatch")) for v in ("previa", "durante", "una_ventana")])


def j8_nuevo_servidor(tm, world):
    for _ in range(20):
        time.sleep(0.5)
        if tm("-f", "/dev/null", "new-session", "-d", "-s", "arranque", "-c", str(world.cwd), "sleep 600").returncode == 0:
            break
    else:
        raise AssertionError("no arrancó el servidor nuevo")
    assert tm("set-option", "-g", "default-shell", "/bin/bash").returncode == 0


def j8_s3(variante):
    """S3 de R9011j7 (`relanzamiento`), tmux REAL y relanzamiento REAL sobre v:.1: durante la espera del TUI, `kill-server`,
    servidor nuevo, sesión v de dos panes (el MISMO `%N`) y v:.1 arrancado por nombre (`codex-root`, o `claude-root` en
    `..._otro_agente`); el relay entrega. Ese `%N` ya es OTRO pane (otra vida del servidor): rc 1, 0 relays, nunca «rol
    recargado» y el mensaje dice que el servidor tmux ya no es el del lanzamiento."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        tm = RealTmux(world)
        datos = {}
        try:
            tm.start()
            tm.session("v", panes=2)
            vida0 = tm("display-message", "-p", "-t", "v:.1", "#{pane_id}@#{pid}").stdout.strip()

            def perturba():
                fin = time.monotonic() + 60
                while not (world.state / "tui").exists() and time.monotonic() < fin:
                    time.sleep(0.05)
                try:
                    tm("kill-server")
                    j8_nuevo_servidor(tm, world)
                    tm.session("v", panes=2)
                    cli = "claude-root" if variante.endswith("otro_agente") else "codex-root"
                    assert tm("respawn-pane", "-k", "-t", "v:.1", cli).returncode == 0
                    time.sleep(1.0)
                    datos["despues"] = tm("display-message", "-p", "-t", "v:.1", "#{pane_id}@#{pid}").stdout.strip()
                finally:
                    (world.state / "perturbado").touch()
            hilo = threading.Thread(target=perturba, daemon=True)
            hilo.start()
            result = world.run(PRELUDE + J8_STUBS_REL + J8_RELAY_OK + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               {"TCO_AUDIT_CLI": "codex-root", "TCO_LANZADO_IDENT_WAIT": "3"}, timeout=120)
            hilo.join(10)
            text = result.stdout + result.stderr
            log = j8_lee_log(world, "relay.log")
            for linea in log:
                print("LOG", linea, flush=True)
            relays = [l for l in log if l.startswith("relay ")]
            despues = datos.get("despues", "")
            print(f"OBSERVACION j8_s3 variante={variante} rc={result.returncode} lanzado={vida0} despues={despues} "
                  f"relays={relays}", flush=True)
            assert despues.split("@")[0] == vida0.split("@")[0] and despues != vida0, \
                f"j8_s3 {variante}: precondición, el servidor nuevo no reutilizó el %N con otra vida: {vida0} -> {despues}"
            assert result.returncode != 0 and "rol recargado" not in text, f"j8_s3 {variante}: éxito sobre otro servidor: {text}"
            assert not relays, f"j8_s3 {variante}: se relevó el rol a un pane de OTRO servidor: {relays}"
            assert "servidor tmux" in text and "OTRO servidor" in text, f"j8_s3 {variante}: mensaje sin la vida: {text}"
        finally:
            tm.close()


def mode_j8_s3_vida():
    j7_todas("j8_s3_vida", [(j8_s3, (v,)) for v in ("servidor_nuevo_mismo_N", "servidor_nuevo_mismo_N_otro_agente")])


J8_STUBS_ACK = ('sleep() { [ "$1" = 5 ] || command sleep "$@"; }\n'
                'tco_wait_tui_ready() { return 0; }\n'
                'tco_codex_skip_update_and_trust() { return 0; }\n')
# Tras el relay, el pane pasa a ejecutar OTRO agente (otro fichero) que responde la línea del ACK: mismo servidor, mismo %N.
J8_RELAY_OTRO = ('tco_relay_file() { printf "relay %s\\n" "$2" >> "$FAKE_STATE/relay.log"; '
                 'incus exec fixture -- su - fixture -c "tmux respawn-pane -k -t \'$2\' \'$J8_OTRO\'"; '
                 'command sleep 0.8; return 0; }\n')
# Control: el agente lanzado sigue en el pane y la línea del ACK llega a él.
J8_RELAY_MISMO = ('tco_relay_file() { printf "relay %s\\n" "$2" >> "$FAKE_STATE/relay.log"; '
                  'incus exec fixture -- su - fixture -c "tmux send-keys -t \'$2\' -l ROL-AUDITORIA-LISTO && tmux send-keys -t \'$2\' Enter"; '
                  'command sleep 0.5; return 0; }\n')


def j8_identidad(caso):
    """J7-03, tmux REAL y relanzamiento REAL sobre v:.1: la identidad TRAS el ACK. «otro»: tras el relay, el `%N` pasa a
    ejecutar otro agente (otro fichero) que responde la línea del ACK, en el MISMO servidor (la vida no cambia): el ACK se
    captura, pero la identidad ya no coincide → rc 1 y nunca «rol recargado». «control»: el agente lanzado sigue y responde →
    rc 0 con el rol recargado. Sin la identidad tras el ACK, «otro» daría rc 0 (mutación (g) del acta)."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        otro = world.root / "otro"
        write(otro, f"#!/bin/bash\nprintf 'ROL-AUDITORIA-LISTO\\n'\nexec {shlex.quote(str(world.remote / 'claude'))}\n")
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            relay = J8_RELAY_OTRO if caso == "otro" else J8_RELAY_MISMO
            result = world.run(PRELUDE + J8_STUBS_ACK + relay + "tco_codex_relaunch_and_role 01 v:.1\nexit $?\n",
                               {"TCO_AUDIT_CLI": "codex-root", "TCO_LANZADO_IDENT_WAIT": "2", "J8_OTRO": str(otro)},
                               timeout=120)
            text = result.stdout + result.stderr
            relays = j8_lee_log(world, "relay.log")
            orden = tm("display-message", "-p", "-t", "v:.1", "#{pane_start_command}").stdout.strip()
            print(f"OBSERVACION j8_identidad caso={caso} rc={result.returncode} relays={relays} orden={orden!r}", flush=True)
            assert len(relays) == 1, f"j8_identidad {caso}: precondición, el relay no corrió una vez: {relays} {text}"
            if caso == "otro":
                assert str(otro) in orden, f"j8_identidad otro: precondición, el pane no pasó al otro agente: {orden!r}"
                assert result.returncode != 0 and "rol recargado" not in text, \
                    f"j8_identidad otro: «rol recargado» con otro agente en el pane tras el ACK: {text}"
                assert "sí, pero la identidad ya no coincide" in text, f"j8_identidad otro: no lo para la identidad: {text}"
            else:
                assert result.returncode == 0 and "rol recargado" in text, f"j8_identidad control: {text}"
        finally:
            tm.close()


def mode_j8_identidad_tras_ack():
    j7_todas("j8_identidad_tras_ack", [(j8_identidad, (caso,)) for caso in ("otro", "control")])


def j8_relanza_ventanas(montaje):
    """J7-01 en el relanzamiento (sesión que ya existía), tmux REAL y relanzamiento REAL sobre v:.1: la sesión v tiene otra
    ventana con dos panes; `previa`: esa otra ventana es la activa; `inactiva`: la activa es la 0. `tres_panes`: una sola
    ventana, pero con un pane de más dividido sobre el .0 (el .1 pasa a ser ese pane ajeno). En todas: rc 1 ANTES de tocar
    nada (ningún pane cambia, ninguna sonda, nada lanzado) y el mensaje dice lo encontrado y el remedio."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        world.agents(text=AGENT_VIVO)
        world.launchers()
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            if montaje == "tres_panes":
                assert tm("split-window", "-d", "-t", "v:0.0", "sleep 600").returncode == 0
            else:
                assert tm("new-window", "-d", "-t", "v:", "-n", "otra", "sleep 600").returncode == 0
                assert tm("split-window", "-d", "-t", "v:1", "sleep 600").returncode == 0
                tm("select-window", "-t", "v:1" if montaje == "previa" else "v:0")
            antes = j7_panes(tm)
            result = relanza(world)
            time.sleep(0.5)
            despues = j7_panes(tm)
            text = result.stdout + result.stderr
            print(f"OBSERVACION j8_relanza_ventanas montaje={montaje} rc={result.returncode} despues={despues}", flush=True)
            assert result.returncode != 0 and "rol recargado" not in text, f"j8_relanza_ventanas {montaje}: {result}"
            assert despues == antes, f"j8_relanza_ventanas {montaje}: se tocó algún pane: {antes} -> {despues}"
            if montaje == "tres_panes":
                assert "tiene 3" in text and "cierra los panes de más" in text, f"j8_relanza_ventanas {montaje}: mensaje: {text}"
            else:
                assert "2 ventanas" in text and "cierra las ventanas" in text, f"j8_relanza_ventanas {montaje}: mensaje: {text}"
        finally:
            tm.close()


def mode_j8_relanzamiento_ventanas():
    j7_todas("j8_relanzamiento_ventanas", [(j8_relanza_ventanas, (m,)) for m in ("previa", "inactiva", "tres_panes")])


# ------------------------------------------------------------------------------------------------------------------------
# Fase del modelo con UNA clave lógica estable (issue 9011, pieza 1.7.4e). El despacho teclea y captura por el `%N` de cada
# pane (N-04), pero el fichero de fase `~/.claude/tf-phase-<clave>.json` se guarda y se lee con la clave LÓGICA del pane en
# la sesión del canal (`<sesión>:.0`, `<sesión>:.1`): la del lector de refresh-claude-auth.sh (tco_modelo_panel_instancia) y
# la de preparar-modelo-canal.sh. Con el `%N` el filtro de claves rechazaba la escritura y el despacho moría tras confirmar el
# modelo (F8 del ensayo 174d). Los dobles de tmux de las pruebas devuelven los ids con la forma real `%N` (fase_dobles_pane_id).

# Doble de incus de la fase: `incus exec <c> -- su - <u> -c '<orden>' [_ args…]` ejecuta la orden CON sus argumentos (los de
# tco_modelo_guardar_fase y tco_modelo_fase_canal) en el HOME del canal ficticio y con el PATH remoto (el tmux de la prueba).
FASE_INCUS = r'''#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
[ "$#" -gt 1 ] || exit 2
shift
cmd="$1"; shift
cd "${FAKE_CWD:-/}" || exit 2
PATH="$FAKE_REMOTE_PATH" HOME="$FAKE_HOME" exec /bin/bash -c "$cmd" "$@"
'''

# Dobles de la INTERFAZ del CLI (picker y diálogo), no del destino: el `%N`, tmux, el fichero de fase y su lector son los
# reales. FASE_ACTIVO=si: el picker muestra el modelo pedido ya activo. Cada tecla va a FAKE_STATE/tui.log con su destino.
FASE_TUI = r'''
sleep() { :; }
tco_current_model_dialog() { printf 'picker\n'; }
tco_model_active() { cat >/dev/null; [ "${FASE_ACTIVO:-no}" = si ]; }
tco_cap_pane() { printf 'picker\n'; }
tco_dialog_choice_from() { cat >/dev/null; return 0; }
tco_model_picker_pick() { cat >/dev/null; printf '2'; }
tco_wait_dialog_closed() { return 0; }
_tco_send_text_submit() { printf 'TECLEO %s %s\n' "$2" "$3" >> "$FAKE_STATE/tui.log"; return 0; }
tco_send_dialog_choice() { printf 'ELIGE %s %s\n' "$2" "$3" >> "$FAKE_STATE/tui.log"; return 0; }
OPUS="$(tco_modelo_read plan)" && SONNET="$(tco_modelo_read coding)" || exit 80
# El lector de refresh-claude-auth.sh: la clave de tco_modelo_panel_instancia.
lee() { tco_modelo_fase_canal "$c" "$TCO_CUSER" "$(tco_modelo_panel_instancia)"; }
'''

# Registro de modelos de la prueba: la fixture compartida del skill (los IDs viven solo en las fixtures exceptuadas de la
# capa modelos-rodantes de validate-package.sh). La prueba no depende de su valor: lo lee con tco_modelo_read.
FASE_REGISTRO = (HERE / "fixtures" / "modelos-cli-current.conf").read_text()
PANE_ID_FORMA = re.compile(r"^%[0-9]+$")


def fase_world(tmp):
    """Canal ficticio de la fase: el doble de incus que pasa los argumentos, `jq` en el PATH remoto (lo usa el lector), el
    registro de modelos neutro y la selección de panel por defecto (sin panel.conf, sin TMUX_SESSION ni TC_CLAUDE_PANE)."""
    world = World(tmp)
    jq = shutil.which("jq")
    assert jq, "jq ausente: el lector de la fase lo exige (los canales ya lo requieren)"
    (world.remote / "jq").symlink_to(jq)
    write(world.shim / "incus", FASE_INCUS)
    write(world.root / "modelos.conf", FASE_REGISTRO, 0o600)
    (world.root / "panel").mkdir()
    world.env.update(TCO_MODELOS_REGISTRO=str(world.root / "modelos.conf"), SECRET_DIR=str(world.root / "panel"))
    # HOST_USER y HOST_HOME se quedan: son del mundo (el aserto del entorno las exige definidas y dentro de él).
    for key in ("TMUX_SESSION", "TC_CLAUDE_PANE", "TC_CLAUDE_PHASE", "TMUX"):
        world.env.pop(key, None)
    aislamiento_agentes.aserto_entorno(world.env, world.root, completo=True, inicial=False)
    return world


def fase_ficheros(world):
    """Ficheros de fase en el HOME del canal: {clave: contenido} (un symlink se da como «-> destino»)."""
    d = world.home / ".claude"
    out = {}
    for f in sorted(d.glob("tf-phase-*")) if d.exists() else []:
        clave = f.name[len("tf-phase-"):-len(".json")]
        out[clave] = f"-> {os.readlink(f)}" if f.is_symlink() else f.read_text()
    return out


def fase_tui_log(world):
    path = world.state / "tui.log"
    return path.read_text() if path.exists() else ""


def mode_fase_tmux_real():
    """(a) %N REAL: tmux real con socket propio (`-L`), la sesión del canal con dos panes. Se lee el `%N` de cada pane como
    dispatch.sh (tco_pane_id_fijar + tco_pane_destino) y se recorre el camino hasta tco_modelo_guardar_fase: el gate del
    despacho (tco_ensure_model por $P_DEV), el cambio por el picker (tco_set_model por $P_DEV) y la clave de fase del
    pane .1 (tco_ensure_model por su `%N`; el auditor es siempre Codex y no tiene fase de Claude). Las teclas van al `%N`; el fichero se escribe con la clave lógica y lo
    lee la clave de refresh-claude-auth.sh."""
    with tempfile.TemporaryDirectory() as tmp:
        world = fase_world(tmp)
        tm = RealTmux(world)
        try:
            tm.start()
            tm.session("v", panes=2)
            reales = [tm("display-message", "-p", "-t", f"v:.{i}", "#{pane_id}").stdout.strip() for i in (0, 1)]
            assert all(PANE_ID_FORMA.match(r) for r in reales) and reales[0] != reales[1], f"precondición: {reales}"
            code = PRELUDE + FASE_TUI + r'''
tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" && tco_pane_id_fijar "$CARRIL" "$(tco_pane_audit)" || exit 90
P_DEV="$(tco_pane_destino "$(tco_pane_dev)")"; P_AUD="$(tco_pane_destino "$(tco_pane_audit)")"
echo "DESTINOS $P_DEV $P_AUD"
FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$P_DEV" "$OPUS" || exit 91
echo "LEE1 $(lee)"
FASE_ACTIVO=no tco_set_model "$CARRIL" "$P_DEV" "$SONNET" || exit 92
echo "LEE2 $(lee)"
FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$P_AUD" "$SONNET" || exit 93
echo "LEE3 $(TC_CLAUDE_PANE=v:.1 lee)"
exit 0
'''
            result = world.run(code)
            text = result.stdout + result.stderr
            assert result.returncode == 0, f"fase_tmux_real: el camino hasta la fase no termina (rc {result.returncode}): {text}"
            assert f"DESTINOS {reales[0]} {reales[1]}" in result.stdout, \
                f"fase_tmux_real: los destinos no son los `%N` reales {reales}: {text}"
            for linea in ("LEE1 plan", "LEE2 coding", "LEE3 coding"):
                assert linea in result.stdout, f"fase_tmux_real: el lector de refresh-claude-auth no lee {linea!r}: {text}"
            ficheros = fase_ficheros(world)
            assert ficheros == {"v:.0": '{"phase":"coding"}\n', "v:.1": '{"phase":"coding"}\n'}, \
                f"fase_tmux_real: ficheros de fase con otra clave o contenido: {ficheros}"
            # N-04 intacto: las teclas del picker van al `%N`, nunca a la clave lógica.
            tui = fase_tui_log(world)
            assert f"TECLEO {reales[0]} /model" in tui and f"ELIGE {reales[0]} model" in tui and "v:." not in tui, \
                f"fase_tmux_real: el tecleo no va por el `%N`: {tui!r}"
            print(f"fase_tmux_real: destinos {reales}, ficheros {sorted(ficheros)}")
        finally:
            tm.close()


def mode_fase_misma_clave():
    """(b) Escritor y lector usan la MISMA clave: lo que escribe tco_set_model/tco_ensure_model con el `%N` lo lee
    tco_modelo_fase_canal con la clave de refresh-claude-auth.sh (tco_modelo_panel_instancia: por defecto, TMUX_SESSION y
    panel.conf), y lo que escribe preparar-modelo-canal.sh también; igual con una sesión propia (`otra`). En el disco no queda
    NUNCA un fichero de fase con una clave que no sea lógica (ni tras un intento directo con el `%N`)."""
    with tempfile.TemporaryDirectory() as tmp:
        world = fase_world(tmp)
        (world.root / "panel-v").mkdir()
        write(world.root / "panel-v" / "panel.conf", "v:.0\n", 0o600)
        code = PRELUDE + FASE_TUI + r'''
PANEL_V="$1"
tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" && tco_pane_id_fijar "$CARRIL" "$(tco_pane_audit)" || exit 90
P_DEV="$(tco_pane_destino "$(tco_pane_dev)")"; P_AUD="$(tco_pane_destino "$(tco_pane_audit)")"
echo "DESTINOS $P_DEV $P_AUD"
FASE_ACTIVO=no tco_set_model "$CARRIL" "$P_DEV" "$OPUS" || exit 91
echo "SET-DEFECTO $(lee)"
echo "SET-SESION $(TMUX_SESSION=v lee)"
echo "SET-PANEL $(SECRET_DIR="$PANEL_V" lee)"
FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$P_AUD" "$SONNET" || exit 92
echo "AUD $(TC_CLAUDE_PANE=v:.1 lee)"
bash "$OP/preparar-modelo-canal.sh" "$c" "$TCO_CUSER" || exit 93
echo "PREPARAR $(lee)"
FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$P_DEV" "$OPUS" || exit 94
echo "ENSURE $(TMUX_SESSION=v lee)"
# Intento directo con el `%N` (lo que hacía el despacho): no debe dejar ningún fichero ni cambiar lo que se lee.
tco_modelo_guardar_fase "$c" "$TCO_CUSER" "$P_DEV" "$SONNET" 2>/dev/null; echo "DIRECTO-RC $?"
echo "TRAS-DIRECTO $(lee)"
# Sesión propia del canal: la clave es la lógica de ESA sesión, la que lee TMUX_SESSION=otra.
TCO_TMUX=otra; unset '_TCO_PANE_ID[v:.0]' '_TCO_PANE_ID[v:.1]'
tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" || exit 95
FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$(tco_pane_destino "$(tco_pane_dev)")" "$OPUS" || exit 96
echo "OTRA $(TMUX_SESSION=otra lee)"
TCO_TMUX=otra bash "$OP/preparar-modelo-canal.sh" "$c" "$TCO_CUSER" || exit 97
echo "OTRA-PREPARAR $(TMUX_SESSION=otra lee)"
exit 0
'''
        driver = world.root / "driver.sh"
        driver.write_text(code)
        env = dict(world.env, OP=str(OP))
        aislamiento_agentes.aserto_entorno(env, world.root, completo=True, inicial=False)
        result = subprocess.run(["/bin/bash", str(driver), str(world.root / "panel-v")], env=env, text=True,
                                capture_output=True, timeout=60)
        text = result.stdout + result.stderr
        assert result.returncode == 0, f"fase_misma_clave: rc {result.returncode}: {text}"
        assert "DESTINOS %0 %1" in result.stdout, f"fase_misma_clave: destinos: {text}"
        for linea in ("SET-DEFECTO plan", "SET-SESION plan", "SET-PANEL plan", "AUD coding", "PREPARAR coding",
                      "ENSURE plan", "TRAS-DIRECTO plan", "OTRA plan", "OTRA-PREPARAR coding"):
            assert linea in result.stdout, f"fase_misma_clave: el lector no lee {linea!r}: {text}"
        ficheros = fase_ficheros(world)
        assert set(ficheros) == {"v:.0", "v:.1", "otra:.0"}, \
            f"fase_misma_clave: ficheros de fase con una clave que no es la lógica: {sorted(ficheros)}"
        print(f"fase_misma_clave: claves en disco {sorted(ficheros)}")


def mode_fase_negativos():
    """(c) Negativos: un `%N` sin registro, de los dos panes o un destino que no es del canal fallan con el error, ANTES de
    teclear nada y sin fichero; una clave fuera del filtro falla con un error que la nombra, al escribir y al leer; y un
    symlink en el fichero de fase falla como antes, sin tocar su destino."""
    with tempfile.TemporaryDirectory() as tmp:
        world = fase_world(tmp)

        def corre(cuerpo):
            (world.state / "tui.log").unlink(missing_ok=True)
            return world.run(PRELUDE + FASE_TUI + cuerpo)

        # %N sin registro (gate y picker), %N de los dos panes y destino que no es del canal.
        casos = [
            ("sin_registro_ensure", 'FASE_ACTIVO=si tco_ensure_model "$CARRIL" %5 "$OPUS"', "'%5'"),
            ("sin_registro_set", 'FASE_ACTIVO=no tco_set_model "$CARRIL" %5 "$OPUS"', "'%5'"),
            ("de_los_dos", "_TCO_PANE_ID[v:.0]=%0; _TCO_PANE_ID[v:.1]=%0\n"
                           'FASE_ACTIVO=si tco_ensure_model "$CARRIL" %0 "$OPUS"', "2 de los dos panes"),
            ("otra_sesion", 'FASE_ACTIVO=si tco_ensure_model "$CARRIL" otra:.0 "$OPUS"', "'otra:.0'"),
        ]
        for nombre, cuerpo, esperado in casos:
            result = corre(cuerpo + "\nexit $?\n")
            text = result.stdout + result.stderr
            assert result.returncode != 0, f"fase_negativos/{nombre}: no falla: {text}"
            assert esperado in result.stderr and "clave de fase" in result.stderr and "ESCALAR" in result.stderr, \
                f"fase_negativos/{nombre}: el error no lo dice: {text}"
            assert fase_tui_log(world) == "", f"fase_negativos/{nombre}: se tecleó: {fase_tui_log(world)!r}"
            assert fase_ficheros(world) == {}, f"fase_negativos/{nombre}: se escribió: {fase_ficheros(world)}"
        # Clave fuera del filtro: el escritor y el lector la rechazan con un error que la nombra; ningún fichero.
        for clave, nombrada in (("%0", "%0"), ("v:.0 x", "v:.0\\ x"), ("v/.0", "v/.0"), ("$(x)", "\\$\\(x\\)")):
            for orden in ('tco_modelo_guardar_fase "$c" "$TCO_CUSER" "$1" "$OPUS"',
                          'tco_modelo_fase_canal "$c" "$TCO_CUSER" "$1"'):
                driver = world.root / "driver.sh"
                driver.write_text(PRELUDE + FASE_TUI + orden + "\nexit $?\n")
                aislamiento_agentes.aserto_entorno(world.env, world.root, completo=True, inicial=False)
                result = subprocess.run(["/bin/bash", str(driver), clave], env=world.env, text=True,
                                        capture_output=True, timeout=30)
                assert result.returncode != 0, f"fase_negativos/filtro {clave!r}: no falla: {result}"
                assert "clave de fase inválida" in result.stderr and nombrada in result.stderr, \
                    f"fase_negativos/filtro {clave!r}: el error no nombra la clave: {result.stderr!r}"
                assert fase_ficheros(world) == {}, f"fase_negativos/filtro {clave!r}: {fase_ficheros(world)}"
        # Symlink en el fichero de fase: el escritor (por el `%N` fijado) y el lector fallan; el destino queda intacto.
        (world.home / ".claude").mkdir()
        objetivo = world.home / "objetivo"
        objetivo.write_text("intacto\n")
        (world.home / ".claude" / "tf-phase-v:.0.json").symlink_to(objetivo)
        result = corre('tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" || exit 90\n'
                       'FASE_ACTIVO=si tco_ensure_model "$CARRIL" "$(tco_pane_destino "$(tco_pane_dev)")" "$OPUS"\n'
                       'echo "ESCRIBE-RC $?"\nlee; echo "LEE-RC $?"\n')
        text = result.stdout + result.stderr
        assert "ESCRIBE-RC 0" not in result.stdout and "ESCRIBE-RC" in result.stdout, f"fase_negativos/symlink: {text}"
        assert "LEE-RC 0" not in result.stdout and "LEE-RC" in result.stdout and "sin fase válida" in result.stderr, \
            f"fase_negativos/symlink: el lector no falla: {text}"
        assert objetivo.read_text() == "intacto\n" and (world.home / ".claude" / "tf-phase-v:.0.json").is_symlink(), \
            "fase_negativos/symlink: se tocó el destino del symlink"
        print("fase_negativos: %N sin registro, de los dos, otra sesión, filtro (4 claves x escritor y lector) y symlink")


def fase_constantes(path):
    """Cadenas literales de un fichero de pruebas en Python, ya sin escapes: sus dobles tal cual se escriben o se evalúan."""
    return [n.value for n in ast.walk(ast.parse(path.read_text()))
            if isinstance(n, ast.Constant) and isinstance(n.value, str)]


def fase_una(constantes, marcas, nombre):
    hits = [c for c in constantes if all(m in c for m in marcas)]
    assert len(hits) == 1, f"{nombre}: doble no localizado por sus marcas {marcas!r} ({len(hits)})"
    return hits[0]


def fase_funcion(texto, nombre):
    """La función bash `nombre() {` … `}` (cerrada en su misma columna) de un texto."""
    lines = texto.splitlines()
    s = next(i for i, l in enumerate(lines) if l.lstrip().startswith(nombre + "() {"))
    sangria = lines[s][:len(lines[s]) - len(lines[s].lstrip())]
    e = next(i for i in range(s + 1, len(lines)) if lines[i] == sangria + "}")
    return "\n".join(lines[s:e + 1]) + "\n"


# Ficheros de este directorio con dobles que contestan a tmux sobre panes (`display-message`, `list-panes`, `new-window`):
# cada uno tiene su comprobación abajo. Uno nuevo con un doble así hace caer la regla hasta que se añada aquí.
FASE_CENSO_DOBLES = {"launcher-dispatch-regressions.py", "launcher-identity-regressions.py",
                     "pane-identity-regressions.py", "test-calibration-preflight.sh"}
PIDE_ID = "#{pane_pid} #{pane_id} #{pid}.#{start_time}"


def mode_fase_dobles_pane_id():
    """(d) Regla de los dobles de tmux: todo doble de las pruebas de este skill que contesta `#{pane_id}` da la forma real
    `%N` (un destino inexistente, vacío, como tmux 3.4). Así un doble no puede volver a esconder un defecto que solo se ve
    con ids reales (F8 del ensayo 174d)."""
    malos = []

    def mira(origen, ids):
        for i in ids:
            if not PANE_ID_FORMA.match(i):
                malos.append(f"{origen}: pane_id {i!r} sin la forma %N")

    def bash(code, env=None, args=()):
        r = subprocess.run(["/bin/bash", "-c", code, "doble", *args],
                           env=dict(aislamiento_agentes.entorno_minimo(), **(env or {})), text=True,
                           capture_output=True, timeout=20)
        assert r.returncode == 0, f"fase_dobles_pane_id: el doble no contesta: {r}"
        return r.stdout

    censo = {p.name for p in HERE.iterdir() if p.is_file() and p.suffix in (".sh", ".py")
             and re.search(r"display-message|new-window|#\{pane_id\}|#\{session_name\}", p.read_text())}
    if censo != FASE_CENSO_DOBLES:
        malos.append(f"censo de dobles de tmux distinto del cubierto: nuevos {sorted(censo - FASE_CENSO_DOBLES)}, "
                     f"desaparecidos {sorted(FASE_CENSO_DOBLES - censo)}")
    with tempfile.TemporaryDirectory() as tmp:
        # FAKE_TMUX y FAKE_INCUS (este fichero): display-message, list-panes, new-window y la lectura del pid con el id.
        world = World(tmp)
        tmux = [str(world.remote / "tmux")]
        run = lambda *a: subprocess.run(tmux + list(a), env=world.env, text=True, capture_output=True, timeout=10).stdout
        mira("FAKE_TMUX display-message", [run("display-message", "-p", "-t", t, "#{pane_id}").strip()
                                           for t in ("v:.0", "v:.1", "%0", "%1")])
        if run("display-message", "-p", "-t", "v:.5", "#{pane_id}").strip() != "":
            malos.append("FAKE_TMUX display-message: un destino inexistente no da vacío (tmux 3.4)")
        mira("FAKE_TMUX list-panes", [l.split("|")[3] for l in run(
            "list-panes", "-s", "-t", "v", "-F", "#{session_name}|#{window_id}|#{pane_index}|#{pane_id}|#{pid}.#{start_time}"
        ).splitlines()])
        mira("FAKE_TMUX new-window", [run("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "v:", "true").strip()])
        out = subprocess.run([str(world.shim / "incus"), "exec", "fixture", "--", "su", "-", "fixture", "-c",
                              f"tmux display-message -p -t 'v:.1' '{PIDE_ID}'"], env=dict(world.env, FAKE_PID_1="77"),
                             text=True, capture_output=True, timeout=10).stdout.split()
        mira("FAKE_INCUS pid+id", out[1:2] or [""])
        # VIDA_DOBLE (este fichero).
        (world.state / "estados").write_text("0||\n")
        vida = bash(VIDA_DOBLE + f"incus exec fixture -- su - fixture -c \"tmux display-message -p -t 'v:.1' '#{{pane_id}}'\"\n"
                    "incus exec fixture -- su - fixture -c \"tmux list-panes -s -t 'v' -F '#{session_name}|#{window_id}|"
                    "#{pane_index}|#{pane_id}|#{pid}.#{start_time}'\"\n"
                    "incus exec fixture -- su - fixture -c \"tmux list-panes -t '%1' -F '#{pane_id}|#{pane_dead}'\"\n",
                    {"FAKE_STATE": str(world.state)}).splitlines()
        mira("VIDA_DOBLE", [vida[0]] + [l.split("|")[3] for l in vida[1:3]] + [l.split("|")[0] for l in vida[3:]])
    # pane-identity-regressions.py: el tmux de la sonda y los dos transportes de incus.
    pi = fase_constantes(HERE / "pane-identity-regressions.py")
    with tempfile.TemporaryDirectory() as tmp:
        shim = Path(tmp) / "tmux"
        write(shim, fase_una(pi, ("new-window) /bin/bash -c",), "pane-identity tmux"))
        mira("pane-identity tmux list-panes", [subprocess.run([str(shim), "list-panes", "-s", "-t", "v", "-F",
                                               "#{pane_id}|#{pane_current_command}"], env=aislamiento_agentes.entorno_minimo(),
                                              text=True, capture_output=True, timeout=10).stdout.split("|")[0]])
        mira("pane-identity tmux new-window", [subprocess.run([str(shim), "new-window", "-d", "-P", "-F", "#{pane_id}",
                                               "true"], env=aislamiento_agentes.entorno_minimo(), text=True,
                                              capture_output=True, timeout=10).stdout.strip()])
    nodo = fase_funcion(fase_una(pi, ("NODE_AGENT", "display-message"), "pane-identity incus (node)"), "incus")
    mira("pane-identity incus (node)", bash(nodo + f"incus exec fixture -- su - fixture -c \"tmux display-message -p -t "
                                            f"'v:.0' '{PIDE_ID}'\"\n").split()[1:2] or [""])
    transporte = fase_funcion(fase_una(pi, ("TEST_DEV", "display-message", "incus() {"), "pane-identity incus"), "incus")
    for t, pid in (("v:.0", "100"), ("v:.1", "101")):
        out = bash(transporte + f"incus exec fixture -- su - fixture -c \"tmux display-message -p -t '{t}' '{PIDE_ID}'\"\n",
                   {"TEST_DEV": "100", "TEST_AUD": "101"}).split()
        if out[:1] != [pid]:
            malos.append(f"pane-identity incus {t}: pid {out[:1]!r}")
        mira(f"pane-identity incus {t}", out[1:2] or [""])
    # launcher-identity-regressions.py: su transporte de incus.
    li = fase_una(fase_constantes(HERE / "launcher-identity-regressions.py"), ("SETUP_PLACEHOLDER", "display-message"),
                  "launcher-identity incus")
    with tempfile.TemporaryDirectory() as tmp:
        shim = Path(tmp) / "incus"
        write(shim, li.replace("SETUP_PLACEHOLDER", ""))
        for t in ("v:0.0", "v:0.1"):
            out = subprocess.run([str(shim), "exec", "fixture", "--", "su", "-", "fixture", "-c",
                                  f"tmux display-message -p -t '{t}' '{PIDE_ID}'"],
                                 env=dict(aislamiento_agentes.entorno_minimo(), TEST_PID="123"),
                                 text=True, capture_output=True, timeout=10).stdout.split()
            mira(f"launcher-identity incus {t}", out[1:2] or [""])
            if out[1:2] and out[1] != "%" + t[-1]:
                malos.append(f"launcher-identity incus {t}: {out[1]} no es el id de su índice")
    # test-calibration-preflight.sh: la lectura de los `%N` de la sesión (`list-panes -s` con #{session_name}).
    linea = [l for l in (HERE / "test-calibration-preflight.sh").read_text().splitlines()
             if "*'#{session_name}'*)" in l]
    assert len(linea) == 1, f"test-calibration-preflight.sh: doble de la sesión no localizado ({len(linea)})"
    orden = linea[0].split("*'#{session_name}'*)", 1)[1].rsplit(";;", 1)[0]
    mira("test-calibration-preflight session", [l.split("|")[3] for l in bash(orden).splitlines()])
    for m in malos:
        print("DOBLE", m, flush=True)
    assert not malos, f"fase_dobles_pane_id: {len(malos)} dobles con un pane_id sin la forma real %N"
    print("fase_dobles_pane_id: todos los dobles de tmux dan pane_id con la forma %N")


def mode_sistema_sin_agentes():
    """Unitario del espejo del sistema SIN agentes, con un sistema FALSO inyectado (nunca el real): los cuatro agentes y dos
    nombres de paquetes de agentes (codex-cli y claude-code) no aparecen, una utilidad sí y apunta a la real, un directorio, un
    enlace roto y un fichero no ejecutable no entran, y en un nombre duplicado gana el primer directorio."""
    with tempfile.TemporaryDirectory() as tmp:
        world = World(tmp)
        assert set(AGENTES) == set(aislamiento_agentes.AGENTES), \
            f"la lista de agentes de la prueba difiere de la de la guarda: {AGENTES}"
        falso = world.root / "falso"
        a, b = falso / "a", falso / "b"
        a.mkdir(parents=True)
        b.mkdir()
        for directorio in (a, b):
            for nombre in ("codex", "codex-root", "claude", "claude-root", "codex-cli", "claude-code"):
                write(directorio / nombre, AGENT)
        (a / "bash").symlink_to(shutil.which("bash"))
        (a / "herramienta").mkdir()
        (a / "roto").symlink_to(a / "no-existe")
        write(a / "datos", "no ejecutable\n", 0o644)
        write(a / "dup", "#!/bin/bash\necho a\n")
        write(b / "dup", "#!/bin/bash\necho b\n")
        ruta = world.sistema_sin_agentes(sistema=(a, b))
        for nombre in ("codex", "codex-root", "claude", "claude-root"):
            assert shutil.which(nombre, path=ruta) is None, f"el espejo deja pasar {nombre}"
        presentes = set(os.listdir(ruta))
        assert not presentes & {"codex-cli", "claude-code"}, f"el espejo deja pasar un paquete de agentes: {presentes}"
        assert os.path.realpath(shutil.which("bash", path=ruta)) == os.path.realpath(shutil.which("bash")), "bash"
        assert not presentes & {"herramienta", "roto", "datos"}, f"entradas que no son ejecutables: {presentes}"
        assert os.readlink(os.path.join(ruta, "dup")) == str(a / "dup"), "en un duplicado gana el primer directorio"
        assert world.sistema_sin_agentes(sistema=(a, b)) == ruta, "la segunda llamada cambia la ruta"
        assert world.sistema_sin_agentes() == world.sistema and ruta != world.sistema


def main():
    mode = sys.argv[1]
    # --- INICIO bloque de la guarda de testigos: llamada al helper (aserta el entorno del proceso y, solo si pasa, escribe el
    # testigo del modo en TCO_TESTIGO_DIR) ---
    aislamiento_agentes.guarda_proceso(mode, TESTIGO_DIR)
    # --- FIN bloque de la guarda de testigos ---
    # Toda llamada a subprocess de esta prueba lleva env= en lista blanca y nada escribe ni copia os.environ.
    aislamiento_agentes.aserto_ast(__file__)
    if mode == "sistema_sin_agentes":
        mode_sistema_sin_agentes()
    elif mode in ("identidad_destino_ajeno_mismo_basename", "identidad_destino_ruta_canonica",
                "preflight_dos_destinos_ajenos_comunes", "identidad_transporte_comilla_simple"):
        mode_identidad_ajena(mode)
    elif mode in ("identidad_r01_dos_sleep", "identidad_r05_path_del_pane", "identidad_r04_mismo_binario_real",
                  "identidad_r04_nombres_declarados"):
        mode_identidad_pane(mode)
    elif mode == "sonda_tmux_real":
        mode_sonda_tmux_real()
    elif mode in ("sonda_shell_del_servidor", "sonda_shell_del_servidor_sistema_con_agentes"):
        mode_sonda_shell_del_servidor(mode)
    elif mode == "sonda_sesion_ausente":
        mode_sonda_sesion_ausente()
    elif mode == "sonda_colgada":
        mode_sonda_colgada()
    elif mode in ("identidad_h02_enlaces_duros", "identidad_emite_inodo"):
        mode_h02(mode)
    elif mode == "vida_remain_local":
        mode_vida_remain_local()
    elif mode == "j5_orden_estatico":
        mode_j5_orden_estatico()
    elif mode in ("j5_a_shell_cambiada", "j5_a_shell_cambiada_sistema_con_agentes"):
        mode_j5_a_shell_cambiada(mode)
    elif mode in ("j5_b_cwd_sin_lanzadores_en_repo", "j5_b_cwd_con_lanzadores_en_repo",
                  "j5_b_cwd_sin_lanzadores_en_repo_sistema_con_agentes"):
        mode_j5_b_cwd(mode)
    elif mode == "j5_hook_after_new_window":
        mode_j5_hook()
    elif mode == "j5_identidad_acreditada":
        mode_j5_identidad_acreditada()
    elif mode == "j5_identidad_acreditada_execve":
        mode_j5_identidad_acreditada_execve()
    elif mode in ("j5_binario_symlink", "j5_binario_rename"):
        mode_j5_binario(mode)
    elif mode in ("j5_marcador_sin_marcador", "j5_marcador_nonce_distinto", "j5_marcador_ruta_relativa",
                  "j5_marcador_ruta_inexistente", "j5_marcador_permisos"):
        mode_j5_marcador(mode)
    elif mode in ("vida_estado_tardio", "vida_estado_nunca", "vida_senal", "vida_restauracion_falla"):
        mode_vida(mode)
    elif mode in ("j6_cuelgue_nunca", "j6_cuelgue_tarde"):
        mode_j6_cuelgue(mode)
    elif mode == "j6_pane_died_hook":
        mode_j6_pane_died_hook()
    elif mode == "j6_mensajes_rc":
        mode_j6_mensajes()
    elif mode in ("j6_identidad_relanzamiento", "j6_identidad_auditoria"):
        mode_j6_identidad_lanzada(mode)
    elif mode == "j6_acreditacion_forjada":
        mode_j6_acreditacion_forjada()
    elif mode == "j6_destinos_estaticos":
        mode_j6_destinos_estaticos()
    elif mode == "j7_n8_ventana_cambia":
        mode_j7_n8()
    elif mode == "j7_n9_acreditacion_rancia":
        mode_j7_n9()
    elif mode == "j7_pane_muere_tui":
        mode_j7_muere()
    elif mode == "j7_censo_destinos":
        mode_j7_censo()
    elif mode == "j7_eco_no_es_ack":
        mode_j7_eco()
    elif mode == "j8_s1_soft":
        mode_j8_s1_soft()
    elif mode == "j8_soft_dispatch":
        mode_j8_soft_dispatch()
    elif mode == "j8_s3_vida":
        mode_j8_s3_vida()
    elif mode == "j8_identidad_tras_ack":
        mode_j8_identidad_tras_ack()
    elif mode == "j8_relanzamiento_ventanas":
        mode_j8_relanzamiento_ventanas()
    elif mode == "fase_tmux_real":
        mode_fase_tmux_real()
    elif mode == "fase_misma_clave":
        mode_fase_misma_clave()
    elif mode == "fase_negativos":
        mode_fase_negativos()
    elif mode == "fase_dobles_pane_id":
        mode_fase_dobles_pane_id()
    elif mode.startswith("dispatch_"):
        mode_dispatch(mode)
    elif mode.startswith("auditoria_"):
        mode_audit(mode)
    elif mode.startswith("relanzamiento_"):
        mode_relanzamiento(mode)
    elif mode.startswith("preparar_"):
        mode_preparar(mode)
    elif mode == "orden_estatico":
        mode_orden()
    else:
        mode_identidad(mode)
    print(f"OK {mode}")


main()
