#!/usr/bin/env bash
# Contratos de destino explícito y requisitos, sin asignar runners ni consultar servicios.
# Vacío/omitido, fallback hosted, grupo ajeno y etiquetas alojadas se rechazan estáticamente.
# Los intérpretes proceden de la imagen; jq permanece fijado por versión y hash.
# La conducta se ensaya con sh -e y stubs locales; los mutantes deben producir rojo.
# El fixture snapshot-checks.yml no es un workflow y no recibe triggers ni runners.
set -u
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null || { echo '⛔ falta python3 — el test no puede afirmar nada'; exit 1; }

# python3 -I: sin el cwd en sys.path. Solo stdlib (sin PyYAML: no se
# puede asumir instalado y el formato de las recetas es estable y lo controla este repo).
exec python3 -I "$RAIZ/tests/runs-on.test.py" "$RAIZ"
