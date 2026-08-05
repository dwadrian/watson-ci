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
  MOTIVO="la base $BASE no esta en este clon (shallow o force-push)"
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
