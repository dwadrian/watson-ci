# Cablear `audit-exceptions.sh` en las tres recetas — diseño

**Fecha:** 2026-08-12 · **Estado:** aprobado por el dueño, pendiente de plan

## Objetivo

Que un advisory **sin parche upstream** tenga una salida **proporcionada y con caducidad** en el CI
de la flota. Hoy la única salida es `--no-verify`, que apaga los nueve gates cuando el rojo era uno.

Pedido por `makro_logistica` el 2026-08-05 como *"lo que más necesito"*.

## Estado medido (2026-08-12) — el punto de partida no era cero

| Receta | Excepción existente | Alcance real | Caduca | Vive en | Repos que la usan |
|---|---|---|---|---|---|
| `verify-php` | input `audit-allow-cve` | **solo** advisories SIN severidad — un `high` nunca tuvo salida | no | el `with:` del stub | **0** |
| `verify-python` | input `pip-audit-ignore-vuln` | cualquier id, vía `pip-audit --ignore-vuln` | no | el `with:` del stub | **0** |
| `verify-node` | ninguna | — | — | — | — |

Distribución de recetas: `verify-node` ×6, `verify-php` ×6, `verify-python` ×2. Ningún repo está en
`@v3`: 12 en `@v2`, `mcp_security_scan` en `@v2.2.1`, `makro_erpnext` SHA-pinneado.

**Dos mecanismos divergentes, ninguno con caducidad, cero usuarios.** El de php además con una
asimetría que casi nadie vería: el escape no cubría el caso que más bloquea.

## Decisiones del dueño (2026-08-12)

1. **Se retiran los dos inputs.** Una sola vía: el archivo con caducidad. Un patrón configurable por
   input deja que un repo ensanche su propio hueco desde su stub, sin caducidad y sin quedar en el
   diff — la clase que `quality-standard.md` ya prohíbe para los patrones del alcance.
2. **`::warning::` por excepción aplicada** (id + fecha + días restantes) **más resumen**. Un hueco
   que no se ve es el que se queda.
3. **El archivo se llama `.watson-audit-exceptions.txt`** y se busca **solo en la raíz** del repo
   auditado. Nombre y ubicación van hardcodeados en los tres scripts: ni input, ni búsqueda
   recursiva. Buscarlo en subdirectorios permitiría a un PR colar uno donde nadie mira.
4. **Extraer el gate por ecosistema a scripts testeables** en vez de insertar el filtro en el YAML.
   Razón: este mecanismo **debilita un gate a propósito**, así que sus modos de fallo pesan más que
   el camino feliz — y dentro de un `run:` no hay forma de escribir un test que compruebe que un
   archivo malformado no exime nada.

## Arquitectura

### Frontera de confianza

| Pieza | Origen | Por qué |
|---|---|---|
| `audit-exceptions.sh`, `dep-gate-*.sh` | `watson-ci` vía `tooling-ref` (pineado) | un PR del repo auditado **no puede tocar el código que lo juzga** |
| **Nombre** del archivo de excepciones | **hardcodeado** en la receta | como input, un repo apuntaría a otro archivo y ensancharía su hueco |
| **Contenido** del archivo | el repo auditado | es el dato, y aparece en el diff del PR |

Las tres recetas **ya** hacen `checkout` de `dwadrian/watson-ci@${{ inputs.tooling-ref }}` en
`.watson-ci-tooling/`, y ya hay precedente de invocar un `.sh` desde ahí
(`.watson-ci-tooling/.github/actions/alcance/alcance.sh`). **No se añade infraestructura.**

### Componentes

Tres scripts nuevos en `tools/`, con **contrato idéntico**:

```
tools/dep-gate-npm.sh       <raiz>
tools/dep-gate-composer.sh  <raiz>
tools/dep-gate-pip.sh       <raiz>

exit 0 = verde  ·  1 = bloquea  ·  2 = ERROR (herramienta caída o entrada no utilizable)
```

**La raíz va por ARGUMENTO, nunca por variable de entorno.** `WATSON_CI_ALCANCE` ya reprodujo el
bypass de que el entorno pise la decisión del gate; no se repite la forma.

Cada script asume lo que hoy está incrustado en el `run:` de su receta:

- **npm**: `npm ci --ignore-scripts` (o `npm install` sin lockfile) y `npm audit --json`.
- **composer**: exigir `composer.lock` (sin lock = RED) y `composer audit --locked --format=json`.
- **pip**: localizar manifiestos a `maxdepth 6` y correr `pip-audit` por fuente.

Y delega la **decisión** en `audit-exceptions.sh`.

### Lo que NO se reimplementa

`audit-exceptions.sh` **ya codifica la regla de bloqueo de cada ecosistema**, verificado contra
corpus real:

| Ecosistema | Regla que ya aplica |
|---|---|
| npm | clausura sobre el grafo con **recálculo de severidad efectiva**; bloquea `high`/`critical` |
| composer | `high`/`critical`, y **`unknown` tratado como crítico** (falta de dato ≠ ausencia de riesgo) |
| pip-audit | cualquier vuln — la herramienta **no expone severidad** (pypa/pip-audit#654) |

Los `dep-gate-*` la **consumen**, no la duplican. Es la misma decisión de diseño que hizo que
`tests/audit-exceptions.test.sh` llame al script real en vez de copiar su expresión `jq`.

## Flujo de datos

```
<tool> audit --json                     →  /tmp/audit.json
  ¿existe .watson-audit-exceptions.txt en la raíz?
     NO  →  se evalúa el JSON crudo        ← comportamiento IDÉNTICO al de hoy
     SÍ  →  audit-exceptions.sh --filter <archivo> <eco> < /tmp/audit.json
               rc 0 → verde   ·   rc 1 → bloquea   ·   rc 2 → ROJO
```

**Propiedad que se exige y se testea:** un repo **sin** el archivo no ve ningún cambio de
comportamiento. Los 14 repos de hoy quedan exactamente igual; solo cambia quien decide añadirlo.

## Manejo de errores (fail-closed)

El `2` es distinto del `1` **a propósito**: *"el filtro murió"* no puede leerse como *"bloqueó"* ni,
mucho peor, como *"no hay hallazgos"*. Casos ya medidos que lo justifican:

- `printf '' | jq '.x'` sale **rc=0 sin salida** — entrada vacía debe ser `2`, jamás "0 hallazgos".
- `npm audit` en `ENOLOCK` sale **rc=1 igual que el camino feliz** y emite **JSON válido** con
  `.error` — el discriminante no puede ser el exit code, tiene que ser la **forma** del JSON.
- Línea malformada en el archivo ⇒ **el archivo entero se invalida**, nada exento.
- `2026-02-30` ⇒ inválida por round-trip; sin él `strptime` la rueda a marzo y **alarga** la excepción.
- Comodines (`GHSA-*`, `all`, `*`) rechazados; un prefijo **no** exime al id completo.

Una excepción **vencida** no exime **y se nombra** en la salida. Una vencida en silencio manda al
`--no-verify`, que es justo lo que este mecanismo existe para evitar.

## Testing

`tests/dep-gate.test.sh`, contra los **fixtures reales que ya existen** en
`tests/fixtures/audit/` (npm: app Expo con 12 `high`; composer: repo Laravel con 6 advisories, 4 con
`cve: null`; pip-audit 2.10.1: 6 vulns sin severidad y con tres identidades cada una).

Casos obligatorios por ecosistema:

1. **Control sin archivo de excepciones** → mismo veredicto que hoy. *(la propiedad de no-regresión)*
2. Control con archivo vacío → idéntico al anterior.
3. Excepción aplicada → verde, y el `::warning::` **nombra el id y los días restantes**.
4. **Sobre-exención**: eximir 1 de 2 sigue bloqueando.
5. Archivo malformado → **exit 2**, nada exento.
6. Excepción **vencida** → no exime, y la salida la **nombra**.
7. Comodín (`*`, `all`, `GHSA-*`) → rechazado.
8. Herramienta caída / JSON con `.error` → **exit 2**, nunca verde.
9. **CONTROL NEGATIVO**: con una excepción declarada para el advisory A, el advisory B **sigue
   bloqueando**. Sin este, "eximir todo" pasaría igual de verde.

Fechas **relativas** (`now ± N días`), nunca fijas: un fixture con fecha fija caduca y el test
empieza a fallar solo.

Cableado al job `decisiones` de `selftest.yml`, donde ya corre `audit-exceptions.test.sh`.

## Publicación

**`v3.1.0`, y mover el alias `v3`.** Retirar inputs es *breaking* en semver, pero **nadie está en
`@v3`**: forzar un `v4` obligaría a tocar 14 stubs a cambio de nada. La migración `@v2 → @v3` ya es
un ítem propio del backlog.

Antes de publicar: `tests/tag-completo.test.sh` sobre el ref, que bloquea si el tag no contiene las
acciones que sus consumidores referencian.

## Alcance — lo que este trabajo NO hace

1. **No desbloquea el caso de `makro_logistica`.** Ese repo bloquea en **su propio `quality.yml`** y
   su `ci-local`, que no pasan por estas recetas. Su caso necesita su propia entrega, y decir lo
   contrario sería vender cerrado lo que sigue abierto.
2. **No migra ningún repo a `@v3`.** Publica la versión; mover cada stub es otro ítem.
3. **No mide la reincidencia.** La ventana es renovable reescribiendo la fecha cada 89 días. Queda
   contada en el log, pero nada impide renovarla indefinidamente.
4. **No toca `dep-audit.sh` de watson** (el de `ci-local`), que hoy es solo-npm. Es otro ítem.
