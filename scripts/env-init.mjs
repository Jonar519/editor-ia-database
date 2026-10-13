// Crea .env a partir de .env.example, o completa un .env existente con las variables nuevas que le
// falten. Las *_PASSWORD vacías se generan aleatorias. Nunca cambia un valor que ya exista.

import { existsSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { completarEnv } from './lib/entorno.mjs';

const RAIZ = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const destino = path.join(RAIZ, '.env');

const plantilla = await readFile(path.join(RAIZ, '.env.example'), 'utf8');
const actual = existsSync(destino) ? await readFile(destino, 'utf8') : null;
const { contenido, agregadas } = completarEnv(plantilla, actual);

if (actual === null) {
  await writeFile(destino, contenido, { flag: 'wx' });
  console.log('.env creado con contraseñas locales aleatorias.');
} else if (agregadas.length > 0) {
  await writeFile(destino, contenido);
  console.log(`.env completado con: ${agregadas.join(', ')} (los valores existentes no se tocaron).`);
} else {
  console.log('.env ya está completo; no se modifica.');
}
