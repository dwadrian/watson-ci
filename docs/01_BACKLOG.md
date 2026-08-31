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

_Ninguna abierta. El movimiento del alias `v2` vive en `## Bloqueado`
porque tiene dueño y comando concretos — no falta decidir nada, falta ejecutarlo._
