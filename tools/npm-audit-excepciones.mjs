#!/usr/bin/env node
// npm-audit-excepciones.mjs — `npm audit` de verify-node con excepciones que CADUCAN.
//
// FUENTE ÚNICA: la tabla «Excepciones vigentes» de docs/SEGURIDAD-DEPENDENCIAS.md del repo que
// llama (columnas: Aviso | Paquete | Severidad | Motivo | Quién la aceptó | Fecha de revisión).
// Este archivo viaja con el tooling-ref de la receta: el repo auditado solo aporta la TABLA, nunca
// el código que decide. Solo stdlib de Node, sin dependencias.
//
// USO
//   node npm-audit-excepciones.mjs --hay-tabla <md>                       exit 0 = hay tabla · 3 = no hay
//   node npm-audit-excepciones.mjs --tabla <md> --audit <json> [--hoy YYYY-MM-DD]
// EXIT  0 nada bloqueante · 1 quedan high/critical sin excepción vigente · 2 ERROR (tabla mal
//       formada, o el audit no es un reporte utilizable). El 2 es distinto del 1 a propósito.
//
// REGLA: una fila exime un hallazgo si coincide el aviso (el GHSA de la `url` del aviso; el título NO
// cuenta y npm no trae CVE, así que una fila CVE queda huérfana: usa el GHSA) Y el paquete afectado, y su fecha de revisión es >= hoy y <= hoy+90 días (UTC). Vencida o fuera de
// ventana: no exime. Fila mal formada o cabecera distinta: ERROR (un typo no ensancha el hueco).
// Al eximir un aviso se RECALCULA la severidad de los paquetes que dependen de él (npm la deriva
// de `via`): sin eso, `astro` seguiría «high» por un aviso ya exento.
import { appendFileSync, existsSync, readFileSync, statSync } from 'node:fs';

const MAX_DIAS = 90;
const MAX_BYTES = 256 * 1024;
const SEV = { info: 0, low: 1, moderate: 2, high: 3, critical: 4 };
// Una severidad que no reconocemos NO es inocua: se trata como crítica.
const sevnum = (s) => (typeof s === 'string' && Object.hasOwn(SEV, s) ? SEV[s] : 4);
const NOMBRE_SEV = ['info', 'low', 'moderate', 'high', 'critical'];

const ENCABEZADO = /^#{1,6}[ \t]*Excepciones vigentes[ \t]*$/;
const ID_AVISO = /^(?:GHSA(?:-[0-9a-z]{4}){3}|CVE-\d{4}-\d{4,})$/i;
const IDS_EN_TEXTO = /GHSA(?:-[0-9a-z]{4}){3}|CVE-\d{4}-\d{4,}/gi;
const PAQUETE = /^(?:@[a-z0-9._~-]+\/)?[a-z0-9._~-]+$/i;
const COLUMNAS = ['aviso', 'paquete', 'severidad', 'motivo', 'quien', 'fecha'];

class Fallo extends Error {}
const falla = (m) => { throw new Fallo(m); };

const plano = (s) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
const celdas = (l) => l.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '').split(/(?<!\\)\|/).map((c) => c.trim());
const sinEnlace = (c) => c.replace(/^\[([^\]]*)\](?:\([^)]*\))?$/, '$1').replaceAll('`', '').trim();
const vacia = (c) => /^[—–-]*$/.test(c);

function dia(fecha) { // días desde 1970-01-01 (UTC), NaN si no es una fecha real (2026-02-30 no pasa)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) return NaN;
  const d = new Date(`${fecha}T00:00:00Z`);
  return Number.isNaN(+d) || d.toISOString().slice(0, 10) !== fecha ? NaN : Math.floor(+d / 864e5);
}

function leer(ruta) {
  if (!existsSync(ruta)) return null;
  if (!statSync(ruta).isFile()) falla(`${ruta} no es un fichero regular`);
  if (statSync(ruta).size > MAX_BYTES) falla(`${ruta} pesa más de ${MAX_BYTES} bytes`);
  return readFileSync(ruta, 'utf8');
}

// → null si no hay encabezado; si lo hay, las líneas `| ...` de su sección [{n, texto}].
function seccion(md) {
  const L = md.split(/\r?\n/);
  const ini = L.flatMap((l, i) => (ENCABEZADO.test(l) ? [i] : []));
  if (ini.length === 0) return null;
  if (ini.length > 1) falla('hay más de un encabezado «Excepciones vigentes»');
  const fin = L.findIndex((l, i) => i > ini[0] && /^#{1,6}\s/.test(l));
  return L.slice(ini[0] + 1, fin < 0 ? undefined : fin)
    .map((texto, k) => ({ n: ini[0] + 2 + k, texto }))
    .filter((f) => f.texto.trimStart().startsWith('|'));
}

function parseTabla(md, hoy) {
  const filas = seccion(md);
  if (!filas || filas.length === 0) return [];
  const cab = celdas(filas[0].texto).map(plano);
  const esperado = ['aviso', 'paquete', 'severidad', 'motivo', 'quien la acepto', 'fecha de revision'];
  if (cab.length !== 6 || !cab.every((c, i) => c.startsWith(esperado[i]))) {
    falla(`línea ${filas[0].n}: la cabecera no es «Aviso | Paquete | Severidad | Motivo | Quién la aceptó | Fecha de revisión»`);
  }
  if (!filas[1] || !/^\|[\s:|-]+\|?$/.test(filas[1].texto.trim())) falla(`línea ${filas[0].n + 1}: falta la fila separadora de la tabla`);
  const vistas = new Map();
  for (const { n, texto } of filas.slice(2)) {
    const c = celdas(texto);
    if (c.length !== 6) falla(`línea ${n}: se esperan 6 columnas y hay ${c.length}`);
    const [aviso, paquete, , , , fecha] = c.map((x, i) => (i < 2 ? sinEnlace(x) : x));
    if (!ID_AVISO.test(aviso) && c.slice(1).every(vacia)) continue; // fila marcador «(ninguna todavía) | — | …»
    if (!ID_AVISO.test(aviso)) falla(`línea ${n}: «${aviso.slice(0, 40)}» no es un GHSA-xxxx-xxxx-xxxx ni un CVE-AAAA-NNNN`);
    if (!PAQUETE.test(paquete)) falla(`línea ${n}: paquete «${paquete.slice(0, 40)}» inválido (sin comodines)`);
    if (c.slice(2, 5).some(vacia)) falla(`línea ${n}: severidad, motivo y quién la aceptó no pueden ir vacíos`);
    const d = dia(fecha);
    if (Number.isNaN(d)) falla(`línea ${n}: fecha de revisión «${fecha.slice(0, 20)}» inválida (AAAA-MM-DD y que exista)`);
    const clave = `${aviso.toLowerCase()}|${paquete.toLowerCase()}`;
    // Duplicados: gana la fecha MÁS TEMPRANA; un merge descuidado no puede extender una exención.
    if (!vistas.has(clave) || d < vistas.get(clave).d) vistas.set(clave, { clave, aviso: aviso.toUpperCase(), paquete: paquete.toLowerCase(), fecha, d });
  }
  return [...vistas.values()].map((e) => ({ ...e, dias: e.d - hoy, estado: e.d < hoy ? 'vencida' : e.d - hoy > MAX_DIAS ? 'lejana' : 'vigente' }));
}

// Severidad efectiva por paquete tras eximir. `vigentes` = Set de «aviso|paquete».
// Un paquete que NO alcanza ningún aviso exento conserva la severidad que dice npm (jamás se
// recalcula a la baja por una lectura propia de `via`); solo los que sí alcanzan uno se recalculan.
function severidades(V, vigentes, aplicadas) {
  const nombres = Object.keys(V);
  const vias = (p) => (Array.isArray(V[p]?.via) ? V[p].via : []);
  const base = {}; // severidad por avisos propios no exentos
  const toca = {}; // ¿tiene un aviso propio exento?
  for (const p of nombres) {
    let max = 0;
    for (const v of vias(p).filter((x) => typeof x !== 'string')) {
      const s = v && typeof v === 'object' ? sevnum(v.severity) : 4;
      const pkg = String(v?.name ?? p).toLowerCase();
      // Solo la URL del aviso: el TÍTULO es texto libre y puede MENCIONAR otro aviso («Incomplete fix for
      // CVE-…»), y un aviso nuevo no hereda la exención de otro. El JSON de npm no trae el CVE.
      const ids = String(v?.url ?? '').match(IDS_EN_TEXTO) ?? [];
      const clave = ids.map((i) => `${i.toLowerCase()}|${pkg}`).find((k) => vigentes.has(k));
      if (clave) { toca[p] = true; if (s >= SEV.high) aplicadas.add(clave); } else max = Math.max(max, s);
    }
    base[p] = max;
  }
  for (let i = 0; i < nombres.length; i++) { // alcanzabilidad a punto fijo: el grafo puede tener ciclos
    for (const p of nombres) if (vias(p).some((v) => typeof v === 'string' && toca[v])) toca[p] = true;
  }
  let sev = base;
  for (let i = 0; i < nombres.length; i++) {
    sev = Object.fromEntries(nombres.map((p) => [p, Math.max(base[p], ...vias(p).filter((v) => typeof v === 'string').map((v) => (v in V ? sev[v] : sevnum(V[p]?.severity))))]));
  }
  return Object.fromEntries(nombres.map((p) => [p, toca[p] ? sev[p] : sevnum(V[p]?.severity)]));
}

function main(args) {
  const val = (k) => (args.includes(k) ? args[args.indexOf(k) + 1] : undefined);
  if (args[0] === '--hay-tabla') {
    const md = leer(val('--hay-tabla') ?? falla('falta la ruta'));
    return md !== null && seccion(md) !== null ? 0 : 3;
  }
  const rutaTabla = val('--tabla') ?? falla('uso: --tabla <md> --audit <json> [--hoy AAAA-MM-DD]');
  const rutaAudit = val('--audit') ?? falla('falta --audit <json>');
  const hoy = val('--hoy') ? dia(val('--hoy')) : Math.floor(Date.now() / 864e5);
  if (Number.isNaN(hoy)) falla('--hoy inválido');

  // Fail-closed: sin un reporte de `npm audit` utilizable NO hay veredicto verde. Lo decide la FORMA
  // del JSON, no el exit code de npm (rc=1 es el camino normal y también el de ENOLOCK).
  let rep;
  try { rep = JSON.parse(readFileSync(rutaAudit, 'utf8')); } catch (e) { falla(`npm audit no produjo JSON utilizable (${e.code ?? e.message.slice(0, 80)})`); }
  if (rep?.error) falla(`npm audit devolvió un error, no un reporte (${rep.error.code ?? rep.error.summary ?? 'sin código'})`);
  const V = rep?.vulnerabilities;
  if (!V || typeof V !== 'object' || Array.isArray(V)) falla('el JSON de npm audit no tiene «vulnerabilities»');

  const md = leer(rutaTabla);
  const tabla = md === null ? [] : parseTabla(md, hoy);
  const vigentes = new Set(tabla.filter((e) => e.estado === 'vigente').map((e) => e.clave));
  const aplicadas = new Set();
  const sev = severidades(V, vigentes, aplicadas);
  const sinExcepciones = severidades(V, new Set(), new Set());
  const bloquean = (s) => Object.keys(V).filter((p) => s[p] >= SEV.high);
  const m = rep.metadata?.vulnerabilities;
  const declarados = Number(m?.high ?? 0) + Number(m?.critical ?? 0);
  if (bloquean(sinExcepciones).length < declarados) falla('el informe es incoherente: su metadata declara más high/critical de los que se leen');

  const log = (l) => console.log(`  ${l}`);
  console.log(`npm audit con excepciones de ${rutaTabla} (hoy ${new Date(hoy * 864e5).toISOString().slice(0, 10)} UTC, ventana ${MAX_DIAS} días)`);
  const resumen = [];
  for (const e of tabla) {
    const quedan = `${e.dias} día(s)`;
    if (e.estado === 'vencida') log(`⏰ VENCIDA: ${e.aviso} (${e.paquete}) venció ${e.fecha}; vuelve a bloquear`);
    else if (e.estado === 'lejana') log(`⛔ FUERA DE VENTANA: ${e.aviso} (${e.paquete}) revisión ${e.fecha} a ${quedan}, máx ${MAX_DIAS}; no exime`);
    else if (aplicadas.has(e.clave)) { log(`✓ excepción aplicada: ${e.aviso} (${e.paquete}), revisar antes de ${e.fecha} (${quedan})`); resumen.push(`- \`${e.aviso}\` (${e.paquete}): revisar antes de ${e.fecha}`); }
    else log(`🧹 HUÉRFANA: ${e.aviso} (${e.paquete}) no casa con ningún aviso high/critical; ¿ya hay parche? bórrala`);
  }
  if (process.env.GITHUB_STEP_SUMMARY && resumen.length) {
    try { appendFileSync(process.env.GITHUB_STEP_SUMMARY, `### npm audit: excepciones aplicadas\n${resumen.join('\n')}\n`); } catch { /* el resumen es cortesía; el veredicto no depende de él */ }
  }
  const malos = bloquean(sev);
  if (malos.length === 0) { console.log(`✓ sin high/critical bloqueantes (${aplicadas.size} excepción(es) aplicada(s)).`); return 0; }
  console.error(`⛔ ${malos.length} paquete(s) high/critical sin excepción vigente:`);
  for (const p of malos) {
    const via = (Array.isArray(V[p]?.via) ? V[p].via : []).map((v) => (typeof v === 'string' ? `vía ${v}` : (String(v?.url ?? '').match(IDS_EN_TEXTO)?.[0] ?? 'aviso sin GHSA'))).join(', ');
    console.error(`  - ${p} (${NOMBRE_SEV[sev[p]]}): ${via}`);
  }
  return 1;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (e) {
  if (!(e instanceof Fallo)) console.error(`⛔ ERROR INTERNO: ${e?.stack ?? e}`);
  else console.error(`⛔ ${e.message}`);
  process.exitCode = 2;
}
