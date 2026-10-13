// Uso:
//   node scripts/huella.mjs tomar <etiqueta>              guarda .huellas/<etiqueta>.json de la base de desarrollo
//   node scripts/huella.mjs comparar <etiqueta> [<otra>]  compara contra el estado actual (o contra <otra>)
// La conexión es de solo lectura: la huella no puede escribir en la base de desarrollo.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { conexion, nombreBaseDesarrollo } from './lib/config.mjs';
import { conectarSoloLectura, existeBase } from './lib/bases.mjs';
import { compararHuellas, tomarHuella } from './lib/huella.mjs';

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.huellas');

/** @typedef {import('./lib/huella.mjs').Huella} Huella */

/** @param {string} etiqueta */
function archivoDe(etiqueta) {
  if (!/^[A-Za-z0-9._-]+$/.test(etiqueta)) throw new Error(`Etiqueta inválida: "${etiqueta}" (usa letras, números, . _ -).`);
  return path.join(DIR, `${etiqueta}.json`);
}

/** @returns {Promise<Huella | { base: string, existe: false }>} */
async function huellaActual() {
  const base = nombreBaseDesarrollo(process.env);
  const conn = conexion(process.env, base);
  if (!(await existeBase(conn, base))) return { base, existe: false };
  const cliente = await conectarSoloLectura(conn);
  try {
    return await tomarHuella(cliente, base);
  } finally {
    await cliente.end();
  }
}

/** @param {Huella | { base: string, existe: false }} h */
function resumen(h) {
  if (!('hashEsquema' in h)) return `base ${h.base}: no existe`;
  const total = Object.values(h.filas).reduce((a, b) => a + b, 0);
  return `base ${h.base}: ${Object.keys(h.filas).length} tablas, ${total} filas, esquema ${h.hashEsquema.slice(0, 16)}…`;
}

async function main() {
  const [accion, etiqueta, otra] = process.argv.slice(2);
  if (accion === 'tomar' && etiqueta) {
    const h = await huellaActual();
    await mkdir(DIR, { recursive: true });
    await writeFile(archivoDe(etiqueta), `${JSON.stringify(h, null, 2)}\n`);
    console.log(`Huella "${etiqueta}" guardada. ${resumen(h)}`);
    return 0;
  }
  if (accion === 'comparar' && etiqueta) {
    const antes = JSON.parse(await readFile(archivoDe(etiqueta), 'utf8'));
    const despues = otra ? JSON.parse(await readFile(archivoDe(otra), 'utf8')) : await huellaActual();
    console.log(`Antes:   ${resumen(antes)}`);
    console.log(`Después: ${resumen(despues)}`);
    const ambasExisten = 'hashEsquema' in antes && 'hashEsquema' in despues;
    const difs = ambasExisten
      ? compararHuellas(antes, despues)
      : antes.existe === despues.existe
        ? []
        : ['la base pasó a existir o dejó de existir'];
    if (difs.length === 0) {
      console.log('IGUALES: la base de desarrollo no cambió.');
      return 0;
    }
    console.log('DIFERENTES:');
    for (const d of difs) console.log(`  - ${d}`);
    return 1;
  }
  console.error('Uso: huella tomar <etiqueta> | huella comparar <etiqueta> [<otra>]');
  return 2;
}

main().then(
  (codigo) => process.exit(codigo),
  (error) => {
    console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  },
);
