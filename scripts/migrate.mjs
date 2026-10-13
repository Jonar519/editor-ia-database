// Uso: node scripts/migrate.mjs <dev|test> [--estado]
//   dev   aplica las migraciones pendientes en la base de desarrollo (CUADERNO_DEV_DB)
//   test  aplica las migraciones pendientes en la base de pruebas (CUADERNO_TEST_DB)
//   --estado  solo muestra aplicadas y pendientes, sin aplicar nada

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { conexion, nombreBaseDesarrollo, nombreBasePruebas } from './lib/config.mjs';
import { conCliente, conectarSoloLectura } from './lib/bases.mjs';
import { leerAplicadas, leerMigraciones, migrar, planificar } from './lib/migraciones.mjs';

const DIR_MIGRACIONES = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

async function main() {
  const [destino, opcion] = process.argv.slice(2);
  if (destino !== 'dev' && destino !== 'test') {
    console.error('Uso: migrate <dev|test> [--estado]');
    return 2;
  }
  const base = destino === 'dev' ? nombreBaseDesarrollo(process.env) : nombreBasePruebas(process.env);
  const conn = conexion(process.env, base);

  if (opcion === '--estado') {
    // Solo lectura: consultar el estado nunca puede escribir en la base.
    const c = await conectarSoloLectura(conn);
    try {
      const aplicadas = await leerAplicadas(c);
      const pendientes = planificar(await leerMigraciones(DIR_MIGRACIONES), aplicadas);
      console.log(`Base ${base}: ${aplicadas.length} aplicadas, ${pendientes.length} pendientes.`);
      for (const p of pendientes) console.log(`  pendiente ${p.archivo}`);
    } finally {
      await c.end();
    }
    return 0;
  }

  const hechas = await conCliente(conn, (c) => migrar(c, DIR_MIGRACIONES, (m) => console.log(`  ${m}`)));
  console.log(`Base ${base}: ${hechas.length === 0 ? 'al día, nada que aplicar' : `${hechas.length} migraciones aplicadas`}.`);
  return 0;
}

main().then(
  (codigo) => process.exit(codigo),
  (error) => {
    console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  },
);
