-- MFA TOTP y códigos de respaldo.

-- @test FK compuesta: una cuenta pendiente no puede tener MFA
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.mfa(%L)$q$, uid), '23503', 'MFA de cuenta pendiente');
END $$;

-- @test CHECK: el MFA no puede declararse de una cuenta pendiente
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO mfa_totp (usuario_id, estado_usuario, secreto_cifrado, iv, etiqueta) VALUES (%L, 'pendiente', prueba.bytes(20), prueba.bytes(12), prueba.bytes(16))$q$, uid),
    '23514', 'MFA declarado pendiente');
END $$;

-- @test el cifrado guarda IV de 12 y etiqueta de 16 bytes (AES-GCM)
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta) VALUES (%L, prueba.bytes(20), prueba.bytes(16), prueba.bytes(16))$q$, uid),
    '23514', 'IV de 16 bytes');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta) VALUES (%L, prueba.bytes(20), prueba.bytes(12), prueba.bytes(8))$q$, uid),
    '23514', 'etiqueta de 8 bytes');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta) VALUES (%L, prueba.bytes(8), prueba.bytes(12), prueba.bytes(16))$q$, uid),
    '23514', 'secreto corto');
END $$;

-- @test anti-replay: el último paso TOTP solo crece
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.mfa(uid);
  UPDATE mfa_totp SET ultimo_paso = 100 WHERE usuario_id = uid;
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET ultimo_paso = 100 WHERE usuario_id = %L$q$, uid), '23514', 'mismo paso');
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET ultimo_paso = 99 WHERE usuario_id = %L$q$, uid), '23514', 'paso anterior');
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET ultimo_paso = NULL WHERE usuario_id = %L$q$, uid), '23514', 'borrar el paso');
  UPDATE mfa_totp SET ultimo_paso = 101 WHERE usuario_id = uid;
END $$;

-- @test el secreto cifrado es inmutable
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.mfa(uid);
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET secreto_cifrado = prueba.bytes(20) WHERE usuario_id = %L$q$, uid), '23514', 'cambiar secreto');
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET iv = prueba.bytes(12) WHERE usuario_id = %L$q$, uid), '23514', 'cambiar IV');
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET confirmado_en = NULL WHERE usuario_id = %L$q$, uid), '23514', 'desconfirmar');
END $$;

-- @test un admin no puede activarse sin MFA confirmado (restricción diferida)
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'activa', hash_contrasena = prueba.hash_scrypt(), activada_en = now() WHERE id = %L;
       SET CONSTRAINTS ALL IMMEDIATE$q$, uid),
    '23514', 'admin activo sin MFA');
END $$;

-- @test un admin se activa con MFA en la misma transacción
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('admin@example.com', 'admin');
BEGIN
  PERFORM prueba.activar(uid);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_igual((SELECT estado FROM usuarios WHERE id = uid), 'activa'::text, 'admin activo');
END $$;

-- @test un admin activo no puede quitarse el MFA ni ascender un editor sin MFA
DO $$
DECLARE
  admin uuid := prueba.cuenta_activa('admin@example.com', 'admin');
  editor uuid := prueba.cuenta_activa('editor@example.com', 'editor');
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_error(format($q$DELETE FROM mfa_totp WHERE usuario_id = %L; SET CONSTRAINTS ALL IMMEDIATE$q$, admin),
    '23514', 'admin borra su MFA');
  PERFORM prueba.afirmar_error(format($q$UPDATE usuarios SET rol = 'admin' WHERE id = %L; SET CONSTRAINTS ALL IMMEDIATE$q$, editor),
    '23514', 'editor ascendido sin MFA');
END $$;

-- @test MFA es opcional para editor y lector
DO $$
BEGIN
  PERFORM prueba.cuenta_activa('editor@example.com', 'editor');
  PERFORM prueba.cuenta_activa('lector@example.com', 'lector');
  SET CONSTRAINTS ALL IMMEDIATE;
END $$;

-- @test códigos de respaldo: dependen del MFA y como máximo 10
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  pendiente uuid := prueba.cuenta_pendiente('pendiente@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (%L, prueba.bytes(32))$q$, uid),
    '23503', 'códigos sin MFA');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (%L, prueba.bytes(32))$q$, pendiente),
    '23503', 'códigos de cuenta pendiente');
  PERFORM prueba.mfa(uid);
  INSERT INTO codigos_respaldo (usuario_id, hash_codigo) SELECT uid, prueba.bytes(32) FROM generate_series(1, 10);
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (%L, prueba.bytes(32))$q$, uid),
    '23514', 'código número 11');
END $$;

-- @test códigos de respaldo: solo hash, un solo uso y se borran con el MFA
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  c uuid;
BEGIN
  PERFORM prueba.mfa(uid);
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (%L, 'ABCD-1234'::bytea)$q$, uid),
    '23514', 'código en claro');
  INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (uid, prueba.bytes(32)) RETURNING id INTO c;
  UPDATE codigos_respaldo SET usado_en = now() WHERE id = c;
  PERFORM prueba.afirmar_error(format($q$UPDATE codigos_respaldo SET usado_en = NULL WHERE id = %L$q$, c), '23514', 'reusar código');
  DELETE FROM mfa_totp WHERE usuario_id = uid;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM codigos_respaldo), 0::bigint, 'códigos borrados con el MFA');
END $$;
