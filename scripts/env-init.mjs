// Crea .env a partir de .env.example con una contraseña local aleatoria.
// No sobrescribe un .env existente.

import { randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const destino = path.join(RAIZ, '.env');

if (existsSync(destino)) {
  console.log('.env ya existe; no se modifica.');
  process.exit(0);
}
const plantilla = await readFile(path.join(RAIZ, '.env.example'), 'utf8');
const clave = randomBytes(24).toString('base64url');
const contenido = plantilla.replace(/^PGPASSWORD=(?=\r?$)/m,`PGPASSWORD=${clave}`);
if (contenido === plantilla) throw new Error('No se encontró la línea "PGPASSWORD=" en .env.example.');
await writeFile(destino, contenido, { flag: 'wx' });
console.log('.env creado con una contraseña local aleatoria.');
