#!/bin/bash
# =============================================================================
# Backstop de roles para watson-ci.
#
# POR QUE EXISTE. El 2026-08-05 se rompio el CI de los 17 repos de la flota desde
# este repo, y ningun gate lo detuvo: watson-ci no tiene harness. Y no puede
# tenerlo — es PUBLICO, y un hook git-trackeado aqui es RCE local por
# `gh pr checkout` antes del merge.
#
# La capa 1 (.claude/agents/config.json) cubre los commits hechos desde una sesion
# de watson. Este script cubre el resto: corre en el CI, no se evade con un
# checkout y no depende de desde donde se commitee.
#
# Semantica IDENTICA a la del gate local, para no tener dos reglas que aprender:
# artefacto docs/reviews/ROLE-REVIEW-*.md con la marca `Roles-Validated: GO`
# co-commiteado, o trailer `Roles-Trivial:` / `Roles-Hotfix:` con razon.
#
# Uso: bash tools/gate-roles.sh <base> <head>
# =============================================================================
set -uo pipefail

# Modo TAG: `gate-roles.sh --tag <sha> <rama-vigilada>`
#
# El paso del tag revisaba SOLO el commit apuntado, y con base vacia el script cae en la rama
# "solo HEAD". Consecuencia medida por el rol: rama lateral -> commit malicioso -> commit inocuo
# encima -> `git tag -f v2` -> VERDE, con la carga util ya distribuida a los 17 repos.
#
# El invariante real no es "el commit del tag cumple": es que ESTE CONTENIDO en la rama que si
# pasa por los gates. Lo que no esta en `main` no se reviso nunca.
if [ "${1:-}" = "--tag" ]; then
  TAG_SHA="${2:-}"; RAMA="${3:-main}"
  # Refnames CUALIFICADOS. `git rev-parse --verify main` resuelve `refs/tags/main` ANTES que
  # `refs/heads/main`, asi que `git tag main <evil>` suplantaba la rama y la contencion daba
  # verde. En el runner ni siquiera existe `refs/heads/main` -- `actions/checkout` deja
  # `refs/remotes/origin/*` --, asi que el tag ganaba solo. Medido de punta a punta por el rol.
  if ! git rev-parse --verify "refs/heads/$RAMA" >/dev/null 2>&1 &&
     ! git rev-parse --verify "refs/remotes/origin/$RAMA" >/dev/null 2>&1; then
    echo "::error::No se pudo resolver la rama vigilada '$RAMA'."
    echo "::error::Sin ella no se puede afirmar que el tag apunte a codigo revisado."
    exit 1
  fi
  REF=$(git rev-parse --verify "refs/heads/$RAMA" 2>/dev/null \
        || git rev-parse --verify "refs/remotes/origin/$RAMA")
  if ! git merge-base --is-ancestor "$TAG_SHA" "$REF" 2>/dev/null; then
    echo "::error::El tag apunta a un commit que NO esta contenido en '$RAMA'."
    echo "::error::Eso es codigo que nunca paso por los gates, y lo van a consumir los repos"
    echo "::error::que apuntan a este alias. Mueve el tag a un commit de '$RAMA'."
    exit 1
  fi
  echo "El commit del tag esta contenido en '$RAMA': revisado por la via normal."
  exit 0
fi

BASE="${1:-}"
HEAD_SHA="${2:-HEAD}"
CERO=0000000000000000000000000000000000000000
fallos=0
TMPCFG=$(mktemp)

# ¿Es una ruta que reparte riesgo a la flota? `case` de POSIX, NO `grep -qv`:
# medido 2026-08-05, en algunos shells `grep` es un wrapper sobre ugrep cuyo `-qv`
# sobre entrada multilinea devuelve la respuesta CONTRARIA.
es_riesgo() {
  case "$1" in
    .github/*)  return 0 ;;   # workflows, actions y lo que venga: todo .github reparte
    tools/*)    return 0 ;;   # el tooling pineado que las recetas instalan en cada job
    tests/fixtures/*) return 1 ;;  # datos de prueba: exigirles loop de 3 roles a diario seria
                                   # un gate que ensena a ignorarse
    tests/*)    return 0 ;;   # el rol lo cazo: es lo unico que el dueno CORRE EN LOCAL
    .gitmodules) return 0 ;;  # repuntar la URL de un submodulo cambia QUE codigo se trae
    .claude/*)  return 0 ;;   # la config de los gates, protegida por el gate
    *)          return 1 ;;
  esac
}

revisar_commit() {
  sha="$1"
  riesgo=0
  review=0
  # FAIL-CLOSED: si `git` no puede listar los archivos del commit, no se afirma que este
  # limpio. Sin esto, un fallo de git dejaba la lista vacia => riesgo=0 => PASA, o sea el
  # gate se apagaba solo justo cuando menos se puede confiar en el.
  # -c   : sin esto un MERGE COMMIT devuelve VACIO y el "evil merge" (editar el workflow al
  #        resolver el conflicto) pasaba invisible. Reproducido por el rol.
  # --root: el commit inicial tambien devolvia vacio.
  # -z    : `core.quotePath` es true por defecto, asi que una ruta con acentos salia ENTRE
  #        COMILLAS y con escapes octales -- el `case` empezaba a matchear en `"` y
  #        `.github/workflows/verificacion.yml` evadia el gate. Tambien reproducido.
  # NO se usa `archivos=$(...)`: la sustitucion de comandos BORRA los bytes NUL, asi que con
  # `-z` la lista llegaba sin separadores y `read -d ''` no iteraba NI UNA VEZ -- el bucle no
  # corria y TODO salia "OK". El plan prescribio `-z` (correcto, por `core.quotePath`) pero
  # nadie lo ejecuto hasta ahora: revisar un plan no es correrlo.
  #
  # Se escribe a un temporal para conservar los NUL Y poder comprobar el exit de git.
  #   -c   : sin esto un MERGE COMMIT devuelve VACIO y el "evil merge" pasa invisible.
  #   --root: el commit inicial tambien devolvia vacio.
  #   -z   : `core.quotePath` sacaba las rutas con acento ENTRE COMILLAS y con escapes
  #          octales, y el `case` empezaba a matchear en la comilla.
  tmp=$(mktemp)
  if ! git diff-tree --no-commit-id --name-only -r -c --root -z "$sha" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "::error::No se pudieron listar los archivos de $sha."
    echo "::error::Un gate que no pudo mirar no dice 'limpio'."
    return 1
  fi
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    if es_riesgo "$f"; then riesgo=1; fi
    case "$f" in
      docs/reviews/ROLE-REVIEW-TEMPLATE*|docs/reviews/*TEMPLATE*)
        # Una PLANTILLA no valida nada. Sin esto, un ROLE-REVIEW-TEMPLATE.md commiteado una vez
        # y tocado de vez en cuando satisfacia el gate para siempre.
        ;;
      docs/reviews/ROLE-REVIEW-*.md)
        # Marca ANCLADA a inicio de linea, decoracion permitida. Predicado IDENTICO al de
        # `role-gate.mjs:20` -- a proposito: dos gates sobre el MISMO artefacto que usan
        # predicados distintos garantizan que uno de los dos esta equivocado.
        # La ronda 4 exigio aqui la marca PELADA, para que un `> Roles-Validated: GO` citado en
        # la prosa no contara. Medido despues: rechazaba el `**Roles-Validated: GO**` que se
        # escribe de verdad Y el `> Roles-Validated: GO` que role-gate.mjs:85 INSTRUYE escribir.
        # 100% de falsos positivos sobre artefactos legitimos y cero adversarios menos -- quien
        # quiera burlar el gate escribe la marca pelada, que era lo unico que pasaba. Un gate que
        # solo rechaza a los honestos no es estricto, esta roto. Lo que el ancla `^` si compra
        # (una MENCION a mitad de linea no es veredicto) se conserva y tiene su propio assert.
        if git show "$sha:$f" 2>/dev/null | grep -qE '^[> \t*_]*Roles-Validated:[ \t]*GO\b'; then
          review=1
        fi ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  [ "$riesgo" -eq 0 ] && return 0

  # El escape se ancla a INICIO DE LINEA y exige una razon detras. Con `case "$msg" in
  # *"Roles-Trivial:"*` bastaba MENCIONAR el trailer en la prosa del mensaje para desactivar
  # el gate: es exactamente la clase que se cerro en `967e749` y que se volvio a colar en el
  # gate de secretos anoche. Arreglar una clase no inmuniza contra repetirla al lado.
  # Patron IDENTICO al de `role-gate.mjs:28`. La primera version llevaba `^[ \t]*`, que es MAS
  # LAXA que la local: un trailer indentado dentro de la prosa -- la forma natural de DOCUMENTAR
  # el escape en un mensaje -- lo disparaba. La clase de `967e749` seguia abierta por ahi.
  if git log -1 --format=%B "$sha" | grep -qE '^Roles-(Trivial|Hotfix):[ ]*[^[:space:]"'"'"']'; then
    # "Queda contado" era FALSO en CI: no habia tally, ni summary, ni nada. La capa 1 si
    # registra `COMMIT_ROLE_ESCAPE` en audit.log; aqui la frase prometia una contabilidad
    # inexistente. Ahora se escribe al summary del run, que es lo que alguien va a leer.
    linea="escape declarado en $(git log -1 --format='%h %s' "$sha")"
    echo "  $linea — pasa y queda contado"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "### Escape de roles usado"; echo ""; echo "- $linea"; } >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi

  if [ "$review" -eq 1 ]; then
    echo "  OK $(git log -1 --format=%h "$sha") — ROLE-REVIEW con marca GO"
    return 0
  fi

  echo "::error::$(git log -1 --format='%h %s' "$sha") toca superficie de distribucion sin ROLE-REVIEW."
  echo "::error::Anade docs/reviews/ROLE-REVIEW-<fecha>-<slug>.md con 'Roles-Validated: GO' en el MISMO commit,"
  echo "::error::o declara el escape con 'Roles-Trivial: <razon>' en el mensaje."
  return 1
}

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  echo "::warning::Clon SHALLOW: el rango de commits no es fiable. Anade 'fetch-depth: 0' al checkout."
fi

if [ -z "$BASE" ] || [ "$BASE" = "$CERO" ] || ! git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  # Fallar aqui deadlockearia el repo (rama nueva, force-push), y un gate sin salida es el
  # anti-patron que este proyecto ya tiene escrito. Se revisa HEAD y se DICE que la cobertura
  # se redujo: un recorte silencioso se lee como cobertura completa.
  echo "::warning::Base no utilizable ('$BASE'): se revisa SOLO el commit HEAD, no el rango."
  revisar_commit "$HEAD_SHA" || fallos=1
else
  # FAIL-CLOSED. Con `for sha in $(git rev-list ...)`, si rev-list fallaba la sustitucion daba
  # vacio, el bucle no iteraba y el script decia "OK" con exit 0. El mismo fail-open que
  # `revisar_commit` si cerraba, pero el llamador no replicaba.
  if ! lista=$(git rev-list --reverse "$BASE..$HEAD_SHA" 2>&1); then
    echo "::error::No se pudo listar el rango $BASE..$HEAD_SHA: $lista"
    exit 1
  fi
  for sha in $lista; do
    revisar_commit "$sha" || fallos=1
  done
fi

# La capa 1 vive en un archivo del repo auditado, asi que un commit podria apagarla. Se
# comprueba el ESTADO RESULTANTE, no el contenido del diff: ni un ROLE-REVIEW de adorno la
# evade sin dejar rastro deliberado.
# La capa 1 vive en un archivo del repo auditado, asi que un commit podria apagarla. Se
# comprueba el ESTADO RESULTANTE, no el contenido del diff.
#
# Se PARSEA con jq, no se busca una subcadena. La version anterior hacia `case "$cfg" in
# *'"enabled": true'*` sobre el archivo ENTERO, asi que bastaba dejar `roles.enabled:false` y
# que CUALQUIER otro bloque tuviera `enabled:true` -- el propio `secrets` del config real lo
# tiene. Tampoco miraba `shadow`, que degrada la capa 1 a solo-aviso, ni el caso de BORRAR el
# archivo. Tres evasiones, las tres medidas por el rol.
# Solo se exige en repos que YA tienen capa 1. Un repo que nunca la tuvo no se le reclama --
# si no, este script no seria reutilizable y los propios fixtures de test fallarian. Pero si la
# tenia en la base y no la tiene en HEAD, eso ES apagarla.
tenia_capa1=false
# El punto de comparacion: BASE si resuelve, y si no el PADRE de HEAD. Sin ese respaldo,
# BORRAR el config pasaba verde en cuanto BASE fuera inutilizable -- force-push a main, o
# `before` en ceros al crear un tag. Apagarlo si se cazaba; borrarlo no. Medido por el rol.
ref_previa=""
if [ -n "$BASE" ] && [ "$BASE" != "$CERO" ] && git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  ref_previa="$BASE"
elif git rev-parse --verify "${HEAD_SHA}^" >/dev/null 2>&1; then
  ref_previa="${HEAD_SHA}^"
fi
if [ -n "$ref_previa" ]; then
  git cat-file -e "$ref_previa:.claude/agents/config.json" 2>/dev/null && tenia_capa1=true
fi
git cat-file -e "$HEAD_SHA:.claude/agents/config.json" 2>/dev/null && tenia_capa1=true

if [ "$tenia_capa1" = "false" ]; then
  :   # este repo no usa la capa 1; no hay estado que verificar
elif ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq no esta disponible: no se puede verificar el estado de la capa 1."
  fallos=1
elif ! git show "$HEAD_SHA:.claude/agents/config.json" > "$TMPCFG" 2>/dev/null; then
  echo "::error::.claude/agents/config.json no existe en $HEAD_SHA: la capa 1 quedaria apagada."
  fallos=1
elif ! jq -e '.roles as $r
              | ($r|type=="object") and ($r.enabled==true) and ($r.shadow==false)
                and ($r.risk_globs|type=="array")
                and ([".github/workflows/verify-node.yml", "tools/gate-roles.sh",
                      ".claude/agents/config.json", "tests/gate-roles.test.sh"]
                     | all(. as $p | ($r.risk_globs
                         | any(. as $g | ($g|type=="string")
                               and (try ($p|test($g)) catch false)))))' "$TMPCFG" >/dev/null 2>&1; then
  echo "::error::La capa 1 no queda ACTIVA tras este push."
  echo "::error::No basta con contar globs: se comprueba que CASEN de verdad las rutas canario"
  echo "::error::(.github/workflows, tools/, .claude/agents/config.json, tests/). Cinco globs"
  echo "::error::inertes satisfacian el conteo y dejaban la capa 1 muerta."
  echo "::error::Si apagarla es deliberado, tiene que decirlo un ROLE-REVIEW, no un booleano."
  fallos=1
fi
rm -f "$TMPCFG"

[ "$fallos" -eq 0 ] || { echo "::error::Backstop de roles: FALLA."; exit 1; }
echo "Backstop de roles: OK."
