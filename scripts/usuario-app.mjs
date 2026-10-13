// Habilita el LOGIN del rol de aplicación cuaderno_app con la contraseña CUADERNO_APP_PASSWORD de .env.
// Los roles son de todo el servidor: esto no toca tablas ni datos de ninguna base.
// Los privilegios sobre las tablas los concede la migración 0012 en cada base migrada.
// Uso: node scripts/usuario-app.mjs   (db-up.bat lo llama solo)

import { conexion } from './lib/config.mjs';
import { conCliente } from './lib/bases.mjs';

async function main() {
  const clave = process.env.CUADERNO_APP_PASSWORD;
  if (!clave || clave.length < 16) {
    throw new Error('Falta CUADERNO_APP_PASSWORD (16+ caracteres) en .env. Ejecuta scripts\\env-init.bat.');
  }
  await conCliente(conexion(process.env, 'postgres'), async (c) => {
    const { rows } = await c.query("SELECT 1 FROM pg_roles WHERE rolname = 'cuaderno_app'");
    const literal = c.escapeLiteral(clave);
    if (rows.length === 0) {
      await c.query(
        `CREATE ROLE cuaderno_app LOGIN PASSWORD ${literal} NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`,
      );
      console.log('Rol cuaderno_app creado con LOGIN.');
    } else {
      await c.query(`ALTER ROLE cuaderno_app LOGIN PASSWORD ${literal}`);
      console.log('Rol cuaderno_app: LOGIN habilitado y contraseña sincronizada con .env.');
    }
  });
  return 0;
}

main().then(
  (codigo) => process.exit(codigo),
  (error) => {
    console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  },
);
