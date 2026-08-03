#!/usr/bin/env bash
# ==============================================================================
# expect-audit-decision.sh — verifica que la LOGICA DE DECISION de las recetas
# produzca el veredicto esperado sobre fixtures conocidos.
#
# POR QUE EXISTE: `selftest.yml` probaba que las recetas ARRANCAN, no que DECIDEN bien. Por eso
# `v2.2.0` y `v2.2.1` cambiaron que commits pasan y cuales fallan en toda la flota sin que nada
# lo detectara — y el unico run de selftest de la historia era anterior a ambos cambios.
#
# Este script extrae la MISMA expresion jq que usa la receta y la corre contra fixtures cuyo
# veredicto se conoce. Si un cambio futuro vuelve a abrir un fail-open, esto sale en rojo ANTES
# de publicar el tag.
#
# Uso: bash tests/expect-audit-decision.sh
# Exit: 0 = todos los veredictos coinciden · 1 = alguno cambio
# ==============================================================================
set -uo pipefail

FALLOS=0
ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; echo "      esperado: $2"; echo "      obtenido: $3"; FALLOS=$((FALLOS + 1)); }

cd "$(dirname "$0")/.." || exit 1

echo "── composer audit: advisory SIN campo severity"

FIX=tests/fixtures/php-advisory-sin-severidad/audit-sin-severidad.json

# Misma expresion que verify-php.yml. Si la receta cambia y esto no, el conteo diverge y el
# test falla — que es justo lo que queremos que pase.
UNKNOWN=$(jq '[.advisories[]?[]? | select((.severity // "unknown") == "unknown")] | length' "$FIX")
HIGHCRIT=$(jq '[.advisories[]?[]? | select((.severity // "unknown") | ascii_downcase | test("high|critical"))] | length' "$FIX")

[[ "$UNKNOWN" == "1" ]] && ok "detecta 1 advisory sin severidad" \
  || fail "conteo de advisories sin severidad" "1" "$UNKNOWN"

[[ "$HIGHCRIT" == "0" ]] && ok "no lo cuenta como high/critical (no tiene severidad)" \
  || fail "conteo high/critical" "0" "$HIGHCRIT"

# El veredicto de v3: UNKNOWN>0 sin allowlist => ROJO. En v2 esto era VERDE.
ALLOW=""
REMAIN=$(jq --arg allow "$ALLOW" '
  [.advisories[]?[]?
   | select((.severity // "unknown") == "unknown")
   | . as $a
   | select(($allow | split(",") | map(ascii_downcase | gsub("^\\s+|\\s+$";"")))
            | index(($a.cve // $a.advisoryId // "sin-id") | ascii_downcase) | not)]
  | length' "$FIX")
[[ "$REMAIN" == "1" ]] && ok "VEREDICTO: bloquea (v2 daba verde aqui)" \
  || fail "veredicto sin allowlist" "1 (bloquea)" "$REMAIN"

# Con el CVE en la allowlist debe pasar — si no, el escape declarado no sirve de nada.
ALLOW="CVE-0000-0001"
REMAIN=$(jq --arg allow "$ALLOW" '
  [.advisories[]?[]?
   | select((.severity // "unknown") == "unknown")
   | . as $a
   | select(($allow | split(",") | map(ascii_downcase | gsub("^\\s+|\\s+$";"")))
            | index(($a.cve // $a.advisoryId // "sin-id") | ascii_downcase) | not)]
  | length' "$FIX")
[[ "$REMAIN" == "0" ]] && ok "VEREDICTO: pasa con el CVE en audit-allow-cve" \
  || fail "veredicto con allowlist" "0 (pasa)" "$REMAIN"

# Un CVE distinto NO debe eximir: la allowlist es por id, no un interruptor global.
ALLOW="CVE-9999-9999"
REMAIN=$(jq --arg allow "$ALLOW" '
  [.advisories[]?[]?
   | select((.severity // "unknown") == "unknown")
   | . as $a
   | select(($allow | split(",") | map(ascii_downcase | gsub("^\\s+|\\s+$";"")))
            | index(($a.cve // $a.advisoryId // "sin-id") | ascii_downcase) | not)]
  | length' "$FIX")
[[ "$REMAIN" == "1" ]] && ok "VEREDICTO: un CVE ajeno NO exime (allowlist por id, no global)" \
  || fail "allowlist con CVE ajeno" "1 (bloquea)" "$REMAIN"

echo ""
echo "── pip-audit: proyecto sin lockfile auditable"

if [[ -f tests/fixtures/python-sin-lock/pyproject.toml ]]; then
  ok "fixture presente (veredicto esperado: ROJO — en v2 era exit 0)"
else
  fail "fixture python-sin-lock" "pyproject.toml presente" "ausente"
fi

echo ""
if [[ "$FALLOS" -eq 0 ]]; then
  echo "✓ Todos los veredictos coinciden con lo esperado."
  exit 0
fi
echo "✗ $FALLOS veredicto(s) cambiaron. Un gate que cambia de veredicto sin que nadie lo pidiera"
echo "  es exactamente la regresion que este script existe para cazar. NO publiques el tag."
exit 1
