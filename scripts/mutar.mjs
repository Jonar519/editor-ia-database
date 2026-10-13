// Pruebas de mutación dirigidas: rompe a propósito cada regla crítica del catálogo
// (mutations/catalogo.json), corre el comando de pruebas indicado y exige que falle.
// Uso: node scripts/mutar.mjs [id...]
//
// Resultados:
//   DETECTADA     las pruebas fallaron con la mutación (lo esperado)
//   SOBREVIVE     las pruebas pasaron con la regla rota: falta un test (hace fallar el comando)
//   EQUIVALENTE   declarada equivalente en el catálogo con su motivo; no cuenta como detectada
// El archivo original se restaura siempre (también con Ctrl+C) y se verifica por hash.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/**
 * @typedef {{
 *   id: string, regla: string, archivo: string, buscar: string, reemplazo: string,
 *   comando: string, equivalente?: string
 * }} Mutacion
 */

/** @param {string} texto */
const sha = (texto) => createHash('sha256').update(texto).digest('hex');

/**
 * @param {string} texto
 * @param {string} buscado
 */
function contar(texto, buscado) {
  let n = 0;
  for (let i = texto.indexOf(buscado); i !== -1; i = texto.indexOf(buscado, i + 1)) n++;
  return n;
}

/** @type {{ ruta: string, original: string } | undefined} */
let pendiente;
function restaurar() {
  if (pendiente) {
    writeFileSync(pendiente.ruta, pendiente.original);
    pendiente = undefined;
  }
}
for (const senal of /** @type {const} */ (['SIGINT', 'SIGTERM'])) {
  process.on(senal, () => {
    restaurar();
    process.exit(130);
  });
}

/** @type {{ mutaciones: Mutacion[] }} */
const catalogo = JSON.parse(readFileSync(path.join(RAIZ, 'mutations', 'catalogo.json'), 'utf8'));
const ids = process.argv.slice(2);
const elegidas = ids.length ? catalogo.mutaciones.filter((m) => ids.includes(m.id)) : catalogo.mutaciones;
if (elegidas.length === 0) {
  console.error('No hay mutaciones que correr.');
  process.exit(2);
}

/** @type {{ m: Mutacion, estado: string }[]} */
const resultados = [];
for (const m of elegidas) {
  const ruta = path.join(RAIZ, m.archivo);
  const original = readFileSync(ruta, 'utf8');
  const apariciones = contar(original, m.buscar);
  if (apariciones !== 1) {
    console.error(`${m.id}: el texto a buscar aparece ${apariciones} veces en ${m.archivo} (debe ser exactamente 1).`);
    resultados.push({ m, estado: 'ERROR' });
    continue;
  }
  const hashOriginal = sha(original);
  pendiente = { ruta, original };
  writeFileSync(ruta, original.replace(m.buscar, () => m.reemplazo));
  process.stdout.write(`${m.id} ${m.regla}\n   corriendo "npm run ${m.comando}"… `);
  let codigo;
  try {
    const r = spawnSync('npm', ['run', m.comando], { cwd: RAIZ, shell: true, encoding: 'utf8', timeout: 600_000 });
    codigo = r.status ?? 1;
  } finally {
    restaurar();
  }
  if (sha(readFileSync(ruta, 'utf8')) !== hashOriginal) {
    console.error(`\nABORTADO: ${m.archivo} no quedó restaurado.`);
    process.exit(3);
  }
  const detectada = codigo !== 0;
  const estado = detectada ? 'DETECTADA' : m.equivalente ? 'EQUIVALENTE' : 'SOBREVIVE';
  console.log(estado);
  resultados.push({ m, estado });
}

console.log('\nResumen de mutaciones');
for (const { m, estado } of resultados) {
  console.log(`  ${estado.padEnd(11)} ${m.id}  ${m.regla}${estado === 'EQUIVALENTE' ? `\n              motivo: ${m.equivalente}` : ''}`);
}
const cuenta = (/** @type {string} */ e) => resultados.filter((r) => r.estado === e).length;
console.log(
  `\nDetectadas ${cuenta('DETECTADA')}, sobreviven ${cuenta('SOBREVIVE')}, equivalentes ${cuenta('EQUIVALENTE')}, errores ${cuenta('ERROR')} (de ${resultados.length}).`,
);
process.exit(cuenta('SOBREVIVE') + cuenta('ERROR') === 0 ? 0 : 1);
