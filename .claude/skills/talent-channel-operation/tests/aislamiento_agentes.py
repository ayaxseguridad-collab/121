"""Guarda de aislamiento de las regresiones del lanzador: ningún caso resuelve ni ejecuta un agente REAL del sistema.

Fichero aparte de `launcher-dispatch-regressions.py`, con sus PROPIAS listas en literal: no importa nada de él, así que un
cambio en las constantes de la prueba no debilita la guarda. Contiene:
- el espejo del PATH del sistema SIN agentes (`espejo`) y las utilidades enlazadas de las variantes (`utilidades`);
- el entorno mínimo (`entorno_minimo`) y los asertos del entorno (`aserto_entorno`);
- los asertos estáticos: el PATH que reciben los panes, las dos funciones de medida por resolución, toda llamada a
  `subprocess` de la prueba con `env=` en lista blanca, y que ningún bloque extraído llame a `tco_load_tokens`;
- la sonda de los panes (`orden_sonda`, `leer_sonda`, `sonda_s1`) y los testigos de la guarda.

El aislamiento solo vale si el proceso se lanza con el entorno limpio desde fuera: el arnés del paquete (`tests/run-tests.sh`,
la batería de F0 por `clean_environment()` de `fases.py`) o el envoltorio de mutantes. La invocación directa sin entorno
limpio queda NO SOPORTADA / NO AISLADA."""
import ast
import glob
import hashlib
import inspect
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import time

# Listas LITERALES de la guarda (no se importan de la prueba).
AGENTES = ("codex", "codex-root", "claude", "claude-root")
DENEGADOS = AGENTES + ("node", "nodejs", "npx", "npm", "bun", "deno", "sudo", "su", "ssh", "incus", "lxc", "docker",
                       "corepack", "pnpm", "pnpx", "yarn", "bunx")
PREFIJOS_AGENTE = ("codex", "claude")
# Red de nombres de credencial: ninguna variable de entorno del mundo puede llevarlos en su nombre (salvo SECRET_DIR).
RED_CREDENCIALES = ("TOKEN", "SECRET", "PASSWORD", "API_KEY", "OAUTH")
NUNCA = ("LINEAR_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "SUPABASE_ACCESS_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
         "CLAUDE_CODE_OAUTH_TOKEN")
SISTEMA = ("/usr/bin", "/bin")

# Estado del modo en curso (lo fija `guarda_proceso`): su nombre, el directorio de testigos, si lo hay, y el registro en memoria
# de las etapas cuyo testigo ya se escribió en este proceso (ast, estatico y medida).
_ESTADO = {"modo": None, "testigos": None, "etapas": set(), "anotada": False}
_MINIMO = None


# ---------------------------------------------------------------------------------------------------------------------
# Rutas y HOME real

def _homes_reales():
    homes = {os.path.realpath(os.path.expanduser("~"))}
    try:
        homes.add(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    except KeyError:
        pass
    return {h for h in homes if h}


def _dentro(base, ruta):
    base, ruta = os.path.realpath(str(base)), os.path.realpath(str(ruta))
    return ruta == base or ruta.startswith(base.rstrip("/") + "/")


def _en_hogar_real(ruta):
    return any(_dentro(home, ruta) for home in _homes_reales())


def md5_helper():
    return hashlib.md5(Path(__file__).read_bytes()).hexdigest()


# ---------------------------------------------------------------------------------------------------------------------
# Espejo del sistema sin agentes y utilidades

def denegado(nombre):
    """¿El nombre es de un agente, de un lanzador de agentes o de una herramienta que puede lanzarlos?"""
    return nombre in DENEGADOS or nombre.startswith(PREFIJOS_AGENTE)


def _agentes_reales_del_sistema():
    """Rutas reales (realpath) de los agentes que existan en el PATH del proceso y en los directorios habituales de la
    instalación de usuario, globales de npm y /opt: ningún enlace del espejo ni de las utilidades puede apuntar a ellos."""
    home = os.path.expanduser("~")
    dirs = [os.path.join(home, ".local/bin"), "/usr/local/bin", os.path.join(home, ".npm-global/bin"), "/opt"]
    dirs += glob.glob(os.path.join(home, ".nvm/versions/*/bin")) + glob.glob("/opt/*/bin")
    reales = set()
    for nombre in AGENTES:
        encontrado = shutil.which(nombre)
        if encontrado:
            reales.add(os.path.realpath(encontrado))
        for d in dirs:
            candidato = os.path.join(d, nombre)
            if os.path.exists(candidato):
                reales.add(os.path.realpath(candidato))
    return reales


def _aserto_realpath(directorio):
    reales = _agentes_reales_del_sistema()
    for entrada in os.listdir(directorio):
        destino = os.path.realpath(os.path.join(directorio, entrada))
        assert destino not in reales, f"{directorio}/{entrada} apunta al mismo binario que un agente del sistema: {destino}"


def espejo(raiz, sistema=SISTEMA, nombre="sistema-sin-agentes"):
    """Directorio propio de la prueba con un enlace simbólico por cada entrada ejecutable de los directorios de `sistema` (en
    orden de PATH, gana el primero), SALVO los DENEGADOS y todo nombre que empiece por codex o claude. Una vez por mundo."""
    destino = Path(raiz) / nombre
    if destino.exists():
        return str(destino)
    destino.mkdir()
    for directorio in sistema:
        if not os.path.isdir(directorio):
            continue
        for entrada in sorted(os.listdir(directorio)):
            if denegado(entrada):
                continue
            origen = os.path.join(os.path.abspath(directorio), entrada)
            if os.path.lexists(destino / entrada) or not os.path.isfile(origen) or not os.access(origen, os.X_OK):
                continue
            os.symlink(origen, destino / entrada)
    _aserto_realpath(destino)
    return str(destino)


def utilidades(raiz, nombres, nombre="utilidades"):
    """Directorio propio con enlaces SOLO a las utilidades que el caso necesita (resueltas en el PATH del proceso de la
    prueba). Cada nombre se aserta contra los DENEGADOS y, por realpath, contra los agentes del sistema."""
    destino = Path(raiz) / nombre
    destino.mkdir()
    for util in nombres:
        assert not denegado(util), f"utilidad denegada: {util}"
        origen = shutil.which(util)
        assert origen, f"utilidad ausente en el PATH del proceso: {util}"
        os.symlink(origen, destino / util)
    _aserto_realpath(destino)
    return str(destino)


# ---------------------------------------------------------------------------------------------------------------------
# Entorno

def _aserto_dir_testigos(directorio, raiz=None):
    assert os.path.isdir(directorio), f"TCO_TESTIGO_DIR no es un directorio: {directorio}"
    modo = stat.S_IMODE(os.stat(directorio).st_mode)
    assert modo == 0o700, f"TCO_TESTIGO_DIR debe ser 0700 y es {modo:o}"
    assert not _en_hogar_real(directorio), "TCO_TESTIGO_DIR cae dentro del HOME real"
    assert raiz is None or not _dentro(raiz, directorio), "TCO_TESTIGO_DIR cae dentro de world.root"


def aserto_entorno(env, raiz=None, completo=False, inicial=True):
    """Fallo cerrado del entorno. Sin `raiz` mira solo el entorno del PROCESO (la red de nombres, SECRET_DIR y HOST_HOME si
    vienen, y TCO_TESTIGO_DIR si viene). Con `raiz` y `completo` exige el entorno del mundo: SECRET_DIR vacío de agents.conf,
    HOST_HOME, HOME, XDG_*, TCO_HOST_ENV y el resto, todos dentro de `raiz` y fuera del HOME real. Con `inicial` (al crear el
    mundo, antes del modo) ningún HOME contiene .codex ni .claude."""
    for clave in env:
        assert clave not in ("BASH_ENV", "ENV"), f"el entorno lleva {clave}"
        assert clave not in NUNCA and not clave.startswith("CODEX_"), f"el entorno lleva una credencial: {clave}"
        if clave != "SECRET_DIR":
            assert not any(red in clave for red in RED_CREDENCIALES), f"variable con nombre de credencial: {clave}"
    if env.get("TCO_TESTIGO_DIR"):
        _aserto_dir_testigos(env["TCO_TESTIGO_DIR"], raiz)
    for clave in ("SECRET_DIR", "HOST_HOME"):
        if env.get(clave):
            assert not _en_hogar_real(env[clave]), f"{clave} cae dentro del HOME real: {env[clave]}"
    if not completo:
        return
    assert raiz is not None
    for clave in ("SECRET_DIR", "HOST_HOME", "HOST_USER", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                  "TCO_HOST_ENV"):
        assert env.get(clave), f"{clave} vacía o sin definir en el entorno del mundo"
        if clave != "HOST_USER":
            assert _dentro(raiz, env[clave]), f"{clave} cae fuera de world.root: {env[clave]}"
            assert not _en_hogar_real(env[clave]), f"{clave} cae dentro del HOME real: {env[clave]}"
    assert not os.path.exists(os.path.join(env["SECRET_DIR"], "agents.conf")), "existe agents.conf en SECRET_DIR"
    for clave in ("HOME", "HOST_HOME") if inicial else ():
        for oculto in (".codex", ".claude"):
            assert not os.path.exists(os.path.join(env[clave], oculto)), f"{clave} contiene {oculto}"
    entradas = env.get("PATH", "").split(":")
    assert entradas and not set(entradas) & set(SISTEMA), f"el PATH del mundo lleva el sistema: {env.get('PATH')}"


def entorno_minimo(extra=None):
    """Entorno para las llamadas sin mundo: HOME temporal propio, vacío y fuera del HOME real, PATH = el espejo, sin
    BASH_ENV ni ENV. Se construye una vez por proceso."""
    global _MINIMO
    if _MINIMO is None:
        base = tempfile.TemporaryDirectory(prefix="aislamiento-")
        raiz = Path(base.name)
        (raiz / "home").mkdir()
        _MINIMO = (base, {"PATH": espejo(raiz), "HOME": str(raiz / "home"), "LANG": "C.UTF-8", "TERM": "dumb"})
    env = dict(_MINIMO[1])
    env.update(extra or {})
    aserto_entorno(env)
    assert not _en_hogar_real(env["HOME"]) and _dentro(_MINIMO[0].name, env["HOME"]), "HOME mínimo fuera del temporal"
    assert not set(env["PATH"].split(":")) & set(SISTEMA), "el PATH mínimo lleva el sistema"
    return env


# ---------------------------------------------------------------------------------------------------------------------
# Testigos de la guarda

def _escribe_exclusivo(ruta, texto):
    try:
        fd = os.open(ruta, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise AssertionError(f"el fichero ya existe: {ruta}")
    with os.fdopen(fd, "w") as fichero:
        fichero.write(texto)


def guarda_proceso(modo, testigos=None):
    """Guarda del PROCESO, al entrar en `main()` y antes de despachar el modo. Aserta el entorno del proceso y, SOLO después
    de que pase, escribe el testigo `<TCO_TESTIGO_DIR>/<modo>.testigo` (una línea: `<modo> <md5 de este fichero>`) con
    O_CREAT|O_EXCL y modo 0600; si el fichero ya existe, ROJO. Sin directorio de testigos no escribe nada."""
    aserto_entorno(dict(os.environ))
    _ESTADO["modo"], _ESTADO["testigos"], _ESTADO["etapas"], _ESTADO["anotada"] = modo, testigos or None, set(), False
    if testigos:
        _aserto_dir_testigos(testigos)
        _escribe_exclusivo(os.path.join(testigos, f"{modo}.testigo"), f"{modo} {md5_helper()}\n")


def _etapa(nombre):
    """Testigo de una ETAPA de la guarda (`ast`, `estatico` o `medida`): lo llama cada guarda DESPUÉS de su último assert, así
    que su fichero prueba que esa guarda llegó a correr y pasó. Se escribe UNA vez por modo, al PRIMER paso de la etapa en este
    proceso (registro en memoria): `<TCO_TESTIGO_DIR>/<modo>.<etapa>` con O_CREAT|O_EXCL y modo 0600, y si ya existía, ROJO.
    Las pasadas siguientes no escriben ni fallan. Sin directorio de testigos, o antes de `guarda_proceso` (que fija el modo),
    no escribe nada."""
    modo, testigos = _ESTADO["modo"], _ESTADO["testigos"]
    if not testigos or not modo or nombre in _ESTADO["etapas"]:
        return
    _escribe_exclusivo(os.path.join(testigos, f"{modo}.{nombre}"), f"{modo} {md5_helper()}\n")
    _ESTADO["etapas"].add(nombre)


def anotar(agentes):
    """Los agentes del sistema vistos por la sonda en una rama de shell normal se ADMITEN y se ANOTAN (solo el nombre y la ruta),
    en el orden fijo de los cuatro agentes. Con directorio de testigos: UN solo `<modo>.anotada`, creado con O_EXCL una única vez,
    con una línea `<modo> <nombre> <ruta>` por agente; el fichero no se reabre nunca. Sin él, una línea fija por agente en la
    salida estándar del modo: `ANOTADO R11c <modo> <ruta>`. `agentes` es una lista de pares (nombre, ruta)."""
    modo, testigos = _ESTADO["modo"], _ESTADO["testigos"]
    agentes = sorted(agentes, key=lambda par: AGENTES.index(par[0]))
    if testigos:
        if _ESTADO["anotada"]:
            return
        _escribe_exclusivo(os.path.join(testigos, f"{modo}.anotada"),
                           "".join(f"{modo} {nombre} {ruta}\n" for nombre, ruta in agentes))
        _ESTADO["anotada"] = True
    else:
        for nombre, ruta in agentes:
            print(f"ANOTADO R11c {modo} {ruta}", flush=True)


# ---------------------------------------------------------------------------------------------------------------------
# Asertos estáticos

def aserto_pane_path(valor):
    """(c) Con ese PATH ninguno de los cuatro agentes resuelve. Los nombres van LITERALES, no de la constante."""
    for n in ("codex", "codex-root", "claude", "claude-root"):
        assert shutil.which(n, path=valor) is None, f"el PATH del pane resuelve {n}: {valor}"
    assert "/usr/bin:/bin" not in valor, f"el PATH del pane es el del sistema: {valor}"


# Forma EXACTA de la última línea de las shells del servidor tmux de la prueba (coincidencia entera): env -i, bash sin login
# (sin -l ni --login), sin rc (--noprofile, --norc) y sin -i de bash. Cada valor es un token entre comillas simples o sin comillas.
_VALOR_SHELL = r"""('[^']*'|[^\s'"]+)"""
_FORMA_SHELL = re.compile(
    r'exec /usr/bin/env -i PATH="\$PATH" HOME=' + _VALOR_SHELL + r' XDG_CONFIG_HOME=' + _VALOR_SHELL
    + r' XDG_DATA_HOME=' + _VALOR_SHELL + r' TERM=dumb LANG=C\.UTF-8 /bin/bash --noprofile --norc "\$@"')


def aserto_estatico_shell(fichero, espejo_ruta, raiz, home, xdg_config, xdg_data, prefijo_pwd=False):
    """Regla 2 y R8 sobre una shell generada. En este orden: (1) el PATH que fija es EXACTAMENTE la ruta del espejo, citada (en
    S3 con el prefijo del directorio actual, que es el objeto del caso); (2) la ÚLTIMA línea tiene la forma exacta; (3) sus tres
    valores (HOME y los dos XDG) son un único token, EXACTAMENTE los esperados del mundo, dentro de `raiz` y fuera del HOME real;
    (4) solo entonces se quitan del texto el valor citado del espejo (en la línea del PATH) y esos tres valores (en la última
    línea, por los tramos de sus grupos de captura); (5) sobre el texto resultante, ningún absoluto que acabe en un agente
    fuera de `raiz` y ninguna llamada a node, nodejs, npx, npm ni bun."""
    texto = Path(fichero).read_text()
    valores = re.findall(r"^export PATH=(.*)$", texto, re.MULTILINE)
    assert len(valores) == 1, f"{fichero}: debe fijar PATH exactamente una vez: {valores}"
    esperado = ('"$PWD/bin":' if prefijo_pwd else "") + shlex.quote(espejo_ruta)
    assert valores[0] == esperado, f"{fichero}: PATH {valores[0]!r} distinto del espejo {esperado!r}"
    aserto_pane_path(espejo_ruta)
    assert "/usr/bin:/bin" not in texto, f"{fichero}: lleva el PATH del sistema"
    lineas = texto.splitlines()
    forma = _FORMA_SHELL.fullmatch(lineas[-1]) if lineas else None
    assert forma, f"{fichero}: la última línea no tiene la forma exacta de la shell (env -i, bash --noprofile --norc): {lineas[-1:]!r}"
    for nombre, grupo, valor_mundo in (("HOME", 1, home), ("XDG_CONFIG_HOME", 2, xdg_config), ("XDG_DATA_HOME", 3, xdg_data)):
        fichas = shlex.split(forma.group(grupo))
        assert len(fichas) == 1, f"{fichero}: {nombre} no es un único token de shell: {forma.group(grupo)!r}"
        assert fichas[0] == valor_mundo, f"{fichero}: {nombre}={fichas[0]!r} distinto del valor del mundo {valor_mundo!r}"
        assert _dentro(raiz, fichas[0]) and not _en_hogar_real(fichas[0]), \
            f"{fichero}: {nombre}={fichas[0]!r} cae fuera de world.root o dentro del HOME real"
    ultima = lineas[-1]
    for inicio, fin in reversed([forma.span(1), forma.span(2), forma.span(3)]):
        ultima = ultima[:inicio] + ultima[fin:]
    mirar = []
    for linea in lineas[:-1]:
        mirar.append(linea.replace(shlex.quote(espejo_ruta), "") if linea.startswith("export PATH=") else linea)
    texto = "\n".join(mirar + [ultima])
    for ruta in re.findall(r"(?<![\w.-])(/[^\s'\"]*/(?:codex|codex-root|claude|claude-root))(?![\w-])", texto):
        assert _dentro(raiz, ruta), f"{fichero}: ruta absoluta de un agente fuera del mundo: {ruta}"
    assert not re.search(r"\b(node|nodejs|npx|npm|bun)\b", texto), f"{fichero}: llama a node, npx, npm o bun"
    _etapa("estatico")


def aserto_estatico_s1(env, espejo_ruta):
    """S1: FAKE_SHELL_PATH definida, no vacía e igual al espejo TAL CUAL (es una variable de entorno, no texto de shell)."""
    valor = env.get("FAKE_SHELL_PATH")
    assert valor, "FAKE_SHELL_PATH sin definir o vacía"
    assert valor == espejo_ruta, f"FAKE_SHELL_PATH {valor!r} distinto del espejo {espejo_ruta!r}"
    aserto_pane_path(valor)
    _etapa("estatico")


def _aserto_texto_r11(texto, nombre):
    assert not re.search(r"\b(lanza_real|relanza)\s*\(", texto), f"{nombre}: lanza un agente por nombre"
    assert "send-keys" not in texto, f"{nombre}: teclea en un pane"
    assert not re.search(r"\b(exec|eval)\b", texto), f"{nombre}: lleva exec o eval"
    assert "$(" not in texto and "`" not in texto, f"{nombre}: lleva una sustitución de órdenes"
    for coincidencia in re.finditer(r"(?:codex|claude)[\w.-]*", texto):
        previo = texto[:coincidencia.start()]
        assert previo.endswith(("command -v ", "type -P ")), \
            f"{nombre}: el nombre {coincidencia.group(0)!r} no va tras command -v ni type -P"
    assert not re.search(r";\s*(?:/|[\w./-]*(?:codex|claude))", texto), f"{nombre}: un ';' seguido de ruta o agente"


def aserto_r11(*funciones):
    """R11 (b) y P1 sobre el texto de las ramas de shell normal: no lanzan ningún agente por nombre. Los nombres codex y
    claude solo pueden ir tras `command -v ` o `type -P `; el texto no lleva `$(`, comillas invertidas, exec, eval ni `;`
    seguido de una ruta o de un nombre de agente."""
    for funcion in funciones:
        _aserto_texto_r11(inspect.getsource(funcion), funcion.__name__)
    _etapa("estatico")


def aserto_orden_medida(orden):
    """P1 sobre la PLANTILLA de la orden de medida (la que construye `orden_medida`), con el marcador `DESTINO-MEDIDA` en el
    lugar del destino; no recibe la orden final con la ruta ya sustituida."""
    _aserto_texto_r11(orden, "orden de medida")
    _etapa("medida")


def orden_medida(cli, destino, raiz):
    """Construye la orden de medida de la resolución de un agente. Aserta que `cli` es uno de los AGENTES y que el destino cae
    dentro de `raiz`; pasa P1 (`aserto_orden_medida`) sobre la PLANTILLA, con un marcador fijo en lugar de la ruta de destino
    (la ruta del mundo puede llevar cualquier nombre), y devuelve la orden con el destino ya citado."""
    assert cli in AGENTES, f"orden de medida: {cli!r} no es uno de los agentes"
    assert _dentro(raiz, destino), f"orden de medida: el destino {destino} cae fuera de world.root"
    plantilla = f"command -v {cli} > DESTINO-MEDIDA; echo rc=$? >> DESTINO-MEDIDA; sleep 600"
    aserto_orden_medida(plantilla)
    return plantilla.replace("DESTINO-MEDIDA", shlex.quote(str(destino)))


def aserto_socket_tmux(salida, raiz):
    """H2: el servidor tmux que arrancó la prueba es el del socket PROPIO del mundo (por realpath), no el por defecto. Recibe la
    salida de la consulta del socket del servidor. No escribe ninguna etapa."""
    assert os.path.realpath(salida.strip()) == os.path.realpath(Path(raiz) / "tmux.sock"), \
        f"el servidor tmux no es el del socket del mundo: {salida.strip()!r}"


def aserto_sin_carga_de_tokens(texto, nombre):
    """D7: ningún bloque que la prueba extrae de los guiones del producto llama a `tco_load_tokens`."""
    assert "tco_load_tokens" not in texto, f"el bloque {nombre} contiene tco_load_tokens"
    _etapa("estatico")


_CON_ENV = {("subprocess", f) for f in ("run", "Popen", "check_output", "check_call", "call")}
_PROHIBIDAS = {("subprocess", "getoutput"), ("subprocess", "getstatusoutput")} | {
    ("os", f) for f in ("system", "popen", "putenv", "unsetenv", "getenv", "execv", "execve", "execl", "execle", "execlp",
                        "execlpe", "execvp", "execvpe", "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve",
                        "spawnvp", "spawnvpe", "posix_spawn", "posix_spawnp")}


def _nombre_llamada(func):
    if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
        return (func.value.id, func.attr)
    if isinstance(func, ast.Name):
        return ("", func.id)
    return ("", "")


def _es_os_environ(nodo):
    return (isinstance(nodo, ast.Attribute) and isinstance(nodo.value, ast.Name) and nodo.value.id == "os"
            and nodo.attr in ("environ", "environb"))


def _forma_permitida(nodo, pila, profundidad=0):
    """Formas permitidas para `env=`: world.env, self.env, dict(<forma permitida>, …), entorno_minimo(…) o un nombre local
    asignado SOLO desde esas formas."""
    if profundidad > 6:
        return False
    if isinstance(nodo, ast.Attribute):
        return isinstance(nodo.value, ast.Name) and nodo.value.id in ("world", "self") and nodo.attr == "env"
    if isinstance(nodo, ast.Call):
        modulo, nombre = _nombre_llamada(nodo.func)
        if nombre == "entorno_minimo" and modulo in ("", "aislamiento_agentes"):
            return True
        return (modulo, nombre) == ("", "dict") and bool(nodo.args) and _forma_permitida(nodo.args[0], pila, profundidad + 1)
    if isinstance(nodo, ast.Name):
        for ambito in reversed(pila):
            asignaciones = [a for a in ast.walk(ambito) if isinstance(a, ast.Assign)
                            and any(isinstance(t, ast.Name) and t.id == nodo.id for t in a.targets)]
            if asignaciones:
                return all(_forma_permitida(a.value, pila, profundidad + 1) for a in asignaciones)
        return False
    return False


# Una sola fuente: los nombres vetados salen de _CON_ENV y _PROHIBIDAS (sus segundos elementos), más los prefijos exec, spawn y
# posix_spawn.
_VETADOS = frozenset(nombre for _, nombre in _CON_ENV | _PROHIBIDAS)
_NOMBRES_DINAMICOS = ("globals", "vars", "locals", "eval", "exec", "compile", "__import__", "getattr", "setattr",
                      "importlib", "builtins", "__builtins__")
_MODULOS_PROHIBIDOS = ("pty", "multiprocessing", "asyncio", "importlib", "builtins", "posix", "_posixsubprocess", "ctypes")
# S3: lista blanca CERRADA de imports del fichero de prueba, todos sin alias, y su único from-import. Para añadir uno se cambia
# esta lista, y con ella el md5 del helper.
_IMPORTS_PERMITIDOS = ("aislamiento_agentes", "ast", "hashlib", "os", "pwd", "re", "shlex", "shutil", "signal", "subprocess",
                       "sys", "tempfile", "threading", "time")
_FROM_IMPORT_PERMITIDO = ("pathlib", "Path")


def _vetado(nombre):
    return nombre in _VETADOS or nombre.startswith(("exec", "spawn", "posix_spawn"))


def _cadena(func):
    """Segmentos de una cadena de atributos (`a.b.c` → [a, b, c]); el primero es un nombre solo si la cadena nace en uno."""
    segmentos = []
    while isinstance(func, ast.Attribute):
        segmentos.append(func.attr)
        func = func.value
    if isinstance(func, ast.Name):
        segmentos.append(func.id)
    return segmentos[::-1]


def _aserto_alias(arbol, ruta, problemas):
    """E1, alias de los módulos: añade a `problemas` (a) las llamadas vetadas por un segmento os o subprocess que no es la base
    literal, (b) todo uso de os o subprocess que no sea la base directa de un atributo, (c) os.X o subprocess.X vetados usados
    como valor, (e) los nombres y atributos con los que se llegaría a un módulo sin nombrarlo, e importar os|subprocess con
    alias, o importar pty, multiprocessing, asyncio, importlib o builtins."""
    bases = {id(n.value) for n in ast.walk(arbol) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)}
    funciones = {id(n.func) for n in ast.walk(arbol) if isinstance(n, ast.Call)}
    for n in ast.walk(arbol):
        linea = getattr(n, "lineno", 0)
        if isinstance(n, ast.Import):
            for alias in n.names:
                modulo = alias.name.split(".")[0]
                if alias.asname and modulo in ("os", "subprocess"):
                    problemas.append(f"{ruta.name}:{linea}: importa {alias.name} con alias")
                if modulo in _MODULOS_PROHIBIDOS:
                    problemas.append(f"{ruta.name}:{linea}: importa {alias.name}")
        if isinstance(n, ast.ImportFrom) and (n.module or "").split(".")[0] in _MODULOS_PROHIBIDOS:
            problemas.append(f"{ruta.name}:{linea}: importa nombres de {n.module}")
        if isinstance(n, ast.Name):
            if n.id in ("os", "subprocess") and id(n) not in bases:
                problemas.append(f"{ruta.name}:{linea}: usa el nombre {n.id} fuera de la base de un atributo")
            if n.id in _NOMBRES_DINAMICOS:
                problemas.append(f"{ruta.name}:{linea}: usa el nombre {n.id}")
        if isinstance(n, ast.Attribute):
            if n.attr == "modules":
                problemas.append(f"{ruta.name}:{linea}: usa el atributo modules")
            if isinstance(n.value, ast.Name) and n.value.id in ("os", "subprocess") and _vetado(n.attr) \
                    and id(n) not in funciones:
                problemas.append(f"{ruta.name}:{linea}: {n.value.id}.{n.attr} usado como valor")
        if isinstance(n, ast.Call):
            cadena = _cadena(n.func)
            if cadena and _vetado(cadena[-1]) and any(s in ("os", "subprocess") for s in cadena[:-1]) \
                    and not (len(cadena) == 2 and cadena[0] in ("os", "subprocess")):
                problemas.append(f"{ruta.name}:{linea}: llamada {'.'.join(cadena)} por un os o subprocess que no es la base literal")


def _publicos_del_helper():
    """Nombres que la prueba puede usar de este módulo: sus funciones públicas de nivel superior y AGENTES. Salen del AST de
    ESTE fichero (`Path(__file__)`), no de una lista de la prueba."""
    arbol = ast.parse(Path(__file__).read_text(), __file__)
    publicos = {n.name for n in arbol.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                and not n.name.startswith("_")}
    return publicos | {"AGENTES"}


def _definidos(arbol):
    """S4, `definidos`: solo los nombres de un def o de una asignación de lambda que NO estén en el cuerpo de una clase, y cuyo
    nombre no se vuelva a ligar en NINGÚN otro sitio del fichero. Cuentan como ligadura:
    - una asignación, una asignación aumentada o una anotada;
    - un for o una comprehension;
    - un with … as;
    - un import;
    - un parámetro;
    - un except … as;
    - un walrus;
    - un global o un nonlocal;
    - un del.
    Si el nombre tiene cualquiera de esas, no está definido. Sirve cualquier ámbito (módulo, función o función anidada) salvo el
    cuerpo de una clase: un método no es candidato. No cuenta la propia ligadura del candidato (el nombre destino de su
    asignación de lambda)."""
    padres = {id(hijo): padre for padre in ast.walk(arbol) for hijo in ast.iter_child_nodes(padre)}

    def fuera_de_clase(nodo):
        return not isinstance(padres.get(id(nodo)), ast.ClassDef)

    candidatos = {n.name for n in ast.walk(arbol)
                  if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and fuera_de_clase(n)}
    propias = {}
    for a in ast.walk(arbol):
        if isinstance(a, ast.Assign) and isinstance(a.value, ast.Lambda) and fuera_de_clase(a):
            for t in a.targets:
                if isinstance(t, ast.Name):
                    candidatos.add(t.id)
                    propias[id(t)] = t.id
    ligados = {nombre for nombre in propias.values() if list(propias.values()).count(nombre) > 1}
    for n in ast.walk(arbol):
        if isinstance(n, ast.Name) and isinstance(n.ctx, (ast.Store, ast.Del)) and id(n) not in propias:
            ligados.add(n.id)
        elif isinstance(n, ast.arg):
            ligados.add(n.arg)
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            ligados.update(alias.asname or alias.name.split(".")[0] for alias in n.names)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            ligados.add(n.name)
        elif isinstance(n, (ast.Global, ast.Nonlocal)):
            ligados.update(n.names)
    return candidatos - ligados


def _llamada_permitida(func, definidos):
    """S4: una llamada de nombre vetado solo vale como os.X o subprocess.X (base Name literal), como world.run (base Name world)
    o como un nombre definido en el propio fichero con def o con una asignación de lambda."""
    if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
        return func.value.id in ("os", "subprocess") or (func.value.id == "world" and func.attr == "run")
    return isinstance(func, ast.Name) and func.id in definidos


def _aserto_cerrado(arbol, ruta, problemas):
    """E1, letra cerrada (S1-S7 y los atributos dunder): solo vale lo listado. Añade a `problemas`: S1 todo atributo llamado os
    o subprocess; S2 todo from-import de os o subprocess; S3 todo import fuera de la lista blanca; S4 toda llamada de nombre
    vetado con una base no permitida; S5 todo atributo vetado usado como valor; S6 todo atributo que empiece por «_» (y, aparte,
    los dunder); S7 todo uso de este módulo que no sea una función pública de nivel superior o AGENTES."""
    publicos = _publicos_del_helper()
    definidos = _definidos(arbol)
    funciones = {id(n.func) for n in ast.walk(arbol) if isinstance(n, ast.Call)}
    for n in ast.walk(arbol):
        linea = getattr(n, "lineno", 0)
        if isinstance(n, ast.Import):
            for alias in n.names:
                if alias.name not in _IMPORTS_PERMITIDOS or alias.asname:
                    problemas.append(f"{ruta.name}:{linea}: S3: import fuera de la lista blanca: {alias.name}"
                                     + (f" as {alias.asname}" if alias.asname else ""))
        if isinstance(n, ast.ImportFrom):
            for alias in n.names:
                if alias.name in ("os", "subprocess"):
                    problemas.append(f"{ruta.name}:{linea}: S2: from {n.module} import {alias.name} reexporta un módulo vetado")
            if not (n.level == 0 and n.module == _FROM_IMPORT_PERMITIDO[0]
                    and [(a.name, a.asname) for a in n.names] == [(_FROM_IMPORT_PERMITIDO[1], None)]):
                problemas.append(f"{ruta.name}:{linea}: S3: from-import fuera de la lista blanca: from {n.module} import "
                                 + ", ".join(a.name for a in n.names))
        if isinstance(n, ast.Attribute):
            if n.attr in ("os", "subprocess"):
                problemas.append(f"{ruta.name}:{linea}: S1: atributo {n.attr} sobre una base (solo vale como Name base)")
            if n.attr.startswith("__") and n.attr.endswith("__"):
                problemas.append(f"{ruta.name}:{linea}: usa el atributo dunder {n.attr}")
            if n.attr.startswith("_"):
                problemas.append(f"{ruta.name}:{linea}: S6: atributo {n.attr} que empieza por _")
            if _vetado(n.attr) and id(n) not in funciones and not (isinstance(n.value, ast.Name)
                                                                  and n.value.id in ("os", "subprocess")):
                problemas.append(f"{ruta.name}:{linea}: S5: atributo vetado {n.attr} usado como valor")
            if isinstance(n.value, ast.Name) and n.value.id == "aislamiento_agentes" and n.attr not in publicos:
                problemas.append(f"{ruta.name}:{linea}: S7: aislamiento_agentes.{n.attr} no es una función pública de nivel "
                                 "superior ni AGENTES")
        if isinstance(n, ast.Call):
            final = n.func.attr if isinstance(n.func, ast.Attribute) else n.func.id if isinstance(n.func, ast.Name) else None
            if final and _vetado(final) and not _llamada_permitida(n.func, definidos):
                problemas.append(f"{ruta.name}:{linea}: S4: llamada {final} con una base no permitida")


def aserto_ast(ruta):
    """E1 y B2: en el fichero de la prueba, TODA llamada a `subprocess` lleva `env=` con una forma permitida; ninguna
    llamada puede heredar el entorno (os.system, os.popen, getoutput…); y `os.environ` solo aparece en la lectura de
    TCO_TESTIGO_DIR (ni escrituras, ni copias, ni alias)."""
    ruta = Path(ruta)
    arbol = ast.parse(ruta.read_text(), str(ruta))
    problemas = []
    lecturas = set()
    for n in ast.walk(arbol):
        if (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "get"
                and _es_os_environ(n.func.value) and len(n.args) == 1 and not n.keywords
                and isinstance(n.args[0], ast.Constant) and n.args[0].value == "TCO_TESTIGO_DIR"):
            lecturas.add(id(n.func.value))
    for n in ast.walk(arbol):
        linea = getattr(n, "lineno", 0)
        if _es_os_environ(n) and id(n) not in lecturas:
            problemas.append(f"{ruta.name}:{linea}: usa os.environ")
        if isinstance(n, ast.Name) and n.id in ("environ", "environb"):
            problemas.append(f"{ruta.name}:{linea}: usa un alias de environ")
        if isinstance(n, ast.ImportFrom) and n.module in ("subprocess", "os"):
            problemas.append(f"{ruta.name}:{linea}: importa nombres de {n.module}")
    _aserto_alias(arbol, ruta, problemas)
    _aserto_cerrado(arbol, ruta, problemas)

    def recorre(nodo, pila):
        if isinstance(nodo, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            pila = pila + [nodo]
        if isinstance(nodo, ast.Call):
            llamada = _nombre_llamada(nodo.func)
            if llamada in _PROHIBIDAS:
                problemas.append(f"{ruta.name}:{nodo.lineno}: {'.'.join(llamada)} no permite controlar el entorno")
            elif llamada in _CON_ENV:
                valores = [k.value for k in nodo.keywords if k.arg == "env"]
                if len(valores) != 1 or not _forma_permitida(valores[0], pila):
                    problemas.append(f"{ruta.name}:{nodo.lineno}: {'.'.join(llamada)} sin env= en lista blanca")
        for hijo in ast.iter_child_nodes(nodo):
            recorre(hijo, pila)
    recorre(arbol, [arbol])
    assert not problemas, "entorno heredado en la prueba: " + "; ".join(problemas)
    _etapa("ast")


# ---------------------------------------------------------------------------------------------------------------------
# Sonda de los panes (R7)

def _cuerpo_sonda():
    """Lo que mide la sonda: un resultado `nombre=ruta` por cada agente, node y npx que resuelva con el PATH real, y una línea
    final FIN. El nombre consultado viaja junto a su ruta."""
    nombres = " ".join(AGENTES + ("node", "npx"))
    return f'for n in {nombres}; do p=$(command -v "$n") && echo "$n=$p"; done; echo FIN'


def orden_sonda(fichero):
    """Lo PRIMERO que ejecuta un pane: escribe en `fichero` (uno por pane) lo que resuelve cada nombre con su PATH real y una
    línea final FIN; después queda vivo."""
    return f"{{ {_cuerpo_sonda()}; }} > {shlex.quote(str(fichero))}; sleep 600"


def _parsea_sonda(lineas):
    """Pares (nombre, ruta) de las líneas `nombre=ruta` que escribió la sonda."""
    pares = []
    for linea in lineas:
        if not linea:
            continue
        nombre, separador, ruta = linea.partition("=")
        assert separador and nombre in AGENTES + ("node", "npx"), f"la sonda devolvió una línea ilegible: {linea!r}"
        pares.append((nombre, ruta))
    return pares


def _evalua_sonda(pares, raiz, rama_shell_normal):
    """Todo lo que resuelva tiene que ser un doble del mundo (dentro de `raiz`). En las dos ramas de shell normal se admiten y se
    anotan SOLO los agentes del sistema; node, npx o cualquier otra herramienta del sistema dan ROJO en cualquier rama."""
    admitidos = {}
    for nombre, ruta in pares:
        assert ruta.startswith("/"), f"la sonda ve algo que no es un ejecutable por ruta: {ruta!r}"
        if _dentro(raiz, ruta):
            continue
        assert rama_shell_normal, f"la sonda ve un agente o herramienta del SISTEMA en el pane: {ruta}"
        assert nombre in AGENTES, f"la sonda ve una herramienta del SISTEMA en el pane (solo se admiten los agentes): {nombre}={ruta}"
        admitidos.setdefault(nombre, ruta)
    if admitidos:
        anotar(list(admitidos.items()))


def _lee_sonda(fichero, espera):
    fin = time.monotonic() + espera
    while time.monotonic() < fin:
        if os.path.exists(fichero):
            contenido = Path(fichero).read_text().splitlines()
            if "FIN" in contenido:
                return _parsea_sonda(contenido[:contenido.index("FIN")])
        time.sleep(0.1)
    raise AssertionError(f"la sonda del pane no escribió su resultado: {fichero}")


def leer_sondas(ficheros, raiz, rama_shell_normal=False, espera=20.0):
    """Lee lo que escribió la sonda de CADA pane (un fichero por pane) y exige TODOS antes de seguir: si a uno le falta su FIN,
    ROJO. Después evalúa los resultados de todos juntos."""
    pares = []
    for fichero in ficheros:
        pares += _lee_sonda(fichero, espera)
    _evalua_sonda(pares, raiz, rama_shell_normal)
    return pares


def leer_sonda(fichero, raiz, rama_shell_normal=False, espera=20.0):
    """Lee lo que la sonda de UN pane escribió (ver `leer_sondas`)."""
    return leer_sondas([fichero], raiz, rama_shell_normal, espera)


def sonda_s1(env_mundo, shell_path, fake_home, raiz):
    """S1: la misma sonda con el MISMO entorno que el doble da al pane (la lista blanca del mundo y encima el PATH de la shell
    del servidor y el HOME del canal), en un subproceso aparte, sin pasar por el doble de tmux."""
    env = dict(env_mundo)
    env.update(PATH=shell_path, HOME=fake_home)
    aserto_entorno(env)
    resultado = subprocess.run(["/bin/bash", "-c", _cuerpo_sonda()], env=env, text=True, capture_output=True, timeout=30)
    lineas = resultado.stdout.splitlines()
    assert "FIN" in lineas, f"la sonda de S1 no terminó: {resultado}"
    pares = _parsea_sonda(lineas[:lineas.index("FIN")])
    _evalua_sonda(pares, raiz, False)
    return pares


# ---------------------------------------------------------------------------------------------------------------------
# Lanzadores generados (R8)

def aserto_lanzador(nombre, texto, destino, raiz):
    """R8 sobre el TEXTO FINAL de un lanzador generado, ANTES de escribirlo: ningún absoluto que acabe en un agente fuera de
    `raiz`, ninguna llamada a node, npx, npm ni bun (un `exec` del agente POR NOMBRE sí vale: el PATH es el espejo), y el
    directorio de destino cae, por realpath, DENTRO de `raiz`. Su etapa propia es `lanzador`."""
    assert _dentro(raiz, destino), f"lanzador {nombre}: el destino {destino} cae fuera de world.root"
    for ruta in re.findall(r"(?<![\w.-])(/[^\s'\"]*/(?:codex|codex-root|claude|claude-root))(?![\w-])", texto):
        assert _dentro(raiz, ruta), f"lanzador {nombre}: ruta absoluta de un agente fuera del mundo: {ruta}"
    assert not re.search(r"\b(node|nodejs|npx|npm|bun)\b", texto), f"lanzador {nombre}: llama a node, npx, npm o bun"
    _etapa("lanzador")
