import { afterEach, describe, expect, it } from 'vitest';
import { migrar } from '../../scripts/lib/migraciones.mjs';
import { crearBaseTemporal, crearDirMigraciones } from './_bd.mjs';

/** @type {(() => Promise<unknown>)[]} */
let limpiezas = [];
afterEach(async () => {
  for (const l of limpiezas.reverse()) await l();
  limpiezas = [];
});

/** @param {Record<string, string>} archivos */
async function preparar(archivos) {
  const base = await crearBaseTemporal('mig');
  const dir = await crearDirMigraciones(archivos);
  limpiezas.push(base.borrar, dir.borrar);
  return { base, dir: dir.dir };
}

/** @param {import('pg').Client} c @param {string} tabla */
async function existeTabla(c, tabla) {
  const { rows } = await c.query('SELECT to_regclass($1) IS NOT NULL AS existe', [tabla]);
  return rows[0].existe === true;
}

describe('migrar contra Postgres real', () => {
  it('aplica en orden, registra checksums y es idempotente', async () => {
    const { base, dir } = await preparar({
      '0001_a.sql': 'CREATE TABLE a (id int PRIMARY KEY);',
      '0002_b.sql': 'CREATE TABLE b (a_id int REFERENCES a(id));',
    });
    const c = await base.cliente();
    try {
      expect((await migrar(c, dir)).map((m) => m.version)).toEqual([1, 2]);
      expect(await migrar(c, dir)).toEqual([]);
      const { rows } = await c.query('SELECT version, length(checksum) AS n FROM schema_migrations ORDER BY version');
      expect(rows).toEqual([
        { version: 1, n: 64 },
        { version: 2, n: 64 },
      ]);
    } finally {
      await c.end();
    }
  });

  it('si una migración falla, la revierte completa y no aplica las siguientes', async () => {
    const { base, dir } = await preparar({
      '0001_a.sql': 'CREATE TABLE a (id int);',
      '0002_b.sql': 'CREATE TABLE b (id int);\nSELECT 1/0;',
      '0003_c.sql': 'CREATE TABLE c (id int);',
    });
    const c = await base.cliente();
    try {
      await expect(migrar(c, dir)).rejects.toThrow(/Falló 0002_b\.sql: division by zero/);
      expect(await existeTabla(c, 'a')).toBe(true);
      expect(await existeTabla(c, 'b')).toBe(false);
      expect(await existeTabla(c, 'c')).toBe(false);
      const { rows } = await c.query('SELECT max(version) AS v FROM schema_migrations');
      expect(rows[0].v).toBe(1);
    } finally {
      await c.end();
    }
  });

  it('el SQL de la migración y su registro son atómicos (fallo inyectado al registrar)', async () => {
    const { base, dir } = await preparar({ '0001_a.sql': 'CREATE TABLE a (id int);' });
    const real = await base.cliente();
    // Cliente que falla justo al registrar la migración, después de ejecutar su SQL.
    const cliente = {
      /** @param {string} texto @param {unknown[]} [valores] */
      query(texto, valores) {
        if (texto.startsWith('INSERT INTO schema_migrations')) return Promise.reject(new Error('fallo inyectado'));
        return real.query(texto, valores);
      },
    };
    try {
      await expect(migrar(cliente, dir)).rejects.toThrow(/fallo inyectado/);
      expect(await existeTabla(real, 'a')).toBe(false);
    } finally {
      await real.end();
    }
  });

  it('se niega a seguir si una migración aplicada fue editada', async () => {
    const { base, dir } = await preparar({ '0001_a.sql': 'CREATE TABLE a (id int);' });
    const c = await base.cliente();
    try {
      await migrar(c, dir);
      const { writeFile } = await import('node:fs/promises');
      await writeFile(`${dir}/0001_a.sql`, 'CREATE TABLE a (id bigint);');
      await expect(migrar(c, dir)).rejects.toThrow(/cambió después de aplicarse/);
    } finally {
      await c.end();
    }
  });

  it('dos ejecuciones simultáneas no chocan (bloqueo consultivo)', async () => {
    const { base, dir } = await preparar({
      '0001_lenta.sql': 'SELECT pg_sleep(0.5);\nCREATE TABLE lenta (id int);',
    });
    const [c1, c2] = [await base.cliente(), await base.cliente()];
    try {
      const resultados = await Promise.all([migrar(c1, dir), migrar(c2, dir)]);
      expect(resultados.map((r) => r.length).sort()).toEqual([0, 1]);
      const { rows } = await c1.query('SELECT count(*)::int AS n FROM schema_migrations');
      expect(rows[0].n).toBe(1);
    } finally {
      await Promise.all([c1.end(), c2.end()]);
    }
  });
});
