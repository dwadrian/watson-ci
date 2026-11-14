"""Las recetas nunca dejan filtros parciales en el workspace del caller."""
import re
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]


def comprobar(texto):
    assert not re.search(r"(?m)^\s*filter\s*:", texto), 'filtro parcial prohibido'
    assert not re.search(r"--filter(?:=|\s)", texto), 'clon parcial prohibido'
    pasos = re.split(r"(?m)^      - ", texto)
    callers = [paso for paso in pasos if 'uses: actions/checkout@' in paso
               and not re.search(r"(?m)^          (?:repository|path):", paso)]
    assert callers, 'falta checkout del caller'
    for paso in callers:
        assert re.search(r"(?m)^          fetch-depth: 0(?:\s|$)", paso), 'historia completa obligatoria'
        assert re.search(r"(?m)^          persist-credentials: false(?:\s|$)", paso), 'sin credencial persistida'
        indice = pasos.index(paso)
        siguiente = pasos[indice + 1]
        assert siguiente.startswith('name: Verificar clon completo offline\n'), 'verificación inmediata obligatoria'
        assert not re.search(r'(?m)^        (if|continue-on-error):', siguiente), 'verificación incondicional'
        assert siguiente.count('if configuracion.returncode != 1:') == 2, 'todos los ámbitos'
        for contrato in ("GIT_NO_LAZY_FETCH='1'", "GIT_ALLOW_PROTOCOL=''", "'--all', 'HEAD'",
                         'if objetos.returncode or ausentes:', 'configuracion.returncode != 1',
                         "nombre.endswith('.promisor')", "shallow.stdout.strip() != 'false'"):
            assert contrato in siguiente, 'verificación offline incompleta: ' + contrato
        assert not re.search(r'rmtree|rm -|\.unlink\(|\.rmdir\(', siguiente), 'borrado prohibido'
    tooling = [paso for paso in pasos if 'uses: actions/checkout@' in paso and 'path: .watson-ci-tooling' in paso]
    assert len(tooling) == 1, 'tooling separado obligatorio'
    assert 'fetch-depth: 1' in tooling[0], 'profundidad propia del tooling'
    siguiente = pasos[pasos.index(tooling[0]) + 1]
    assert siguiente.startswith('name: Verificar tooling offline (profundidad 1)\n'), 'verificar tooling separado'
    assert "Path(os.environ['GITHUB_WORKSPACE']) / '.watson-ci-tooling'" in siguiente
    assert "shallow.stdout.strip() not in ('true', 'false')" in siguiente


class CheckoutCompleto(unittest.TestCase):
    def test_recetas_y_mutantes(self):
        for ruta in sorted((RAIZ / '.github/workflows').glob('verify-*.yml')):
            texto = ruta.read_text()
            with self.subTest(receta=ruta.name):
                comprobar(texto)
                for filtro in ('blob:none', 'tree:0', "${{ inputs.filter }}"):
                    with self.assertRaisesRegex(AssertionError, 'filtro parcial'):
                        comprobar(texto.replace('          fetch-depth: 0',
                                                f'          filter: {filtro}\n          fetch-depth: 0', 1))
                with self.assertRaisesRegex(AssertionError, 'historia completa'):
                    comprobar(texto.replace('          fetch-depth: 0', '          fetch-depth: 1', 1))
                with self.assertRaisesRegex(AssertionError, 'credencial'):
                    comprobar(texto.replace('persist-credentials: false', 'persist-credentials: true'))
                for original, mutado in (
                        ('if objetos.returncode or ausentes:', 'if ausentes:'),
                        ("GIT_ALLOW_PROTOCOL=''", "GIT_ALLOW_PROTOCOL='https'"),
                        ('configuracion.returncode != 1', 'configuracion.returncode not in (0, 1)'),
                        ('name: Verificar clon completo offline', 'name: omitir verificación')):
                    with self.assertRaises(AssertionError):
                        comprobar(texto.replace(original, mutado, 1))


if __name__ == '__main__':
    unittest.main()
