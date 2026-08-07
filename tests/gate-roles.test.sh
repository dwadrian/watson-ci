#!/bin/bash
# Tests del backstop de roles. Repos de fixture REALES: el script trabaja con git, así que
# simularlo con cadenas probaria otra cosa.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/tools/gate-roles.sh"
fallos=0

# OJO: cada invocacion va dentro de `( cd "$d" && ... )`. La primera version llamaba
# `bash "$GATE"` desde el cwd de la suite, asi que el script operaba sobre EL REPO DE LA SUITE
# y no sobre el fixture: 6 de los 10 asserts pasaban por la razon equivocada (SHA foraneo =>
# error => exit 1) y la prueba de mutacion daba salida IDENTICA con y sin mutante. Los tests
# no probaban nada. Lo midio el rol en la ronda 1.
ok() { if [ "$1" = "$2" ]; then echo "OK    $3"; else echo "FALLA $3 (esperado=$1 obtenido=$2)"; fallos=$((fallos+1)); fi; }

nuevo_repo() {
  d=$(mktemp -d)
  git -C "$d" init -q -b base
  git -C "$d" config user.email t@t.co; git -C "$d" config user.name t
  git -C "$d" config gc.auto 0
  mkdir -p "$d/.github/workflows" "$d/docs/reviews"
  echo base > "$d/README.md"
  git -C "$d" add README.md >/dev/null; git -C "$d" commit -qm base
  echo "$d"
}

# 1. commit de riesgo SIN review => falla
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml; git -C "$d" commit -qm "feat: receta nueva"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "commit de riesgo sin review => FALLA"

# 2. con ROLE-REVIEW co-commiteado => pasa
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-06-x.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-06-x.md
git -C "$d" commit -qm "feat: receta con review"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "con ROLE-REVIEW co-commiteado => PASA"

# 3. trailer de escape => pasa
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml
git -C "$d" commit -qm "fix: typo en un comentario

Roles-Trivial: solo un comentario, sin cambio de comportamiento"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "trailer Roles-Trivial => PASA"

# 4. NO-BOQUETE: commit sin rutas de riesgo => pasa
d=$(nuevo_repo)
echo hola > "$d/README.md"
git -C "$d" add README.md; git -C "$d" commit -qm "docs: nota"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "commit sin riesgo => PASA"

# 5. NO-BOQUETE: un ROLE-REVIEW SIN la marca GO no vale
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'aqui no hay marca\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-06-x.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-06-x.md
git -C "$d" commit -qm "feat: receta con review vacio"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "ROLE-REVIEW sin marca GO => FALLA"

# 6. rango indeterminable => revisa solo HEAD y AVISA
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml; git -C "$d" commit -qm "feat: receta"
salida=$( cd "$d" && bash "$GATE" "" "$(git rev-parse HEAD)" 2>&1 )
ok 1 $? "sin base, revisa HEAD (que es de riesgo) => FALLA"
case "$salida" in *"::warning::"*) ok 0 0 "sin base, AVISA de la cobertura reducida";;
  *) ok 0 1 "sin base, AVISA de la cobertura reducida";; esac

# 7. NO-BOQUETE: varios commits, solo uno malo => falla
d=$(nuevo_repo)
inicio=$(git -C "$d" rev-parse HEAD)
echo hola > "$d/README.md"; git -C "$d" add README.md; git -C "$d" commit -qm "docs: uno"
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml; git -C "$d" commit -qm "feat: dos"
( cd "$d" && bash "$GATE" "$inicio" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "rango con un commit malo => FALLA"

# 8. NO-BOQUETE: el trailer MENCIONADO en la prosa no desactiva el gate
# Es la clase de `967e749`: bastaba nombrar el trailer para apagar el gate. Se cerro en
# otro gate y se volvio a colar en el de secretos anoche; aqui se fija con un test.
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml
git -C "$d" commit -qm "docs: explico que el escape se escribe con Roles-Trivial: motivo"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "trailer solo MENCIONADO en la prosa => FALLA"

# 9. NO-BOQUETE: si git no puede mirar el commit, FALLA (no dice 'limpio')
d=$(nuevo_repo)
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD)" "0000000000000000000000000000000000000001" ) >/dev/null 2>&1
ok 1 $? "sha inexistente => FALLA, no pasa en silencio"

# 10. BYPASS reproducido por el rol: evil merge (diff-tree sin -c ve VACIO)
d=$(nuevo_repo)
git -C "$d" checkout -qb rama
echo hola > "$d/otro.md"; git -C "$d" add otro.md; git -C "$d" commit -qm "docs: inocente"
git -C "$d" checkout -q base
base=$(git -C "$d" rev-parse HEAD)
git -C "$d" merge --no-commit --no-ff rama >/dev/null 2>&1
echo "on: push" > "$d/.github/workflows/x.yml"           # <- contenido que no esta en ningun padre
git -C "$d" add .github/workflows/x.yml
git -C "$d" commit -qm "merge: rama"
( cd "$d" && bash "$GATE" "$base" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "evil merge => FALLA"

# 11. BYPASS reproducido: ruta no-ASCII (core.quotePath la saca entre comillas)
d=$(nuevo_repo)
printf 'on: push\n' > "$d/.github/workflows/verificación.yml"
git -C "$d" add ".github/workflows/verificación.yml"
git -C "$d" commit -qm "feat: receta con acento"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "ruta con acento => FALLA"

# 12. BYPASS reproducido: rev-list roto no puede decir OK
d=$(nuevo_repo)
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD)" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ) >/dev/null 2>&1
ok 1 $? "rango irresoluble => FALLA, no dice OK"

# 13. BYPASS reproducido: el escape INDENTADO en la prosa no cuenta
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
git -C "$d" add .github/workflows/x.yml
git -C "$d" commit -qm "docs: como documentar el escape

Para saltarse el gate se escribe:

    Roles-Trivial: la razon va aqui
"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "escape INDENTADO en prosa => FALLA"

# 14. NO-BOQUETE: apagar la capa 1 no pasa aunque traiga review
d=$(nuevo_repo)
mkdir -p "$d/.claude/agents"
printf '{"roles":{"enabled":false}}\n' > "$d/.claude/agents/config.json"
git -C "$d" add .claude/agents/config.json
git -C "$d" commit -qm "chore: apagar la capa 1"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "config con roles.enabled false => FALLA"

# ---- Hallazgos del loop sobre la implementacion ----

# 16-18. ALTO-1: el chequeo de estado era un SUBSTRING sobre el archivo ENTERO, asi que
# bastaba intercambiar dos booleanos. Y no miraba `shadow`, que degrada la capa 1 a aviso.
# Y borrar el archivo tambien pasaba. El assert 14 sobrevivia a borrar el chequeo COMPLETO.
# Se co-commitea un ROLE-REVIEW VALIDO a proposito: `.claude/agents/config.json` ya es
# superficie de riesgo, asi que sin el review el commit fallaria por FALTA DE REVIEW y el
# assert pasaria por la razon equivocada -- exactamente el defecto que el gatekeeper encontro
# en el assert 15, que sobrevivia a borrar el chequeo de estado entero. Con el review puesto,
# lo UNICO que puede hacer fallar el commit es el chequeo de estado.
cfg_case() {   # $1 = json, $2 = esperado, $3 = nombre
  d=$(nuevo_repo); mkdir -p "$d/.claude/agents"
  printf '%s\n' "$1" > "$d/.claude/agents/config.json"
  printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-cfg.md"
  git -C "$d" add .claude/agents/config.json docs/reviews/ROLE-REVIEW-2026-08-07-cfg.md
  git -C "$d" commit -qm "chore: config"
  ( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
  ok "$2" $? "$3"
}
cfg_case '{"roles":{"enabled":false},"secrets":{"enabled":true}}' 1 \
  "roles false + otro enabled true en el archivo => FALLA"
cfg_case '{"roles":{"enabled":true,"shadow":true,"risk_globs":["^x$"]}}' 1 \
  "shadow true degrada la capa 1 => FALLA"
cfg_case '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^\\.github/.*","^tools/.*","^tests/.*","(^|/)\\.claude/agents/config\\.json$","(^|/)\\.claude/.*\\.(mjs|sh|bash)$"]}}' 0 \
  "NO-BOQUETE: config correcta => PASA"

# 19. ALTO-1c: BORRAR el config tambien apagaba la capa 1 y pasaba
d=$(nuevo_repo); mkdir -p "$d/.claude/agents"
printf '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^x$"]}}\n' > "$d/.claude/agents/config.json"
git -C "$d" add .claude/agents/config.json; git -C "$d" commit -qm "chore: config"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-del.md"
git -C "$d" rm -q .claude/agents/config.json
git -C "$d" add docs/reviews/ROLE-REVIEW-2026-08-07-del.md
git -C "$d" commit -qm "chore: fuera"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "borrar el config => FALLA"

# 20. MEDIO-4, el caso de regresion del incidente: un ROLE-REVIEW-TEMPLATE.md con la marca
# citada como EJEMPLO satisfacia el gate PARA SIEMPRE -- se commitea una vez y cada vez que se
# toca vuelve a "validar" cualquier cambio de riesgo.
# OJO con el titulo: hasta 2026-08-07 decia "marca CITADA en un blockquote => FALLA" y eso ya no
# es lo que prueba. El blockquote AHORA se acepta a proposito (es el formato que role-gate.mjs:85
# instruye, ver 35b); lo que hace fallar a este caso es el NOMBRE de plantilla, nada mas. Se
# conserva por ser el caso real del incidente, pero quien aisla la exclusion es el 36.
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Ejemplo de la marca:\n\n> Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-TEMPLATE.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-TEMPLATE.md
git -C "$d" commit -qm "feat: con plantilla"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "REGRESION: plantilla con la marca de ejemplo => FALLA"

# 21. BAJO-7: repuntar un submodulo a otra URL no era superficie de riesgo
d=$(nuevo_repo)
printf '[submodule "x"]\n\tpath = x\n\turl = https://evil.example/x\n' > "$d/.gitmodules"
git -C "$d" add .gitmodules; git -C "$d" commit -qm "chore: repunta submodulo"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? ".gitmodules => FALLA"

# 22. NO-BOQUETE: un fixture de test no debe cobrar peaje diario
d=$(nuevo_repo); mkdir -p "$d/tests/fixtures"
echo x > "$d/tests/fixtures/caso.txt"
git -C "$d" add tests/fixtures/caso.txt; git -C "$d" commit -qm "test: fixture nuevo"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "tests/fixtures NO pide review (no es distribucion)"

# 23-25. ALTO-2: el paso del TAG revisaba SOLO el commit apuntado, asi que una rama lateral
# con un commit malicioso y otro inocuo encima daba VERDE. El invariante real no es "el commit
# del tag cumple" sino "el commit del tag esta CONTENIDO en la rama vigilada".
d=$(nuevo_repo)
git -C "$d" checkout -qb lateral
echo "on: push" > "$d/.github/workflows/pwn.yml"          # <- receta troyanizada, sin review
git -C "$d" add .github/workflows/pwn.yml; git -C "$d" commit -qm "feat: receta"
echo nota > "$d/nota.md"; git -C "$d" add nota.md; git -C "$d" commit -qm "docs: nota"
( cd "$d" && bash "$GATE" --tag "$(git rev-parse HEAD)" base ) >/dev/null 2>&1
ok 1 $? "tag a un commit FUERA de la rama vigilada => FALLA"

d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-x.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-07-x.md
git -C "$d" commit -qm "feat: receta con review"
( cd "$d" && bash "$GATE" --tag "$(git rev-parse HEAD)" base ) >/dev/null 2>&1
ok 0 $? "NO-BOQUETE: tag a un commit de la rama vigilada, con review => PASA"

d=$(nuevo_repo)
( cd "$d" && bash "$GATE" --tag "$(git rev-parse HEAD)" rama-que-no-existe ) >/dev/null 2>&1
ok 1 $? "rama vigilada inexistente => FALLA, no asume que esta contenido"

# 26. ALTO-A: `rev-parse --verify main` resuelve refs/tags/main ANTES que refs/heads/main.
# Cadena medida: rama lateral -> receta troyanizada -> `git tag <rama> <evil>` -> `git tag -f v2`
# -> VERDE entero. En el runner ni siquiera existe refs/heads/main (checkout deja
# refs/remotes/origin/*), asi que el tag gana solo.
#
# OJO CON EL FIXTURE: la primera version vigilaba `main`, que en el fixture NO EXISTE, asi que
# el gate fallaba por el chequeo de RESOLUBILIDAD y no por la cualificacion -- pasaba por la
# razon equivocada, y descualificar solo el `REF=` sobrevivia. Se vigila `base`, que SI existe,
# para que lo unico que pueda salvar el caso sea la cualificacion del refname.
d=$(nuevo_repo)
git -C "$d" checkout -qb lateral
echo "on: push" > "$d/.github/workflows/pwn.yml"
git -C "$d" add .github/workflows/pwn.yml; git -C "$d" commit -qm "feat: receta"
evil=$(git -C "$d" rev-parse HEAD)
git -C "$d" checkout -q base
git -C "$d" tag base "$evil"                       # <- tag homonimo de una rama que SI existe
( cd "$d" && bash "$GATE" --tag "$evil" base ) >/dev/null 2>&1
ok 1 $? "un TAG llamado como la rama no puede suplantarla"

# 27. ALTO-C: borrar el config pasaba verde si BASE no resuelve (force-push, o before en ceros)
d=$(nuevo_repo); mkdir -p "$d/.claude/agents"
printf '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^\\.github/.*","^tools/.*","^tests/.*","(^|/)\\.claude/agents/config\\.json$","(^|/)\\.claude/.*\\.(mjs|sh|bash)$"]}}\n' > "$d/.claude/agents/config.json"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-a.md"
git -C "$d" add .claude docs; git -C "$d" commit -qm "chore: capa 1"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-b.md"
git -C "$d" rm -q .claude/agents/config.json
git -C "$d" add docs/reviews/ROLE-REVIEW-2026-08-07-b.md
git -C "$d" commit -qm "chore: fuera la capa 1"
( cd "$d" && bash "$GATE" "" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "borrar la capa 1 con BASE irresoluble => FALLA igual"

# 28-29. MEDIO-D: `>=5 risk_globs` no era invariante. Cinco globs inertes lo satisfacian, y
# `jq length` sobre un string o un numero tambien da 5. El invariante tiene que ser CONDUCTUAL:
# que los globs casen de verdad las rutas que reparten riesgo.
cfg_case '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^$","^$","^$","^$","^$"]}}' 1 \
  "5 globs que no casan NADA => FALLA"
cfg_case '{"roles":{"enabled":true,"shadow":false,"risk_globs":"cinco"}}' 1 \
  "risk_globs que no es lista => FALLA"

# 30. BAJO-G: el escape no puede desarmar el gate sobre la config DEL PROPIO gate
d=$(nuevo_repo); mkdir -p "$d/.claude/agents"
printf '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^x$"]}}\n' > "$d/.claude/agents/config.json"
git -C "$d" add .claude/agents/config.json
git -C "$d" commit -qm "chore: limpieza

Roles-Trivial: quito config muerta"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "Roles-Trivial NO desarma el gate sobre la config del gate"

# 31-34. Cada CONJUNTO del chequeo `jq` con su propio assert. El gatekeeper midio que
# ninguno estaba probado: quitar `.roles.enabled == true` dejaba la suite en verde Y dejaba
# pasar una capa 1 APAGADA. Los fixtures 16-18 fallaban por OTRO conjunto que el que su
# nombre anuncia -- aislar no es discriminar.
#
# Cada caso deja TODOS los conjuntos validos salvo UNO, para que solo pueda fallar por ese.
# OJO con el escape: JSON necesita `\\.` para producir el regex `\.`. Con cuatro barras el
# regex quedaba "barra literal + cualquier caracter" y NO casaba `.github/...`, asi que estos
# asserts pasaban por globs INVALIDOS y no por el conjunto que dicen probar. Vacuos otra vez.
GLOBS_OK='["^\\.github/.*","^tools/.*","^tests/.*","(^|/)\\.claude/agents/config\\.json$","(^|/)\\.claude/.*\\.(mjs|sh|bash)$"]'
cfg_case "{\"roles\":{\"enabled\":false,\"shadow\":false,\"risk_globs\":$GLOBS_OK}}" 1 \
  "SOLO enabled:false (lo demas valido) => FALLA"
cfg_case "{\"roles\":{\"enabled\":true,\"shadow\":true,\"risk_globs\":$GLOBS_OK}}" 1 \
  "SOLO shadow:true (lo demas valido) => FALLA"
cfg_case '{"roles":{"enabled":true,"shadow":false,"risk_globs":["^tools/.*","^tests/.*","(^|/)\\.claude/agents/config\\.json$","(^|/)\\.claude/.*\\.(mjs|sh|bash)$","^docs/.*"]}}' 1 \
  "SOLO quitan el glob de .github (5 globs igual) => FALLA"
cfg_case "{\"roles\":{\"enabled\":true,\"risk_globs\":$GLOBS_OK}}" 1 \
  "SOLO falta shadow (ausente, no false) => FALLA"

# 35-37. B1: el assert 20 cubria DOS defensas superpuestas -- la exclusion de `*TEMPLATE*` y el
# anclaje de la marca -- asi que quitar cualquiera de las dos dejaba la suite VERDE. Solo moria
# con las dos a la vez. Un assert que cubre dos mecanismos no pinnea ninguno: es la clase
# "arreglar un bug no inmuniza contra repetirlo al lado", en el codigo que la cita.
# Aqui va uno por mecanismo, cada uno construido para que SOLO pueda fallar por el suyo.

# 35 / 35b / 35c. PARIDAD CON EL HARNESS, y el ancla que SI sirve.
# La version de la ronda 4 exigia la marca PELADA en columna 0. Medido: rechazaba (a) el formato
# `**Roles-Validated: GO**` que se escribe de verdad en los reviews, y (b) el formato
# `> Roles-Validated: GO` que role-gate.mjs:85 INSTRUYE escribir. O sea: 100% de falsos positivos
# sobre artefactos legitimos, y ni un adversario menos -- quien quiera burlar el gate escribe la
# marca pelada, que era justo lo unico que pasaba. Dos gates sobre el MISMO artefacto tienen que
# usar el MISMO predicado: si divergen, uno de los dos esta garantizadamente equivocado.
# El predicado ahora es identico a role-gate.mjs:20. Lo que el ancla `^` si compra esta en 35c.

# 35. El formato REAL de los reviews de este repo: decorado con **
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Contexto\n\n**Roles-Validated: GO** (seguridad + gatekeeper, 4 rondas)\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-real.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-07-real.md
git -C "$d" commit -qm "feat: marca decorada, como se escribe de verdad"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "PARIDAD: marca con ** (el formato real) => PASA"

# 35b. El formato que el propio harness instruye (role-gate.mjs:85)
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Contexto\n\n> Roles-Validated: GO (a + b + c, 3 rondas, 2026-08-07)\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-real.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-07-real.md
git -C "$d" commit -qm "feat: marca citada, formato que instruye el harness"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 0 $? "PARIDAD: marca con > (formato de role-gate.mjs:85) => PASA"

# 35c. Lo que el ancla `^` SI compra: una MENCION a mitad de linea no es un veredicto.
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Este review explica que hay que poner Roles-Validated: GO al cerrar el loop.\n' > "$d/docs/reviews/ROLE-REVIEW-2026-08-07-real.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-2026-08-07-real.md
git -C "$d" commit -qm "feat: solo MENCIONA la marca a mitad de linea"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "ANCLA: mencion a mitad de linea NO es veredicto => FALLA"

# 36. SOLO la exclusion de TEMPLATE: marca SIN decorar, pero en una plantilla
d=$(nuevo_repo)
echo "on: push" > "$d/.github/workflows/x.yml"
printf 'Roles-Validated: GO\n' > "$d/docs/reviews/ROLE-REVIEW-TEMPLATE.md"
git -C "$d" add .github/workflows/x.yml docs/reviews/ROLE-REVIEW-TEMPLATE.md
git -C "$d" commit -qm "feat: marca limpia pero en la PLANTILLA"
( cd "$d" && bash "$GATE" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" ) >/dev/null 2>&1
ok 1 $? "SOLO TEMPLATE: marca limpia en una plantilla => FALLA"

# 37. El chequeo de RAMA RESOLUBLE del modo --tag. El assert 25 solo moria apagando el modo
# entero: con la rama irresoluble el gate caia igual en rojo, pero por `merge-base` con REF
# vacio, no por el chequeo que su nombre anuncia. Este exige el mensaje concreto.
d=$(nuevo_repo)
salida=$( cd "$d" && bash "$GATE" --tag "$(git rev-parse HEAD)" no-existe 2>&1 )
case "$salida" in
  *"No se pudo resolver la rama vigilada"*) ok 0 0 "rama irresoluble: FALLA POR SU PROPIO motivo";;
  *) ok 0 1 "rama irresoluble: FALLA POR SU PROPIO motivo";;
esac

echo; echo "RESULTADO: $fallos fallo(s)"
[ "$fallos" -eq 0 ]
