// Operaciones sobre bases completas. Todo lo destructivo exige un nombre de base de pruebas.

import pg from 'pg';
import { asegurarBaseDePruebas } from './config.mjs';

/** @typedef {import('./config.mjs').ConexionPg} ConexionPg */

/**
 * @param {ConexionPg} conn
 * @param {(cliente: pg.Client) => Promise<T>} fn
 * @template T
 */
export async function conCliente(conn, fn) {
  const cliente = new pg.Client(conn);
  await cliente.connect();
  try {
    return await fn(cliente);
  } finally {
    await cliente.end();
  }
}

/**
 * Borra (si existe) y crea vacía una base de pruebas. Se niega con cualquier otro nombre.
 * @param {ConexionPg} conn conexión base; se usa la base de mantenimiento "postgres"
 * @param {string} nombre
 */
export async function recrearBasePruebas(conn, nombre) {
  asegurarBaseDePruebas(nombre);
  await conCliente({ ...conn, database: 'postgres' }, async (c) => {
    await c.query(`DROP DATABASE IF EXISTS "${nombre}" WITH (FORCE)`);
    await c.query(`CREATE DATABASE "${nombre}" TEMPLATE template0 ENCODING 'UTF8'`);
  });
}

/**
 * Borra una base de pruebas. Se niega con cualquier otro nombre.
 * @param {ConexionPg} conn
 * @param {string} nombre
 */
export async function borrarBasePruebas(conn, nombre) {
  asegurarBaseDePruebas(nombre);
  await conCliente({ ...conn, database: 'postgres' }, async (c) => {
    await c.query(`DROP DATABASE IF EXISTS "${nombre}" WITH (FORCE)`);
  });
}

/**
 * Cliente cuyas transacciones son de solo lectura desde el arranque de la sesión.
 * Lo usa la huella para que leer la base de desarrollo no pueda escribir en ella.
 * @param {ConexionPg} conn
 */
export async function conectarSoloLectura(conn) {
  const cliente = new pg.Client({ ...conn, options: '-c default_transaction_read_only=on' });
  await cliente.connect();
  return cliente;
}

/**
 * @param {ConexionPg} conn
 * @param {string} nombre
 */
export async function existeBase(conn, nombre) {
  return conCliente({ ...conn, database: 'postgres' }, async (c) => {
    const { rows } = await c.query('SELECT 1 FROM pg_database WHERE datname = $1', [nombre]);
    return rows.length === 1;
  });
}
