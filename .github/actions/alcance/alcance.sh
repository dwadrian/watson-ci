#!/bin/bash
# =============================================================================
# ¿El push tocó SOLO documentación?
#
# FUENTE ÚNICA. La consumen dos caminos, para que no exista una copia que derive:
#   - las recetas reutilizables (`verify-*.yml`), vía el checkout del tooling
#   - la composite action `.github/actions/alcance`, para workflows LOCALES de
#     cada repo (los que no heredan de una receta)
#
# POR QUÉ EXISTE. Medido en la flota (2026-08-05): 12 de 16 commits de un día
# fueron documentación pura y cada uno pagó ~11.6 min de CI — ~140 de 221 min
# tirados corriendo pest, eslint y semgrep contra Markdown. Con 3000 min/mes de
# cuota, un repo puede quemar un tercio del mes escribiendo docs.
#
# POR QUÉ NO `paths-ignore`, que era lo obvio:
#   1. Excluiría también el escaneo de SECRETOS. Una clave pegada en un `.md` es
#      una fuga igual que en código: el CI de watson estuvo 4 días en rojo por
#      exactamente eso, un hallazgo en `docs/**.md`. `paths-ignore` lo habría
#      vuelto invisible.
#   2. Deja los *required status checks* en "Expected — waiting for status" para
#      siempre. Con un `if:` de paso, el job siempre corre y siempre reporta.
#
# CONTRATO: escribe `solo_docs=true|false` en $GITHUB_OUTPUT.
#
# FAIL-SAFE POR CONSTRUCCIÓN: `true` solo se escribe cuando se PRUEBA que todo es
# documentación. Ante cualquier duda —rama nueva, force-push, base ausente, diff
# vacío, evento no contemplado— sale `false`, o sea SE CORRE TODO. Un fallo de
# detección jamás puede traducirse en "no escanees".
#
# Variables de entorno: EVENT_NAME, BEFORE_SHA, BASE_SHA, HEAD_SHA, GITHUB_OUTPUT
# =============================================================================
set -uo pipefail

EVENT_NAME="${EVENT_NAME:-}"
BEFORE_SHA="${BEFORE_SHA:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-HEAD}"
CERO=0000000000000000000000000000000000000000

SOLO_DOCS=false
MOTIVO="se corre TODO"

case "$EVENT_NAME" in
  pull_request|pull_request_target) BASE="$BASE_SHA" ;;
  push)                             BASE="$BEFORE_SHA" ;;
  *)                                BASE="" ;;
esac

if [ -z "$BASE" ] || [ "$BASE" = "$CERO" ]; then
  MOTIVO="sin base utilizable (rama nueva, force-push o evento '$EVENT_NAME')"
elif ! git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  # Distinguir "clon shallow" de "base que de verdad no existe" NO es cosmético: con el
  # `fetch-depth: 1` por defecto de actions/checkout, la base NUNCA está en el clon, así que
  # esto cae SIEMPRE a "corre todo" y el filtro es un NO-OP SILENCIOSO — parece instalado y
  # no ahorra un minuto. Lo reportó makro_logistica al cablearlo, tras leer el script antes
  # de usarlo. Un ahorro que no ahorra y no lo dice es peor que no tener el filtro.
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    MOTIVO="clon SHALLOW: la base no esta aqui, asi que NUNCA se omite nada"
    echo "::warning::El filtro de solo-documentacion no puede funcionar en un clon shallow." \
         "Anade 'fetch-depth: 0' al actions/checkout de este workflow, o quita el filtro:" \
         "tal como esta, corre todo siempre y no ahorra minutos."
  else
    MOTIVO="la base $BASE no esta en este clon (force-push o rebase)"
  fi
else
  CHANGED=$(git diff --name-only "$BASE" "$HEAD_SHA" 2>/dev/null) || CHANGED="__ERROR__"
  if [ "$CHANGED" = "__ERROR__" ]; then
    MOTIVO="git diff fallo"
  elif [ -z "$CHANGED" ]; then
    MOTIVO="diff vacio (merge, revert o push sin cambios)"
  else
    # Conteo explícito con `case`, NO `grep -qv`. Medido 2026-08-05: en un shell
    # donde `grep` es un wrapper sobre `ugrep`, `-qv` sobre entrada MULTILÍNEA
    # devuelve la respuesta CONTRARIA a `/usr/bin/grep`. Produjo un conteo
    # imposible ("0 commits con código" en un día donde sí los hubo) y estuvo a un
    # paso de que se construyera una decisión encima. `case` es POSIX y
    # determinista en cualquier shell.
    NO_DOCS=0
    TOTAL=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      TOTAL=$((TOTAL + 1))
      case "$f" in
        # Las extensiones EJECUTABLES van PRIMERO: el `case` evalua en orden, y un `.sh` no es
        # documentacion por vivir en `docs/`. Sin esta rama, el patron `docs/*` se lo tragaba —
        # en POSIX el `*` CRUZA LA BARRA— y `docs/scripts/deploy.sh` y
        # `docs/scripts/verify-multiagent.sh` (el codigo que distribuye el harness a la flota;
        # el numero NO se escribe aqui: este mismo fichero decia 22 y `selftest.yml` decia 16 y 17.
        # Medido 2026-09-02: 17 repos git en ~/Sites, 13 con caller-stub. Una cifra en un
        # comentario envejece sola -- el que la necesite la cuenta)
        # contaban como documentacion: un push que solo los tocara pasaba SIN SAST.
        # Lo reporto `coffee_framework_prod` en FEEDBACK-2026-08-18 y estuvo 14 dias sin atender.
        #
        # ALCANCE HONESTO del hueco, y hay que leerlo entero antes de citarlo:
        #
        # 1. Era de SAST, NO de secretos. `secrets` y `dep-audit` corren SIEMPRE en las tres
        #    recetas -- verificado extrayendo cada step con su `if:` -- asi que una clave pegada
        #    ahi se seguia viendo.
        #
        # 2. Y para los `.sh` el impacto real es HOY CASI NULO, medido el 2026-09-02:
        #       semgrep --config p/security-audit sobre docs/scripts (12 ficheros .sh)
        #         -> ficheros ESCANEADOS: 0
        #       control positivo, mismo comando + p/php sobre app/Console
        #         -> escaneados: 11   (la sonda funciona)
        #    Semgrep, tal como estas recetas lo configuran, NO PARSEA shell. El paso SAST omitido
        #    no habria analizado ni una linea de esos scripts.
        #
        #    Decir "pasaban sin SAST" es literalmente cierto y operativamente vacio para `.sh`.
        #    Donde SI habia impacto: los `.py/.php/.js/.yml` bajo `docs/` (esos si se escanean) y
        #    el paso de TESTS de la receta de node, que tambien se saltaba.
        #
        #    La clasificacion se arregla IGUAL, y a proposito: la regla no debe depender de que
        #    ruleset tenga semgrep hoy. Si manana anaden reglas de bash, esto ya esta bien.
        #    · depende-de: que el ruleset de semgrep siga sin reglas para shell
        #
        # 3. El ahorro NO se apaga. Medido sobre 3.694 commits reales de 17 repos en 180 dias:
        #       saltos "solo docs" con el case VIEJO   1298
        #       con el case NUEVO                      1292   -> se conserva el 99,54 %
        #    Los 6 perdidos son todos de watson y todos VERDADEROS POSITIVOS (scripts de deploy y
        #    una plantilla de workflow). Cero falsos positivos, cero repos afectados salvo watson.
        #
        # Y la mitad simetrica, que es la que hace util el filtro: un `.md`, un ADR o un PNG bajo
        # `docs/` SIGUEN siendo documentacion. Ensanchar esto hasta suspender a los sanos seria el
        # error contrario, y un check que suspende a los sanos se desactiva a la semana.
        *.sh|*.bash|*.mjs|*.js|*.py|*.php|*.yml|*.yaml) NO_DOCS=$((NO_DOCS + 1)) ;;
        docs/*|*.md) ;;
        *) NO_DOCS=$((NO_DOCS + 1)) ;;
      esac
    done <<EOF
$CHANGED
EOF
    if [ "$TOTAL" -gt 0 ] && [ "$NO_DOCS" -eq 0 ]; then
      SOLO_DOCS=true
      MOTIVO="$TOTAL archivo(s), todos documentacion"
    else
      MOTIVO="$NO_DOCS de $TOTAL archivo(s) NO son documentacion"
    fi
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "solo_docs=$SOLO_DOCS" >> "$GITHUB_OUTPUT"
fi
echo "alcance: solo_docs=$SOLO_DOCS - $MOTIVO"
if [ "$SOLO_DOCS" = "true" ]; then
  echo "::notice::Push solo-documentacion: SAST y tests OMITIDOS. Secretos y dep-audit SI corrieron."
fi
