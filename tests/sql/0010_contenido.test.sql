-- Contenido: escritura protegida, versiones de solo inserción con cadena de hash, comentarios y presencia.

-- @test escribir: editor sí; lector, cuenta lectora y externo no
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  lec uuid := prueba.cuenta_activa('lector@example.com');
  lectora uuid := prueba.cuenta_activa('lectora@example.com', 'lector');
  ext uuid := prueba.cuenta_activa('externo@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, lec, 'lector');
  PERFORM prueba.miembro(e, lectora, 'lector');
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (%L, %L, '\x01')$q$, d, lec),
    '42501', 'escribe un lector del espacio');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (%L, %L, '\x01')$q$, d, lectora),
    '42501', 'escribe una cuenta lectora');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (%L, %L, '\x01')$q$, d, ext),
    '42501', 'escribe un externo');
END $$;

-- @test las actualizaciones no se reescriben
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a;
  PERFORM prueba.afirmar_error(format($q$UPDATE actualizaciones_documento SET actualizacion = '\x02' WHERE id = %s$q$, a), '23514', 'reescribir');
END $$;

-- @test versiones: la base numera y encadena (el cliente no elige)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  v1 versiones;
  v2 versiones;
  v3 versiones;
BEGIN
  INSERT INTO versiones (documento_id, motivo, creado_por, estado_yjs, contenido_texto, numero, hash_previo, hash)
  VALUES (d, 'manual', ana, '\x01', 'uno', 99, prueba.bytes(32), prueba.bytes(32));
  PERFORM prueba.version(d, ana, 'dos');
  PERFORM prueba.version(d, NULL, 'tres');
  SELECT * INTO v1 FROM versiones WHERE documento_id = d AND numero = 1;
  SELECT * INTO v2 FROM versiones WHERE documento_id = d AND numero = 2;
  SELECT * INTO v3 FROM versiones WHERE documento_id = d AND numero = 3;
  PERFORM prueba.afirmar_igual(v1.contenido_texto, 'uno'::text, 'número 99 ignorado: es la 1');
  PERFORM prueba.afirmar_igual(v1.hash_previo, decode(repeat('00', 32), 'hex'), 'la primera parte de cero');
  PERFORM prueba.afirmar_igual(v2.hash_previo, v1.hash, 'la 2 encadena con la 1');
  PERFORM prueba.afirmar_igual(v3.hash_previo, v2.hash, 'la 3 encadena con la 2');
  PERFORM prueba.afirmar_igual(v1.hash, hash_version(v1.hash_previo, d, 1, v1.estado_yjs, v1.contenido_texto,
    v1.creado_por, v1.motivo, v1.restaurada_de, v1.creado_en), 'hash calculado por la base');
  PERFORM prueba.afirmar_igual(verificar_cadena_versiones(d), NULL::bigint, 'cadena íntegra');
END $$;

-- @test versiones: solo inserción (UPDATE, DELETE y TRUNCATE prohibidos)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  v uuid := prueba.version(d, ana, 'original');
BEGIN
  PERFORM prueba.afirmar_error(format($q$UPDATE versiones SET contenido_texto = 'manipulado' WHERE id = %L$q$, v), '42501', 'UPDATE');
  PERFORM prueba.afirmar_error(format($q$DELETE FROM versiones WHERE id = %L$q$, v), '42501', 'DELETE');
  PERFORM prueba.afirmar_error('TRUNCATE versiones', '42501', 'TRUNCATE');
END $$;

-- @test versiones: desaparecen solo junto con su documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  PERFORM prueba.version(d, ana, 'uno');
  PERFORM prueba.version(d, ana, 'dos');
  DELETE FROM documentos WHERE id = d;
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM versiones), 0::bigint, 'versiones borradas con el documento');
END $$;

-- @test versiones: la verificación detecta un contenido manipulado (aunque se salten los triggers)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  PERFORM prueba.version(d, ana, 'uno');
  PERFORM prueba.version(d, ana, 'dos');
  PERFORM prueba.version(d, ana, 'tres');
  SET CONSTRAINTS ALL IMMEDIATE;
  ALTER TABLE versiones DISABLE TRIGGER versiones_solo_insercion;
  UPDATE versiones SET contenido_texto = 'dos (manipulado)' WHERE documento_id = d AND numero = 2;
  ALTER TABLE versiones ENABLE TRIGGER versiones_solo_insercion;
  PERFORM prueba.afirmar_igual(verificar_cadena_versiones(d), 2::bigint, 'detecta la versión 2');
END $$;

-- @test versiones: rehacer el hash de la versión manipulada rompe el eslabón siguiente
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  v versiones;
BEGIN
  PERFORM prueba.version(d, ana, 'uno');
  PERFORM prueba.version(d, ana, 'dos');
  PERFORM prueba.version(d, ana, 'tres');
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT * INTO v FROM versiones WHERE documento_id = d AND numero = 2;
  ALTER TABLE versiones DISABLE TRIGGER versiones_solo_insercion;
  UPDATE versiones
  SET contenido_texto = 'dos (manipulado)',
      hash = hash_version(v.hash_previo, d, 2, v.estado_yjs, 'dos (manipulado)', v.creado_por, v.motivo, v.restaurada_de, v.creado_en)
  WHERE id = v.id;
  ALTER TABLE versiones ENABLE TRIGGER versiones_solo_insercion;
  PERFORM prueba.afirmar_igual(verificar_cadena_versiones(d), 3::bigint, 'la 3 ya no encadena');
END $$;

-- @test versiones: un lector no crea versiones; las automáticas no tienen autor
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  lec uuid := prueba.cuenta_activa('lector@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, lec, 'lector');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.version(%L, %L)$q$, d, lec), '42501', 'versión de un lector');
  PERFORM prueba.version(d, NULL);
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO versiones (documento_id, motivo, estado_yjs, contenido_texto) VALUES (%L, 'manual', '\x01', 'x')$q$, d),
    '23514', 'manual sin autor');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO versiones (documento_id, motivo, creado_por, estado_yjs, contenido_texto) VALUES (%L, 'automatica', %L, '\x01', 'x')$q$, d, ana),
    '23514', 'automática con autor');
END $$;

-- @test versiones: restaurar solo desde una versión del mismo documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d1 uuid := prueba.documento(e, ana);
  d2 uuid := prueba.documento(e, ana);
  v1 uuid := prueba.version(d1, ana, 'del uno');
BEGIN
  INSERT INTO versiones (documento_id, motivo, creado_por, restaurada_de, estado_yjs, contenido_texto)
  VALUES (d1, 'restauracion', ana, v1, '\x01', 'del uno');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO versiones (documento_id, motivo, creado_por, restaurada_de, estado_yjs, contenido_texto) VALUES (%L, 'restauracion', %L, %L, '\x01', 'x')$q$, d2, ana, v1),
    '23503', 'restaurar desde otro documento');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO versiones (documento_id, motivo, creado_por, estado_yjs, contenido_texto) VALUES (%L, 'restauracion', %L, '\x01', 'x')$q$, d1, ana),
    '23514', 'restauración sin origen');
END $$;

-- @test comentarios: un lector comenta; un externo no
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  lec uuid := prueba.cuenta_activa('lector@example.com');
  ext uuid := prueba.cuenta_activa('externo@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, lec, 'lector');
  INSERT INTO comentarios (documento_id, autor_id, cuerpo, ancla) VALUES (d, lec, 'Duda sobre esta sección', '\x01');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO comentarios (documento_id, autor_id, cuerpo) VALUES (%L, %L, 'hola')$q$, d, ext), '42501', 'comenta un externo');
END $$;

-- @test comentarios: la respuesta pertenece al documento del hilo y no lleva ancla
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d1 uuid := prueba.documento(e, ana);
  d2 uuid := prueba.documento(e, ana);
  hilo uuid;
BEGIN
  INSERT INTO comentarios (documento_id, autor_id, cuerpo) VALUES (d1, ana, 'Hilo') RETURNING id INTO hilo;
  INSERT INTO comentarios (documento_id, autor_id, padre_id, cuerpo) VALUES (d1, ana, hilo, 'Respuesta');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO comentarios (documento_id, autor_id, padre_id, cuerpo) VALUES (%L, %L, %L, 'Respuesta cruzada')$q$, d2, ana, hilo),
    '23503', 'respuesta en otro documento');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO comentarios (documento_id, autor_id, padre_id, cuerpo, ancla) VALUES (%L, %L, %L, 'x', '\x01')$q$, d1, ana, hilo),
    '23514', 'respuesta con ancla');
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE comentarios SET autor_id = gen_random_uuid() WHERE id = %L$q$, hilo), '23514', 'cambiar el autor');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO comentarios (documento_id, autor_id, cuerpo) VALUES (%L, %L, '   ')$q$, d1, ana), '23514', 'cuerpo vacío');
END $$;

-- @test sesiones de edición: el rol registrado es el rol efectivo
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  ed uuid := prueba.cuenta_activa('editor@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
  s uuid;
BEGIN
  PERFORM prueba.miembro(e, ed, 'editor');
  s := prueba.sesion(ed);
  INSERT INTO sesiones_edicion (documento_id, usuario_id, sesion_id, rol) VALUES (d, ed, s, 'editor');
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO sesiones_edicion (documento_id, usuario_id, sesion_id, rol) VALUES (%L, %L, %L, 'propietario')$q$, d, ed, s),
    '42501', 'se registra con más rol');
END $$;

-- @test sesiones de edición: exigen una sesión de login viva y del mismo usuario
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  ed uuid := prueba.cuenta_activa('editor@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
  s_ana uuid := prueba.sesion(ana);
  s_ed uuid;
BEGIN
  PERFORM prueba.miembro(e, ed, 'editor');
  s_ed := prueba.sesion(ed);
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO sesiones_edicion (documento_id, usuario_id, sesion_id, rol) VALUES (%L, %L, %L, 'editor')$q$, d, ed, s_ana),
    '23503', 'sesión de otro usuario');
  UPDATE sesiones SET revocada_en = now(), motivo_revocacion = 'cierre' WHERE id = s_ed;
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO sesiones_edicion (documento_id, usuario_id, sesion_id, rol) VALUES (%L, %L, %L, 'editor')$q$, d, ed, s_ed),
    '42501', 'sesión revocada');
END $$;

-- @test sesiones de edición: borrar la sesión de login las borra
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  s uuid := prueba.sesion(ana);
BEGIN
  INSERT INTO sesiones_edicion (documento_id, usuario_id, sesion_id, rol) VALUES (d, ana, s, 'propietario');
  DELETE FROM sesiones WHERE id = s;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM sesiones_edicion), 0::bigint, 'presencia borrada');
END $$;
