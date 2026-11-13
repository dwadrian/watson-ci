# watson-ci

Recetas de CI **reutilizables** para la flota de proyectos. Un solo lugar, sin drift.

Este repo contiene **solo workflows** (`workflow_call`) — **ningún código de aplicación,
ningún secreto**. Es público para que cualquier repo (bajo cualquier owner) pueda referenciarlo.

## Qué hace cada receta

Ambas corren la **capa stack-agnóstica de seguridad** (no necesita DB ni servicios):

| Paso | php | node | python | Bloquea |
|------|:---:|:----:|:------:|---------|
| Secrets scan (Semgrep `p/secrets`) | ✅ | ✅ | ✅ | **siempre** |
| SAST ERROR **diff-aware** (vs baseline) | ✅ | ✅ | ✅ | hallazgos **nuevos**; la deuda vieja no rompe |
| SAST en rama gateada (`main`/`master`/`*_prod`) | ✅ | ✅ | ✅ | full-estricto, salvo `strict-on-gated: false` |
| SAST medio/bajo | advisory | advisory | advisory | nunca |
| Dependencias high/critical | ✅ | ✅ | ✅ | **siempre** |
| Advisory **sin campo `severity`** | ✅ | — | — | **v3: SÍ bloquea** (v2 daba verde) |
| Proyecto Python **sin lockfile auditable** | — | — | ✅ | **v3: SÍ bloquea** (v2 hacía `exit 0`) |

> El input `blocking` **ya no existe** (se eliminó en v2). Secrets siempre bloquea, deps siempre
> high/critical, SAST es diff-aware. Un caller que lo pase falla al arrancar con "input desconocido".

Los **tests con DB/servicios** NO van aquí — son project-specific y viven en el workflow
propio de cada repo (ej. el `no-mock` job de coffee con su MariaDB).

## Cómo usarla (caller-stub, ~8 líneas)

En cada repo, `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main, master]   # ajustar a la rama default del repo
  pull_request:
jobs:
  verify:
    uses: dwadrian/watson-ci/.github/workflows/verify-php.yml@v3
    with:
      php-version: '8.3'
      # audit-allow-cve: 'CVE-2024-1234'   # opcional: exime advisories SIN severidad, por id
```

Node:

```yaml
jobs:
  verify:
    uses: dwadrian/watson-ci/.github/workflows/verify-node.yml@v3
    with:
      node-version: '20'
      # test-command: 'node --test'   # opcional. NUNCA metas ${{ }} de datos de evento aquí:
      #   se ejecuta como shell. Del caller a su propio job no es escalada (quien edita ese YAML
      #   ya puede ejecutar lo que quiera), pero interpolar un título de PR sí lo convierte en RCE.
```

## Checkout Python completo (issue #2537 del caller)

`verify-python.yml` conserva el checkout en la raíz del caller con `fetch-depth: 0`,
pero sin `filter: blob:none`: descarga también los blobs históricos mientras checkout
tiene autenticación temporal. `persist-credentials: false` se mantiene. Así no deja
un promisor en el workspace compartido por los siguientes jobs del runner.
No se mueve el código a un subdirectorio: se conservan exactamente el alcance de
`alcance.sh`, `.semgrepignore`, los comandos de Semgrep y su baseline, la limpieza
de `.watson-ci-tooling` y la búsqueda de lockfiles de pip-audit, sin cambiar su estrictez.
El coste es transferir los blobs históricos, no solo el grafo de commits.

Quitar el filtro no convierte un clon parcial existente en completo. La receta
falla explícitamente si cualquiera de `remote.origin.promisor` o
`remote.origin.partialclonefilter` está definido (incluso vacío o `false`), o si
no puede consultar la configuración. No hace refetch ni elimina configuración.
Para un workspace ya contaminado, retirar el runner, esperar a que no tenga jobs
y recrear ese workspace con un clon completo antes de reintentar; no borrarlo en uso.
La regresión local y en selftest es `python3 -I tests/checkout-completo.test.py`.

## Runner propio (input `runs-on`)

Todo job de las tres recetas elige su runner con el input `runs-on` (JSON). Sin pasarlo, corre en
`ubuntu-latest` como siempre. Con runners propios (fabrica#2425: al agotarse el tope de gasto de
Actions, el job `seguridad` de makro_web no podía correr y `ci-ok` quedaba en rojo):

```yaml
jobs:
  seguridad:
    uses: dwadrian/watson-ci/.github/workflows/verify-node.yml@<sha-40>
    with:
      runs-on: ${{ vars.RUNS_ON }}     # p. ej. ["self-hosted","makro-web"]
      tooling-ref: <sha-40>            # el MISMO sha que el `uses:`
```

Si `vars.RUNS_ON` no está definida llega `''`, y la receta lo trata como `"ubuntu-latest"`: el
default de un input **no** se aplica a un valor pasado vacío, así que sin ese fallback `fromJSON('')`
rompería el job.

El valor es **JSON**, no una etiqueta suelta: `'"ubuntu-latest"'` o `'["self-hosted","makro-web"]'`.
Escribir `runs-on: ubuntu-latest` (sin las comillas de JSON) hace fallar el job al arrancar; falla
con ruido, no en silencio, pero es la trampa obvia porque el input se llama igual que la clave.

### Qué tiene que traer el runner

**En un runner propio la receta no descarga intérpretes: falla cerrada.** `setup-python`,
`setup-node` y `shivammathur/setup-php` solo corren en un runner **alojado** de GitHub con el
`runs-on` por defecto (`''` o `"ubuntu-latest"`). Ahí la imagen ya trae las versiones y el
comportamiento no cambia. En cualquier otro caso (`runner.environment` distinto de `github-hosted`,
**o** un `runs-on` distinto del default) no se llaman. La razón: sin la versión ya instalada,
descargan y ejecutan código **sin checksum**. `setup-php` baja un `install.sh` de
`releases/latest` (con alternativas en `@main`): fijar el SHA de la action no fija ese código
transitivo. `setup-python` baja y ejecuta un `setup.sh` y luego hace
`pip install --upgrade pip` sin versión ni hashes. `setup-node` baja el tarball de Node. Por eso
**la imagen del runner tiene que traer los intérpretes** en la versión que pide la receta.

El primer paso de cada job (`🧰 Requisitos del runner`) decide el modo y comprueba las filas marcadas
**(c)**. Si falta algo, falla con la lista y remite aquí, en vez de dejar que un paso posterior se
rompa (o, peor, que se degrade en silencio). Las filas sin **(c)** no las comprueba la receta: si
faltan, falla el paso que las usa.

#### Imagen de un runner propio — lista exacta

| Necesita | node | python | php | Por qué |
|---|:---:|:---:|:---:|---|
| **(c)** `git` ≥ 2.18 | ✅ | ✅ | ✅ | sin él `actions/checkout` baja por API **sin `.git`**: el merge-base sale vacío y el SAST pasaría a advisory |
| **(c)** `sh`, `bash` (≥ 4.4: los gates usan `set -u` con arrays que pueden ir vacíos; no se comprueba la versión), `grep`, `sed`, `cat`, `wc`, `tr`, `tar`, `gzip`, `uname` | ✅ | ✅ | ✅ | sistema base |
| **(c)** `find`, `sort`, `timeout` | — | ✅ | — | sistema base (gate de pip-audit) |
| **(c)** `python3` **3.12** con `venv`/`ensurepip` (Debian/Ubuntu: `python3.12` + `python3.12-venv`) | ✅ | ✅ (la de `python-version`, default 3.12) | ✅ | Semgrep (y pip-audit en python). La receta crea un venv con `python3 -m venv` en `$RUNNER_TEMP`. Así tiene `python`/`pip` en PATH sin tocar el Python del sistema (PEP 668). El **pip** es el que trae `ensurepip` con ese Python: no se descarga ni se actualiza. Semgrep/pip-audit se instalan dentro con `--require-hashes` |
| **(c)** `node` de la versión de `node-version` (el default es `20`; makro_web pide `24`) + `npm` | ✅ | — | — | `npm ci`/`npm audit` |
| **(c)** `php` de la versión de `php-version` (default `8.3`) + `composer` 2 | — | — | ✅ | `composer audit --locked`. En runner propio va con `--no-plugins --no-scripts`: sin eso, Composer carga los plugins de `vendor/composer/installed.json`, que viene del repo auditado |
| `ca-certificates` | ✅ | ✅ | ✅ | TLS de git, pip, npm, composer y la descarga de jq |
| Linux x86_64 o arm64 | ✅ | ✅ | ✅ | jq está fijado (sha256) solo para esas dos arquitecturas |
| Salida HTTPS a github.com y `api.github.com` (checkout), `objects.githubusercontent.com` y `release-assets.githubusercontent.com` (jq, redirección del release), pypi.org y `files.pythonhosted.org`, semgrep.dev; registry.npmjs.org (node); packagist.org (php) | ✅ | ✅ | ✅ | descargas fijadas, rulesets y paquetes |
| **Runner efímero** (un contenedor por job, `--ephemeral`) | ✅ | ✅ | ✅ | la receta usa rutas fijas (`/tmp/venv-*`, `$RUNNER_TEMP/watson-ci-python`). En un runner persistente compartido, un job anterior podría dejar plantado algo que el siguiente reutilice. No se comprueba |

No hace falta `sudo` ni `curl`: solo los usaba `setup-php`, que en un runner propio ya no corre.

**El runner de makro_web** (usa `verify-node`): `git` ≥ 2.18, las utilidades base, **node 24 + npm**,
**python3.12 con pip (`python3.12-venv`)** y `ca-certificates`. **PHP + composer 2 solo si el
runner también ejecuta `verify-php`.** `verify-python` pide lo mismo menos node, más `find`/`sort`/`timeout`.

Comprobar una imagen antes de registrarla (lo mismo que mira el paso de requisitos):

```sh
git --version                       # >= 2.18
python3 -I -c 'import sys, venv, ensurepip; print(sys.version)'   # 3.12.x, sin error de import
node --version && npm --version     # v24.x (verify-node)
php -r 'echo PHP_VERSION;' && composer --version   # 8.3.x y 2.x (verify-php)
```

Lo que **sí** instala siempre la receta, fijado: Semgrep y pip-audit (`--require-hashes`) y
**jq 1.8.2** (sha256 por arquitectura, 3 reintentos ante fallo de red). En un runner alojado, además,
Python (`setup-python`), Node (`setup-node`) y PHP (`setup-php`), igual que antes de este cambio: del
tool cache de la imagen de GitHub si la versión está ahí, y si no **los descargan** (p. ej.
`node-version: 24` o PHP 8.4). Ese camino alojado no se ha tocado y **no** está fijado por checksum.

En un runner propio, `verify-python` audita los `requirements*.txt` con `pip-audit --disable-pip`.
Ojo: `--no-deps` solo no basta, porque sin `--disable-pip` pip-audit crea un venv, actualiza pip sin
versión e instala los requirements. Con `--disable-pip` audita los pins sin instalar nada. Un
requisito sin `==` hace fallar el gate. En un runner alojado sigue como estaba.

Todo `python -m …` de las recetas va con `-I`. Sin él, Python busca el módulo primero en el
directorio actual, que tras el checkout es el repo del caller: un `venv/` o un `pip/` plantados ahí
se ejecutarían. Todo venv se crea con `--clear`. `tests/runs-on.test.sh` defiende estas reglas y la
conducta del paso de requisitos, que ejecuta con `sh -e` como Actions.

jq era la dependencia oculta: ubuntu-latest lo trae de serie y los gates de composer audit y
pip-audit deciden con él. Es 1.8.2 y no el 1.7.1 de ubuntu-24.04 porque el binario upstream 1.7.1 no
lleva los arreglos de CVE-2024-23337, CVE-2024-53427 y CVE-2025-48060 (ni los posteriores hasta
1.8.2; el paquete de Ubuntu puede llevarlos por backport). `selftest` repite con ese pin las
expresiones de decisión de composer audit; el conteo de pip-audit lo ejercita el job python.

Docker y gitleaks no hacen falta: los secretos los escanea Semgrep.

> **Seguridad del runner.** `runs-on` decide en qué máquina corre el gate, con el fuente del
> repo en disco. Un runner propio **no** debe ejecutar `pull_request` de forks en repos públicos
> (cualquiera podría correr código en él), y `vars.RUNS_ON` debe apuntar solo a runners del
> mismo dueño que el repo.

## Garantías de seguridad / costo (por qué no se dispara solo ni cobra de más)

- **`timeout-minutes: 15`** por job — tope duro, nada se va de largo.
- **`concurrency` + `cancel-in-progress`** — un push nuevo cancela el anterior; no se acumulan minutos.
- **No auto-loop:** un push hecho por `GITHUB_TOKEN` no re-dispara workflows (garantía nativa de Actions).
- **Actions pineadas por SHA** (no por tag móvil) — inmune a un tag repointeado maliciosamente.
- **Semgrep sin `--config auto`** (que hace lookup de red gated por login); se usan rulesets `p/...`.
- **`permissions: contents: read`** — mínimo; la receta solo lee código.
- **Fail-closed:** un fallo de herramienta (semgrep/composer/npm) hace RED, nunca verde-falso. El gate de deps decide por exit-code/JSON, no por parseo de texto humano.
- **`npm ci --ignore-scripts`** — no ejecuta lifecycle scripts de dependencias durante el audit.
- **Cuenta sin gasto por defecto:** repos privados = 2000 min/mes gratis; spending limit $0 = hard-stop, no hay cobro sorpresa.

## Riesgo aceptado (v1)

Los rulesets `p/...` de Semgrep se descargan del registry en cada corrida — **no están pineados
por versión/hash**, así que su contenido puede cambiar entre corridas y una caída del registry
hace fail-closed (RED) toda la flota. Aceptable para v1 (bus factor 1, prioridad = tener gate).
Mitigación futura: vendorizar los rulesets críticos en este repo (`--config ./rules/...`).

## Alias móviles: el criterio cambió

Hasta v2, `@vN` era un **alias móvil**: se re-apuntaba con `git push --force origin vN` y los
callers recibían el cambio sin tocar nada. Cómodo, y por eso mismo peligroso.

**Criterio desde v3:** cualquier cambio que pueda voltear **pass → fail** en código YA existente
va en un mayor nuevo, aunque sea aditivo en el YAML. El alias móvil queda para lo que de verdad
no altera veredictos (documentación, refactor interno, pines de actions a la misma versión).

`main` es desarrollo; no referenciar `@main` en producción. Cada movimiento de alias lleva su
**tag inmutable** — `v2` llegó a apuntar a un commit sin tag, que es lo que ejecutaban 11 repos.

### Nota de seguridad sobre el alias

Un tag **no** lo protege una branch protection rule: quien tenga `write` sobre este repo (o un
PAT comprometido de la cuenta) puede re-apuntarlo. Como 16 repos privados lo consumen —varios de
producción— **pinear por SHA en el caller es más seguro que `@vN`**, siempre que se acompañe de
Dependabot `github-actions`; sin él, el pin se congela y el repo deja de recibir arreglos (ya
pasó: un caller lleva desde 2026-07-17 sin recibir tres versiones).
