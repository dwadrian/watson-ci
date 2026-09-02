#!/usr/bin/env bash
# ==============================================================================
# alcance-clasificacion.test.sh — un `.sh` no es documentación por vivir en `docs/`.
#
# POR QUÉ EXISTE, y por qué llega tarde:
# `coffee_framework_prod` lo reportó en `FEEDBACK-2026-08-18` y estuvo **14 días sin atender**.
# El `case` de `alcance.sh` era `docs/*|*.md`, y en POSIX el `*` **cruza la barra**, así que
# cualquier cosa bajo `docs/` contaba como documentación:
#
#   docs/scripts/deploy.sh              -> DOC   (salta SAST, tests y lint)
#   docs/scripts/verify-multiagent.sh   -> DOC   (idem)
#
# Esos dos NO son documentación: son **el código que distribuye el harness a 22 repos**. Un push
# que solo los tocara pasaba sin SAST.
#
# EL HUECO ES DE SAST, NO DE SECRETOS — y la distinción importa para no exagerarlo: `secrets` y
# `dep-audit` corren SIEMPRE por diseño, así que una clave pegada ahí se seguía viendo. Lo que se
# saltaba era el análisis estático del código.
#
# LO QUE ARREGLA, Y LO QUE NO PUEDE ROMPER:
# las extensiones **ejecutables** se evalúan ANTES que la ruta. Un `.md`, un ADR o un PNG bajo
# `docs/` siguen siendo documentación — que es el ahorro de minutos que el filtro existe para dar,
# y suspenderlo sería el error simétrico: *un check que suspende a los sanos se desactiva a la
# semana*.
#
# Uso:  bash tests/alcance-clasificacion.test.sh
# Exit: 0 = clasifica bien · 1 = algún caso mal
# ==============================================================================
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/alcance/alcance.sh"
[ -f "$SCRIPT" ] || { echo "⛔ no encuentro $SCRIPT"; exit 1; }

# Se extrae el `case` REAL del script y se ejercita, en vez de reimplementarlo aquí: un test que
# copia la regla mide su propia copia, no el fichero que corre en CI.
CASE_BODY=$(awk '/^      case "\$f" in/{f=1} f{print} /^      esac/{if(f) exit}' "$SCRIPT")
# H2 (auditor ofensivo, 2026-09-02): los backticks DENTRO de comillas dobles son sustitucion
# de comandos VIVA. `shellcheck` lo marca SC1073/SC1072 como ERROR, y ejecutado se comia la
# palabra: «no pude extraer el  de /ruta». La ruta OK nunca lo toca, asi que el fichero pasaba
# verde con su mensaje de fallo roto. Es el anti-patron que la doctrina de watson documenta,
# cometido DENTRO del gate. Comillas simples.
[ -n "$CASE_BODY" ] || { echo '⛔ no pude extraer el case de alcance.sh — el test no puede afirmar nada'; exit 1; }

clasifica() {
  f="$1"; NO_DOCS=0
  eval "$(printf '%s\n' "$CASE_BODY" | sed 's/^      //')"
  [ "$NO_DOCS" -eq 0 ] && echo DOC || echo CODIGO
}

fallos=0; total=0
comprueba() {  # $1 = ruta, $2 = esperado
  total=$((total + 1))
  got=$(clasifica "$1")
  if [ "$got" != "$2" ]; then
    printf '  🔴 %-44s esperaba %-6s y dio %s\n' "$1" "$2" "$got"; fallos=$((fallos + 1))
  else
    printf '  ✅ %-44s %s\n' "$1" "$got"
  fi
}

echo "== EL HUECO: código de distribución bajo docs/ =="
comprueba "docs/scripts/deploy.sh"            CODIGO
comprueba "docs/scripts/verify-multiagent.sh" CODIGO
comprueba "docs/scripts/setup-lib/helpers.sh" CODIGO

# H1 (auditor ofensivo, 2026-09-02): la version anterior de este test SOLO ejercitaba `.sh`, asi
# que las otras SIETE extensiones de la rama se podian borrar una a una con la suite en VERDE, y
# `*.sh` -> `*.sh*` tambien sobrevivia. Los casos `src/app.php` y `.github/workflows/ci.yml` NO
# cubren la rama: ya salian CODIGO por el `*)` de siempre, asi que mutarla no los mueve.
# Es "el control negativo tiene que demostrar la PROPIEDAD del check, no el estado del mundo".
echo "== CADA extensión de la rama, bajo docs/ (una por mutante) =="
comprueba "docs/x.php"                        CODIGO
comprueba "docs/x.py"                         CODIGO
comprueba "docs/x.js"                         CODIGO
comprueba "docs/x.mjs"                        CODIGO
comprueba "docs/x.bash"                       CODIGO
comprueba "docs/x.yml"                        CODIGO
comprueba "docs/x.yaml"                       CODIGO
# Y el limite SUPERIOR: `*.sh` no puede ensancharse a `*.sh*`, que se tragaria un `.shell`.
comprueba "docs/notas.shell"                  DOC

echo "== CONTROL NEGATIVO: la documentación sigue siendo documentación =="
comprueba "docs/README.md"                    DOC
comprueba "docs/patterns/anti-mock-guard.md"  DOC
comprueba "docs/adr/ADR-2026-01-01-x.md"      DOC
comprueba "docs/design/references/home.png"   DOC
comprueba "docs/bitacoras/BITACORA-1.md"      DOC
comprueba "CHANGELOG.md"                      DOC

echo "== CONTROL: el código de siempre no cambia =="
comprueba "scripts/deploy.sh"                 CODIGO
comprueba "src/app.php"                       CODIGO
comprueba ".github/workflows/ci.yml"          CODIGO

echo
if [ "$fallos" -eq 0 ]; then
  echo "✅ $total rutas clasificadas correctamente"
else
  echo "🔴 $fallos de $total mal clasificadas"
fi
exit $([ "$fallos" -eq 0 ] && echo 0 || echo 1)
