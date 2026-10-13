# editor-ia-database

Esquema de base de datos de **Cuaderno**, un editor colaborativo de documentación técnica con IA.

Contiene:

- las migraciones SQL puras y numeradas (PostgreSQL 16 + pgvector),
- las pruebas SQL y las pruebas de las herramientas,
- los scripts para levantar los servicios locales.

El backend (`editor-ia-backend`) usa este esquema solo como cliente, mediante Prisma.

## Requisitos

- Docker Desktop (motor Linux)
- Node.js 24 o superior

No hace falta instalar `psql` ni `gitleaks`: corren en Docker.

## Servicios locales

| Servicio | Contenedor | Dirección |
|---|---|---|
| PostgreSQL 16 + pgvector | `cuaderno_postgres` | `127.0.0.1:5435` |
| Redis 7 | `cuaderno_redis` | `127.0.0.1:6381` |

| Base | Para qué |
|---|---|
| `cuaderno` | Desarrollo. Las pruebas nunca escriben aquí; la huella solo la lee. |
| `cuaderno_test` | Pruebas. Se recrea desde cero en cada corrida. |
| `cuaderno_*_test` | Bases temporales de las pruebas de integración. Se borran al terminar. |

Bases lógicas de Redis: 0 = desarrollo, 1 = pruebas, 2 = E2E.

## Puesta en marcha (cmd.exe)

```bat
npm ci
scripts\db-up.bat
scripts\db-migrate.bat dev
```

`db-up.bat` genera `.env` por sí solo la primera vez, con contraseñas locales aleatorias de 24 bytes, así que el bloque se puede reproducir en cualquier computador sin pasos manuales. Si `.env` ya existe, no lo toca.

**Ojo:** Postgres fija la contraseña cuando crea el volumen. Si borras `.env` pero conservas el volumen, la contraseña nueva no coincidirá. En ese caso tienes dos opciones:

- recuperar tu `.env` anterior, o
- recrear la base desde cero con `docker compose down -v`, que **borra los datos locales**.

## Scripts

Todos los `.bat` están en `scripts\` y se pueden ejecutar desde cualquier carpeta.

| Script | Qué hace |
|---|---|
| `env-init.bat` | Crea `.env` con contraseñas locales aleatorias. Si `.env` ya existe, le agrega solo las variables nuevas que falten, sin tocar las existentes. `db-up.bat` lo llama automáticamente. |
| `db-up.bat` / `db-down.bat` | `db-up.bat` crea o completa `.env`, levanta los contenedores esperando el healthcheck y habilita el LOGIN de `cuaderno_app`. `db-down.bat` detiene los contenedores. Los datos se conservan. |
| `db-migrate.bat dev\|test [--estado]` | Aplica las migraciones pendientes, o solo muestra su estado. `--estado` usa una conexión de solo lectura. |
| `db-test.bat [filtro]` | Pruebas Vitest (unitarias e integración) y pruebas SQL. |
| `db-huella.bat tomar\|comparar <etiqueta>` | Huella de solo lectura de la base de desarrollo: filas por tabla y hash del esquema. |
| `mutar.bat [id...]` | Pruebas de mutación del catálogo `mutations\catalogo.json`. |
| `gitleaks.bat` | Busca secretos en todo el historial de git. |
| `ci.bat` | Corre los mismos pasos que el CI y muestra el código de salida de cada uno. |

## Migraciones

Las reglas están en [migrations/README.md](migrations/README.md). En resumen:

- archivos `NNNN_nombre.sql`, consecutivos;
- cada uno se aplica en una transacción junto con su registro y su checksum;
- una migración aplicada no se edita.

## Esquema

| Migración | Contenido |
|---|---|
| `0001_extensiones` | `vector` (pgvector) y `citext` |
| `0002_usuarios` | cuentas (pendiente → activa → lápida) y funciones genéricas de integridad |
| `0003_invitaciones` | alta solo por invitación, de un solo uso y 72 h como máximo |
| `0004_sesiones` | sesiones (IP truncada) y tokens de refresco rotativos |
| `0005_tokens_cuenta` | recuperación de contraseña (15 min) y cambio de correo (24 h) |
| `0006_mfa` | TOTP cifrado, anti-replay, códigos de respaldo y "un admin activo tiene MFA" |
| `0007_correo_simulado_geo` | buzón del correo simulado y rangos IP → ubicación aproximada |
| `0008_espacios` | espacios de trabajo y miembros (propietario único, techo de rol de cuenta) |
| `0009_documentos` | documentos, permisos por documento, `rol_efectivo_documento` y aviso `NOTIFY` de permisos |
| `0010_contenido` | actualizaciones Yjs, versiones de solo inserción con cadena de hash, comentarios y presencia |
| `0011_ia` | embeddings aislados por espacio y acceso, búsqueda semántica y uso diario de IA |
| `0012_rol_aplicacion` | rol `cuaderno_app` con privilegios mínimos para el backend |

## Rol de aplicación (privilegios mínimos)

Hay dos usuarios de base de datos:

| Usuario | Para qué |
|---|---|
| `cuaderno` (`PGUSER`) | Dueño de las tablas. Solo lo usan las migraciones y las pruebas. |
| `cuaderno_app` (`CUADERNO_APP_PASSWORD`) | El único usuario con el que se conecta el backend. |

Al no ser dueño de las tablas, `cuaderno_app` **no puede**:

- desactivar triggers;
- cambiar el esquema;
- hacer `TRUNCATE`;
- usar `session_replication_role`;
- escribir en `schema_migrations`;
- modificar o borrar versiones, ni reescribir actualizaciones Yjs. Esto lo impide por privilegio, además del trigger.

Las pruebas `tests/sql/0012_rol_aplicacion.test.sql` lo intentan una por una.

`db-up.bat` habilita el LOGIN del rol y le pone la contraseña de `.env` (`scripts/usuario-app.mjs`). Los roles son de todo el servidor, no de una base, así que este paso no toca tablas ni datos.

Cada regla, con su prueba y su mutación, está documentada en dos archivos:

- [docs/esquema-identidad.md](docs/esquema-identidad.md) (migraciones 0002–0007)
- [docs/esquema-dominio.md](docs/esquema-dominio.md) (migraciones 0008–0011)

## Pruebas

- **SQL** (`tests/sql/*.test.sql`): cada caso empieza con `-- @test <nombre>` y corre en su propia transacción, que termina siempre en `ROLLBACK`. Las aserciones son las funciones del esquema `prueba`: `afirmar`, `afirmar_igual` y `afirmar_error` (exige el SQLSTATE exacto). Los apoyos `tests/sql/_*.sql` se cargan antes de las pruebas: primero las aserciones y luego las fábricas de datos ficticios.
- **Vitest** (`tests/unitarias`, `tests/integracion`): las de integración corren contra Postgres real, en bases temporales `*_test`.
- **Mutaciones** (`mutations/catalogo.json`): cada regla crítica se rompe a propósito y algún test tiene que fallar. Antes, una corrida base sin mutaciones tiene que pasar; si no pasa, el runner aborta. De cada mutación detectada se muestra como evidencia la primera prueba que falló. Una mutación declarada equivalente se informa aparte y no cuenta como detectada.

Por seguridad, ninguna operación destructiva acepta un nombre de base que no termine en `_test`.
