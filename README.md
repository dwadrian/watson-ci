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

El primer paso de cada job (`🧰 Requisitos del runner`) comprueba las filas marcadas **(c)** y falla
con la lista de lo que falte, en vez de dejar que un paso posterior se rompa (o, peor, que se degrade
en silencio). El resto son requisitos **no comprobados** por la receta: si faltan, falla el paso que
los usa.

| Necesita | node | python | php | Por qué no lo instala la receta |
|---|:---:|:---:|:---:|---|
| **(c)** `git` ≥ 2.18 | ✅ | ✅ | ✅ | sin él `actions/checkout` baja por API **sin `.git`**: el merge-base sale vacío y el SAST pasaría a advisory |
| **(c)** `sh`, `bash`, `grep`, `sed`, `cat`, `wc`, `tr`, `tar`, `gzip`, `uname` | ✅ | ✅ | ✅ | sistema base; `tar`/`gzip` los usan `setup-python`/`setup-node` para desempaquetar |
| **(c)** `find`, `sort`, `timeout` | — | ✅ | — | sistema base (gate de pip-audit) |
| **(c)** `curl` + **`sudo` sin contraseña** (o root con sudo permitido) | — | — | ✅ | `shivammathur/setup-php` usa `sudo` para todo; sin él se queda esperando un candado hasta el timeout (medido en ci-makro, 2026-09-26). En self-hosted instala PHP por apt (Ubuntu/Debian), cada run: cuenta minutos contra el `timeout-minutes: 15`. `sudo -n true` se comprueba siempre (en ubuntu-latest viene de serie) |
| `ca-certificates` | ✅ | ✅ | ✅ | TLS de git, pip y la descarga de jq |
| Linux x86_64 o arm64, **versión de Ubuntu de las que tiene GitHub** (runner-images), `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` escribible | ✅ | ✅ | ✅ | `setup-python`/`setup-node` bajan builds hechos para esas imágenes; en otra distro pueden no funcionar (doc de setup-python, «self-hosted runner») |
| Salida HTTPS a github.com, `api.github.com`, `raw.githubusercontent.com` (manifiestos de setup-python/setup-node), `objects.githubusercontent.com` y `release-assets.githubusercontent.com` (redirecciones de releases), pypi.org y `files.pythonhosted.org`, semgrep.dev; registry.npmjs.org y `nodejs.org` (node); packagist.org, los mirrors de apt y `ppa.launchpadcontent.net` (php) | ✅ | ✅ | ✅ | descargas fijadas, rulesets y paquetes |
| **Runner efímero** (un contenedor por job, `--ephemeral`) | ✅ | ✅ | ✅ | la receta usa rutas fijas (`/tmp/venv-*`) y hace `pip install` en el Python del tool cache. En un runner persistente compartido, un job anterior podría dejar plantado un paquete que `pip` dé por «ya instalado». No se comprueba |

Lo que **sí** instala la receta, fijado: Python (`setup-python`), Node (`setup-node`), Semgrep y
pip-audit (`--require-hashes`), y **jq 1.8.2** (sha256 por arquitectura, 3 reintentos ante fallo de
red). jq era la dependencia oculta: ubuntu-latest lo trae de serie y los gates de composer audit y
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
