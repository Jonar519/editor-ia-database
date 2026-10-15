-- Registro de auditoría: solo inserción, solo anonimizar, retención de 180 días, sin texto libre.

-- @test se registra un evento con cuenta e IP truncada
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id, ip_red) VALUES ('inicio_sesion', uid, '203.0.113.0/24');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE usuario_id = uid), 1::bigint, 'registrado');
END $$;

-- @test sin texto libre: un tipo fuera de la lista (como un token) se rechaza
SELECT prueba.afirmar_error(
  $q$INSERT INTO eventos_seguridad (tipo) VALUES ('token=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG')$q$, '23514', 'tipo con un token');
SELECT prueba.afirmar_error(
  $q$INSERT INTO eventos_seguridad (tipo) VALUES ('contrasena: una frase larga')$q$, '23514', 'tipo con una contraseña');

-- @test la IP se guarda truncada
SELECT prueba.afirmar_error(
  $q$INSERT INTO eventos_seguridad (tipo, ip_red) VALUES ('inicio_fallido', '203.0.113.7/32')$q$, '23514', 'IP completa');

-- @test solo inserción: no se puede cambiar el tipo, la fecha ni reasignar la cuenta
DO $$
DECLARE
  a uuid := prueba.cuenta_activa('a@example.com');
  b uuid := prueba.cuenta_activa('b@example.com');
  e bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id) VALUES ('inicio_fallido', a) RETURNING id INTO e;
  PERFORM prueba.afirmar_error(format($q$UPDATE eventos_seguridad SET tipo = 'inicio_sesion' WHERE id = %s$q$, e), '42501', 'cambiar el tipo');
  PERFORM prueba.afirmar_error(format($q$UPDATE eventos_seguridad SET usuario_id = %L WHERE id = %s$q$, b, e), '42501', 'reasignar la cuenta');
  PERFORM prueba.afirmar_error(format($q$UPDATE eventos_seguridad SET creado_en = now() - interval '1 day' WHERE id = %s$q$, e), '42501', 'cambiar la fecha');
END $$;

-- @test anonimizar sí: cuenta e IP a NULL
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  e bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id, ip_red) VALUES ('inicio_sesion', uid, '203.0.113.0/24') RETURNING id INTO e;
  UPDATE eventos_seguridad SET usuario_id = NULL, ip_red = NULL WHERE id = e;
  PERFORM prueba.afirmar((SELECT usuario_id IS NULL AND ip_red IS NULL FROM eventos_seguridad WHERE id = e), 'anonimizado');
END $$;

-- @test borrar: solo eventos más antiguos que la retención (180 días); TRUNCATE prohibido
DO $$
DECLARE e bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo) VALUES ('inicio_fallido') RETURNING id INTO e;
  PERFORM prueba.afirmar_error(format($q$DELETE FROM eventos_seguridad WHERE id = %s$q$, e), '42501', 'borrar uno reciente');
  PERFORM prueba.afirmar_error('TRUNCATE eventos_seguridad', '42501', 'TRUNCATE');
  -- Un evento viejo (se envejece como dueño, desactivando el trigger) sí se puede borrar.
  ALTER TABLE eventos_seguridad DISABLE TRIGGER eventos_seguridad_solo_insercion;
  UPDATE eventos_seguridad SET creado_en = now() - interval '181 days' WHERE id = e;
  ALTER TABLE eventos_seguridad ENABLE TRIGGER eventos_seguridad_solo_insercion;
  DELETE FROM eventos_seguridad WHERE id = e;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE id = e), 0::bigint, 'borrado por retención');
END $$;

-- @test borrar una cuenta pendiente anonimiza sus eventos (no los borra)
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('pendiente@example.com');
  e bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id) VALUES ('invitacion_creada', uid) RETURNING id INTO e;
  DELETE FROM usuarios WHERE id = uid;
  PERFORM prueba.afirmar((SELECT usuario_id IS NULL FROM eventos_seguridad WHERE id = e), 'evento conservado y anonimizado');
END $$;

-- @test la aplicación (cuaderno_app) solo puede anonimizar, no reescribir columnas
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  e bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id) VALUES ('inicio_sesion', uid) RETURNING id INTO e;
  SET CONSTRAINTS ALL IMMEDIATE;
  ALTER TABLE eventos_seguridad DISABLE TRIGGER eventos_seguridad_solo_insercion;
  SET LOCAL ROLE cuaderno_app;
  -- Sin el trigger, el PRIVILEGIO por columna igual impide cambiar el tipo.
  PERFORM prueba.afirmar_error(format($q$UPDATE eventos_seguridad SET tipo = 'mfa_correcto' WHERE id = %s$q$, e), '42501', 'UPDATE del tipo por privilegio');
  RESET ROLE;
  ALTER TABLE eventos_seguridad ENABLE TRIGGER eventos_seguridad_solo_insercion;
END $$;
