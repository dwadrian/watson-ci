# Cablear `audit-exceptions.sh` en las tres recetas — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** que un advisory sin parche upstream tenga una salida con caducidad en el CI de la flota, en vez de `--no-verify`, que apaga los nueve gates.

**Architecture:** cada receta delega su gate de dependencias en `tools/dep-gate-<eco>.sh`, que viaja por el tooling ya pineado (`.watson-ci-tooling/`). El script corre la herramienta oficial del ecosistema y, **solo si el repo auditado tiene `.watson-audit-exceptions.txt` en su raíz**, pasa el JSON por `tools/audit-exceptions.sh` antes de decidir. Sin ese archivo, el camino es byte por byte el de hoy.

**Tech Stack:** bash 3.2+ (los runners traen 5.x, pero el macOS del dueño es 3.2 y ahí se depura), `jq`, `npm audit --json`, `composer audit --format=json`, `pip-audit --format=json`, GitHub reusable workflows.

## Global Constraints

Copiadas literales de la spec — aplican a **todas** las tareas:

- El archivo se llama **`.watson-audit-exceptions.txt`** y se busca **solo en la raíz** del repo auditado. Nombre y ubicación **hardcodeados**: ni input, ni búsqueda recursiva.
- La raíz del repo va **por ARGUMENTO posicional, nunca por variable de entorno**. `WATSON_CI_ALCANCE` ya reprodujo el bypass de que el entorno pise la decisión del gate.
- Contrato de salida idéntico en los tres: **`0` verde · `1` bloquea · `2` ERROR**. El `2` es distinto del `1` a propósito: *"murió"* no puede leerse como *"bloqueó"* ni como *"no hay hallazgos"*.
- **Un repo sin el archivo no ve ningún cambio de comportamiento.** Es un criterio de aceptación con test, no una aspiración.
- Fechas en tests **siempre relativas** (`now ± N días`). Una fecha fija caduca y el test empieza a fallar solo.
- Ningún `input:` nuevo en las recetas. Se **retiran** dos.
- `set -uo pipefail`. **NO `set -e`**: los scripts necesitan capturar `rc` de herramientas que salen != 0 en el camino normal. ⚠️ **Pero perder `-e` compra un fail-open, y hay que pagarlo explícitamente.** Hoy los pasos que se mueven llevan `set -euo pipefail` dentro del `run:` (`verify-node:210`, `verify-php:242`). Reproducido en la ronda 1:

  ```
  ── SIN -e (lo que este plan proponía) ──      ── CON -e (el run: de hoy) ──
  jq: error … explode input must be a string    jq: error … explode input
  [: : integer expression expected              (aborta)
  composer audit OK   ← rc=0, VERDE
  ```

  O sea: `jq` reventado y **«composer audit OK» en verde**, que es literalmente el fallo que
  `verify-php:263-267` dice haber cerrado en v3. Por eso es **obligatorio** validar que TODO
  contador es numérico antes de compararlo, en los tres scripts:

  ```bash
  # num_o_muere <valor> <nombre> — un contador no numerico significa que jq fallo. Sin -e, el
  # `[ "$x" -gt 0 ]` de despues es falso y el script cae al `exit 0` del final: verde con el
  # audit roto. Esta funcion es lo que compensa el -e que se pierde al salir del `run:`.
  num_o_muere() {
    case "$1" in
      ''|*[!0-9]*) echo "::error::conteo no numerico para $2 ('$1') — jq fallo, bloqueando."; exit 2 ;;
    esac
  }
  ```
- **Rutas temporales con `mktemp`, jamás fijas.** `/tmp/audit.json` sobrevive entre corridas en la máquina del dueño (estos scripts también van a `ci-local`/pre-push): un redirect que falla deja el JSON de **la corrida anterior**, que pasa el `jq -e .` y se cuenta como fresco. Un audit rancio leído como actual.
- **El archivo de excepciones debe ser un archivo REGULAR.** `[ -f ]` sigue los symlinks, así que un `ln -s docs/oculto.txt .watson-audit-exceptions.txt` derrota la decisión de «solo en la raíz»: el enlace se ve una vez en el diff y a partir de ahí la lista crece en un archivo cuyo nombre no dice nada.
- **`export AUDIT_LEVEL=high` al inicio de los tres scripts.** Ver la sección Prohibido: la variable ya existe y sí cambia el veredicto.
- Anti-patrón prohibido, ya documentado en este sistema: **`grep -c … || echo 0` imprime DOS líneas** (`grep -c` ya imprime `0` *y* sale con código 1). Idiom correcto: `grep -c … || true`.

---

### Task 1: `audit-exceptions.sh` anota en formato GitHub y dice cuántos días quedan

Hoy el filtro ya reporta por excepción a stderr (`✓ aplicada` / `⏰ VENCIDA` / `🧹 HUÉRFANA`), pero sin formato de anotación y sin días restantes. En la pestaña de checks esas líneas se pierden dentro del log del paso.

**Files:**
- Modify: `tools/audit-exceptions.sh` (el bucle de reporte: `while IFS=...read -r id epoch orig`)
  — se cita por su ancla y no por linea: la unificacion del predicado de vigencia desplazo el bloque 30 lineas
- Test: `tests/audit-exceptions.test.sh` (añadir al final, antes del resumen)

**Interfaces:**
- Consumes: nada de tareas previas.
- Produces: `audit-exceptions.sh` emite `::warning::…` en stderr cuando `GITHUB_ACTIONS=true`, y el texto incluye `(en N días)`. El veredicto (exit code) **no cambia** en ningún caso.

- [ ] **Step 1: Escribir los tests que fallan**

Añadir en `tests/audit-exceptions.test.sh`, justo antes del bloque `echo` del resumen final:

```bash
echo "── anotación GitHub: el aviso tiene que VERSE en la pestaña de checks"

# Sin GITHUB_ACTIONS no se anota: en local el prefijo es ruido.
r="$(corre npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE sin parche" \
                                     "GHSA-5p2g-fcmc-qvqq $VIGENTE idem")"
grep -q '::warning::' "$TMP/err" \
  && fail "en local NO debe anotar" "sin ::warning::" "$(head -1 "$TMP/err")" \
  || ok "en local no anota (el prefijo seria ruido)"

# Con GITHUB_ACTIONS=true, cada excepcion APLICADA sale como anotacion y con dias restantes.
GITHUB_ACTIONS=true bash "$FILTRO" --filter "$TMP/e.txt" npm \
  < "$FIX/npm-makro-12high.json" >/dev/null 2>"$TMP/err2"
grep -q '::warning::.*GHSA-w3rx-r6r6-pgpr' "$TMP/err2" \
  && ok "anota la excepcion aplicada con su id" \
  || fail "anotacion ausente" "::warning:: con el id" "$(head -3 "$TMP/err2")"
grep -qE 'en [0-9]+ d' "$TMP/err2" \
  && ok "…y dice cuantos dias le quedan" \
  || fail "sin dias restantes" "en N dias" "$(head -3 "$TMP/err2")"

# Una VENCIDA tambien se anota: es la que manda al --no-verify si pasa en silencio.
printf 'GHSA-w3rx-r6r6-pgpr %s vencida\n' "$AYER" > "$TMP/e2.txt"
GITHUB_ACTIONS=true bash "$FILTRO" --filter "$TMP/e2.txt" npm \
  < "$FIX/npm-makro-12high.json" >/dev/null 2>"$TMP/err3"
grep -q '::warning::.*VENCIDA' "$TMP/err3" \
  && ok "la VENCIDA se anota" \
  || fail "vencida silenciosa" "::warning:: VENCIDA" "$(head -3 "$TMP/err3")"

# CONTROL: anotar es FORMATO. El veredicto no puede depender de GITHUB_ACTIONS.
# Se comprueba en los DOS veredictos, no en uno: con solo el caso VENCIDO (rc=1 por ambos
# lados) una regresion que volteara una excepcion APLICADA (0 <-> 1) pasaria en verde. El
# control estaria fijando la frontera justo donde no puede moverse.
for caso in "e.txt:0" "e2.txt:1"; do
  arch="${caso%%:*}"; esp="${caso##*:}"
  GITHUB_ACTIONS=true bash "$FILTRO" --filter "$TMP/$arch" npm \
    < "$FIX/npm-makro-12high.json" >/dev/null 2>/dev/null; rc_gh=$?
  bash "$FILTRO" --filter "$TMP/$arch" npm \
    < "$FIX/npm-makro-12high.json" >/dev/null 2>/dev/null; rc_local=$?
  { [ "$rc_gh" = "$rc_local" ] && [ "$rc_gh" = "$esp" ]; } \
    && ok "CONTROL($arch): el veredicto NO depende de GITHUB_ACTIONS (rc=$rc_gh)" \
    || fail "el entorno cambia el veredicto ($arch)" "ambos=$esp" "gh=$rc_gh local=$rc_local"
done
```

⚠️ El bucle exige que `$TMP/e.txt` siga conteniendo **las dos** excepciones vigentes cuando se
llega aquí — lo deja así la llamada a `corre` del primer assert de este bloque.

- [ ] **Step 2: Correr y verlos fallar**

Run: `bash tests/audit-exceptions.test.sh`
Expected: FAIL en «anota la excepcion aplicada con su id», «dias restantes» y «la VENCIDA se anota». Los otros dos (el de local y el CONTROL) pasan ya.

- [ ] **Step 3: Implementar**

En `tools/audit-exceptions.sh`, sustituir el bucle de reporte por:

```bash
# El prefijo de anotacion es FORMATO, nunca veredicto: `GITHUB_ACTIONS` solo decide como se
# imprime. Si algun dia decidiera si algo bloquea, seria un bypass activable desde el entorno
# -- la clase de WATSON_CI_ALCANCE. El test de CONTROL fija esa frontera.
ANOT=""; [ "${GITHUB_ACTIONS:-}" = "true" ] && ANOT="::warning::"

while IFS="$(printf '\t')" read -r id epoch orig; do
  [ -n "$id" ] || continue
  orig="${orig:-$id}"
  f="$(jq -rn --argjson e "${epoch:-0}" '$e|strftime("%Y-%m-%d")')"
  # Division entera de segundos a dias. Puede dar 0 el ultimo dia: "en 0 dias" es correcto
  # y mas honesto que redondear hacia arriba a "1".
  dias=$(( ( ${epoch:-0} - HOY_EPOCH ) / 86400 ))
  if [ "${epoch:-0}" -lt "$HOY_EPOCH" ]; then
    err "${ANOT}  ⏰ excepción VENCIDA: $orig (venció $f) — vuelve a bloquear"
  # `-F`: sin el, el id se trata como EXPRESION REGULAR y el charset admite `.`, asi que
  # `cve-2020.28493` casaria con `cve-2020-28493`. No cambiaba el veredicto (el jq casa exacto),
  # pero esta linea pasa aqui de log a ANOTACION en la pestaña de checks: afirmaria "excepcion
  # aplicada" sobre un id que no esta en el corpus.
  elif printf '%s\n' "$IDS_PRESENTES" | grep -Fqx -- "$id"; then
    err "${ANOT}  ✓ excepción aplicada: $orig (caduca $f, en $dias días)"
  else
    err "${ANOT}  🧹 excepción HUÉRFANA: $orig ($f) no casa con ningún hallazgo — ¿ya hay parche? bórrala"
  fi
done <<EOF
$VALIDAS
EOF
```

- [ ] **Step 4: Correr y verlos pasar**

Run: `bash tests/audit-exceptions.test.sh`
Expected: `audit-exceptions: TODO VERDE`, con los 19 asserts nuevos incluidos (36 en total)
  — 6 por C3 y 6 mas tras el gate: N-1 (id como cadena) x2, N-2 (una viva se reporta viva),
    N-3 (2 campos con tab y con sangria) x2 y N-4 (salida cerrada -> rc=2).

- [ ] **Step 5: Commit**

```bash
git add tools/audit-exceptions.sh tests/audit-exceptions.test.sh
git commit -m "feat(audit-exceptions): la excepcion aplicada se ve en la pestana de checks, con sus dias"
```

---

### Task 2: `dep-gate-npm.sh` — el ecosistema que hoy no tiene ninguna salida

`verify-node` corre `npm audit --audit-level=high` y depende del exit code de npm. No parsea JSON, así que no hay dónde insertar un filtro: hay que construir el camino con JSON, **y solo cuando hay archivo de excepciones**.

**Files:**
- Create: `tools/dep-gate-npm.sh`
- Create: `tests/dep-gate.test.sh`
- Modify: `.github/workflows/verify-node.yml:208-218` (el paso `📦 npm audit`)
- Modify: `.github/workflows/selftest.yml:76` (añadir el test nuevo al job `decisiones`)

**Interfaces:**
- Consumes: `tools/audit-exceptions.sh --filter <archivo> npm` (stdin JSON → stdout JSON filtrado; `0` nada bloqueante, `1` quedan, `2` ERROR).
- Produces: `tools/dep-gate-npm.sh <raiz>` → exit `0`/`1`/`2`. Las tareas 3 y 4 copian su estructura y **extienden `tests/dep-gate.test.sh`**, que esta tarea crea con su harness (`stub_bin`, `corre_gate`).

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/dep-gate.test.sh`. El harness stubea `npm` en el `PATH` — es cómo se prueba un script que instala dependencias sin instalarlas, y es el precedente que watson ya usa en `ci-local-audit-exceptions.test.mjs`. **No** se añade un env-override al script: eso sería el bypass que las constraints prohíben.

```bash
#!/usr/bin/env bash
# ==============================================================================
# dep-gate.test.sh — los gates de dependencias por ecosistema, contra corpus REAL.
#
# POR QUE UN STUB EN EL PATH y no una variable de entorno: el gate no puede tener una
# palanca que cambie su decision desde el entorno (clase WATSON_CI_ALCANCE). El stub
# sustituye la HERRAMIENTA, no la logica: el script sigue siendo el que decide.
#
# Uso:  bash tests/dep-gate.test.sh
# Exit: 0 = todo verde · 1 = algun veredicto cambio
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FALLOS=0
FIX=tests/fixtures/audit
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; echo "      esperado: $2"; echo "      obtenido: $3"; FALLOS=$((FALLOS + 1)); }

VIGENTE="$(jq -rn 'now + (30*86400) | strftime("%Y-%m-%d")')"
AYER="$(jq -rn 'now - 86400 | strftime("%Y-%m-%d")')"

# stub_bin <nombre> <cuerpo>  -> crea un ejecutable falso en $TMP/bin (primero en el PATH)
stub_bin() {
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# repo_npm <fixture> [linea-de-excepcion...]  -> arma un repo de mentira y devuelve su ruta
repo_npm() {
  local fixture="$1"; shift
  local d="$TMP/repo-$RANDOM"; mkdir -p "$d"
  printf '{"name":"x","version":"1.0.0"}\n' > "$d/package.json"
  printf '{"lockfileVersion":3}\n' > "$d/package-lock.json"
  cp "$FIX/$fixture" "$d/.audit-fixture.json"
  if [ "$#" -gt 0 ]; then
    : > "$d/.watson-audit-exceptions.txt"
    for l in "$@"; do printf '%s\n' "$l" >> "$d/.watson-audit-exceptions.txt"; done
  fi
  printf '%s' "$d"
}

# corre_gate <script> <raiz> -> imprime el rc; deja la salida combinada en $TMP/out
corre_gate() {
  # GITHUB_ACTIONS=true NO es decorativo: Task 1 condiciona la anotacion a esa variable y su
  # propio assert exige que en LOCAL no se anote. Sin fijarla aqui, el assert de "la excepcion
  # se ANOTA" es INSATISFACIBLE: las dos suites no pueden estar verdes en el mismo entorno.
  # Reproducido por dos roles: audit-exceptions.test.sh falla en CI, dep-gate.test.sh en el Mac,
  # y Task 5 Step 2 las encadena con `&&`.
  PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true bash "$1" "$2" > "$TMP/out" 2>&1
  printf '%s' "$?"
}

echo "── npm: el ecosistema que hoy no tiene NINGUNA salida"

# El stub responde a las dos formas que usa el gate: `audit --json` escupe el fixture,
# `audit --audit-level=high` replica el veredicto de npm (rc 1 si hay high).
stub_bin npm '
case "$*" in
  *"--json"*)  cat "$PWD/.audit-fixture.json"; exit 1 ;;
  *"--audit-level=high"*)
      n=$(jq "[.vulnerabilities[]?|select(.severity==\"high\" or .severity==\"critical\")]|length" "$PWD/.audit-fixture.json")
      [ "$n" -gt 0 ] && exit 1 || exit 0 ;;
  ci|install|*ci\ *|*install\ *) exit 0 ;;
esac
exit 0'

d="$(repo_npm npm-makro-12high.json)"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "1" ] && ok "SIN archivo de excepciones: bloquea igual que hoy" \
  || fail "no-regresion npm" "1" "$r"

d="$(repo_npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE sin parche upstream" \
                                    "GHSA-5p2g-fcmc-qvqq $VIGENTE idem")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "0" ] && ok "con las 2 excepciones vigentes: verde" || fail "excepcion npm" "0" "$r"
grep -q '::warning::' "$TMP/out" && ok "…y la excepcion se ANOTA" \
  || fail "excepcion silenciosa" "::warning::" "$(head -3 "$TMP/out")"

d="$(repo_npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $VIGENTE solo una de las dos")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "1" ] && ok "SOBRE-EXENCION: 1 de 2 sigue bloqueando" || fail "sobre-exencion npm" "1" "$r"

d="$(repo_npm npm-makro-12high.json "GHSA-w3rx-r6r6-pgpr $AYER vencida" \
                                    "GHSA-5p2g-fcmc-qvqq $VIGENTE viva")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "1" ] && ok "excepcion VENCIDA no exime" || fail "caducidad npm" "1" "$r"

d="$(repo_npm npm-makro-12high.json "GHSA-* $VIGENTE comodin")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "2" ] && ok "comodin: exit 2, y NO se lee como verde" || fail "comodin npm" "2" "$r"

d="$(repo_npm npm-enolock-error.json "GHSA-w3rx-r6r6-pgpr $VIGENTE x")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "2" ] && ok "JSON valido de FORMA INCORRECTA (.error): exit 2" \
  || fail "el audit murio y se leyo como repo limpio" "2" "$r"

# CONTROL NEGATIVO: eximir A no puede eximir B. Sin esto, "exime todo" pasaria igual de verde.
d="$(repo_npm npm-makro-12high.json "CVE-0000-0000 $VIGENTE un id que no esta en el corpus")"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "1" ] && ok "CONTROL: una excepcion ajena no exime nada" || fail "exime de mas" "1" "$r"

d="$TMP/vacio-$RANDOM"; mkdir -p "$d"
r="$(corre_gate tools/dep-gate-npm.sh "$d")"
[ "$r" = "0" ] && ok "sin package.json: skip, verde" || fail "skip npm" "0" "$r"

echo
if [ "$FALLOS" -eq 0 ]; then echo "dep-gate: TODO VERDE"; else echo "dep-gate: $FALLOS fallo(s)"; fi
exit $((FALLOS > 0))
```

- [ ] **Step 2: Correr y verlo fallar**

Run: `bash tests/dep-gate.test.sh`
Expected: FAIL en los 9 asserts. La salida contiene `tools/dep-gate-npm.sh: No such file or directory`.

⚠️ Comprobar que el fallo es **ese**. Un assert que pasa con el script sin escribir es un assert vacío — ya ocurrió en este sistema: cuatro tests pasaron en verde con `audit-exceptions.sh` sin existir porque afirmaban `notEqual(rc, 0)`, y *"command not found"* lo satisface.

- [ ] **Step 3: Implementar `tools/dep-gate-npm.sh`**

```bash
#!/usr/bin/env bash
# ==============================================================================
# dep-gate-npm.sh <raiz> — gate de dependencias npm, con excepciones que CADUCAN.
#
# SIN `.watson-audit-exceptions.txt` el camino es EXACTAMENTE el de siempre
# (`npm audit --audit-level=high`), byte por byte. Esa igualdad no es una comodidad:
# es la garantia de que cablear esto no cambia el veredicto de ningun repo de la flota.
# Solo cuando el repo AÑADE el archivo se toma el camino por JSON.
#
# EXIT: 0 verde · 1 bloquea · 2 ERROR (herramienta caida o entrada no utilizable)
# ==============================================================================
set -uo pipefail

RAIZ="${1:-}"
if [ -z "$RAIZ" ] || [ ! -d "$RAIZ" ]; then
  echo "::error::dep-gate-npm.sh: falta la raiz del repo (va por ARGUMENTO, no por entorno)"
  exit 2
fi
AQUI="$(cd "$(dirname "$0")" && pwd)"
FILTRO="$AQUI/audit-exceptions.sh"
cd "$RAIZ" || exit 2

# El umbral se FIJA. `audit-exceptions.sh:25` lee `${AUDIT_LEVEL:-high}`, asi que un
# `export AUDIT_LEVEL=critical` en el shell del dueño dejaria pasar todo `high` sin declarar
# una sola excepcion, sin caducidad y sin salir en ningun diff.
export AUDIT_LEVEL=high

EXC=".watson-audit-exceptions.txt"
# `[ -f ]` SIGUE los symlinks: `ln -s docs/oculto.txt $EXC` derrota el "solo en la raiz", porque
# el enlace se ve una vez en el diff y luego la lista crece donde nadie mira.
if [ -h "$EXC" ]; then
  echo "::error::$EXC es un symlink — el archivo de excepciones debe ser regular y estar en la raiz."
  exit 2
fi

TMPJ="$(mktemp)"; TMPF="$(mktemp)"; TMPE="$(mktemp)"
trap 'rm -f "$TMPJ" "$TMPF" "$TMPE"' EXIT

[ -f package.json ] || { echo "sin package.json — skip npm audit"; exit 0; }

if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
  npm ci --ignore-scripts --no-audit --no-fund || exit 2
else
  echo "sin lockfile — npm install (reproducibilidad reducida)"
  npm install --ignore-scripts --no-audit --no-fund || exit 2
fi

if [ ! -f "$EXC" ]; then
  npm audit --audit-level=high
  exit $?
fi

echo "ℹ️ $EXC presente — las excepciones vigentes se aplican y se anotan una a una."
npm audit --json > "$TMPJ" 2>"$TMPE"
# El rc de `npm audit --json` NO discrimina: sale 1 tanto por vulnerabilidades como por
# ENOLOCK, y en ENOLOCK emite JSON VALIDO con `.error`. Por eso no se mira aqui: quien
# decide es la FORMA del JSON, y de eso se encarga el filtro (su exit 2).
bash "$FILTRO" --filter "$EXC" npm < "$TMPJ" > "$TMPF"
rc=$?
case "$rc" in
  0) echo "✅ npm audit OK tras aplicar las excepciones vigentes."; exit 0 ;;
  1) echo "::error::Dependencias npm high/critical que NO estan exentas — bloqueado."; exit 1 ;;
  *) echo "::error::El filtro de excepciones fallo (rc=$rc) — bloqueando por seguridad."
     # El volcado crudo se INDENTA: stderr de npm puede contener una linea que empiece por
     # `::` (nombre de paquete, URL de registry en un mensaje de error) y forjar una anotacion
     # falsa en la pestaña de checks. Dos espacios delante la desactivan sin ocultar nada.
     sed 's/^/  /' "$TMPE" 2>/dev/null || true
     exit 2 ;;
esac
```

- [ ] **Step 4: Correr y verlo pasar**

Run: `chmod +x tools/dep-gate-npm.sh && bash tests/dep-gate.test.sh`
Expected: `dep-gate: TODO VERDE` (9 asserts).

- [ ] **Step 5: Salvar los scripts ANTES del borrado del tooling** ⚠️ *(hallazgo CRÍTICO-1 de la ronda 1)*

`.watson-ci-tooling/` **se borra en el paso `Limpiar el checkout del tooling`, que va ANTES del de
dependencias** en las tres recetas — medido: borrado en `verify-node:138`, `verify-php:149`,
`verify-python:165`; paso de deps en `:208`, `:236`, `:230`. Invocar el script desde ahí daría
**exit 127 en los 15 repos, en todos los pushes**: una caída total del gate de dependencias con
pinta de fallo de infraestructura — la pantalla que `tag-completo.test.sh:26-31` documenta como la
que nadie sabe leer.

El borrado es correcto y no se toca (`verify-node:135-136`: *"si no, semgrep analizaría el código
de la receta como si fuera del repo auditado"*). Lo que se hace es **sacar los scripts del
workspace** antes. Sustituir el paso de limpieza (`verify-node:137-138`) por:

```yaml
      # El checkout del tooling se borra ANTES de escanear: si no, semgrep analizaría el
      # código de la receta como si fuera del repo auditado.
      # Los gates de dependencias corren DESPUES de este borrado, asi que sus scripts se copian
      # fuera del workspace primero. $RUNNER_TEMP lo provee el runner, esta FUERA del arbol
      # escaneado, y GitHub lo destruye al acabar el job.
      - name: Limpiar el checkout del tooling
        run: |
          mkdir -p "$RUNNER_TEMP/watson-tools"
          cp .watson-ci-tooling/tools/*.sh "$RUNNER_TEMP/watson-tools/"
          chmod +x "$RUNNER_TEMP/watson-tools"/*.sh
          # El `cp` de arriba NO garantiza nada por si solo: se comprueba POR NOMBRE lo que este
          # paso promete entregar. Ver el aviso de abajo.
          for s in audit-exceptions.sh dep-gate-npm.sh; do
            [ -f "$RUNNER_TEMP/watson-tools/$s" ] || {
              echo "::error::el tooling de watson-ci@${{ inputs.tooling-ref }} no trae tools/$s."
              echo "  Sin el, el gate de dependencias moriria con exit 127 doscientas lineas mas abajo,"
              echo "  con pinta de fallo de infraestructura. Se falla AQUI, nombrando lo que falta."
              exit 1
            }
          done
          rm -rf .watson-ci-tooling
```

⚠️ **Corrección de la ronda 2 — aquí este plan afirmaba algo FALSO.** Decía que el `cp` era
*"fail-closed por construcción, porque los `run:` corren con `bash -e`"*. Medido:

```
$ git ls-tree --name-only v3 tools/
tools/audit-exceptions.sh   tools/gate-roles.sh
tools/requirements-pip-audit.txt   tools/requirements-semgrep.txt
```

**`v3` SÍ trae dos `.sh`**, así que el glob casa, el `cp` **sale con éxito**, y el `exit 127`
reaparece más abajo al faltar `dep-gate-npm.sh` — exactamente el fallo que este paso existía para
impedir. Un glob no puede comprobar la presencia de un archivo concreto: hay que **nombrarlo**.
La comprobación explícita de arriba es lo que convierte la promesa en garantía.

*(Y el nombre de cada receta cambia: `dep-gate-composer.sh` en php, `dep-gate-pip.sh` en python.)*

`dep-gate-*.sh` y `audit-exceptions.sh` acaban en el **mismo directorio**, que es lo que hace que
`FILTRO="$AQUI/audit-exceptions.sh"` resuelva.

- [ ] **Step 6: Cablear `verify-node.yml`**

Sustituir el paso `📦 npm audit (bloquea high/critical SIEMPRE)` (líneas 206-218) por:

```yaml
      # --ignore-scripts: NO ejecutar lifecycle scripts de deps. El audit lee el lockfile.
      # La logica vive en el tooling PINEADO, no en este YAML: dentro de un `run:` no hay
      # forma de escribir un test que compruebe que un archivo de excepciones malformado
      # no exime nada -- y este mecanismo debilita un gate a proposito.
      - name: 📦 npm audit (bloquea high/critical SIEMPRE)
        run: bash "$RUNNER_TEMP/watson-tools/dep-gate-npm.sh" "$GITHUB_WORKSPACE"
```

- [ ] **Step 7: Subir el default de `tooling-ref` a `v3`** ⚠️ *(hallazgo CRÍTICO-2)*

Medido: `git ls-tree --name-only v2 tools/` devuelve **solo** `requirements-pip-audit.txt` y
`requirements-semgrep.txt`. **El tag `v2` no contiene ningún `.sh`.** Con el default actual
(`tooling-ref: 'v2'` en las tres recetas), el `cp` del Step 5 muere en todos los repos.

En las tres recetas, cambiar el `default: 'v2'` del input `tooling-ref` por `default: 'v3'`, **en
este mismo commit**. Va junto porque separarlos deja una versión intermedia que no arranca.

- [ ] **Step 8: Cablear el test en el selftest**

En `.github/workflows/selftest.yml`, tras el paso `Excepciones de auditoría — decisión sobre corpus real` (línea 76):

```yaml
      # Los gates por ecosistema: mismo corpus real, y con el CONTROL NEGATIVO de que una
      # excepcion ajena no exime nada. Un gate que solo sabe decir que si no es un gate.
      - name: Gates de dependencias por ecosistema
        run: bash tests/dep-gate.test.sh
```

- [ ] **Step 9: Verificar el YAML y que el script se invoca desde donde SÍ existe**

Run:
```bash
python3 -c "import yaml;[yaml.safe_load(open(f)) for f in ['.github/workflows/verify-node.yml','.github/workflows/selftest.yml']];print('YAML OK')"
# Ningun `run:` puede seguir invocando un .sh desde el checkout que se borra:
/usr/bin/grep -n 'bash \.watson-ci-tooling/tools/' .github/workflows/*.yml \
  && echo "⛔ hay invocaciones desde el directorio BORRADO" || echo "✓ ninguna invocacion desde el borrado"
```
Expected: `YAML OK` y `✓ ninguna invocacion desde el borrado`.

*(`alcance.sh` sigue invocándose desde `.watson-ci-tooling/` y es correcto: corre **antes** del
borrado. Por eso el grep busca `tools/` y no el directorio entero.)*

- [ ] **Step 10: Commit**

```bash
git add tools/dep-gate-npm.sh tests/dep-gate.test.sh .github/workflows/verify-node.yml .github/workflows/selftest.yml
git commit -m "feat(node): el gate de npm acepta excepciones que caducan, y sin archivo no cambia nada"
```

---

### Task 3: `dep-gate-composer.sh` y retirar `audit-allow-cve`

El escape de php solo cubría advisories **sin severidad**: un `high` nunca tuvo salida, ni declarándolo. Cero repos lo pasan (medido en los 14 stubs), así que retirarlo no rompe a nadie.

**Files:**
- Create: `tools/dep-gate-composer.sh`
- Modify: `tests/dep-gate.test.sh` (añadir bloque composer antes del resumen)
- Modify: `.github/workflows/verify-php.yml:39-42` (borrar el input) y `:236-287` (el paso)

**Interfaces:**
- Consumes: `stub_bin`, `corre_gate`, `VIGENTE`, `AYER`, `FIX`, `TMP` de `tests/dep-gate.test.sh` (Task 2); `audit-exceptions.sh --filter <archivo> composer`.
- Produces: `tools/dep-gate-composer.sh <raiz>` → exit `0`/`1`/`2`.

- [ ] **Step 1: Escribir el test que falla**

Añadir en `tests/dep-gate.test.sh`, antes del `echo` del resumen:

```bash
echo "── composer: 4 de 6 advisories tienen cve=null, y 'unknown' bloquea"

stub_bin composer '
case "$*" in
  *audit*) cat "$PWD/.audit-fixture.json"; exit 1 ;;
esac
exit 0'

repo_composer() {
  local fixture="$1"; shift
  local d="$TMP/repo-$RANDOM"; mkdir -p "$d"
  printf '{"name":"x/y"}\n' > "$d/composer.json"
  printf '{"packages":[]}\n' > "$d/composer.lock"
  cp "$FIX/$fixture" "$d/.audit-fixture.json"
  if [ "$#" -gt 0 ]; then
    : > "$d/.watson-audit-exceptions.txt"
    for l in "$@"; do printf '%s\n' "$l" >> "$d/.watson-audit-exceptions.txt"; done
  fi
  printf '%s' "$d"
}

d="$(repo_composer composer-zigterback-6adv.json)"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "1" ] && ok "SIN archivo: bloquea igual que hoy" || fail "no-regresion composer" "1" "$r"

# Se exime por advisoryId (PKSA) cuando cve es null: casar solo por CVE dejaria 3 high en pie.
d="$(repo_composer composer-zigterback-6adv.json \
      "PKSA-cqd6-fg4n-nxpf $VIGENTE x" "PKSA-1q6p-sqkj-8mmj $VIGENTE x" \
      "PKSA-mc58-w91n-f5gv $VIGENTE x" "CVE-2026-71488 $VIGENTE x")"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "0" ] && ok "se exime por advisoryId cuando cve es null" || fail "composer PKSA" "0" "$r"

d="$(repo_composer composer-zigterback-6adv.json "PKSA-cqd6-fg4n-nxpf $AYER vencida")"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "1" ] && ok "VENCIDA no exime" || fail "caducidad composer" "1" "$r"

# CONTROL NEGATIVO
d="$(repo_composer composer-zigterback-6adv.json "CVE-0000-0000 $VIGENTE ajeno")"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "1" ] && ok "CONTROL: una excepcion ajena no exime nada" || fail "exime de mas" "1" "$r"

# composer.json SIN lock: sin lock no hay audit reproducible. Sigue siendo RED.
d="$TMP/sinlock-$RANDOM"; mkdir -p "$d"; printf '{"name":"x/y"}\n' > "$d/composer.json"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "1" ] && ok "composer.json sin lock: sigue bloqueando" || fail "sin lock" "1" "$r"

# Discriminante del `2`, que composer NO tenia: con el mutante `exit 1` este bloque pasaba 4/5.
# Sin un assert que exija 2, toda la maquineria fail-closed (num_o_muere, jq -e ., la propagacion
# del rc del filtro) se implementa sin un solo test que la vea.
d="$(repo_composer composer-zigterback-6adv.json "PKSA-* $VIGENTE comodin")"
r="$(corre_gate tools/dep-gate-composer.sh "$d")"
[ "$r" = "2" ] && ok "comodin: exit 2 (composer tampoco tenia discriminante del 2)" \
  || fail "comodin composer" "2" "$r"
```

- [ ] **Step 2: Correr y verlo fallar**

Run: `bash tests/dep-gate.test.sh`
Expected: los 9 de npm pasan; FAIL en los 5 de composer con `tools/dep-gate-composer.sh: No such file or directory`.

- [ ] **Step 3: Implementar `tools/dep-gate-composer.sh`**

```bash
#!/usr/bin/env bash
# ==============================================================================
# dep-gate-composer.sh <raiz> — gate de dependencias PHP, con excepciones que CADUCAN.
#
# `unknown` se trata como BLOQUEANTE (v3, 2026-08-03): los advisories de PHP via
# FriendsOfPHP llegan con frecuencia sin metadato de severidad, y antes una RCE critica
# en una dep de Laravel pasaba en VERDE imprimiendo "composer audit OK". Sin severidad
# no es sin riesgo: es falta de dato, y ante falta de dato se bloquea.
#
# EXIT: 0 verde · 1 bloquea · 2 ERROR
# ==============================================================================
set -uo pipefail

RAIZ="${1:-}"
if [ -z "$RAIZ" ] || [ ! -d "$RAIZ" ]; then
  echo "::error::dep-gate-composer.sh: falta la raiz del repo (va por ARGUMENTO, no por entorno)"
  exit 2
fi
AQUI="$(cd "$(dirname "$0")" && pwd)"
FILTRO="$AQUI/audit-exceptions.sh"
cd "$RAIZ" || exit 2
export AUDIT_LEVEL=high

# Lo que compensa el `-e` que se pierde al salir del `run:`. Ver Global Constraints.
num_o_muere() {
  case "$1" in
    ''|*[!0-9]*) echo "::error::conteo no numerico para $2 ('$1') — jq fallo, bloqueando."; exit 2 ;;
  esac
}

EXC=".watson-audit-exceptions.txt"
if [ -h "$EXC" ]; then
  echo "::error::$EXC es un symlink — el archivo de excepciones debe ser regular y estar en la raiz."
  exit 2
fi
TMPJ="$(mktemp)"; TMPF="$(mktemp)"
trap 'rm -f "$TMPJ" "$TMPF"' EXIT

[ -f composer.json ] || { echo "sin composer.json — skip composer audit"; exit 0; }
if [ ! -f composer.lock ]; then
  echo "::error::composer.json sin composer.lock — sin lock no hay audit reproducible (commitear el lock)."
  exit 1
fi

composer audit --locked --no-interaction --abandoned=ignore --format=json > "$TMPJ"
# NO se pone `|| true` en el redirect: se traga tambien un fallo de ESCRITURA, y con una ruta
# reutilizable eso deja el JSON de la corrida anterior pasando por fresco.
if ! jq -e . "$TMPJ" >/dev/null 2>&1; then
  # exit 2, NO 1: el mensaje dice "la herramienta fallo" y el 1 significa "hay hallazgos
  # bloqueantes". Decirlo con el codigo equivocado es el colapso que este mismo plan prohibe.
  echo "::error::composer audit no produjo JSON válido (la herramienta falló) — bloqueando por seguridad."
  sed 's/^/  /' "$TMPJ" 2>/dev/null || true
  exit 2
fi

if [ -f "$EXC" ]; then
  echo "ℹ️ $EXC presente — las excepciones vigentes se aplican y se anotan una a una."
  bash "$FILTRO" --filter "$EXC" composer < "$TMPJ" > "$TMPF"
  rc=$?
  # El 2 se propaga TAL CUAL: un filtro que murio no puede degradarse a "no habia nada".
  [ "$rc" -eq 2 ] && { echo "::error::El filtro de excepciones fallo — bloqueando por seguridad."; exit 2; }
  mv "$TMPF" "$TMPJ" || exit 2
fi

TOTAL=$(jq '[.advisories[]?[]?] | length' "$TMPJ");    num_o_muere "$TOTAL" TOTAL
HIGHCRIT=$(jq '[.advisories[]?[]? | select((.severity // "unknown") | ascii_downcase | test("high|critical"))] | length' "$TMPJ"); num_o_muere "$HIGHCRIT" HIGHCRIT
UNKNOWN=$(jq '[.advisories[]?[]? | select((.severity // "unknown") == "unknown")] | length' "$TMPJ");  num_o_muere "$UNKNOWN" UNKNOWN
echo "advisories: $TOTAL total · $HIGHCRIT high/critical · $UNKNOWN sin severidad"
jq '.advisories' "$TMPJ"

if [ "$HIGHCRIT" -gt 0 ]; then
  echo "::error::Dependencias PHP high/critical: $HIGHCRIT — bloqueado (supply chain no es opcional)."
  echo "  Si alguno no tiene parche upstream, declaralo en $EXC con su id y una fecha:"
  echo "    <advisory-id>  YYYY-MM-DD  <razon>"
  exit 1
fi
if [ "$UNKNOWN" -gt 0 ]; then
  echo "::error::$UNKNOWN advisory(s) SIN severidad — bloqueado."
  echo "  Sin severidad no es sin riesgo: es falta de dato. Revisa el JSON de arriba."
  echo "  Si son falsos positivos, declaralos UNO A UNO en $EXC, con fecha de caducidad."
  exit 1
fi
echo "✅ composer audit OK (medium/low no bloquean; sin-severidad SI bloquea)."
```

- [ ] **Step 4: Correr y verlo pasar**

Run: `chmod +x tools/dep-gate-composer.sh && bash tests/dep-gate.test.sh`
Expected: `dep-gate: TODO VERDE` (14 asserts).

- [ ] **Step 5: Cablear `verify-php.yml` y retirar el input**

Borrar el input (líneas 39-42):

```yaml
      audit-allow-cve:
        description: 'CVEs concretos (coma-separados) exentos del bloqueo por advisory SIN severidad. NO hay escape global: cada falso positivo se declara por su id.'
        type: string
        default: ''
```

Sustituir el paso `📦 composer audit` completo (236-287) por:

```yaml
      # v2.0.1: audit --locked lee composer.lock directo, SIN composer install — más rápido,
      # y evita que un fallo de plataforma impida llegar al audit (caso Laravel 4.2).
      # El input `audit-allow-cve` se RETIRO: solo cubria los advisories sin severidad (un
      # `high` nunca tuvo salida), no caducaba, y vivia en el `with:` del stub en vez de en un
      # archivo que se ve en el diff del PR. Cero repos lo pasaban. Lo sustituye
      # `.watson-audit-exceptions.txt` en la raiz del repo auditado.
      - name: 📦 composer audit (bloquea high/critical SIEMPRE)
        run: bash "$RUNNER_TEMP/watson-tools/dep-gate-composer.sh" "$GITHUB_WORKSPACE"
```

Y aplicar **también aquí** los dos cambios del Step 5 y Step 7 de la Task 2: el paso `Limpiar el
checkout del tooling` (`verify-php:148-149`) copia los `.sh` a `$RUNNER_TEMP/watson-tools` antes de
borrar, y el input `tooling-ref` sube su `default` a `'v3'`.

- [ ] **Step 6: Verificar que ninguna referencia al input sobrevive**

Run: `/usr/bin/grep -rn "audit-allow-cve\|AUDIT_ALLOW_CVE" .github/ tools/ tests/ || echo "sin referencias huerfanas"`
Expected: `sin referencias huerfanas`

- [ ] **Step 7: Commit**

```bash
git add tools/dep-gate-composer.sh tests/dep-gate.test.sh .github/workflows/verify-php.yml
git commit -m "feat(php): excepciones con caducidad, y fuera el input que solo cubria 'sin severidad'"
```

---

### Task 4: `dep-gate-pip.sh` y retirar `pip-audit-ignore-vuln`

El paso de python es el más largo (~105 líneas de shell en YAML) y el que más cobertura silenciosa ha tenido: a profundidad 3+ **no se auditaba y el log decía «pip-audit OK» igual**. Se mueve tal cual, sin cambiar su lógica de descubrimiento.

**Files:**
- Create: `tools/dep-gate-pip.sh`
- Modify: `tests/dep-gate.test.sh` (bloque pip antes del resumen)
- Modify: `.github/workflows/verify-python.yml:41-44` (borrar el input) y `:228-339` (el paso)

**Interfaces:**
- Consumes: `stub_bin`, `corre_gate`, `VIGENTE`, `AYER`, `FIX`, `TMP` (Task 2); `audit-exceptions.sh --filter <archivo> pip-audit`.
- Produces: `tools/dep-gate-pip.sh <raiz>` → exit `0`/`1`/`2`. Lee `AUDIT_OPTIONAL` del entorno **solo** para el caso «proyecto sin lockfile auditable», que es el que ya existía como `python-audit-optional` y **no se retira**.

- [ ] **Step 1: Escribir el test que falla**

Añadir en `tests/dep-gate.test.sh`, antes del resumen:

```bash
echo "── pip-audit: sin severidad, y con TRES identidades por vuln"

stub_bin pip-audit '
case "$*" in
  *--version*) echo "pip-audit 2.10.1"; exit 0 ;;
  *) cat "$PWD/.audit-fixture.json"; exit 1 ;;
esac'

repo_pip() {
  local fixture="$1"; shift
  local d="$TMP/repo-$RANDOM"; mkdir -p "$d"
  printf 'jinja2==2.11.2\n' > "$d/requirements.txt"
  cp "$FIX/$fixture" "$d/.audit-fixture.json"
  if [ "$#" -gt 0 ]; then
    : > "$d/.watson-audit-exceptions.txt"
    for l in "$@"; do printf '%s\n' "$l" >> "$d/.watson-audit-exceptions.txt"; done
  fi
  printf '%s' "$d"
}

d="$(repo_pip pipaudit-jinja2-6vulns.json)"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "1" ] && ok "SIN archivo: bloquea igual que hoy (cualquier vuln)" \
  || fail "no-regresion pip" "1" "$r"

# id=PYSEC-2021-66, aliases=[SNYK-…, GHSA-…, CVE-2020-28493]. Quien busca el advisory
# encuentra el CVE, no el PYSEC: exigir el id seria una trampa de usabilidad.
d="$(repo_pip pipaudit-jinja2-6vulns.json "CVE-2020-28493 $VIGENTE alias, no el id")"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "1" ] && ok "se exime por un ALIAS, y las otras 5 siguen bloqueando" \
  || fail "alias pip" "1" "$r"

d="$(repo_pip pipaudit-jinja2-6vulns.json "CVE-2020-28493 $AYER vencida")"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "1" ] && ok "VENCIDA no exime" || fail "caducidad pip" "1" "$r"

# CONTROL NEGATIVO
d="$(repo_pip pipaudit-jinja2-6vulns.json "CVE-0000-0000 $VIGENTE ajeno")"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "1" ] && ok "CONTROL: una excepcion ajena no exime nada" || fail "exime de mas" "1" "$r"

# Un repo con pyproject y SIN lockfile pineado sigue en ROJO: antes de v3 esto era exit 0,
# o sea VERDE sin auditar una sola dependencia.
d="$TMP/pyproj-$RANDOM"; mkdir -p "$d"; printf '[project]\nname="x"\n' > "$d/pyproject.toml"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "1" ] && ok "pyproject sin lockfile: sigue bloqueando" || fail "pyproject" "1" "$r"

# ⛔ SIN LOS DOS DE ABAJO, EL BLOQUE PIP ENTERO PASA 5/5 CONTRA UN GATE DE DOS LINEAS QUE SOLO
# DICE `exit 1`. Reproducido por dos roles: los 5 asserts anteriores esperan `1`, asi que un
# script inservible los satisface todos — y por eso el "mecanismo inerte" (3c-bis) no se veia.
# Los ids salen del corpus real: jq -r '.dependencies[].vulns[].id' del fixture.
d="$(repo_pip pipaudit-jinja2-6vulns.json \
      "PYSEC-2021-66 $VIGENTE x"   "PYSEC-2019-217 $VIGENTE x" \
      "PYSEC-2026-1473 $VIGENTE x" "PYSEC-2026-1471 $VIGENTE x" \
      "PYSEC-2026-1474 $VIGENTE x" "PYSEC-2026-1475 $VIGENTE x")"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "0" ] && ok "las 6 exentas: VERDE (el mecanismo SI hace algo en python)" \
  || fail "el mecanismo es INERTE en python" "0" "$r"

d="$(repo_pip pipaudit-jinja2-6vulns.json "PYSEC-* $VIGENTE comodin")"
r="$(corre_gate tools/dep-gate-pip.sh "$d")"
[ "$r" = "2" ] && ok "comodin: exit 2 (pip no tenia NINGUN discriminante del 2)" \
  || fail "comodin pip" "2" "$r"
```

- [ ] **Step 2: Correr y verlo fallar**

Run: `bash tests/dep-gate.test.sh`
Expected: los 14 anteriores pasan; FAIL en los 5 de pip con `tools/dep-gate-pip.sh: No such file or directory`.

- [ ] **Step 3: Implementar `tools/dep-gate-pip.sh`**

Copiar íntegro el cuerpo del paso `📦 pip-audit` de `verify-python.yml:234-339` con estos cambios y **ningún otro**:

1. Cabecera del script (shebang, comentario, `set -uo pipefail`), `RAIZ`/`cd`, `export AUDIT_LEVEL=high` y la guarda de symlink sobre `$EXC`: **igual que en los dos anteriores**. La función `num_o_muere` se copia **del de composer** — el de npm **no la tiene y no la necesita**, porque no cuenta nada con `jq`: delega la decisión entera en el filtro y solo traduce su exit code. Copiarla ahí sería código muerto; darla por existente en los tres es el error que esta línea evita.
2. `AUDIT_OPTIONAL` se sigue leyendo del entorno (viene del input `python-audit-optional`, que **no** se retira).
3. Borrar el bloque `IGNORE_ARGS` (líneas 283-290) y su uso en `audit_source`.
3b. **Guarda de array vacío bajo `set -u`** *(hallazgo de la ronda 1)*. El cuerpo original expande `"${reqfiles[@]}"` (`:331`) y en **bash 3.2 —el entorno declarado para depurar— eso revienta** con `reqfiles[@]: unbound variable` cuando el array está vacío. Camino alcanzable: `pylock.toml` presente y cero `requirements*.txt`. Y muere con **1**, que bajo este contrato debería ser 2. Sustituir el bucle por:

```bash
    # bash 3.2 trata "${arr[@]}" como unbound si el array esta vacio. El `+` lo hace
    # condicional: sin elementos, la expansion desaparece en vez de abortar.
    for f in ${reqfiles[@]+"${reqfiles[@]}"}; do
      audit_source "$f" --no-deps --strict -r "$f"; rc_src=$?
      [ "$rc_src" -eq 2 ] && exit 2
      [ "$rc_src" -ne 0 ] && rc_total=1
    done
```

3c. **`num_o_muere "$vulns" vulns`** justo después del `vulns=$(jq …)` de `audit_source` (`:305`). Sin `-e`, un `jq` que falla deja `vulns` vacío, `[ "$vulns" -gt 0 ]` es falso, `[ "$rc" -ne 0 ]` con `rc=0` también, y `audit_source` **devuelve 0**: verde con cero cobertura.

3c-bis. ⛔ **EL MECANISMO ERA INERTE EN PYTHON — sin esto, la Task 4 entera no entrega nada.**
Dos roles lo reprodujeron por separado declarando las **6** vulns del corpus como exentas y vigentes:

```
── auditando: ./requirements.txt
vulns conocidas en './requirements.txt': 0
::error::pip-audit salio con rc=1 … con JSON valido y 0 vulns — fail-closed.
RC=1          ← ninguna excepción puede poner Python en verde
```

**Causa:** ese `rc` es **PRE-filtro**. `pip-audit` sale `1` **por haber encontrado** justo las vulns
que estás eximiendo. Tras filtrar, `vulns=0`, se salta el bloqueo por vulns… y cae en el check de
`rc`, que lo relee como *"la herramienta falló"*. Corregir `verify-python.yml:317`:

```bash
    # `rc` es PRE-filtro: pip-audit sale !=0 por HABER ENCONTRADO vulns. Si hubo filtrado, ese rc
    # ya esta explicado por los hallazgos que el filtro acaba de eximir; releerlo como "fallo de la
    # herramienta" deja el mecanismo INERTE. Solo es diagnostico cuando NO se filtro nada.
    if [ "$rc" -ne 0 ] && [ ! -f "$EXC" ]; then
```

3c-ter. **El colapso `2→1` sigue vivo en pip, y la ronda 1 lo dio por cerrado.** Verificado:
`verify-python.yml:302` y `:322` hacen `return 1` con mensajes que dicen *"la herramienta falló"* —
el mismo defecto que este plan corrige en composer con el argumento de que *"decirlo con el código
equivocado es el colapso que este mismo plan prohíbe"*. Ambos pasan a `return 2`.
3d. **Rutas temporales por `mktemp`**, no `/tmp/pipaudit_$$.json`: `$$` se repite entre corridas en la máquina del dueño, donde estos scripts también van a `ci-local`.
4. En `audit_source`, entre la validación del JSON y el conteo de `vulns`, insertar:

```bash
    if [ -f "$EXC" ]; then
      bash "$FILTRO" --filter "$EXC" pip-audit < "$out" > "$out.filtrado"
      local rcf=$?
      if [ "$rcf" -eq 2 ]; then
        echo "::error::El filtro de excepciones fallo en '$label' — bloqueando por seguridad."
        return 2
      fi
      mv "$out.filtrado" "$out"
    fi
```

5. `audit_source` devuelve `2` hacia arriba sin colapsarlo a `1`: cambiar `|| rc_total=1` por:

```bash
  audit_source "pylock.toml" --locked --strict; rc_src=$?
  [ "$rc_src" -eq 2 ] && exit 2
  [ "$rc_src" -ne 0 ] && rc_total=1
```

y lo mismo en el bucle de `reqfiles`. **Motivo:** si el filtro murió, colapsarlo a `1` haría indistinguible *"hay vulnerabilidades"* de *"el gate no pudo evaluarse"*, que es exactamente la confusión que el contrato de tres códigos existe para evitar.

6. Definir arriba: `EXC=".watson-audit-exceptions.txt"` y `FILTRO="$AQUI/audit-exceptions.sh"`.

- [ ] **Step 4: Correr y verlo pasar**

Run: `chmod +x tools/dep-gate-pip.sh && bash tests/dep-gate.test.sh`
Expected: `dep-gate: TODO VERDE` (19 asserts).

- [ ] **Step 5: Cablear `verify-python.yml` y retirar el input**

Borrar el input (41-44):

```yaml
      pip-audit-ignore-vuln:
        description: 'IDs de vulnerabilidad (coma-separados) exentos, declarados UNO A UNO. Para deps pineadas exacto por una herramienta upstream que aun no las corrige. NO es un interruptor global.'
        type: string
        default: ''
```

Sustituir el paso completo (228-339) por:

```yaml
      # Dep-audit con pip-audit (PyPA oficial). Gate por JSON. --no-deps/--locked auditan SIN
      # instalar (no se ejecuta setup.py de ninguna dep). Solo fuentes TOTALMENTE PINEADAS.
      # El input `pip-audit-ignore-vuln` se RETIRO: no caducaba y vivia en el `with:` del stub.
      # Lo sustituye `.watson-audit-exceptions.txt` en la raiz del repo auditado.
      - name: 📦 pip-audit (bloquea CUALQUIER vuln SIEMPRE)
        env:
          AUDIT_OPTIONAL: ${{ inputs.python-audit-optional }}
        run: bash "$RUNNER_TEMP/watson-tools/dep-gate-pip.sh" "$GITHUB_WORKSPACE"
```

Y aplicar **también aquí** los dos cambios del Step 5 y Step 7 de la Task 2: el paso `Limpiar el
checkout del tooling` (`verify-python:164-165`) copia los `.sh` a `$RUNNER_TEMP/watson-tools` antes
de borrar, y el input `tooling-ref` sube su `default` a `'v3'`.

- [ ] **Step 5b: Migrar el propio `selftest.yml`** ⚠️ *(hallazgo ALTA-3: el input NO estaba muerto)*

`selftest.yml:54` pasa `pip-audit-ignore-vuln: 'PYSEC-2026-3481,PYSEC-2026-3482,PYSEC-2026-3483'`
— las 3 vulns de `mcp==1.23.3` en el cierre pineado de semgrep, que su propio comentario explica
que no se pueden arreglar. **La afirmación «cero repos usan los inputs» era falsa**: se midieron
los 14 stubs de la flota y **no se midió este repo**. Retirar el input sin migrar esto rompe el
selftest con *"Invalid input"*.

Borrar esa línea y crear `.watson-audit-exceptions.txt` en la raíz de watson-ci:

```
# Cierre pineado de semgrep: mcp==1.23.3. Sin version corregida upstream al 2026-08-12.
# La fecha se ata al proximo bump de requirements-semgrep.txt, no al calendario.
PYSEC-2026-3481  2026-11-10  mcp 1.23.3, dep transitiva de semgrep, sin fix upstream
PYSEC-2026-3482  2026-11-10  idem
PYSEC-2026-3483  2026-11-10  idem
```

⚠️ **Y hay que decir en voz alta lo que esto implica, porque es el precio del diseño:** watson-ci
es **público**, así que ese archivo publica qué CVEs se auto-exime el repo del que dependen 15.
Es coherente con la decisión de que las excepciones se vean, pero no es gratis y no debe
descubrirse después.

⚠️ **El canario se pondrá rojo solo.** `MAX_DIAS=90` (`audit-exceptions.sh:26`) es un tope duro:
esta exención caduca a los ≤90 días sin que cambie una línea de código, y bloqueará toda
publicación de tag. Su renovación **se ata al bump de `requirements-semgrep.txt`**, y así queda
escrito en el propio archivo: si al renovar la fecha nadie ha mirado si hay versión nueva de
`mcp`, el mecanismo se ha convertido en el trámite que pretendía evitar.

- [ ] **Step 6: Verificar que ninguna referencia al input sobrevive**

Run: `/usr/bin/grep -rn "pip-audit-ignore-vuln\|IGNORE_VULN\|IGNORE_ARGS" .github/ tools/ tests/ || echo "sin referencias huerfanas"`
Expected: `sin referencias huerfanas`

- [ ] **Step 7: Commit**

```bash
git add tools/dep-gate-pip.sh tests/dep-gate.test.sh .github/workflows/verify-python.yml
git commit -m "feat(python): excepciones con caducidad, y el gate sale del YAML a un script testeable"
```

---

### Task 5: documentar el archivo y publicar `v3.1.0`

Un mecanismo que nadie sabe usar no existe: el canal de feedback ya midió que **9 de 17 repos no sabían que existía el canal**, por funcionar de tradición oral. Esto no puede nacer igual.

**Files:**
- Modify: `README.md` (sección nueva)
- Create: `docs/bitacoras/BITACORA-2026-08-12-cablear-audit-exceptions.md`
- Modify: `docs/01_BACKLOG.md`

**Interfaces:**
- Consumes: los tres `dep-gate-*.sh` de las tareas 2-4.
- Produces: nada que consuma código.

- [ ] **Step 1: Documentar en el README**

Añadir:

````markdown
## Advisory sin parche upstream: la salida con caducidad

Cuando una dependencia tiene un advisory **que upstream aún no ha corregido**, la salida NO es
`--no-verify` —que apaga los nueve gates cuando el rojo era uno—. Crea
`.watson-audit-exceptions.txt` **en la raíz** del repo:

```
# <id-del-advisory>  <caduca YYYY-MM-DD>  <razón>
GHSA-w3rx-r6r6-pgpr  2026-11-10  sin parche upstream, seguimiento en issue #42
CVE-2020-28493       2026-09-30  dep pineada por expo, PR upstream abierto
```

Reglas, todas fail-closed:

| | |
|---|---|
| **Un id por línea** | comodines (`*`, `all`, `GHSA-*`) se **rechazan**: exit 2, no exime nada |
| **La fecha es obligatoria** y se valida con round-trip | `2026-02-30` es inválida; sin round-trip `strptime` la rueda a marzo y **alarga** la excepción |
| **Vencida = vuelve a bloquear**, y se nombra en el log | una vencida en silencio manda al `--no-verify` |
| **Una línea malformada invalida el archivo entero** | nada exento, exit 2 |
| **Se casa por identidad exacta** | un prefijo no exime al id completo |
| npm | se casa el GHSA del advisory; la severidad efectiva se **recalcula** sobre el grafo |
| composer | se casa `cve` **o** `advisoryId` — `cve` es `null` en la mayoría |
| pip-audit | se casa el `id` (PYSEC) **o** cualquiera de sus `aliases` (GHSA/CVE/SNYK) |

### Qué es este mecanismo, y qué NO es

**Deja rastro y recuerda. No autoriza.** Conviene decirlo claro porque la diferencia importa:

Medido el 2026-08-12 en la flota — `gh api repos/…/branches/main/protection` devuelve **404 Branch
not protected** en los repos comprobados, y los stubs disparan en **push directo a `main`**. O sea
que el mismo commit puede añadir el archivo, eximirse y poner el gate en verde: sin PR, sin
reviewer y sin required status check. No hace falta un PR malicioso; es el camino normal de trabajo.

Y la caducidad se renueva reescribiendo la fecha, con la misma persona a los dos lados.

Lo que sí aporta, y no es poco, frente a la alternativa real que es `--no-verify`:

| | `--no-verify` | este mecanismo |
|---|---|---|
| Alcance | apaga **los nueve gates** | un advisory, por su id |
| Rastro | ninguno | el archivo, en el diff y en el log del check |
| Olvido | permanente | vuelve a bloquear al caducar, y lo dice |

Si se quiere que además **autorice**, falta el control que no existe hoy: *required status check* +
`CODEOWNERS` sobre la ruta del archivo. Mientras no esté, esto es visibilidad y memoria — venderlo
como autorización sería peor que no tenerlo.
````

- [ ] **Step 1b: Extender `tag-completo.test.sh` a los `tools/*.sh`** ⚠️ *(hallazgo CRÍTICO-2)*

Ese test se citaba como el gate previo a publicar, pero **no cubre esto**: deriva su lista de
`find .github/actions -mindepth 1 -maxdepth 1 -type d` (`:46`) y solo comprueba
`action.yml`/`action.yaml` (`:77-78`). `tools/` no entra. Era aseguramiento falso justo para la
dependencia nueva que este cambio introduce.

Añadir, con la misma disciplina de **derivar del árbol y no de una lista a mano** —que es el
principio que ese archivo ya defiende en `:44-45`—:

```bash
# Los .sh del tooling que los workflows invocan por ruta. Se DERIVAN de los propios YAML: una
# lista a mano es lo que se olvida de actualizar, que es la clase de este mismo incidente.
SCRIPTS="$(grep -rhoE '(watson-tools|\.watson-ci-tooling/tools)/[a-z0-9-]+\.sh' .github/workflows/ \
           | sed 's|.*/||' | sort -u)"
# ⛔ FAIL-OPEN, y lo escribi yo para cerrar un hueco de aseguramiento falso. Verificado HOY: el
# grep devuelve VACIO -> el bucle da CERO iteraciones -> pasa en verde. Un check que no puede
# fallar no es un check. Si no se deriva nada, es que el cableado no esta: eso es un ROJO.
if [ -z "$SCRIPTS" ]; then
  fail "no se derivo ningun tools/*.sh de los workflows — o no hay cableado, o el patron no casa"
fi
for s in $SCRIPTS; do
  git cat-file -e "$OBJETIVO:tools/$s" 2>/dev/null \
    || fail "$OBJETIVO — le FALTA tools/$s, que un workflow invoca por ruta"
done
```

Verificación de que el check **sabe decir que no**, no solo que sí:

Run: `bash tests/tag-completo.test.sh v2`
Expected: **falla** nombrando `tools/dep-gate-npm.sh` — `v2` no contiene ningún `.sh`, medido con
`git ls-tree --name-only v2 tools/`.

- [ ] **Step 2: Correr la suite completa antes de tocar ningún tag**

Run:
```bash
bash tests/audit-exceptions.test.sh && bash tests/dep-gate.test.sh && \
bash tests/expect-audit-decision.sh && bash tests/tag-completo.test.sh HEAD
```
Expected: los cuatro en verde. `tag-completo` debe decir `el ref a publicar esta COMPLETO`.

- [ ] **Step 3: Escribir la bitácora**

`docs/bitacoras/BITACORA-2026-08-12-cablear-audit-exceptions.md` con las 7 fases de Staff Hours, la medición de partida (dos mecanismos divergentes, cero usuarios, el escape de php que solo cubría `unknown`) y la sección **«Lo que NO queda cerrado»** con los cuatro límites de la spec — empezando por que **esto no desbloquea a `makro_logistica`**, que bloquea en su propio `quality.yml`.

- [ ] **Step 4: Actualizar el backlog**

Marcar el P0 *«Un advisory SIN PARCHE no tiene salida proporcionada»* como cerrado **para las recetas**, y abrir el ítem que queda: `dep-audit.sh` de watson sigue siendo solo-npm.

- [ ] **Step 5: Commit y PR**

```bash
git add README.md docs/bitacoras/ docs/01_BACKLOG.md
git commit -m "docs: la salida con caducidad, documentada donde se busca"
git push -u origin HEAD
gh pr create --fill
```

- [ ] **Step 6: Publicar tras el merge**

```bash
git tag -a v3.1.0 -m "excepciones de dependencias con caducidad en las 3 recetas"
git push origin v3.1.0
```

⚠️ **Mover el alias `v3` es `git push --force origin v3`, y el harness lo bloquea a propósito.**
Lo corre el dueño. Hasta que se mueva, **ningún repo consume esto**: los 14 stubs apuntan a `@v2`.

---

## Ronda 1 del loop de validación — 14 hallazgos, y ninguno era opinable

Rol: **auditor ofensivo de cadena de suministro / CI**. Veredicto de ronda 1: **NO-GO**.
De los 14, **cinco los reproduje yo ejecutando** antes de tocar el plan — no se integra un reporte
de subagente sin comprobarlo.

| # | Sev | Hallazgo | Estado |
|---|---|---|---|
| 1 | CRÍT | `.watson-ci-tooling/` se borra (`:138/:149/:165`) **antes** del paso de deps (`:208/:236/:230`) → `exit 127` en los 15 repos | **CERRADO** · Task 2 Step 5 |
| 2 | CRÍT | `tooling-ref` default `v2`, y `v2` no contiene ningún `tools/*.sh` | **CERRADO** · Task 2 Step 7 + Task 5 Step 1b |
| 3 | ALTA | «cero repos usan los inputs» **falso**: `selftest.yml:54` usa `pip-audit-ignore-vuln` | **CERRADO** · Task 4 Step 5b |
| 4 | ALTA | perder `set -e` abre un fail-open: `jq` roto → «composer audit OK» en verde | **CERRADO** · `num_o_muere` en los tres |
| 5 | ALTA | el plan colapsaba el `2` a `1` en composer, donde él mismo lo prohíbe | **CERRADO** · `exit 2` |
| 6 | ALTA | no hay protección de rama: el README prometía una revisión que no existe | **CERRADO** · README reescrito: «deja rastro y recuerda, no autoriza» |
| 7 | MEDIA | un symlink derrota el «solo en la raíz» (`[ -f ]` lo sigue) | **CERRADO** · guarda `[ -h ]` — y **confirmado ejecutando**: ver abajo |
| 8 | MEDIA | `AUDIT_LEVEL` **sí** cambia el veredicto (`audit-exceptions.sh:25`) | **CERRADO** · `export AUDIT_LEVEL=high` + Prohibido corregido |
| 9 | MEDIA | rutas fijas en `/tmp`: audit rancio leído como fresco en `ci-local` | **CERRADO** · `mktemp` + `trap` |
| 10 | MEDIA | el control de `GITHUB_ACTIONS` solo cubría el veredicto que no puede moverse | **CERRADO** · bucle sobre los dos |
| 11 | MEDIA | la medición de stubs no declaraba su corpus | **CERRADO** · reformulado abajo |
| 12 | BAJA | `grep -qx` trata el id como regex, y Task 1 lo promueve a anotación | **CERRADO** · `grep -Fqx` |
| 13 | BAJA | bash 3.2: `"${reqfiles[@]}"` vacío revienta bajo `set -u`, y muere con 1 | **CERRADO** · Task 4 punto 3b |
| 14 | BAJA | volcado crudo de stderr puede forjar una anotación `::error::` | **CERRADO** · `sed 's/^/  /'` |

**Reformulación del hallazgo 11 (la celda «0 repos»):** lo correcto es *«cero stubs de la flota en
su rama por defecto al 2026-08-12, más watson-ci, que SÍ lo usa»*. Lo que la medición **no** cubría:
el propio watson-ci, ramas no-default, la divergencia con `origin` (nadie hizo `fetch` antes de
contar) y un denominador que suma `lnbp-web-2022`, cuyo `origin` es **Bitbucket** y por tanto nunca
ejecuta en GitHub Actions.

### Cobertura ausente, y lo que se cubrió a mano en su lugar

**El rol de code-reviewer de shell se despachó TRES veces y ninguna entregó reporte.** Se declara
como hueco, no se tapa: *asserts que no discriminan* y *bash 3.2* siguen sin revisión de
especialista. Un verificador lanzado que no entrega da falsa sensación de cobertura — es peor que
no lanzarlo — así que queda escrito aquí y condiciona el GO.

Lo que sí se pudo cubrir ejecutando, por ser mecánico:

**1 · Fidelidad de los stubs — VERIFICADA.** El stub de `npm` del plan, extraído a un ejecutable
real y puesto en el PATH contra el fixture `npm-makro-12high.json`:

```
npm ci --ignore-scripts …            → rc=0
npm audit --audit-level=high         → rc=1   (correcto: hay 12 high)
npm audit --json | audit-exceptions.sh --filter <2 excepciones vigentes> npm
                                     → rc=0, y reporta 2 "excepción aplicada"
```
El JSON del stub tiene la forma que espera el `case` de `audit-exceptions.sh:221`. El diseño de
test se sostiene.

**2 · bash 3.2 — las dos construcciones nuevas, PROBADAS en `3.2.57(1)-release` real.**

```
for f in "${reqfiles[@]}";              → reqfiles[@]: unbound variable   (muere)
for f in ${reqfiles[@]+"${reqfiles[@]}"} → llega al final                 (correcto)
```
Y `num_o_muere` contra 12 entradas hostiles: acepta `0`, `12`, `999999999`; rechaza vacío, `-1`,
`1.5`, `abc`, `12x`, `0x1f`, con espacios delante o detrás, y multilínea. Rechazar es **fail-closed**,
así que un falso positivo bloquea en vez de dejar pasar.

**3 · ¿Los asserts discriminan? — MUTACIÓN, no lectura.** Es la casilla que el rol ausente debía
cubrir. Se cubrió fabricando scripts defectuosos y midiendo cuántos asserts los cazan:

| Prueba | Resultado |
|---|---|
| **(A) script ausente** | `rc=127`, y **los tres** valores esperados (0/1/2) lo rechazan, porque los asserts comparan por **igualdad exacta**. El assert de la anotación también falla: `out.txt` no contiene `::warning::`. Es la lección de los cuatro incidentes previos aplicada — un `!= 0` lo habría aceptado |
| **(B) mutante que exime de MÁS** (verde en cuanto existe el archivo, sin mirar ids) | **cazado por 6 de 9**: sobre-exención, vencida, comodín, ENOLOCK, control-ajena, sin-package |
| **(C) mutante que exime de MENOS** (ignora el archivo, siempre bloquea) | **cazado por 5 de 9**: dos-vigentes, anotación, comodín, ENOLOCK, sin-package |

Cada clase de defecto cae por **varios asserts independientes**, no por uno: el bloque no tiene un
único punto de detección que se pueda perder en un refactor.

⚠️ **Y una trampa en el propio arnés de medición, que casi falsea este resultado:** la primera
corrida dio *"1 de 1"*. En **zsh una variable sin comillas NO se parte en palabras** —al contrario
que en bash—, así que el bucle iteró una sola vez. Repetido bajo `/bin/bash` explícito con un array.
Misma clase que el `grep` envuelto que este sistema ya tiene documentada: **un arnés se valida
contra el shell real, no contra el que uno cree que tiene.**

**4 · El hallazgo 7 (symlink), CONFIRMADO ejecutando.** `audit-exceptions.sh` ya rechaza lo que no
es fichero regular —`⛔ /dev/null no es un fichero regular`— pero **acepta un symlink a un archivo
regular**: `rc=0` y excepción aplicada. La guarda `[ -h "$EXC" ]` de los `dep-gate-*` es necesaria;
el chequeo que ya existía aguas arriba **no** la cubre.

**Lo que el rol de seguridad atacó y aguantó** (importa tanto como lo que cayó): `pull_request_target` no existe
en ninguna receta ni stub —solo `workflow_call`, y los stubs declaran `permissions: contents: read`,
que es el techo del token—; cero interpolación `${{ }}` de dato del repo auditado dentro de un
`run:`; comodines, `all` y prefijos rechazados de verdad; `2026-02-30` inválida por round-trip; una
línea mala invalida el archivo entero y los duplicados se resuelven por la fecha **más temprana**;
`MAX_DIAS=90` es constante, no input; y las rutas de `/tmp` **no** son explotables en el CI actual
(runner efímero, y el único paso con código del caller va después del audit).

## Criterios de aceptación

Mecánicos: comando + resultado esperado. Ninguno es «que quede bien».

- [ ] `bash tests/dep-gate.test.sh` → `dep-gate: TODO VERDE`, **22 asserts** *(19 + los 3 discriminantes que la ronda 2 exigió: camino verde de pip, comodín de pip, comodín de composer)*
- [ ] **Las dos suites verdes en el MISMO entorno.** `bash tests/audit-exceptions.test.sh && bash tests/dep-gate.test.sh` en local **y** con `GITHUB_ACTIONS=true`. Medido en la ronda 2: sin el arreglo de `corre_gate`, una de las dos está siempre roja
- [ ] **MUTACIÓN del bloque pip:** `printf '#!/usr/bin/env bash\nexit 1\n' > tools/dep-gate-pip.sh` → **la suite falla**. Sin los asserts nuevos pasaba **5/5**
- [ ] **MUTACIÓN del bloque composer:** el mismo mutante → **falla**. Antes pasaba 4/5
- [ ] **El mecanismo NO es inerte en python:** con las 6 vulns del corpus exentas y vigentes, `dep-gate-pip.sh` → **0**
- [ ] `bash tests/audit-exceptions.test.sh` → `TODO VERDE`, **22 asserts** (17 previos + 5 de Task 1)
      ⚠️ Son **17**, no 18: el `ROLE-REVIEW-2026-08-12-audit-exceptions.md` decía 18 y este plan
      heredó la cifra sin ejecutarla. Contado corriendo el archivo, que es la única fuente que no
      miente sobre sí misma. Corregido también en el review.
- [ ] `bash tests/expect-audit-decision.sh` → exit 0 (no cambió ningún veredicto ya fijado)
- [ ] `bash tests/tag-completo.test.sh HEAD` → `el ref a publicar esta COMPLETO`
- [ ] `/usr/bin/grep -rn "audit-allow-cve\|AUDIT_ALLOW_CVE\|pip-audit-ignore-vuln\|IGNORE_VULN\|IGNORE_ARGS" .github/ tools/ tests/` → **sin coincidencias**
- [ ] `python3 -c "import yaml;[yaml.safe_load(open(f)) for f in ['.github/workflows/verify-node.yml','.github/workflows/verify-php.yml','.github/workflows/verify-python.yml','.github/workflows/selftest.yml']];print('YAML OK')"` → `YAML OK`
- [ ] Los tres `tools/dep-gate-*.sh` tienen bit de ejecución: `ls -l tools/dep-gate-*.sh | grep -c '^-rwx'` → `3`
- [ ] **No-regresión, el criterio que sostiene todo lo demás:** el primer assert de cada bloque (npm, composer, pip) verifica que **sin** `.watson-audit-exceptions.txt` el veredicto es idéntico al de hoy → 3 asserts en verde
- [ ] El selftest corre el test nuevo: `/usr/bin/grep -c 'dep-gate.test.sh' .github/workflows/selftest.yml` → `1`
- [ ] **Ningún `run:` invoca un `.sh` desde el checkout que se borra:** `/usr/bin/grep -c 'bash \.watson-ci-tooling/tools/' .github/workflows/*.yml` → **0 coincidencias** *(el `127` del hallazgo 1)*
- [ ] **El default de `tooling-ref` es `v3` en las tres recetas:** `/usr/bin/grep -c "default: 'v3'" .github/workflows/verify-{node,php,python}.yml` → `1` en cada una
- [ ] **`tag-completo` sabe decir que NO:** `bash tests/tag-completo.test.sh v2` → **falla** nombrando `tools/dep-gate-npm.sh`
- [ ] **El selftest ya no pasa el input retirado y tiene su archivo:** `/usr/bin/grep -c 'pip-audit-ignore-vuln' .github/workflows/selftest.yml` → 0, y `.watson-audit-exceptions.txt` existe en la raíz con los 3 PYSEC
- [ ] **El fail-open del `-e` está pagado:** con un `severity` no-string en el JSON, los tres scripts salen **2**, no 0. Test: inyectar `{"advisories":{"p":[{"severity":123}]}}` y verificar `rc=2`
- [ ] **Symlink rechazado:** `ln -s x .watson-audit-exceptions.txt` → los tres gates salen **2**
- [ ] **`AUDIT_LEVEL` no puede aflojar el gate:** `AUDIT_LEVEL=critical bash tools/dep-gate-npm.sh <repo-con-12-high>` → sigue **1**

## Prohibido

- **Ningún `input:` nuevo** en las tres recetas. El nombre y la ubicación del archivo van hardcodeados.
- **Ninguna variable de entorno NUEVA que altere el veredicto**, y **neutralizar la que ya existe**.
  ⚠️ Este punto decía que `AUDIT_OPTIONAL` y `GITHUB_ACTIONS` eran las únicas que se leen. **Era
  falso**: `tools/audit-exceptions.sh:25` es `UMBRAL="${AUDIT_LEVEL:-high}"`. Un `export
  AUDIT_LEVEL=critical` deja pasar **todo `high`** sin declarar una sola excepción, sin caducidad y
  sin aparecer en ningún diff — la forma exacta de `WATSON_CI_ALCANCE` que este plan citaba tres
  veces como la clase a no repetir, mientras la tenía dentro. No es alcanzable desde un PR (un
  caller no inyecta `env:` en el job de un reusable workflow), **sí** en `ci-local`/pre-push, donde
  un `export` persiste en el shell del dueño. Los tres `dep-gate-*.sh` hacen `export
  AUDIT_LEVEL=high` antes de invocar el filtro.
  `AUDIT_OPTIONAL` se conserva (ya existía, cubre «proyecto sin lockfile auditable»). `GITHUB_ACTIONS`
  **solo decide formato**, con test de control en los DOS veredictos —aplicada y vencida—, no solo en
  uno.
- **No colapsar el `2` a `1`** en ningún punto de la cadena.
- **No tocar `.github/actions/alcance/`** ni el reparto de qué pasos corren: dep-audit corre SIEMPRE, incluida documentación, y eso no se toca.
- **No mover el alias `v3`** desde esta sesión: es `push --force` y lo corre el dueño.
- **No declarar desbloqueado a `makro_logistica`**: bloquea en su propio `quality.yml`, que no pasa por estas recetas.

## Estimated Hours (staff, sin AI)

| Fase | Horas |
|---|---:|
| Análisis (leer los 3 pasos actuales, medir quién usa los inputs, mapear el contrato del filtro) | 2.0 |
| Diseño (frontera de confianza, contrato 0/1/2, la propiedad de no-regresión) | 1.5 |
| Admin (spec, plan, bitácora, README) | 2.0 |
| Implementación (3 scripts + 3 cableados + retirar 2 inputs) | 4.0 |
| Debugging (stubs de PATH, el `2` que se colapsaba, bash 3.2) | 3.0 |
| Testing (19 asserts nuevos + 5 de anotación, con controles negativos) | 3.5 |
| Review (loop de 3 roles sobre un cambio que altera el veredicto de CI de la flota) | 2.0 |
| **Total** | **18.0** |

## Auto-revisión del plan

**1 · Cobertura de la spec.** Frontera de confianza → Tasks 2/3/4 (los tres invocan desde `.watson-ci-tooling/`, nombre hardcodeado). Retirar los dos inputs → Tasks 3 y 4, con un paso explícito de verificar que no quedan referencias huérfanas. `::warning::` por excepción + días → Task 1. Contrato 0/1/2 → los tres scripts, y el paso 5 de Task 4 impide que el `2` se colapse a `1`. No-regresión sin archivo → primer assert de cada bloque. Los 9 casos de test obligatorios de la spec → repartidos entre Tasks 2-4. Publicación `v3.1.0` → Task 5. Los cuatro límites de alcance → Task 5, Step 3.

**2 · Placeholders.** Ninguno: cada paso lleva el código o el comando exacto. La única indirección es Task 4 Step 3 («copiar el cuerpo de `verify-python.yml:234-339` con estos cambios y ningún otro»), y va con las seis modificaciones enumeradas una a una — copiar 105 líneas al plan las duplicaría y la copia se desincronizaría del original.

**3 · Consistencia de nombres.** `.watson-audit-exceptions.txt` idéntico en spec, README, los tres scripts y los tres bloques de test. `EXC` y `FILTRO` con el mismo nombre en los tres scripts. Los ecosistemas que acepta el filtro son `npm` / `composer` / `pip-audit` — con guion en el tercero, que es como lo espera el `case` de `audit-exceptions.sh:220-224`, y así está escrito en Task 4. `stub_bin`, `corre_gate`, `repo_npm`, `repo_composer`, `repo_pip`: definidos en Task 2 y consumidos con esos nombres en 3 y 4.

**4 · Un hueco que la spec no cubría y el plan sí.** El contrato dice `2 = ERROR`, pero el `audit_source` de python colapsaba todo fallo a `rc_total=1`. Sin el cambio del paso 5 de Task 4, un filtro muerto se habría reportado como *"hay vulnerabilidades"* — el gate correcto con el diagnóstico equivocado, que es la clase que este repo ya cazó una vez en ese mismo bloque.
