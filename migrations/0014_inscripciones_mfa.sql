-- 0014 · Inscripción MFA de un admin PENDIENTE (alternativa D, aprobada en el bloque F).
--
-- Un admin no puede activarse sin MFA confirmado (0006) y una cuenta pendiente no puede tener fila en
-- mfa_totp (CHECK + FK compuesta a cuentas activas). El secreto que se le muestra antes de confirmar el
-- primer código vive aquí, ligado a su invitación:
--   - solo cuentas PENDIENTES (CHECK + FK compuesta, como invitaciones) y solo con rol admin (trigger);
--   - una por invitación y por cuenta; desaparece EN CASCADA con la invitación (al completar, cancelar
--     o vencer la invitación);
--   - su vencimiento nunca supera el de la invitación (trigger);
--   - como máximo 5 intentos (el backend la borra al quinto fallo y hay que empezar de nuevo);
--   - el secreto cifrado (AES-256-GCM, datos asociados = id de la cuenta) es inmutable: al completar se
--     copia TAL CUAL a mfa_totp, porque los datos asociados ya son el id de la cuenta.

-- Destino de la FK compuesta (invitacion_id, usuario_id): la inscripción es de ESA invitación y ESA cuenta.
ALTER TABLE invitaciones ADD CONSTRAINT invitaciones_id_usuario_unico UNIQUE (id, usuario_id);

CREATE TABLE inscripciones_mfa (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitacion_id   uuid        NOT NULL,
  usuario_id      uuid        NOT NULL,
  estado_usuario  text        NOT NULL DEFAULT 'pendiente',
  secreto_cifrado bytea       NOT NULL,
  iv              bytea       NOT NULL,
  etiqueta        bytea       NOT NULL,
  intentos        integer     NOT NULL DEFAULT 0,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  expira_en       timestamptz NOT NULL,

  CONSTRAINT inscripciones_mfa_solo_cuentas_pendientes CHECK (estado_usuario = 'pendiente'),
  CONSTRAINT inscripciones_mfa_usuario_pendiente FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado) ON DELETE CASCADE,
  CONSTRAINT inscripciones_mfa_de_su_invitacion FOREIGN KEY (invitacion_id, usuario_id) REFERENCES invitaciones (id, usuario_id) ON DELETE CASCADE,
  CONSTRAINT inscripciones_mfa_una_por_invitacion UNIQUE (invitacion_id, usuario_id),
  CONSTRAINT inscripciones_mfa_una_por_cuenta UNIQUE (usuario_id, estado_usuario),
  CONSTRAINT inscripciones_mfa_secreto_longitud CHECK (octet_length(secreto_cifrado) BETWEEN 16 AND 64),
  CONSTRAINT inscripciones_mfa_iv_gcm CHECK (octet_length(iv) = 12),
  CONSTRAINT inscripciones_mfa_etiqueta_gcm CHECK (octet_length(etiqueta) = 16),
  CONSTRAINT inscripciones_mfa_intentos_max_5 CHECK (intentos BETWEEN 0 AND 5),
  CONSTRAINT inscripciones_mfa_vigencia CHECK (expira_en > creado_en)
);

-- Solo admins y nunca más allá del vencimiento de su invitación.
CREATE FUNCTION inscripciones_mfa_validar() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT rol FROM usuarios WHERE id = NEW.usuario_id) IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'La inscripción MFA previa a la activación es solo para cuentas admin'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.expira_en > (SELECT expira_en FROM invitaciones WHERE id = NEW.invitacion_id) THEN
    RAISE EXCEPTION 'La inscripción MFA no puede vencer después que su invitación'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER inscripciones_mfa_fijar_creado_en BEFORE INSERT ON inscripciones_mfa
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER inscripciones_mfa_validar BEFORE INSERT OR UPDATE ON inscripciones_mfa
  FOR EACH ROW EXECUTE FUNCTION inscripciones_mfa_validar();
CREATE TRIGGER inscripciones_mfa_plazos_solo_se_acortan BEFORE UPDATE ON inscripciones_mfa
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
CREATE TRIGGER inscripciones_mfa_secreto_inmutable BEFORE UPDATE ON inscripciones_mfa
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('secreto_cifrado', 'iv', 'etiqueta', 'invitacion_id', 'usuario_id');

GRANT SELECT, INSERT, UPDATE, DELETE ON inscripciones_mfa TO cuaderno_app;
