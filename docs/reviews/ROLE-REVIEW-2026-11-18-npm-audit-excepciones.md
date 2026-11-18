# ROLE-REVIEW — `npm audit` con excepciones caducables (verify-node)

> **Roles-Validated: GO** (decisión PROVISIONAL del operador, 2026-11-18, por delegación del dueño: «los bots deciden PROVISIONAL cuando el dueño no está»).
> Dos rondas de revisor independiente (Claude Opus, contexto nuevo en cada ronda, solo lectura, `--permission-mode plan`,
> mandato de REFUTAR; eje: supply-chain y fail-closed). Ronda 1: **NO-GO** por un bloqueante reproducido (R1-H1), corregido
> con prueba que fallaba antes. Ronda 2 sobre el arreglo: **GO**, sin bloqueantes. Los menores van a `docs/01_BACKLOG.md`.

## Qué cambia

El paso `npm audit` de `.github/workflows/verify-node.yml` respeta la tabla «Excepciones vigentes» de
`docs/SEGURIDAD-DEPENDENCIAS.md` **del repo que llama** (sin inputs nuevos). Decide
`tools/npm-audit-excepciones.mjs` (solo stdlib de Node; viaja con `tooling-ref` y se copia a `$RUNNER_TEMP` antes de que
nada del repo auditado corra). Una fila exime si coincide el aviso (**GHSA de la URL del aviso**) Y el paquete y su fecha de
revisión es ≥ hoy y ≤ hoy+90 días (UTC). Vencida, fuera de ventana o mal formada → rojo; sin JSON utilizable de `npm audit`
→ exit 2. **Sin tabla**, el comando es `npm audit --audit-level=high`, como siempre. Pruebas:
`tests/npm-audit-excepciones.test.sh` (+ fixtures; paso en `selftest.yml`).

## Cobertura

| rol | quién | independiente |
|---|---|---|
| ronda 1 · refutación supply-chain / fail-closed del `.mjs`, el paso bash y el reparto de tooling | Claude Opus, contexto nuevo, solo lectura | ✅ |
| ronda 2 · verificación del arreglo de R1-H1 + nueva refutación (severidades, fechas, paso bash, repo sin tabla) | Claude Opus, contexto nuevo, sin el de la ronda 1 | ✅ |
| implementación, TDD, mutantes, reproducción de los hallazgos | el autor | ❌ |

Límite: los revisores son de la misma familia de modelos que el autor (distinto modelo y contexto, no distinta familia).

## Trazabilidad por hallazgo

| hallazgo | estado |
|---|---|
| **R1-H1 BLOQUEANTE** el aviso se identificaba por `url`+`title`: un aviso nuevo *critical* cuyo título decía «Incomplete fix for CVE-X / GHSA-X» heredaba la exención de la fila de X (fallo abierto; rc=0 en vez de 1). Reproducido por el autor antes de tocar nada | **CERRADO**: solo cuenta el GHSA de la `url`; una fila CVE (npm no trae CVE en el JSON) queda «huérfana» y no exime. Prueba que **fallaba antes** (3 aserciones rojas) y pasa ahora: `tests/fixtures/npm-excepciones/audit-titulo-menciona.json` |
| R1-H2 filas en `<!-- -->` o bloques de código se leen | MENOR → backlog (a) |
| R1-H3 `--hay-tabla` da 2 si el doc pesa > 256 KB sin sección | MENOR → backlog (b) |
| R1-H4 la columna Severidad no se compara con la real | MENOR → backlog (c) |
| R1-H5 el `case` bash 3/0/otro no tiene prueba propia | MENOR → backlog (d) |
| R2-H1 GHSA de la `url` sin anclar al final de la ruta (`…/GHSA-X?x=GHSA-Y`); reproducido por el autor, exige un registro de npm manipulado | MENOR → backlog (e) |
| R2-H2 la exención compara `via.name`, no la clave del paquete (forma que npm no genera) | MENOR → backlog (f) |
| R2-H3 `toca/base/sev` aceptan claves del prototipo; hoy acaba en exit 2 | MENOR → backlog (g) |
| R2-H4 Node < 16.9 / npm 6: exit 2 (falla cerrado); falta documentar la versión mínima | MENOR → backlog (h) |
| riesgo operativo: docs de la flota con un encabezado «Excepciones vigentes» de otra forma pasarían a rojo al mover el alias | declarado → backlog (i) |
| no refutado (ambas rondas) | el código que decide viene de `tooling-ref` y se copia antes de borrar el checkout; `set -euo pipefail` y `|| true` solo en la generación del JSON; JSON vacío/texto/ENOLOCK/npm 6/metadata incoherente → exit 2; sin inyección de workflow commands (regex en aviso, paquete y fecha; mensajes empiezan por `⛔`); sin ReDoS; fechas en UTC, bisiestos, `2026-02-30` inválida, límites 0 y +90 exactos; `--hoy` no se pasa en el workflow; duplicados: gana la fecha más temprana; un crítico propio no se rebaja por la propagación; repo sin documento → `npm audit --audit-level=high` idéntico |

## Límites declarados

- Quien edita la tabla en un PR cambia la excepción en ese mismo PR: el control es la revisión humana de la fila
  (tope de 90 días, queda en el log y en el resumen del run). Está dicho en el README. En `pull_request` ese mismo PR ya
  podría editar el workflow que llama, así que la tabla no abre un vector nuevo.
- El input `tooling-ref` lo elige el repo que llama (ya era así) y puede saltarse la receta entera.
- No se ejecutó el paso bash real de `verify-node.yml` en un runner con una tabla vigente en este ciclo (la suite prueba el
  `.mjs`; el paso lo ejercitó el autor en local sobre un lockfile real). Ver R1-H5.
- El corte exacto del alias `v2` y la subida de `tooling-ref` en cada repo que llama son decisión del dueño; este PR no los toca.
