# Fixtures del selftest

## Por que existen

Hasta v2, `selftest.yml` corria las 3 recetas **contra este mismo repo**, que no tiene
manifiestos: los dep-audits hacian skip limpio y el SAST barria 4 archivos yml. Eso probaba que
las recetas **arrancan**, no que **deciden bien**.

La consecuencia se midio: `v2.2.0` y `v2.2.1` cambiaron **que commits pasan y cuales fallan** en
todos los repos gateados, se publicaron en el alias movil, y el unico run de selftest de toda la
historia era **anterior a ambos**. Encima, el corte de facturacion de GitHub tumbo el CI de la
flota ~10 dias, asi que una regresion real no habria sido detectable. Que no pasara nada fue
suerte.

Un gate que no se puede probar antes de publicarlo no se puede cambiar con seguridad.

## Como se usan

Cada fixture es un arbol minimo que **debe producir un veredicto conocido**. El selftest los
corre y compara el veredicto real contra el esperado. Un fixture que cambia de veredicto sin que
nadie lo pidiera es exactamente la regresion que buscamos.

| Fixture | Que prueba | Veredicto esperado |
|---|---|---|
| `php-advisory-sin-severidad/` | composer audit con advisory SIN campo `severity` | **ROJO** (v3; en v2 era verde) |
| `python-sin-lock/` | pyproject.toml sin lockfile auditable | **ROJO** (v3; en v2 era `exit 0`) |

## Limite honesto

Estos dos fixtures cubren los dos fail-open que v3 cierra. **No** cubren el resto de la matriz
(SAST diff-aware, rama gateada, npm audit, secrets). Ampliarlos esta en el backlog: lo que hay
hoy es el minimo que impide re-publicar los dos bugs conocidos, no una suite completa.
