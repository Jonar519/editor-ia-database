import { afterAll, describe, expect, it } from 'vitest';
import pg from 'pg';
import { conexion } from '../../scripts/lib/config.mjs';
import { borrarBasePruebas, existeBase, recrearBasePruebas } from '../../scripts/lib/bases.mjs';

// Nombre que NO es de pruebas y que no existe. Si alguien quita la guarda, la prueba falla
// creando esta base inofensiva (nunca toca la base de desarrollo); afterAll la limpia.
const NO_PRUEBAS = 'cuaderno_guarda_sin_sufijo';
const conn = conexion(process.env, 'postgres');

afterAll(async () => {
  const c = new pg.Client({ ...conn, database: 'postgres' });
  await c.connect();
  await c.query(`DROP DATABASE IF EXISTS "${NO_PRUEBAS}" WITH (FORCE)`);
  await c.end();
});

describe('operaciones destructivas solo sobre bases *_test', () => {
  it('recrearBasePruebas se niega con una base que no es de pruebas', async () => {
    await expect(recrearBasePruebas(conn, NO_PRUEBAS)).rejects.toThrow(/no es una base de pruebas/);
    expect(await existeBase(conn, NO_PRUEBAS)).toBe(false);
  });

  it('borrarBasePruebas se niega con una base que no es de pruebas', async () => {
    await expect(borrarBasePruebas(conn, NO_PRUEBAS)).rejects.toThrow(/no es una base de pruebas/);
  });
  // A propósito NO hay una prueba con el nombre de la base de desarrollo: si una mutación
  // quitara la guarda, esa prueba la borraría de verdad.
});
