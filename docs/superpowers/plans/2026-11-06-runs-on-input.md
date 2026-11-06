# Input `runs-on` en las recetas — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** que `verify-{node,python,php}.yml` corran en runners propios via un input `runs-on`, sin cambiar nada para quien no lo pasa.

**Architecture:** input JSON `runs-on` → `runs-on: ${{ fromJSON(inputs.runs-on || '"ubuntu-latest"') }}` en cada job. Lo que la receta asumía preinstalado (jq) lo instala ella misma, versión y sha256 fijos. Lo que no se puede fijar (git, coreutils, sudo para setup-php) se comprueba al inicio y falla con diagnóstico; se documenta en README.

**Tech Stack:** GitHub Actions (workflow_call), bash, python3 stdlib (para el test y la descarga verificada de jq).

**Spec:** el encargo de dwadrian/fabrica#2425 (contrato de 5 puntos).

## Global Constraints

- Input: `runs-on`, `type: string`, `required: false`, `default: '"ubuntu-latest"'` (JSON).
- Sin el input, comportamiento IDÉNTICO (mismo runner; jq 1.7.1 = el de ubuntu-24.04).
- Ningún archivo nuevo en `tools/` que la receta ejecute: el default `tooling-ref: v2` no lo contendría y rompería a los callers con default. Todo lo nuevo de la receta va inline.
- Commits con «Refs dwadrian/fabrica#2425».

## Review Focus

1. Caller pasa `runs-on: ${{ vars.RUNS_ON }}` con la variable SIN definir → llega `''` (no el default) → `fromJSON('')` revienta. Por eso el `|| '"ubuntu-latest"'` en la expresión; el test lo exige.
2. Runner sin `git` → `actions/checkout` cae a descarga REST sin `.git` → merge-base vacío → SAST degrada a ADVISORY en silencio. Precheck de git obligatorio.
3. Runner self-hosted sin `sudo` → setup-php se cuelga esperando un candado (`sudo mkdir`, medido 11+ min en ci-makro). Precheck `sudo -n true` solo en PHP y solo si `runner.environment == self-hosted`.
4. Runner arm64 → el jq fijado debe elegir binario por arquitectura o fallar explícito, nunca bajar el de amd64.
5. Un job nuevo añadido a la receta con `runs-on: ubuntu-latest` literal → el test debe contarlo (todos los jobs, no solo `verify`).

---

### Task 1: test `tests/runs-on.test.sh` (ROJO primero)

**Files:** Create `tests/runs-on.test.sh`; Modify `.github/workflows/selftest.yml` (paso nuevo en `decisiones`).

- [ ] Para cada receta: cada job bajo `jobs:` tiene exactamente un `runs-on:` y es `${{ fromJSON(inputs.runs-on || '"ubuntu-latest"') }}`.
- [ ] El input `runs-on` existe con `type: string`, `required: false` y un default que, decodificado como JSON, es `"ubuntu-latest"`; el fallback de la expresión decodifica a lo mismo.
- [ ] Toda receta que invoque `jq` lo instala antes con el paso fijado (versión 1.7.1 + sha256 amd64/arm64).
- [ ] Auto-mutantes: el checker corre sobre copias mutadas y DEBE fallar con (a) `runs-on: ubuntu-latest` literal, (b) default cambiado, (c) fallback `||` quitado, (d) job extra con literal.
- [ ] Correr: debe FALLAR sobre el árbol actual.

### Task 2: recetas

**Files:** Modify los 3 `verify-*.yml`.

- [ ] Input `runs-on` + expresión en `runs-on:`.
- [ ] Paso `🧰 Requisitos del runner` primero: git≥2.18, bash, coreutils/findutils/tar/gzip; en PHP, `sudo -n true` si self-hosted.
- [ ] PHP y Python: paso `Instalar jq 1.7.1 (sha256 fijado)` tras setup-python, en `$RUNNER_TEMP/watson-ci-bin` → `$GITHUB_PATH`.
- [ ] Test en VERDE; shellcheck sobre el test; actionlint (binario fijado por checksum) sobre los workflows.

### Task 3: README — sección «Runner propio» (qué necesita, qué instala la receta, cómo pasarlo).

### Task 4: 2 rondas de revisión con subagente con mandato de refutar → PR (no fusionar) → `.fin`.
