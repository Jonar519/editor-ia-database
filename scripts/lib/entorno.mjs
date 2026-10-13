// Completar .env a partir de .env.example sin tocar nunca los valores existentes.

import { randomBytes } from 'node:crypto';

const LINEA_VARIABLE = /^([A-Z][A-Z0-9_]*)=(.*)$/;

/** Las contraseñas (…PASSWORD) vacías en la plantilla se generan aleatorias (24 bytes, base64url). */
const generable = (/** @type {string} */ clave) => clave.endsWith('PASSWORD');

/**
 * @param {string} texto
 * @returns {Set<string>}
 */
function clavesDe(texto) {
  const claves = new Set();
  for (const linea of texto.split(/\r?\n/)) {
    const m = LINEA_VARIABLE.exec(linea);
    if (m?.[1]) claves.add(m[1]);
  }
  return claves;
}

/**
 * @param {string} plantilla contenido de .env.example
 * @param {string | null} actual contenido de .env, o null si no existe
 * @param {(clave: string) => string} [generar]
 * @returns {{ contenido: string, agregadas: string[] }}
 */
export function completarEnv(plantilla, actual, generar = () => randomBytes(24).toString('base64url')) {
  /** @param {string} linea */
  const rellenar = (linea) => {
    const m = LINEA_VARIABLE.exec(linea);
    if (m?.[1] && m[2] === '' && generable(m[1])) return `${m[1]}=${generar(m[1])}`;
    return linea;
  };

  if (actual === null) {
    const lineas = plantilla.split(/\r?\n/);
    return { contenido: lineas.map(rellenar).join('\n'), agregadas: [...clavesDe(plantilla)] };
  }

  const existentes = clavesDe(actual);
  const nuevas = plantilla.split(/\r?\n/).filter((l) => {
    const m = LINEA_VARIABLE.exec(l);
    return m?.[1] !== undefined && !existentes.has(m[1]);
  });
  if (nuevas.length === 0) return { contenido: actual, agregadas: [] };
  const base = actual.endsWith('\n') ? actual : `${actual}\n`;
  const agregado = nuevas.map(rellenar).join('\n');
  return {
    contenido: `${base}\n# Agregadas por env-init (ver .env.example para su descripción)\n${agregado}\n`,
    agregadas: nuevas.map((l) => /** @type {string} */ (LINEA_VARIABLE.exec(l)?.[1])),
  };
}
