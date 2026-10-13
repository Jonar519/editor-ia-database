import { describe, expect, it } from 'vitest';
import { asegurarBaseDePruebas, conexion, nombreBaseDesarrollo, nombreBasePruebas } from '../../scripts/lib/config.mjs';

describe('asegurarBaseDePruebas', () => {
  it('acepta nombres que terminan en _test', () => {
    expect(asegurarBaseDePruebas('cuaderno_test')).toBe('cuaderno_test');
    expect(asegurarBaseDePruebas('cuaderno_mig_ab12_test')).toBe('cuaderno_mig_ab12_test');
  });

  it.each(['cuaderno', 'postgres', 'cuaderno_testing', 'test', '_test', 'Cuaderno_test', 'x_test"; DROP DATABASE cuaderno; --'])(
    'rechaza "%s"',
    (nombre) => {
      expect(() => asegurarBaseDePruebas(nombre)).toThrow(/no es una base de pruebas/);
    },
  );
});

describe('nombres de base desde el entorno', () => {
  it('la base de pruebas pasa por la guarda', () => {
    expect(() => nombreBasePruebas({ CUADERNO_TEST_DB: 'cuaderno' })).toThrow(/no es una base de pruebas/);
    expect(nombreBasePruebas({})).toBe('cuaderno_test');
  });

  it('la base de desarrollo usa el valor por defecto', () => {
    expect(nombreBaseDesarrollo({})).toBe('cuaderno');
  });
});

describe('conexion', () => {
  it('exige PGPASSWORD', () => {
    expect(() => conexion({}, 'cuaderno_test')).toThrow(/PGPASSWORD/);
  });

  it('usa 127.0.0.1:5435 por defecto', () => {
    expect(conexion({ PGPASSWORD: 'x' }, 'd_test')).toEqual({
      host: '127.0.0.1',
      port: 5435,
      user: 'cuaderno',
      password: 'x',
      database: 'd_test',
    });
  });

  it('rechaza un puerto inválido', () => {
    expect(() => conexion({ PGPASSWORD: 'x', PGPORT: 'abc' }, 'd_test')).toThrow(/PGPORT/);
  });
});
