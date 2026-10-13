import { describe, expect, it } from 'vitest';
import { dividirCasos } from '../../scripts/lib/pruebas-sql.mjs';

describe('dividirCasos', () => {
  it('separa por la marca @test y conserva el SQL de cada caso', () => {
    const casos = dividirCasos('-- comentario\n\n-- @test uno\nSELECT 1;\n-- @test dos\r\nSELECT 2;\r\n', 'a.test.sql');
    expect(casos.map((c) => [c.nombre, c.sql.trim(), c.linea])).toEqual([
      ['uno', 'SELECT 1;', 3],
      ['dos', 'SELECT 2;', 5],
    ]);
  });

  it('rechaza SQL fuera de un caso', () => {
    expect(() => dividirCasos('SELECT 1;\n-- @test uno\nSELECT 1;', 'a.test.sql')).toThrow(/antes del primer/);
  });

  it('rechaza un archivo sin casos', () => {
    expect(() => dividirCasos('-- nada', 'a.test.sql')).toThrow(/ningún caso/);
  });

  it('rechaza casos duplicados', () => {
    expect(() => dividirCasos('-- @test x\nSELECT 1;\n-- @test x\nSELECT 2;', 'a.test.sql')).toThrow(/duplicado/);
  });

  it('rechaza casos vacíos', () => {
    expect(() => dividirCasos('-- @test x\n\n-- @test y\nSELECT 1;', 'a.test.sql')).toThrow(/vacío/);
  });
});
