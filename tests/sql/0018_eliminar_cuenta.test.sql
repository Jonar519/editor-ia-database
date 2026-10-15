-- Eliminación de cuenta por lápida (eliminar_cuenta): 409 con documentos o espacios compartidos, borrado
-- de lo que no tiene colaboradores, sin documentos huérfanos y con el historial de versiones intacto.
-- Las restricciones diferidas (un propietario por documento y por espacio, MFA de admin) se fuerzan con
-- SET CONSTRAINTS ALL IMMEDIATE: cada caso termina en ROLLBACK y nunca llegaría al COMMIT.

-- @test los tipos de evento del bloque G existen
INSERT INTO eventos_seguridad (tipo) VALUES ('correo_cambiado'), ('contrasena_cambiada'), ('otras_sesiones_cerradas'),
  ('avatar_actualizado'), ('datos_exportados'), ('cuenta_eliminada');
SELECT prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad), 6::bigint, 'insertados');

-- @test elimina la cuenta: lápida sin datos personales; borra lo suyo y lo que no tiene colaboradores
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  propio uuid;      -- espacio donde Ana es el único miembro
  ajeno uuid;       -- espacio de Beto donde Ana es editora
  doc_propio uuid;
  doc_ajeno uuid;
  ses uuid;
  r record;
BEGIN
  propio := prueba.espacio(ana, 'Notas de Ana');
  doc_propio := prueba.documento(propio, ana);
  PERFORM prueba.version(doc_propio, ana, 'borrador privado');
  ajeno := prueba.espacio(beto, 'Equipo');
  PERFORM prueba.miembro(ajeno, ana, 'editor');
  doc_ajeno := prueba.documento(ajeno, beto);
  PERFORM prueba.permiso(doc_ajeno, ana, 'editor');
  ses := prueba.sesion(ana);
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (ses, ana, prueba.bytes(32), now() + interval '1 day');
  INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (ana, prueba.bytes(32), now() + interval '10 minutes');
  INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (ana, 'ana.nueva@example.com', prueba.bytes(32), now() + interval '1 hour');
  PERFORM prueba.mfa(ana);
  INSERT INTO codigos_respaldo (usuario_id, hash_codigo) VALUES (ana, prueba.bytes(32));
  PERFORM prueba.avatar(ana);
  INSERT INTO uso_ia_diario (usuario_id, dia, peticiones) VALUES (ana, current_date, 3);
  INSERT INTO eventos_seguridad (tipo, usuario_id, ip_red) VALUES ('inicio_sesion', ana, '203.0.113.0/24'), ('inicio_sesion', beto, '198.51.100.0/24');

  SET LOCAL ROLE cuaderno_app;
  SELECT * INTO r FROM eliminar_cuenta(ana);
  SET CONSTRAINTS ALL IMMEDIATE;
  RESET ROLE;

  PERFORM prueba.afirmar_igual(r.espacios_borrados, 1, 'un espacio sin colaboradores');
  PERFORM prueba.afirmar_igual(r.documentos_borrados, 1, 'un documento sin colaboradores');
  PERFORM prueba.afirmar((SELECT estado = 'eliminada' AND eliminada_en IS NOT NULL AND correo IS NULL AND nombre IS NULL
                                 AND telefono IS NULL AND hash_contrasena IS NULL FROM usuarios WHERE id = ana), 'lápida');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM espacios WHERE id = propio), 'su espacio sin colaboradores se borró');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM documentos WHERE id = doc_propio), 'su documento sin colaboradores se borró');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM versiones WHERE documento_id = doc_propio), 'con sus versiones');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM documentos WHERE id = doc_ajeno), 'el documento de Beto sigue');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM miembros_espacio WHERE usuario_id = ana), 0::bigint, 'membresías');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM permisos_documento WHERE usuario_id = ana), 0::bigint, 'permisos');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM sesiones WHERE usuario_id = ana), 0::bigint, 'sesiones');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM tokens_refresco WHERE usuario_id = ana), 0::bigint, 'refresh');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM tokens_recuperacion WHERE usuario_id = ana), 0::bigint, 'recuperación');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM cambios_correo WHERE usuario_id = ana), 0::bigint, 'cambio de correo');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM mfa_totp WHERE usuario_id = ana), 0::bigint, 'MFA');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM codigos_respaldo WHERE usuario_id = ana), 0::bigint, 'códigos de respaldo');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM avatares WHERE usuario_id = ana), 0::bigint, 'avatar');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM uso_ia_diario WHERE usuario_id = ana), 0::bigint, 'uso de IA');
  -- Eventos: los de Ana se anonimizan (no se borran); los de Beto no se tocan.
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE usuario_id = ana), 0::bigint, 'eventos de Ana');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE usuario_id IS NULL AND ip_red IS NULL AND tipo = 'inicio_sesion'), 1::bigint, 'anonimizado');
  PERFORM prueba.afirmar_igual((SELECT ip_red FROM eventos_seguridad WHERE usuario_id = beto), '198.51.100.0/24'::cidr, 'Beto intacto');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE tipo = 'cuenta_eliminada' AND usuario_id IS NULL), 1::bigint, 'evento de eliminación');
END $$;

-- @test ningún documento queda huérfano y el historial de versiones sigue verificable
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  eid uuid;
  did uuid;
BEGIN
  eid := prueba.espacio(beto, 'Equipo');
  PERFORM prueba.miembro(eid, ana, 'editor');
  did := prueba.documento(eid, beto);
  PERFORM prueba.version(did, beto, 'v1');
  PERFORM prueba.version(did, ana, 'v2 de Ana');
  PERFORM prueba.version(did, NULL, 'automática');
  INSERT INTO comentarios (documento_id, autor_id, cuerpo) VALUES (did, ana, 'Comentario ficticio');

  PERFORM eliminar_cuenta(ana);
  SET CONSTRAINTS ALL IMMEDIATE;

  PERFORM prueba.afirmar_igual(verificar_cadena_versiones(did), NULL::bigint, 'cadena de hash íntegra');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM versiones WHERE documento_id = did), 3::bigint, 'las 3 versiones siguen');
  PERFORM prueba.afirmar_igual((SELECT creado_por FROM versiones WHERE documento_id = did AND numero = 2), ana, 'autoría: el id de la lápida');
  PERFORM prueba.afirmar_igual((SELECT autor_id FROM comentarios WHERE documento_id = did), ana, 'comentario con el id de la lápida');
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM documentos d
     WHERE NOT EXISTS (SELECT 1 FROM permisos_documento p JOIN usuarios u ON u.id = p.usuario_id
                       WHERE p.documento_id = d.id AND p.rol = 'propietario' AND u.estado = 'activa')),
    0::bigint, 'documentos sin propietario activo');
END $$;

-- @test 409: propietaria de un documento con colaboradores (otro miembro del espacio); nada cambia
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  eid uuid;
BEGIN
  eid := prueba.espacio(beto, 'Equipo');
  PERFORM prueba.miembro(eid, ana, 'editor');
  PERFORM prueba.documento(eid, ana);
  PERFORM prueba.sesion(ana);
  PERFORM prueba.afirmar_error(format('SELECT eliminar_cuenta(%L)', ana), 'CU409', 'documento compartido');
  PERFORM prueba.afirmar((SELECT estado = 'activa' AND correo IS NOT NULL FROM usuarios WHERE id = ana), 'sigue activa');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM sesiones WHERE usuario_id = ana), 1::bigint, 'conserva su sesión');
END $$;

-- @test 409: propietaria de un espacio con otros miembros aunque no tenga documentos ahí
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  eid uuid;
BEGIN
  eid := prueba.espacio(ana, 'Equipo de Ana');
  PERFORM prueba.miembro(eid, beto, 'editor');
  PERFORM prueba.afirmar_error(format('SELECT eliminar_cuenta(%L)', ana), 'CU409', 'espacio compartido');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM espacios WHERE id = eid), 'el espacio sigue');
END $$;

-- @test transferida la propiedad, sí se puede eliminar
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  eid uuid;
  did uuid;
BEGIN
  eid := prueba.espacio(beto, 'Equipo');
  PERFORM prueba.miembro(eid, ana, 'editor');
  did := prueba.documento(eid, ana);
  PERFORM prueba.permiso(did, beto, 'editor');
  UPDATE permisos_documento SET rol = 'editor' WHERE documento_id = did AND usuario_id = ana;
  UPDATE permisos_documento SET rol = 'propietario' WHERE documento_id = did AND usuario_id = beto;
  PERFORM eliminar_cuenta(ana);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM documentos WHERE id = did), 'el documento transferido sigue');
END $$;

-- @test un admin también se elimina (la regla "admin activo con MFA" no lo impide)
DO $$
DECLARE uid uuid := prueba.cuenta_activa('admin@example.com', 'admin');
BEGIN
  PERFORM eliminar_cuenta(uid);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM prueba.afirmar((SELECT estado = 'eliminada' FROM usuarios WHERE id = uid), 'lápida');
END $$;

-- @test solo se elimina una cuenta activa (dos veces, o una pendiente, falla)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  pend uuid := prueba.cuenta_pendiente('pendiente@example.com');
BEGIN
  PERFORM eliminar_cuenta(ana);
  PERFORM prueba.afirmar_error(format('SELECT eliminar_cuenta(%L)', ana), '23514', 'ya eliminada');
  PERFORM prueba.afirmar_error(format('SELECT eliminar_cuenta(%L)', pend), '23514', 'pendiente');
END $$;
