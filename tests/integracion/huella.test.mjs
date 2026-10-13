import { afterEach, describe, expect, it } from 'vitest';
import { conectarSoloLectura } from '../../scripts/lib/bases.mjs';
import { compararHuellas, tomarHuella } from '../../scripts/lib/huella.mjs';
import { crearBaseTemporal } from './_bd.mjs';

/** @type {(() => Promise<unknown>)[]} */
let limpiezas = [];
afterEach(async () => {
  for (const l of limpiezas.reverse()) await l();
  limpiezas = [];
});

async function basePreparada() {
  const base = await crearBaseTemporal('huella');
  limpiezas.push(base.borrar);
  const c = await base.cliente();
  await c.query('CREATE TABLE notas (id int PRIMARY KEY, texto text NOT NULL)');
  await c.query("INSERT INTO notas VALUES (1, 'a'), (2, 'b')");
  await c.end();
  return base;
}

/** @param {Awaited<ReturnType<typeof basePreparada>>} base */
async function huellaDe(base) {
  const c = await conectarSoloLectura(base.conn);
  try {
    return await tomarHuella(c, base.nombre);
  } finally {
    await c.end();
  }
}

describe('huella de la base', () => {
  it('la conexión de solo lectura no puede escribir', async () => {
    const base = await basePreparada();
    const c = await conectarSoloLectura(base.conn);
    try {
      await expect(c.query("INSERT INTO notas VALUES (3, 'c')")).rejects.toMatchObject({ code: '25006' });
      await expect(c.query('CREATE TABLE otra (id int)')).rejects.toMatchObject({ code: '25006' });
    } finally {
      await c.end();
    }
  });

  it('cuenta filas por tabla y es estable si nada cambia', async () => {
    const base = await basePreparada();
    const a = await huellaDe(base);
    const b = await huellaDe(base);
    expect(a.filas).toEqual({ 'public.notas': 2 });
    expect(a.hashEsquema).toMatch(/^[0-9a-f]{64}$/);
    expect(compararHuellas(a, b)).toEqual([]);
  });

  it('detecta filas nuevas', async () => {
    const base = await basePreparada();
    const antes = await huellaDe(base);
    const c = await base.cliente();
    await c.query("INSERT INTO notas VALUES (3, 'c')");
    await c.end();
    expect(compararHuellas(antes, await huellaDe(base))).toEqual(['filas: public.notas pasó de 2 a 3']);
  });

  it.each([
    ['columnas', 'ALTER TABLE notas ADD COLUMN extra int'],
    ['restricciones', 'ALTER TABLE notas ADD CONSTRAINT texto_corto CHECK (length(texto) < 10)'],
    ['indices', 'CREATE INDEX notas_texto ON notas (texto)'],
    ['funciones', 'CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$'],
    ['vistas', 'CREATE VIEW v AS SELECT id FROM notas'],
  ])('detecta cambios de esquema en la sección %s', async (seccion, ddl) => {
    const base = await basePreparada();
    const antes = await huellaDe(base);
    const c = await base.cliente();
    await c.query(ddl);
    await c.end();
    const despues = await huellaDe(base);
    expect(despues.hashEsquema).not.toBe(antes.hashEsquema);
    expect(compararHuellas(antes, despues)).toContain(`esquema: cambió la sección "${seccion}"`);
  });

  it('detecta triggers', async () => {
    const base = await basePreparada();
    const c = await base.cliente();
    await c.query("CREATE FUNCTION nada() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$");
    await c.end();
    const antes = await huellaDe(base);
    const c2 = await base.cliente();
    await c2.query('CREATE TRIGGER t BEFORE INSERT ON notas FOR EACH ROW EXECUTE FUNCTION nada()');
    await c2.end();
    expect(compararHuellas(antes, await huellaDe(base))).toContain('esquema: cambió la sección "triggers"');
  });
});
