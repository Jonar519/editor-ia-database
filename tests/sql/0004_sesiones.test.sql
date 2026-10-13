-- Sesiones y tokens de refresco: solo cuentas activas, IP truncada, rotación y revocación definitiva.

-- @test una cuenta activa puede tener sesiones
SELECT prueba.sesion(prueba.cuenta_activa('ana@example.com'));
SELECT prueba.afirmar_igual((SELECT count(*) FROM sesiones), 1::bigint, 'una sesión');

-- @test FK compuesta: una cuenta pendiente no puede tener sesiones
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.sesion(%L)$q$, uid), '23503', 'sesión de cuenta pendiente');
END $$;

-- @test CHECK: una sesión no puede declararse de una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO sesiones (usuario_id, estado_usuario, expira_en) VALUES (%L, 'pendiente', now() + interval '1 day')$q$, uid),
    '23514', 'sesión declarada pendiente');
END $$;

-- @test una cuenta con sesiones no se puede anonimizar sin cerrarlas
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.sesion(uid);
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL, correo = NULL, nombre = NULL WHERE id = %L$q$, uid),
    '23503', 'lápida con sesiones vivas');
  DELETE FROM sesiones WHERE usuario_id = uid;
  UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL, correo = NULL, nombre = NULL WHERE id = uid;
END $$;

-- @test vigencia máxima de 30 días
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO sesiones (usuario_id, expira_en) VALUES (%L, now() + interval '30 days 1 second')$q$, uid),
    '23514', '30 días y un segundo');
  INSERT INTO sesiones (usuario_id, expira_en) VALUES (uid, now() + interval '30 days');
END $$;

-- @test la revocación exige motivo válido y es definitiva
DO $$
DECLARE s uuid := prueba.sesion(prueba.cuenta_activa('ana@example.com'));
BEGIN
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET revocada_en = now() WHERE id = %L$q$, s), '23514', 'revocar sin motivo');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE sesiones SET revocada_en = now(), motivo_revocacion = 'porque sí' WHERE id = %L$q$, s), '23514', 'motivo inventado');
  UPDATE sesiones SET revocada_en = now(), motivo_revocacion = 'cierre' WHERE id = s;
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE sesiones SET revocada_en = NULL, motivo_revocacion = NULL WHERE id = %L$q$, s), '23514', 'revivir sesión');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE sesiones SET motivo_revocacion = 'admin' WHERE id = %L$q$, s), '23514', 'cambiar el motivo');
END $$;

-- @test la sesión puede registrar uso y acortar su plazo, nunca alargarlo
DO $$
DECLARE s uuid := prueba.sesion(prueba.cuenta_activa('ana@example.com'));
BEGIN
  UPDATE sesiones SET ultimo_uso_en = now(), expira_en = now() + interval '1 hour' WHERE id = s;
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE sesiones SET expira_en = now() + interval '2 days' WHERE id = %L$q$, s), '23514', 'alargar sesión');
END $$;

-- @test la IP se guarda truncada (/24 IPv4, /48 IPv6)
DO $$
DECLARE s uuid := prueba.sesion(prueba.cuenta_activa('ana@example.com'));
BEGIN
  UPDATE sesiones SET ip_red = '203.0.113.0/24' WHERE id = s;
  UPDATE sesiones SET ip_red = '2001:db8:1::/48' WHERE id = s;
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET ip_red = '203.0.113.7/32' WHERE id = %L$q$, s), '23514', 'IPv4 completa');
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET ip_red = '203.0.0.0/16' WHERE id = %L$q$, s), '23514', 'IPv4 /16');
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET ip_red = '2001:db8:1:2::/64' WHERE id = %L$q$, s), '23514', 'IPv6 /64');
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET ip_red = '203.0.113.7/24' WHERE id = %L$q$, s), '22P02', 'bits de host');
END $$;

-- @test user-agent y ubicación recortados
DO $$
DECLARE s uuid := prueba.sesion(prueba.cuenta_activa('ana@example.com'));
BEGIN
  UPDATE sesiones SET user_agent = 'Firefox 140 · Windows', ubicacion = 'Bogotá, CO' WHERE id = s;
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET user_agent = repeat('x', 81) WHERE id = %L$q$, s), '23514', 'user-agent largo');
  PERFORM prueba.afirmar_error(format($q$UPDATE sesiones SET ubicacion = repeat('x', 121) WHERE id = %L$q$, s), '23514', 'ubicación larga');
END $$;

-- @test refresco: un token por sesión, del mismo usuario que la sesión
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  s uuid := prueba.sesion(ana);
BEGIN
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (s, ana, prueba.bytes(32), now() + interval '1 day');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (%L, %L, prueba.bytes(32), now() + interval '1 day')$q$, s, ana),
    '23505', 'dos tokens vigentes en la misma sesión');
END $$;

-- @test refresco: no existe para una cuenta pendiente ni con la sesión de otra cuenta
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  pendiente uuid := prueba.cuenta_pendiente('pendiente@example.com');
  s uuid := prueba.sesion(ana);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (%L, %L, prueba.bytes(32), now() + interval '1 day')$q$, s, pendiente),
    '23503', 'token de cuenta pendiente en sesión ajena');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (gen_random_uuid(), %L, prueba.bytes(32), now() + interval '1 day')$q$, ana),
    '23503', 'token sin sesión');
END $$;

-- @test refresco: rotación marca usado una sola vez y permite el siguiente
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  s uuid := prueba.sesion(ana);
  t uuid;
BEGIN
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en)
  VALUES (s, ana, prueba.bytes(32), now() + interval '1 day') RETURNING id INTO t;
  UPDATE tokens_refresco SET usado_en = now() WHERE id = t;
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (s, ana, prueba.bytes(32), now() + interval '1 day');
  PERFORM prueba.afirmar_error(format($q$UPDATE tokens_refresco SET usado_en = NULL WHERE id = %L$q$, t), '23514', 'reactivar token usado');
  PERFORM prueba.afirmar_error(format($q$UPDATE tokens_refresco SET token_hash = prueba.bytes(32) WHERE id = %L$q$, t), '23514', 'cambiar el hash');
END $$;

-- @test refresco: no se emiten tokens para una sesión revocada y borrar la sesión los borra
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  s uuid := prueba.sesion(ana);
BEGIN
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (s, ana, prueba.bytes(32), now() + interval '1 day');
  UPDATE tokens_refresco SET usado_en = now() WHERE sesion_id = s;
  UPDATE sesiones SET revocada_en = now(), motivo_revocacion = 'reutilizacion_refresco' WHERE id = s;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (%L, %L, prueba.bytes(32), now() + interval '1 day')$q$, s, ana),
    '23514', 'token para sesión revocada');
  DELETE FROM sesiones WHERE id = s;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM tokens_refresco), 0::bigint, 'tokens borrados en cascada');
END $$;

-- @test refresco: solo SHA-256 y vigencia máxima de 30 días
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  s uuid := prueba.sesion(ana);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (%L, %L, 'abc'::bytea, now() + interval '1 day')$q$, s, ana),
    '23514', 'token que no es sha256');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (%L, %L, prueba.bytes(32), now() + interval '31 days')$q$, s, ana),
    '23514', '31 días');
END $$;
