-- Espacios de trabajo: propietario único, solo cuentas activas, techo de rol de cuenta.

-- @test un espacio se crea con su propietario
DO $$
DECLARE e uuid := prueba.espacio(prueba.cuenta_activa('ana@example.com'));
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_igual((SELECT rol FROM miembros_espacio WHERE espacio_id = e), 'propietario'::text, 'propietario');
END $$;

-- @test un espacio sin propietario no se puede confirmar
DO $$
DECLARE ana uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO espacios (nombre, creado_por) VALUES ('Huérfano', %L); SET CONSTRAINTS ALL IMMEDIATE$q$, ana),
    '23514', 'espacio sin propietario');
END $$;

-- @test no hay dos propietarios ni se puede quitar al único
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.miembro(%L, %L, 'propietario')$q$, e, bruno), '23P01', 'segundo propietario');
  PERFORM prueba.afirmar_error(format(
    $q$DELETE FROM miembros_espacio WHERE espacio_id = %L AND usuario_id = %L$q$, e, ana), '23514', 'quitar al único propietario');
  -- Transferir la propiedad sí se puede: en una transacción, revisado al final (como al COMMIT).
  PERFORM prueba.miembro(e, bruno, 'editor');
  SET CONSTRAINTS ALL DEFERRED;
  UPDATE miembros_espacio SET rol = 'editor' WHERE espacio_id = e AND usuario_id = ana;
  UPDATE miembros_espacio SET rol = 'propietario' WHERE espacio_id = e AND usuario_id = bruno;
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_igual(
    (SELECT usuario_id FROM miembros_espacio WHERE espacio_id = e AND rol = 'propietario'), bruno, 'propiedad transferida');
END $$;

-- @test borrar un espacio completo sí se puede
DO $$
DECLARE e uuid := prueba.espacio(prueba.cuenta_activa('ana@example.com'));
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  DELETE FROM espacios WHERE id = e;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM miembros_espacio), 0::bigint, 'miembros borrados');
END $$;

-- @test FK compuesta: una cuenta pendiente no es miembro
DO $$
DECLARE
  e uuid := prueba.espacio(prueba.cuenta_activa('ana@example.com'));
  p uuid := prueba.cuenta_pendiente('pendiente@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.miembro(%L, %L, 'lector')$q$, e, p), '23503', 'miembro pendiente');
END $$;

-- @test CHECK: una membresía no puede declararse de una cuenta pendiente
DO $$
DECLARE
  e uuid := prueba.espacio(prueba.cuenta_activa('ana@example.com'));
  p uuid := prueba.cuenta_pendiente('pendiente@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO miembros_espacio (espacio_id, usuario_id, estado_usuario, rol) VALUES (%L, %L, 'pendiente', 'lector')$q$, e, p),
    '23514', 'membresía declarada pendiente');
END $$;

-- @test anonimizar una cuenta exige sacarla antes de sus espacios
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'editor');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), hash_contrasena = NULL, correo = NULL, nombre = NULL WHERE id = %L$q$, bruno),
    '23503', 'lápida con membresías');
END $$;

-- @test una cuenta lectora solo puede ser lectora en un espacio
DO $$
DECLARE
  e uuid := prueba.espacio(prueba.cuenta_activa('ana@example.com'));
  lec uuid := prueba.cuenta_activa('lector@example.com', 'lector');
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.miembro(%L, %L, 'editor')$q$, e, lec), '42501', 'lectora como editora');
  PERFORM prueba.miembro(e, lec, 'lector');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE miembros_espacio SET rol = 'editor' WHERE espacio_id = %L AND usuario_id = %L$q$, e, lec), '42501', 'ascender a la lectora');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.espacio(%L)$q$, lec), '42501', 'lectora propietaria de un espacio');
END $$;

-- @test bajar una cuenta a lectora exige quitarle antes los roles que escriben
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'editor');
  PERFORM prueba.afirmar_error(format($q$UPDATE usuarios SET rol = 'lector' WHERE id = %L$q$, bruno), '42501', 'editor de espacio pasa a lector');
  UPDATE miembros_espacio SET rol = 'lector' WHERE espacio_id = e AND usuario_id = bruno;
  UPDATE usuarios SET rol = 'lector' WHERE id = bruno;
END $$;

-- @test nombre del espacio recortado y de 1 a 80 caracteres
DO $$
DECLARE ana uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$INSERT INTO espacios (nombre, creado_por) VALUES ('', %L)$q$, ana), '23514', 'nombre vacío');
  PERFORM prueba.afirmar_error(format($q$INSERT INTO espacios (nombre, creado_por) VALUES (' Equipo ', %L)$q$, ana), '23514', 'con espacios');
END $$;
