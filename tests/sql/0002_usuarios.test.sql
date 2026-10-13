-- Cuentas: ciclo de vida, formatos y lápida. Cada caso intenta violar una regla.

-- @test una cuenta pendiente existe sin contraseña
SELECT prueba.cuenta_pendiente('ana@example.com');
SELECT prueba.afirmar_igual(
  (SELECT hash_contrasena FROM usuarios WHERE correo = 'ana@example.com'), NULL::text, 'sin contraseña');
SELECT prueba.afirmar_igual(
  (SELECT estado FROM usuarios WHERE correo = 'ana@example.com'), 'pendiente'::text, 'nace pendiente');

-- @test una cuenta pendiente no puede tener contraseña
SELECT prueba.cuenta_pendiente('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET hash_contrasena = prueba.hash_scrypt() WHERE correo = 'ana@example.com'$q$,
  '23514', 'pendiente con contraseña');

-- @test no se puede crear una cuenta directamente activa
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (correo, nombre, rol, estado, hash_contrasena, activada_en)
     VALUES ('bruno@example.com', 'Bruno', 'editor', 'activa', prueba.hash_scrypt(), now())$q$,
  '23514', 'alta directa activa');

-- @test no se puede crear una cuenta directamente eliminada
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (rol, estado, eliminada_en) VALUES ('editor', 'eliminada', now())$q$,
  '23514', 'alta directa eliminada');

-- @test activar exige contraseña y fecha de activación
SELECT prueba.cuenta_pendiente('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'activa', activada_en = now() WHERE correo = 'ana@example.com'$q$,
  '23514', 'activa sin contraseña');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'activa', hash_contrasena = prueba.hash_scrypt() WHERE correo = 'ana@example.com'$q$,
  '23514', 'activa sin activada_en');

-- @test pendiente pasa a activa
SELECT prueba.cuenta_activa('ana@example.com');
SELECT prueba.afirmar_igual(
  (SELECT estado FROM usuarios WHERE correo = 'ana@example.com'), 'activa'::text, 'activada');

-- @test una cuenta activa no vuelve a pendiente
SELECT prueba.cuenta_activa('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'pendiente', hash_contrasena = NULL, activada_en = NULL WHERE correo = 'ana@example.com'$q$,
  '23514', 'activa → pendiente');

-- @test una cuenta pendiente no pasa directo a eliminada
SELECT prueba.cuenta_pendiente('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'eliminada', correo = NULL, nombre = NULL, eliminada_en = now() WHERE correo = 'ana@example.com'$q$,
  '23514', 'pendiente → eliminada');

-- @test la eliminación es una lápida sin datos personales
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  UPDATE usuarios SET telefono = '+573001234567' WHERE id = uid;
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL WHERE id = %L$q$, uid),
    '23514', 'lápida con correo y nombre');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL, correo = NULL, nombre = NULL WHERE id = %L$q$, uid),
    '23514', 'lápida con teléfono');
  UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL,
                      correo = NULL, nombre = NULL, telefono = NULL WHERE id = uid;
  PERFORM prueba.afirmar_igual((SELECT estado FROM usuarios WHERE id = uid), 'eliminada'::text, 'lápida creada');
END $$;

-- @test una lápida es definitiva
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL,
                      correo = NULL, nombre = NULL WHERE id = uid;
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'activa', eliminada_en = NULL, correo = 'ana@example.com', nombre = 'Ana', hash_contrasena = prueba.hash_scrypt() WHERE id = %L$q$, uid),
    '23514', 'eliminada → activa');
END $$;

-- @test la lápida libera el correo
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL,
                      correo = NULL, nombre = NULL WHERE id = uid;
  PERFORM prueba.cuenta_pendiente('ana@example.com');
END $$;

-- @test eliminada_en solo y siempre en cuentas eliminadas
SELECT prueba.cuenta_activa('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET eliminada_en = now() WHERE correo = 'ana@example.com'$q$, '23514', 'activa con eliminada_en');

-- @test solo se borran cuentas pendientes
SELECT prueba.cuenta_pendiente('pendiente@example.com');
DELETE FROM usuarios WHERE correo = 'pendiente@example.com';
SELECT prueba.cuenta_activa('activa@example.com');
SELECT prueba.afirmar_error(
  $q$DELETE FROM usuarios WHERE correo = 'activa@example.com'$q$, '23514', 'borrar cuenta activa');

-- @test correo único sin distinguir mayúsculas
SELECT prueba.cuenta_pendiente('ana@example.com');
SELECT prueba.afirmar_error(
  $q$SELECT prueba.cuenta_pendiente('ANA@Example.COM')$q$, '23505', 'correo duplicado');

-- @test formatos de correo, nombre y teléfono
SELECT prueba.afirmar_error(
  $q$SELECT prueba.cuenta_pendiente('sin-arroba.example.com')$q$, '23514', 'correo sin arroba');
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (correo, nombre, rol) VALUES ('a@example.com', ' Ana ', 'editor')$q$, '23514', 'nombre con espacios');
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (correo, nombre, rol) VALUES ('a@example.com', '', 'editor')$q$, '23514', 'nombre vacío');
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (correo, nombre, rol) VALUES ('a@example.com', repeat('x', 81), 'editor')$q$, '23514', 'nombre largo');
SELECT prueba.cuenta_pendiente('tel@example.com');
UPDATE usuarios SET telefono = '+573001234567' WHERE correo = 'tel@example.com';
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET telefono = '3001234567' WHERE correo = 'tel@example.com'$q$, '23514', 'teléfono sin +');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET telefono = '+57 300 1234567' WHERE correo = 'tel@example.com'$q$, '23514', 'teléfono con espacios');

-- @test rol y estado válidos
SELECT prueba.afirmar_error(
  $q$SELECT prueba.cuenta_pendiente('x@example.com', 'superadmin')$q$, '23514', 'rol inventado');
SELECT prueba.afirmar_error(
  $q$INSERT INTO usuarios (correo, nombre, rol, estado) VALUES ('x@example.com', 'X', 'editor', 'suspendida')$q$,
  '23514', 'estado inventado');

-- @test la contraseña solo se guarda como hash scrypt
SELECT prueba.cuenta_pendiente('ana@example.com');
DELETE FROM invitaciones;
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'activa', activada_en = now(), hash_contrasena = 'contraseña-en-claro-123' WHERE correo = 'ana@example.com'$q$,
  '23514', 'texto plano');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET estado = 'activa', activada_en = now(), hash_contrasena = '$2b$12$abcdefghijklmnopqrstuv' WHERE correo = 'ana@example.com'$q$,
  '23514', 'otro algoritmo');

-- @test fallos de login no negativos
SELECT prueba.cuenta_activa('ana@example.com');
SELECT prueba.afirmar_error(
  $q$UPDATE usuarios SET fallos_login = -1 WHERE correo = 'ana@example.com'$q$, '23514', 'fallos negativos');

-- @test solo un admin activo puede invitar
DO $$
DECLARE
  admin uuid := prueba.cuenta_activa('admin@example.com', 'admin');
  editor uuid := prueba.cuenta_activa('editor@example.com', 'editor');
  pendiente uuid := prueba.cuenta_pendiente('admin2@example.com', 'admin');
BEGIN
  PERFORM prueba.cuenta_pendiente('nueva@example.com', 'lector', admin);
  PERFORM prueba.afirmar_error(format(
    $q$SELECT prueba.cuenta_pendiente('otra@example.com', 'lector', %L)$q$, editor), '23514', 'invita un editor');
  PERFORM prueba.afirmar_error(format(
    $q$SELECT prueba.cuenta_pendiente('otra@example.com', 'lector', %L)$q$, pendiente), '23514', 'invita un admin pendiente');
END $$;

-- @test la base fija creado_en y actualizado_en
DO $$
DECLARE uid uuid;
BEGIN
  INSERT INTO usuarios (correo, nombre, rol, creado_en) VALUES ('ana@example.com', 'Ana', 'editor', '2000-01-01')
  RETURNING id INTO uid;
  PERFORM prueba.afirmar_igual((SELECT creado_en FROM usuarios WHERE id = uid), now(), 'creado_en lo pone la base');
  UPDATE usuarios SET nombre = 'Ana María', actualizado_en = '2000-01-01' WHERE id = uid;
  PERFORM prueba.afirmar_igual((SELECT actualizado_en FROM usuarios WHERE id = uid), now(), 'actualizado_en lo pone la base');
END $$;
