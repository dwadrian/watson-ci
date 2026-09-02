# ROLE-REVIEW: cablear `audit-exceptions.sh` en las tres recetas

**Roles-Validated: NO — el loop NO convergió, y esta marca lo dice en vez de disimularlo.**

Escalado al dueño con los ítems abiertos, que es lo que el protocolo manda cuando un loop no cierra.

## Por qué no hay GO

Se despacharon **6 roles en 2 rondas**. **Entregó uno.** Los otros cinco emitieron
`idle_notification` con cero contenido — incluso tras pedirles el reporte explícitamente, y tras
bajar el listón a *"tres líneas en texto plano, sin formato"*.

| Ronda | Rol | Entregó |
|---|---|---|
| 1 | Auditor ofensivo de cadena de suministro / CI | ✅ **NO-GO, 14 hallazgos** (2 críticos, 4 altas) |
| 1 | Code-reviewer de shell portable | ❌ idle ×2, sin contenido |
| 1→2 | Re-despacho del anterior | ❌ idle ×2, sin contenido |
| 2 | Release gatekeeper | ❌ idle ×2, sin contenido |
| 2 | Code-reviewer de shell (3.er intento) | ❌ idle, sin contenido |
| 2 | Encargo acotado: «¿qué asserts no discriminan?» | ❌ idle, sin contenido |

Firmar GO aquí sería certificar una cobertura que no ocurrió. El propio skill lo dice: *un
verificador lanzado que no entrega es **peor** que no lanzarlo*, porque da falsa sensación de
cobertura. Y el harness no lo distinguiría: valida que **exista** el artefacto con la marca, no que
la revisión haya pasado. Anotado como **P0** en el backlog de watson — afecta a todos los loops
futuros, no a esta entrega.

## Lo que SÍ respalda el plan corregido

**1 · La ronda 1 fue devastadora y se integró entera.** 14 hallazgos, todos cerrados en el plan con
su corrección concreta. **Ocho los reproduje ejecutando** antes de integrarlos — no se actúa sobre
un reporte de subagente sin comprobarlo:

| Hallazgo | Cómo se confirmó |
|---|---|
| El cableado apuntaba a un directorio **ya borrado** → `exit 127` en los 15 repos | borrado en `:138/:149/:165`, paso de deps en `:208/:236/:230` |
| El tag `v2` no contiene ningún `tools/*.sh`, y era el default de `tooling-ref` | `git ls-tree --name-only v2 tools/` |
| «Cero repos usan los inputs» era **falso** | `selftest.yml:54` usa `pip-audit-ignore-vuln` |
| Perder `set -e` abría un **fail-open** | reproducido: `jq` roto → «composer audit OK» con `rc=0` |
| `AUDIT_LEVEL` sí cambia el veredicto | `audit-exceptions.sh:25` |
| El symlink derrota el «solo en la raíz» | el filtro **acepta** un symlink a archivo regular: `rc=0` |
| bash 3.2 mata el bucle sin guarda | `3.2.57` real: `reqfiles[@]: unbound variable` |
| El README prometía una revisión en PR que la flota no tiene | `gh api …/branches/main/protection` → **404** |

**2 · Cobertura mecánica, hecha a mano por ausencia del rol.** Lo que se pudo convertir en ejecución
se ejecutó:

- **Mutación de los asserts.** Dos scripts defectuosos fabricados a propósito: *"exime de más"*
  cazado por **6 de 9** asserts, *"exime de menos"* por **5 de 9**. Cada clase de defecto cae por
  varios asserts independientes. Y un script ausente (`rc=127`) lo rechazan los tres valores
  esperados, porque se compara por **igualdad exacta** — la lección de los cuatro incidentes
  previos, aplicada.
- **bash 3.2.** La guarda `${arr[@]+"${arr[@]}"}` funciona; `num_o_muere` aguanta 12 entradas
  hostiles y rechaza en fail-closed.
- **Fidelidad de los stubs.** El stub de `npm` extraído a ejecutable real: el filtro lo procesa,
  `rc=0`, dos excepciones reportadas como aplicadas.

⚠️ El propio arnés de mutación falló primero y casi falsea el resultado: dio *"1 de 1"* porque **en
zsh una variable sin comillas no se parte en palabras**. Repetido bajo `/bin/bash` con un array.

## Lo que queda ABIERTO — decisión del dueño

1. **Sin revisión adversarial de shell por un tercero.** La mutación cubre clases gruesas de
   defecto; **no** cubre la lectura fina de cada assert, ni una lente distinta sobre el código
   propuesto. Esta casilla está vacía y no me la puedo autoconceder: revisar mis propios asserts
   buscando cuáles no prueban nada es exactamente el sesgo que el rol adversarial existe para
   romper.
2. **Sin gatekeeper independiente.** La trazabilidad de los 14 hallazgos la verifiqué yo sobre mis
   propias correcciones. Encontré una contradicción así (`num_o_muere` mandada copiar «igual que en
   los dos anteriores» cuando npm no la tiene ni la necesita), lo cual demuestra que el
   auto-chequeo sirve — y también que no basta: en este sistema, **cada ronda ha encontrado que la
   corrección anterior traía el siguiente bug**.
3. **El plan no se ha ejecutado.** Todo lo anterior valida el *plan*; el código real no existe aún.

## Qué haría falta para un GO legítimo

Un rol de shell y un gatekeeper que **entreguen**, sobre el plan ya corregido. Mientras el
mecanismo de subagentes no devuelva reportes, la alternativa honesta es que un humano lea el plan —
o implementarlo aceptando por escrito que estas dos casillas van vacías, que es una decisión de
riesgo del dueño y no del modelo.
