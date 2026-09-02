# ROLE-REVIEW — las cuatro condiciones bloqueantes del tag `v3.1.0`

> **Roles-Validated: GO (rol adversarial de shell + release gatekeeper, 4 rondas, 2026-09-02)**
>
> Roles que aplicaron y por qué, según la tabla de `/validate` — el artefacto es shell distribuido a
> 17 repos que decide si un CVE bloquea un build, o sea **tier crítico**:
> · **rol adversarial de shell** (code-review + seguridad sobre la superficie que ejecuta) — 29
>   mutaciones en 2 plataformas, veredicto GO CONDICIONADO con 4 bloqueantes.
> · **release gatekeeper** — 4 rondas, trazabilidad binaria por hallazgo. NO-GO · NO-GO · NO-GO · **GO**.
>
> **Rol NO despachado y por qué:** no hubo un tercer rol de *seguridad* separado. La superficie de
> ataque de este fichero es su parser y su contrato de salida, y las dos las cubrió el rol de shell
> con mutación adversarial (fail-open de entrega, charset del id, inyección de `.bloqueantes`
> descartada con control ejecutado). **Se declara en vez de contarlo como cubierto.**


**Artefacto:** `tools/audit-exceptions.sh` + `tests/audit-exceptions.test.sh`
**Origen:** veredicto **GO CONDICIONADO** del rol adversarial de shell (2026-09-02): *"GO para
implementar el plan · NO-GO para publicar el tag hasta cerrar estas cuatro"*. 29 mutaciones
medidas por ese rol en bash 3.2.57/BSD y bash 5.2.26/alpine/GNU: 13 morían, **16 sobrevivían**.

## Estado por condición

| | qué pedía | estado |
|---|---|---|
| **F1** | reproducir el parseo con tabulador y con sangría | **CERRADO — y SÍ era defecto.** Contra HEAD, una línea de 2 campos con tab o con sangría daba `✓ válido`: una exención **sin razón escrita**, que es justo el rastro de auditoría por el que este fichero existe. Árbol nuevo: `rc=2` en las dos |
| **C1** | un solo parser para la línea de excepción | **CERRADO** — `awk` único + conteo `NF`; tab → `rc=2`, sangría → `rc=2`, línea legítima → `rc=0` |
| **C2** | contrato de salida y rc de la entrega | **CERRADO** — `case` sobre `.bloqueantes` → `exit 2`; `\|\| { … exit 2; }` en el `jq` que entrega |
| **C3** | tres asserts: tope de 90 días, duplicados por fecha temprana, frontera `>=` | **CERRADO con hallazgo** — abajo |
| **C4** | criterio de aceptación 22 → 23 y «5 asserts» → 6 | **PARCIAL, y digo cuál mitad** |

## C2 — la repro, en las cuatro direcciones

Fabricada eximiendo los GHSA de `npm-makro-12high.json`:

```
VIEJO · entrega sana     rc=0
VIEJO · salida CERRADA   rc=0   ← el fail-open reportado
NUEVO · entrega sana     rc=0   ← no rompe el caso sano
NUEVO · salida CERRADA   rc=2   ← arreglado
```

## C3 — el assert que escribí primero NO defendía nada, y lo dijo la mutación

Los tres asserts pasaron a la primera. Eso no probaba nada: **las tres propiedades ya estaban
verdes antes de escribirlos**. Al mutar, dos murieron y **el de la frontera sobrevivió**:

```
MAX_DIAS=90 → 99999      1 fallo     ✔ muere
-k2,2n → -k2,2nr         2 fallos    ✔ muere
>= $hoy → > $hoy         TODO VERDE  ← sobrevivió
```

**Causa medida: la vigencia estaba implementada DOS VECES.**

```
el que DECIDE   jq    select(.e >= $hoy)        → quién exime
el que INFORMA  bash  [ $epoch -lt $HOY_EPOCH ] → imprime "⏰ VENCIDA"
```

Coincidían, pero eran dos bloques. Mi assert leía el **mensaje**, así que medía al que informa
mientras yo mutaba al que decide. Es «arregla el BLOQUE, no el consumidor» y su corolario «el
reporte no depende del RESULTADO», juntos.

**Y no es solo un hueco de test.** Con `-le` en el bucle de bash, el filtro **exime** una excepción
mientras el mensaje dice *"VENCIDA — vuelve a bloquear"*: el gate pasa en verde y el operador lee lo
contrario de lo que ocurrió.

**Segunda trampa, también medida:** `select(.severity=="high")` cuenta **paquetes**, no advisories,
así que eximir UN id no mueve el conteo. El único observable del decisor es el **veredicto** con
todos los ids exentos.

**El arreglo NO es un quinto assert: es un solo predicado.** `VIV_JSON` se calcula una vez y lo
consumen el filtro (`--argjson vivid`) y el reporte (`grep -qx` sobre `$VIVOS`). Tras unificar, el
cuarto sitio de mutación **ya no existe** — eso es el cierre, no un hueco sin medir.

```
MAX_DIAS=90 → 99999             1 fallo   ✔
-k2,2n → -k2,2nr                2 fallos  ✔
select(.e >= $hoy) → > $hoy     1 fallo   ✔  (antes sobrevivía)
-lt "$HOY_EPOCH" → -le          sitio inexistente tras unificar
```

Los duplicados se prueban en **las dos ordenaciones** del fichero: con una sola, el test pasaría por
el orden de escritura y no por la regla.

## C4 — la mitad que era cierta y la que no

El revisor pidió dos correcciones. Medido en el plan: **«5 asserts nuevos» sí estaba mal → 6**
(corregido). **El total ya decía 23**, no 22 — esa mitad no existía. Lo digo en vez de anotar las
dos como cerradas.

De paso, el plan citaba `audit-exceptions.sh:226-238` y la unificación desplazó el bloque 30 líneas:
pasa a citarse **por ancla**, no por número.

## Dos veces la misma trampa dentro de este trabajo, y las dos las cazó un aborto, no un verde

1. Mi editor no encontró el ancla del resumen → **abortó sin escribir**, y acto seguido el `bash -n`
   y la suite dieron **verde sobre el fichero sin modificar**. Verde de un objeto que no era el que
   creía estar midiendo.
2. Mutar `select(.e >= $hoy)` dio *"casa 2"*: **mi propio comentario cita el predicado que
   explica**. Es *"un documento que define una convención siempre contiene instancias de ella"* —
   dentro del arreglo cuya lección es ésa. Anclado a líneas de código no-comentario.

Las dos veces la señal fue el **mensaje de aborto**. Ninguna la habría cazado leyendo el verde.

## Verificación ejecutada

```
shellcheck -S warning          limpio (script y suite)
bash 3.2.57 / BSD (macOS)          29/29 · TODO VERDE
bash 5.2.26 / alpine / BUSYBOX     29/29 · TODO VERDE
bash 5.2.21 / ubuntu 24.04 / GNU   29/29 · TODO VERDE   ← la que corre selftest.yml:76
mutación (4 sitios)            3 mueren · el 4º dejó de existir al unificar
```

**Veredicto: GO para el tag en lo que toca a F1/C1/C2/C3.** C4 cerrado con la corrección real y la
mitad inexistente declarada.

**NO verificado:** esto no ha corrido en un runner de Actions. Local en dos shells, y sólo eso.


---

# RONDA 2 — el gatekeeper dijo NO-GO, y en lo que más dolía tenía razón

**Veredicto recibido:** NO-GO para `v3.1.0`. *"El camino que **decide** está sano; lo que no está
listo es el camino que **informa**, y la red que impide que estos arreglos se borren solos."*

## El hallazgo que invalida mi propia conclusión de la ronda 1

Escribí que la unificación cerraba la divergencia decisor/reportero. **Unificó la FUENTE
(`VIV_JSON`) y no el PREDICADO:**

```
DECIDE    jq     index($i)        → comparación EXACTA
INFORMA   bash   grep -qx "$id"   → el id se trata como REGEX
```

Y el charset de ids **permite el punto**, así que `CVE-2020-2849.` casa la línea
`CVE-2020-28493`. Reproducido en BSD grep y en GNU grep 3.11:

```
⏰ excepción VENCIDA: CVE-2020-2849.   ← sano (grep -qxF)
🧹 excepción HUÉRFANA: … bórrala        ← mutante -qx: manda BORRAR una exención vencida
✓ excepción aplicada: CVE-2020-2849.   ← mutante con los DOS grep: dice que una vencida aplica
```

**Reintroduje la clase dentro del arreglo cuya lección era ésa.** Cerrado con `grep -qxF` en
`:260` y `:262` — una letra.

## Y mi primer assert para eso TAMBIÉN estaba muerto

Lo até a `"✓ aplicada"` y pasaba con el mutante puesto: **según cuál de los dos `grep` se rompa,
la mentira sale como `✓ aplicada` o como `🧹 HUÉRFANA`**. Un assert atado a uno de los dos
mensajes no defiende nada. La propiedad que discrimina no es el texto: es que **una VENCIDA se
reporte VENCIDA**.

## Los tres huecos de cobertura que el gate midió, y su mutante

| hueco | mutante que sobrevivía | ahora |
|---|---|---|
| **N-2** el reportero siempre podía decir VENCIDA | `VIVOS → ""` → verde | **2 fallos** |
| **N-3** revertir C1 entero dejaba verde | `nf` Y `resto` fuera → verde | **2 fallos** |
| **N-4** la guarda de entrega | quitar su `exit 2` → verde | **1 fallo** |

Los tres asserts de mensaje que ya existían eran **todos positivos-para-VENCIDA**, así que un
reportero que dijera *"VENCIDA"* siempre los satisfacía los tres. Es *"un patrón muerto colapsa
los dos mundos en uno"*, aplicado a mi propia batería.

## Mutación final — 29 asserts

```
R1  grep -qxF → -q   (VIVOS)          1 fallo   ✔
N1  grep -qxF → -qx  (VIVOS)          1 fallo   ✔
R1b grep -qxF → -q   (IDS_PRESENTES)  1 fallo   ✔
R3  VIVOS → ""                        2 fallos  ✔
N9b quita `nf` Y `resto`              2 fallos  ✔
N5a la entrega ya no aborta           1 fallo   ✔
N5b se quita la guarda de entrega    12 fallos  ✔
N10 quita SOLO `nf`                   verde — correcto: las dos mitades son redundantes,
                                      `resto` caza el mismo caso. No es hueco.
N4  `.bloqueantes` no numérico        verde — **RONDA 3: era FALSO que no se pudiera disparar.**
                                      Un STREAM de dos documentos JSON hace que `jq -r .bloqueantes`
                                      emita `0\n0`. Cuesta un `printf`. Cerrado con assert.
```

## Lo demás del reporte, aceptado y aplicado

- **N-5** — el comentario listaba `| head` como disparador cubierto y **no lo está** (la salida
  son ~5 KB y cabe en el buffer de pipe de 64 KB, así que jq nunca ve EPIPE). Se nombra el
  límite en el propio comentario.
- **N-6** — `nf` era global; declarado `local`.
- **N-7** — el guardia del fixture emitía **1 `fail`** donde el criterio cuenta 2 asserts: un
  guardia no puede romper el conteo que defiende. Ahora emite 2.
- **La matriz de plataformas de la ronda 1 estaba mal etiquetada**: alpine es **busybox**, no
  GNU, y **faltaba ubuntu/GNU+mawk, que es la que ejecuta `selftest.yml:76`**. Añadida.
- **N-8** (flake de medianoche UTC: `TOPE` se calcula al arrancar y `HOY_EPOCH` en cada
  invocación) — **reconocido y NO arreglado**. Ventana pequeña, no observada, y el arreglo toca
  el cálculo de fechas de toda la suite. Queda declarado.
- **N-9** — el gatekeeper no consiguió reproducirlo y yo tampoco lo intenté. **Levantado, no
  cerrado.**

**NO verificado, igual que en la ronda 1:** nada de esto ha corrido en un runner de Actions.
Tres plataformas en local y docker, y sólo eso.


---

# RONDA 3 — el gate refutó una de mis dos lecturas benignas, y al medir la otra encontró lo grande

**Veredicto recibido:** NO-GO, *"por poco y con dos ítems concretos"*. 7 de 7 cerrados; quedaban H-1 y H-2.

## H-1 — declaré IMPOSIBLE algo que cuesta un `printf`

Escribí que la guarda de `.bloqueantes` *"no se puede disparar desde fuera sin mutar el filtro"*.
Falso, y con la peor forma:

```bash
printf '{"vulnerabilities":{}}{"vulnerabilities":{}}\n' | … --filter e.txt npm
→ rc=2 · "⛔ ERROR INTERNO: '.bloqueantes' no es un número ('0\n0')"
```

`jq -e .` acepta un stream y `jq -e 'has(...)'` devuelve el rc del **último** documento, así que la
forma pasa las dos validaciones y llega a la guarda.

> **Declarar un hueco es correcto; declararlo IMPOSIBLE cierra la puerta a que alguien lo cubra.**
> Es la clase del `medido:` sin `depende-de:` — una afirmación sobre el mundo que nadie iba a volver
> a mirar. Cerrado con assert.

**Su límite, heredado tal cual:** que la forma **alcance** la guarda está medido; que
`npm audit`/`composer audit`/`pip-audit` emitan un stream de dos documentos en alguna condición real
**no lo está**. El assert vale igual —la guarda existe para lo que no previmos— pero no se vende
como disparador observado.

## H-2 — el veredicto del parser DEPENDÍA DE LA PLATAFORMA, con la suite 29/29 verde en las tres

Reproducido por mí, independiente (rc=1 = línea válida, rc=2 = rechazada):

```
razón = solo U+00A0 (espacio duro)   macOS RECHAZA · alpine acepta  · ubuntu acepta
razón = solo U+2003 (em space)       macOS acepta  · alpine RECHAZA · ubuntu acepta
```

**Tres plataformas, tres veredictos sobre el mismo fichero.** Causa medida: las dos mitades de C1
usan **definiciones distintas de "blanco"**. El separador de campos de awk da `NF=3` en las tres —el
NBSP nunca separa—, pero el `[[:space:]]` de `sub()` **sí** varía: BSD/UTF-8 lo borra, busybox y mawk
no. **`nf` es la mitad portable; `resto` era la variable.**

**Y la dirección era la mala: el RUNNER es el permisivo**, justo en el campo que **es** el rastro de
auditoría — la razón, que es donde se pega prosa copiada de un advisory, de Slack o de un PDF.

**Arreglado, no documentado.** Un gate que va a 17 repos no puede opinar según el `awk` de la
máquina. Se exige explícitamente **al menos un carácter imprimible ASCII**, evaluado por bytes en
locale C (`LC_ALL=C tr -dc '!-~'`). Más estricto que antes, y **el mismo veredicto en todas partes**.
Con control positivo: una razón real con acentos y emoji sigue siendo válida — el predicado no
suspende a los sanos.

```
tras el arreglo:  macOS 33/33 · alpine 33/33 · ubuntu 33/33
```

## H-3 — el crédito que no reclamé

HEAD **también rechazaba falsamente** líneas legítimas de 3 campos que mezclan tab y espacio
(`'GHSA-x<TAB>2026-12-01 razon'` → HEAD `rc=2`, árbol `rc=0`). El arreglo cierra **las dos
direcciones** y el comentario sólo documentaba el fail-open. Un gate que empieza a aceptar lo que
antes rechazaba merece la línea, aunque el cambio sea a mejor.

## H-4 — la fecha hardcodeada

Los dos asserts de C1 llevaban `2026-10-02` fijo, contra la convención que el propio fichero declara.
Sustituida por `$VIGENTE`. **Y al hacerlo rompí el balance de comillas** —concatené en vez de usar
`%s`—, lo que dejó la suite con `unexpected EOF`. La clase de citación, otra vez, en el arreglo de
una nota menor. Lo cazó `bash -n`, no la lectura.

## H-5 · N-8 · N-9

- **H-5**: el gate corrió él mismo el control positivo del assert de `>&-` (misma entrada, salida
  abierta → `rc=0`). Hoy pasa por su razón. Sin cambios.
- **N-8** (flake de medianoche UTC): el gate **no lo considera bloqueante** y da su razón — la
  dirección del fallo es un **rojo falso**, ruidoso y no silencioso. Se queda declarado. *Si la suite
  llega a correr en un cron nocturno, cambia la respuesta.*
- **N-9**: sigue sin reproducir por ninguno de los dos. **Levantado, no cerrado.**

## Su propio fallo, que es el que produjo H-2

Leyó una fila del diferencial como *imposible* y **fue a perseguirla en vez de publicarla**: la
contradicción estaba en su modelo de qué mitad decidía, no en los datos. **Sin perseguir esa fila,
H-2 no aparece.** Es *"un resultado imposible se persigue, no se publica"* dando fruto en vez de
evitando un error.

**NO verificado, tercera ronda consecutiva:** nada de esto ha corrido en un runner de Actions.


---

# RONDA 4 — `LC_ALL=C` estaba en la mitad que no era el problema

**Veredicto recibido:** NO-GO por **un ítem**, con el remedio ya medido por el gate.

## H-6 — puse el locale en `tr`, y `tr` nunca fue el problema

`tr` da lo mismo en las tres plataformas (14 entradas raras medidas). **Los cuatro `awk` de `:94-97`
seguían corriendo con el locale del entorno**, y BSD awk bajo `en_US.UTF-8` revienta con bytes UTF-8
inválidos. Quedaba **1 divergencia sobre 28 líneas**, y en la misma dirección mala:

```
razón = bytes inválidos + texto ASCII legítimo   macOS RECHAZA · alpine acepta · ubuntu acepta
```

**Y la mitad peor no es el veredicto:** ese awk escribe `towc: multibyte conversion failure` **por
stderr, que ES el canal del reporte de excepciones** (`err()` → stderr → `$GITHUB_STEP_SUMMARY`).
Cuatro líneas de tripas encima de un diagnóstico que además **nombraba la causa equivocada** —
hablaba de *"espacios invisibles"* con la razón llena de texto legible.

**Arreglado acotando a los cuatro `awk`, no al script entero:** el `sort -k1,1` del dedup también
corre con el locale del entorno, y el gate declaró que su invariancia la **razonó sin medirla
adversarialmente**. Cambiar la colación de un `sort` que no hace falta tocar sería ensanchar el
cambio sobre una suposición ajena.

**Y por qué no lo documenté, que era la salida que el propio gate me dio en la ronda 2:** su
argumento es mío y es correcto — *"un gate que va a 17 repos no puede opinar según el `awk` de la
máquina"*. Documentar una divergencia residual de la misma clase, en el mismo campo y con el runner
otra vez del lado permisivo, contradice la decisión que acababa de tomar.

## El límite de los dos asserts nuevos, declarado en el propio test

Medido por mutación (quitar `LC_ALL=C` de los cuatro awk):

```
macOS/BSD        2 fallos  ← los dos, por su razón
ubuntu/mawk      TODO VERDE ← mawk no se atraganta: NINGUNO dispara
```

> **El CI —que corre en ubuntu— jamás cazaría esta regresión: sólo la caza quien desarrolla en un
> Mac.** Es la asimetría inversa del par NBSP/EM, y va escrita en el test porque **un assert que
> sólo tiene dientes en una plataforma se lee igual que uno que los tiene en las tres.**

## H-7, H-8, H-9

- **H-7** · el contrato de la razón sube al bloque `FORMATO` de la cabecera, con la consecuencia
  escrita: *una razón íntegramente en cirílico, japonés o sólo emoji se rechaza*. Es una decisión de
  **política**, no sólo de portabilidad, y el gate tenía razón en que no podía vivir en un `die`.
- **H-8** · dos defectos en el diagnóstico del propio test: la etiqueta estaba en la rama `ok` y no
  en la `fail` (en ubuntu caían los dos y salían **dos líneas idénticas**), y `"rc=$?"` dentro del
  `||` imprime el estado del `[`, no el del script. Es *"el reporte no depende del RESULTADO"*
  **dentro de los diagnósticos del test que persigue esa clase**, cuarta ronda seguida.
- **H-9** · la razón pasa por `%s`; la línea entera era la cadena de **formato** de `printf`.

## Las tres respuestas del gate a mis preguntas, y las dos que me corrigen

1. **Sí suspende a sanos**, acotado: japonés, ruso, chino, sólo emoji, `ñ` sola, `«»`. Para esta
   flota no es un caso vivo —toda prosa española o inglesa lleva letras ASCII— y ahora está escrito.
2. **Mi sospecha estaba AL REVÉS.** Escribí que el par quizá defendiera *"sólo en dos de tres"*.
   Defiende en las **tres**: cada plataforma ejercita **la mitad** del par y **ubuntu ejercita las
   dos**. Ninguno sobra.
3. **7/8/9 veredictos movidos**, todos de la familia de la razón y todos hacia estricto. Nada fuera.

## Su fallo de la ronda, que es el de siempre

Su primera descomposición usaba `2>&1`, así que **el error de awk entró en la variable** y lo leyó
como comportamiento del script. Lo rehizo contra la herramienta real y el resultado honesto salió
**peor** que el artefacto — *"pero eso fue suerte: la lectura contaminada era publicable tal cual"*.

```
macOS 35/35 · alpine 35/35 · ubuntu 35/35 · shellcheck limpio
```

**NO verificado, cuarta ronda:** sin runner de Actions. **N-9 sigue levantado y sin reproducir.**
**El alcance de H-6 es "hay una divergencia residual y ésta es su causa", no "ésta es la única"** —
28 líneas, 3 plataformas, sin gawk y sin otros locales.


---

# RONDA 5 — GO, y la mitad de ENFORCEMENT que el gate recomendó sin bloquear

**Veredicto recibido: GO** para `v3.1.0`, con una recomendación para el mismo commit.

## Me corrigió el límite que yo mismo había declarado: es peor

Escribí que los dos asserts de H-6 no tenían dientes en ubuntu. Medido por él:

```
quitando LC_ALL=C   macOS 2 fallos  ·  alpine TODO VERDE  ·  ubuntu TODO VERDE
```

**1 de 3, no 2 de 3.** Las dos plataformas Linux se quedan verdes.

## Su respuesta a mi pregunta, en dos mitades, y la segunda es la que faltaba

**Sí cuenta como red** — el defecto que vigilan *sólo existe en BSD awk*, así que pedirle a Linux
que lo ejercite es pedirle al CI reproducir un bug que ahí no está. Es *"medir donde el fallo se ve,
no donde no se ve"*.

**Pero no es ENFORCEMENT:** *"un detector que no escribe su salida en el backlog no está desplegado,
está instalado"*. Un assert que no puede ponerse rojo en el único entorno que bloquea merges está
**instalado**. Si alguien borra el `LC_ALL=C` por *"ruido"*, el CI lo deja pasar en verde.

**La mitad que falta no es otro assert de comportamiento: es uno ESTÁTICO.** La propiedad a proteger
no es *"el defecto no se reproduce"* —sólo observable en BSD— sino *"los cuatro awk del parser llevan
`LC_ALL=C`"*, que es **contable en cualquier plataforma**:

```
grep -c "| LC_ALL=C awk '{"  →  4        grep -c "| awk '{"  →  0
```

Añadido, y **con su aviso pegado en el propio test**: un assert sobre el TEXTO del fuente es la clase
del `includes()` que esta flota ya se comió. **Se suma, no sustituye** — el de comportamiento
demuestra que la propiedad importa donde puede, el estático la hace cumplir en todas partes.

**Verificado por mutación en el entorno que importa:** quitándole el `LC_ALL=C` a **un** awk,
**ubuntu** ahora falla (`✗ un awk del parser perdio su LC_ALL=C`). Antes se quedaba verde.

## Lo que el gate cerró de SU parte, y por qué importa

El `sort -k1,1` que en la ronda 3 dejó como *"razonado, no medido"*. Lo midió: **4 locales × 2
plataformas** con ids construidos para colacionar distinto — el dedup es invariante, 3/3 en los ocho
casos.

> **Mi negativa a ensanchar el cambio al `sort`, citando su propio límite, fue lo que le obligó a
> medirlo.** Un límite declarado por un revisor es una deuda del revisor, no una excusa del
> implementador para tocar de más ni para no tocar.

## Sus otras dos respuestas

- **`LC_ALL=C` no movió nada más:** 1 movida sobre 24 en macOS (la intencionada), **0 en alpine, 0 en
  ubuntu**, con corpus ampliado a blancos Unicode **entre** id y fecha (U+00A0, U+2003, U+3000,
  U+202F, bytes inválidos dentro del id y de la fecha). Ids y fechas intactos.
  **Bonus del mecanismo:** la razón *"sólo NBSP"* antes se rechazaba por **dos caminos distintos**
  según la plataforma; ahora por uno. *Un veredicto correcto por una sola razón vale más que el
  mismo veredicto por dos.*
- **Barrido de `%` con denominador:** 46 `printf` · 44 con formato literal · **2 no literales,
  examinados los dos**. El interno `printf "$bytes"` **es correcto ahí** —literal de la propia línea
  del bucle, única forma de emitir esos bytes—; el defecto de H-9 era el externo, arreglado. Y el
  `awk` de `:193` no puede romper el JSON: control ejecutado, id con comilla → `rc=2` antes de llegar.

```
macOS 36/36 · alpine 36/36 · ubuntu 36/36 · shellcheck limpio
```

## Lo que queda ABIERTO tras el GO, y no se entierra con él

- **NADA de esto ha corrido en un runner de Actions.** Cuatro rondas, macOS + docker. Es el límite
  que los dos declaramos y el que sigue en pie.
- **N-9** (el `|| true` de `IDS_PRESENTES`, si ese `jq` muriera todas las excepciones se reportarían
  `🧹 HUÉRFANA … bórrala`) — **sin reproducir por ninguno de los dos en cuatro rondas.** Es lo único
  de toda la revisión que ni el gate ni yo hemos conseguido tocar. **Levantado, no cerrado.**
- **El realismo del disparador de H-1** —que un `audit` real emita un stream de dos documentos— sigue
  **no medido**. El assert vale igual: la guarda existe para lo que no previmos.
- **N-8** (flake de medianoche UTC) declarado, con su condición: *si la suite llega a correr en un
  cron nocturno, cambia la respuesta*.
- **El alcance de la invariancia es "24 líneas, 3 plataformas, locales {C, POSIX, en_US, es_ES}"**,
  no "total". Sin gawk, sin WSL.

**El tag NO se publica desde aquí.** El GO es del gate sobre el código; publicar `v3.1.0` es una
acción hacia fuera en un repo público y la decide el dueño.
