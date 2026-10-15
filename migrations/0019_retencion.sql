-- 0019 · Retención de datos: purgar_retencion(), que el backend corre una vez al día (job de BullMQ).
--
-- Los plazos viven AQUÍ, no en el backend: la base es la que decide qué se considera vencido y con su
-- propio reloj (now()). Detalle y justificación en docs/data-retention.md del backend.
--
--   sesiones             terminadas (revocadas o vencidas) hace más de 30 días. Sus refresh y sesiones de
--                        edición se van en cascada. Los refresh USADOS de una sesión viva NO se borran:
--                        son los que permiten detectar la reutilización de uno robado.
--   tokens_recuperacion  vencidos hace más de 1 día (vencen a los 15 min).
--   cambios_correo       vencidos hace más de 1 día (vencen a las 24 h como máximo).
--   correos_simulados    vencidos (la base ya los limita a 7 días).
--   eventos_seguridad    más de 180 días (retencion_eventos_seguridad(), 0015). El trigger de solo
--                        inserción no deja borrar nada más reciente, ni siquiera desde aquí.

CREATE FUNCTION retencion_sesiones_terminadas() RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT interval '30 days'
$$;

CREATE FUNCTION retencion_tokens_vencidos() RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT interval '1 day'
$$;

CREATE FUNCTION purgar_retencion() RETURNS TABLE (tabla text, borradas bigint) LANGUAGE plpgsql AS $$
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
END
$$;
