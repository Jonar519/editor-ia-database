# Demo · Bloque A: fundación de la base de datos

**Rol:** ninguno. Este bloque todavía no tiene usuarios ni interfaz.
**Terminal:** `cmd.exe`, ubicado en la carpeta del repo:

```bat
cd /d "C:\Users\<tu-usuario>\...\editor-ia\editor-ia-database"
```

## 1. Preparar y levantar los servicios

```bat
npm ci
scripts\env-init.bat
scripts\db-up.bat
```

**Qué debes ver:**

- `.env creado con una contraseña local aleatoria.` (o `.env ya existe; no se modifica.`)
- `Container cuaderno_postgres Healthy` y `Container cuaderno_redis Healthy`

Comprueba los puertos:

```bat
docker ps --filter name=cuaderno
```

Debe mostrar `127.0.0.1:5435->5432/tcp` y `127.0.0.1:6381->6379/tcp`. Solo escuchan en tu máquina.

## 2. Migrar la base de desarrollo

```bat
scripts\db-migrate.bat dev --estado
scripts\db-migrate.bat dev
scripts\db-migrate.bat dev
```

**Qué debes ver:**

1. `Base cuaderno: 0 aplicadas, 1 pendientes.` y la línea `pendiente 0001_extensiones.sql`
2. `aplicada 0001_extensiones.sql` y `Base cuaderno: 1 migraciones aplicadas.`
3. `Base cuaderno: al día, nada que aplicar.` (es idempotente)

## 3. Una migración aplicada no se puede editar

Abre `migrations\0001_extensiones.sql`, agrega al final la línea `-- cambio` y guarda. Luego:

```bat
scripts\db-migrate.bat dev
```

**Qué debes ver:** `ERROR: La migración 0001_extensiones.sql cambió después de aplicarse (checksum distinto)...` y código de salida 1.

Comprueba el código con `echo %ERRORLEVEL%`. Después deshaz el cambio:

```bat
git checkout -- migrations\0001_extensiones.sql
scripts\db-migrate.bat dev
```

**Qué debes ver:** `al día, nada que aplicar.`

## 4. Pruebas (solo usan bases `*_test`)

Toma primero una huella de tu base de desarrollo, corre las pruebas y compara:

```bat
scripts\db-huella.bat tomar demo-antes
scripts\db-test.bat
scripts\db-huella.bat comparar demo-antes
```

**Qué debes ver:**

- La salida de Vitest con todos los archivos en `passed`.
- Las pruebas SQL caso por caso con `OK`, y al final `Pruebas SQL: N OK, 0 fallidas (base cuaderno_test).`
- La línea `test:unit exit=0   test:sql exit=0`
- En la comparación: `IGUALES: la base de desarrollo no cambió.`

## 5. La guarda impide que las pruebas toquen tu base

En la misma ventana de cmd:

```bat
set CUADERNO_TEST_DB=cuaderno
npm run test:sql
set CUADERNO_TEST_DB=
```

**Qué debes ver:** `ERROR: Negado: "cuaderno" no es una base de pruebas (debe terminar en "_test" ...)`. No se borra nada.

## 6. Pruebas de mutación

```bat
scripts\mutar.bat
```

**Qué debes ver:** cada regla con `DETECTADA` y al final `Detectadas 19, sobreviven 0, equivalentes 0, errores 0 (de 19).`

Para ver una sola mutación: `scripts\mutar.bat A01`.

## 7. Todo lo que corre el CI

```bat
scripts\ci.bat
```

**Qué debes ver:** el resumen con `exit 0` en cada paso (lint, typecheck, test:unit, test:sql, mutaciones, npm audit, gitleaks) y `RESULTADO: OK`.

## 8. Apagar

```bat
scripts\db-down.bat
```

Los datos se conservan en los volúmenes `cuaderno_cuaderno_pgdata` y `cuaderno_cuaderno_redisdata`.
