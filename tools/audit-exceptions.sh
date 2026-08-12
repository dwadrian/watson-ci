#!/usr/bin/env bash
# ==============================================================================
# audit-exceptions.sh — excepciones de dependencias que CADUCAN.
#
# PROTOTIPO. Su sitio final es `watson-ci/tools/`, consumido por las recetas y por
# `ci-local.sh` (extraído del TAG pineado, jamás del árbol de trabajo de un repo público).
# Vive aquí primero porque dos versiones de la spec fueron NO-GO por la misma causa:
# **especificar un algoritmo en prosa deja dos lecturas**. Este archivo fija la lectura.
#
# POR QUÉ EXISTE: un advisory HIGH sin parche upstream no tiene hoy salida proporcionada.
# Las dos opciones reales son no empujar nada, o `--no-verify`, que apaga los NUEVE gates
# cuando el rojo era uno. Medido en makro_logistica el 2026-08-07.
#
# USO
#   audit-exceptions.sh --validate <archivo>
#   audit-exceptions.sh --filter   <archivo> <ecosistema>   < audit.json  > filtrado.json
#
# EXIT (contrato — el 2 es distinto del 1 A PROPÓSITO: "murió" no puede leerse como "bloqueó")
#   0  nada bloqueante tras filtrar
#   1  quedan hallazgos bloqueantes
#   2  ERROR: archivo de excepciones inválido, o entrada no utilizable
# ==============================================================================
set -uo pipefail

UMBRAL="${AUDIT_LEVEL:-high}"     # severidad a partir de la cual se bloquea
MAX_DIAS=90                       # tope de la ventana; una excepción a 2099 es un gate apagado

err() { printf '%s\n' "$*" >&2; }          # SIEMPRE printf '%s': la razón es texto libre
die() { err "⛔ $*"; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq no está instalado — sin jq no se puede decidir, y ante falta de dato se bloquea."

# ── Fechas: jq, NO date ───────────────────────────────────────────────────────
# `date -d` es GNU y no existe en macOS; `date -j -f` es BSD y no existe en Linux.
# Ramificar por `uname` duplica la lógica de caducidad en dos ramas de las que solo una
# se prueba en cada entorno. `jq strptime|mktime` es timegm: UTC real, invariante al huso
# (medido idéntico en Asia/Tokyo, America/Los_Angeles y sin TZ).
HOY_EPOCH="$(jq -n 'now|todate[0:10]|strptime("%Y-%m-%d")|mktime')" || die "no pude calcular la fecha de hoy"

# Valida una fecha en TRES pasos. El 3º no es ceremonia: sin round-trip, `2026-02-30`
# pasa y se convierte en `2026-03-02` — un typo ALARGA la excepción. Medido.
fecha_epoch() {
  local f="$1"
  [[ "$f" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1     # 1: forma estricta
  local e rt
  e="$(jq -rn --arg f "$f" '$f|strptime("%Y-%m-%d")|mktime' 2>/dev/null)" || return 1   # 2
  rt="$(jq -rn --argjson e "$e" '$e|strftime("%Y-%m-%d")' 2>/dev/null)" || return 1
  [ "$rt" = "$f" ] || return 1                                # 3: round-trip
  printf '%s' "$e"
}

# ── Lectura y validación del archivo ─────────────────────────────────────────
# Salida: líneas `id<TAB>epoch` en $VALIDAS. Una línea mala invalida el archivo ENTERO:
# ignorar solo la mala deja que un typo ensanche el hueco en silencio.
VALIDAS=""
leer_archivo() {
  local ruta="$1"
  [ -e "$ruta" ] || { VALIDAS=""; return 0; }                # ausente = opt-in, sin cambio
  [ -f "$ruta" ] || die "$ruta no es un fichero regular."
  local n; n="$(wc -l < "$ruta" | tr -d ' ')"
  [ "$n" -le 200 ] || die "$ruta tiene $n líneas (máx 200)."

  local ln=0 id fecha resto epoch acc=""
  # `|| [ -n "$id" ]`: sin esto se pierde la última línea si el archivo no acaba en \n
  # (medido: 2 líneas sin newline final => `while read` cuenta 1). La dirección sería
  # fail-closed, pero --validate diría "válido" y el push bloquearía sin nombrar nada.
  while IFS= read -r linea || [ -n "$linea" ]; do
    ln=$((ln+1))
    case "$linea" in
      '#'*) continue ;;                                       # comentario
    esac
    [[ "$linea" =~ ^[[:space:]]*$ ]] && continue              # blanco = espacios, no solo vacío
    case "$linea" in
      '<<<<<<<'*|'======='*|'>>>>>>>'*)
        die "$ruta:$ln — marcador de conflicto de merge sin resolver." ;;
    esac
    id="$(printf '%s' "$linea" | awk '{print $1}')"
    fecha="$(printf '%s' "$linea" | awk '{print $2}')"
    resto="$(printf '%s' "$linea" | cut -d' ' -f3-)"
    [ -n "$id" ] && [ -n "$fecha" ] && [ -n "$resto" ] \
      || die "$ruta:$ln — se esperan 3 campos: <ID> <YYYY-MM-DD> <razón>."
    # Charset del ID. Sin esto, `GHSA-*` se cuela y la comparación idiomática de bash
    # (`[[ $x == $exc ]]`, RHS sin comillas) lo convierte en comodín. Medido: matchea.
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "$ruta:$ln — ID inválido '$id': solo [A-Za-z0-9._-], sin comodines."
    case "$(printf '%s' "$id" | tr 'A-Z' 'a-z')" in
      all|any|'*') die "$ruta:$ln — '$id' es un escape global; solo IDs concretos." ;;
    esac
    epoch="$(fecha_epoch "$fecha")" \
      || die "$ruta:$ln — fecha '$fecha' inválida (formato YYYY-MM-DD y que exista)."
    if [ "$(( (epoch - HOY_EPOCH) / 86400 ))" -gt "$MAX_DIAS" ]; then
      die "$ruta:$ln — '$fecha' está a más de $MAX_DIAS días: una excepción sin horizonte es un gate apagado."
    fi
    # Se guarda el ID normalizado (para comparar) Y el original (para MOSTRAR). Devolver
    # una version mutilada de la linea que escribio el usuario hace que no encuentre su
    # propio ID en la salida -- lo cazo el test del listado.
    acc="$acc$(printf '%s\t%s\t%s' "$(printf '%s' "$id" | tr 'A-Z' 'a-z')" "$epoch" "$id")
"
  done < "$ruta"
  # Duplicados: gana la fecha MÁS TEMPRANA — un merge descuidado no puede extender una exención.
  VALIDAS="$(printf '%s' "$acc" | grep -v '^$' | sort -t"$(printf '\t')" -k1,1 -k2,2n | awk -F'\t' '!seen[$1]++')"
}

modo="${1:-}"; archivo="${2:-}"
[ -n "$modo" ] && [ -n "$archivo" ] || die "uso: $0 --validate|--filter <archivo> [ecosistema]"

leer_archivo "$archivo"

if [ "$modo" = "--validate" ]; then
  err "✓ $archivo válido ($(printf '%s' "$VALIDAS" | grep -c . || true) excepción(es))."
  exit 0
fi

[ "$modo" = "--filter" ] || die "modo desconocido: $modo"
ECO="${3:-npm}"

# ── Entrada ──────────────────────────────────────────────────────────────────
ENTRADA="$(cat)"
# NO usar `${ENTRADA//[[:space:]]/}`: la sustitución global de patrón de bash sobre una
# cadena de 10 KB **se cuelga** (medido en bash 3.2 de macOS, timeout a los 8 s con el
# corpus real). Lo cazó ejecutar el prototipo; ninguna spec en prosa lo habría dicho.
# `tr | head -c1` es O(n) en C e instantáneo.
if [ -z "$(printf '%s' "$ENTRADA" | tr -d '[:space:]' | head -c1)" ]; then
  die "la entrada está vacía — el audit no produjo JSON. Eso es un fallo de la herramienta, no un repo limpio."
fi
printf '%s' "$ENTRADA" | jq -e . >/dev/null 2>&1 || die "la entrada no es JSON válido."
# JSON VÁLIDO de FORMA INCORRECTA. Este es el que reprodujo el fail-open DENTRO del
# arreglo del fail-open: npm en ENOLOCK sale rc=1 (igual que el camino feliz) y emite
# JSON válido con `.error`. El discriminante NO puede ser el exit code de npm: tiene
# que ser la FORMA del JSON.
case "$ECO" in
  npm)
    printf '%s' "$ENTRADA" | jq -e 'has("vulnerabilities")' >/dev/null 2>&1 \
      || die "el JSON no tiene 'vulnerabilities': $(printf '%s' "$ENTRADA" | jq -r '.error.code // "forma desconocida"'). El audit falló." ;;
  composer)
    printf '%s' "$ENTRADA" | jq -e 'has("advisories")' >/dev/null 2>&1 \
      || die "el JSON no tiene 'advisories'. El composer audit falló." ;;
  pip-audit)
    printf '%s' "$ENTRADA" | jq -e 'has("dependencies")' >/dev/null 2>&1 \
      || die "el JSON no tiene 'dependencies'. El pip-audit falló." ;;
  *) die "ecosistema no soportado: '$ECO' (hoy: npm, composer, pip-audit)." ;;
esac

EP_JSON="$(printf '%s' "$VALIDAS" | awk -F'\t' 'NF{printf "{\"id\":\"%s\",\"e\":%s}\n",$1,$2}' | jq -s . 2>/dev/null || echo '[]')"

# ── El filtro ────────────────────────────────────────────────────────────────
# LA REGLA, y es la que dos versiones de la spec no supieron fijar:
# npm DERIVA la severidad de una entrada de su `via`. Si parte del `via` queda exento,
# la severidad derivada HAY QUE RECALCULARLA. Medido sobre el corpus real:
#   · «sobrevive si alcanza un advisory vivo»      -> 3 high  (los sostiene un MODERATE)
#   · «recalcular la severidad efectiva»           -> 0 high  <- correcta
# Un advisory moderate no puede sostener un veredicto high.
# El grafo TIENE CICLOS (metro -> metro-config -> metro), así que se itera a punto fijo
# N veces (N = nº de paquetes), que es cota suficiente para alcanzabilidad.
SALIDA="$(printf '%s' "$ENTRADA" | jq \
  --argjson ep "$EP_JSON" --argjson hoy "$HOY_EPOCH" --arg umbral "$UMBRAL" --arg eco "$ECO" '
  # `medium` es el vocabulario de composer; `moderate` el de npm. Medido 2026-08-12: sin
  # `medium` en la tabla, un advisory de composer caía al `// 0` y DESAPARECÍA en silencio.
  # Fail-open del camino PHP, y lo habría enviado sin el corpus real.
  # El desconocido va a `-1` y NO a 0: una severidad que no reconocemos no puede tratarse
  # como inocua. `sevsafe` la sube a crítica — ante falta de dato, se bloquea.
  def sevnum: {"info":0,"low":1,"moderate":2,"medium":2,"high":3,"critical":4}[.] // -1;
  def sevsafe: if . == -1 then 4 else . end;
  def sevname: {"0":"info","1":"low","2":"moderate","3":"high","4":"critical"}[tostring];
  # vigentes = exenciones cuya fecha NO ha pasado (>= hoy: vale hasta el final de su día)
  ([$ep[] | select(.e >= $hoy) | .id]) as $viv
  # ── composer: plano, sin grafo. El ID es `.cve` o `.advisoryId` — y medido sobre el
  # corpus real, `cve` es NULL en 4 de 6: el "fallback" es el caso MAYORITARIO. Se casa
  # contra LOS DOS, porque quien copia un id de la salida de composer ve el que ve.
  # ── pip-audit: NO TIENE campo `severity`. Medido con pip-audit 2.10.1 sobre corpus real:
  # las claves de una vuln son aliases/description/fix_versions/id, y ninguna es severidad.
  # El concepto de umbral NO APLICA aqui: cualquier vuln no exenta bloquea, que es lo que
  # hace la receta. Y cada vuln trae TRES identidades (id PYSEC + aliases GHSA/CVE/SNYK),
  # asi que se casa contra `id` UNION `aliases`: quien busca el advisory encuentra el CVE,
  # no el PYSEC, y exigir el id seria una trampa de usabilidad. Ojo: esto NO es un comodin
  # -- los aliases son del MISMO advisory, no una referencia cruzada a otros.
  | if $eco == "pip-audit" then
      { dependencies: ( .dependencies | map(
          .vulns = [ .vulns[]? | select(
            ([ .id ] + (.aliases // []) | map(ascii_downcase)
              | any(. as $i | $viv | index($i))) | not ) ] ) ) }
      | .bloqueantes = ( [ .dependencies[]?.vulns[]? ] | length )
    elif $eco == "composer" then
      { advisories: ( .advisories | map_values(
          [ .[] | select(
              ([ (.cve // empty), (.advisoryId // empty) ]
                | map(ascii_downcase) | any(. as $i | $viv | index($i))) | not ) ] )
        | with_entries(select(.value | length > 0)) ) }
      | .bloqueantes = ( [ .advisories[]?[]? | select((.severity | sevnum | sevsafe) >= ($umbral|sevnum)) ] | length )
    else
  .vulnerabilities as $V
  | ($V|keys) as $pk
  # base: max severidad de los advisories-objeto NO exentos de cada paquete
  | ($V | map_values(
      [ .via[]? | select(type=="object")
        | select( (.url // "" | split("/") | last | ascii_downcase) as $i | ($viv | index($i)) | not )
        | .severity | sevnum | sevsafe ] | max // 0 )) as $base
  # punto fijo: sev[p] = max(base[p], sev de los paquetes que alcanza por `via` de strings)
  | (reduce range(0; ($pk|length)) as $_ ($base;
      . as $s | reduce $pk[] as $p (.;
        .[$p] = ([ $s[$p] ] + [ $V[$p].via[]? | select(type=="string") | $s[.] // 0 ] | max)
      ))) as $sev
  | ($umbral | sevnum) as $lim
  | { vulnerabilities: ( $V | with_entries( select( $sev[.key] > 0 )
        | .value.severity = ($sev[.key] | sevname) ) ) }
  | .metadata = { vulnerabilities: ( reduce (.vulnerabilities[].severity) as $s
        ({info:0,low:0,moderate:0,high:0,critical:0}; .[$s] += 1) ) }
  | .bloqueantes = ( [ .vulnerabilities[] | select((.severity|sevnum|sevsafe) >= $lim) ] | length )
  end
')" || die "el filtro falló al procesar el JSON."

# ── Reporte por stderr: aplicadas, vencidas, huérfanas ───────────────────────
# El script NO escribe logs: emite por stderr y cada consumidor decide destino
# (audit.log en local, $GITHUB_STEP_SUMMARY en CI). Escribir al audit.log de watson
# desde un runner efímero sería escribir en una ruta inexistente.
# La extracción de ids presentes es POR ECOSISTEMA. Con la versión npm-only, toda excepción
# válida de composer o pip-audit se reportaba como HUÉRFANA — o sea que el mensaje mandaba a
# borrar la línea que estaba haciendo su trabajo. El veredicto era correcto; el consejo, no.
# Un gate que aconseja mal se obedece mal.
case "$ECO" in
  npm)      _q='[.vulnerabilities[]?.via[]? | select(type=="object") | (.url // "" | split("/") | last)]' ;;
  composer) _q='[.advisories[]?[]? | (.cve // empty), (.advisoryId // empty)]' ;;
  pip-audit)_q='[.dependencies[]?.vulns[]? | .id, (.aliases[]? // empty)]' ;;
esac
IDS_PRESENTES="$(printf '%s' "$ENTRADA" | jq -r "$_q | map(ascii_downcase) | unique[]" 2>/dev/null || true)"
while IFS="$(printf '\t')" read -r id epoch orig; do
  [ -n "$id" ] || continue
  orig="${orig:-$id}"
  f="$(jq -rn --argjson e "${epoch:-0}" '$e|strftime("%Y-%m-%d")')"
  if [ "${epoch:-0}" -lt "$HOY_EPOCH" ]; then
    err "  ⏰ excepción VENCIDA: $orig (venció $f) — vuelve a bloquear"
  elif printf '%s\n' "$IDS_PRESENTES" | grep -qx -- "$id"; then
    err "  ✓ excepción aplicada: $orig (revisar antes de $f)"
  else
    err "  🧹 excepción HUÉRFANA: $orig ($f) no casa con ningún hallazgo — ¿ya hay parche? bórrala"
  fi
done <<EOF
$VALIDAS
EOF

BLOQ="$(printf '%s' "$SALIDA" | jq -r '.bloqueantes')"
printf '%s' "$SALIDA" | jq 'del(.bloqueantes)'
[ "$BLOQ" -eq 0 ] || { err "  ⛔ quedan $BLOQ hallazgo(s) >= $UMBRAL tras aplicar las excepciones"; exit 1; }
exit 0
