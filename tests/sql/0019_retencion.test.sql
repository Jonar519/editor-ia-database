-- Retención diaria (purgar_retencion): borra solo lo vencido según los plazos de la base y respeta lo vigente.
-- Las filas "viejas" se envejecen como dueño: los plazos solo se pueden acortar (moverlos hacia atrás está
-- permitido) y en eventos_seguridad hay que desactivar el trigger de solo inserción.

-- @test sesiones: borra las terminadas hace más de 30 días; conserva las vivas y las terminadas hace poco
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  vieja_revocada uuid := prueba.sesion(ana);
  vieja_vencida uuid := prueba.sesion(ana);
  reciente uuid := prueba.sesion(ana);
  viva uuid := prueba.sesion(ana);
  r record;
BEGIN
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en, usado_en)
  VALUES (viva, ana, prueba.bytes(32), now() + interval '1 day', now());
  INSERT INTO tokens_refresco (sesion_id, usuario_id, token_hash, expira_en) VALUES (vieja_revocada, ana, prueba.bytes(32), now() + interval '1 day');
  -- Revocada hace 40 días aunque su vencimiento fue hace solo 25: cuenta lo que ocurrió primero.
  UPDATE sesiones SET creado_en = now() - interval '45 days', expira_en = now() - interval '25 days',
                      revocada_en = now() - interval '40 days', motivo_revocacion = 'cierre' WHERE id = vieja_revocada;
  UPDATE tokens_refresco SET creado_en = now() - interval '45 days', expira_en = now() - interval '25 days' WHERE sesion_id = vieja_revocada;
  UPDATE sesiones SET creado_en = now() - interval '45 days', expira_en = now() - interval '31 days' WHERE id = vieja_vencida;
  UPDATE sesiones SET revocada_en = now() - interval '29 days', motivo_revocacion = 'cierre' WHERE id = reciente;

  SET LOCAL ROLE cuaderno_app;
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'sesiones';
  RESET ROLE;

  PERFORM prueba.afirmar_igual(r.borradas, 2::bigint, 'dos sesiones terminadas hace más de 30 días');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM sesiones WHERE id IN (vieja_revocada, vieja_vencida)), 'borradas');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM tokens_refresco WHERE sesion_id = vieja_revocada), 0::bigint, 'sus refresh en cascada');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM sesiones WHERE id = reciente), 'revocada hace 29 días: sigue');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM sesiones WHERE id = viva), 'viva: sigue');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM tokens_refresco WHERE sesion_id = viva AND usado_en IS NOT NULL), 1::bigint,
    'el refresh USADO de una sesión viva se conserva (detección de reutilización)');
END $$;

-- @test tokens de recuperación y cambios de correo: borra los vencidos hace más de 1 día
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  beto uuid := prueba.cuenta_activa('beto@example.com');
  r record;
BEGIN
  INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (ana, prueba.bytes(32), now() + interval '10 minutes');
  UPDATE tokens_recuperacion SET creado_en = now() - interval '3 days', expira_en = now() - interval '3 days' + interval '15 minutes' WHERE usuario_id = ana;
  INSERT INTO tokens_recuperacion (usuario_id, token_hash, expira_en) VALUES (beto, prueba.bytes(32), now() + interval '10 minutes');
  UPDATE tokens_recuperacion SET creado_en = now() - interval '20 hours', expira_en = now() - interval '20 hours' + interval '15 minutes' WHERE usuario_id = beto;
  INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (ana, 'ana.nueva@example.com', prueba.bytes(32), now() + interval '1 hour');
  UPDATE cambios_correo SET creado_en = now() - interval '3 days', expira_en = now() - interval '2 days' WHERE usuario_id = ana;
  INSERT INTO cambios_correo (usuario_id, correo_nuevo, token_hash, expira_en) VALUES (beto, 'beto.nuevo@example.com', prueba.bytes(32), now() + interval '1 hour');

  SET LOCAL ROLE cuaderno_app;
  CREATE TEMP TABLE resultado ON COMMIT DROP AS SELECT * FROM purgar_retencion();
  RESET ROLE;

  PERFORM prueba.afirmar_igual((SELECT borradas FROM resultado WHERE tabla = 'tokens_recuperacion'), 1::bigint, 'recuperación vencida hace 3 días');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM tokens_recuperacion WHERE usuario_id = beto), 'vencida hace menos de 1 día: sigue');
  PERFORM prueba.afirmar_igual((SELECT borradas FROM resultado WHERE tabla = 'cambios_correo'), 1::bigint, 'cambio de correo vencido');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM cambios_correo WHERE usuario_id = beto), 'cambio vigente: sigue');
END $$;

-- @test correos simulados: borra los vencidos
DO $$
DECLARE r record;
BEGIN
  INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
  VALUES ('ana@example.com', 'invitacion', 'Viejo', 'Cuerpo ficticio', now() + interval '1 day'),
         ('ana@example.com', 'invitacion', 'Nuevo', 'Cuerpo ficticio', now() + interval '1 day');
  UPDATE correos_simulados SET creado_en = now() - interval '8 days', expira_en = now() - interval '1 day' WHERE asunto = 'Viejo';
  SET LOCAL ROLE cuaderno_app;
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'correos_simulados';
  RESET ROLE;
  PERFORM prueba.afirmar_igual(r.borradas, 1::bigint, 'uno vencido');
  PERFORM prueba.afirmar_igual((SELECT string_agg(asunto, ',') FROM correos_simulados), 'Nuevo', 'el vigente sigue');
END $$;

-- @test eventos de seguridad: borra los de más de 180 días y conserva los demás
DO $$
DECLARE
  viejo bigint;
  casi bigint;
  r record;
BEGIN
  INSERT INTO eventos_seguridad (tipo) VALUES ('inicio_fallido') RETURNING id INTO viejo;
  INSERT INTO eventos_seguridad (tipo) VALUES ('inicio_fallido') RETURNING id INTO casi;
  INSERT INTO eventos_seguridad (tipo) VALUES ('inicio_sesion');
  ALTER TABLE eventos_seguridad DISABLE TRIGGER eventos_seguridad_solo_insercion;
  UPDATE eventos_seguridad SET creado_en = now() - interval '181 days' WHERE id = viejo;
  UPDATE eventos_seguridad SET creado_en = now() - interval '179 days' WHERE id = casi;
  ALTER TABLE eventos_seguridad ENABLE TRIGGER eventos_seguridad_solo_insercion;

  SET LOCAL ROLE cuaderno_app;
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'eventos_seguridad';
  RESET ROLE;

  PERFORM prueba.afirmar_igual(r.borradas, 1::bigint, 'uno de más de 180 días');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM eventos_seguridad WHERE id = viejo), 'borrado');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM eventos_seguridad WHERE id = casi), '179 días: sigue');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad), 2::bigint, 'quedan dos');
END $$;

-- @test sin nada vencido no borra nada e informa cada tabla
DO $$
DECLARE ana uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.sesion(ana);
  INSERT INTO eventos_seguridad (tipo, usuario_id) VALUES ('inicio_sesion', ana);
  PERFORM prueba.afirmar_igual(
    (SELECT string_agg(tabla || '=' || borradas, ',' ORDER BY tabla) FROM purgar_retencion()),
    'cambios_correo=0,correos_simulados=0,cuentas_pendientes=0,eventos_seguridad=0,sesiones=0,tokens_recuperacion=0,uso_ia_diario=0,uso_ia_indexado_diario=0',
    'nada que borrar (con los pasos de 0020 y 0023)');
END $$;
