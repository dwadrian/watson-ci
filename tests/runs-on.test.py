#!/usr/bin/env python3
# Logica de tests/runs-on.test.sh (ver ahi el POR QUE). Uso: python3 -I tests/runs-on.test.py <raiz-del-repo>
import hashlib, json, os, re, sys, tempfile, textwrap, urllib.request
from pathlib import Path

RAIZ = Path(sys.argv[1])
RECETAS = ["verify-node.yml", "verify-python.yml", "verify-php.yml"]
RUNS_ON_ESPERADO = """${{ fromJSON(inputs.runs-on || '"ubuntu-latest"') }}"""
# jq 1.8.2 (2026-06-20): 1.8.0 corrigio CVE-2024-23337, CVE-2024-53427, CVE-2025-48060. Los sha256
# son los de `sha256sum.txt` del release oficial (gh release download jq-1.8.2 --repo jqlang/jq).
JQ_VERSION = "jq-1.8.2"
JQ_SHA = {
    "amd64": "b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f",
    "arm64": "8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309",
}
JQ_ARCH_UNAME = {"amd64": r"x86_64\)", "arm64": r"aarch64\|arm64\)"}
JQ_URL_PREFIJO = "https://github.com/jqlang/jq/releases/download/"


def yaml_escalar(v):
    """Escalar YAML de una linea: '...' (con '' escapado), "..." o plano."""
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    if len(v) >= 2 and v[0] == v[-1] == '"':
        return json.loads(v)
    return v


def bloques_jobs(lineas):
    """{job: [lineas del job]} para las claves de 2 espacios bajo `jobs:`."""
    jobs, actual, dentro = {}, None, False
    for ln in lineas:
        if re.match(r"^jobs:\s*$", ln):
            dentro = True
            continue
        if dentro and re.match(r"^\S", ln):
            break
        if not dentro:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", ln)
        if m:
            actual = m.group(1)
            jobs[actual] = []
        elif actual is not None:
            jobs[actual].append(ln)
    return jobs


def props_input(lineas, nombre):
    """Propiedades del input `nombre` de workflow_call (claves a 8 espacios)."""
    props, dentro = {}, False
    for ln in lineas:
        if re.match(rf"^      {re.escape(nombre)}:\s*$", ln):
            dentro = True
            continue
        if dentro:
            if re.match(r"^ {0,6}\S", ln):
                break
            m = re.match(r"^        ([a-z-]+):\s*(.*)$", ln)
            if m:
                props[m.group(1)] = m.group(2)
    return props if dentro else None


def bloque_paso(lineas, patron_nombre):
    """(indice_inicio, indice_fin) del paso cuyo `- name:` casa con patron_nombre."""
    ini = None
    for i, ln in enumerate(lineas):
        if re.match(r"^      - name:", ln):
            if ini is not None:
                return ini, i
            if re.search(patron_nombre, ln):
                ini = i
    return (ini, len(lineas)) if ini is not None else (None, None)


def revisa(texto):
    """Lista de errores (vacia = la receta cumple)."""
    errores = []
    lineas = texto.splitlines()

    # 1. Todo `runs-on:` a nivel de job (4 espacios) es la expresion esperada. Los jobs con otra
    # indentacion o sin runs-on los atrapa el conteo por bloque de abajo.
    for i, ln in enumerate(lineas, 1):
        m = re.match(r"^(\s*)runs-on:\s*(.*)$", ln)
        if m and len(m.group(1)) == 4 and m.group(2) != RUNS_ON_ESPERADO:
            errores.append(f"L{i}: runs-on no pasa por el input: {m.group(2)!r}")
    jobs = bloques_jobs(lineas)
    if not jobs:
        errores.append("no encontre ningun job bajo `jobs:`")
    for job, cuerpo in jobs.items():
        ro = [l for l in cuerpo if re.match(r"^    runs-on:", l)]
        if len(ro) != 1:
            errores.append(f"job {job}: {len(ro)} lineas runs-on (se esperaba 1)")
        # 4. Primer paso = requisitos del runner.
        pasos = [l for l in cuerpo if re.match(r"^      - name:", l)]
        if not pasos or "Requisitos del runner" not in pasos[0]:
            errores.append(f"job {job}: el primer paso no es 'Requisitos del runner'")

    # 2. El input.
    p = props_input(lineas, "runs-on")
    if p is None:
        errores.append("falta el input `runs-on` en workflow_call")
    else:
        if p.get("type") != "string":
            errores.append(f"input runs-on: type={p.get('type')!r} (se esperaba string)")
        if p.get("required") != "false":
            errores.append(f"input runs-on: required={p.get('required')!r} (se esperaba false)")
        try:
            d = json.loads(yaml_escalar(p.get("default", "")))
        except ValueError:
            d = None
        if d != "ubuntu-latest":
            errores.append(f"input runs-on: el default decodifica a {d!r}, no a 'ubuntu-latest'")

    # 3. El fallback de la expresion.
    m = re.search(r"fromJSON\(inputs\.runs-on \|\| '(.*?)'\)", texto)
    try:
        f = json.loads(m.group(1).replace("''", "'")) if m else None
    except ValueError:
        f = None
    if f != "ubuntu-latest":
        errores.append(f"el fallback de fromJSON decodifica a {f!r}, no a 'ubuntu-latest'")

    # 1b. Un job en forma de mapping en linea (`  x: {runs-on: ...}`) esquiva el conteo por
    # bloques: no se admite, las recetas escriben los jobs en bloque.
    dentro = False
    for i, ln in enumerate(lineas, 1):
        if re.match(r"^jobs:\s*$", ln):
            dentro = True
            continue
        if dentro and re.match(r"^\S", ln):
            break
        if dentro and re.match(r"^  [A-Za-z0-9_-]+:\s*\S", ln) and not re.match(r"^  [A-Za-z0-9_-]+:\s*#", ln):
            errores.append(f"L{i}: job escrito en linea; las recetas escriben los jobs en bloque")

    # 4b. El paso de requisitos no se puede neutralizar: sin `if:`/`continue-on-error`, falla con
    # `exit 1`, y nunca sale antes con `exit 0`. En php, comprueba sudo SIEMPRE (no solo si
    # RUNNER_ENVIRONMENT dice self-hosted: setup-php decide self-hosted por mas señales).
    ri, rf = bloque_paso(lineas, r"Requisitos del runner")
    if ri is not None:
        req = lineas[ri:rf]
        if any(re.match(r"^        (if|continue-on-error):", l) for l in req):
            errores.append("el paso de requisitos lleva if:/continue-on-error (se puede saltar)")
        if not any("exit 1" in codigo(l) for l in req) or any(re.search(r"\bexit 0\b", codigo(l)) for l in req):
            errores.append("el paso de requisitos no falla con exit 1 (o sale antes con exit 0)")
        # (Hasta la ronda 2 aqui se exigia `sudo -n true` incondicional para setup-php. Ya no aplica:
        # setup-php solo corre en un runner ALOJADO, que trae sudo de serie; en un runner propio no
        # se llama — ver 6.)
        errores += revisa_falla_cerrado(lineas, req, texto)

    # 5. jq fijado antes de usarse. Cualquier `jq` como palabra en una linea que no sea comentario
    # ni del propio paso de instalacion cuenta como uso.
    ini, fin = bloque_paso(lineas, r"Instalar jq")
    usos = [i for i, ln in enumerate(lineas)
            if not ln.lstrip().startswith("#") and not re.match(r"^\s*- name:", ln)
            and re.search(r"(?<![\w.-])jq(?![\w.-])", codigo(ln))
            and not (ini is not None and ini <= i < fin)]
    if usos:
        if ini is None:
            errores.append(f"usa jq (L{usos[0]+1}) pero no tiene el paso 'Instalar jq' fijado")
        else:
            errores += revisa_paso_jq(lineas[ini:fin])
            if usos[0] < ini:
                errores.append(f"jq se usa en L{usos[0]+1}, ANTES de instalarlo (L{ini+1})")
    return errores


def codigo(ln):
    """La linea sin su comentario de shell (aproximado: lo que va tras ` #`)."""
    return re.split(r"\s#", ln, maxsplit=1)[0]


# ── 6. Falla cerrado en un runner propio (ronda 2 de fabrica#2425, P1/P2 de Codex) ────────────
# setup-php (sin PHP en el runner) descarga y ejecuta un instalador de `releases/latest` / `@main`
# sin checksum; setup-python (sin Python en el tool cache) baja y ejecuta un `setup.sh` sin checksum
# y luego hace `pip install --upgrade pip` sin version ni hashes; setup-node baja Node sin verificar.
# Principio: en un runner propio NO se descarga codigo sin verificar. Esas actions solo corren en un
# runner ALOJADO de GitHub con el runs-on por defecto (ahi la imagen ya trae las versiones y el
# comportamiento no cambia). En un runner propio la imagen tiene que traerlas, y el primer paso lo
# comprueba con la version pedida.
SETUP_ACTIONS = ("actions/setup-python@", "actions/setup-node@", "shivammathur/setup-php@")
IF_ALOJADO = "if: steps.runner.outputs.alojado == 'true'"
IF_PROPIO = "if: steps.runner.outputs.alojado != 'true'"
USES_PERMITIDOS = ("actions/checkout@",) + SETUP_ACTIONS
PY_TOKEN = re.compile(r"(?<![\w-])(python\d*(?:\.\d+)?|pip3?|pip-audit|pip_audit)(?![\w-])")
PY_LINEAS_PERMITIDAS = {
    # requisitos (propio)
    """py=$(python3 -I -c 'import sys, venv, ensurepip; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || py=\"\"""",
    # Python del runner (propio)
    'python3 -I -m venv --clear "$venv" || { echo "::error::python3 no pudo crear el venv (Debian/Ubuntu: falta python3.X-venv) — ver README § Runner propio."; exit 1; }',
    '"$venv/bin/python" --version',
    '"$venv/bin/python" -I -m pip --version',
    # jq fijado
    """python -I - "$JQ_VERSION" "$arch" "$sha" "$dir/jq" <<'PY'""",
    # tooling con hashes
    "run: pip install --require-hashes --no-deps -r .watson-ci-tooling/tools/requirements-semgrep.txt",
    "python -I -m venv --clear /tmp/venv-semgrep",
    "/tmp/venv-semgrep/bin/pip install --quiet --require-hashes --no-deps -r .watson-ci-tooling/tools/requirements-semgrep.txt",
    "python -I -m venv --clear /tmp/venv-pipaudit",
    "/tmp/venv-pipaudit/bin/pip install --quiet --require-hashes --no-deps -r .watson-ci-tooling/tools/requirements-pip-audit.txt",
    "/tmp/venv-pipaudit/bin/pip-audit --version",
    'timeout 300 pip-audit "$@" "${IGNORE_ARGS[@]}" --format=json > "$out" 2>/tmp/pipaudit_err_$$.txt',
    # rulesets de semgrep (`p/python` no invoca nada, pero casa el token)
    "CONFIGS='--config p/security-audit --config p/python'",
    'run: semgrep scan --config "p/security-audit" --config "p/python" --severity WARNING --quiet --disable-version-check --metrics=off --timeout 120 . || true',
}
SHELL_LINEAS_PERMITIDAS = {
    "run: bash .watson-ci-tooling/.github/actions/alcance/alcance.sh",   # tooling de watson-ci
    'run: bash -c "$TEST_CMD"',   # el `test-command` que el CALLER declara (verify-node)
    # la lista de comprobacion de requisitos (`bash` es un nombre, no se ejecuta)
    'for t in bash git grep sed cat wc tr tar gzip uname; do',
    'for t in bash git grep sed cat wc tr tar gzip uname find sort timeout; do',
}
GITHUB_PATH_PERMITIDOS = {
    'echo "$venv/bin" >> "$GITHUB_PATH"',            # Python del runner (propio)
    'echo "$dir" >> "$GITHUB_PATH"',                 # jq fijado
    'echo "/tmp/venv-semgrep/bin" >> "$GITHUB_PATH"',
    'echo "/tmp/venv-pipaudit/bin" >> "$GITHUB_PATH"',
}
# Los `with:` del camino alojado (regex sobre la linea sin sangria): si cambian, cambia alojado.
WITH_ALOJADO = {
    "actions/setup-python@": [r"python-version: (?:'3\.12'|\$\{\{ inputs\.python-version \}\})"],
    "actions/setup-node@": [r"node-version: \$\{\{ inputs\.node-version \}\}"],
    "shivammathur/setup-php@": [r"php-version: \$\{\{ inputs\.php-version \}\}", r"tools: composer:2", r"coverage: none"],
}
# Lo que cada receta exige a un runner propio: herramienta -> (stub con version buena, con mala).
# Las «malas» incluyen la trampa de prefijo (3.120 no es 3.12; v200 no es 20; 8.30 no es 8.3).
PY_MALAS = ("3.11.9", "3.120.0")
PROPIO = {
    "verify-node.yml": {"python3": ("3.12.3", PY_MALAS), "node": ("v20.11.1", ("v18.20.0", "v200.1.0")), "npm": ("10.2.4", ())},
    "verify-python.yml": {"python3": ("3.12.3", PY_MALAS)},
    "verify-php.yml": {"python3": ("3.12.3", PY_MALAS), "php": ("8.3.6", ("8.2.1", "8.30.0")),
                        "composer": ("Composer version 2.8.4 2024-12-11 11:57:47",
                                     ("Composer version 1.10.27 2023-09-29", "Composer version 22.0.0 2030-01-01"))},
}


def pasos(lineas):
    """[(ini, fin)] de cada paso: de un `      - ` al siguiente (o al final del job)."""
    ini = [i for i, l in enumerate(lineas) if re.match(r"^      - ", l)]
    return [(a, b) for a, b in zip(ini, ini[1:] + [len(lineas)])]


def revisa_falla_cerrado(lineas, req, texto):
    errores = []
    if not any(re.match(r"^        id: runner\s*$", l) for l in req):
        errores.append("el paso de requisitos no lleva `id: runner` (de el sale el modo alojado/propio)")
    for clave, valor in (("RUNS_ON_INPUT", "${{ inputs.runs-on }}"), ("RUNNER_ENV", "${{ runner.environment }}")):
        if not any(l.strip() == f"{clave}: {valor}" for l in req):
            errores.append(f"el paso de requisitos no recibe {clave}: {valor} por env")
    # 6d. Reglas GENERALES (ronda 1 de refutacion): no basta con vigilar tres actions concretas.
    #   - `uses:` solo de la allowlist (comparada sin mayusculas: GitHub resuelve owner/repo asi).
    #   - Ninguna linea de codigo descarga por su cuenta (curl/wget/`| sh`) ni actualiza nada con
    #     `--upgrade`/`-U`/`--upgrade-deps`/get-pip: pip queda el que trae el Python, sin version nueva.
    #   - urlopen solo dentro del paso 'Instalar jq' (que verifica sha256).
    #   - Todo venv se crea con --clear: en un runner reutilizado no se hereda uno envenenado.
    ji, jf = bloque_paso(lineas, r"Instalar jq")
    for i, l in enumerate(lineas):
        c = codigo(l)
        if l.lstrip().startswith("#"):
            continue
        m = re.search(r"\buses:\s*['\"]?([^'\"\s#]+)", c)
        if m and not m.group(1).lower().startswith(USES_PERMITIDOS):
            errores.append(f"L{i+1}: `uses: {m.group(1)}` fuera de la allowlist {USES_PERMITIDOS}")
        if re.search(r"\b(curl|wget)\b|\|\s*(ba)?sh\b|--upgrade|\bpip3?\b[^#]*\binstall\b[^#]*\s-U\b|get-pip", c):
            errores.append(f"L{i+1}: descarga o actualiza por su cuenta: {l.strip()}")
        if "urlopen" in c and not (ji is not None and ji <= i < jf):
            errores.append(f"L{i+1}: urlopen fuera del paso 'Instalar jq'")
        if re.search(r"-m venv\b", c) and "--clear" not in c:
            errores.append(f"L{i+1}: venv sin --clear: {l.strip()}")
        # Ronda 2 de refutacion. `python -m X` sin -I busca X PRIMERO en el cwd, que tras el
        # checkout es el repo del caller: un `venv/` o `pip/` plantado ahi toma el control.
        # Incluye `python -` (heredoc): tambien pone el cwd en sys.path — un hashlib.py del caller
        # suplantaria la verificacion del sha256 de jq (gatekeeper, ronda 3).
        if re.search(r"(?:\bpython3?|bin/python)\"?\s+(?!-I\b)-(?:[mc]\b|\s)", c):
            errores.append(f"L{i+1}: python -m/-c/- sin -I (resuelve modulos del repo del caller): {l.strip()}")
        if re.search(r"\bpip3?\"?\s+install\b|-m pip install\b", c) and not (
                "--require-hashes" in c and re.search(r"\s-r\s", c)):
            errores.append(f"L{i+1}: pip install sin --require-hashes -r: {l.strip()}")
        # Sin el texto entre comillas dobles (mensajes de echo). `codigo()` puede cortar dentro de
        # una cadena (` #654`): una comilla sin cerrar se come hasta el final.
        sc = re.sub(r'"[^"]*(?:"|$)', '""', c)
        sc = re.sub(r"'[^']*(?:'|$)", "''", sc)
        # pip-audit en CUALQUIER posicion de comando (`if pip-audit`, `$(pip-audit`, ...): solo vale
        # la llamada de audit_source y el `--version` del venv.
        if re.search(r"(?<![\w/.-])pip-audit(?![\w-])", sc) and not re.match(r"^\s*-?\s*name:", l) and \
                c.strip() != 'timeout 300 pip-audit "$@" "${IGNORE_ARGS[@]}" --format=json > "$out" 2>/tmp/pipaudit_err_$$.txt':
            errores.append(f"L{i+1}: pip-audit invocado fuera de audit_source: {l.strip()}")
        cmd = r"(?:^\s*|[;&|]\s*|\brun:\s*|\bthen\s+|\bdo\s+)"  # posicion de comando
        if re.search(cmd + r"(?:pipx|uvx?)\s|\bnpm (?:exec|x)\b", sc) or \
                re.search(r"(?:^\s*|[;&]\s*|\brun:\s*|\bthen\s+|\bdo\s+)(?:\./\S|\.\s+[./~$]|source\s)", sc):
            errores.append(f"L{i+1}: ejecuta codigo descargado o del repo: {l.strip()}")
        if re.search(r"\baudit_source \"pylock", c) and "--locked" not in c:
            errores.append(f"L{i+1}: pip-audit sobre pylock sin --locked (instalaria el proyecto)")
        if re.search(r"\b(urllib|urlretrieve|requests\.|http\.client)\b", c) and not (ji is not None and ji <= i < jf):
            errores.append(f"L{i+1}: descarga por python fuera del paso 'Instalar jq': {l.strip()}")
        if re.search(r"\bgit clone\b|\bnpx\b|\bnpm (?:install|i) (?:-g|--global)\b|\bcomposer\s+(?:\S+\s+)*?(?:self-update|install|update|require|global|create-project)\b|--system-site-packages", c):
            errores.append(f"L{i+1}: instala/descarga codigo por su cuenta: {l.strip()}")
        if re.search(r"\bnpm (?:ci|install)\b", sc) and "--ignore-scripts" not in sc:
            errores.append(f"L{i+1}: npm sin --ignore-scripts: {l.strip()}")
        if re.search(r"\b(?:ba)?sh\s+[^\s|;&]+\.sh\b", c) and c.strip() != "run: bash .watson-ci-tooling/.github/actions/alcance/alcance.sh":
            errores.append(f"L{i+1}: ejecuta un .sh fuera de la allowlist: {l.strip()}")
        if "GITHUB_PATH" in c and c.strip() not in GITHUB_PATH_PERMITIDOS:
            errores.append(f"L{i+1}: escritura a $GITHUB_PATH fuera de la allowlist: {l.strip()}")
    # 6h. ALLOWLIST EXACTA (gatekeeper, ronda 4): las reglas por regex de arriba se esquivaban con
    # sinonimos (`python -u -`, ruta absoluta a pip-audit, `-m pip_audit`, `$(command -v ...)`,
    # `ALOJADO=true`, `unset "${!SIN_@}"`, `bash scripts/x`, `if ./x`). En vez de perseguirlos: toda
    # linea que invoque python/pip/pip-audit tiene que ser UNA de las literales aprobadas, ALOJADO
    # solo se lee, y no hay interpretes de shell sueltos. Una linea nueva legitima = se anade aqui
    # a proposito, a la vista del revisor.
    for i, l in enumerate(lineas):
        if l.lstrip().startswith("#") or re.match(r"^\s*-?\s*(name|description):", l):
            continue
        c = codigo(l)
        sc = re.sub(r'"[^"]*(?:"|$)', '""', c)
        sc = re.sub(r"'[^']*(?:'|$)", "''", sc)
        if c.strip().startswith("echo ") and not PY_TOKEN.search(sc):
            pass  # mensaje puro
        elif PY_TOKEN.search(c) and c.strip() not in PY_LINEAS_PERMITIDAS:
            errores.append(f"L{i+1}: invoca python/pip/pip-audit fuera de la allowlist: {l.strip()}")
        if "ALOJADO" in c and c.strip() != "ALOJADO: ${{ steps.runner.outputs.alojado }}" and \
                c.count("ALOJADO") != c.count('"$ALOJADO"'):
            errores.append(f"L{i+1}: ALOJADO solo se lee como \"$ALOJADO\": {l.strip()}")
        if re.search(r"\bunset\b|\$\{!|\beval\b", c):
            errores.append(f"L{i+1}: unset/eval/indireccion prohibidos (anularian SIN_*): {l.strip()}")
        if re.search(r"(?<![\w./-])(?:ba|da|z)?sh(?![\w.-])", sc) and not re.match(r"^\s*shell: (?:ba)?sh\s*$", c) \
                and c.strip() not in SHELL_LINEAS_PERMITIDAS:
            errores.append(f"L{i+1}: interprete de shell fuera de la allowlist: {l.strip()}")
        if re.search(r"(?<![\w.])\./", sc):
            errores.append(f"L{i+1}: ejecuta un ./ del repo: {l.strip()}")
    # 6e. Lo que corre en ALOJADO no cambia: los `with:` de cada action de setup, EXACTOS (ni falta
    # ni sobra una clave: `check-latest: true` forzaria una descarga, `extensions:` cambia PHP).
    for a, b in pasos(lineas):
        paso = "\n".join(lineas[a:b])
        for accion, lineas_with in WITH_ALOJADO.items():
            if re.search(r"uses:\s*['\"]?" + re.escape(accion), paso, flags=re.I):
                w_i = next((i for i in range(a, b) if re.match(r"^        with:\s*$", lineas[i])), None)
                claves = []
                if w_i is not None:
                    for l in lineas[w_i + 1:b]:
                        if re.match(r"^          \S", l):
                            claves.append(codigo(l).strip())
                        elif l.strip() and not l.lstrip().startswith("#"):
                            break
                if len(claves) != len(lineas_with) or not all(
                        any(re.fullmatch(w, k) for k in claves) for w in lineas_with):
                    errores.append(f"L{a+1}: el `with:` de {accion} no es exactamente {lineas_with}: {claves} (cambia alojado)")
    # 6g. composer en runner propio, sin plugins ni scripts: `composer audit` carga los plugins de
    # vendor/composer/installed.json (Composer Factory::loadInstalledPlugins), que viene del repo.
    if "composer audit" in texto:
        if not any(codigo(l).strip() == '[ "$ALOJADO" = true ] || SIN_PLUGINS=(--no-plugins --no-scripts)' for l in lineas):
            errores.append("composer audit: falta `[ \"$ALOJADO\" = true ] || SIN_PLUGINS=(--no-plugins --no-scripts)`")
        if sum(1 for l in lineas if "SIN_PLUGINS" in codigo(l)) != 3:
            errores.append("composer audit: SIN_PLUGINS aparece un numero de veces distinto de 3 (init/condicion/uso)")
        for i, l in enumerate(lineas):
            sc = re.sub(r'"[^"]*"', '""', codigo(l))
            if re.search(r"\bcomposer\s+(?:\S+\s+)*?audit\b", sc) and not l.lstrip().startswith(("#", "- name")) \
                    and 'composer "${SIN_PLUGINS[@]}" audit' not in codigo(l):
                errores.append(f"L{i+1}: composer audit sin \"${{SIN_PLUGINS[@]}}\"")
        if not any(l.strip() == "ALOJADO: ${{ steps.runner.outputs.alojado }}" for l in lineas):
            errores.append("el paso de composer audit no recibe ALOJADO: ${{ steps.runner.outputs.alojado }}")
        if not re.search(r"composer --no-plugins --no-scripts --no-interaction --version", texto):
            errores.append("el chequeo de composer en requisitos no lleva --no-plugins --no-scripts")
    # 6f. pip-audit sobre requirements: sin --disable-pip crea un venv, hace `pip install --upgrade
    # pip` SIN version e instala los requirements del caller (pip-audit 2.10.1,
    # _dependency_source/requirement.py:161-177 y _virtual_env.py:119-134). En runner propio va con
    # --disable-pip: audita los pins sin instalar nada. En alojado sigue como estaba.
    if re.search(r"\bpip-audit\b", texto) and re.search(r"\baudit_source\b", texto):
        llamadas = [l for l in lineas if re.search(r"audit_source [^\n]*-r ", codigo(l))]
        if not llamadas or any('"${SIN_PIP[@]}"' not in codigo(l) for l in llamadas):
            errores.append("pip-audit -r no pasa \"${SIN_PIP[@]}\" (en runner propio instalaria con pip)")
        if not any(l.strip() == "ALOJADO: ${{ steps.runner.outputs.alojado }}" for l in lineas):
            errores.append("el paso de pip-audit no recibe ALOJADO: ${{ steps.runner.outputs.alojado }}")
        if not any(codigo(l).strip() == '[ "$ALOJADO" = true ] || SIN_PIP=(--disable-pip)' for l in lineas):
            errores.append("pip-audit: falta `[ \"$ALOJADO\" = true ] || SIN_PIP=(--disable-pip)`")
        if not any(codigo(l).strip() == "SIN_PIP=()" for l in lineas):
            errores.append("pip-audit: falta inicializar SIN_PIP=()")
        # Exactamente 3 menciones: init, condicion, uso. Un reset o un `unset` lo anularia.
        if sum(1 for l in lineas if "SIN_PIP" in codigo(l)) != 3:
            errores.append("pip-audit: SIN_PIP aparece un numero de veces distinto de 3 (init/condicion/uso)")
    # 6a. Todo paso que usa una action de setup va condicionado, EXACTAMENTE, al modo alojado.
    hay_setup_python = False
    for a, b in pasos(lineas):
        paso = lineas[a:b]
        usa = [l for l in paso if re.search(r"\buses:\s*['\"]?(%s)" % "|".join(map(re.escape, SETUP_ACTIONS)), codigo(l), flags=re.I)]
        if not usa:
            continue
        hay_setup_python |= any("setup-python" in l for l in usa)
        ifs = [l.strip() for l in paso if re.match(r"^\s*-?\s*if:", l)]
        if ifs != [IF_ALOJADO]:
            errores.append(f"L{a+1}: {usa[0].strip()} no va con `{IF_ALOJADO}` (tiene {ifs}): en un runner propio descargaria sin verificar")
    # 6b. Cualquier `uses:` de setup fuera de un paso reconocible (p. ej. en linea) tampoco vale.
    n_setup = sum(1 for l in lineas if any(s in codigo(l) for s in SETUP_ACTIONS))
    n_en_pasos = sum(1 for a, b in pasos(lineas) for l in lineas[a:b] if any(s in codigo(l) for s in SETUP_ACTIONS))
    if n_setup != n_en_pasos:
        errores.append("hay una action de setup fuera de un paso en bloque")
    # 6c. En un runner propio, Python sale de la imagen: un venv con el pip que trae ensurepip, sin
    # instalar ni actualizar pip, y antes de cualquier uso de python/pip.
    if hay_setup_python:
        propios = [(a, b) for a, b in pasos(lineas) if any(l.strip() == IF_PROPIO for l in lineas[a:b])]
        if len(propios) != 1:
            errores.append(f"se esperaba 1 paso 'Python del runner' con `{IF_PROPIO}`, hay {len(propios)}")
        else:
            a, b = propios[0]
            cuerpo = [codigo(l) for l in lineas[a:b]]
            ifs = [l.strip() for l in lineas[a:b] if re.match(r"^\s*-?\s*if:", l)]
            if ifs != [IF_PROPIO]:
                errores.append(f"'Python del runner' con condiciones de mas: {ifs}")
            if not any(re.search(r"\bpython3 -I -m venv --clear\b", l) for l in cuerpo):
                errores.append("'Python del runner' no crea el venv con `python3 -I -m venv --clear`")
            if not any(re.search(r'>> "\$GITHUB_PATH"', l) for l in cuerpo):
                errores.append("'Python del runner' no pone el venv en $GITHUB_PATH")
            prohibido = r"\binstall\b|--upgrade|get-pip|curl|wget|urlopen|--without-pip|uses:|--system-site-packages"
            malas = [l.strip() for l in cuerpo if re.search(prohibido, l)]
            if malas:
                errores.append(f"'Python del runner' descarga o actualiza algo: {malas}")
            if not any("README § Runner propio" in l for l in cuerpo):
                errores.append("'Python del runner' no remite a README § Runner propio si el venv no se puede crear")
            usos_py = [i for i, l in enumerate(lineas) if not (a <= i < b)
                       and re.search(r"(?<![\w/.-])(python|pip)(?![\w.-])", codigo(l))
                       and not l.lstrip().startswith("#") and not re.match(r"^\s*-?\s*name:", l)]
            if usos_py and usos_py[0] < a:
                errores.append(f"python/pip se usa en L{usos_py[0]+1}, antes de 'Python del runner' (L{a+1})")
    return errores


def env_del_paso(paso_lineas, defaults, runs_on, entorno):
    """El `env:` del paso, con las expresiones resueltas como las resolveria Actions."""
    env, dentro = {}, False
    for l in paso_lineas:
        if re.match(r"^        env:\s*$", l):
            dentro = True
            continue
        if dentro:
            m = re.match(r"^          ([A-Z_][A-Z0-9_]*):\s*(.*)$", l)
            if not m:
                break
            k, v = m.group(1), m.group(2).strip()
            e = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", v)
            if not e:
                env[k] = yaml_escalar(v)
            elif e.group(1) == "inputs.runs-on":
                env[k] = runs_on
            elif e.group(1) == "runner.environment":
                env[k] = entorno
            elif e.group(1).startswith("inputs.") and e.group(1)[7:] in defaults:
                env[k] = defaults[e.group(1)[7:]]
            else:
                raise ValueError(f"expresion no resoluble en el env del paso: {v}")
    return env


def ejecuta_requisitos(texto, receta):
    """CONDUCTA del paso de requisitos: su script real, con `sh`, PATH de stubs y el env del paso.
    Casos: alojado (no exige nada de la imagen) / propio con todo / propio sin cada herramienta /
    propio con cada version equivocada. Devuelve la lista de errores."""
    lineas = texto.splitlines()
    ri, rf = bloque_paso(lineas, r"Requisitos del runner")
    if ri is None:
        return ["no hay paso de requisitos que ejecutar"]
    paso = lineas[ri:rf]
    k = next((i for i, l in enumerate(paso) if re.match(r"^        run: \|\s*$", l)), None)
    if k is None:
        return ["el paso de requisitos no tiene `run: |`"]
    script = textwrap.dedent("\n".join(l for l in paso[k + 1:])) + "\n"
    defaults = {}
    for n in ("node-version", "python-version", "php-version"):
        p = props_input(lineas, n)
        if p and "default" in p:
            defaults[n] = yaml_escalar(p["default"])
    req = PROPIO[receta]
    errores = []

    def corre(runs_on, entorno, herramientas):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin")
            os.mkdir(b)
            for real in ("sed", "grep", "cat", "tr", "uname", "wc"):
                for base in ("/usr/bin", "/bin"):
                    if os.path.exists(os.path.join(base, real)):
                        os.symlink(os.path.join(base, real), os.path.join(b, real))
                        break
            stubs = {"git": "git version 2.43.0", "bash": "", "tar": "", "gzip": "", "find": "", "sort": "",
                     "timeout": "", "curl": ""}
            stubs.update(herramientas)
            for nombre, salida in stubs.items():
                with open(os.path.join(b, nombre), "w") as f:
                    # None = la herramienta existe pero falla (python3 sin venv/ensurepip, php roto).
                    f.write("#!/bin/sh\nexit 1\n" if salida is None else f"#!/bin/sh\nprintf '%s\\n' '{salida}'\n")
                os.chmod(os.path.join(b, nombre), 0o755)
            out = os.path.join(d, "out")
            open(out, "w").close()
            env = {"PATH": b, "GITHUB_OUTPUT": out, "RUNNER_TEMP": d, "HOME": d}
            env.update(env_del_paso(paso, defaults, runs_on, entorno))
            import subprocess
            # `-e`: Actions ejecuta `shell: sh` como `sh -e {0}` (github/docs supported-shells). Sin
            # -e aqui, una asignacion `py=$(python3 ...)` que falla cortaria el job en Actions SIN
            # el mensaje que remite al README, y el test no lo veria (ronda 2 de refutacion).
            r = subprocess.run(["/bin/sh", "-e", "-c", script], env=env, capture_output=True, text=True, timeout=30)
            salida = open(out).read()
            m = re.findall(r"^alojado=(.*)$", salida, flags=re.M)
            return r.returncode, (m[-1] if m else None), r.stdout + r.stderr

    buenas = {t: v[0] for t, v in req.items()}
    try:
        for etiqueta, runs_on, entorno, esperado in (
                ("alojado, runs-on vacio", "", "github-hosted", "true"),
                ("alojado, runs-on default", '"ubuntu-latest"', "github-hosted", "true")):
            rc, al, log = corre(runs_on, entorno, {})  # sin NADA de la imagen: alojado no lo exige
            if rc != 0 or al != esperado:
                errores.append(f"{etiqueta}: rc={rc} alojado={al!r} (se esperaba 0/'true') — se pierde el comportamiento alojado\n{log}")
        for etiqueta, runs_on, entorno in (
                ("propio, self-hosted con etiqueta", '["self-hosted","makro-web"]', "self-hosted"),
                ("propio, self-hosted con runs-on default", '"ubuntu-latest"', "self-hosted"),
                ("propio, self-hosted con runs-on vacio", "", "self-hosted"),
                ("propio, github-hosted con otra etiqueta", '"ubuntu-24.04"', "github-hosted"),
                ("propio, runner.environment vacio (runner antiguo)", "", "")):
            rc, al, log = corre(runs_on, entorno, buenas)
            if rc != 0 or al != "false":
                errores.append(f"{etiqueta}, imagen completa: rc={rc} alojado={al!r} (se esperaba 0/'false')\n{log}")
        for t, (buena, malas) in req.items():
            sin = {x: v for x, v in buenas.items() if x != t}
            rc, al, log = corre('["self-hosted"]', "self-hosted", sin)
            if rc == 0 or al is not None or "README § Runner propio" not in log or "Modo RUNNER PROPIO" not in log:
                errores.append(f"propio sin {t}: rc={rc} alojado={al!r} — no falla cerrado remitiendo al README (y explicando el modo)")
            for mala in malas + (None,):
                rc, al, log = corre('["self-hosted"]', "self-hosted", {**buenas, t: mala})
                if rc == 0 or al is not None or "README § Runner propio" not in log:
                    errores.append(f"propio con {t} en version equivocada ({mala}): rc={rc} — no falla remitiendo al README")
    except ValueError as e:
        errores.append(str(e))
    return errores


def revisa_paso_jq(paso_lineas):
    """El paso 'Instalar jq': estructura (version, sha por arquitectura, PATH) y CONDUCTA del
    python que descarga — se ejecuta de verdad con urlopen simulado."""
    errores = []
    paso = "\n".join(paso_lineas)
    if f"JQ_VERSION: {JQ_VERSION}" not in paso:
        errores.append(f"el paso 'Instalar jq' no fija JQ_VERSION: {JQ_VERSION}")
    # Cada sha en la rama de SU arquitectura, en codigo (no en un comentario).
    for arch, sha in JQ_SHA.items():
        rama = [l for l in paso_lineas if re.search(JQ_ARCH_UNAME[arch], codigo(l))]
        if not rama or f"arch={arch};" not in codigo(rama[0]) or f"sha={sha}" not in codigo(rama[0]):
            errores.append(f"el paso 'Instalar jq' no liga {arch} con su sha256 en la rama de uname")
    a_path = [l for l in paso_lineas if re.search(r"GITHUB_PATH", codigo(l))]
    if len(a_path) != 1 or not re.match(r'^\s*echo "\$dir" >> "\$GITHUB_PATH"\s*$', a_path[0]):
        errores.append("el paso 'Instalar jq' debe poner SOLO su directorio en $GITHUB_PATH (una linea)")
    if any(re.match(r"^        (if|continue-on-error):", l) for l in paso_lineas):
        errores.append("el paso 'Instalar jq' lleva if:/continue-on-error (el gate usaria otro jq)")
    if not re.search(r"urlopen\([^)]*timeout=", paso):
        errores.append("la descarga de jq no lleva timeout")

    # El heredoc de python, tal cual lo ejecutaria el runner (el bloque YAML ya dedentado).
    m = re.search(r"<<'PY'\n(.*?)\n\s*PY\s*$", paso, flags=re.S | re.M)
    if not m:
        return errores + ["el paso 'Instalar jq' no tiene el heredoc <<'PY' de descarga"]
    src = textwrap.dedent(m.group(1))
    errores += ejecuta_descarga(src)
    return errores


def ejecuta_descarga(src):
    """Corre el python de descarga con urlopen simulado: con sha correcto escribe un ejecutable;
    con sha incorrecto TIENE que abortar sin dejar el binario; pide la URL oficial."""
    errores = []
    contenido = b"#!/bin/sh\necho jq-falso\n"
    bueno = hashlib.sha256(contenido).hexdigest()
    pedidas = []

    class Resp:
        def read(self):
            return contenido

    def urlopen_falso(url, *a, **k):
        pedidas.append(url if isinstance(url, str) else url.full_url)
        return Resp()

    def corre(sha, dest):
        orig_urlopen, orig_argv = urllib.request.urlopen, sys.argv
        urllib.request.urlopen = urlopen_falso
        sys.argv = ["-", JQ_VERSION, "amd64", sha, dest]
        try:
            exec(compile(src, "<paso-jq>", "exec"), {"__name__": "__main__"})
            return None
        except SystemExit as e:
            return e.code if e.code is not None else 0
        finally:
            urllib.request.urlopen, sys.argv = orig_urlopen, orig_argv

    with tempfile.TemporaryDirectory() as d:
        dest = os.path.join(d, "jq")
        rc = corre(bueno, dest)
        if rc not in (None, 0) or not os.path.isfile(dest):
            errores.append(f"con sha256 correcto la descarga no deja el binario (salida={rc!r})")
        elif not os.access(dest, os.X_OK):
            errores.append("con sha256 correcto el binario queda sin permiso de ejecucion")
        dest2 = os.path.join(d, "jq2")
        rc = corre("0" * 64, dest2)
        if rc in (None, 0):
            errores.append("con sha256 INCORRECTO la descarga NO aborta (no verifica el checksum)")
        if os.path.exists(dest2):
            errores.append("con sha256 INCORRECTO queda un binario escrito")
    esperada = f"{JQ_URL_PREFIJO}{JQ_VERSION}/jq-linux-amd64"
    if not pedidas or any(u != esperada for u in pedidas):
        errores.append(f"la descarga no pide (solo) la URL oficial {esperada}: {pedidas}")

    # Reintentos ante red: un corte a mitad (IncompleteRead, que NO es OSError) y luego exito
    # tiene que terminar bien; tres fallos seguidos, abortar sin binario. time.sleep se anula.
    import http.client, time as _time
    def con_fallos(fallos):
        cola = list(fallos)
        def u(url, *a, **k):
            if cola:
                raise cola.pop(0)
            return Resp()
        return u
    orig_sleep = _time.sleep
    _time.sleep = lambda s: None
    try:
        for etiqueta, fallos, debe_ok in (
                ("corte a mitad y luego exito", [http.client.IncompleteRead(b"x")], True),
                ("timeout y luego exito", [TimeoutError("t")], True),
                ("tres fallos de red", [OSError("a"), OSError("b"), OSError("c")], False)):
            orig_urlopen, orig_argv = urllib.request.urlopen, sys.argv
            with tempfile.TemporaryDirectory() as d:
                dest = os.path.join(d, "jq")
                urllib.request.urlopen = con_fallos(fallos)
                sys.argv = ["-", JQ_VERSION, "amd64", bueno, dest]
                try:
                    exec(compile(src, "<paso-jq>", "exec"), {"__name__": "__main__"})
                    rc = 0
                except SystemExit as e:
                    rc = e.code if e.code is not None else 0
                except Exception as e:  # una excepcion sin capturar = sin reintento
                    rc = f"excepcion {type(e).__name__}"
                finally:
                    urllib.request.urlopen, sys.argv = orig_urlopen, orig_argv
                ok = rc == 0 and os.path.isfile(dest)
                if ok != debe_ok or (not debe_ok and (rc == 0 or os.listdir(d))):
                    errores.append(f"reintentos: '{etiqueta}' dio rc={rc!r}, archivos={os.listdir(d)}")
    finally:
        _time.sleep = orig_sleep
    return errores


fallos = 0
total = 0


def afirma(cond, ok, ko):
    global fallos, total
    total += 1
    if cond:
        print(f"  ✅ {ok}")
    else:
        print(f"  🔴 {ko}")
        fallos += 1


for nombre in RECETAS:
    ruta = RAIZ / ".github" / "workflows" / nombre
    texto = ruta.read_text(encoding="utf-8")
    print(f"== {nombre} ==")
    errs = revisa(texto)
    afirma(not errs, "cumple el contrato runs-on", "NO cumple:\n      - " + "\n      - ".join(errs))
    conducta = ejecuta_requisitos(texto, nombre)
    afirma(not conducta, "requisitos: alojado no exige nada; propio exige la imagen y falla cerrado",
           "requisitos NO se comportan:\n      - " + "\n      - ".join(conducta))
    if errs or conducta:
        continue  # los mutantes solo significan algo sobre una receta que cumple

    def detecta(mut):
        return bool(revisa(mut) or ejecuta_requisitos(mut, nombre))

    mutantes = {
        "runs-on: ubuntu-latest literal en el job":
            texto.replace("runs-on: " + RUNS_ON_ESPERADO, "runs-on: ubuntu-latest", 1),
        "default cambiado a ubuntu-22.04":
            texto.replace("""default: '"ubuntu-latest"'""", """default: '"ubuntu-22.04"'""", 1),
        "fallback `||` quitado de la expresion":
            texto.replace(""" || '"ubuntu-latest"'""", "", 1),
        "job extra con runs-on literal":
            texto.rstrip("\n").replace("\njobs:\n",
                "\njobs:\n  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - name: \"🧰 Requisitos del runner\"\n        run: true\n", 1) + "\n",
        "required: false quitado":
            re.sub(r"(\n      runs-on:\n(?:        .*\n)*?)        required: false\n", r"\1", texto, count=1),
        "paso de requisitos movido de primero":
            re.sub(r"      - name: \"?🧰 Requisitos del runner.*?(?=\n      - name:)", "", texto, count=1, flags=re.S),
    }
    mutantes["job en linea con runs-on literal"] = texto.replace(
        "\njobs:\n", "\njobs:\n  extra: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}\n", 1)
    req_nombre = '      - name: "🧰 Requisitos del runner"\n'
    mutantes.update({
        "requisitos con if: false": texto.replace(req_nombre, req_nombre + "        if: false\n", 1),
        "requisitos con continue-on-error": texto.replace(req_nombre, req_nombre + "        continue-on-error: true\n", 1),
        "requisitos con exit 0 al inicio": texto.replace(
            '        run: |\n          falta=""\n', '        run: |\n          exit 0\n          falta=""\n', 1),
        "jq empty usado sin instalar": texto.replace(
            "      - name: Checkout\n", "      - name: Checkout\n        run: jq empty f.json\n", 1),
    })
    # Falla cerrado (6): «runner propio que vuelve a llamar setup-* en modo descarga» y «se pierde
    # el comportamiento alojado», en todas sus formas razonables.
    for accion in SETUP_ACTIONS:
        if accion not in texto:
            continue
        corto = accion.split("/")[1].rstrip("@")
        con_if = f"        {IF_ALOJADO}\n        uses: {accion}"
        mutantes.update({
            f"{corto} sin if (runner propio descarga)": texto.replace(con_if, f"        uses: {accion}", 1),
            f"{corto} con if permisivo (!= 'false')": texto.replace(
                con_if, con_if.replace("== 'true'", "!= 'false'"), 1),
            f"{corto} con if por runner.environment": texto.replace(
                con_if, f"        if: runner.environment != 'self-hosted'\n        uses: {accion}", 1),
            f"{corto} con if: always()": texto.replace(
                con_if, f"        if: always()\n        uses: {accion}", 1),
        })
    mutantes.update({
        "modo alojado perdido (siempre propio)": texto.replace(
            """'"ubuntu-latest"') alojado=true ;;""", """'"ubuntu-latest"') alojado=false ;;""", 1),
        "modo propio perdido (siempre alojado)": texto.replace("          alojado=false\n", "          alojado=true\n", 1),
        "modo ignora el input runs-on": texto.replace(
            """case "$RUNS_ON_INPUT" in ''|'"ubuntu-latest"') alojado=true ;; esac""", "alojado=true", 1),
        "modo ignora runner.environment": texto.replace(
            'if [ "$RUNNER_ENV" = "github-hosted" ]; then', "if true; then", 1),
        "RUNNER_ENV desde otra fuente": texto.replace(
            "RUNNER_ENV: ${{ runner.environment }}", "RUNNER_ENV: github-hosted", 1),
        "requisitos sin id: runner": texto.replace("        id: runner\n", "        id: reqs\n", 1),
        "sin chequeo de python3 en propio": re.sub(r"\n *py=\$\(python3 [^\n]*", "\n          py=3.12.3", texto, count=1),
        "Python del runner con pip install --upgrade pip": texto.replace(
            '          "$venv/bin/python" -I -m pip --version\n',
            '          "$venv/bin/python" -I -m pip --version\n          "$venv/bin/python" -I -m pip install --upgrade pip\n', 1),
        "Python del runner borrado": re.sub(
            r"      - name: Python del runner.*?(?=\n      - name:)", "", texto, count=1, flags=re.S),
        "Python del runner sin if (pisa el python alojado)": texto.replace(f"        {IF_PROPIO}\n", "", 1),
    })
    # Ronda 1 de refutacion: las formas que sobrevivian, y las de H3/H4/H1.
    paso_extra = lambda cuerpo: texto.replace(
        "      - name: Checkout\n", f"      - name: extra\n{cuerpo}\n\n      - name: Checkout\n", 1)
    instalar = ("          /tmp/venv-semgrep/bin/pip install" if "venv-semgrep" in texto
                else "        run: pip install --require-hashes")
    mutantes.update({
        "uses en mayusculas sin if (Actions/Setup-Python)": texto.replace(
            f"        {IF_ALOJADO}\n        uses: actions/setup-python@", "        uses: Actions/Setup-Python@", 1),
        "pip install --upgrade pip antes del tooling": texto.replace(
            instalar, instalar.replace("pip install", "pip install --upgrade pip && pip install"), 1),
        "pip install -U pip antes del tooling": texto.replace(
            instalar, instalar.replace("pip install", "pip install -U pip && pip install"), 1),
        "venv con --upgrade-deps": texto.replace('python3 -I -m venv --clear "$venv"', 'python3 -I -m venv --clear --upgrade-deps "$venv"', 1),
        "venv sin --clear": texto.replace('python3 -I -m venv --clear "$venv"', 'python3 -I -m venv "$venv"', 1),
        "paso nuevo con curl | bash": paso_extra("        run: curl -fsSL https://example.com/install.sh | bash"),
        "paso nuevo con wget": paso_extra("        run: wget -q https://example.com/x"),
        "paso nuevo uses: astral-sh/setup-uv": paso_extra("        uses: astral-sh/setup-uv@v6"),
        "paso nuevo con urlopen": paso_extra("        run: python -c 'import urllib.request as u; u.urlopen(\"https://x\")'"),
        "setup-python cambia python-version (alojado)": re.sub(
            r"(uses: actions/setup-python@[^\n]*\n        with:\n          python-version: )[^\n]*", r"\g<1>'3.11'", texto, count=1),
    })
    # Ronda 2 de refutacion: las 34 formas que sobrevivian, agrupadas por regla.
    mutantes.update({
        "requisitos: asignacion de python3 sin `|| py=` (sh -e corta sin mensaje)": texto.replace(
            ' 2>/dev/null) || py=""\n', " 2>/dev/null)\n", 1),
        "venv sin -I (modulo venv del repo del caller)": texto.replace(
            'python3 -I -m venv --clear "$venv"', 'python3 -m venv --clear "$venv"', 1),
        "pip --version sin -I": texto.replace('"$venv/bin/python" -I -m pip --version', '"$venv/bin/python" -m pip --version', 1),
        "Python del runner instala pip==25.0": texto.replace(
            '          "$venv/bin/python" -I -m pip --version\n',
            '          "$venv/bin/python" -I -m pip --version\n          "$venv/bin/pip" install pip==25.0\n', 1),
        "Python del runner con --system-site-packages": texto.replace(
            'python3 -I -m venv --clear "$venv"', 'python3 -I -m venv --clear --system-site-packages "$venv"', 1),
        "Python del runner sin mensaje al README si venv falla": re.sub(
            r'( *python3 -I -m venv --clear "\$venv") \|\| \{[^\n]*\}', r"\1", texto, count=1),
        "GITHUB_PATH extra": texto.replace(
            '          echo "$venv/bin" >> "$GITHUB_PATH"\n',
            '          echo "$venv/bin" >> "$GITHUB_PATH"\n          echo "$HOME/.local/bin" >> "$GITHUB_PATH"\n', 1),
        "GITHUB_PATH del venv neutralizado": texto.replace(
            '          echo "$venv/bin" >> "$GITHUB_PATH"\n', '          true || echo "$venv/bin" >> "$GITHUB_PATH"\n', 1),
        "paso nuevo urlretrieve + sh": paso_extra(
            "        run: python3 -I -c 'import urllib.request as u; u.urlretrieve(\"https://x/i.sh\", \"/tmp/i.sh\")' && sh /tmp/i.sh"),
        "paso nuevo npx": paso_extra("        run: npx -y pkg@latest"),
        "paso nuevo git clone": paso_extra("        run: git clone https://example.com/x /tmp/x"),
        "paso nuevo npm install -g": paso_extra("        run: npm install -g npm@latest"),
        "paso nuevo composer self-update": paso_extra("        run: composer self-update"),
        "paso nuevo composer install": paso_extra("        run: composer install --no-interaction"),
        "setup-python con check-latest (alojado descarga)": re.sub(
            r"(uses: actions/setup-python@[^\n]*\n        with:\n)", r"\1          check-latest: true\n", texto, count=1),
        "modo: RUNNER_ENV != self-hosted (vacio = alojado)": texto.replace(
            'if [ "$RUNNER_ENV" = "github-hosted" ]; then', 'if [ "$RUNNER_ENV" != "self-hosted" ]; then', 1),
        "version_ok sin el punto (2 acepta 24)": texto.replace('case "$1." in "$p".*)', 'case "$1." in "$p"*)', 1),
    })
    # Gatekeeper (ronda 3): las variantes que sobrevivian.
    mutantes.update({
        "requisitos sin la linea 'Modo RUNNER PROPIO'": re.sub(
            r'\n *\[ "\$alojado" = true \] \|\| echo "Modo RUNNER PROPIO[^\n]*', "", texto, count=1),
        "paso nuevo pipx run": paso_extra("        run: pipx run cowsay"),
        "paso nuevo uvx": paso_extra("        run: uvx ruff"),
        "paso nuevo npm exec": paso_extra("        run: npm exec --yes pkg"),
        "paso nuevo ./script del repo": paso_extra("        run: ./scripts/install"),
        "paso nuevo '. archivo'": paso_extra("        run: . /tmp/i.sh"),
    })
    # Gatekeeper (ronda 4): sinonimos que esquivaban las reglas por regex. La allowlist (6h) los
    # mata por construccion; estos mutantes lo demuestran.
    mutantes.update({
        "paso nuevo bash scripts/install": paso_extra("        run: bash scripts/install"),
        "paso nuevo sh -c $(cat x)": paso_extra('        run: sh -c "$(cat x)"'),
        "paso nuevo if ./x": paso_extra("        run: if ./x; then :; fi"),
    })
    if 'python -I - "$JQ_VERSION"' in texto:
        mutantes["heredoc de jq con -u en vez de -I"] = texto.replace('python -I - "$JQ_VERSION"', 'python -u - "$JQ_VERSION"', 1)
        mutantes["heredoc de jq sin guion"] = texto.replace(
            'python -I - "$JQ_VERSION" "$arch" "$sha" "$dir/jq" <<\'PY\'', "python <<'PY'", 1)
    if "venv-semgrep" in texto:
        mutantes.update({
            "venv del tooling con -s": texto.replace("python -I -m venv --clear /tmp/venv-semgrep", "python -s -m venv --clear /tmp/venv-semgrep", 1),
            "ALOJADO reasignado en el paso pip-audit": texto.replace(
                "          SIN_PIP=()\n", "          ALOJADO=true\n          SIN_PIP=()\n", 1),
            "pip-audit por ruta absoluta": texto.replace(
                "          rc_total=0\n", "          rc_total=0\n          /tmp/venv-pipaudit/bin/pip-audit -r requirements.txt || true\n", 1),
            "pip_audit como modulo": texto.replace(
                "          rc_total=0\n", "          rc_total=0\n          python -I -m pip_audit -r requirements.txt || true\n", 1),
            "pip-audit via command -v": texto.replace(
                "          rc_total=0\n", '          rc_total=0\n          "$(command -v pip-audit)" -r requirements.txt || true\n', 1),
            "unset por indireccion": texto.replace(
                '          for f in "${reqfiles[@]}"; do\n', '          for f in "${reqfiles[@]}"; do\n            unset "${!SIN_@}"\n', 1),
        })
    if "composer audit" in texto:
        mutantes["ALOJADO reasignado en composer audit"] = texto.replace(
            "          SIN_PLUGINS=()\n", "          ALOJADO=true\n          SIN_PLUGINS=()\n", 1)
    if 'python -I - "$JQ_VERSION"' in texto:
        mutantes["heredoc de jq sin -I (hashlib del caller)"] = texto.replace(
            'python -I - "$JQ_VERSION"', 'python - "$JQ_VERSION"', 1)
    if "venv-semgrep" in texto:
        mutantes["unset SIN_PIP dentro del for"] = texto.replace(
            '          for f in "${reqfiles[@]}"; do\n', '          for f in "${reqfiles[@]}"; do\n            unset SIN_PIP\n', 1)
        mutantes["if pip-audit directo"] = texto.replace(
            "          rc_total=0\n", "          rc_total=0\n          if pip-audit -r requirements.txt; then :; fi\n", 1)
    if "composer audit" in texto:
        mutantes["unset SIN_PLUGINS"] = texto.replace(
            '          composer "${SIN_PLUGINS[@]}" audit', '          unset SIN_PLUGINS\n          composer "${SIN_PLUGINS[@]}" audit', 1)
    if "npm ci --ignore-scripts" in texto:
        mutantes["npm ci sin --ignore-scripts"] = texto.replace("npm ci --ignore-scripts", "npm ci", 1)
    if "venv-semgrep" in texto:
        mutantes.update({
            "venv del tooling sin -I": texto.replace("python -I -m venv --clear /tmp/venv-semgrep", "python -m venv --clear /tmp/venv-semgrep", 1),
            "SIN_PIP reseteado tras la condicion": texto.replace(
                '          [ "$ALOJADO" = true ] || SIN_PIP=(--disable-pip)\n',
                '          [ "$ALOJADO" = true ] || SIN_PIP=(--disable-pip)\n          SIN_PIP=()\n', 1),
            "pip-audit directo fuera de audit_source": texto.replace(
                "          rc_total=0\n", "          rc_total=0\n          pip-audit -r requirements.txt || true\n", 1),
            "pylock sin --locked": texto.replace('audit_source "pylock.toml" --locked --strict', 'audit_source "pylock.toml" --strict .', 1),
        })
    if "composer audit" in texto:
        mutantes.update({
            "composer audit sin SIN_PLUGINS": texto.replace('composer "${SIN_PLUGINS[@]}" audit', "composer audit", 1),
            "SIN_PLUGINS con condicion invertida": texto.replace(
                '[ "$ALOJADO" = true ] || SIN_PLUGINS=', '[ "$ALOJADO" = true ] && SIN_PLUGINS=', 1),
            "SIN_PLUGINS reseteado": texto.replace(
                '          [ "$ALOJADO" = true ] || SIN_PLUGINS=(--no-plugins --no-scripts)\n',
                '          [ "$ALOJADO" = true ] || SIN_PLUGINS=(--no-plugins --no-scripts)\n          SIN_PLUGINS=()\n', 1),
            "composer --version de requisitos con plugins": texto.replace(
                "composer --no-plugins --no-scripts --no-interaction --version", "composer --no-interaction --version", 1),
            "setup-php con extensions extra (alojado)": texto.replace(
                "          tools: composer:2\n", "          tools: composer:2\n          extensions: intl\n", 1),
        })
    if "actions/setup-node@" in texto:
        mutantes["setup-node con check-latest (alojado descarga)"] = texto.replace(
            "          node-version: ${{ inputs.node-version }}\n",
            "          node-version: ${{ inputs.node-version }}\n          check-latest: true\n", 1)
        mutantes["setup-node pierde node-version del input (alojado)"] = texto.replace(
            "node-version: ${{ inputs.node-version }}\n", "node-version: '24'\n", 1)
    if "shivammathur/setup-php@" in texto:
        mutantes["setup-php sin tools: composer:2 (alojado)"] = texto.replace("          tools: composer:2\n", "", 1)
    if "venv-semgrep" in texto:
        mutantes["venv del tooling sin --clear"] = texto.replace(
            "python -I -m venv --clear /tmp/venv-semgrep", "python -I -m venv /tmp/venv-semgrep", 1)
        mutantes["pip-audit -r sin SIN_PIP"] = texto.replace(' "${SIN_PIP[@]}" -r "$f"', ' -r "$f"', 1)
        mutantes["pip-audit SIN_PIP con condicion invertida"] = texto.replace(
            '[ "$ALOJADO" = true ] || SIN_PIP=(--disable-pip)', '[ "$ALOJADO" = true ] && SIN_PIP=(--disable-pip)', 1)
        mutantes["pip-audit ALOJADO de otra fuente"] = texto.replace(
            "ALOJADO: ${{ steps.runner.outputs.alojado }}", "ALOJADO: 'true'", 1)
    if "php" in PROPIO[nombre]:
        mutantes["sin chequeo de php en propio"] = re.sub(r"\n *phpv=\$\(php [^\n]*", "\n          phpv=8.3.6", texto, count=1)
        mutantes["sin chequeo de composer en propio"] = re.sub(r"\n *cv=\$\(composer [^\n]*", "\n          cv=2", texto, count=1)
    if "node" in PROPIO[nombre]:
        mutantes["sin chequeo de node en propio"] = re.sub(r"\n *nv=\$\(node [^\n]*", "\n          nv=20.11.1", texto, count=1)
    if "Instalar jq" in texto:
        a, b = JQ_SHA["amd64"], JQ_SHA["arm64"]
        mutantes.update({
            "paso 'Instalar jq' borrado": re.sub(
                r"      - name: [^\n]*Instalar jq.*?(?=\n      - name:)", "", texto, count=1, flags=re.S),
            "sha256 amd64 de jq alterado": texto.replace(a, "0" * 64, 1),
            "comparacion del sha256 quitada": re.sub(
                r"\n( *)if got != sha:\n\1    sys\.exit\([^\n]*\)", "", texto, count=1),
            "sha256 de amd64 y arm64 intercambiados": texto.replace(a, "@@A@@").replace(b, a).replace("@@A@@", b),
            "GITHUB_PATH quitado": re.sub(r'\n *echo "\$dir" >> "\$GITHUB_PATH"', "", texto, count=1),
            "URL a otro host": texto.replace("https://github.com/jqlang/jq/", "https://evil.example/jqlang/jq/", 1),
            'jq "..." antes de instalarlo': texto.replace(
                "      - name: Checkout\n", '      - name: Checkout\n        run: jq ".x" f.json\n', 1),
            "sha valido solo en comentario": texto.replace(
                f"sha={a} ;;", f"sha={'1' * 64} ;; # {a}", 1),
            "version de jq cambiada": texto.replace(f"JQ_VERSION: {JQ_VERSION}", "JQ_VERSION: jq-1.7.1", 1),
            "Instalar jq con if: solo self-hosted": re.sub(
                r"(      - name: Instalar jq[^\n]*\n)", r"\1        if: runner.environment == 'self-hosted'\n", texto, count=1),
            "Instalar jq con continue-on-error": re.sub(
                r"(      - name: Instalar jq[^\n]*\n)", r"\1        continue-on-error: true\n", texto, count=1),
            "/usr/bin antepuesto tras el pin": texto.replace(
                '          echo "$dir" >> "$GITHUB_PATH"\n',
                '          echo "$dir" >> "$GITHUB_PATH"\n          echo /usr/bin >> "$GITHUB_PATH"\n', 1),
            "urlopen sin timeout": texto.replace("urlopen(url, timeout=60)", "urlopen(url)", 1),
            "reintento sin HTTPException": texto.replace(
                "(urllib.error.URLError, http.client.HTTPException, OSError)", "(urllib.error.URLError, OSError)", 1),
            "sin reintentos": texto.replace("for intento in (1, 2, 3):", "for intento in (3,):", 1),
        })
    for etiqueta, mut in mutantes.items():
        afirma(mut != texto and detecta(mut),
               f"mutante detectado: {etiqueta}",
               f"mutante SOBREVIVE (o no se pudo aplicar): {etiqueta}")

# El selftest corre las decisiones de jq (tests/expect-audit-decision.sh) con el MISMO jq que fijan
# las recetas: si el pin sube en las recetas y no ahi, se probaria un jq que nadie usa.
print("== selftest.yml ==")
def revisa_selftest(st):
    sl = st.splitlines()
    i, f = bloque_paso(sl, r"Decisiones de jq con el jq que fijan las recetas")
    if i is None:
        return ["falta el paso 'Decisiones de jq con el jq que fijan las recetas'"]
    while f > i and (not sl[f - 1].strip() or sl[f - 1].lstrip().startswith("#")):
        f -= 1  # los comentarios que preceden al paso siguiente no son de este paso
    paso = "\n".join(sl[i:f])
    errs = []
    for need, msg in ((f"JQ_VERSION: {JQ_VERSION}", f"no fija {JQ_VERSION}"),
                      (f"JQ_SHA256: {JQ_SHA['amd64']}", "no fija el sha256 amd64 de las recetas"),
                      ("sha256sum -c -", "no verifica el sha256"),
                      ('export PATH="$dir:$PATH"', "no antepone el jq fijado al PATH"),
                      ('[ "$(jq --version)" = "$JQ_VERSION" ]', "no comprueba que el jq en PATH es el fijado")):
        if need not in paso:
            errs.append(msg)
    if any(re.match(r"^        (if|continue-on-error):", l) for l in sl[i:f]):
        errs.append("lleva if:/continue-on-error")
    if not re.search(r"\n\s*bash tests/expect-audit-decision\.sh\s*$", paso):
        errs.append("no termina corriendo tests/expect-audit-decision.sh")
    return errs


st = (RAIZ / ".github" / "workflows" / "selftest.yml").read_text(encoding="utf-8")
e = revisa_selftest(st)
afirma(not e, f"corre las decisiones de jq con el jq fijado ({JQ_VERSION})",
       "selftest NO prueba con el jq fijado:\n      - " + "\n      - ".join(e))
if not e:
    for etiqueta, mut in {
        "selftest sin export PATH": st.replace('          export PATH="$dir:$PATH"\n', "", 1),
        "selftest sin sha256sum -c": st.replace('          echo "${JQ_SHA256}  $dir/jq" | sha256sum -c -\n', "", 1),
        "selftest con continue-on-error": st.replace(
            "      - name: Decisiones de jq con el jq que fijan las recetas\n",
            "      - name: Decisiones de jq con el jq que fijan las recetas\n        continue-on-error: true\n", 1),
    }.items():
        afirma(mut != st and revisa_selftest(mut), f"mutante detectado: {etiqueta}",
               f"mutante SOBREVIVE (o no se pudo aplicar): {etiqueta}")

print()
print(f"✅ {total} afirmaciones" if fallos == 0 else f"🔴 {fallos} de {total} fallaron")
sys.exit(0 if fallos == 0 else 1)
