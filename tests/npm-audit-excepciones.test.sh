#!/usr/bin/env bash
# ==============================================================================
# npm-audit-excepciones.test.sh — el filtro de excepciones del paso `npm audit` de verify-node.
#
# Llama al MISMO script que ejecuta la receta (tools/npm-audit-excepciones.mjs); no duplica su
# lógica. Fecha fija (--hoy) para que ningún caso caduque solo. El fixture audit-picomatch.json es
# una captura real de `npm audit --json --omit=dev` con un HIGH sin versión corregida (9 paquetes
# high: el advisory y sus 8 dependientes transitivos, que solo existen por él).
#
# Uso:  bash tests/npm-audit-excepciones.test.sh
# Exit: 0 = todo afirmado · 1 = algún veredicto cambió
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
command -v node >/dev/null || { echo '⛔ falta node'; exit 1; }

S=tools/npm-audit-excepciones.mjs
FX=tests/fixtures/npm-excepciones
HOY=2026-11-17
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FALLOS=0
ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; echo "      esperado: $2"; echo "      obtenido: $3"; FALLOS=$((FALLOS + 1)); }

# suma <días> -> fecha HOY+días (UTC)
suma() { node -e 'console.log(new Date(Date.parse(process.argv[1]+"T00:00:00Z")+process.argv[2]*864e5).toISOString().slice(0,10))' "$HOY" "$1"; }

CAB='| Aviso (CVE o GHSA) | Paquete | Severidad | Motivo | Quién la aceptó | Fecha de revisión |
|---|---|---|---|---|---|'
# tabla <archivo> <fila>... : documento con la sección «Excepciones vigentes» y esas filas
tabla() { local f="$1"; shift; { printf '# Dependencias\n\nprosa\n\n### Excepciones vigentes\n\n%s\n' "$CAB"; for r in "$@"; do printf '%s\n' "$r"; done; printf '\n## Otra sección\n\n| x | y |\n|---|---|\n| GHSA-zzzz-zzzz-zzzz | nada | 2099-01-01 |\n'; } > "$f"; }
fila() { printf '| [%s](https://github.com/advisories/%s) | %s | HIGH | sin parche; no alcanzable | Operación | %s |' "$1" "$1" "$2" "$3"; }

# corre <audit.json> [tabla.md|-] -> "rc|<paquetes bloqueantes>" ; stdout+stderr en $TMP/out
corre() {
  local a="$FX/$1" t="${2:--}"; [ "$t" = "-" ] && t="$TMP/no-existe.md"
  node "$S" --tabla "$t" --audit "$a" --hoy "$HOY" >"$TMP/out" 2>&1; local rc=$?
  printf '%s|%s' "$rc" "$(grep -c '^  - ' "$TMP/out")"
}
espera() { # <descripción> <esperado> <obtenido>
  [ "$2" = "$3" ] && ok "$1" || fail "$1" "$2" "$3"
}
hay() { grep -qF -- "$2" "$TMP/out" && ok "$1" || fail "$1" "el log contiene «$2»" "$(head -c 300 "$TMP/out")"; }

echo "── rojo antes / verde después (picomatch, GHSA sin versión corregida)"
espera "sin tabla: bloquea los 9 paquetes (igual que npm audit --audit-level=high)" "1|9" "$(corre audit-picomatch.json)"
tabla "$TMP/ok.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")"
espera "con la fila vigente: verde (la severidad de los 8 dependientes se recalcula)" "0|0" "$(corre audit-picomatch.json "$TMP/ok.md")"
hay "el log lista la excepción aplicada" "excepción aplicada: GHSA-FC5Q-39XC-VJPF (picomatch)"
hay "el log dice hasta cuándo" "revisar antes de $(suma 30)"

echo "── caducidad: >= hoy y <= hoy+90"
for caso in "0:0|0:vence hoy (límite, pasa)" "-1:1|9:vencida ayer" "90:0|0:hoy+90 (límite, pasa)" "91:1|9:hoy+91 (fuera de ventana)"; do
  d="${caso%%:*}"; rest="${caso#*:}"; exp="${rest%%:*}"; desc="${rest#*:}"
  tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma "$d")")"
  espera "$desc" "$exp" "$(corre audit-picomatch.json "$TMP/f.md")"
done
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma -3)")"
corre audit-picomatch.json "$TMP/f.md" >/dev/null; hay "vencida: el log lo dice" "VENCIDA: GHSA-FC5Q-39XC-VJPF"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 120)")"
corre audit-picomatch.json "$TMP/f.md" >/dev/null; hay "fuera de ventana: el log lo dice" "FUERA DE VENTANA"

echo "── la coincidencia exige aviso Y paquete"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf otro-paquete "$(suma 30)")"
espera "mismo aviso, paquete distinto: rojo" "1|9" "$(corre audit-picomatch.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-aaaa-bbbb-cccc picomatch "$(suma 30)")"
espera "mismo paquete, aviso distinto: rojo" "1|9" "$(corre audit-picomatch.json "$TMP/f.md")"
corre audit-picomatch.json "$TMP/f.md" >/dev/null; hay "la excepción sin hallazgo se marca huérfana" "HUÉRFANA"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf PICOMATCH "$(suma 30)")"
espera "paquete en otras mayúsculas: sigue exento" "0|0" "$(corre audit-picomatch.json "$TMP/f.md")"
printf '%s\n' '### Excepciones vigentes' '' "$CAB" '| GHSA-fc5q-39xc-vjpf | picomatch | HIGH | sin parche | Operación | '"$(suma 30)"' |' > "$TMP/f.md"
espera "sin enlaces markdown en la celda: también casa" "0|0" "$(corre audit-picomatch.json "$TMP/f.md")"

echo "── el aviso se identifica por el GHSA de la URL del aviso, nunca por lo que diga su título"
# Un aviso NUEVO y critical cuyo título MENCIONA otro aviso (p. ej. «Incomplete fix for CVE-…») no
# hereda la exención de ese otro. npm audit no trae el CVE en el JSON: una fila CVE no puede casar.
tabla "$TMP/f.md" "| CVE-2026-1111 | foo | HIGH | sin parche | Operación | $(suma 30) |"
espera "fila CVE nombrada en el título de OTRO aviso (url GHSA distinta): rojo" "1|1" "$(corre audit-titulo-menciona.json "$TMP/f.md")"
corre audit-titulo-menciona.json "$TMP/f.md" >/dev/null; hay "la fila CVE sin casar se marca huérfana" "HUÉRFANA"
tabla "$TMP/f.md" "$(fila GHSA-aaaa-bbbb-cccc foo "$(suma 30)")"
espera "fila GHSA nombrada solo en el título (url GHSA distinta): rojo" "1|1" "$(corre audit-titulo-menciona.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-zzzz-yyyy-xxxx foo "$(suma 30)")"
espera "fila con el GHSA de la URL: verde" "0|0" "$(corre audit-titulo-menciona.json "$TMP/f.md")"

echo "── una excepción no exime más de lo que nombra"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")"
espera "mixto: picomatch exento, pero 'ajeno' y 'mixto' tienen avisos propios" "1|2" "$(corre audit-mixto.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")" "$(fila GHSA-aaaa-bbbb-cccc ajeno "$(suma 30)")" "$(fila GHSA-dddd-eeee-ffff mixto "$(suma 30)")"
espera "mixto: las tres exentas, verde" "0|0" "$(corre audit-mixto.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")" "$(fila GHSA-aaaa-bbbb-cccc ajeno "$(suma 30)")"
espera "mixto: falta eximir 'mixto' (su propio aviso), rojo" "1|1" "$(corre audit-mixto.json "$TMP/f.md")"
espera "audit limpio, sin tabla: verde" "0|0" "$(corre audit-limpio.json)"

echo "── sin tabla = comportamiento de siempre"
printf '# Dependencias\n\nSin sección de excepciones. GHSA-fc5q-39xc-vjpf picomatch %s\n' "$(suma 30)" > "$TMP/f.md"
espera "documento sin la sección: rojo como sin documento" "1|9" "$(corre audit-picomatch.json "$TMP/f.md")"
tabla "$TMP/f.md" '| _(ninguna todavía)_ | — | — | — | — | — |'
espera "tabla solo con la fila «ninguna todavía»: rojo" "1|9" "$(corre audit-picomatch.json "$TMP/f.md")"
node "$S" --hay-tabla "$TMP/no-existe.md"; espera "--hay-tabla: archivo ausente = 3" "3" "$?"
node "$S" --hay-tabla "$TMP/f.md"; espera "--hay-tabla: con sección = 0" "0" "$?"
printf 'solo prosa\n' > "$TMP/g.md"; node "$S" --hay-tabla "$TMP/g.md"; espera "--hay-tabla: sin sección = 3" "3" "$?"

echo "── tabla mal formada: ERROR (2), nunca verde ni «sin excepciones» silencioso"
mal() { # <descripción> <fila>
  tabla "$TMP/f.md" "$2"; espera "$1" "2|0" "$(corre audit-picomatch.json "$TMP/f.md")"
}
mal "fecha inexistente (2026-02-30)" "$(fila GHSA-fc5q-39xc-vjpf picomatch 2026-02-30)"
mal "fecha en otro formato" "$(fila GHSA-fc5q-39xc-vjpf picomatch 17/12/2026)"
mal "fecha vacía" "$(fila GHSA-fc5q-39xc-vjpf picomatch '')"
mal "identificador con comodín" "$(fila 'GHSA-*' picomatch "$(suma 30)")"
mal "identificador que no es GHSA/CVE" "$(fila 'all' picomatch "$(suma 30)")"
mal "paquete con comodín" "$(fila GHSA-fc5q-39xc-vjpf '*' "$(suma 30)")"
mal "5 columnas" "| GHSA-fc5q-39xc-vjpf | picomatch | HIGH | sin parche | $(suma 30) |"
mal "motivo vacío" "| GHSA-fc5q-39xc-vjpf | picomatch | HIGH | — | Operación | $(suma 30) |"
printf '### Excepciones vigentes\n\n| Aviso | Paquete | Fecha |\n|---|---|---|\n| GHSA-fc5q-39xc-vjpf | picomatch | %s |\n' "$(suma 30)" > "$TMP/f.md"
espera "cabecera distinta de las 6 columnas" "2|0" "$(corre audit-picomatch.json "$TMP/f.md")"
printf '### Excepciones vigentes\n\n%s\n%s\n\n### Excepciones vigentes\n' "$CAB" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")" > "$TMP/f.md"
espera "dos encabezados «Excepciones vigentes»" "2|0" "$(corre audit-picomatch.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")" "$(fila GHSA-fc5q-39xc-vjpf picomatch 2026-13-45)"
espera "una fila buena y una mala: el archivo entero falla" "2|0" "$(corre audit-picomatch.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 80)")" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 120)")"
espera "duplicado: manda la fecha más temprana (80 → exime)" "0|0" "$(corre audit-picomatch.json "$TMP/f.md")"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma -1)")" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")"
espera "duplicado: la vencida gana sobre la vigente (no se extiende por merge)" "1|9" "$(corre audit-picomatch.json "$TMP/f.md")"

echo "── fail-closed: sin reporte real de npm audit no hay verde"
tabla "$TMP/ok.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(suma 30)")"
: > "$TMP/vacio.json"; printf 'npm ERR! network\n' > "$TMP/texto.json"; printf '{"foo":1}\n' > "$TMP/forma.json"; printf '{"vulnerabilities":[]}\n' > "$TMP/arr.json"
printf '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"high":3,"critical":0}}}\n' > "$TMP/incoherente.json"
for f in vacio.json texto.json forma.json arr.json incoherente.json; do
  node "$S" --tabla "$TMP/ok.md" --audit "$TMP/$f" --hoy "$HOY" >/dev/null 2>&1; espera "audit no utilizable ($f): exit 2" "2" "$?"
done
espera "ENOLOCK (JSON válido con .error): exit 2, con tabla vigente" "2|0" "$(corre audit-enolock.json "$TMP/ok.md")"
node "$S" --tabla "$TMP/ok.md" --audit "$TMP/no-existe.json" --hoy "$HOY" >/dev/null 2>&1; espera "audit ausente: exit 2" "2" "$?"
node "$S" --tabla "$TMP/ok.md" >/dev/null 2>&1; espera "sin --audit: exit 2" "2" "$?"

echo "── sin --hoy usa la fecha real (UTC)"
tabla "$TMP/f.md" "$(fila GHSA-fc5q-39xc-vjpf picomatch "$(node -e 'console.log(new Date(Date.now()+30*864e5).toISOString().slice(0,10))')")"
node "$S" --tabla "$TMP/f.md" --audit "$FX/audit-picomatch.json" >/dev/null 2>&1; espera "hoy+30 con reloj real: exit 0" "0" "$?"

echo
if [ "$FALLOS" -eq 0 ]; then echo "✓ npm-audit-excepciones: todos los veredictos coinciden."; exit 0; fi
echo "✗ $FALLOS veredicto(s) cambiaron."; exit 1
