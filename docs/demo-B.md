# Demo · Bloque B: esquema de identidad

**Rol:** ninguno. Todavía no hay backend ni interfaz: se prueba directo contra la base.
**Terminal:** `cmd.exe`, en la carpeta `editor-ia-database`.
**Datos:** solo ficticios (`@example.com`).

## 1. Servicios arriba y huella antes de empezar

```bat
scripts\db-up.bat
scripts\db-huella.bat tomar demo-b-antes
```

## 2. Pruebas: cada regla intenta violarse

```bat
scripts\db-test.bat
```

**Qué debes ver:**

- Vitest con todos los archivos en `passed`.
- Las pruebas SQL caso por caso, agrupadas por archivo: `0002_usuarios`, `0003_invitaciones`, `0004_sesiones`, `0005_tokens_cuenta`, `0006_mfa` y `0007_correo_simulado_geo`.
- Al final, `Pruebas SQL: 83 OK, 0 fallidas (base cuaderno_test).` y `test:unit exit=0   test:sql exit=0`.

Para correr un solo archivo SQL: `scripts\db-test.bat sesiones`.

## 3. Mutaciones: quitar el CHECK y la clave foránea compuesta

Primero, las 10 mutaciones que quitan el CHECK o reemplazan la clave foránea compuesta por una simple, en las cinco tablas:

```bat
scripts\mutar.bat B01 B02 B03 B04 B05 B06 B07 B08 B09 B10
```

**Qué debes ver:** cada una con `DETECTADA` y una línea `evidencia:` con el nombre de la prueba que falló. Por ejemplo:

- `B03 ... evidencia: FALLA CHECK: una sesión no puede declararse de una cuenta pendiente`
- `B04 ... evidencia: FALLA FK compuesta: una cuenta pendiente no puede tener sesiones`

Al final: `Detectadas 10, sobreviven 0, equivalentes 0, errores 0 (de 10).`

Después, el catálogo completo (61 mutaciones, unos 2 minutos en mi máquina):

```bat
scripts\mutar.bat
```

## 4. Verlo con tus propias manos en psql (opcional)

Abre una consola SQL sobre la base de **pruebas**:

```bat
docker exec -it cuaderno_postgres psql -U cuaderno -d cuaderno_test
```

Y dentro de psql:

```sql
BEGIN;
INSERT INTO usuarios (correo, nombre, rol) VALUES ('demo@example.com', 'Demo', 'editor');
-- Una cuenta pendiente no puede tener sesiones (debe fallar con "violates foreign key constraint"):
INSERT INTO sesiones (usuario_id, expira_en)
  SELECT id, now() + interval '1 day' FROM usuarios WHERE correo = 'demo@example.com';
ROLLBACK;
```

Escribe `\q` para salir. El `ROLLBACK` deja la base de pruebas como estaba.

## 5. Migrar tu base de desarrollo (cuando quieras)

```bat
scripts\db-migrate.bat dev --estado
scripts\db-migrate.bat dev
```

**Qué debes ver:**

- El primero solo lista las pendientes (de `0002_usuarios.sql` a `0007_correo_simulado_geo.sql`). Usa una conexión de solo lectura y no escribe nada.
- El segundo aplica las migraciones e informa cuántas aplicó.

## 6. Comparar la huella

Si **no** hiciste el paso 5:

```bat
scripts\db-huella.bat comparar demo-b-antes
```

**Qué debes ver:** `IGUALES: la base de desarrollo no cambió.`

Si hiciste el paso 5, la comparación muestra las tablas nuevas. Es lo esperado, porque ese paso sí escribe en tu base.

## 7. Todo lo que corre el CI

```bat
scripts\ci.bat
```

**Qué debes ver:** `exit 0` en cada paso y `RESULTADO: OK`.
