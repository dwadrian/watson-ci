# ROLE-REVIEW — input `runs-on` en las recetas (fabrica#2425)

> **Roles-Validated: GO (operador de runner self-hosted + atacante de supply chain, 2 rondas, + gatekeeper, 2026-11-06)**

## Cobertura

| rol | quién | independiente |
|---|---|---|
| ronda 1 · operador de runners self-hosted hostil + auditor de supply chain | subagente nuevo, mandato REFUTAR | ✅ |
| ronda 2 · atacante de supply chain + operador del consumidor makro_web | subagente nuevo (sin el contexto de la ronda 1), mandato REFUTAR | ✅ |
| gatekeeper · trazabilidad por hallazgo | subagente nuevo | ✅ |
| implementación, TDD y mutación | el autor | ❌ |

## El problema

Las tres recetas fijaban `runs-on: ubuntu-latest`. Al agotarse el tope de gasto de Actions, el job
`seguridad` de makro_web no podía correr y `ci-ok` quedaba en rojo, aunque todos los demás jobs ya
corrían en runners propios (`vars.RUNS_ON`).

## Lo que cambió por las rondas (lo que el autor NO había visto)

- **jq 1.7.1 → 1.8.2** (R1-H3). El autor fijó 1.7.1 «porque es el de ubuntu-24.04». El binario
  upstream 1.7.1 no lleva los arreglos de CVE-2024-23337/53427 y CVE-2025-48060: fijarlo era una
  regresión de seguridad para los consumidores en ubuntu-latest.
- **El test de jq solo buscaba cadenas** (R1-H4). Quitar la comparación del sha256 sobrevivía. Ahora
  el test **ejecuta** el python de descarga con `urlopen` simulado: con sha correcto deja el binario;
  con sha incorrecto aborta sin escribirlo; con red fallando reintenta; y pide solo la URL oficial.
- **Pasos neutralizables** (R2-M3): `if:`, `continue-on-error`, `exit 0`, `/usr/bin` antepuesto
  tras el pin. Todos tienen ahora su mutante.
- **Afirmación inflada de cobertura** (R2-M2): «selftest comprueba que jq 1.8.2 no mueve
  veredictos». Solo cubre 3 de 6 expresiones. Reescrito con lo que de verdad se cubre.
- **Chequeo de sudo** (R2-B3): dependía de `RUNNER_ENVIRONMENT`; setup-php decide self-hosted por más
  señales. Ahora es incondicional.
- **actionlint** (R1-H1): shellcheck marcaba hallazgos info que ya existían en el paso SAST. Se
  excluyen DOS reglas, no la severidad entera.

## Trazabilidad (gatekeeper)

| id | veredicto |
|---|---|
| R1-H1 actionlint rojo por info preexistente | CERRADO (CI 41379d8: fixtures verde) |
| R1-H2 falta este ROLE-REVIEW | CERRADO (este archivo, en el commit aplastado) |
| R1-H3 jq con CVEs | CERRADO (1.8.2; sha = digest del release) |
| R1-H4 mutantes del paso jq | CERRADO (test conductual) |
| R1-H5 job en línea | CERRADO |
| R1-H6 runners no efímeros | CERRADO (documentado como requisito, no comprobado) |
| R1-H7 setup-python exige /opt/hostedtoolcache | RECHAZO CORRECTO (solo en macOS, advanced-usage.md @ece7cb06) |
| R1-H8/H9/H10 README | CERRADO |
| R1-H11 descarga sin reintentos | CERRADO (y defendido por mutante) |
| R1-H12 setup-php en self-hosted | CERRADO (sudo incondicional; apt por run documentado) |
| R1-H13 selftest/gate-roles con literal | FUERA DE CONTRATO — declarado en el PR |
| R2-M1 sin input ya no es idéntico | DECISIÓN CONSCIENTE — declarada en el PR |
| R2-M2 cobertura inflada | CERRADO |
| R2-M3 mutantes sobrevivientes | CERRADO |
| R2-B1 IncompleteRead | CERRADO (y defendido por mutante) |
| R2-B2 escritura no atómica | CERRADO (temp + os.replace; sin mutante) |
| R2-B3 sudo vs heurística de setup-php | CERRADO |
| R2-B4/B5/B6 README | CERRADO |
| R2-B7 título «todo job» | CERRADO (título del commit y del PR reformulados) |
| R2-B8 audit-exceptions.sh no probado con jq fijado | FUERA DE ALCANCE (ninguna receta lo llama) — declarado |

## Lo que sigue sin cubrir (dicho, no escondido)

- **Ninguna ejecución en un runner `makro-web` real.** La imagen de esos runners
  (`cluster2-mweb-1`, `cluster4-mweb-1`) no se pudo inspeccionar desde aquí: los requisitos salen de
  leer el código de cada paso y de las actions en sus SHA fijados, no de correrlas en esa imagen.
- **El job python del selftest está rojo también en main** (run 42302381222): hay vulnerabilidades
  nuevas en `tools/requirements-*.txt`. Es previo a este cambio y no se toca aquí.
- `--exclude=SC2086` silencia esa regla también en código futuro. Es el trade-off elegido frente a
  tocar el paso SAST que ya existía.
