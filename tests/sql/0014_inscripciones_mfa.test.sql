-- Inscripción MFA de un admin pendiente: ligada a su invitación, solo admin, vencimiento acotado.

-- @test un admin pendiente con invitación puede tener su inscripción
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
  inv uuid := prueba.invitacion(uid);
BEGIN
  INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
  VALUES (inv, uid, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour');
END $$;

-- @test solo cuentas admin
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('editor@example.com', 'editor');
  inv uuid := prueba.invitacion(uid);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
       VALUES (%L, %L, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour')$q$, inv, uid),
    '23514', 'inscripción de un editor');
END $$;

-- @test el vencimiento nunca supera al de la invitación
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
  inv uuid := prueba.invitacion(uid);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
       VALUES (%L, %L, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '73 hours')$q$, inv, uid),
    '23514', 'vence después que la invitación');
END $$;

-- @test FK compuesta: es de ESA invitación y ESA cuenta
DO $$
DECLARE
  a uuid := prueba.cuenta_pendiente('admin.a@example.com', 'admin');
  b uuid := prueba.cuenta_pendiente('admin.b@example.com', 'admin');
  inv_a uuid := prueba.invitacion(a);
BEGIN
  PERFORM prueba.invitacion(b);
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
       VALUES (%L, %L, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour')$q$, inv_a, b),
    '23503', 'invitación de otra cuenta');
END $$;

-- @test CHECK: no puede declararse de una cuenta activa
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
  inv uuid := prueba.invitacion(uid);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, estado_usuario, secreto_cifrado, iv, etiqueta, expira_en)
       VALUES (%L, %L, 'activa', prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour')$q$, inv, uid),
    '23514', 'declarada activa');
END $$;

-- @test una por invitación, como máximo 5 intentos y secreto inmutable
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
  inv uuid := prueba.invitacion(uid);
  i uuid;
BEGIN
  INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
  VALUES (inv, uid, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour') RETURNING id INTO i;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
       VALUES (%L, %L, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour')$q$, inv, uid),
    '23505', 'segunda inscripción');
  UPDATE inscripciones_mfa SET intentos = 5 WHERE id = i;
  PERFORM prueba.afirmar_error(format($q$UPDATE inscripciones_mfa SET intentos = 6 WHERE id = %L$q$, i), '23514', 'sexto intento');
  PERFORM prueba.afirmar_error(format($q$UPDATE inscripciones_mfa SET secreto_cifrado = prueba.bytes(20) WHERE id = %L$q$, i), '23514', 'cambiar secreto');
END $$;

-- @test desaparece en cascada con la invitación (al completar, cancelar o reenviar)
DO $$
DECLARE
  uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
  inv uuid := prueba.invitacion(uid);
BEGIN
  INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
  VALUES (inv, uid, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour');
  DELETE FROM invitaciones WHERE id = inv;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM inscripciones_mfa WHERE usuario_id = uid), 0::bigint, 'borrada en cascada');
END $$;
