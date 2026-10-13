// Runner de pruebas SQL. Cada archivo *.test.sql se divide en casos con la marca "-- @test <nombre>".
// Cada caso corre en su propia transacción que siempre termina en ROLLBACK: los casos no se afectan entre sí.

/** @typedef {import('./migraciones.mjs').ClienteSql} ClienteSql */
/** @typedef {{ nombre: string, sql: string, linea: number }} CasoSql */
/** @typedef {{ archivo: string, caso: string, ok: boolean, error?: string }} ResultadoCaso */

const MARCA = /^--\s*@test\s+(.+?)\s*$/;

/**
 * @param {string} contenido
 * @param {string} archivo para los mensajes de error
 * @returns {CasoSql[]}
 */
export function dividirCasos(contenido, archivo) {
  const lineas = contenido.replace(/\r\n/g, '\n').split('\n');
  /** @type {CasoSql[]} */
  const casos = [];
  /** @type {CasoSql | undefined} */
  let actual;
  lineas.forEach((linea, i) => {
    const m = MARCA.exec(linea);
    if (m && m[1] !== undefined) {
      actual = { nombre: m[1], sql: '', linea: i + 1 };
      casos.push(actual);
      return;
    }
    if (actual) {
      actual.sql += `${linea}\n`;
    } else if (linea.trim() !== '' && !linea.trim().startsWith('--')) {
      throw new Error(`${archivo}:${i + 1}: hay SQL antes del primer "-- @test". Todo el SQL debe pertenecer a un caso.`);
    }
  });
  if (casos.length === 0) throw new Error(`${archivo}: no tiene ningún caso "-- @test <nombre>".`);
  const nombres = new Set();
  for (const c of casos) {
    if (nombres.has(c.nombre)) throw new Error(`${archivo}:${c.linea}: caso duplicado "${c.nombre}".`);
    nombres.add(c.nombre);
    if (c.sql.trim() === '') throw new Error(`${archivo}:${c.linea}: el caso "${c.nombre}" está vacío.`);
  }
  return casos;
}

/**
 * Código de salida del runner: 0 solo si hubo al menos un caso y ninguno falló.
 * @param {ResultadoCaso[]} resultados
 */
export function codigoDeSalida(resultados) {
  if (resultados.length === 0) return 1;
  return resultados.every((r) => r.ok) ? 0 : 1;
}

/**
 * @param {ClienteSql} cliente
 * @param {string} archivo
 * @param {CasoSql[]} casos
 * @returns {Promise<ResultadoCaso[]>}
 */
export async function ejecutarCasos(cliente, archivo, casos) {
  /** @type {ResultadoCaso[]} */
  const resultados = [];
  for (const caso of casos) {
    await cliente.query('BEGIN');
    try {
      await cliente.query(caso.sql);
      resultados.push({ archivo, caso: caso.nombre, ok: true });
    } catch (error) {
      resultados.push({ archivo, caso: caso.nombre, ok: false, error: error instanceof Error ? error.message : String(error) });
    } finally {
      await cliente.query('ROLLBACK');
    }
  }
  return resultados;
}
