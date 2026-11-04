#!/usr/bin/env python3
"""Verificador íntegro y check de F2; transporte y servicios externos doblados."""
import importlib.util
import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile


CLIENTE = r'''#!/usr/bin/python3
import os
import json
from pathlib import Path
import subprocess
import sys
tool = Path(sys.argv[0]).name
a = sys.argv[1:]
root = Path(os.environ['ETAPAS_ROOT'])
pkg = Path(os.environ['ETAPAS_PKG'])
def ejecutar(args, **kw):
    sys.exit(subprocess.run(args, **kw).returncode)
if tool == 'sudo':
    if '-l' in a: sys.exit(1)
    user = None
    while a and a[0].startswith('-'):
        if a[0] == '-u': user = a[1]; a = a[2:]
        else: a = a[1:]
    if user: os.environ['HOME'] = str(root/'actores'/user)
    if a[:2] == ['env', '-i']:
        i = 2
        while i < len(a) and '=' in a[i]: i += 1
        a[i:i] = ['PATH='+os.environ['PATH'], 'ETAPAS_ROOT='+str(root), 'ETAPAS_PKG='+str(pkg)]
    ejecutar(a)
if tool == 'getent':
    user = a[-1]
    home = root/'runner' if user == 'runner' else root/'actores'/user
    print(user+':x:1000:1000:fixture:'+str(home)+':/bin/bash'); sys.exit(0)
if tool == 'id':
    if a[0] == '-nG': print('docker'); sys.exit(0)
    ejecutar(['/usr/bin/id', *a])
if tool == 'systemctl': sys.exit(0)
if tool != 'incus': sys.exit(2)
states = {'golden-ejemplo':'STOPPED', 'vibe-channel-11':'RUNNING', 'vibe-channel-12':'RUNNING',
          'runner-ejemplo':'RUNNING', 'p1':'RUNNING', 'p2':'RUNNING'}
if a[:2] == ['storage', 'show']: print('driver: btrfs'); sys.exit(0)
if a[:2] == ['network', 'show']: print('name: incusbr0'); sys.exit(0)
if a[0] == 'query':
    if os.environ.get('ETAPAS_QUERY_FAIL'): sys.exit(1)
    instance, path = a[1].split('/instances/', 1)[1].split('/files?path=', 1)
    directory = root/'contenedores'/instance/path.lstrip('/')
    if not directory.is_dir(): sys.exit(1)
    print(json.dumps([p.name for p in directory.iterdir()])); sys.exit(0)
if a[0] == 'list':
    selected = [x for x in a if x.startswith('^')]
    names = [selected[0].strip('^$')] if selected else list(states)
    for name in names:
        if name in states: print(name+(','+states[name] if 'ns' in a else ''))
    sys.exit(0)
if a[0] != 'exec' or a[1] not in states: sys.exit(2)
container = a[1]
if states[container] != 'RUNNING': sys.exit(1)
remote = root/'contenedores'/container
a = a[3:]
def ruta(value):
    return str(remote/value.lstrip('/')) if value.startswith(('/home', '/root', '/var/lib')) else value
if a[0] == 'hostname': print(container); sys.exit(0)
if a[0] in ('systemctl', 'tailscale'): sys.exit(1)
if a[0] == 'stat':
    if a[1:3] == ['-c', '%U']: print('operador'); sys.exit(0)
if a[0] == 'su':
    user = a[2]; script = a[4]
    os.environ['HOME'] = str(remote/'home'/user)
    ejecutar(['/bin/bash', '-c', script, *a[5:]])
if a[0] == 'sudo':
    user = a[a.index('-u')+1]
    a = a[a.index('-u')+2:]
    os.environ['HOME'] = str(remote/'home'/user)
if a[:2] in (['bash', '-c'], ['bash', '-lc']):
    script = a[2]
    if '/dev/tcp/' in script: sys.exit(0)  # La salida TCP es un servicio doblado, nunca red.
    if script == 'command -v node && command -v claude && command -v codex':
        print('/fixture/node\n/fixture/claude\n/fixture/codex'); sys.exit(0)
    if script == 'claude --version': print('2.1.289'); sys.exit(0)
    if 'lg_preflight runner' in script:
        script = script.replace('/home/runner/repo', str(remote/'home/runner/repo'))
        os.environ['PF_HOME_ROOTS'] = str(remote/'root')+' '+str(remote/'home/runner')
    ejecutar(['/bin/bash', '-c', script, *[ruta(x) for x in a[3:]]])
if a[0] == 'find':
    p = subprocess.run([a[0], *[ruta(x) for x in a[1:]]], capture_output=True, text=True)
    print(p.stdout.replace(str(remote), ''), end=''); sys.exit(p.returncode)
if a[0] in ('test', 'ls', 'grep', 'jq', 'md5sum', 'git'):
    ejecutar([a[0], *[ruta(x) for x in a[1:]]])
sys.exit(2)
'''


def casos(package, tmp, expect, log=None):
    # Fuente única de datos de modelos de prueba autorizada por el validador.
    registry_template = (package/'skills/talent-channel-operation/tests/fixtures/modelos-cli-current.conf').read_text()
    fixture_models = dict(line.split('=', 1) for line in registry_template.splitlines())
    sonnet_model = fixture_models['SONNET_MODEL'].strip('"')
    def set_model(path, model):
        data = json.loads(path.read_text())
        data['model'] = model
        path.write_text(json.dumps(data))
    root = tmp/'etapas-reales'
    pkg = root/'paquete'
    shutil.copytree(package, pkg, ignore=shutil.ignore_patterns('.git', '__pycache__', 'estado', 'generado'))
    subprocess.run(['git', 'init', '-q', str(pkg)], check=True)
    bindir = root/'bin'
    bindir.mkdir()
    for tool in ('incus', 'sudo', 'systemctl', 'getent', 'id'):
        path = bindir/tool
        path.write_text(CLIENTE)
        path.chmod(0o755)
    ceo = pwd.getpwuid(os.getuid()).pw_name
    home = root/'actores'/ceo
    for user in (ceo, 'ejemplo-c1', 'ejemplo-m1', 'ejemplo-incus'):
        (root/'actores'/user).mkdir(parents=True, exist_ok=True)
    escrow = home/'.config/talent-channels'
    (escrow/'env').mkdir(parents=True)
    (escrow/'channel-profiles.list').write_text('vibe-channel-11=produccion\nvibe-channel-12=produccion\nrunner-ejemplo=runner\n')
    inherited = {key: value for key, value in os.environ.items()
                 if not key.startswith(('TC_', 'TCO_', 'TF_', 'BASH_FUNC_'))}
    env = dict(inherited, PATH=str(bindir)+':'+os.environ['PATH'], HOME=str(home), USER=ceo,
               ETAPAS_ROOT=str(root), ETAPAS_PKG=str(pkg), SECRET_DIR=str(escrow), MACHINE_NUM='1', COUNT='2',
               GOLDEN='golden-ejemplo', CUSER='operador', REPO_DIR='producto', REPO_URL='https://example.invalid/producto.git',
               TF_REPO_DIR='motor-paquete', TC_LOCAL_ONLY='yes', TF_CHANNEL_GIT_NAME_TMPL='{channel}',
               TF_CHANNEL_GIT_EMAIL_TMPL='{channel}@channels.invalid')
    for key in ('TC_NO_AUTOLOAD', 'TC_VERIFY_SCOPE', 'TCO_MODELOS_REGISTRO', 'SUDO_USER'):
        env.pop(key, None)
    settings = []
    for name in ('vibe-channel-11', 'vibe-channel-12', 'runner-ejemplo', 'p1', 'p2', 'golden-ejemplo'):
        remote = root/'contenedores'/name
        (remote/'root').mkdir(parents=True)
        h = remote/'home/operador'
        (h/'.codex').mkdir(parents=True)
        (h/'.claude').mkdir()
        (h/'producto/.git').mkdir(parents=True)
        (h/'motor-paquete').symlink_to(pkg, target_is_directory=True)
        (h/'.codex/config.toml').write_text('check_for_update_on_startup = false\ntrust_level = "trusted"\n')
        (h/'.claude.json').write_text('{"hasCompletedOnboarding":true}\n')
        s = h/'.claude/settings.json'
        s.write_text(json.dumps({'model':'', 'tui':'default', 'statusLine':{'type':'command', 'command':'statusline-ctx.sh'}}))
        settings.append(s)
        (h/'.bashrc').write_text('export DISABLE_AUTOUPDATER=1\nexport CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1\n')
        (h/'.tmux.conf').write_text('set -g alternate-screen off\n')
        for key, value in (('user.name', name), ('user.email', name+'@channels.invalid')):
            subprocess.run(['git', 'config', '--file', str(h/'.gitconfig'), key, value], check=True)
    runner = root/'contenedores/runner-ejemplo/home/runner/repo'
    runner.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(runner)], check=True)
    declared_url = dict(line.split('=', 1) for line in
                        (package/'instalacion/tests/fixtures/minima.resp').read_text().splitlines())['repo_url']
    subprocess.run(['git', '-C', str(runner), 'remote', 'add', 'origin', declared_url], check=True)
    (root/'runner').symlink_to(runner.parent, target_is_directory=True)
    verify = pkg/'skills/talent-channels/scripts/verify.sh'
    def ejecutar(args, e=None):
        p = subprocess.run(list(map(str, args)), env=e or env, capture_output=True, text=True, timeout=90)
        detail = 'CASO rc='+str(p.returncode)+' orden='+' '.join(map(str, args))+'\n'+p.stdout+p.stderr
        if log is None:
            print(detail, end='')
        else:
            with log.open('a') as output:
                output.write(detail)
        return p.returncode, p.stdout+p.stderr
    rc, out = ejecutar(['bash', verify, '--etapa', 'creado'])
    expect('creado sin registro: verde y modelo pendiente explícito', rc == 0 and 'PENDIENTE:' in out and 'FAIL=0' in out)
    for rel in ('.claude/.credentials.json', '.codex/auth.json', '.claude_token.env'):
        channel_credential = settings[0].parent.parent/rel
        channel_credential.write_text('{}')
        rc, out = ejecutar(['bash', verify, '--etapa', 'creado'])
        expect('creado rechaza ruta de credencial '+rel, rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
        channel_credential.unlink()
    set_model(settings[0], sonnet_model)
    rc, out = ejecutar(['bash', verify, '--etapa', 'creado'])
    expect('creado con modelo escrito: rojo', rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    set_model(settings[0], '')
    rc, out = ejecutar(['bash', verify])
    expect('completo sin registro: fallo cerrado', rc == 1 and 'ERROR modelos:' in out)
    registry = home/'.config/talent-channel-operation/modelos.conf'
    registry.parent.mkdir(parents=True)
    registry.write_text(registry_template)
    for ch in ('vibe-channel-11', 'vibe-channel-12'):
        rc, _ = ejecutar(['bash', pkg/'skills/talent-channel-operation/scripts/preparar-modelo-canal.sh', ch, 'operador'])
        expect('preparación real del modelo '+ch, rc == 0)
    rc, out = ejecutar(['bash', verify])
    expect('completo con registro y canal preparado: verde', rc == 0 and 'FAIL=0' in out and 'PENDIENTE:' not in out)
    rc, out = ejecutar(['bash', verify, '--etapa', 'preparado'])
    expect('etapa preparado explícita equivale a completo', rc == 0 and 'PENDIENTE:' not in out)
    # Ambas políticas conservan su modelo y rechazan documentos JSON no únicos.
    for stage in ('creado', 'acreditado', 'preparado'):
        originals = [s.read_text() for s in settings[:2]]
        if stage == 'creado':
            for s in settings[:2]:
                set_model(s, '')
        onboarding = settings[0].parent.parent/'.claude.json'
        for target in (settings[0], onboarding):
            original_json = target.read_text()
            for kind, content in (('dos', '{}\n'+original_json),
                                  ('basura', original_json+'\nbasura'),
                                  ('lista', '['+original_json+']'), ('vacio', '')):
                target.write_text(content)
                rc, out = ejecutar(['bash', verify, '--etapa', stage])
                expect(stage+' rechaza JSON '+target.name+' '+kind,
                       rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
            target.write_text(original_json)
        for s, original_json in zip(settings[:2], originals):
            s.write_text(original_json)
    token = settings[0].parent.parent/'.claude_token.env'
    token.write_text('{}')
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
    expect('acreditado permite token de canal', rc == 0 and 'FAIL=0' in out)
    token.unlink()
    credential = settings[0].parent/'.credentials.json'
    credential.write_text('{}')
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
    expect('acreditado permite login de canal y modelo vigente', rc == 0 and 'FAIL=0' in out)
    rc, out = ejecutar(['bash', verify, '--etapa', 'creado'])
    expect('creado rechaza canal acreditado', rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    rc, out = ejecutar(['bash', verify])
    expect('completo conserva rechazo del fichero de login', rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    credential.unlink()
    credential = settings[0].parent.parent/'.codex/auth.json'
    credential.write_text('{}')
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
    expect('acreditado permite login Codex de canal', rc == 0)
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'], dict(env, ETAPAS_QUERY_FAIL='1'))
    expect('acreditado consulta de golden fallida cierra gate', rc == 1 and 'FAIL  golden sin credencial' in out)
    golden_home = root/'contenedores/golden-ejemplo/home/operador'
    for rel in ('.claude/.credentials.json', '.codex/auth.json', '.claude_token.env'):
        golden_credential = golden_home/rel
        golden_credential.write_text('{}')
        rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
        expect('acreditado rechaza credencial de golden '+rel, rc == 1 and 'FAIL  golden sin credencial' in out)
        golden_credential.unlink()
    for model in ('manual', sonnet_model+'-otro', None, 42, 'sonnet'):
        set_model(settings[0], model)
        rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
        expect('acreditado exige igualdad del modelo '+repr(model), rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
        if model == 'sonnet':
            expect('alias posterior conserva rojo y orienta al doctor y preparación',
                   'primer despacho' in out and 'doctor de F7' in out and
                   'etiqueta del panel' in out and 'preparar-modelo-canal.sh' in out)
    set_model(settings[0], sonnet_model)
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'], dict(env, TCO_MODELOS_REGISTRO=str(root/'ausente')))
    expect('acreditado sin registro: diagnóstico y fallo cerrado', rc != 0 and 'ERROR modelos:' in out)
    credential.unlink()
    set_model(settings[0], '')
    rc, out = ejecutar(['bash', verify])
    expect('completo con canal sin preparar: rojo', rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    for args in (['--etapa'], ['--etapa', 'ajena'], ['--otro'], ['--etapa', 'creado', 'extra']):
        rc, _ = ejecutar(['bash', verify, *args])
        expect('opción inválida rechazada '+repr(args), rc == 2)
    rc, out = ejecutar(['bash', verify], dict(env, etapa='creado', TC_VERIFY_ETAPA='creado', TCO_MODELOS_REGISTRO=str(root/'ausente')))
    expect('etapa heredada no reduce verificación completa', rc == 1 and 'ERROR modelos:' in out)
    original = settings[0].read_text()
    for model in (None, 42, 'ausente'):
        data = json.loads(original)
        if model == 'ausente':
            data.pop('model')
        else:
            data['model'] = model
        settings[0].write_text(json.dumps(data))
        rc, out = ejecutar(['bash', verify, '--etapa', 'creado'])
        expect('creado rechaza tipo de modelo '+repr(model), rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    settings[0].write_text(original)
    # Positivo F2 propio: cuestionario, núcleo, envoltorio y preflight reales.
    for s in settings[:2]:
        set_model(s, '')
    registry.unlink()
    state = pkg/'instalacion/estado'
    state.mkdir(mode=0o700)
    text = (pkg/'instalacion/tests/fixtures/minima.resp').read_text().replace('usuario_ceo=operador', 'usuario_ceo='+ceo)
    answers = state/'respuestas.resp'
    answers.write_text(text)
    answers.chmod(0o600)
    clon = home/'producto'
    clon.mkdir()
    (state/'contexto.conf').write_text('respuestas='+str(answers)+'\nhome='+str(home)+'\nclon='+str(clon)+'\n')
    spec = importlib.util.spec_from_file_location('generador_etapas', pkg/'instalacion/instalacion.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    public = generator.render(dict(line.split('=', 1) for line in text.splitlines()), pkg, home)
    for rel in ('manifiestos/ejemplo.conf', 'manifiestos/ejemplo.perfil.tsv', 'ledger/cuentas.json'):
        path = pkg/rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(public[rel])
    rc, _ = ejecutar(['bash', pkg/'instalacion/scripts/manifiesto-nucleo.sh', '--generar'])
    expect('núcleo real del fixture F2 generado', rc == 0)
    rc, out = ejecutar(['bash', pkg/'instalacion/scripts/check-F2.sh'])
    expect('F2 con consumidores reales sin registro: verde', rc == 0 and 'PENDIENTE:' in out)
    set_model(settings[0], 'manual')
    rc, out = ejecutar(['bash', pkg/'instalacion/scripts/check-F2.sh'])
    expect('F2 con modelo manual: rojo del consumidor real', rc == 1 and 'FAIL  vibe-channel-11 claude baseline' in out)
    set_model(settings[0], '')
    rc, out = ejecutar(['bash', pkg/'instalacion/scripts/check-F2.sh'])
    expect('F2 restaurada sin registro: verde', rc == 0 and 'PENDIENTE:' in out)
    # Tramo del consumidor real tras F3: sesiones/logins representados por fixtures.
    registry.write_text(registry_template)
    for s in settings[:2]:
        set_model(s, sonnet_model)
        (s.parent/'.credentials.json').write_text('{}')
    rc, out = ejecutar(['bash', verify, '--etapa', 'acreditado'])
    expect('tras F2 y logins F3, consumidor acreditado de F5 verde', rc == 0 and 'FAIL=0' in out)
    for s in settings[:2]:
        (s.parent/'.credentials.json').unlink()
        set_model(s, '')
    registry.unlink()
    settings[0].write_text(settings[0].read_text().replace('"default"', '"alternate"'))
    rc, out = ejecutar(['bash', pkg/'instalacion/scripts/check-F2.sh'])
    expect('F2 creado conserva comprobación del renderer', rc == 1 and 'FAIL  vibe-channel-11 renderer:' in out)
    settings[0].write_text(settings[0].read_text().replace('"alternate"', '"default"'))
    profiles = escrow/'channel-profiles.list'
    profiles.write_text(profiles.read_text().replace('vibe-channel-11=produccion\n', ''))
    rc, out = ejecutar(['bash', pkg/'instalacion/scripts/check-F2.sh'])
    expect('F2 creado conserva comprobación de identidad', rc == 1 and 'SIN perfil declarado' in out)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--paquete', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--log', type=Path, help='diagnóstico íntegro del consumidor, separado del resumen de casos')
    args = parser.parse_args()
    if args.log is not None:
        args.log.write_text('')
        print('Diagnóstico íntegro del consumidor: '+str(args.log))
    counters = [0, 0]
    def expect(label, condition):
        counters[not condition] += 1
        print(('PASS ' if condition else 'FAIL ')+label)
    with tempfile.TemporaryDirectory(prefix='verify-etapas-') as td:
        casos(args.paquete, Path(td), expect, args.log)
    if sum(counters) != 66:
        print('FAIL conteo: esperados=66 ejecutados='+str(sum(counters)))
        counters[1] += 1
    print('PASS='+str(counters[0])+' FAIL='+str(counters[1]))
    raise SystemExit(bool(counters[1]))
