// Configuración de conexión a partir de variables de entorno (PG* estándar + nombres de base propios).

/** @typedef {{ host: string, port: number, user: string, password: string, database: string }} ConexionPg */

/** Sufijo obligatorio para cualquier base que las herramientas puedan borrar o recrear. */
export const SUFIJO_PRUEBAS = '_test';

/**
 * Lanza un error si el nombre no es de una base de pruebas.
 * Es la guarda que impide que las pruebas toquen la base de desarrollo.
 * @param {string} nombre
 */
export function asegurarBaseDePruebas(nombre) {
  if (!/^[a-z][a-z0-9_]*$/.test(nombre) || !nombre.endsWith(SUFIJO_PRUEBAS)) {
    throw new Error(
      `Negado: "${nombre}" no es una base de pruebas (debe terminar en "${SUFIJO_PRUEBAS}" y usar [a-z0-9_]).`,
    );
  }
  return nombre;
}

/**
 * @param {NodeJS.ProcessEnv} env
 * @param {string} clave
 */
function requerida(env, clave) {
  const valor = env[clave];
  if (valor === undefined || valor === '') {
    throw new Error(`Falta la variable de entorno ${clave}. Ejecuta scripts\\env-init.bat o revisa .env.`);
  }
  return valor;
}

/**
 * @param {NodeJS.ProcessEnv} env
 * @param {string} database
 * @returns {ConexionPg}
 */
export function conexion(env, database) {
  const port = Number(env.PGPORT ?? '5435');
  if (!Number.isInteger(port) || port <= 0) throw new Error(`PGPORT inválido: ${env.PGPORT}`);
  return {
    host: env.PGHOST ?? '127.0.0.1',
    port,
    user: env.PGUSER ?? 'cuaderno',
    password: requerida(env, 'PGPASSWORD'),
    database,
  };
}

/** @param {NodeJS.ProcessEnv} env */
export function nombreBaseDesarrollo(env) {
  return env.CUADERNO_DEV_DB ?? 'cuaderno';
}

/** @param {NodeJS.ProcessEnv} env */
export function nombreBasePruebas(env) {
  return asegurarBaseDePruebas(env.CUADERNO_TEST_DB ?? 'cuaderno_test');
}
