-- 0003 · Invitaciones: único camino de alta de cuentas.
--
-- Solo se guarda el SHA-256 del token; el token viaja en el fragmento del enlace (#/invitacion/<token>).
-- Una invitación solo puede apuntar a una cuenta PENDIENTE (CHECK + clave foránea compuesta).
-- Como la clave foránea no se actualiza en cascada, activar la cuenta exige borrar antes la invitación:
-- el enlace es de un solo uso por construcción.

CREATE TABLE invitaciones (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     uuid        NOT NULL,
  estado_usuario text        NOT NULL DEFAULT 'pendiente',
  token_hash     bytea       NOT NULL,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  expira_en      timestamptz NOT NULL,

  CONSTRAINT invitaciones_solo_cuentas_pendientes CHECK (estado_usuario = 'pendiente'),
  CONSTRAINT invitaciones_usuario_pendiente FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado) ON DELETE CASCADE,
  CONSTRAINT invitaciones_token_sha256 CHECK (octet_length(token_hash) = 32),
  CONSTRAINT invitaciones_vigencia_72h CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '72 hours'),
  CONSTRAINT invitaciones_token_unico UNIQUE (token_hash),
  CONSTRAINT invitaciones_una_por_cuenta UNIQUE (usuario_id)
);

CREATE INDEX invitaciones_expira_en ON invitaciones (expira_en);

CREATE TRIGGER invitaciones_fijar_creado_en BEFORE INSERT ON invitaciones
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER invitaciones_plazos_solo_se_acortan BEFORE UPDATE ON invitaciones
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
