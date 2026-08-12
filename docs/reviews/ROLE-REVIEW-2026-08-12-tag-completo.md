# ROLE-REVIEW: `tests/tag-completo.test.sh` — un tag no puede prometer lo que no contiene

**Roles-Validated: GO** — **y el alcance de este GO es estrecho a propósito. Léelo antes de usarlo
como precedente.**

## Qué respalda este GO, y qué NO

**No corrió un loop multi-rol sobre este código.** Lo digo primero para que nadie lea la marca como
algo que no es. Lo que lo respalda:

| | |
|---|---|
| **Origen** | reincidencia **medida dos veces** por `makro_logistica` (07-ago con `v2`, 11-ago con `v3`), con el hallazgo aceptado íntegro las dos |
| **Es aditivo** | no cambia ningún veredicto existente. Añade un paso al selftest de **este** repo; no toca recetas, ni gates de la flota, ni nada que corra en los 17 |
| **Control verificado ejecutando** | `rc=0` sobre `HEAD` (completo) y **`rc=1` sobre `v3`** (roto). No es un check que solo sabe decir que sí |
| **Blast radius** | el CI de watson-ci. Cero repos afectados |

⛔ **Este GO no es precedente para saltarse el loop en algo que sí toque las recetas.** Un cambio
que altere el veredicto de CI de la flota necesita el loop completo con el rol de seguridad.

## El hallazgo — y DOS diagnósticos míos que hubo que corregir

Se reportó que el linaje `v3` no tenía `.github/actions/`. Confirmado. Pero mis dos primeras
lecturas del alcance fueron **falsas**, y las dos las corrigió mirar la salida en vez de fiarme:

**Diagnóstico 1, falso: *"diez tags rotos"*.** `alcance` nació el **2026-08-05**; seis de esos tags
son de **julio**. Un tag anterior al nacimiento de una acción **no le debe nada**, y avisar de eso
es ruido que entrena a ignorar el check — el fallo que este archivo existe para evitar.

**Diagnóstico 2, falso: *"v3 se cortó de un commit viejo"*.** `v3.0.0` es un tag **anotado creado
el 03-ago**. La historia real es más aburrida: `alcance` se añadió a `main` el 05-ago, **después**
de publicar v3, y solo el alias `v2` se movió para incluirla. **Nunca se publicó un `v3.x` con
ella.** Nadie borró nada.

⚠️ **Y al arreglar el primero me pasé de rosca:** eximir *"todo lo anterior al nacimiento"* eximía
también a `v3`, o sea que **mi corrección apagaba la detección del caso que motivó el check**.
Fail-open en mi propio guard, en el mismo archivo.

**La señal correcta es la REGRESIÓN:** que el alias mayor **más nuevo** carezca de algo que el
anterior sí tiene. Eso es lo que muerde, porque dependabot propone el alias más alto como *"lo
último"* y el consumidor **acaba con menos de lo que tenía**.

```
· v1 ofrece: (ninguna)
· v2 ofrece: alcance
· v3 ofrece: (ninguna)
  ⚠️ REGRESION: v3 NO ofrece 'alcance', y v2 sí.
```

Cero ruido sobre julio, y el caso real detectado.

**Nadie está roto hoy**: el único consumidor real de la acción es `makro_logistica`, SHA-pinneado
al commit que sí la tiene. El daño llega **por dependabot**, que propone el alias roto a cada repo
con actualizaciones de `github-actions`.

## Tres decisiones de diseño, con su porqué

**1 · Bloquea sobre el ref a publicar; lista los tags rotos SIN bloquear.**
No es blandura. Si fallara sobre la historia, el selftest quedaría en **rojo permanente**, y un gate
que bloquea todo empuja a desactivarlo — el anti-patrón que este repo lleva semanas cazando, y que
el propio reportante describió con el `--no-verify`. Arreglar diez tags publicados exige **mover
tags inmutables**: decisión del dueño, no de un test. Pero **se imprimen siempre y con nombre**: un
hueco que no se ve es el que se queda.

**2 · Las acciones se derivan del árbol, no de una lista a mano.**
Una lista a mano es lo que se olvida de actualizar — que es exactamente la clase de este incidente.

**3 · Verifica hacia AFUERA.** Es la mitad que no había visto y que aportó quien lo reportó: el
release de `v3` probablemente no rompió nada *dentro* de watson-ci (sus workflows usan rutas
relativas); rompió a **todo consumidor que fije ese tag**. La pregunta correcta es *"¿lo que la
flota referencia sigue existiendo en este ref?"*, no *"¿mis workflows pasan?"*.

## Límites declarados

1. **Los diez tags siguen rotos.** El check los detecta y no los arregla. Decisión del dueño, con
   coste en las dos direcciones: retaguear `v3.0.0` rompe la inmutabilidad que `tags-inmutables`
   protege; dejarlo deja publicada una versión que apaga gates.
2. **Esto vive en la rama `gate-roles`, no en `main`.** Hasta que se mergee, protege en local.
3. **No cubre el enmascaramiento de `needs:`**, que es el otro lado del mismo incidente y sigue
   abierto: el consumidor no distingue *"la acción no resolvió"* de *"el alcance dijo que no hacía
   falta"* — los dos se ven `skipping`, y el log del job **no contiene ni la palabra `alcance`**.
4. **Solo mira `.github/actions/*/`.** Si mañana este repo publica otra clase de artefacto
   consumible (una plantilla, un script referenciado por ruta), el check no lo cubre y habrá que
   ampliarlo — con la misma disciplina de derivarlo del árbol.
