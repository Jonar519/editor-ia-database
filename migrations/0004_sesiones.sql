-- 0004 · Sesiones y tokens de refresco rotativos.
--
-- Una sesión solo puede pertenecer a una cuenta ACTIVA (CHECK + clave foránea compuesta). Para anonimizar
-- una cuenta hay que borrar antes sus sesiones; la clave foránea no deja cambiar el estado mientras existan.
-- Los tokens de refresco forman una familia por sesión: solo uno vigente a la vez. Si se presenta uno ya
-- usado, el backend revoca la sesión entera (detección de reutilización).
-- La IP se guarda truncada (/24 en IPv4, /48 en IPv6) y el user-agent recortado.

CREATE TABLE sesiones (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id        uuid        NOT NULL,
  estado_usuario    text        NOT NULL DEFAULT 'activa',
  creado_en         timestamptz NOT NULL DEFAULT now(),
  ultimo_uso_en     timestamptz NOT NULL DEFAULT now(),
  expira_en         timestamptz NOT NULL,
  revocada_en       timestamptz,
  motivo_revocacion text,
  mfa_verificada    boolean     NOT NULL DEFAULT false,
  ip_red            cidr,
  ubicacion         text,
  user_agent        text,

  CONSTRAINT sesiones_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT sesiones_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado),
  CONSTRAINT sesiones_vigencia_30d CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '30 days'),
  CONSTRAINT sesiones_revocacion_coherente CHECK ((revocada_en IS NULL) = (motivo_revocacion IS NULL)),
  CONSTRAINT sesiones_motivo_valido CHECK (motivo_revocacion IN ('cierre', 'cierre_otras', 'cambio_contrasena', 'reutilizacion_refresco', 'bloqueo', 'admin')),
  CONSTRAINT sesiones_ip_truncada CHECK (ip_red IS NULL OR (family(ip_red) = 4 AND masklen(ip_red) = 24) OR (family(ip_red) = 6 AND masklen(ip_red) = 48)),
  CONSTRAINT sesiones_ubicacion_corta CHECK (ubicacion IS NULL OR length(ubicacion) <= 120),
  CONSTRAINT sesiones_user_agent_corto CHECK (user_agent IS NULL OR length(user_agent) <= 80),
  -- Destino de la clave foránea (sesion_id, usuario_id) de tokens_refresco.
  CONSTRAINT sesiones_id_usuario_unico UNIQUE (id, usuario_id)
);

CREATE INDEX sesiones_vivas_por_usuario ON sesiones (usuario_id) WHERE revocada_en IS NULL;
CREATE INDEX sesiones_expira_en ON sesiones (expira_en);

CREATE TRIGGER sesiones_fijar_creado_en BEFORE INSERT ON sesiones
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER sesiones_plazos_solo_se_acortan BEFORE UPDATE ON sesiones
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
CREATE TRIGGER sesiones_revocacion_definitiva BEFORE UPDATE ON sesiones
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('revocada_en', 'motivo_revocacion');

-- Tokens de refresco. Su ligadura a una cuenta activa es TRANSITIVA: pertenecen a una sesión
-- (clave foránea compuesta con el usuario), y una sesión solo existe para una cuenta activa.
CREATE TABLE tokens_refresco (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  sesion_id  uuid        NOT NULL,
  usuario_id uuid        NOT NULL,
  token_hash bytea       NOT NULL,
  creado_en  timestamptz NOT NULL DEFAULT now(),
  expira_en  timestamptz NOT NULL,
  usado_en   timestamptz,

  CONSTRAINT tokens_refresco_de_su_sesion FOREIGN KEY (sesion_id, usuario_id) REFERENCES sesiones (id, usuario_id) ON DELETE CASCADE,
  CONSTRAINT tokens_refresco_token_sha256 CHECK (octet_length(token_hash) = 32),
  CONSTRAINT tokens_refresco_token_unico UNIQUE (token_hash),
  CONSTRAINT tokens_refresco_vigencia_30d CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '30 days')
);

-- Rotación: como máximo un token sin usar por sesión.
CREATE UNIQUE INDEX tokens_refresco_uno_vigente_por_sesion ON tokens_refresco (sesion_id) WHERE usado_en IS NULL;
CREATE INDEX tokens_refresco_expira_en ON tokens_refresco (expira_en);

-- No se emiten tokens para una sesión revocada.
CREATE FUNCTION tokens_refresco_sesion_viva() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM sesiones WHERE id = NEW.sesion_id AND revocada_en IS NOT NULL) THEN
    RAISE EXCEPTION 'No se emiten tokens de refresco para una sesión revocada'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER tokens_refresco_fijar_creado_en BEFORE INSERT ON tokens_refresco
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER tokens_refresco_sesion_viva BEFORE INSERT ON tokens_refresco
  FOR EACH ROW EXECUTE FUNCTION tokens_refresco_sesion_viva();
CREATE TRIGGER tokens_refresco_plazos_solo_se_acortan BEFORE UPDATE ON tokens_refresco
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();
CREATE TRIGGER tokens_refresco_uso_unico BEFORE UPDATE ON tokens_refresco
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('usado_en', 'token_hash', 'sesion_id', 'usuario_id');
