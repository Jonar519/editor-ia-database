-- Retención de cuentas pendientes: se borran 7 días después de que venció su invitación; las vigentes,
-- las vencidas hace poco y las activas no se tocan. La invitación y la inscripción MFA se van en cascada
-- y los eventos se anonimizan.

-- @test borra la cuenta pendiente con la invitación vencida hace más de 7 días (y lo que cuelga de ella)
DO $$
DECLARE
  admin uuid := prueba.cuenta_activa('admin@example.com', 'admin');
  vieja uuid := prueba.cuenta_pendiente('vieja@example.com', 'admin', admin);
  inv uuid;
  r record;
BEGIN
  inv := prueba.invitacion(vieja);
  INSERT INTO inscripciones_mfa (invitacion_id, usuario_id, secreto_cifrado, iv, etiqueta, expira_en)
  VALUES (inv, vieja, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now() + interval '1 hour');
  INSERT INTO eventos_seguridad (tipo, usuario_id) VALUES ('invitacion_creada', vieja);
  -- Envejecer (los plazos solo se acortan): creada hace 12 días, invitación vencida hace 8.
  UPDATE inscripciones_mfa SET creado_en = now() - interval '12 days', expira_en = now() - interval '9 days' WHERE usuario_id = vieja;
  UPDATE invitaciones SET creado_en = now() - interval '11 days', expira_en = now() - interval '8 days' WHERE usuario_id = vieja;
  UPDATE usuarios SET creado_en = now() - interval '12 days' WHERE id = vieja;

  SET LOCAL ROLE cuaderno_app;
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'cuentas_pendientes';
  RESET ROLE;

  PERFORM prueba.afirmar_igual(r.borradas, 1::bigint, 'una cuenta pendiente');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM usuarios WHERE id = vieja), 'cuenta borrada');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM invitaciones WHERE usuario_id = vieja), 'invitación en cascada');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM inscripciones_mfa WHERE usuario_id = vieja), 'inscripción en cascada');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE tipo = 'invitacion_creada' AND usuario_id IS NULL), 1::bigint, 'evento anonimizado');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM usuarios WHERE id = admin AND estado = 'activa'), 'el admin sigue');
END $$;

-- @test conserva: invitación vigente, vencida hace menos de 7 días y cuentas activas
DO $$
DECLARE
  vigente uuid := prueba.cuenta_pendiente('vigente@example.com');
  reciente uuid := prueba.cuenta_pendiente('reciente@example.com');
  activa uuid := prueba.cuenta_activa('activa@example.com');
  r record;
BEGIN
  PERFORM prueba.invitacion(vigente);
  PERFORM prueba.invitacion(reciente);
  UPDATE usuarios SET creado_en = now() - interval '30 days' WHERE id IN (vigente, reciente, activa);
  UPDATE invitaciones SET creado_en = now() - interval '9 days', expira_en = now() - interval '6 days' WHERE usuario_id = reciente;

  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'cuentas_pendientes';
  PERFORM prueba.afirmar_igual(r.borradas, 0::bigint, 'nada que borrar');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM usuarios WHERE id IN (vigente, reciente, activa)), 3::bigint, 'las tres siguen');
END $$;

-- @test una cuenta pendiente recién creada sin invitación (todavía) no se toca
DO $$
DECLARE nueva uuid := prueba.cuenta_pendiente('nueva@example.com');
BEGIN
  PERFORM prueba.afirmar_igual((SELECT borradas FROM purgar_retencion() WHERE tabla = 'cuentas_pendientes'), 0::bigint, 'recién creada');
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM usuarios WHERE id = nueva), 'sigue');
END $$;
