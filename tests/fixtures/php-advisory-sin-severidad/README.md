Fixture para el bloqueo de advisories SIN campo `severity`.

No se commitea un `composer.lock` con una dependencia vulnerable real (seria distribuir una
version vulnerable en un repo publico). El caso se prueba con un JSON de `composer audit`
sintetico, alimentado al mismo `jq` que usa la receta — la logica de decision es lo que se
verifica, no la descarga de composer.

Ver `tests/expect-audit-decision.sh`.
