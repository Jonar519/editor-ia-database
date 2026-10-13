-- Invitaciones: solo para cuentas pendientes, de un solo uso, máximo 72 h, solo el hash.

-- @test se puede invitar una cuenta pendiente
SELECT prueba.invitacion(prueba.cuenta_pendiente('ana@example.com'));
SELECT prueba.afirmar_igual((SELECT count(*) FROM invitaciones), 1::bigint, 'una invitación');

-- @test FK compuesta: no hay invitación para una cuenta activa
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.invitacion(%L)$q$, uid), '23503', 'invitación a cuenta activa');
END $$;

-- @test CHECK: estado_usuario no puede declararse activa
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, estado_usuario, token_hash, expira_en)
       VALUES (%L, 'activa', prueba.bytes(32), now() + interval '1 hour')$q$, uid),
    '23514', 'invitación declarada activa');
END $$;

-- @test activar la cuenta exige consumir (borrar) la invitación: un solo uso
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.invitacion(uid);
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'activa', hash_contrasena = prueba.hash_scrypt(), activada_en = now() WHERE id = %L$q$, uid),
    '23503', 'activar con invitación viva');
  DELETE FROM invitaciones WHERE usuario_id = uid;
  UPDATE usuarios SET estado = 'activa', hash_contrasena = prueba.hash_scrypt(), activada_en = now() WHERE id = uid;
END $$;

-- @test cancelar la invitación borrando la cuenta pendiente arrastra la invitación
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.invitacion(uid);
  DELETE FROM usuarios WHERE id = uid;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM invitaciones), 0::bigint, 'invitación borrada');
END $$;

-- @test vigencia máxima de 72 horas
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (%L, prueba.bytes(32), now() + interval '72 hours 1 second')$q$, uid),
    '23514', '72 h y un segundo');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (%L, prueba.bytes(32), now())$q$, uid),
    '23514', 'vence al crearse');
  INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (uid, prueba.bytes(32), now() + interval '72 hours');
END $$;

-- @test creado_en lo fija la base (no se puede fabricar una invitación más larga)
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, token_hash, creado_en, expira_en)
       VALUES (%L, prueba.bytes(32), now() + interval '10 days', now() + interval '11 days')$q$, uid),
    '23514', 'creado_en en el futuro');
END $$;

-- @test los plazos solo se acortan
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.invitacion(uid);
  UPDATE invitaciones SET expira_en = now() + interval '1 hour' WHERE usuario_id = uid;
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE invitaciones SET expira_en = now() + interval '2 hours' WHERE usuario_id = %L$q$, uid),
    '23514', 'alargar el plazo');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE invitaciones SET creado_en = now() + interval '1 minute' WHERE usuario_id = %L$q$, uid),
    '23514', 'mover creado_en hacia adelante');
END $$;

-- @test solo se guarda un SHA-256, único, y una invitación por cuenta
DO $$
DECLARE
  a uuid := prueba.cuenta_pendiente('ana@example.com');
  b uuid := prueba.cuenta_pendiente('bruno@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (%L, 'token-en-claro'::bytea, now() + interval '1 hour')$q$, a),
    '23514', 'token que no es sha256');
  INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (a, sha256('x'), now() + interval '1 hour');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO invitaciones (usuario_id, token_hash, expira_en) VALUES (%L, sha256('x'), now() + interval '1 hour')$q$, b),
    '23505', 'hash repetido');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.invitacion(%L)$q$, a), '23505', 'segunda invitación');
END $$;
