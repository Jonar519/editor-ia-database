// Huella de una base: conteo de filas por tabla y hash del esquema por secciones.
// Sirve para demostrar que un bloque no escribió en la base de desarrollo.

import { createHash } from 'node:crypto';

/** @typedef {import('./migraciones.mjs').ClienteSql} ClienteSql */
/**
 * @typedef {{
 *   base: string,
 *   tomadaEn: string,
 *   filas: Record<string, number>,
 *   secciones: Record<string, string>,
 *   hashEsquema: string,
 * }} Huella
 */

const ESQUEMAS_SISTEMA = `('pg_catalog', 'information_schema', 'pg_toast')`;

/** Consultas canónicas (ordenadas) que describen el esquema. Excluyen objetos de extensiones. */
const SECCIONES = {
  extensiones: `SELECT extname || ' ' || extversion AS l FROM pg_extension ORDER BY 1`,
  columnas: `
    SELECT table_schema || '.' || table_name || '.' || column_name || ' ' || udt_name || ' ' ||
           is_nullable || ' ' || coalesce(column_default, '') AS l
    FROM information_schema.columns
    WHERE table_schema NOT IN ${ESQUEMAS_SISTEMA}
    ORDER BY table_schema, table_name, ordinal_position`,
  restricciones: `
    SELECT c.conrelid::regclass::text || ' ' || c.conname || ' ' || pg_get_constraintdef(c.oid) AS l
    FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname NOT IN ${ESQUEMAS_SISTEMA}
    ORDER BY 1`,
  indices: `
    SELECT schemaname || ' ' || indexdef AS l FROM pg_indexes
    WHERE schemaname NOT IN ${ESQUEMAS_SISTEMA} ORDER BY 1`,
  triggers: `
    SELECT pg_get_triggerdef(t.oid) AS l FROM pg_trigger t
    WHERE NOT t.tgisinternal ORDER BY 1`,
  funciones: `
    SELECT pg_get_functiondef(p.oid) AS l
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ${ESQUEMAS_SISTEMA}
      AND p.prokind IN ('f', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
    ORDER BY 1`,
  vistas: `
    SELECT schemaname || '.' || viewname || ' ' || definition AS l FROM pg_views
    WHERE schemaname NOT IN ${ESQUEMAS_SISTEMA} ORDER BY 1`,
  politicas: `
    SELECT schemaname || '.' || tablename || ' ' || policyname || ' ' || cmd || ' ' ||
           coalesce(qual, '') || ' ' || coalesce(with_check, '') AS l
    FROM pg_policies ORDER BY 1`,
};

/** @param {string} texto */
const sha256 = (texto) => createHash('sha256').update(texto, 'utf8').digest('hex');

/**
 * Toma la huella. Espera un cliente de solo lectura (ver conectarSoloLectura).
 * @param {ClienteSql} cliente
 * @param {string} base
 * @returns {Promise<Huella>}
 */
export async function tomarHuella(cliente, base) {
  /** @type {Record<string, string>} */
  const secciones = {};
  for (const [nombre, consulta] of Object.entries(SECCIONES)) {
    const { rows } = await cliente.query(consulta);
    secciones[nombre] = sha256(rows.map((r) => String(r.l)).join('\n'));
  }
  const hashEsquema = sha256(
    Object.entries(secciones)
      .map(([k, v]) => `${k}:${v}`)
      .join('\n'),
  );

  const { rows: tablas } = await cliente.query(`
    SELECT schemaname, tablename FROM pg_tables
    WHERE schemaname NOT IN ${ESQUEMAS_SISTEMA} ORDER BY schemaname, tablename`);
  /** @type {Record<string, number>} */
  const filas = {};
  for (const t of tablas) {
    const ident = `"${String(t.schemaname).replaceAll('"', '""')}"."${String(t.tablename).replaceAll('"', '""')}"`;
    const { rows } = await cliente.query(`SELECT count(*)::bigint AS n FROM ${ident}`);
    filas[`${t.schemaname}.${t.tablename}`] = Number(rows[0]?.n ?? 0);
  }
  return { base, tomadaEn: new Date().toISOString(), filas, secciones, hashEsquema };
}

/**
 * Compara dos huellas y devuelve la lista de diferencias legibles (vacía si son iguales).
 * @param {Huella} antes
 * @param {Huella} despues
 * @returns {string[]}
 */
export function compararHuellas(antes, despues) {
  /** @type {string[]} */
  const difs = [];
  for (const seccion of new Set([...Object.keys(antes.secciones), ...Object.keys(despues.secciones)])) {
    if (antes.secciones[seccion] !== despues.secciones[seccion]) difs.push(`esquema: cambió la sección "${seccion}"`);
  }
  for (const tabla of new Set([...Object.keys(antes.filas), ...Object.keys(despues.filas)])) {
    const a = antes.filas[tabla];
    const d = despues.filas[tabla];
    if (a === undefined) difs.push(`filas: tabla nueva ${tabla} (${d} filas)`);
    else if (d === undefined) difs.push(`filas: desapareció la tabla ${tabla} (tenía ${a})`);
    else if (a !== d) difs.push(`filas: ${tabla} pasó de ${a} a ${d}`);
  }
  return difs;
}
