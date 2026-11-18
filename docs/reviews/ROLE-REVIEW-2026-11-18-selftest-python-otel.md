# ROLE-REVIEW — selftest python: CVE-2026-126360 de opentelemetry-api 1.37.0

> **Roles-Validated: GO** (decisión PROVISIONAL del operador, 2026-11-18, por delegación del dueño: «los bots deciden PROVISIONAL cuando el dueño no está»).
> Revisor independiente de otro contexto (Claude Opus, solo lectura, `--permission-mode plan`, mandato de REFUTAR) sobre `e02eec8`:
> **GO** para este cambio, con 3 menores (todos atendidos abajo). Ningún bloqueante.

## Qué cambia

El job `python / secrets + SAST + deps (Python)` estaba rojo en **todo** PR de watson-ci desde el 2026-11-12: pip-audit
reporta `CVE-2026-126360` (GHSA-mf5v-w3w3-f6cg, DoS por parseo cuadrático de `traceparent`) en `opentelemetry-api 1.37.0`,
fijado por `tools/requirements-semgrep.txt` (cierre de semgrep 1.184.0, con `--require-hashes`).

- **No hay parche utilizable.** El arreglo es `opentelemetry-api 1.45.2`, pero semgrep (incluida la 1.186.0, la última en PyPI
  el 2026-11-18) exige `opentelemetry-api~=1.37.0` y `mcp==1.29.0`. Ninguna versión anterior de semgrep escapa: el aviso dice
  «afecta desde 0 hasta 1.45.2». Forzar una versión incompatible (override de `uv`) rompe el contrato de semgrep y no se hace.
- **Se usa el mecanismo que ya existía**: la entrada `pip-audit-ignore-vuln` del selftest, una ID por una, sin interruptor
  global. Se añade `CVE-2026-126360` a las 5 ya declaradas. Solo aplica al autotest de watson-ci; ningún repo que llama
  hereda la lista (el input por defecto es vacío).
- **Fecha de revisión: 2026-12-02**, o antes en cuanto semgrep publique una versión que admita `mcp>=1.30.0` y
  `opentelemetry-api>=1.45.2`. Está en el comentario junto a la lista y en `docs/01_BACKLOG.md § Bloqueado`.
  Estas excepciones **no caducan solas** (`tools/audit-exceptions.sh` no está cableado a las recetas): la fecha la vigila una
  persona. Es un límite declarado, no nuevo.
- `tools/requirements-semgrep.txt`: solo cambia el comentario (el contenido no comentado es idéntico byte a byte).

Medido en local con pip-audit 2.10.1 (`--no-deps --strict --disable-pip -r tools/requirements-semgrep.txt`):
con las 5 excepciones previas → 1 vuln (`CVE-2026-126360`); con la sexta → 0. Sin ninguna excepción → 6 vulns
(4 en `mcp 1.29.0`, 2 en `opentelemetry-api 1.37.0`), es decir, no se ocultó nada más.
`tests/*.test.sh` (alcance, audit-exceptions, gate-roles, runs-on, tag-completo) en verde en local.

## Cobertura

| rol | quién | independiente |
|---|---|---|
| refutación: ¿hay versión corregida compatible?, ¿fuga a callers?, ¿parseo de `IGNORE_VULN`?, ¿gate debilitado? | Claude Opus, contexto nuevo, solo lectura | ✅ |
| medición local con pip-audit, consulta a OSV y PyPI, redacción | el autor | ❌ |

Límite: el revisor es de la misma familia de modelos que el autor (distinto modelo y contexto, no distinta familia).

## Trazabilidad por hallazgo

| hallazgo | estado |
|---|---|
| ¿Existe versión corregida compatible con semgrep? | **No refutado**: PyPI (semgrep 1.186.0 → `~=1.37.0`) y OSV (fixed 1.45.2, introduced 0) lo confirman |
| ¿Se filtra la excepción a los callers? | **No refutado**: input con default `''`; la lista solo está en `selftest.yml` |
| ¿Inyección/parseo inseguro de `IGNORE_VULN` en `verify-python.yml`? | **No refutado**: entra por `env`, se arma como array, se recortan espacios y se descartan vacíos |
| ¿Se debilitó algún gate? | **No refutado**: el único cambio funcional es añadir una ID |
| A-H1 (menor) entrada de backlog mal colocada dentro de la leyenda | **CERRADO** (reproducido y corregido: ahora está en `## Bloqueado`) |
| A-H2 (menor) este ROLE-REVIEW, citado como origen, no existía | **CERRADO** (este archivo) |
| A-H3 (menor) CI sin medir con la nueva excepción; ¿pip-audit acepta un `CVE-` en `--ignore-vuln`? | **CERRADO en local** (con la ID añadida, 0 vulns); el CI del PR lo confirma |

## Límites declarados

- Alcance real de la vuln: DoS en el parseo de una cabecera `traceparent`; semgrep corre como CLI en CI y no recibe esa
  cabecera de una fuente no confiable. Inferido por el revisor, no probado.
- Las 6 excepciones no caducan solas; dependen de la fecha escrita y de que alguien la vigile.
- No se verificó el comportamiento en un runner propio (solo el alojado).
