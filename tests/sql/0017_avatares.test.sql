-- Avatares: solo cuentas activas, tipo y firma de bytes coherentes, tamaño, dimensiones y hash.

-- @test una cuenta activa guarda su avatar; la app puede reemplazarlo y borrarlo
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.avatar(uid);
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM avatares WHERE usuario_id = uid), 1::bigint, 'guardado');
END $$;
SET LOCAL ROLE cuaderno_app;
UPDATE avatares SET tipo = 'image/png', datos = '\x89504e470d0a1a0a00'::bytea, hash = sha256('\x89504e470d0a1a0a00'::bytea);
DELETE FROM avatares;
SELECT prueba.afirmar_igual((SELECT count(*) FROM avatares), 0::bigint, 'borrado');

-- @test una cuenta pendiente no tiene avatar (CHECK + clave foránea compuesta)
DO $$
DECLARE uid uuid := prueba.cuenta_pendiente('pendiente@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format('SELECT prueba.avatar(%L)', uid), '23503', 'cuenta pendiente');
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, estado_usuario, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'pendiente', 'image/png', '\x89504e470d0a1a0a'::bytea, 1, 1, sha256('\x89504e470d0a1a0a'::bytea))$q$, uid),
    '23514', 'declararse pendiente');
END $$;

-- @test con avatar, la cuenta no cambia de estado (hay que borrarlo antes de anonimizarla)
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.avatar(uid);
  PERFORM prueba.afirmar_error(format($q$
    UPDATE usuarios SET estado = 'eliminada', eliminada_en = now(), correo = NULL, nombre = NULL, hash_contrasena = NULL
    WHERE id = %L$q$, uid), '23503', 'anonimizar con avatar');
END $$;

-- @test solo JPEG o PNG (un SVG, que puede llevar scripts, no entra)
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/svg+xml', '\x3c737667'::bytea, 1, 1, sha256('\x3c737667'::bytea))$q$, uid), '23514', 'svg');
END $$;

-- @test la firma de bytes coincide con el tipo y no hay nada después del fin de un JPEG
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  -- Bytes PNG declarados como JPEG.
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/jpeg', '\x89504e470d0a1a0a'::bytea, 1, 1, sha256('\x89504e470d0a1a0a'::bytea))$q$, uid), '23514', 'png como jpeg');
  -- Termina como un JPEG pero no empieza como uno (un ZIP con FF D9 al final).
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/jpeg', '\x504b0304ffd9'::bytea, 1, 1, sha256('\x504b0304ffd9'::bytea))$q$, uid), '23514', 'zip como jpeg');
  -- Bytes JPEG declarados como PNG.
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/png', '\xffd8ffd9'::bytea, 1, 1, sha256('\xffd8ffd9'::bytea))$q$, uid), '23514', 'jpeg como png');
  -- Un JPEG con datos pegados después de FF D9 (por ejemplo, un ZIP escondido).
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/jpeg', '\xffd8ffd9504b0304'::bytea, 1, 1, sha256('\xffd8ffd9504b0304'::bytea))$q$, uid), '23514', 'datos tras el fin');
END $$;

-- @test 1 MiB como máximo
DO $$
DECLARE
  uid uuid := prueba.cuenta_activa('ana@example.com');
  grande bytea := '\xffd8ff'::bytea || decode(repeat('00', 1048574), 'hex') || '\xffd9'::bytea;
BEGIN
  PERFORM prueba.afirmar_igual(octet_length(grande), 1048579, 'tamaño de la prueba');
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash) VALUES (%L, 'image/jpeg', %L::bytea, 1, 1, sha256(%L::bytea))$q$,
    uid, grande, grande), '23514', 'más de 1 MiB');
END $$;

-- @test dimensiones de 1 a 4096 px
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/png', '\x89504e470d0a1a0a'::bytea, 4097, 10, sha256('\x89504e470d0a1a0a'::bytea))$q$, uid), '23514', 'demasiado ancho');
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/png', '\x89504e470d0a1a0a'::bytea, 10, 0, sha256('\x89504e470d0a1a0a'::bytea))$q$, uid), '23514', 'alto cero');
END $$;

-- @test el hash corresponde a los datos
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.afirmar_error(format($q$
    INSERT INTO avatares (usuario_id, tipo, datos, ancho, alto, hash)
    VALUES (%L, 'image/png', '\x89504e470d0a1a0a'::bytea, 1, 1, sha256('otros datos'::bytea))$q$, uid), '23514', 'hash ajeno');
END $$;
