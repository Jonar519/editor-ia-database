// Uso: node scripts/sql-test.mjs [filtro]
// Recrea desde cero la base de pruebas (CUADERNO_TEST_DB, debe terminar en _test), aplica todas las
// migraciones, instala las funciones de aserción (tests/sql/_prueba.sql) y los demás apoyos
// (tests/sql/_*.sql, por ejemplo las fábricas de datos) y corre tests/sql/*.test.sql.
// Nunca se conecta a la base de desarrollo.

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { conexion, nombreBasePruebas } from './lib/config.mjs';
import { conCliente, recrearBasePruebas } from './lib/bases.mjs';
import { migrar } from './lib/migraciones.mjs';
import { codigoDeSalida, dividirCasos, ejecutarCasos } from './lib/pruebas-sql.mjs';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIR_PRUEBAS = path.join(RAIZ, 'tests', 'sql');

async function main() {
  const filtro = process.argv[2];
  const base = nombreBasePruebas(process.env);
  const conn = conexion(process.env, base);

  await recrearBasePruebas(conn, base);
  const archivos = (await readdir(DIR_PRUEBAS))
    .filter((a) => a.endsWith('.test.sql'))
    .filter((a) => !filtro || a.includes(filtro))
    .sort();
  if (archivos.length === 0) throw new Error('No hay archivos de prueba que correr.');

  const resultados = await conCliente(conn, async (c) => {
    await migrar(c, path.join(RAIZ, 'migrations'));
    // Primero las aserciones (_prueba.sql); luego los demás apoyos (_*.sql), en orden.
    const apoyos = (await readdir(DIR_PRUEBAS)).filter((a) => /^_.*\.sql$/.test(a) && a !== '_prueba.sql').sort();
    for (const apoyo of ['_prueba.sql', ...apoyos]) {
      await c.query(await readFile(path.join(DIR_PRUEBAS, apoyo), 'utf8'));
    }
    const todos = [];
    for (const archivo of archivos) {
      const casos = dividirCasos(await readFile(path.join(DIR_PRUEBAS, archivo), 'utf8'), archivo);
      todos.push(...(await ejecutarCasos(c, archivo, casos)));
    }
    return todos;
  });

  let archivoPrevio = '';
  for (const r of resultados) {
    if (r.archivo !== archivoPrevio) {
      console.log(`\n${r.archivo}`);
      archivoPrevio = r.archivo;
    }
    console.log(`  ${r.ok ? 'OK  ' : 'FALLA'} ${r.caso}${r.ok ? '' : `\n        ${r.error}`}`);
  }
  const fallidas = resultados.filter((r) => !r.ok).length;
  console.log(`\nPruebas SQL: ${resultados.length - fallidas} OK, ${fallidas} fallidas (base ${base}).`);
  return codigoDeSalida(resultados);
}

main().then(
  (codigo) => process.exit(codigo),
  (error) => {
    console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  },
);
