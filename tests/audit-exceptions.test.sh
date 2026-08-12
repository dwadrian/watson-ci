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

echo
if [ "$FALLOS" -eq 0 ]; then
  echo "audit-exceptions: TODO VERDE"
else
  echo "audit-exceptions: $FALLOS fallo(s) — NO publicar el tag"
fi
exit $((FALLOS > 0))
