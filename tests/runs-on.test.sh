#!/usr/bin/env bash
# ==============================================================================
# runs-on.test.sh — ningún job de las recetas fija su runner; todos pasan por el input `runs-on`.
#
# POR QUÉ EXISTE (dwadrian/fabrica#2425, 2026-11-06):
# las tres recetas fijaban `runs-on: ubuntu-latest`. Al agotarse el tope de gasto de Actions, el job
# `seguridad` de makro_web no pudo correr y `ci-ok` quedó en rojo aunque TODO lo demás ya corría en
# runners propios. La regla de la fábrica es que todo job corra en nuestros runners, eligiéndolo con
# el input `runs-on`.
#
# QUÉ AFIRMA, por receta:
#   1. Cada job bajo `jobs:` tiene UN `runs-on:` y es exactamente RUNS_ON_ESPERADO. Un
#      `runs-on: ubuntu-latest` literal (el mutante del encargo) o un job nuevo que lo fije, rojo.
#   2. El input `runs-on` existe: type string, required false, y su default DECODIFICADO como JSON
#      es "ubuntu-latest" — sin el input, el runner es el de siempre.
#   3. El fallback `|| '"ubuntu-latest"'` de la expresión decodifica a lo mismo que el default. Sin
#      él, un caller que pasa `${{ vars.RUNS_ON }}` con la variable SIN definir manda '' (el default
#      NO se aplica a un input pasado vacío) y `fromJSON('')` revienta el job.
#   4. El primer paso de cada job es el de requisitos del runner (fallar rápido y con diagnóstico).
#   5. Toda receta que usa `jq` lo instala ANTES ella misma, versión y sha256 fijados: un runner
#      propio no lo trae de serie como ubuntu-latest.
#
# Y LOS AUTO-MUTANTES: el checker corre sobre copias mutadas de cada receta y TIENE que dar rojo.
# Un test que no ve fallar sus mutantes no demuestra que mire lo que dice mirar.
#
# Uso:  bash tests/runs-on.test.sh
# Exit: 0 = todo afirmado · 1 = alguna receta (o algún mutante) mal
# ==============================================================================
set -u
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null || { echo '⛔ falta python3 — el test no puede afirmar nada'; exit 1; }

# python3 -I: sin el cwd en sys.path. Solo stdlib (sin PyYAML: no se
# puede asumir instalado y el formato de las recetas es estable y lo controla este repo).
exec python3 -I "$RAIZ/tests/runs-on.test.py" "$RAIZ"
