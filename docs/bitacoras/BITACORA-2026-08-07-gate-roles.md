# BITÁCORA 2026-08-07 — backstop de roles en watson-ci

**Qué se entrega:** el repo que reparte CI a 17 repos ahora exige loop de roles en sus propios
cambios de riesgo, y un job en su CI lo verifica aunque el harness local no corra.

## Por qué

El **2026-08-05** se movió el tag `v2` con 5 commits sin validar y **se rompió el CI de los 17
repos de la flota** — `tools/requirements-semgrep.txt` no existe en los callers. Ningún gate lo
detectó, y la causa es concreta: este repo **no tenía `.claude/agents/config.json`**, y el default
del harness es `roles.enabled: false`. Ese día el gate sí pidió bitácora y backlog, pero **no el
loop de roles**, sobre un cambio que tocaba a toda la flota.

## Qué se hizo

**Capa 1 — `.claude/agents/config.json`.** Solo configuración. Los hooks que la aplican son los
del repo desde el que se commitea (`pre-tool.mjs:921` lee la config del repo **destino**).

**Capa 2 — `tools/gate-roles.sh` + `tests/` + `.github/workflows/gate-roles.yml`.** Backstop que
corre en el CI de este repo, en `push` a `main` **y al mover un tag `v*`** — que es el evento que
de verdad reparte.

**Restricción que ordenó el diseño:** este repo es **público**, y un hook git-trackeado aquí es
**RCE local** (un tercero abre un PR que toca `.claude/hooks/cli.mjs`, haces `gh pr checkout` para
revisarlo, y su `SessionStart` ejecuta su código antes del merge). La propuesta inicial de
desplegar el harness completo **se descartó al explorar el contexto**, antes de escribir nada.
Por eso aquí no hay ni un `.mjs`.

## Verificación

| Comprobación | Resultado |
|---|---|
| `bash tests/gate-roles.test.sh` | **39 asserts, 0 fallos** |
| Cada defensa muere por mutación de **un solo sitio** | 4/4 aisladas |
| Mutación de control (`.github/*` deja de ser riesgo) | **11 asserts caen** (el plan exige ≥8) |
| Capa 1, rojo/verde sobre un **clon** | 8/8 |
| Restricción de repo público | **0** archivos `.mjs`; `.claude/` solo tiene `agents/config.json` |
| Canario del repo (`expect-audit-decision.sh`) | verde; las 3 recetas sin tocar |

## El loop: 5 rondas

Detalle por ronda en `docs/reviews/ROLE-REVIEW-2026-08-07-gate-roles.md`. Resumen de lo que se
cazó: el gate no oía el evento que reparte · evil merge · ruta no-ASCII · fail-open en `rev-list` ·
`refs/tags/main` suplantando la rama · `--depth=0` fatal que dejó el arreglo anterior sin
ejecutarse **ni una vez** · substring sobre el archivo entero en vez de leer el campo.

La **ronda 5** salió ya con el GO dado, al escribir el review: el gate **lo rechazó**. Exigía la
marca pelada en columna 0, o sea que rechazaba el formato que se escribe de verdad **y el que
`role-gate.mjs:85` instruye** — 100% de falsos positivos sobre artefactos legítimos y cero
adversarios menos. Alineado al predicado exacto del harness. **Un gate que solo rechaza a los
honestos no es estricto: está roto.**

**El patrón, sin adornos: seis veces un verde no probó lo que decía.** No
aislaba; globs con cuatro barras invertidas que no casaban nada; un assert cubriendo dos defensas
que se enmascaraban; un fixture que fallaba por otro motivo. Y en la ronda 5, la propia prueba de mutación **no aplicó** —sin argumentos a
`python3 -c`— y reportó `0 fallo(s)`. **Ninguna la cazó el verde: las cazó la mutación, y a esa
última la cazó leer el traceback en vez del resultado.**

## Lo que NO queda cerrado

1. **El job todavía no es *required status check*** — hasta que el dueño lo añada al ruleset
   `main-protegido`, esto **avisa pero no frena**. Es la mitad del valor.
2. **`--is-ancestor` prueba contención, no revisión.**
3. **En `pull_request`, Actions corre el código del propio PR** — se cierra exigiendo el check por
   nombre en el ruleset (mismo punto 1).
4. **23 mecanismos sin test** (14 de una batería, 9 de otra — **no se suman**, son denominadores
   distintos). El único que fallaba **abierto** está cerrado.
5. **El camino de producción del modo `--tag`** no tiene fixture; verificado a mano.

Todos con su origen en `watson/docs/01_BACKLOG.md`.

## Staff Hours (sin AI)

| Fase | Horas |
|---|---:|
| Análisis (leer el incidente del 08-05, medir por qué ningún gate disparó, acotar el riesgo de repo público) | 3.0 |
| Diseño (spec + plan; descartar el despliegue del harness completo por RCE; dos capas) | 2.5 |
| Admin (bitácora, review, backlog, coordinación del ruleset) | 1.0 |
| Implementación (config.json + gate-roles.sh + workflow) | 4.0 |
| Debugging (evil merge, quotePath, refs/tags/main, --depth=0, jq) | 5.5 |
| Testing (39 asserts + pruebas de mutación en dos baterías) | 6.0 |
| Review (5 rondas, roles de seguridad de cadena de suministro + gatekeeper) | 4.0 |
| **Total** | **26.0** |
