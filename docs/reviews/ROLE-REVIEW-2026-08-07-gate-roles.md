# ROLE-REVIEW: backstop de roles en watson-ci

**Roles-Validated: GO** (seguridad de cadena de suministro + gatekeeper, **5 rondas**, 2026-08-07).

| Campo | Valor |
|---|---|
| Cambio | capa 1 (`.claude/agents/config.json`, solo configuración) + capa 2 (`tools/gate-roles.sh`, `tests/`, `gate-roles.yml`) |
| Origen | el 2026-08-05 se rompió el CI de los 17 repos **desde este repo** y ningún gate lo detectó |
| Spec y plan | en watson: `docs/superpowers/specs/2026-08-06-gates-en-watson-ci-design.md`, `docs/superpowers/plans/2026-08-06-gates-en-watson-ci.md` |

## La restricción que ordenó el diseño

Este repo es **público**. Un hook git-trackeado aquí es **RCE local**: un tercero abre un PR que
toca `.claude/hooks/cli.mjs`, se hace `gh pr checkout` para revisarlo, y al abrir Claude Code el
`SessionStart` ejecuta su código — **antes del merge**, y branch protection no lo mitiga porque el
ataque ocurre en el checkout.

La primera propuesta fue desplegar el harness completo. **Se descartó al explorar el contexto**,
antes de escribir nada. Por eso aquí no hay ni un `.mjs`: la capa 1 es **solo un archivo de
configuración**, que los hooks del repo desde el que se commitea leen vía `crossCfg`.

## Lo que encontró el loop, por rondas

**Ronda 1 — NO-GO, 3 ALTO.** El gate no disparaba en el **evento que reparte**: la flota consume
`@v2`, así que la distribución ocurre al **mover el tag**, y el workflow solo oía `push` a `main`.
Más: **evil merge** (`diff-tree` sin `-c` devuelve vacío sobre un merge), **ruta no-ASCII**
(`core.quotePath` la saca entre comillas y el `case` no matchea), y **fail-open** si `rev-list`
falla. Y los tests **no ejercían el fixture** —faltaba el `cd`—, así que 6 de 10 asserts pasaban
por la razón equivocada y la mutación daba salida idéntica.

**Ronda 2 — NO-GO, 3 ALTO.** Dos dejaban el arreglo anterior **en cero**:
`git rev-parse --verify main` resuelve `refs/tags/main` **antes** que la rama, así que
`git tag main <evil>` la suplantaba; y `git fetch --depth=0` es **fatal**, así que el paso del tag
abortaba antes de llamar al gate — **el arreglo nunca se ejecutó ni una vez**. Además el chequeo
de estado era un **substring sobre el archivo entero**: bastaba dejar `roles.enabled:false` y que
cualquier otro bloque tuviera `enabled:true`.

**Ronda 3 — NO-GO, sin huecos vivos.** 7 de 25 asserts eran **vacuos**. Y al escribir los
reemplazos caí en la misma trampa: mis globs de prueba llevaban cuatro barras invertidas en vez de
dos, así que **no casaban nada** y los tests pasaban por globs inválidos.

**Ronda 4 — NO-GO, y el hallazgo fino.** El assert que cubría la cualificación de refnames
**pasaba por el chequeo de resolubilidad**: su fixture vigilaba `main`, que en el fixture no
existe. Consecuencia medida: descualificar **solo** el `REF=` sobrevivía a la suite entera, con
bypass verde y receta distribuible.

**Ronda 5 — el gate rechazaba a los honestos.** Ya con GO, al escribir ESTE review el gate lo
rechazó. Medido: la marca pelada en columna 0 que exigía la ronda 4 rechaza el
`**Roles-Validated: GO**` que se escribe de verdad **y** el `> Roles-Validated: GO` que
`role-gate.mjs:85` **instruye escribir**. O sea **100% de falsos positivos sobre artefactos
legítimos y cero adversarios menos** — quien quiera burlarlo escribe la marca pelada, que era
justo lo único que pasaba. Se alineó al predicado exacto de `role-gate.mjs:20`: dos gates sobre
el mismo artefacto con predicados distintos garantizan que uno está equivocado. Lo que el ancla
`^` sí compra (una **mención a mitad de línea** no es veredicto) se conserva, con su propio
assert aislado.

Efecto lateral: el assert 20 pasó a depender **solo** del nombre de plantilla, y su título
—"marca CITADA en un blockquote => FALLA"— quedó **mintiendo** sobre lo que pinnea. Retitulado.

## El patrón, dicho sin adornos

**Seis veces en este trabajo un verde no probó lo que decía** — cinco asserts y, en la ronda 5,
una prueba de mutación que **no aplicó** (no le pasé los argumentos a `python3 -c`) y reportó
`0 fallo(s)`: un verde que no significaba nada. La cazó leer el traceback, no el resultado. No aislaba;
globs inválidos; un assert cubriendo dos defensas que se enmascaraban; un fixture que fallaba por
otro motivo. Ninguna la cazó el verde: **todas las cazó la mutación**. El resto del gate no vale
más que su prueba de mutación.

## Verificación

| Comprobación | Resultado |
|---|---|
| `bash tests/gate-roles.test.sh` | **39 asserts, 0 fallos** |
| Cada defensa muere por **mutación de un solo sitio** | exclusión `TEMPLATE` → #36 (+#20, el caso de regresión) · **ancla `^` → solo #35c** · rama resoluble → solo #37 · cualificación `refs/heads/` → solo #26 |
| Mutación de control (`.github/*` deja de ser riesgo) | **11 asserts caen** (el plan exige ≥8) |
| Batería del gatekeeper | 55 mutantes, **32 muertos**; el único movimiento tras el fix fue `T3`: de sobrevive a muerto |
| Capa 1, rojo/verde sobre un **clon** | 8/8, con rutas literales |
| Restricción de repo público | **0** archivos `.mjs`; `.claude/` contiene **solo** `agents/config.json` |
| Canario propio del repo | `expect-audit-decision.sh` en verde; las 3 recetas sin tocar |

## Límites declarados

1. **`--is-ancestor` prueba contención, no revisión.** El mismo tag pasa de rojo a verde solo con
   empujar esa rama a `main`. Vale exactamente lo que valga el gate del push a main.
2. **El job no es *required status check* todavía** — hasta que lo sea, esto **avisa pero no
   frena**. Es acción del dueño.
3. **En `pull_request`, Actions corre el código del propio PR**, así que un PR puede neutralizar
   el gate que lo juzga. Se cierra exigiendo el check **por nombre** en el ruleset.
4. **23 mecanismos sin test** (14 de una batería, 9 de otra — no se suman). Todos fail-closed o
   no-op salvo el `\b` final de `GO`. El único que fallaba **abierto** está cerrado.
5. **El camino de producción del modo `--tag`** (detached en el tag, sin `refs/heads/main`) no
   tiene fixture. Verificado a mano que funciona y que romperlo da rojo.
6. **`tests/fixtures/*` exento por convención**, sin guard que lo enforce.

Todos están en `watson/docs/01_BACKLOG.md` con su origen.
