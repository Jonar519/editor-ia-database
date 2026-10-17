// compactar_documento() con transacciones REALES y concurrentes (el runner SQL no puede: corre todo en una
// sola conexión). Dos propiedades del bloqueo FOR NO KEY UPDATE tomado ANTES de comprobar hasta_id:
//   1. una compactación más vieja que espera a otra más nueva NO escribe su estado encima (perdería las
//      filas que la nueva ya borró): falla y el job vuelve a leer;
//   2. mientras se compacta, insertar cambios nuevos del mismo documento NO se bloquea.

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { migrar } from '../../scripts/lib/migraciones.mjs';
import { crearBaseTemporal } from './_bd.mjs';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

/** @type {Awaited<ReturnType<typeof crearBaseTemporal>>} */
let base;
/** @type {import('pg').Client[]} */
const clientes = [];
/** @type {import('pg').Client} */
let dueno;
/** @type {{ ana: string, d: string }} */
let ids;

/** Cliente nuevo que actúa como la app (cuaderno_app), con un límite de espera de bloqueos. */
async function comoApp() {
  const c = await base.cliente();
  clientes.push(c);
  await c.query('SET ROLE cuaderno_app');
  await c.query("SET lock_timeout = '2s'");
  return c;
}

/** Inserta una actualización (como dueño, para no depender del rol) y devuelve su id. */
async function actualizacion(/** @type {string} */ bytes) {
  const { rows } = await dueno.query('INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES ($1, $2, $3) RETURNING id', [
    ids.d,
    ids.ana,
    Buffer.from(bytes, 'hex'),
  ]);
  return String(rows[0].id);
}

beforeAll(async () => {
  base = await crearBaseTemporal('compactar');
  dueno = await base.cliente();
  clientes.push(dueno);
  await migrar(dueno, path.join(RAIZ, 'migrations'));
  for (const apoyo of ['_prueba.sql', '_fabricas.sql']) {
    await dueno.query(await readFile(path.join(RAIZ, 'tests', 'sql', apoyo), 'utf8'));
  }
  await dueno.query('BEGIN');
  const { rows } = await dueno.query(`
    WITH a AS (SELECT prueba.cuenta_activa('ana@example.com') AS ana)
    SELECT ana, prueba.documento(prueba.espacio(ana), ana) AS d FROM a`);
  await dueno.query('COMMIT');
  ids = rows[0];
});

afterAll(async () => {
  for (const c of clientes) await c.end().catch(() => undefined);
  await base?.borrar();
});

describe('compactar_documento() concurrente', () => {
  it('la compactación vieja que esperaba a la nueva falla en vez de pisar su estado', async () => {
    const a1 = await actualizacion('01');
    const a2 = await actualizacion('02');
    const nueva = await comoApp();
    const vieja = await comoApp();

    // La nueva compacta hasta a2 y se queda con la transacción abierta (tiene el bloqueo).
    await nueva.query('BEGIN');
    await nueva.query("SELECT compactar_documento($1, $2, '\\xaa02')", [ids.d, a2]);

    // La vieja (calculada hasta a1) empieza mientras tanto: tiene que esperar.
    await vieja.query('BEGIN');
    const resultadoVieja = vieja.query("SELECT compactar_documento($1, $2, '\\xaa01')", [ids.d, a1]).then(
      () => 'compactó',
      (/** @type {{ code?: string }} */ e) => e.code ?? 'error',
    );
    await new Promise((r) => setTimeout(r, 200));
    await nueva.query('COMMIT');

    expect(await resultadoVieja).toBe('23514'); // a1 ya no existe: la nueva lo borró
    await vieja.query('ROLLBACK');
    const { rows } = await dueno.query('SELECT encode(estado_yjs, $2) AS e FROM documentos WHERE id = $1', [ids.d, 'hex']);
    expect(rows[0].e).toBe('aa02'); // queda el estado de la nueva
  });

  it('insertar un cambio nuevo durante la compactación no se bloquea', async () => {
    const a = await actualizacion('03');
    const compactador = await comoApp();
    await compactador.query('BEGIN');
    await compactador.query("SELECT compactar_documento($1, $2, '\\xaa03')", [ids.d, a]);

    // Con la compactación abierta, un autor inserta un cambio del MISMO documento (como la app).
    const autor = await comoApp();
    const inicio = Date.now();
    await autor.query("INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES ($1, $2, '\\x04')", [ids.d, ids.ana]);
    const espera = Date.now() - inicio;
    await compactador.query('COMMIT');

    expect(espera).toBeLessThan(1000); // si se bloqueara, lock_timeout (2 s) lo haría fallar
    const { rows } = await dueno.query('SELECT count(*)::int AS n FROM actualizaciones_documento WHERE documento_id = $1', [ids.d]);
    expect(rows[0].n).toBe(1); // el cambio nuevo quedó para la próxima compactación
  });
});
