-- Recuperación de contraseña (15 min) y cambio de correo (24 h): solo cuentas activas, un solo uso.

-- @test recuperación: una cuenta activa puede pedirla
SELECT prueba.cuenta_activa('ana@example.com');
INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en)
SELECT id, prueba.bytes(32), now() + interval '15 minutes' FROM usuarios WHERE correo = 'ana@example.com';

-- @test recuperación FK compuesta: no existe para una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (%L, prueba.bytes(32), now() + interval '15 minutes')$q$, uid),
    '23503', 'recuperación de cuenta pendiente');
END $$;

-- @test recuperación CHECK: no puede declararse de una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_recuperacion (usuario_id, estado_usuario, token_hash, expira_en) VALUES (%L, 'pendiente', prueba.bytes(32), now() + interval '15 minutes')$q$, uid),
    '23514', 'recuperación declarada pendiente');
END $$;

-- @test recuperación: vigencia máxima de 15 minutos
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (%L, prueba.bytes(32), now() + interval '15 minutes 1 second')$q$, uid),
    '23514', '15 min y un segundo');
END $$;

-- @test recuperación: un solo uso y uno vigente por cuenta
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  t uuid;
BEGIN
  INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en)
  VALUES (uid, prueba.bytes(32), now() + interval '15 minutes') RETURNING id INTO t;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (%L, prueba.bytes(32), now() + interval '15 minutes')$q$, uid),
    '23P01', 'dos vigentes');
  UPDATE tokens_recuperacion SET usado_en = now() WHERE id = t;
  PERFORM prueba.afirmar_error(format($q$UPDATE tokens_recuperacion SET usado_en = NULL WHERE id = %L$q$, t), '23514', 'reusar token');
  PERFORM prueba.afirmar_error(format($q$UPDATE tokens_recuperacion SET usado_en = now() - interval '1 minute' WHERE id = %L$q$, t), '23514', 'cambiar usado_en');
  INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (uid, prueba.bytes(32), now() + interval '15 minutes');
END $$;

-- @test cambio de correo: una cuenta activa puede pedirlo
SELECT prueba.cuenta_activa('ana@example.com');
INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en)
SELECT id, 'ana.nueva@example.com', prueba.bytes(32), now() + interval '24 hours' FROM usuarios WHERE correo = 'ana@example.com';

-- @test cambio de correo FK compuesta: no existe para una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (%L, 'x@example.com', prueba.bytes(32), now() + interval '1 hour')$q$, uid),
    '23503', 'cambio de correo de cuenta pendiente');
END $$;

-- @test cambio de correo CHECK: no puede declararse de una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO cambios_correo (usuario_id, estado_usuario, correo_nuevo, token_hash, expira_en) VALUES (%L, 'pendiente', 'x@example.com', prueba.bytes(32), now() + interval '1 hour')$q$, uid),
    '23514', 'cambio declarado pendiente');
END $$;

-- @test cambio de correo: formato, 24 h, uno pendiente y confirmación definitiva
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  c uuid;
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (%L, 'no-es-correo', prueba.bytes(32), now() + interval '1 hour')$q$, uid),
    '23514', 'correo inválido');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (%L, 'x@example.com', prueba.bytes(32), now() + interval '25 hours')$q$, uid),
    '23514', '25 horas');
  INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en)
  VALUES (uid, 'x@example.com', prueba.bytes(32), now() + interval '1 hour') RETURNING id INTO c;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (%L, 'y@example.com', prueba.bytes(32), now() + interval '1 hour')$q$, uid),
    '23P01', 'dos pendientes');
  UPDATE cambios_correo SET confirmado_en = now() WHERE id = c;
  PERFORM prueba.afirmar_error(format($q$UPDATE cambios_correo SET confirmado_en = NULL WHERE id = %L$q$, c), '23514', 'desconfirmar');
  PERFORM prueba.afirmar_error(format($q$UPDATE cambios_correo SET correo_nuevo = 'z@example.com' WHERE id = %L$q$, c), '23514', 'cambiar el correo destino');
END $$;
