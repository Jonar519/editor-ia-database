-- 0018 · Eventos de seguridad del bloque G y eliminación de cuenta por lápida.
--
-- eliminar_cuenta(cuenta) hace TODA la eliminación en una sola llamada (y por lo tanto en la transacción
-- del llamador). La política:
--   - 409 (SQLSTATE CU409) si la cuenta es PROPIETARIA de documentos con otros colaboradores y no
--     transfirió la propiedad (decisión escrita del bloque C). Como un documento no tiene privacidad
--     dentro de su espacio, "colaborador" es cualquier otro miembro del espacio del documento: todos
--     tienen acceso efectivo a él.
--   - 409 también si es propietaria de un ESPACIO con otros miembros. Es consecuencia de 0008: el espacio
--     necesita exactamente un propietario y no puede quedar sin él.
--   - Los documentos SIN colaboradores son los de los espacios donde la cuenta es el único miembro: se
--     borran esos espacios con todo su contenido (documentos, versiones, comentarios, embeddings).
--   - El resto queda: los documentos de otros conservan su propietario, y la autoría (versiones,
--     actualizaciones, comentarios) sigue apuntando al id de la lápida. La cadena de hash de las versiones
--     incluye ese id, que no cambia: el historial sigue verificable.
--   - Se borran sesiones (y en cascada sus refresh y sesiones de edición), tokens, cambios de correo, MFA
--     (y en cascada los códigos de respaldo), avatar y uso de IA. Los eventos de seguridad se ANONIMIZAN.
--   - La cuenta queda como lápida: sin correo, nombre, teléfono ni contraseña (CHECK de 0002).
--
-- Ningún documento queda huérfano por construcción: todo documento tiene exactamente un propietario
-- (0009, revisado al COMMIT), ese propietario tiene que ser miembro de su espacio y solo una cuenta
-- activa puede ser miembro. Una lápida no puede ser propietaria de nada.

ALTER TABLE eventos_seguridad DROP CONSTRAINT eventos_seguridad_tipo_valido;
ALTER TABLE eventos_seguridad ADD CONSTRAINT eventos_seguridad_tipo_valido CHECK (tipo IN (
  'inicio_sesion', 'inicio_fallido', 'cuenta_bloqueada', 'cierre_sesion', 'refresco_reutilizado',
  'mfa_desafio', 'mfa_correcto', 'mfa_fallido', 'codigo_respaldo_usado',
  'mfa_activado', 'mfa_desactivado', 'codigos_respaldo_regenerados',
  'invitacion_creada', 'invitacion_reenviada', 'invitacion_cancelada', 'invitacion_completada',
  'recuperacion_solicitada', 'contrasena_restablecida',
  -- Bloque G: perfil, sesiones y datos.
  'perfil_actualizado', 'cambio_correo_solicitado', 'correo_cambiado', 'contrasena_cambiada',
  'sesion_cerrada', 'otras_sesiones_cerradas', 'avatar_actualizado', 'avatar_eliminado',
  'datos_exportados', 'cuenta_eliminada'
));

CREATE FUNCTION eliminar_cuenta(p_usuario uuid)
RETURNS TABLE (espacios_borrados integer, documentos_borrados integer)
LANGUAGE plpgsql AS $$
DECLARE
  v_estado text;
  v_solos uuid[];
  v_espacios integer;
  v_documentos integer;
BEGIN
  SELECT estado INTO v_estado FROM usuarios WHERE id = p_usuario FOR UPDATE;
  IF v_estado IS DISTINCT FROM 'activa' THEN
    RAISE EXCEPTION 'Solo se elimina una cuenta activa' USING ERRCODE = 'check_violation';
  END IF;

  -- Bloquea los espacios de la cuenta: nadie puede sumarse a uno (la clave foránea de miembros_espacio
  -- toma FOR KEY SHARE, que choca con FOR UPDATE) entre la revisión y el borrado.
  PERFORM 1 FROM espacios
  WHERE id IN (SELECT espacio_id FROM miembros_espacio WHERE usuario_id = p_usuario)
  FOR UPDATE;

  IF EXISTS (
    SELECT 1 FROM permisos_documento pd
    JOIN miembros_espacio otro ON otro.espacio_id = pd.espacio_id AND otro.usuario_id <> p_usuario
    WHERE pd.usuario_id = p_usuario AND pd.rol = 'propietario'
  ) THEN
    RAISE EXCEPTION 'La cuenta es propietaria de documentos con otros colaboradores: transfiere la propiedad antes de eliminarla'
      USING ERRCODE = 'CU409', DETAIL = 'documentos_compartidos';
  END IF;
  IF EXISTS (
    SELECT 1 FROM miembros_espacio me
    JOIN miembros_espacio otro ON otro.espacio_id = me.espacio_id AND otro.usuario_id <> p_usuario
    WHERE me.usuario_id = p_usuario AND me.rol = 'propietario'
  ) THEN
    RAISE EXCEPTION 'La cuenta es propietaria de espacios con otros miembros: transfiere la propiedad antes de eliminarla'
      USING ERRCODE = 'CU409', DETAIL = 'espacios_compartidos';
  END IF;

  -- Espacios donde es el único miembro: sus documentos no tienen colaboradores. Se borran enteros.
  SELECT coalesce(array_agg(me.espacio_id), '{}') INTO v_solos
  FROM miembros_espacio me
  WHERE me.usuario_id = p_usuario
    AND NOT EXISTS (SELECT 1 FROM miembros_espacio o WHERE o.espacio_id = me.espacio_id AND o.usuario_id <> p_usuario);
  SELECT count(*) INTO v_documentos FROM documentos WHERE espacio_id = ANY (v_solos);
  DELETE FROM espacios WHERE id = ANY (v_solos);
  GET DIAGNOSTICS v_espacios = ROW_COUNT;

  -- Membresías en espacios de otros (en cascada, sus permisos de documento).
  DELETE FROM miembros_espacio WHERE usuario_id = p_usuario;

  DELETE FROM sesiones WHERE usuario_id = p_usuario;
  DELETE FROM tokens_recuperacion WHERE usuario_id = p_usuario;
  DELETE FROM cambios_correo WHERE usuario_id = p_usuario;
  DELETE FROM mfa_totp WHERE usuario_id = p_usuario;
  DELETE FROM avatares WHERE usuario_id = p_usuario;
  DELETE FROM uso_ia_diario WHERE usuario_id = p_usuario;

  UPDATE eventos_seguridad SET usuario_id = NULL, ip_red = NULL WHERE usuario_id = p_usuario;

  UPDATE usuarios
  SET estado = 'eliminada', eliminada_en = now(), correo = NULL, nombre = NULL, telefono = NULL,
      hash_contrasena = NULL, bloqueada_hasta = NULL, fallos_login = 0
  WHERE id = p_usuario;

  -- El evento no se liga a la lápida: solo deja constancia de que hubo una eliminación.
  INSERT INTO eventos_seguridad (tipo) VALUES ('cuenta_eliminada');

  RETURN QUERY SELECT v_espacios, v_documentos;
END
$$;
