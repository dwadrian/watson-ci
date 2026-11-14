"""Las recetas nunca dejan filtros parciales en el workspace del caller."""
import re
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]


def comprobar(texto):
    assert not re.search(r"(?m)^\s*filter\s*:", texto), 'filtro parcial prohibido'
    assert not re.search(r"--filter(?:=|\s)|partialclonefilter|promisor", texto), 'clon parcial prohibido'
    pasos = re.split(r"(?m)^      - ", texto)
    callers = [paso for paso in pasos if 'uses: actions/checkout@' in paso
               and not re.search(r"(?m)^          (?:repository|path):", paso)]
    assert callers, 'falta checkout del caller'
    for paso in callers:
        assert re.search(r"(?m)^          fetch-depth: 0(?:\s|$)", paso), 'historia completa obligatoria'
        assert re.search(r"(?m)^          persist-credentials: false(?:\s|$)", paso), 'sin credencial persistida'


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


if __name__ == '__main__':
    unittest.main()
