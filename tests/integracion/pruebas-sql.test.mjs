import { afterEach, describe, expect, it } from 'vitest';
import { codigoDeSalida, dividirCasos, ejecutarCasos } from '../../scripts/lib/pruebas-sql.mjs';
import { crearBaseTemporal } from './_bd.mjs';

/** @type {(() => Promise<unknown>)[]} */
let limpiezas = [];
afterEach(async () => {
  for (const l of limpiezas.reverse()) await l();
  limpiezas = [];
});

describe('ejecutarCasos contra Postgres real', () => {
  it('aísla los casos: lo que hace uno no lo ve el siguiente', async () => {
    const base = await crearBaseTemporal('casos');
    limpiezas.push(base.borrar);
    const c = await base.cliente();
    try {
      const casos = dividirCasos(
        [
          '-- @test crea',
          'CREATE TABLE efimera (id int);',
          '-- @test no la ve',
          "DO $$ BEGIN IF to_regclass('efimera') IS NOT NULL THEN RAISE EXCEPTION 'fuga entre casos'; END IF; END $$;",
        ].join('\n'),
        'aislamiento.test.sql',
      );
      const r = await ejecutarCasos(c, 'aislamiento.test.sql', casos);
      expect(r.map((x) => [x.caso, x.ok])).toEqual([
        ['crea', true],
        ['no la ve', true],
      ]);
      const { rows } = await c.query("SELECT to_regclass('efimera') IS NULL AS limpia");
      expect(rows[0].limpia).toBe(true);
    } finally {
      await c.end();
    }
  });

  it('reporta el fallo de un caso con su mensaje y sigue con los demás', async () => {
    const base = await crearBaseTemporal('casos');
    limpiezas.push(base.borrar);
    const c = await base.cliente();
    try {
      const casos = dividirCasos('-- @test falla\nSELECT 1/0;\n-- @test pasa\nSELECT 1;', 'f.test.sql');
      const r = await ejecutarCasos(c, 'f.test.sql', casos);
      expect(r[0]).toMatchObject({ caso: 'falla', ok: false, error: 'division by zero' });
      expect(r[1]).toMatchObject({ caso: 'pasa', ok: true });
    } finally {
      await c.end();
    }
  });
});

describe('codigoDeSalida', () => {
  it('0 solo si todos pasan', () => {
    expect(codigoDeSalida([{ archivo: 'a', caso: 'x', ok: true }])).toBe(0);
  });

  it('1 si alguno falla', () => {
    expect(
      codigoDeSalida([
        { archivo: 'a', caso: 'x', ok: true },
        { archivo: 'a', caso: 'y', ok: false, error: 'e' },
      ]),
    ).toBe(1);
  });

  it('1 si no corrió ningún caso', () => {
    expect(codigoDeSalida([])).toBe(1);
  });
});
