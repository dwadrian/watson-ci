# ROLE-REVIEW: `tools/audit-exceptions.sh` llega a watson-ci

**Roles-Validated: GO** (auditor ofensivo + code-reviewer de shell portable + crítico de
completitud + release gatekeeper · **2 rondas sobre la spec** + prototipo ejecutable · 2026-08-12)
— **con el alcance acotado de la sección siguiente.**

## Qué cambia para los 17 repos con este commit: NADA

Y conviene que quede escrito antes que nada:

| | |
|---|---|
| **Ninguna receta lo llama** | `verify-{node,php,python}.yml` están **sin tocar**. El script está en el repo y no lo invoca nadie |
| **Ningún tag se mueve** | los repos consumen `@v2`/`@v3` por tag; hasta que el dueño mueva un alias, esto no llega a ninguna parte |
| **El único consumidor nuevo es el selftest** | corre la suite en el CI de este repo, que es exactamente donde debe fallar si algo se rompe |

⛔ **Este GO NO autoriza cablear las recetas ni publicar un tag.** Eso sí cambia el veredicto de
CI en 17 repos y necesita **su propia ronda** con el rol de seguridad, sobre el cableado.

## Qué llega

`tools/audit-exceptions.sh` — excepciones de dependencias **por advisory y con caducidad**, para
que un advisory sin parche upstream deje de tener como única salida `--no-verify`, que apaga los
nueve gates cuando el rojo era uno.

`tests/audit-exceptions.test.sh` — **18 asserts** sobre **corpus real capturado**:
npm (app Expo, 12 high), composer (repo Laravel, 6 advisories), pip-audit 2.10.1 (6 vulns).
Cableado en `selftest.yml`, job `decisiones`.

**A diferencia de `expect-audit-decision.sh`, este NO duplica la expresión `jq` de la receta:**
llama **al mismo script** que llamará la receta, así que no puede divergir de lo que se ejecuta.
Aquel duplica a propósito —como detector de deriva— y su comentario lo explica; aquí no hace falta.

## Los tres hallazgos que el corpus real produjo, y que datos inventados no habrían dado

1. **npm no es un filtro por ID: es una clausura sobre un grafo con ciclos.** De las 12 entradas
   `high`, **una sola lleva identificador**. Y la regla correcta **recalcula la severidad
   efectiva**, no decide supervivencia: con la otra lectura dan **3 high** porque un advisory
   **`moderate`** de `uuid` sostiene tres paquetes `high`. Dos versiones de la spec fijaron la
   lectura equivocada; lo resolvió ejecutar.
2. **composer: `cve` es `null` en 4 de 6** — el "fallback" a `advisoryId` es el caso mayoritario —
   y dice **`medium`** donde npm dice `moderate`. Sin `medium` en la tabla de severidad, el
   advisory **desaparecía en silencio**: fail-open que ya estaba escrito.
3. **pip-audit NO TIENE campo de severidad**, y cada vuln trae **tres identidades**
   (`id` PYSEC + aliases GHSA/CVE/SNYK). Se casa contra `id ∪ aliases`, porque quien busca el
   advisory encuentra el CVE.

## Fail-closed: lo que decide si esto sirve

El mecanismo **debilita un gate a propósito**, así que sus modos de fallo pesan más que el camino
feliz. Todos con assert:

- **stdin vacío ⇒ exit 2**, jamás "0 hallazgos" (medido: `printf '' | jq` sale **rc=0 sin salida**).
- **JSON válido de FORMA INCORRECTA ⇒ exit 2** — npm en `ENOLOCK` sale **rc=1 igual que el camino
  feliz** y emite JSON válido con `.error`. **El discriminante no puede ser el exit code.**
- Línea malformada ⇒ **el archivo entero se invalida**, nada exento.
- `2026-02-30` ⇒ inválida (round-trip); sin él, `strptime` lo rueda a marzo y **alarga** la
  excepción.
- Comodines (`GHSA-*`, `all`, `*`) rechazados; prefijo **no** exime al ID completo.
- Severidad desconocida ⇒ se trata como **crítica**, no como 0. *Lo que no entendemos no puede
  considerarse inofensivo.*

## Límites declarados

1. **Las recetas no lo usan.** Cablearlas es la siguiente entrega, con su propia validación.
2. **El caso que motivó todo esto no se desbloquea con esto**: `makro_logistica` bloquea en su
   propio `quality.yml` y su propio `ci-local`, que no pasan por estas recetas.
3. **La ventana de caducidad es renovable** reescribiendo la fecha cada 89 días. Queda contada,
   pero nada mide la reincidencia.
4. **El fixture de pip-audit se provocó** con un paquete viejo real, porque los tres manifiestos
   Python de la flota están limpios. La salida es de la herramienta real contra la base de
   advisories real; **la entrada la elegí yo**, y eso se dice.
