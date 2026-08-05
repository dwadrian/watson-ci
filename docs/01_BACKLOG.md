# BACKLOG — watson-ci

> **Cola única.** Si un pendiente no está aquí, no existe. Bitácoras y reviews son evidencia
> histórica, no cola: lo que sobreviva de ellas se copia aquí **con su origen**.
>
> Estados: `## Ahora` (WIP, ideal 1) · `## Siguiente` (comprometido) · `## Después` ·
> `## Bloqueado` (nombra a QUIÉN desbloquea) · `## Decisión del dueño`

## Bloqueado

- [ ] **Mover el alias `v2` para que la flota reciba el filtro de solo-docs** — el cambio está en
  `main` pero los 17 repos consumen `@v2`, y mover un tag exige `git push --force origin v2`, que
  el harness bloquea. **Desbloquea: Adrián**, con
  `git tag -f v2 <sha> && git push --force origin v2`. Hasta entonces el sangrado de minutos
  sigue exactamente igual.
  · origen: `docs/bitacoras/BITACORA-2026-08-05-paths-solo-docs.md`

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
