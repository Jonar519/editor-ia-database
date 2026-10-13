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

`db-up.bat` genera `.env` por sí solo la primera vez, con una contraseña local aleatoria de 24 bytes, así que el bloque se puede reproducir en cualquier computador sin pasos manuales. Si `.env` ya existe, no lo toca.

**Ojo:** Postgres fija la contraseña cuando crea el volumen. Si borras `.env` pero conservas el volumen, la contraseña nueva no coincidirá. En ese caso tienes dos opciones:

- recuperar tu `.env` anterior, o
- recrear la base desde cero con `docker compose down -v`, que **borra los datos locales**.

## Scripts

Todos los `.bat` están en `scripts\` y se pueden ejecutar desde cualquier carpeta.

| Script | Qué hace |
|---|---|
| `env-init.bat` | Crea `.env` con una contraseña local aleatoria. No sobrescribe uno existente. `db-up.bat` lo llama automáticamente. |
| `db-up.bat` / `db-down.bat` | `db-up.bat` crea `.env` si falta y levanta los contenedores esperando el healthcheck. `db-down.bat` los detiene. Los datos se conservan. |
| `db-migrate.bat dev\|test [--estado]` | Aplica las migraciones pendientes, o solo muestra su estado. |
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

## Pruebas

- **SQL** (`tests/sql/*.test.sql`): cada caso empieza con `-- @test <nombre>` y corre en su propia transacción, que termina siempre en `ROLLBACK`. Las aserciones son las funciones del esquema `prueba`: `afirmar`, `afirmar_igual` y `afirmar_error` (exige el SQLSTATE exacto).
- **Vitest** (`tests/unitarias`, `tests/integracion`): las de integración corren contra Postgres real, en bases temporales `*_test`.
- **Mutaciones** (`mutations/catalogo.json`): cada regla crítica se rompe a propósito y algún test tiene que fallar. Antes, una corrida base sin mutaciones tiene que pasar; si no pasa, el runner aborta. Una mutación declarada equivalente se informa aparte y no cuenta como detectada.

Por seguridad, ninguna operación destructiva acepta un nombre de base que no termine en `_test`.
