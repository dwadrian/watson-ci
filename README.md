# watson-ci

Recetas de CI **reutilizables** para la flota de proyectos. Un solo lugar, sin drift.

Este repo contiene **solo workflows** (`workflow_call`) — **ningún código de aplicación,
ningún secreto**. Es público para que cualquier repo (bajo cualquier owner) pueda referenciarlo.

## Qué hace cada receta

Ambas corren la **capa stack-agnóstica de seguridad** (no necesita DB ni servicios):

| Paso | verify-php | verify-node | Bloquea |
|------|-----------|-------------|---------|
| Secrets scan (Semgrep `p/secrets`) | ✅ | ✅ | siempre |
| SAST high/critical (Semgrep security-audit + lang pack, `--severity ERROR`) | ✅ | ✅ | si `blocking: true` |
| SAST medio/bajo | advisory | advisory | nunca |
| Dependencias (`composer audit` / `npm audit`) | ✅ | ✅ | high/critical si `blocking: true` |

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
    uses: dwadrian/watson-ci/.github/workflows/verify-php.yml@v1
    with:
      php-version: '8.3'
      blocking: true            # false en repos dev/experimentales (advisory)
```

Node:

```yaml
jobs:
  verify:
    uses: dwadrian/watson-ci/.github/workflows/verify-node.yml@v1
    with:
      node-version: '20'
      blocking: true
      test-command: 'node --test'   # opcional
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

## Versionado

`@v1` es un **alias mayor móvil**: apunta siempre al último `v1.x` (bugfixes y features
retro-compatibles se publican re-apuntando `v1` a un commit nuevo). Los callers fijan `@v1` y
reciben fixes sin tocar nada. Un cambio **breaking** sale como `@v2` (los callers migran a mano).
`main` es desarrollo; no referenciar `@main` en producción.
