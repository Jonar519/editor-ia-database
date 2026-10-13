# Demo · Bloque C: esquema del dominio

**Rol:** ninguno. Todavía no hay backend: se prueba directo contra la base de **pruebas**.
**Terminal:** `cmd.exe`, en la carpeta `editor-ia-database`.
**Datos:** solo ficticios (`@example.com`).

## 1. Servicios arriba y huella antes de empezar

```bat
scripts\db-up.bat
scripts\db-huella.bat tomar demo-c-antes
```

## 2. Pruebas

```bat
scripts\db-test.bat
```

**Qué debes ver:**

- Vitest con 8 archivos en `passed`, incluido `avisos-permisos.test.mjs`.
- Las pruebas SQL de `0008_espacios`, `0009_documentos`, `0010_contenido` y `0011_ia` junto con las anteriores.
- Al final, `Pruebas SQL: 129 OK, 0 fallidas` y `test:unit exit=0   test:sql exit=0`.

## 3. Romper a propósito el historial y el aislamiento

```bat
scripts\mutar.bat C01 C02 C04 C05 C07 C08 C19 C20 C22 C23
```

**Qué debes ver:** cada una con `DETECTADA` y su `evidencia:`. Por ejemplo:

- C05 (el hash ya no cubre el contenido): `FALLA versiones: la verificación detecta un contenido manipulado...`
- C19 (sin trigger de aislamiento): `FALLA AISLAMIENTO trigger: nadie indexa un documento al que no tiene acceso`

Al final: `Detectadas 10, sobreviven 0, equivalentes 0, errores 0 (de 10).`

Para ver una mutación **equivalente** (declarada con su motivo):

```bat
scripts\mutar.bat C29
```

**Qué debes ver:** `EQUIVALENTE` y el motivo: la membresía ya exige que la cuenta esté activa.

## 4. Manipular el historial con tus manos (psql, base de pruebas)

```bat
docker exec -it cuaderno_postgres psql -U cuaderno -d cuaderno_test
```

Dentro de psql, pega este bloque. Todo termina en `ROLLBACK`, así que la base queda igual:

```sql
BEGIN;
INSERT INTO usuarios (correo, nombre, rol) VALUES ('demo@example.com', 'Demo', 'editor');
UPDATE usuarios SET estado = 'activa', activada_en = now(),
  hash_contrasena = '$scrypt$ln=15,r=8,p=1$c2Fs$aGFzaA' WHERE correo = 'demo@example.com';
INSERT INTO espacios (nombre, creado_por) SELECT 'Demo', id FROM usuarios WHERE correo = 'demo@example.com';
INSERT INTO miembros_espacio (espacio_id, usuario_id, rol) SELECT e.id, e.creado_por, 'propietario' FROM espacios e;
INSERT INTO documentos (espacio_id, titulo, creado_por) SELECT id, 'Guía', creado_por FROM espacios;
INSERT INTO permisos_documento (documento_id, espacio_id, usuario_id, rol) SELECT id, espacio_id, creado_por, 'propietario' FROM documentos;
INSERT INTO versiones (documento_id, motivo, creado_por, estado_yjs, contenido_texto)
  SELECT id, 'manual', creado_por, '\x01', 'versión ' || n FROM documentos, generate_series(1, 3) AS n;
SELECT numero, encode(hash, 'hex') AS hash FROM versiones ORDER BY numero;
UPDATE versiones SET contenido_texto = 'manipulada' WHERE numero = 2;
ROLLBACK;
```

**Qué debes ver:**

- Las versiones numeradas 1, 2 y 3, cada una con su hash.
- El `UPDATE` falla con `El historial de versiones es de solo inserción (UPDATE prohibido)`.

Escribe `\q` para salir.

## 5. Comparar la huella

```bat
scripts\db-huella.bat comparar demo-c-antes
```

**Qué debes ver:** `IGUALES: la base de desarrollo no cambió.` (si no migraste `dev` en medio).

## 6. Todo lo que corre el CI

```bat
scripts\ci.bat
```

**Qué debes ver:** `exit 0` en cada paso y `RESULTADO: OK`.
