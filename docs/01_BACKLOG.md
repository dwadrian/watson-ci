# BACKLOG — watson-ci

> **Cola única.** Si un pendiente no está aquí, no existe. Bitácoras y reviews son evidencia
> histórica, no cola: lo que sobreviva de ellas se copia aquí **con su origen**.
>
> Estados: `## Ahora` (WIP, ideal 1) · `## Siguiente` (comprometido) · `## Después` ·
> `## Bloqueado` (nombra a QUIÉN desbloquea) · `## Decisión del dueño`

## Ahora

_Sin trabajo activo declarado. El siguiente que arranque se mueve aquí._

## Siguiente


- [ ] **Medir el reparto secrets vs SAST en un repo grande antes de prometer el ahorro** — en
  watson el escaneo de secretos tarda ~9 s, pero watson es chico y el ahorro se estimó sobre eso.
  En un repo donde `semgrep` tarda 6.4 min no se sabe cuánto es secrets (que sigue corriendo
  siempre) y cuánto SAST (que ahora se omite). Si secrets fuera la mayor parte, el ahorro real
  sería mucho menor que lo anunciado. El paso ya emite un `::notice::` con lo que omitió: basta
  comparar dos runs. **No dar el ahorro por bueno sin este número.**
  · origen: `docs/bitacoras/BITACORA-2026-08-05-paths-solo-docs.md` — límite declarado

## Después


- [ ] **El `pip install` de semgrep sigue corriendo en pushes de solo-docs** — es necesario porque
  el escaneo de secretos lo usa, así que el ahorro es de los pasos caros, no del arranque del job
  (~25-40 s por run). Cachear el entorno de semgrep recortaría ese piso.
  · origen: `docs/bitacoras/BITACORA-2026-08-05-paths-solo-docs.md` — límite declarado

- [ ] **El canario `selftest.yml` es ciego a los bugs cross-repo, por construcción** — corre
  DENTRO de watson-ci, donde toda ruta relativa al repo resuelve. Por eso salió **verde** el
  mismo día en que la receta rompió el CI de los 17 repos con
  `pip install -r tools/requirements-semgrep.txt` (ese archivo solo existe aquí; un workflow
  reutilizable ejecuta sus `run:` sobre el checkout del CALLER). El canario debe invocar la
  receta desde un repo **distinto** — un fixture mínimo o un repo de la flota designado— o
  seguirá dando falsos verdes en la única clase que de verdad importa aquí.
  · origen: incidente 2026-08-05, alias `v2` movido y revertido

- [ ] **Decidir el reparto cuando el filtro guarda JOBS enteros, no pasos** — reportado por
  makro_logistica al cablear la composite action: sus workflows son locales y guardan el **job**
  completo, así que al omitir también se salta `composer audit` / `npm audit`. Eso contradice la
  regla de watson ("dep-audit corre SIEMPRE": un CVE nuevo aparece sin que cambie tu código — es
  el caso guzzle que ellos mismos reportaron). **Recomendación**: partir el dep-audit a un job
  propio sin guarda; cuesta segundos y conserva la propiedad. La alternativa —aceptar el hueco—
  hay que declararla, no heredarla por omisión.
  · origen: feedback de makro_logistica, 2026-08-06

## Bloqueado


- [ ] **Mover el alias `v2` para que la flota reciba el filtro de solo-docs** — el cambio está en
  `main` pero los 17 repos consumen `@v2`, y mover un tag exige `git push --force origin v2`, que
  el harness bloquea. **Desbloquea: Adrián**, con
  `git tag -f v2 <sha> && git push --force origin v2`. Hasta entonces el sangrado de minutos
  sigue exactamente igual.
  · origen: `docs/bitacoras/BITACORA-2026-08-05-paths-solo-docs.md`

## Decisión del dueño

- [ ] **¿Endurecer también el camino ALOJADO como el propio?** (fabrica#2425, ronda 2). En runner
  propio, la receta ya no descarga sin verificar. En **alojado** se dejó intacto a propósito,
  porque cambiarlo altera decisiones del gate en toda la flota. Ahí siguen tres cosas, todas
  anteriores a #2425:
  1. `pip-audit --no-deps -r` sin `--disable-pip` crea un venv, hace `pip install --upgrade pip`
     sin versión e instala los requirements del caller, ejecutando el `setup.py` de cualquier
     sdist (pip-audit 2.10.1, `_dependency_source/requirement.py:161-177`,
     `_virtual_env.py:119-134`). Con `--disable-pip`, un requisito sin `==` pasaría a ROJO.
  2. `composer audit` carga plugins de `vendor/composer/installed.json` (falta `--no-plugins`).
  3. setup-python/setup-node/setup-php descargan sin checksum si la versión no está en el tool
     cache de la imagen.
  · origen: revisión Codex + refutación, ronda 2 de `operador/runs-on-input-20261106` (PR #3)
- [ ] **`pylock.toml` siempre da ROJO en verify-python** (anterior a #2425, diferido aquí). Se llama
  `audit_source "pylock.toml" --locked --strict` sin ruta de proyecto, y pip-audit 2.10.1 aborta
  con `--locked flag can only be used with a project path` (`_cli.py:463-465`). Falla cerrado,
  pero el camino `--locked` nunca ha funcionado. Arreglarlo (pasar `.`) cambia el veredicto en
  alojado: por eso queda aquí y no en el PR de runners propios.
  · origen: gatekeeper de la ronda 2, PR #3
