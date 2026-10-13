-- 0005 · Tokens de cuenta: recuperación de contraseña y cambio de correo.
--
-- Ambos solo existen para cuentas ACTIVAS (CHECK + clave foránea compuesta), guardan solo el SHA-256
-- del token, son de un solo uso y tienen un plazo máximo fijado por la base.

CREATE TABLE tokens_recuperacion (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     uuid        NOT NULL,
  estado_usuario text        NOT NULL DEFAULT 'activa',
  token_hash     bytea       NOT NULL,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  expira_en      timestamptz NOT NULL,
  usado_en       timestamptz,

  CONSTRAINT tokens_recuperacion_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT tokens_recuperacion_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado),
  CONSTRAINT tokens_recuperacion_token_sha256 CHECK (octet_length(token_hash) = 32),
  CONSTRAINT tokens_recuperacion_token_unico UNIQUE (token_hash),
  CONSTRAINT tokens_recuperacion_vigencia_15min CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '15 minutes')
);

-- Pedir uno nuevo exige invalidar (borrar) el anterior: como máximo uno sin usar por cuenta.
CREATE UNIQUE INDEX tokens_recuperacion_uno_vigente_por_cuenta ON tokens_recuperacion (usuario_id) WHERE usado_en IS NULL;
CREATE INDEX tokens_recuperacion_expira_en ON tokens_recuperacion (expira_en);

CREATE TRIGGER tokens_recuperacion_fijar_creado_en BEFORE INSERT ON tokens_recuperacion
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER tokens_recuperacion_plazos_solo_se_acortan BEFORE UPDATE ON tokens_recuperacion
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
CREATE TRIGGER tokens_recuperacion_uso_unico BEFORE UPDATE ON tokens_recuperacion
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('usado_en', 'token_hash', 'usuario_id');

-- Cambio de correo: el token se envía al correo NUEVO para re-verificarlo; el backend avisa al anterior.
CREATE TABLE cambios_correo (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     uuid        NOT NULL,
  estado_usuario text        NOT NULL DEFAULT 'activa',
  correo_nuevo   citext      NOT NULL,
  token_hash     bytea       NOT NULL,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  expira_en      timestamptz NOT NULL,
  confirmado_en  timestamptz,

  CONSTRAINT cambios_correo_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT cambios_correo_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado),
  CONSTRAINT cambios_correo_formato CHECK (correo_nuevo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(correo_nuevo) <= 254),
  CONSTRAINT cambios_correo_token_sha256 CHECK (octet_length(token_hash) = 32),
  CONSTRAINT cambios_correo_token_unico UNIQUE (token_hash),
  CONSTRAINT cambios_correo_vigencia_24h CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '24 hours')
);

CREATE UNIQUE INDEX cambios_correo_uno_pendiente_por_cuenta ON cambios_correo (usuario_id) WHERE confirmado_en IS NULL;
CREATE INDEX cambios_correo_expira_en ON cambios_correo (expira_en);

CREATE TRIGGER cambios_correo_fijar_creado_en BEFORE INSERT ON cambios_correo
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER cambios_correo_plazos_solo_se_acortan BEFORE UPDATE ON cambios_correo
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
CREATE TRIGGER cambios_correo_uso_unico BEFORE UPDATE ON cambios_correo
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('confirmado_en', 'token_hash', 'usuario_id', 'correo_nuevo');
