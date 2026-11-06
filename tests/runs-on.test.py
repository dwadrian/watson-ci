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
        if "shivammathur/setup-php" in texto and not any(
                re.match(r"^\s*if ! sudo -n true", codigo(l)) for l in req):
            errores.append("receta con setup-php: el paso de requisitos no comprueba `sudo -n true` incondicional")

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
    if errs:
        continue  # los mutantes solo significan algo sobre una receta que cumple

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
            req_nombre + "        shell: sh\n        run: |\n",
            req_nombre + "        shell: sh\n        run: |\n          exit 0\n", 1),
        "jq empty usado sin instalar": texto.replace(
            "      - name: Checkout\n", "      - name: Checkout\n        run: jq empty f.json\n", 1),
    })
    if "sudo -n true" in texto:
        mutantes["chequeo de sudo condicionado a RUNNER_ENVIRONMENT"] = texto.replace(
            "if ! sudo -n true", 'if [ "${RUNNER_ENVIRONMENT:-}" = "self-hosted" ] && ! sudo -n true', 1)
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
        afirma(mut != texto and revisa(mut),
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
