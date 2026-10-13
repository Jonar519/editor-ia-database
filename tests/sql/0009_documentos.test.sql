-- Documentos, permisos y rol efectivo.

-- @test un documento se crea con su propietario
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(ana, d), 'propietario'::text, 'creador propietario');
END $$;

-- @test un documento sin propietario no se puede confirmar
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO documentos (espacio_id, titulo, creado_por) VALUES (%L, 'Huérfano', %L); SET CONSTRAINTS ALL IMMEDIATE$q$, e, ana),
    '23514', 'documento sin propietario');
END $$;

-- @test un solo propietario por documento y no se puede quitar
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.miembro(e, bruno, 'editor');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.permiso(%L, %L, 'propietario')$q$, d, bruno), '23505', 'segundo propietario');
  PERFORM prueba.afirmar_error(format(
    $q$DELETE FROM permisos_documento WHERE documento_id = %L AND usuario_id = %L$q$, d, ana), '23514', 'quitar al propietario');
END $$;

-- @test solo un editor o propietario del espacio crea documentos
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  carla uuid := prueba.cuenta_activa('carla@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'lector');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.documento(%L, %L)$q$, e, bruno), '42501', 'lector del espacio');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.documento(%L, %L)$q$, e, carla), '42501', 'no miembro');
END $$;

-- @test FK compuesta: solo se da permiso a miembros del espacio del documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  extra uuid := prueba.cuenta_activa('extra@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.permiso(%L, %L, 'lector')$q$, d, extra), '23503', 'permiso a no miembro');
END $$;

-- @test FK compuesta: el permiso no puede declarar otro espacio que el del documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e1 uuid := prueba.espacio(ana, 'Uno');
  e2 uuid := prueba.espacio(bruno, 'Dos');
  d uuid := prueba.documento(e1, ana);
BEGIN
  -- Bruno es miembro del espacio 2, no del 1: declarar el espacio 2 para un documento del 1 no cuela.
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO permisos_documento (documento_id, espacio_id, usuario_id, rol) VALUES (%L, %L, %L, 'editor')$q$, d, e2, bruno),
    '23503', 'permiso cruzando espacios');
END $$;

-- @test sacar a alguien del espacio borra sus permisos de documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'lector');
  PERFORM prueba.permiso(d, bruno, 'editor');
  DELETE FROM miembros_espacio WHERE espacio_id = e AND usuario_id = bruno;
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(bruno, d), NULL::text, 'sin acceso');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM permisos_documento WHERE usuario_id = bruno), 0::bigint, 'permisos borrados');
END $$;

-- @test un documento no cambia de espacio
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e1 uuid := prueba.espacio(ana, 'Uno');
  e2 uuid := prueba.espacio(ana, 'Dos');
  d uuid := prueba.documento(e1, ana);
BEGIN
  PERFORM prueba.afirmar_error(format($q$UPDATE documentos SET espacio_id = %L WHERE id = %L$q$, e2, d), '23514', 'mover de espacio');
END $$;

-- @test rol efectivo: matriz de casos
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  ed uuid := prueba.cuenta_activa('editor@example.com');
  lec uuid := prueba.cuenta_activa('lector@example.com');
  sub uuid := prueba.cuenta_activa('subido@example.com');
  ext uuid := prueba.cuenta_activa('externo@example.com');
  e uuid := prueba.espacio(ana);
  d uuid;
  d2 uuid;
BEGIN
  PERFORM prueba.miembro(e, ed, 'editor');
  PERFORM prueba.miembro(e, lec, 'lector');
  PERFORM prueba.miembro(e, sub, 'lector');
  d := prueba.documento(e, ed);
  d2 := prueba.documento(e, ed);
  PERFORM prueba.permiso(d, sub, 'editor');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(ed, d), 'propietario'::text, 'propietario del documento');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(ana, d), 'editor'::text, 'propietario del espacio = editor');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(lec, d), 'lector'::text, 'lector del espacio');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(sub, d), 'editor'::text, 'permiso de documento sube el rol');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(sub, d2), 'lector'::text, 'solo en ese documento');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(ext, d), NULL::text, 'no miembro');
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(ana, gen_random_uuid()), NULL::text, 'documento inexistente');
END $$;

-- @test rol efectivo: una cuenta lectora nunca pasa de lector (aunque se salten el trigger)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  lec uuid := prueba.cuenta_activa('lectora@example.com', 'lector');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, lec, 'lector');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.permiso(%L, %L, 'editor')$q$, d, lec), '42501', 'permiso editor a lectora');
  -- Segunda capa: aun si alguien desactiva el trigger del techo, el rol efectivo no sube.
  SET CONSTRAINTS ALL IMMEDIATE;
  ALTER TABLE permisos_documento DISABLE TRIGGER permisos_documento_techo_rol_cuenta;
  PERFORM prueba.permiso(d, lec, 'editor');
  ALTER TABLE permisos_documento ENABLE TRIGGER permisos_documento_techo_rol_cuenta;
  PERFORM prueba.afirmar_igual(rol_efectivo_documento(lec, d), 'lector'::text, 'techo en el rol efectivo');
END $$;

-- @test bajar a lectora exige quitar también los permisos de documento que escriben
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'lector');
  PERFORM prueba.permiso(d, bruno, 'editor');
  PERFORM prueba.afirmar_error(format($q$UPDATE usuarios SET rol = 'lector' WHERE id = %L$q$, bruno), '42501', 'editor de documento pasa a lector');
END $$;

-- @test título recortado y de 1 a 200 caracteres
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.documento(%L, %L, '')$q$, e, ana), '23514', 'título vacío');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.documento(%L, %L, repeat('x', 201))$q$, e, ana), '23514', 'título largo');
END $$;
