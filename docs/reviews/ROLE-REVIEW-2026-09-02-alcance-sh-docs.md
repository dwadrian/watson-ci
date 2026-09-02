# ROLE-REVIEW — un `.sh` bajo `docs/` no es documentación

> **Roles-Validated: GO (auditor ofensivo + code-reviewer + gatekeeper, 2 rondas, 2026-09-02)**

## Cobertura

| rol | quién | independiente |
|---|---|---|
| **auditor ofensivo + code-reviewer** | subagente `opus`, **entregó por `SendMessage`** | ✅ |
| descubridor original | `coffee_framework_prod`, `FEEDBACK-2026-08-18` | ✅ externo |
| implementación, TDD y mutación | el orchestrator | ❌ |

## El agujero

El `case` era `docs/*|*.md`. **En POSIX el `*` cruza la barra**, así que todo lo que viva bajo
`docs/` contaba como documentación:

```
docs/scripts/deploy.sh              →  DOC  (salta SAST, tests y lint)
docs/scripts/verify-multiagent.sh   →  DOC
```

Eso no es documentación: es **el código que distribuye el harness a la flota**. Reportado el
**2026-08-18** y **14 días sin atender**.

## Ronda 1 · auditoría ofensiva — GO condicionado, con dos bloqueantes míos

### 🔴 H1 · el test era CIEGO a 7 de las 8 extensiones

Mi mutante era *«quitar la rama nueva»* — el más grueso posible. La batería de 9 del auditor:

```
quitar *.php · *.py · *.js+*.mjs · *.yml+*.yaml · *.bash   →  TODAS sobrevivían en verde
*.sh → *.sh*                                                →  sobrevivía
```

**Y los casos que parecían cubrirlas no cubren nada:** `src/app.php` y `.github/workflows/ci.yml`
ya salían `CODIGO` por el `*)` de siempre, así que **mutar la rama no los mueve**.

→ 8 casos nuevos: `docs/x.{php,py,js,mjs,bash,yml,yaml}` → `CODIGO`, y `docs/notas.shell` → `DOC`
para fijar el límite superior. **Los 11 mutantes mueren, cada uno por su caso.**

### 🟠 H2 · backticks dentro de comillas dobles, en el mensaje de fallo

```
echo "⛔ no pude extraer el `case` de $SCRIPT"
  → imprime:  ⛔ no pude extraer el  de /ruta      ← la palabra desapareció
  → shellcheck: SC1073/SC1072 (ERROR)
```

**El anti-patrón que la doctrina de watson documenta, cometido dentro del gate.** La ruta OK nunca
lo toca, así que el fichero pasaba verde con su mensaje de fallo roto. Mitigante que el auditor
midió: el `exit 1` **sí** ocurre — es fail-closed, solo el mensaje estaba roto.

### 🟡 H4 · una cifra que se contradecía consigo misma

El comentario decía «22 repos» tres veces; `selftest.yml` dice 16 y 17. Medido: **17 repos git,
13 con caller-stub**. → La cifra sale del comentario: **una cifra en un comentario envejece sola.**

## El hallazgo que yo no esperaba, y acota mi propia afirmación

```
semgrep --config p/security-audit sobre docs/scripts (12 ficheros .sh)  →  ESCANEADOS: 0
control positivo, mismo comando + p/php sobre app/Console              →  escaneados: 11
```

> **Semgrep, tal como estas recetas lo configuran, no parsea shell.** El paso SAST omitido no
> habría analizado **ni una línea** de esos scripts.

Decir *«pasaban sin SAST»* es literalmente cierto y **operativamente vacío para `.sh`**. Donde sí
había impacto: los `.py/.php/.js/.yml` bajo `docs/`, y **el paso de tests de la receta de node**.

**La clasificación se arregla igual, y a propósito:** la regla no debe depender del ruleset de hoy.
Escrito en el código con su `· depende-de:`.

## Lo que el auditor midió y yo no

**El ahorro no se apaga** — 3.694 commits reales, 17 repos, 180 días:

```
saltos "solo docs" con el case VIEJO   1298
con el NUEVO                           1292      →  99,54 % conservado
los 6 perdidos: todos de watson, todos VERDADEROS POSITIVOS
```

**`secrets` y `dep-audit` corren SIEMPRE en las tres recetas** — extrajo cada step con su `if:`.
**El arreglo es monotónico en la dirección segura**: la rama nueva solo incrementa `NO_DOCS`, así
que estructuralmente no puede convertir un `CODIGO` en `DOC`.
Y **`*.yml` no sobra**: hay exactamente **1** bajo `docs/` en toda la flota, y es una plantilla de
workflow. Dispara 1 vez en 3.694 commits y esa vez acierta.

## Lo que este commit NO cierra

**El arreglo no llega a nadie todavía.** `v2` (`f038b39`), `v3`, `main` y `origin/main` **no lo
tienen**. Hace falta merge a `main` + `git push --force origin v2` — que **el harness me bloquea**
y corre el dueño.

**Y dos repos no lo reciben ni moviendo el alias:** `mcp_security_scan` (`@v2.2.1`, tag inmutable)
y `makro_erpnext` (`@SHA` pineado). Van como pendiente `dueño: <repo>`.

**Encolado, no bloqueante:** `*.sql` y `*.html` bajo `docs/` — 6 ficheros vivos en 3 repos.

## VEREDICTO: **GO para commitear** · el hueco **NO** queda cerrado hasta que el alias se mueva
