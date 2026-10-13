-- Rol de aplicación cuaderno_app: privilegios mínimos. Las fábricas corren como dueño y luego cada
-- caso cambia a cuaderno_app con SET LOCAL ROLE (se deshace con el ROLLBACK del caso).

-- @test el rol no tiene atributos privilegiados
SELECT prueba.afirmar(EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cuaderno_app'), 'existe');
SELECT prueba.afirmar(
  (SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname = 'cuaderno_app'),
  'sin superusuario, createdb, createrole, replication ni bypassrls');
SELECT prueba.afirmar(
  NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tableowner = 'cuaderno_app'), 'no es dueño de ninguna tabla');

-- @test todas las tablas tienen privilegios definidos para la app (una tabla nueva sin GRANT falla aquí)
SELECT prueba.afirmar_igual(
  (SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND NOT has_table_privilege('cuaderno_app', c.oid, 'SELECT')),
  NULL::text, 'tablas sin SELECT para cuaderno_app');

-- @test la app trabaja con normalidad: crea y lee una cuenta pendiente
SET LOCAL ROLE cuaderno_app;
INSERT INTO usuarios (correo, nombre, rol) VALUES ('app@example.com', 'App', 'editor');
SELECT prueba.afirmar_igual((SELECT count(*) FROM usuarios WHERE correo = 'app@example.com'), 1::bigint, 'insertó');

-- @test la app no puede desactivar triggers
SET LOCAL ROLE cuaderno_app;
SELECT prueba.afirmar_error('ALTER TABLE versiones DISABLE TRIGGER versiones_solo_insercion', '42501', 'desactivar trigger');
SELECT prueba.afirmar_error('ALTER TABLE embeddings DISABLE TRIGGER ALL', '42501', 'desactivar todos');

-- @test la app no puede cambiar el esquema ni la replicación
SET LOCAL ROLE cuaderno_app;
SELECT prueba.afirmar_error('CREATE TABLE intrusa (id int)', '42501', 'crear tabla');
SELECT prueba.afirmar_error('DROP TABLE versiones', '42501', 'borrar tabla');
SELECT prueba.afirmar_error('ALTER TABLE usuarios DROP CONSTRAINT usuarios_hash_scrypt', '42501', 'quitar un CHECK');
SELECT prueba.afirmar_error($q$SET session_replication_role = replica$q$, '42501', 'saltarse triggers con replica');

-- @test la app no puede vaciar tablas con TRUNCATE
SET LOCAL ROLE cuaderno_app;
SELECT prueba.afirmar_error('TRUNCATE sesiones', '42501', 'TRUNCATE sesiones');
SELECT prueba.afirmar_error('TRUNCATE usuarios CASCADE', '42501', 'TRUNCATE usuarios');

-- @test la app solo lee schema_migrations
SET LOCAL ROLE cuaderno_app;
SELECT prueba.afirmar((SELECT count(*) > 0 FROM schema_migrations), 'puede leer');
SELECT prueba.afirmar_error($q$DELETE FROM schema_migrations WHERE version = 12$q$, '42501', 'borrar historial');
SELECT prueba.afirmar_error($q$UPDATE schema_migrations SET checksum = repeat('0', 64)$q$, '42501', 'falsear checksum');

-- @test versiones: la app no las modifica ni borra POR PRIVILEGIO (aunque falte el trigger)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  v uuid := prueba.version(d, ana, 'original');
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  -- Se quita el trigger (como dueño) para comprobar que el privilegio, por sí solo, también lo impide.
  ALTER TABLE versiones DISABLE TRIGGER versiones_solo_insercion;
  SET LOCAL ROLE cuaderno_app;
  PERFORM prueba.afirmar_error(format($q$UPDATE versiones SET contenido_texto = 'x' WHERE id = %L$q$, v), '42501', 'UPDATE por privilegio');
  PERFORM prueba.afirmar_error(format($q$DELETE FROM versiones WHERE id = %L$q$, v), '42501', 'DELETE por privilegio');
  RESET ROLE;
  ALTER TABLE versiones ENABLE TRIGGER versiones_solo_insercion;
END $$;

-- @test actualizaciones Yjs: la app inserta pero no reescribe POR PRIVILEGIO
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a bigint;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  ALTER TABLE actualizaciones_documento DISABLE TRIGGER actualizaciones_inmutables;
  SET LOCAL ROLE cuaderno_app;
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a;
  PERFORM prueba.afirmar_error(format($q$UPDATE actualizaciones_documento SET actualizacion = '\x02' WHERE id = %s$q$, a), '42501', 'UPDATE por privilegio');
  RESET ROLE;
  ALTER TABLE actualizaciones_documento ENABLE TRIGGER actualizaciones_inmutables;
END $$;
