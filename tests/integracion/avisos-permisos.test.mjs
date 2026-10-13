// El aviso NOTIFY cuaderno_permisos solo sale al COMMIT, así que se prueba con transacciones reales
// en una base temporal (no en el runner SQL, donde todo termina en ROLLBACK).

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { migrar } from '../../scripts/lib/migraciones.mjs';
import { crearBaseTemporal } from './_bd.mjs';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

/** @type {Awaited<ReturnType<typeof crearBaseTemporal>>} */
let base;
/** @type {import('pg').Client} */
let escritor;
/** @type {import('pg').Client} */
let oyente;
/** @type {Record<string, unknown>[]} */
const avisos = [];
/** @type {{ ana: string, bruno: string, e: string, d: string }} */
let ids;

beforeAll(async () => {
  base = await crearBaseTemporal('avisos');
  escritor = await base.cliente();
  await migrar(escritor, path.join(RAIZ, 'migrations'));
  for (const apoyo of ['_prueba.sql', '_fabricas.sql']) {
    await escritor.query(await readFile(path.join(RAIZ, 'tests', 'sql', apoyo), 'utf8'));
  }
  await escritor.query('BEGIN');
  const { rows } = await escritor.query(`
    WITH a AS (SELECT prueba.cuenta_activa('ana@example.com') AS ana, prueba.cuenta_activa('bruno@example.com') AS bruno)
    SELECT ana, bruno, prueba.espacio(ana) AS e FROM a`);
  const { ana, bruno, e } = rows[0];
  await escritor.query('SELECT prueba.miembro($1, $2, $3)', [e, bruno, 'editor']);
  const { rows: docs } = await escritor.query('SELECT prueba.documento($1, $2) AS d', [e, ana]);
  await escritor.query('SELECT prueba.permiso($1, $2, $3)', [docs[0].d, bruno, 'editor']);
  await escritor.query('COMMIT');
  ids = { ana, bruno, e, d: docs[0].d };

  oyente = await base.cliente();
  oyente.on('notification', (n) => {
    if (n.channel === 'cuaderno_permisos' && n.payload) avisos.push(JSON.parse(n.payload));
  });
  await oyente.query('LISTEN cuaderno_permisos');
});

afterAll(async () => {
  await oyente?.end();
  await escritor?.end();
  await base?.borrar();
});

/**
 * Espera hasta que lleguen n avisos (o 3 s) y los devuelve.
 * @param {number} n
 */
async function esperarAvisos(n) {
  const limite = Date.now() + 3000;
  while (avisos.length < n && Date.now() < limite) await new Promise((r) => setTimeout(r, 25));
  return avisos.splice(0, avisos.length);
}

describe('NOTIFY cuaderno_permisos', () => {
  it('avisa al quitar un permiso de documento', async () => {
    await escritor.query('DELETE FROM permisos_documento WHERE documento_id = $1 AND usuario_id = $2', [ids.d, ids.bruno]);
    expect(await esperarAvisos(1)).toEqual([
      { tabla: 'permisos_documento', operacion: 'DELETE', usuario_id: ids.bruno, espacio_id: ids.e, documento_id: ids.d },
    ]);
  });

  it('avisa al cambiar el rol de un miembro del espacio', async () => {
    await escritor.query("UPDATE miembros_espacio SET rol = 'lector' WHERE espacio_id = $1 AND usuario_id = $2", [ids.e, ids.bruno]);
    expect(await esperarAvisos(1)).toEqual([
      { tabla: 'miembros_espacio', operacion: 'UPDATE', usuario_id: ids.bruno, espacio_id: ids.e, documento_id: null },
    ]);
  });

  it('no avisa si la transacción se revierte', async () => {
    await escritor.query('BEGIN');
    await escritor.query('DELETE FROM miembros_espacio WHERE espacio_id = $1 AND usuario_id = $2', [ids.e, ids.bruno]);
    await escritor.query('ROLLBACK');
    expect(await esperarAvisos(1)).toEqual([]);
  });

  it('no avisa al dar un permiso (no hay conexión que cortar)', async () => {
    await escritor.query('SELECT prueba.permiso($1, $2, $3)', [ids.d, ids.bruno, 'lector']);
    expect(await esperarAvisos(1)).toEqual([]);
  });
});
