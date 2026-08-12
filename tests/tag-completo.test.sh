#!/usr/bin/env bash
# ==============================================================================
# tag-completo.test.sh — un tag no puede prometer lo que no contiene.
#
# POR QUE EXISTE, y por que llega tarde:
# el 2026-08-07 `makro_logistica` reporto que el alias `v2` apuntaba a un commit SIN
# `.github/actions/alcance`, y watson ACEPTO el hallazgo y prometio este check. Se quedo en
# el backlog. El 2026-08-11 se publico `v3` y **volvio a morder, peor**: no falta un archivo,
# falta el DIRECTORIO entero, en todo el linaje.
#
#   v2      f038b39  ->  .github/actions/  = 2 archivos   OK
#   v3      8691a8e  ->  .github/actions/  = 0            ROTO
#   v3.0.0  aa97649  ->  .github/actions/  = 0            ROTO
#   main    7031e66  ->  .github/actions/  = 2 archivos   OK
#
# El commit de v3 se llama "cierra los fail-open medidos": el release que endurece el gating
# es el que se llevo las acciones, y se etiqueto sin comprobar que sus consumidores siguieran
# resolviendo.
#
# LO QUE ESTE CHECK MIRA — y es la mitad que faltaba, senalada por quien lo reporto:
# verifica HACIA AFUERA, no hacia adentro. El release de v3 probablemente no rompio nada
# DENTRO de watson-ci (sus workflows usan rutas relativas); rompio a todo CONSUMIDOR que fije
# ese tag. La pregunta correcta no es "¿mis workflows pasan?" sino "¿lo que la flota
# referencia sigue existiendo en este ref?".
#
# POR QUE DUELE TANTO CUANDO PASA: el consumidor no ve "falta una accion". Ve esto —
#   Alcance del push    fail      4s
#   backend / app / god files / OWASP / DAST    skipping  0
# — un check rojo con pinta de infraestructura y todo lo demas en gris. Quien mergea mirando
# el resumen supone que el resto paso. En el caso medido, el PR estuvo ABIERTO UN DIA con los
# gates apagados y nadie lo noto.
#
# Uso:  bash tests/tag-completo.test.sh [ref...]     (por defecto: los tags v* y HEAD)
# Exit: 0 = cada ref contiene las acciones que sus consumidores referencian · 1 = alguno no
# ==============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FALLOS=0
ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FALLOS=$((FALLOS + 1)); }

# Las acciones que este repo PUBLICA. Se derivan del arbol de trabajo, no de una lista a mano:
# una lista a mano es lo que se olvida de actualizar, que es la clase de este mismo incidente.
ACCIONES="$(find .github/actions -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's|.*/||' | sort)"
if [ -z "$ACCIONES" ]; then
  echo "⛔ no hay .github/actions/ en el arbol de trabajo."
  echo "   Si es a proposito, este check sobra; si no, el arbol ya esta roto."
  exit 1
fi
echo "Acciones publicadas por este repo: $(printf '%s' "$ACCIONES" | tr '\n' ' ')"

# nacimiento <accion> -> epoch del commit que la ANADIO.
# Un tag anterior a esa fecha NO esta roto: es de antes de que la accion existiera, y su
# consumidor nunca tuvo nada que referenciar. Sin esta distincion el check gritaba sobre
# SEIS tags legitimos de julio, y un check que grita sobre lo correcto entrena a ignorarlo
# -- que es justo el fallo que este archivo existe para evitar.
# La fecha se DERIVA del repo. Hardcodearla es la lista a mano otra vez.
nacimiento() {
  git log --diff-filter=A --format=%ct --reverse -- ".github/actions/$1/action.yml" \
       ".github/actions/$1/action.yaml" 2>/dev/null | head -1
}

# faltan_en <ref> -> imprime las acciones ausentes (vacio si estan todas)
# <solo_posteriores>: si es "si", ignora las acciones que NO existian cuando se corto el ref.
faltan_en() {
  local ref="$1" solo_post="${2:-no}" a faltan="" tref
  tref="$(git log -1 --format=%ct "$ref" 2>/dev/null || echo 0)"
  for a in $ACCIONES; do
    if [ "$solo_post" = "si" ]; then
      local nac; nac="$(nacimiento "$a")"
      # `-lt` sobre epochs: si el ref es anterior al nacimiento, la accion no le corresponde.
      [ -n "$nac" ] && [ "$tref" -lt "$nac" ] && continue
    fi
    # `action.yml` O `action.yaml`: GitHub acepta las dos y exigir una sola daria falsos rojos.
    if ! git cat-file -e "$ref:.github/actions/$a/action.yml" 2>/dev/null \
      && ! git cat-file -e "$ref:.github/actions/$a/action.yaml" 2>/dev/null; then
      faltan="$faltan $a"
    fi
  done
  printf '%s' "$faltan"
}

por_que_duele() {
  echo "      Un consumidor con \`uses: dwadrian/watson-ci/.github/actions/<x>@$1\` revienta con"
  echo "      \"Can't find 'action.yml'\", y sus jobs dependientes salen 'skipping' — que en la"
  echo "      pantalla de checks NO se distingue de un skip legitimo. Se ve UN rojo con pinta de"
  echo "      infraestructura y todo lo demas en gris."
}

# ── BLOQUEANTE: el ref que se va a publicar ──────────────────────────────────
# El trabajo de este check es impedir el PROXIMO release incompleto. Los tags ya rotos son
# un hecho consumado y arreglarlos exige mover tags inmutables — decision del dueño, no de
# un test. Si esto fallara por la historia, el selftest quedaria en rojo permanente y un gate
# que bloquea todo empuja a desactivarlo: el anti-patron que este repo lleva semanas cazando.
OBJETIVO="${1:-HEAD}"
echo
echo "── BLOQUEANTE: $OBJETIVO (lo que se publicaria)"
if ! git rev-parse --verify --quiet "$OBJETIVO^{commit}" >/dev/null 2>&1; then
  fail "$OBJETIVO — no resuelve"
else
  f="$(faltan_en "$OBJETIVO")"
  if [ -z "$f" ]; then
    ok "$OBJETIVO ($(git rev-parse --short "$OBJETIVO")) — contiene todas las acciones"
  else
    fail "$OBJETIVO ($(git rev-parse --short "$OBJETIVO")) — le FALTA:$f"
    por_que_duele "$OBJETIVO"
  fi
fi

# ── INFORMATIVO: los tags ya publicados ──────────────────────────────────────
# No suma a $FALLOS a proposito. Pero se IMPRIME siempre y con nombre: un hueco que no se
# ve es el que se queda. Aqui salio que `alcance` existe en UN solo ref -- el alias movil --
# y falta en los diez tags inmutables, o sea que fijar una version concreta (la practica
# recomendada) da un CI roto mientras que el alias movil (la desaconsejada) funciona.
echo
echo "── INFORMATIVO: REGRESIONES entre alias mayores (no bloquean; son decision del dueño)"
# La senal util NO es "a este tag le falta una accion" -- un tag anterior al nacimiento de la
# accion no le debe nada, y avisar de eso es ruido que entrena a ignorar el check.
#
# La senal util es una REGRESION: que el alias mayor MAS NUEVO carezca de algo que el ANTERIOR
# si tiene. Eso es lo que muerde de verdad, porque dependabot propone el alias mas alto como
# "lo ultimo" y el consumidor acaba con MENOS de lo que tenia.
#
# Caso medido 2026-08-11 (reportado por makro_logistica): `alcance` nacio el 05-ago, DESPUES de
# publicar v3 (03-ago). Solo el alias `v2` se movio para incluirla; nunca se publico un v3.x con
# ella. Nadie borro nada -- pero @v3 ofrece MENOS que @v2, y ese es el defecto.
ALIAS="$(git tag --list 'v[0-9]' | sort -V)"
REGRES=0
ANT=""
for a in $ALIAS; do
  tiene="$(for x in $ACCIONES; do
             git cat-file -e "$a:.github/actions/$x/action.yml" 2>/dev/null && printf '%s ' "$x"
           done)"
  echo "  · $a ($(git rev-parse --short "$a")) ofrece: ${tiene:-(ninguna)}"
  if [ -n "$ANT" ]; then
    for x in $ANT_TIENE; do
      case " $tiene " in *" $x "*) ;; *)
        echo "    ⚠️  REGRESION: $a NO ofrece '$x', y $ANT sí."
        echo "        dependabot propone el alias mas alto como 'lo ultimo': un consumidor que"
        echo "        acepte el bump se queda con MENOS de lo que tenia, y sus jobs dependientes"
        echo "        salen 'skipping' — indistinguible de un skip legitimo."
        REGRES=$((REGRES + 1)) ;;
      esac
    done
  fi
  ANT="$a"; ANT_TIENE="$tiene"
done
[ "$REGRES" -gt 0 ] && {
  echo
  echo "  ⚠️  $REGRES regresion(es) entre alias. Arreglo SIN reescribir historia: publicar una"
  echo "      version nueva del mayor afectado desde un ref completo y mover su alias ahi."
  echo "      Retaguear una version publicada rompe la inmutabilidad; mover un alias es su funcion."
}

echo
if [ "$FALLOS" -eq 0 ]; then
  echo "tag-completo: el ref a publicar esta COMPLETO"
else
  echo "tag-completo: $FALLOS fallo(s) — NO publicar"
fi
exit $((FALLOS > 0))
