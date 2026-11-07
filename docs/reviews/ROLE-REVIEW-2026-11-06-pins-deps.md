# ROLE-REVIEW — pins de pip-audit y semgrep (fabrica#2425, PR #4)

> **Roles-Validated: GO**, otorgado por el operador el 2026-11-06 tras la revisión cruzada.

Autor: ChatGPT/Codex. Regeneró los archivos con `uv pip compile --generate-hashes` y los verificó en local. El operador hizo el commit y ajustó las excepciones.

Revisor independiente: Claude (Sonnet), de otra familia que el autor, con mandato de REFUTAR, en solo lectura sobre `02fc9ac`. Veredicto: **PASA**.
- (1) Las 5 excepciones no tienen arreglo posible: semgrep 1.184.0 es la última versión publicada en PyPI y fija `mcp==1.29.0` y `opentelemetry-api~=1.37.0`.
- (2) Ninguna excepción se filtra a los callers: solo `selftest.yml` las pasa, y los callers no tienen `tools/requirements-*.txt`.
- (3) Los archivos están regenerados con hashes, sin paquetes huérfanos.
- (4) Ninguna compuerta se debilitó: se declaran una a una y no hay ningún interruptor global.

Menores atendidos: el comentario contradictorio en `tools/requirements-semgrep.txt:10` (corregido en este commit) y este mismo ROLE-REVIEW.

Menor diferido: las excepciones del selftest no caducan solas, porque `tools/audit-exceptions.sh` no está cableado. La limitación ya existía antes de este PR y se revisa en el próximo bump de semgrep.

Informe completo: `revisiones/rescate-20261105/claude-wci4.txt` (plan del operador).
