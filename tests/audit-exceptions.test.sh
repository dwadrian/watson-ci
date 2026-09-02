#!/usr/bin/env bash
# ==============================================================================
# audit-exceptions.test.sh — el filtro de excepciones que CADUCAN, contra corpus REAL.
#
# POR QUE EXISTE, y por que los fixtures son capturas de verdad:
# este script decide si un advisory bloquea o no en los 17 repos. Cada cifra de aqui salio de
# ejecutar la herramienta real contra un repo real; ninguna esta inventada. Esa disciplina no es
# ceremonia: los tres hallazgos que mas cambiaron el diseno NO habrian aparecido con datos
# inventados —
#   · npm: de 12 entradas `high`, solo UNA lleva identificador; las otras 11 son transitivas.
#   · composer: `cve` es null en 4 de 6, y dice `medium` donde npm dice `moderate`.
#   · pip-audit: NO TIENE campo de severidad, y cada vuln trae TRES identidades.
#
# A diferencia de expect-audit-decision.sh, este NO duplica la expresion jq de la receta:
# llama al MISMO script que llamara la receta. No puede divergir de lo que se ejecuta.
#
# Uso:  bash tests/audit-exceptions.test.sh
# Exit: 0 = todo verde · 1 = algun veredicto cambio
# ==============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FALLOS=0
FILTRO=tools/audit-exceptions.sh
FIX=tests/fixtures/audit
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; echo "      esperado: $2"; echo "      obtenido: $3"; FALLOS=$((FALLOS + 1)); }

# Fechas relativas: un fixture con fecha fija caducaria y el test empezaria a fallar solo.
VIGENTE="$(jq -rn 'now + (30*86400) | strftime("%Y-%m-%d")')"
AYER="$(jq -rn 'now - 86400 | strftime("%Y-%m-%d")')"
HOY="$(jq -rn 'now | strftime("%Y-%m-%d")')"
TOPE="$(jq -rn 'now + (90*86400) | strftime("%Y-%m-%d")')"      # el limite exacto: debe PASAR
PASADO="$(jq -rn 'now + (91*86400) | strftime("%Y-%m-%d")')"    # uno mas: debe MORIR
TARDIA="$(jq -rn 'now + (60*86400) | strftime("%Y-%m-%d")')" 

# corre <ecosistema> <fixture> <linea>...  -> imprime "rc|<conteo>"; deja stderr en $TMP/err
corre() {
  local eco="$1" fix="$2"; shift 2
  local exc="$TMP/e.txt"; : > "$exc"
  for l in "$@"; do printf '%s\n' "$l" >> "$exc"; done
  local out rc
  out="$(bash "$FILTRO" --filter "$exc" "$eco" < "$FIX/$fix" 2>"$TMP/err")"; rc=$?
  local n
  case "$eco" in
    npm)       n="$(printf '%s' "$out" | jq '[.vulnerabilities[]?|select(.severity=="high")]|length' 2>/dev/null || echo x)" ;;
    composer)  n="$(printf '%s' "$out" | jq '[.advisories[]?[]?|select(.severity=="high")]|length' 2>/dev/null || echo x)" ;;
    pip-audit) n="$(printf '%s' "$out" | jq '[.dependencies[]?.vulns[]?]|length' 2>/dev/null || echo x)" ;;
  esac
  printf '%s|%s' "$rc" "$n"
}

echo "── npm: clausura con severidad EFECTIVA (corpus real de una app Expo)"

r="$(corre npm npm-makro-12high.json)"
[ "$r" = "1|12" ] && ok "sin exenciones: 12 high, bloquea" || fail "control npm" "1|12" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE sin parche upstream" \
                                     "GHSA-5p2g-fcmc-qvqq $VIGENTE idem")"
# LA regla: se RECALCULA la severidad efectiva, no se decide supervivencia. Con
# «sobrevive si alcanza un advisory vivo» esto daria 3 high, porque un advisory MODERATE
# de uuid sostiene tres paquetes high por @expo/config -> config-plugins -> xcode -> uuid.
[ "$r" = "0|0" ] && ok "los 2 GHSA exentos: 0 high (severidad recalculada)" \
  || fail "clausura npm — la regla que dos specs no supieron fijar" "0|0" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE solo uno de los dos")"
[ "$r" = "1|12" ] && ok "SOBRE-EXENCION: 1 de 2 exento sigue bloqueando los 12" \
  || fail "sobre-exencion npm" "1|12" "$r"

echo "── fail-closed: donde este mecanismo se gana o se pierde"

r="$(corre npm npm-vacio.json "GHSA-w3rx-r6r6-pgpr $VIGENTE x")"
[ "${r%%|*}" = "2" ] && ok "stdin vacio: exit 2, jamas '0 hallazgos'" \
  || fail "stdin vacio (printf '' | jq sale rc=0 SIN salida)" "2|*" "$r"

r="$(corre npm npm-enolock-error.json "GHSA-w3rx-r6r6-pgpr $VIGENTE x")"
# npm en ENOLOCK sale rc=1 IGUAL que el camino feliz, y emite JSON VALIDO con .error:
# el discriminante no puede ser el exit code, tiene que ser la FORMA del JSON.
[ "${r%%|*}" = "2" ] && ok "JSON valido de FORMA INCORRECTA (.error): exit 2" \
  || fail "el audit murio y se leyo como repo limpio" "2|*" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr esto-no-es-fecha x")"
[ "${r%%|*}" = "2" ] && ok "archivo malformado: no exime NADA" || fail "archivo malformado" "2|*" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr 2026-02-30 fecha imposible")"
[ "${r%%|*}" = "2" ] && ok "30 de febrero: invalida (round-trip)" || fail "30-feb rueda a marzo" "2|*" "$r"

for id in 'GHSA-*' 'all' '*'; do
  r="$(corre npm npm-makro-12high.json "$id $VIGENTE comodin")"
  [ "${r%%|*}" = "2" ] && ok "comodin '$id' rechazado" || fail "comodin '$id' aceptado" "2|*" "$r"
done

r="$(corre npm npm-makro-12high.json "GHSA-w3rx $VIGENTE prefijo")"
[ "$r" = "1|12" ] && ok "prefijo NO exime (igualdad exacta, no substring)" || fail "prefijo" "1|12" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $AYER vencida" \
                                     "GHSA-5p2g-fcmc-qvqq $VIGENTE viva")"
[ "$r" = "1|12" ] && ok "excepcion VENCIDA no exime" || fail "caducidad" "1|12" "$r"
grep -qi "VENCIDA" "$TMP/err" && ok "…y la salida la NOMBRA" \
  || fail "vencida silenciosa (manda al --no-verify)" "VENCIDA en stderr" "$(head -1 "$TMP/err")"

echo "── composer: el 'fallback' a advisoryId es el caso MAYORITARIO"

r="$(corre composer composer-zigterback-6adv.json)"
[ "$r" = "1|4" ] && ok "sin exenciones: 4 high, bloquea" || fail "control composer" "1|4" "$r"

r="$(corre composer composer-zigterback-6adv.json \
      "PKSA-cqd6-fg4n-nxpf $VIGENTE x" "PKSA-1q6p-sqkj-8mmj $VIGENTE x" \
      "PKSA-mc58-w91n-f5gv $VIGENTE x" "CVE-2026-71488 $VIGENTE x")"
# 4 de 6 advisories tienen cve=null: casar solo por CVE dejaria 3 high en pie.
[ "$r" = "0|0" ] && ok "se exime por advisoryId (PKSA) cuando cve es null" \
  || fail "composer por PKSA" "0|0" "$r"

echo "── pip-audit: sin severidad, y con TRES identidades por vuln"

r="$(corre pip-audit pipaudit-jinja2-6vulns.json)"
[ "$r" = "1|6" ] && ok "sin exenciones: 6 vulns, bloquea (no hay umbral)" || fail "control pip" "1|6" "$r"

r="$(corre pip-audit pipaudit-jinja2-6vulns.json "CVE-2020-28493 $VIGENTE alias, no el id")"
# id=PYSEC-2021-66, aliases=[SNYK-…, GHSA-…, CVE-2020-28493]. Quien busca el advisory
# encuentra el CVE, no el PYSEC: exigir el id seria una trampa de usabilidad.
[ "$r" = "1|5" ] && ok "se exime por un ALIAS (el CVE)" || fail "alias pip-audit" "1|5" "$r"


echo "── las tres propiedades que el plan daba por buenas y que NADIE defendia (2026-09-02)"
# Un revisor adversarial de shell muto las tres y las TRES SOBREVIVIERON con la suite en verde:
#   MAX_DIAS=90 -> 99999  ·  el dedup `-k2,2n` -> `-k2,2nr`  ·  la frontera `>=` -> `>`
# Su formulacion, que es la que justifica estas lineas:
#   «"Constante" no es "protegida", y "lo comprobe leyendo" no es "hay algo que lo sostenga
#    manana". Una constante sin test esta a una edicion descuidada de valer 99999 sin que nada
#    se ponga rojo.»
# El plan lista las tres en "lo que el rol de seguridad ataco y aguanto", y las tres eran
# CIERTAS. Ciertas y sin red: la clase «tu medicion es CONSISTENTE con estar anclado, pero no
# lo demuestra».

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $TOPE sin parche, al limite exacto")"
[ "${r%%|*}" != "2" ] && ok "el TOPE exacto de 90 dias se ACEPTA (control positivo)" \
  || fail "el limite de 90 dias rechaza su propio limite" "rc != 2" "$r"

r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $PASADO sin parche, un dia de mas")"
[ "${r%%|*}" = "2" ] && ok "91 dias MUERE: una excepcion sin horizonte es un gate apagado" \
  || fail "el tope de MAX_DIAS no bloquea" "rc=2" "$r"

# Duplicados: gana la MAS TEMPRANA. Si ganara la tardia, un merge descuidado extenderia la
# exencion sin que nadie lo viera. Se prueban las DOS ordenaciones del fichero: con una sola,
# el test pasaria por el orden de escritura y no por la regla.
for orden in temprana-primero tardia-primero; do
  if [ "$orden" = temprana-primero ]; then L1="$AYER"; L2="$TARDIA"; else L1="$TARDIA"; L2="$AYER"; fi
  r="$(corre npm npm-makro-12high.json \
        "GHSA-w3rx-r6r6-pgpr $L1 duplicada" "GHSA-w3rx-r6r6-pgpr $L2 duplicada")"
  if grep -qi "VENCIDA" "$TMP/err"; then
    ok "duplicados ($orden): gana la fecha MAS TEMPRANA, y esa esta vencida"
  else
    fail "duplicados ($orden): gano la mas TARDIA — un merge puede extender la exencion" \
         "VENCIDA en stderr" "$(head -1 "$TMP/err")"
  fi
done

# La frontera: una excepcion que caduca HOY sigue VIGENTE (`>= $hoy`, no `>`).
#
# ⚠️ La PRIMERA version de este assert media el MENSAJE ("VENCIDA" en stderr) y el mutante
# `>= $hoy` -> `> $hoy` SOBREVIVIO en verde. Motivo, medido: la vigencia esta implementada
# DOS VECES en el filtro — el `select(.e >= $hoy)` de jq DECIDE quien exime, y el
# `[ $epoch -lt $HOY_EPOCH ]` de bash INFORMA. Hoy coinciden; son dos bloques distintos.
# Es «arregla el BLOQUE, no el consumidor», y su corolario: «el reporte no depende del
# RESULTADO». Un assert sobre el mensaje mide al que informa, no al que decide.
#
# Segunda trampa, tambien medida: `select(.severity=="high")` cuenta PAQUETES, no advisories,
# asi que eximir UN id no mueve el conteo. El unico observable del decisor es el VEREDICTO
# con todos los ids exentos: rc=0 si la exencion vale hoy, rc=1 si ya no.
IDS_HIGH="$(jq -r '[.vulnerabilities[]?|select(.severity=="high")|.via[]?|objects|.url//empty]|unique[]' \
             "$FIX/npm-makro-12high.json" | sed 's#.*/##')"
N_IDS="$(printf '%s\n' "$IDS_HIGH" | grep -c '^GHSA-')"
if [ "$N_IDS" -ne 2 ]; then
  # DOS fails, no uno: si el guardia emitiera uno solo, el total caeria a 22 y contradiria
  # el criterio de aceptacion que dice 23. Un guardia no puede romper el conteo que defiende.
  for _e in vigente-hoy vencida-ayer; do
    fail "frontera ($_e): el fixture ya no tiene los 2 GHSA que exime — sin ellos NO se mide" \
         "2 ids" "$N_IDS: $(printf '%s' "$IDS_HIGH" | tr '\n' ' ')"
  done
else
  for d in "$HOY|vigente-hoy|0" "$AYER|vencida-ayer|1"; do
    fecha="${d%%|*}"; rest="${d#*|}"; etiq="${rest%%|*}"; esperado="${rest##*|}"
    set --
    for i in $IDS_HIGH; do set -- "$@" "$i $fecha frontera"; done
    r="$(corre npm npm-makro-12high.json "$@")"
    [ "${r%%|*}" = "$esperado" ] \
      && ok "frontera ($etiq): el VEREDICTO es rc=$esperado — mide al que decide, no al que informa" \
      || fail "frontera ($etiq): la comparacion de vigencia cambio de sentido" "rc=$esperado" "$r"
  done
fi


echo "── el camino que INFORMA, y las guardas: lo que el gatekeeper midio indefenso (2026-09-02)"
# Los tres asserts de mensaje que ya habia eran TODOS positivos-para-VENCIDA, asi que un
# reportero que dijera "VENCIDA" siempre los satisfacia los tres. Medido: con VIVOS=""
# el filtro EXIME (rc=0) mientras el mensaje manda a bloquear — y la suite quedaba verde.
# «Un patron muerto colapsa los dos mundos en uno y siempre contesta lo mismo.»
r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE viva y presente")"
if grep -qF "✓ excepción aplicada" "$TMP/err" && ! grep -qi "VENCIDA" "$TMP/err"; then
  ok "una exencion VIVA se reporta '✓ aplicada' — el reporte discrimina, no dice siempre lo mismo"
else
  fail "el reportero no distingue viva de vencida" "✓ aplicada y sin VENCIDA" "$(head -2 "$TMP/err" | tr '\n' ' ')"
fi

# N-1: el id es una CADENA. Con `grep -qx` (sin -F) se trata como REGEX, y el charset de ids
# permite el punto: el patron `CVE-2020-2849.` casa la linea `CVE-2020-28493`. El decisor (jq,
# `index()` exacto) no se deja enganar, asi que era la divergencia decisor/reportero
# REINTRODUCIDA por el propio arreglo que la cerraba.
#
# ⚠️ La primera version de este assert buscaba "✓ aplicada" y pasaba con el mutante puesto:
# segun CUAL de los dos `grep` se rompa, la mentira sale como "✓ aplicada" o como
# "🧹 HUÉRFANA — bórrala". Un assert atado a UNO de los dos mensajes es un patron muerto.
# La propiedad que discrimina no es el texto del error: es que una VENCIDA se reporte VENCIDA.
r="$(corre pip-audit pipaudit-jinja2-6vulns.json "CVE-2020-2849. $AYER con punto, vencida" "CVE-2020-28493 $VIGENTE viva")"
if grep -qF "excepción VENCIDA: CVE-2020-2849." "$TMP/err"; then
  ok "el id se compara como CADENA: un punto no casa con el advisory vecino"
else
  fail "el id se compara como REGEX: un punto casa con otro advisory y la VENCIDA se reporta mal" \
       "⏰ VENCIDA para CVE-2020-2849." "$(grep -F '2849.' "$TMP/err" | head -1)"
fi

# Y el hermano, en el segundo grep: sin `-x` la comparacion es por SUBCADENA, asi que un id
# que sea PREFIJO de un hallazgo presente se reporta "aplicada" cuando en realidad no exime.
r="$(corre pip-audit pipaudit-jinja2-6vulns.json "CVE-2020-284 $VIGENTE prefijo, no exime")"
if grep -qF "HUÉRFANA: CVE-2020-284 " "$TMP/err"; then
  ok "un id PREFIJO se reporta HUÉRFANA, no 'aplicada' — igualdad exacta tambien al informar"
else
  fail "el segundo grep compara por subcadena: un prefijo se reporta como aplicado" \
       "🧹 HUÉRFANA para CVE-2020-284" "$(grep -F 'CVE-2020-284 ' "$TMP/err" | head -1)"
fi

# C1 sin red: revertir el arreglo ENTERO dejaba la suite verde. Ningun assert alimentaba una
# linea de 2 campos —la que crea una exencion SIN razon escrita, que es el rastro de auditoria
# por el que este fichero existe—. Las dos formas, porque son dos reversiones distintas.
r="$(corre npm npm-makro-12high.json "$(printf 'GHSA-w3rx-r6r6-pgpr\t%s' "$VIGENTE")")"
[ "${r%%|*}" = "2" ] && ok "linea de 2 campos con TABULADOR: rc=2, no 'valido' sin razon" \
  || fail "una linea sin razon pasa como valida (tab)" "rc=2" "$r"

r="$(corre npm npm-makro-12high.json "   GHSA-w3rx-r6r6-pgpr $VIGENTE")"
[ "${r%%|*}" = "2" ] && ok "linea de 2 campos con SANGRIA: rc=2, no 'valido' sin razon" \
  || fail "una linea sin razon pasa como valida (sangria)" "rc=2" "$r"

# C2 sin red: las dos guardas de la entrega sobrevivian a la mutacion. Se ejercita la que se
# puede disparar desde fuera —descriptor de salida cerrado—; la de `.bloqueantes` no numerico
# no se puede provocar sin mutar el filtro, y eso queda DECLARADO en la review, no listado
# como cerrado.
printf 'GHSA-5p2g-fcmc-qvqq %s todas\nGHSA-w3rx-r6r6-pgpr %s todas\n' "$VIGENTE" "$VIGENTE" > "$TMP/e2.txt"
bash "$FILTRO" --filter "$TMP/e2.txt" npm < "$FIX/npm-makro-12high.json" >&- 2>/dev/null; rc=$?
[ "$rc" = "2" ] && ok "salida CERRADA: rc=2 — una entrega fallida no se lee como 'sin bloqueantes'" \
  || fail "fail-open de entrega: el veredicto no llego y el rc dice que si" "rc=2" "rc=$rc"


echo "── lo que el gate de la ronda 2 refutó: dos suposiciones mías (2026-09-02)"
# H-2 · el veredicto del parser DEPENDIA DE LA PLATAFORMA y la suite no lo veia. Misma linea,
# tres awks, tres respuestas — y el RUNNER era el permisivo, en el campo que ES el rastro de
# auditoria. Estos dos asserts fijan el veredicto UNICO; sin ellos el arreglo se pierde en
# cuanto alguien vuelva a confiar en `[[:space:]]`.
# ⚠️ Cada plataforma solo ejercita la MITAD del par: macOS rechaza NBSP de forma nativa y acepta
# EM; alpine al reves; ubuntu aceptaba los DOS. Medido revirtiendo el predicado: macOS 1 fallo,
# alpine 1 fallo, ubuntu 2. Ninguno de los dos sobra — quitar uno deja una plataforma sin control.
#
# La razon va por `%s`, NO interpolada: la linea entera era la cadena de FORMATO de printf, asi que
# un `%` en una razon futura habria roto el fixture en silencio.
for inv in 'U+00A0 espacio-duro|\xc2\xa0' 'U+2003 em-space|\xe2\x80\x83'; do
  etiq="${inv%%|*}"; bytes="${inv##*|}"
  printf '%s %s %s\n' "GHSA-w3rx-r6r6-pgpr" "$VIGENTE" "$(printf "$bytes")" > "$TMP/inv.txt"
  bash "$FILTRO" --filter "$TMP/inv.txt" npm < "$FIX/npm-makro-12high.json" >/dev/null 2>&1
  rc=$?   # se captura AQUI: `$?` dentro del `||` es el estado del `[`, no el del script
  [ "$rc" = "2" ] && ok "razon hecha solo de $etiq: RECHAZADA — mismo veredicto en todo awk" \
    || fail "razon de $etiq aceptada: el veredicto depende de la plataforma" "rc=2" "rc=$rc"
done

# ⚠️ LIMITE DE ESTOS DOS ASSERTS, medido por mutacion. Quitando `LC_ALL=C` de los cuatro awk:
#   macOS/BSD  2 fallos   ·   alpine  TODO VERDE   ·   ubuntu  TODO VERDE
# Tienen dientes en 1 de 3, no en 2 de 3 — las DOS plataformas Linux se quedan verdes. (Lo escribi
# primero como "solo ubuntu" y el gate lo corrigio: era peor.) El CI corre en Linux, asi que jamas
# cazaria esta regresion: solo la caza quien desarrolla en un Mac.
#
# Y NO es un defecto del assert: el bug que vigila —BSD awk atragantandose con UTF-8 invalido—
# SOLO EXISTE en BSD awk. Pedirle a Linux que lo ejercite es pedirle al CI que reproduzca un bug
# que ahi no esta; es «medir donde el fallo se ve, no donde no se ve». Lo que falta no es otro
# assert de comportamiento: es ENFORCEMENT, y va justo debajo.
# La divergencia RESIDUAL que quedaba tras poner LC_ALL=C solo en `tr`: bytes UTF-8 invalidos
# SEGUIDOS de texto ASCII legitimo. macOS rechazaba (BSD awk revienta con ellos bajo UTF-8) y el
# runner aceptaba. La razon TIENE imprimibles ASCII, asi que el veredicto correcto es ACEPTAR.
printf '%s %s %s\n' "GHSA-w3rx-r6r6-pgpr" "$VIGENTE" "$(printf '\xff\xfe basura no-utf8')" > "$TMP/inv8.txt"
bash "$FILTRO" --filter "$TMP/inv8.txt" npm < "$FIX/npm-makro-12high.json" >/dev/null 2>"$TMP/e8"
rc=$?
[ "$rc" != "2" ] && ok "bytes UTF-8 invalidos + texto ASCII: ACEPTADA en toda plataforma" \
  || fail "bytes invalidos: el veredicto vuelve a depender del awk" "rc != 2" "rc=$rc · $(head -1 "$TMP/e8")"

# Y la mitad que no es el veredicto: el error de awk salia por STDERR, que ES el canal del reporte
# de excepciones (err() -> stderr -> $GITHUB_STEP_SUMMARY). Cuatro lineas de tripas encima del
# diagnostico. Un gate que ensucia su propio canal de reporte no es solo feo: tapa lo que dice.
if grep -q "awk:" "$TMP/e8"; then
  fail "las tripas de awk se filtran al canal del reporte de excepciones" \
       "stderr sin 'awk:'" "$(head -1 "$TMP/e8")"
else
  ok "el canal del reporte queda limpio: ni una linea de diagnostico interno de awk"
fi
# Control positivo: el predicado nuevo no suspende a una razon sana con acentos y no-ASCII.
r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE sin parche upstream — según el mantenedor ✅")"
[ "${r%%|*}" != "2" ] && ok "una razon real con acentos y emoji sigue siendo valida (no suspende a los sanos)" \
  || fail "el predicado de la razon rechaza texto legitimo" "rc != 2" "$r"

# H-1 · yo declare esta guarda "no disparable desde fuera sin mutar el filtro". FALSO, y lo
# probo un printf: un STREAM de dos documentos JSON hace que `jq -r .bloqueantes` emita "0\n0",
# que no es un numero. Declarar un hueco es correcto; declararlo IMPOSIBLE cierra la puerta a
# que alguien lo cubra — y es una afirmacion sobre el mundo que nadie iba a volver a mirar.
printf 'GHSA-w3rx-r6r6-pgpr %s stream de dos documentos\n' "$VIGENTE" > "$TMP/st.txt"
printf '{"vulnerabilities":{}}{"vulnerabilities":{}}\n' \
  | bash "$FILTRO" --filter "$TMP/st.txt" npm >/dev/null 2>"$TMP/sterr"; rc=$?
if [ "$rc" = "2" ] && grep -qF "ERROR INTERNO" "$TMP/sterr"; then
  ok "un stream de dos JSON dispara la guarda de .bloqueantes: rc=2 y ERROR INTERNO"
else
  fail "la guarda de .bloqueantes no salta con un veredicto no numerico" \
       "rc=2 + ERROR INTERNO" "rc=$rc · $(head -1 "$TMP/sterr")"
fi


# ── Invariante ESTATICO, y por que se suma en vez de sustituir ───────────────────────────────
# El assert de comportamiento de arriba solo puede ponerse rojo en macOS, asi que en el unico
# entorno que bloquea merges esta INSTALADO, no desplegado: si alguien borra el `LC_ALL=C` por
# "ruido", el CI lo deja pasar en verde. La propiedad que hay que proteger no es "el defecto no se
# reproduce" —eso solo es observable en BSD— sino "los cuatro awk del parser llevan LC_ALL=C", que
# es CONTABLE en cualquier plataforma.
#
# ⚠️ Un assert sobre el TEXTO del fuente es la clase que esta flota ya se comio: «un includes()
# sobre el fuente mide la documentacion del arreglo, no el arreglo». Por eso va SUMADO: el de
# comportamiento demuestra que la propiedad importa (donde puede), el estatico la hace cumplir en
# todas partes. El estatico SOLO seria ceremonia.
n_loc="$(grep -c "| LC_ALL=C awk '{" "$FILTRO")"
n_sin="$(grep -c "| awk '{" "$FILTRO")"
[ "$n_loc" = "4" ] && [ "$n_sin" = "0" ] \
  && ok "los 4 awk del parser llevan LC_ALL=C y ninguno va sin el (4/0) — contable en todo entorno" \
  || fail "un awk del parser perdio su LC_ALL=C: el veredicto vuelve a depender de la maquina" \
          "4 con LC_ALL=C y 0 sin" "$n_loc con / $n_sin sin"

echo
if [ "$FALLOS" -eq 0 ]; then
  echo "audit-exceptions: TODO VERDE"
else
  echo "audit-exceptions: $FALLOS fallo(s) — NO publicar el tag"
fi
exit $((FALLOS > 0))
