// Utilidades para pruebas de integración: cada prueba usa su propia base temporal *_test.

import { randomBytes } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import pg from 'pg';
import { conexion } from '../../scripts/lib/config.mjs';
import { borrarBasePruebas, recrearBasePruebas } from '../../scripts/lib/bases.mjs';

/** @param {string} prefijo */
export async function crearBaseTemporal(prefijo) {
  const nombre = `cuaderno_${prefijo}_${randomBytes(4).toString('hex')}_test`;
  const conn = conexion(process.env, nombre);
  await recrearBasePruebas(conn, nombre);
  return {
    nombre,
    conn,
    async cliente() {
      const c = new pg.Client(conn);
      await c.connect();
      return c;
    },
    borrar: () => borrarBasePruebas(conn, nombre),
  };
}

/** @param {Record<string, string>} archivos */
export async function crearDirMigraciones(archivos) {
  const dir = await mkdtemp(path.join(tmpdir(), 'cuaderno-mig-'));
  for (const [nombre, sql] of Object.entries(archivos)) await writeFile(path.join(dir, nombre), sql);
  return { dir, borrar: () => rm(dir, { recursive: true, force: true }) };
}
