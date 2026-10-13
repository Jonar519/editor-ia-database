// Lógica de migraciones SQL puras y numeradas.
// La parte pura (nombres, checksums, plan) se separa de la que toca la base para poder probarla sin Postgres.

import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

/** @typedef {{ version: number, nombre: string, archivo: string }} ArchivoMigracion */
/** @typedef {ArchivoMigracion & { sql: string, checksum: string }} Migracion */
/** @typedef {{ version: number, nombre: string, checksum: string }} MigracionAplicada */

export const PATRON_ARCHIVO = /^(\d{4})_([a-z0-9]+(?:_[a-z0-9]+)*)\.sql$/;

/** Clave del bloqueo consultivo que serializa migraciones concurrentes sobre la misma base. */
export const CLAVE_BLOQUEO = 4_200_435;

/**
 * Valida los nombres de archivo: formato NNNN_nombre.sql, sin duplicados y sin huecos desde 0001.
 * Los archivos que no terminan en .sql se ignoran (README, etc.).
 * @param {string[]} nombres
 * @returns {ArchivoMigracion[]}
 */
export function analizarArchivos(nombres) {
  const sql = nombres.filter((n) => n.endsWith('.sql')).sort();
  /** @type {ArchivoMigracion[]} */
  const resultado = [];
  for (const archivo of sql) {
    const m = PATRON_ARCHIVO.exec(archivo);
    if (!m || m[1] === undefined || m[2] === undefined) {
      throw new Error(`Nombre de migración inválido: "${archivo}" (formato esperado: 0001_nombre_en_minusculas.sql).`);
    }
    resultado.push({ version: Number(m[1]), nombre: m[2], archivo });
  }
  resultado.forEach((mig, i) => {
    const esperada = i + 1;
    if (mig.version !== esperada) {
      const previa = resultado[i - 1];
      if (previa && previa.version === mig.version) {
        throw new Error(`Versión duplicada ${mig.version}: "${previa.archivo}" y "${mig.archivo}".`);
      }
      throw new Error(`Hueco en la numeración: se esperaba la versión ${esperada} y llegó "${mig.archivo}".`);
    }
  });
  return resultado;
}

/**
 * SHA-256 del contenido con finales de línea normalizados a LF,
 * para que un checkout con CRLF en Windows no cambie el checksum.
 * @param {string} sql
 */
export function checksum(sql) {
  return createHash('sha256').update(sql.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

/**
 * Decide qué migraciones faltan. Falla si una migración aplicada cambió o desapareció.
 * @param {Migracion[]} archivos
 * @param {MigracionAplicada[]} aplicadas
 * @returns {Migracion[]} pendientes, en orden
 */
export function planificar(archivos, aplicadas) {
  const porVersion = new Map(archivos.map((m) => [m.version, m]));
  for (const ap of aplicadas) {
    const local = porVersion.get(ap.version);
    if (!local) {
      throw new Error(`La base tiene aplicada la versión ${ap.version} (${ap.nombre}) pero no existe en migrations/.`);
    }
    if (local.checksum !== ap.checksum) {
      throw new Error(
        `La migración ${local.archivo} cambió después de aplicarse (checksum distinto). Las migraciones aplicadas no se editan: crea una nueva.`,
      );
    }
  }
  const maxAplicada = aplicadas.reduce((max, ap) => Math.max(max, ap.version), 0);
  if (aplicadas.length !== maxAplicada) {
    throw new Error(`Historial de migraciones inconsistente: ${aplicadas.length} aplicadas pero la máxima es ${maxAplicada}.`);
  }
  return archivos.filter((m) => m.version > maxAplicada);
}

/**
 * @param {string} directorio
 * @returns {Promise<Migracion[]>}
 */
export async function leerMigraciones(directorio) {
  const archivos = analizarArchivos(await readdir(directorio));
  return Promise.all(
    archivos.map(async (a) => {
      const sql = await readFile(path.join(directorio, a.archivo), 'utf8');
      return { ...a, sql, checksum: checksum(sql) };
    }),
  );
}

/**
 * @typedef {{ query: (texto: string, valores?: unknown[]) => Promise<{ rows: any[] }> }} ClienteSql
 */

const DDL_HISTORIAL = `
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    integer PRIMARY KEY CHECK (version > 0),
  nombre     text        NOT NULL,
  checksum   char(64)    NOT NULL,
  aplicada_en timestamptz NOT NULL DEFAULT now()
)`;

/**
 * Solo lee: si la tabla de historial no existe, devuelve []. Nunca crea nada
 * (se usa con conexiones de solo lectura, por ejemplo en "migrate dev --estado").
 * @param {ClienteSql} cliente
 * @returns {Promise<MigracionAplicada[]>}
 */
export async function leerAplicadas(cliente) {
  const { rows: existe } = await cliente.query("SELECT to_regclass('schema_migrations') IS NOT NULL AS existe");
  if (existe[0]?.existe !== true) return [];
  const { rows } = await cliente.query('SELECT version, nombre, checksum FROM schema_migrations ORDER BY version');
  return rows.map((r) => ({ version: Number(r.version), nombre: String(r.nombre), checksum: String(r.checksum) }));
}

/**
 * Aplica las pendientes, cada una en su propia transacción junto con su registro en schema_migrations.
 * Si una falla, se revierte completa y no se aplican las siguientes.
 * @param {ClienteSql} cliente
 * @param {string} directorio
 * @param {(mensaje: string) => void} [log]
 * @returns {Promise<Migracion[]>} las aplicadas en esta ejecución
 */
export async function migrar(cliente, directorio, log = () => {}) {
  const archivos = await leerMigraciones(directorio);
  await cliente.query('SELECT pg_advisory_lock($1)', [CLAVE_BLOQUEO]);
  try {
    await cliente.query(DDL_HISTORIAL);
    const pendientes = planificar(archivos, await leerAplicadas(cliente));
    /** @type {Migracion[]} */
    const hechas = [];
    for (const mig of pendientes) {
      await cliente.query('BEGIN');
      try {
        await cliente.query(mig.sql);
        await cliente.query('INSERT INTO schema_migrations (version, nombre, checksum) VALUES ($1, $2, $3)', [
          mig.version,
          mig.nombre,
          mig.checksum,
        ]);
        await cliente.query('COMMIT');
      } catch (error) {
        await cliente.query('ROLLBACK');
        const motivo = error instanceof Error ? error.message : String(error);
        throw new Error(`Falló ${mig.archivo}: ${motivo}`, { cause: error });
      }
      hechas.push(mig);
      log(`aplicada ${mig.archivo}`);
    }
    return hechas;
  } finally {
    await cliente.query('SELECT pg_advisory_unlock($1)', [CLAVE_BLOQUEO]);
  }
}
