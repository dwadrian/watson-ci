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
