"""Checkout Python: sin promisor, mismo alcance y decisiones del SAST."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
TEXTO = (RAIZ / ".github/workflows/verify-python.yml").read_text()
PASOS = re.split(r"^      - name: ", TEXTO, flags=re.MULTILINE)[1:]


def paso(nombre, texto=PASOS):
    return next(bloque for bloque in texto if bloque.splitlines()[0].strip('"') == nombre)


def programa(bloque):
    contenido = bloque.split("        run: |\n", 1)[1]
    lineas = []
    for linea in contenido.splitlines():
        if linea and not linea.startswith("          "):
            break
        lineas.append(linea[10:])
    return "\n".join(lineas)


class CheckoutCompleto(unittest.TestCase):
    def test_checkout_sin_filtro_ni_ruta_y_credencial_temporal(self):
        checkout = paso("Checkout")
        self.assertIn("fetch-depth: 0", checkout)
        self.assertIn("persist-credentials: false", checkout)
        self.assertNotRegex(checkout, r"(?m)^\s+(?:filter|path|sparse-checkout):")
        nombres = [bloque.splitlines()[0] for bloque in PASOS]
        self.assertEqual(nombres[nombres.index("Checkout") + 1], "Comprobar checkout completo del caller")

    def ejecutar(self, codigo, entorno):
        with tempfile.TemporaryDirectory() as temporal:
            raiz = Path(temporal)
            git = raiz / "git"
            git.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = config ] && [ "$2" = --get-all ]; then\n'
                '  [ "${ERROR_CONFIG:-0}" = 0 ] || exit 3\n'
                '  [ "$3" = "${CLAVE:-}" ] && { printf "%s" "${VALOR:-}"; exit 0; }\n'
                '  exit 1\n'
                'fi\n'
                'case "$1" in\n'
                '  merge-base) printf "%s" baseline-pr;;\n'
                '  cat-file) exit 0;;\n'
                '  *) exit 99;;\n'
                'esac\n'
            )
            git.chmod(0o755)
            semgrep = raiz / "semgrep"
            semgrep.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\nexit "${SCAN_RC:-0}"\n')
            semgrep.chmod(0o755)
            return subprocess.run(
                ["bash", "-e", "-c", codigo], cwd=raiz, text=True, capture_output=True,
                env={**os.environ, "PATH": f"{raiz}:{os.environ['PATH']}", **entorno},
            )

    def test_guardia_normal_y_heredados_sin_reparacion(self):
        codigo = programa(paso("Comprobar checkout completo del caller"))
        self.assertEqual(self.ejecutar(codigo, {}).returncode, 0)
        for clave in ("remote.origin.promisor", "remote.origin.partialclonefilter"):
            for valor in ("true", "false", "blob:none", ""):
                with self.subTest(clave=clave, valor=valor):
                    resultado = self.ejecutar(codigo, {"CLAVE": clave, "VALOR": valor})
                    self.assertNotEqual(resultado.returncode, 0)
                    self.assertIn("::error::Clon parcial heredado", resultado.stdout)
                    self.assertIn(clave, resultado.stdout)
                    self.assertIn("#2537", resultado.stdout)
                    self.assertIn("recrear", resultado.stdout)
        resultado = self.ejecutar(codigo, {"ERROR_CONFIG": "1"})
        self.assertNotEqual(resultado.returncode, 0)
        self.assertIn("::error::No se pudo comprobar", resultado.stdout)

    def test_rutas_alcance_limpieza_y_auditoria_no_se_mueven(self):
        self.assertIn("run: bash .watson-ci-tooling/.github/actions/alcance/alcance.sh", TEXTO)
        self.assertIn("run: rm -rf .watson-ci-tooling", TEXTO)
        self.assertLess(TEXTO.index("run: rm -rf .watson-ci-tooling"), TEXTO.index("run: semgrep scan"))
        self.assertIn("find . -maxdepth 6 -name 'requirements*.txt'", TEXTO)
        self.assertNotIn("working-directory:", TEXTO)
        self.assertIn("run: semgrep scan --config \"p/secrets\" --error", TEXTO)

    def test_baseline_y_estrictez_del_programa_real(self):
        codigo = programa(paso("🛡️ SAST high/critical (diff-aware)"))
        entorno = {"EVENT_NAME": "pull_request", "BASE_SHA": "base", "BEFORE_SHA": "abc123",
                   "BASE_REF": "feature", "REF_NAME": "feature", "GATED_EXTRA": "",
                   "GATED_STRICT": "true"}
        casos = [({}, "--baseline-commit baseline-pr --error .", 1, 1),
                 ({"EVENT_NAME": "push", "BASE_REF": ""}, "--baseline-commit abc123 --error .", 1, 1),
                 ({"BASE_REF": "main"}, "--error .", 1, 1),
                 ({"BASE_REF": "main", "GATED_STRICT": "false"},
                  "--baseline-commit baseline-pr --error .", 1, 1),
                 ({"EVENT_NAME": "workflow_dispatch"}, "--error .", 1, 0),
                 ({"EVENT_NAME": "workflow_dispatch"}, "--error .", 2, 1)]
        for cambios, esperado, scan_rc, rc in casos:
            with self.subTest(cambios=cambios, scan_rc=scan_rc):
                resultado = self.ejecutar(codigo, {**entorno, **cambios, "SCAN_RC": str(scan_rc)})
                self.assertEqual(resultado.returncode, rc, resultado.stdout + resultado.stderr)
                self.assertIn(esperado, resultado.stdout)
                self.assertIn("--severity ERROR", resultado.stdout)
                if cambios.get("BASE_REF") == "main" and cambios.get("GATED_STRICT") != "false":
                    self.assertNotIn("--baseline-commit", resultado.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
