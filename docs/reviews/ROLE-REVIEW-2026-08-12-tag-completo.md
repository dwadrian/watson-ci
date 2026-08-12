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

## El hallazgo, y por qué es peor de lo reportado

Se reportó que el linaje `v3` no tenía `.github/actions/`. Al construir el check salió el alcance
real:

```
✓ v2   (alias MÓVIL)
✗ v1  v1.0.0  v1.1.0  v1.1.1  v2.0.0  v2.0.1  v2.2.0  v2.2.1  v3  v3.0.0
```

**`alcance` existe en un solo ref, y es el alias móvil.** Los diez tags inmutables no la tienen.

Eso **invierte el consejo de seguridad**: fijar una versión concreta o un SHA —la práctica
correcta, la que este mismo repo predica— da un CI roto, mientras que el alias móvil, el
desaconsejado, funciona. No es un release malo: es que **la forma segura de consumir este repo era
la que fallaba**.

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
