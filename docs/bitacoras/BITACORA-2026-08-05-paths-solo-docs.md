# BITACORA: omitir SAST y tests en pushes de solo documentación

## Metadata

| Campo | Valor |
|-------|-------|
| Task  | paths-solo-docs |
| Fecha | 2026-08-05 |
| Origen | reporte medido de `makro_logistica`; urgencia del dueño: ~1000 de 3000 min consumidos |

## Resumen

`makro_logistica` midió que 12 de 16 commits de un día fueron documentación pura y que cada uno
disparó los tres workflows: ~11.6 min × 12 ≈ **140 de 221 minutos** gastados en correr pest,
eslint y semgrep contra Markdown. Su diagnóstico del gasto es correcto.

Su arreglo propuesto —`paths-ignore` en los tres workflows— **no se implementó como lo pidieron**,
y por una razón concreta, no estética.

## Por qué NO `paths-ignore`

**1. Los secretos deben escanearse siempre, y hoy tengo la prueba.** El CI de watson estuvo
**cuatro días en rojo** por un hallazgo de `p/secrets` en `docs/superpowers/plans/*.md`. Con
`paths-ignore: docs/**` en el workflow de security, ese hallazgo habría sido **invisible**. Una
clave pegada en un `.md` es una fuga igual que en un `.php`.

**2. `paths-ignore` atasca los required status checks.** Un push filtrado deja el check en
"Expected — waiting for status" indefinidamente. Con un `if:` de paso, el job siempre corre y
siempre reporta.

**3. El trigger vive en el stub de cada repo; el `if:` vive en la receta.** Como `paths-ignore`
habría que tocarlo en 17 stubs y derivaría. Como paso de la receta es **un cambio para toda la
flota** y no puede desincronizarse.

## Qué se omite y qué no

| | Costo | Regla |
|---|---|---|
| 🔑 Secrets | segundos | **SIEMPRE** — una clave en un `.md` es una clave |
| 📦 dep-audit | segundos | **SIEMPRE** — un CVE nuevo aparece sin que cambie tu código; es el caso guzzle que reportó zigter_back |
| 🛡️ SAST high/critical | minutos | omitido en solo-docs |
| 🟡 SAST advisory | minutos | omitido en solo-docs |
| 🧪 Tests / lint | minutos | omitido en solo-docs |

En la medición de `makro_logistica`, security se lleva el **55%** de los minutos, así que el
recorte cae donde está el gasto.

## Dos decisiones de diseño que son el fondo del cambio

**Fail-safe por construcción, no por un `if` extra.** `solo_docs=true` **solo** se escribe cuando
se prueba que todo es documentación. Si el paso muere por cualquier motivo, la salida queda sin
definir, `!= 'true'` evalúa a cierto y **se corre todo**. Un fallo de detección jamás puede
traducirse en "no escanees".

**Los patrones están hardcodeados.** Como input, un repo podría ensanchar su propio hueco — que es
exactamente la clase que esta misma receta ya vigila con el aviso de `.semgrepignore`.

## El conteo NO usa `grep -qv`

Medido hoy: en un shell con `grep` aliasado a `ugrep`, `grep -qv` sobre entrada **multilínea**
devuelve la respuesta **contraria** a `/usr/bin/grep`. Produjo un conteo imposible —"0 commits con
código" en un día donde sí los hubo— y estuve a punto de construir sobre esa cifra. El
clasificador usa `case` de POSIX, determinista en cualquier shell. Es la tercera vez en el día que
una herramienta de medición miente en este entorno.

## Verificación

Se ejecutó el script **extraído del YAML**, no una copia, para que el dedent del heredoc entrara
también en la prueba:

| Caso | Resultado |
|---|---|
| `73de714` (2 archivos, docs) | `solo_docs=true` |
| `16b7985` (1 archivo, docs) | `solo_docs=true` |
| `f496186` (10 archivos, 6 código) | `solo_docs=false` |
| rama nueva (`before` en ceros) | `false` |
| base ajena (no está en el clon) | `false` |
| sin base | `false` |
| diff vacío (merge/revert) | `false` |
| evento no contemplado (`schedule`) | `false` |
| `pull_request` con base real | clasifica bien |

Los seis modos de fallo caen a `false`, o sea **corre todo**.

## Límite declarado

- El `pip install` de semgrep sigue corriendo en solo-docs, porque el escaneo de secretos lo
  necesita. El ahorro es de los pasos caros, no del arranque del job.
- No se midió el reparto interno entre "secrets" y "SAST" en un repo grande. En watson secrets
  tarda ~9 s, pero watson es chico. **Cada repo debe medir su propio reparto** antes de dar por
  hecho el ahorro; el paso ya emite un `::notice::` que dice qué se omitió.
- El alias `v2` **no está movido**: mover un tag exige `git push --force`, que el harness bloquea.
  Hasta que el dueño lo mueva, la flota sigue consumiendo la versión anterior.

## Staff Hours Estimados

| Fase | Tiempo | Notas |
|------|--------|-------|
| Análisis | 0.4hr | Verificar el reporte, medir watson, refutar `paths-ignore` |
| Diseño | 0.3hr | Dónde acotar sin abrir hueco; fail-safe por construcción |
| Admin | 0.2hr | Bitácora |
| Implementación | 0.3hr | Tres recetas |
| Debugging | 0.2hr | Mezcla inválida de `${{ }}` con `&&`; nombre del paso |
| Testing | 0.5hr | Script extraído del YAML + 6 modos de fallo |
| Review | 0.2hr | — |
| **Total** | **2.1hr** | |

## Archivos Modificados

- `.github/workflows/verify-node.yml` — paso de alcance + guardas en SAST y tests
- `.github/workflows/verify-php.yml` — paso de alcance + guardas en SAST
- `.github/workflows/verify-python.yml` — paso de alcance + guardas en SAST
