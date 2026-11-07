# ROLE-REVIEW — runner propio falla cerrado (fabrica#2425, ronda 2 de PR #3)

> **Roles-Validated: GO** (decisión PROVISIONAL del operador, 2026-11-06, por delegación del dueño: «los bots deciden PROVISIONAL cuando el dueño no está»).
> Ronda 5, revisor independiente de otro modelo (ChatGPT/Codex, solo lectura, mandato de REFUTAR) sobre `1898c56`:
> **P1 y P2 CERRADOS** en runner propio; el camino **ALOJADO no cambia** de comportamiento. Sus 3 bloqueantes son
> evasiones **ofuscadas** del comprobador estático (`echo "$(python -u …)"`, `read -a "SIN_"PIP`,
> `printf -v "ALO"JADO`) que **no están en las recetas**: quedan declaradas como LÍMITE (ver abajo), no como defecto.

Commit revisado: `76c309f`.

## Origen

Codex dio NO PASA sobre `01e607b`:
- **P1.** En un runner sin PHP, setup-php ejecuta un `install.sh` de `releases/latest`/`@main` sin
  checksum.
- **P2.** En un runner sin Python en el tool cache, setup-python ejecuta un `setup.sh` sin checksum
  y después `pip install --upgrade pip` sin versión.

## Cobertura

| rol | quién | independiente |
|---|---|---|
| ronda 1 · seguridad supply-chain en GitHub Actions | subagente nuevo, mandato REFUTAR | ✅ |
| ronda 2 · ídem | subagente nuevo, sin el contexto de la ronda 1 | ✅ |
| rondas 3-4 · gatekeeper, trazabilidad por hallazgo | subagente nuevo; la ronda 4 la hizo el mismo agente, reanudado | ✅ |
| implementación, TDD y mutación | el autor | ❌ |

## Trazabilidad (veredictos del gatekeeper en la ronda 4)

| hallazgo | estado |
|---|---|
| P1, P2 | CERRADO |
| R1-H1 pip-audit sin `--disable-pip` instala con pip | CERRADO en propio (verificado contra pip-audit 2.10.1) |
| R1-H2..H6 | CERRADO |
| R2-H1 `-I` en python | PARCIAL en la ronda 4 → la regla 6h (allowlist) mata las variantes del gate **sin revisar** |
| R2-H2 `sh -e` | CERRADO |
| R2-H3 SIN_PIP / pip-audit | PARCIAL en la ronda 4 → regla 6h, **sin revisar** |
| R2-H4, H5, H8 | CERRADO |
| R2-H6 plugins de composer | PARCIAL en la ronda 4 (`ALOJADO=true` reasignado) → regla 6h, **sin revisar** |
| R2-H7 pylock `--locked` sin ruta | DIFERIDO (`docs/01_BACKLOG.md` § Decisión del dueño); el gate lo da por aceptable |
| endurecer el camino alojado | DIFERIDO; decisión del dueño |

Sin verificar: el parseo YAML con un parser real (no hay PyYAML ni actionlint, y ruby necesita
aprobación). Tampoco se ejecutaron `tests/{alcance-clasificacion,audit-exceptions,gate-roles,tag-completo}.test.sh`
ni `expect-audit-decision.sh`: necesitan aprobación. Por grep, ninguno lee los archivos cambiados.
`tests/runs-on.test.py` da `✅ 267 afirmaciones`.


## LÍMITE declarado (ronda 5)

`tests/runs-on.test.py` defiende contra **regresiones accidentales** de las recetas: alguien vuelve a poner
`setup-*` en modo descarga, quita `-I`, `--disable-pip`, `--no-plugins`/`--no-scripts` o reasigna `ALOJADO`
de forma directa. **No** defiende contra un mantenedor con permiso de escritura que **ofusca** a propósito el shell
(nombres construidos por concatenación, `printf -v`, `read -a`, ejecución dentro de `$(…)` en un `echo`).
Un comprobador estático de shell no puede cerrar esa clase: perseguir cada variante agrandaría la lista sin fin
(ronda 4 → 6h → ronda 5 encontró 4 nuevas). Esa clase la cubren el **code review** de cada cambio en las recetas y
**este mismo gate de roles** (todo cambio de distribución exige ROLE-REVIEW).
Falso positivo conocido (Codex r5): `printf "%s\n" "python listo"` se rechaza aunque solo imprime texto; es una
restricción de mantenimiento, no rompe a consumidores. Si molesta, issue aparte.
Informe: `revisiones/rescate-20261105/codex-wci3r2.txt` (plan del operador).
