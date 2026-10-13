import { describe, expect, it } from 'vitest';
import { completarEnv } from '../../scripts/lib/entorno.mjs';

const PLANTILLA = ['# comentario', 'PGHOST=127.0.0.1', 'PGPASSWORD=', 'CUADERNO_APP_PASSWORD=', 'REDIS_PORT=6381', ''].join('\n');
const generar = (/** @type {string} */ clave) => `gen-${clave}`;

describe('completarEnv', () => {
  it('sin .env: copia la plantilla y genera las *_PASSWORD vacías', () => {
    const { contenido, agregadas } = completarEnv(PLANTILLA, null, generar);
    expect(contenido).toContain('PGPASSWORD=gen-PGPASSWORD');
    expect(contenido).toContain('CUADERNO_APP_PASSWORD=gen-CUADERNO_APP_PASSWORD');
    expect(contenido).toContain('PGHOST=127.0.0.1');
    expect(agregadas).toEqual(['PGHOST', 'PGPASSWORD', 'CUADERNO_APP_PASSWORD', 'REDIS_PORT']);
  });

  it('con .env: agrega solo las que faltan y NUNCA cambia un valor existente', () => {
    const actual = 'PGHOST=10.0.0.9\nPGPASSWORD=mi-clave-de-siempre\n';
    const { contenido, agregadas } = completarEnv(PLANTILLA, actual, generar);
    expect(agregadas).toEqual(['CUADERNO_APP_PASSWORD', 'REDIS_PORT']);
    expect(contenido.startsWith(actual)).toBe(true);
    expect(contenido).toContain('PGPASSWORD=mi-clave-de-siempre');
    expect(contenido).not.toContain('gen-PGPASSWORD');
    expect(contenido).toContain('CUADERNO_APP_PASSWORD=gen-CUADERNO_APP_PASSWORD');
    expect(contenido).toContain('REDIS_PORT=6381');
  });

  it('con .env completo: no cambia nada', () => {
    const actual = 'PGHOST=a\nPGPASSWORD=b\nCUADERNO_APP_PASSWORD=c\nREDIS_PORT=d';
    expect(completarEnv(PLANTILLA, actual, generar)).toEqual({ contenido: actual, agregadas: [] });
  });

  it('no genera valores para variables que no son contraseñas', () => {
    const { contenido } = completarEnv('ALGO=\n', null, generar);
    expect(contenido).toBe('ALGO=\n');
  });

  it('por defecto genera 24 bytes aleatorios en base64url', () => {
    const { contenido } = completarEnv('X_PASSWORD=\n', null);
    expect(contenido).toMatch(/^X_PASSWORD=[A-Za-z0-9_-]{32}\n$/);
  });
});
