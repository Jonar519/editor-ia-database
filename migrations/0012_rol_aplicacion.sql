-- 0012 · Rol de aplicación con privilegios mínimos (cuaderno_app).
--
-- El backend se conecta como cuaderno_app, NUNCA como el dueño de las tablas. Como no es dueño:
--   - no puede desactivar triggers (ALTER TABLE ... DISABLE TRIGGER exige ser dueño),
--   - no puede cambiar el esquema (sin CREATE en el esquema public, sin DDL sobre tablas ajenas),
--   - no puede hacer TRUNCATE (no se concede), ni cambiar session_replication_role (exige superusuario).
-- Además, por privilegio y no solo por trigger: no modifica ni borra versiones, no reescribe
-- actualizaciones Yjs y solo lee schema_migrations.
--
-- Los roles son de todo el servidor (no de una base): aquí se crea sin LOGIN si no existe. La contraseña
-- y el LOGIN los pone scripts/usuario-app.mjs con CUADERNO_APP_PASSWORD de .env, nunca una migración.
--
-- No hay privilegios por defecto para tablas futuras A PROPÓSITO: cada migración nueva concede lo suyo
-- explícitamente, y una prueba SQL falla si alguna tabla queda sin privilegios definidos para la app.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cuaderno_app') THEN
    CREATE ROLE cuaderno_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO cuaderno_app', current_database());
END
$$;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO cuaderno_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cuaderno_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cuaderno_app;

-- Excepciones: solo lectura o solo inserción.
REVOKE INSERT, UPDATE, DELETE ON schema_migrations FROM cuaderno_app;
REVOKE UPDATE, DELETE ON versiones FROM cuaderno_app;
REVOKE UPDATE ON actualizaciones_documento FROM cuaderno_app;
