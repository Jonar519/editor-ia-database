import { describe, expect, it } from 'vitest';
import { analizarArchivos, checksum, planificar } from '../../scripts/lib/migraciones.mjs';

/** @param {number} version @param {string} sql */
const mig = (version, sql = `-- ${version}`) => ({
  version,
  nombre: `m${version}`,
  archivo: `${String(version).padStart(4, '0')}_m${version}.sql`,
  sql,
  checksum: checksum(sql),
});

describe('analizarArchivos', () => {
  it('ordena, ignora lo que no es .sql y extrae versión y nombre', () => {
    expect(analizarArchivos(['0002_b.sql', 'README.md', '0001_a_b.sql'])).toEqual([
      { version: 1, nombre: 'a_b', archivo: '0001_a_b.sql' },
      { version: 2, nombre: 'b', archivo: '0002_b.sql' },
    ]);
  });

  it.each(['1_a.sql', '0001-a.sql', '0001_A.sql', '0001_.sql', '0001_a__b.sql', '0001_a.SQL.sql'])('rechaza el nombre "%s"', (n) => {
    expect(() => analizarArchivos([n])).toThrow(/Nombre de migración inválido/);
  });

  it('rechaza huecos en la numeración', () => {
    expect(() => analizarArchivos(['0001_a.sql', '0003_c.sql'])).toThrow(/Hueco/);
  });

  it('rechaza que no empiece en 0001', () => {
    expect(() => analizarArchivos(['0002_b.sql'])).toThrow(/Hueco/);
  });

  it('rechaza versiones duplicadas', () => {
    expect(() => analizarArchivos(['0001_a.sql', '0001_b.sql'])).toThrow(/duplicada/);
  });
});

describe('checksum', () => {
  it('es SHA-256 hex', () => {
    expect(checksum('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  it('no cambia entre CRLF y LF', () => {
    expect(checksum('a\r\nb\r\n')).toBe(checksum('a\nb\n'));
  });

  it('cambia si cambia el contenido', () => {
    expect(checksum('SELECT 1;')).not.toBe(checksum('SELECT 2;'));
  });
});

describe('planificar', () => {
  it('devuelve todas si no hay aplicadas', () => {
    expect(planificar([mig(1), mig(2)], []).map((m) => m.version)).toEqual([1, 2]);
  });

  it('devuelve solo las posteriores a la última aplicada', () => {
    const [a, b, c] = [mig(1), mig(2), mig(3)];
    expect(planificar([a, b, c], [a, b]).map((m) => m.version)).toEqual([3]);
  });

  it('no devuelve nada si está al día', () => {
    const a = mig(1);
    expect(planificar([a], [a])).toEqual([]);
  });

  it('falla si una migración aplicada cambió', () => {
    const aplicada = mig(1, 'CREATE TABLE a ();');
    expect(() => planificar([mig(1, 'CREATE TABLE a (x int);')], [aplicada])).toThrow(/cambió después de aplicarse/);
  });

  it('falla si la base tiene una versión que no existe en los archivos', () => {
    expect(() => planificar([mig(1)], [mig(1), mig(2)])).toThrow(/no existe en migrations/);
  });

  it('falla si el historial aplicado tiene huecos', () => {
    const [a, b, c] = [mig(1), mig(2), mig(3)];
    expect(() => planificar([a, b, c], [a, c])).toThrow(/inconsistente/);
  });
});
