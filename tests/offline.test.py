"""Contratos offline y de admisión; solo Git local, sin asignar runners."""
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
RECETAS = sorted((RAIZ / '.github/workflows').glob('verify-*.yml'))


def scripts(texto):
    return [textwrap.dedent(bloque) for bloque in
            re.findall(r"          python3 -I - <<'PYTHON'\n(.*?)\n          PYTHON", texto, re.S)]


def destino(valor):
    if not valor:
        raise ValueError('destino obligatorio')
    configuracion = json.loads(valor)
    if not isinstance(configuracion, dict) or configuracion.get('group') != 'ci-comun':
        raise ValueError('grupo obligatorio')
    etiquetas = configuracion.get('labels')
    if not isinstance(etiquetas, list) or 'self-hosted' not in etiquetas:
        raise ValueError('capacidades obligatorias')
    if any(prefijo in json.dumps(etiquetas) for prefijo in ('ubuntu-', 'windows-', 'macos-')):
        raise ValueError('alojado prohibido')
    return configuracion


class Offline(unittest.TestCase):
    def setUp(self):
        self.temporal = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporal.cleanup)
        self.raiz = Path(self.temporal.name).resolve()
        self.repo = self.raiz / 'caller'
        self.repo.mkdir()
        self.entorno = {clave: valor for clave, valor in os.environ.items() if not clave.startswith('GIT_')}
        self.entorno.update(HOME=str(self.raiz), GIT_CONFIG_NOSYSTEM='1',
                            GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_LAZY_FETCH='1',
                            GITHUB_WORKSPACE=str(self.repo))
        self.git('init', '-q')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '--allow-empty', '-qm', 'completo')

    def git(self, *argumentos):
        return subprocess.run(['git', '-C', str(self.repo), *argumentos], env=self.entorno,
                              capture_output=True, text=True, check=True).stdout.strip()

    def ejecutar(self, codigo, **variables):
        return subprocess.run([sys.executable, '-I', '-'], input=codigo,
                              env=dict(self.entorno, **variables), capture_output=True,
                              text=True, timeout=30)

    def test_las_tres_recetas_comparten_contrato(self):
        candidatos = [scripts(ruta.read_text()) for ruta in RECETAS]
        self.assertEqual(len(candidatos), 3)
        self.assertTrue(all(len(par) == 2 for par in candidatos))
        self.assertTrue(all(par == candidatos[0] for par in candidatos))
        caller, tooling = candidatos[0]
        self.assertNotIn('.watson-ci-tooling', caller)
        self.assertIn("/ '.watson-ci-tooling'", tooling)
        self.assertNotEqual(caller, tooling)

    def test_ambitos_false_vacio_no_modifican_ni_reparan(self):
        codigo = scripts(RECETAS[0].read_text())[0]
        self.assertEqual(self.ejecutar(codigo).returncode, 0)
        for ambito in ('local', 'global', 'system', 'worktree', 'command', 'include'):
            for clave in ('remote.origin.promisor', 'remote.origin.partialclonefilter', 'extensions.partialclone'):
                for valor in ('', 'false'):
                    with self.subTest(ambito=ambito, clave=clave, valor=valor):
                        archivo = self.raiz / 'marca'
                        self.git('config', '--file', str(archivo), clave, valor)
                        variables = {}
                        if ambito == 'local':
                            destino_config = self.repo / '.git/config'
                            previo = destino_config.read_bytes()
                            self.git('config', clave, valor)
                        elif ambito == 'worktree':
                            destino_config = self.repo / '.git/config.worktree'
                            previo = None
                            destino_config.write_bytes(archivo.read_bytes())
                        elif ambito == 'include':
                            destino_config = self.repo / '.git/config'
                            previo = destino_config.read_bytes()
                            self.git('config', 'include.path', str(archivo))
                        elif ambito == 'command':
                            variables.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=clave,
                                             GIT_CONFIG_VALUE_0=valor)
                        else:
                            variables['GIT_CONFIG_' + ambito.upper()] = str(archivo)
                            variables['GIT_CONFIG_NOSYSTEM'] = '0'
                        estado = {ruta: ruta.read_bytes() for ruta in self.repo.rglob('*') if ruta.is_file()}
                        self.assertNotEqual(self.ejecutar(codigo, **variables).returncode, 0)
                        self.assertEqual(estado, {ruta: ruta.read_bytes() for ruta in self.repo.rglob('*') if ruta.is_file()})
                        if ambito in ('local', 'include', 'worktree'):
                            if previo is None:
                                destino_config.unlink()
                            else:
                                destino_config.write_bytes(previo)
                        archivo.unlink()

    def test_blob_historico_ausente_promisor_shallow_alternates(self):
        codigo = scripts(RECETAS[0].read_text())[0]
        (self.repo / 'viejo').write_text('historia')
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'blob')
        blob = self.git('rev-parse', 'HEAD:viejo')
        self.git('rm', 'viejo')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'actual')
        self.assertEqual(self.ejecutar(codigo).returncode, 0)
        objeto = self.repo / '.git/objects' / blob[:2] / blob[2:]
        contenido = objeto.read_bytes()
        objeto.unlink()
        self.assertNotEqual(self.ejecutar(codigo).returncode, 0)
        self.assertFalse(objeto.exists())
        objeto.write_bytes(contenido)
        for archivo, contenido in (('objects/pack/residual.promisor', ''),
                                   ('shallow', self.git('rev-parse', 'HEAD') + '\n'),
                                   ('objects/info/alternates', str(self.raiz / 'otro'))):
            marca = self.repo / '.git' / archivo
            marca.parent.mkdir(parents=True, exist_ok=True)
            marca.write_text(contenido)
            self.assertNotEqual(self.ejecutar(codigo).returncode, 0)
            self.assertTrue(marca.exists())
            marca.unlink()

    def test_tooling_shallow_no_se_confunde_con_caller(self):
        caller, tooling = scripts(RECETAS[0].read_text())
        ruta_tooling = self.repo / '.watson-ci-tooling'
        self.git('clone', '--depth=1', self.repo.as_uri(), str(ruta_tooling))
        self.assertEqual(self.ejecutar(caller).returncode, 0)
        self.assertEqual(self.ejecutar(tooling).returncode, 0)
        config = ruta_tooling / '.git/config'
        config.write_text(config.read_text() + '\n[remote "origin"]\n promisor = false\n')
        self.assertEqual(self.ejecutar(caller).returncode, 0)
        self.assertNotEqual(self.ejecutar(tooling).returncode, 0)

    def test_error_git_es_rojo_y_mutante_aceptarlo_es_verde(self):
        codigo = scripts(RECETAS[0].read_text())[0]
        binarios = self.raiz / 'bin'
        binarios.mkdir()
        git_falso = binarios / 'git'
        git_falso.write_text('#!/bin/sh\ncase "$*" in\n*config*) exit 1;;\n'
                             '*rev-parse*) echo false; exit 0;;\n*rev-list*) exit 23;;\nesac\nexit 99\n')
        git_falso.chmod(0o755)
        self.assertNotEqual(self.ejecutar(codigo, PATH=str(binarios)).returncode, 0)
        mutante = codigo.replace('if objetos.returncode or ausentes:', 'if ausentes:')
        self.assertNotEqual(mutante, codigo)
        self.assertEqual(self.ejecutar(mutante, PATH=str(binarios)).returncode, 0)

    def test_destino_requerido_solo_fixtures_estaticos(self):
        bueno = '{"group":"ci-comun","labels":["self-hosted","linux","x64","python"]}'
        self.assertEqual(destino(bueno)['group'], 'ci-comun')
        for valor in (None, '', 'null', '"ubuntu-latest"', '[]', '{}',
                      '{"group":"otro","labels":["self-hosted"]}',
                      '{"group":"ci-comun","labels":"self-hosted"}',
                      '{"group":"ci-comun","labels":["ubuntu-latest"]}',
                      '{"group":"ci-comun","labels":["self-hosted","macos-latest"]}'):
            with self.subTest(valor=valor), self.assertRaises(ValueError):
                destino(valor)
        for ruta in RECETAS:
            texto = ruta.read_text()
            entrada = texto.split('      runs-on:\n', 1)[1].split('      gated-branches:', 1)[0]
            self.assertIn('required: true', entrada)
            self.assertNotIn('default:', entrada)
            expresion = re.search(r'^    runs-on: (.*)$', texto, re.M)[1]
            for contrato in (".group == 'ci-comun'", "startsWith(toJSON(fromJSON(inputs.runs-on).labels), '[')",
                             "contains(fromJSON(inputs.runs-on).labels, 'self-hosted')",
                             "fromJSON('ERROR_RUNS_ON_REQUIERE_GRUPO_Y_CAPACIDAD')"):
                self.assertIn(contrato, expresion)
            self.assertNotIn('ubuntu-latest', texto)

    def test_publico_sin_workflows_ejecutables(self):
        rutas = list((RAIZ / '.github/workflows').glob('*.y*ml'))
        self.assertEqual(set(rutas), set(RECETAS))
        for ruta in rutas:
            triggers = ruta.read_text().split('on:\n', 1)[1].split('\nconcurrency:', 1)[0]
            self.assertIn('  workflow_call:', triggers)
            self.assertNotRegex(triggers, r'(?m)^  (pull_request|push|workflow_dispatch|schedule)[: ]')
        fixture = (RAIZ / 'tests/fixtures/snapshot-checks.yml').read_text()
        self.assertNotRegex(fixture, r'(?m)^(jobs|on):|runs-on:')


if __name__ == '__main__':
    unittest.main()
