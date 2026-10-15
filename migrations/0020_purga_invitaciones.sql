-- 0020 · Retención: cuentas pendientes con la invitación vencida (decisión 7 del bloque G).
--
-- Una invitación vence a las 72 h. Si nadie la reenvía, la cuenta pendiente queda con el nombre y el
-- correo de alguien que nunca completó el alta. Se borra 7 días después de que venció su invitación:
-- es margen para que un admin la reenvíe (reenviar crea una invitación nueva y la cuenta deja de
-- calificar).
--
-- Borrar la cuenta pendiente se lleva en cascada su invitación y su inscripción MFA; sus eventos de
-- seguridad se anonimizan (ON DELETE SET NULL, 0015). Una cuenta pendiente no puede ser autora ni
-- propietaria de nada, así que no deja referencias colgando.
--
-- purgar_retencion() se reemplaza ENTERA (la de 0019 + el paso nuevo al final). Las mutaciones del
-- cuerpo de la función apuntan a esta migración, que es la definición vigente.

CREATE FUNCTION retencion_invitaciones_vencidas() RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT interval '7 days'
$$;

CREATE OR REPLACE FUNCTION purgar_retencion() RETURNS TABLE (tabla text, borradas bigint) LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
BEGIN
  -- Terminada = revocada o vencida; cuenta lo que haya ocurrido primero.
  DELETE FROM sesiones
  WHERE least(coalesce(revocada_en, 'infinity'::timestamptz), expira_en) < now() - retencion_sesiones_terminadas();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'sesiones'; borradas := n; RETURN NEXT;

  DELETE FROM tokens_recuperacion WHERE expira_en < now() - retencion_tokens_vencidos();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'tokens_recuperacion'; borradas := n; RETURN NEXT;

  DELETE FROM cambios_correo WHERE expira_en < now() - retencion_tokens_vencidos();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'cambios_correo'; borradas := n; RETURN NEXT;

  DELETE FROM correos_simulados WHERE expira_en <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'correos_simulados'; borradas := n; RETURN NEXT;

  DELETE FROM eventos_seguridad WHERE creado_en < now() - retencion_eventos_seguridad();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'eventos_seguridad'; borradas := n; RETURN NEXT;

  -- Cuentas pendientes sin una invitación vigente o vencida hace poco. "Hace poco" = menos de 7 días.
  -- creado_en evita tocar una cuenta recién creada cuya invitación aún no se inserta (misma transacción).
  DELETE FROM usuarios u
  WHERE u.estado = 'pendiente'
    AND u.creado_en < now() - retencion_invitaciones_vencidas()
    AND NOT EXISTS (
      SELECT 1 FROM invitaciones i
      WHERE i.usuario_id = u.id AND i.expira_en >= now() - retencion_invitaciones_vencidas()
    );
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'cuentas_pendientes'; borradas := n; RETURN NEXT;
END
$$;
