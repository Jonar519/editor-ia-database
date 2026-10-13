-- 0006 · MFA TOTP y códigos de respaldo.
--
-- El secreto TOTP se guarda cifrado con AES-256-GCM (el backend usa el id de la cuenta como datos
-- asociados, así que un secreto copiado a otra cuenta no se descifra). La base guarda texto cifrado,
-- IV (12 bytes) y etiqueta (16 bytes), y no permite cambiarlos: reconfigurar MFA es borrar y crear.
-- Anti-replay: ultimo_paso (último paso de tiempo TOTP aceptado) solo puede crecer.
-- Regla de rol: un admin ACTIVO siempre tiene MFA confirmado (restricción diferida al COMMIT, porque al
-- completar la invitación la cuenta se activa y su MFA se crea en la misma transacción).

CREATE TABLE mfa_totp (
  usuario_id      uuid        PRIMARY KEY,
  estado_usuario  text        NOT NULL DEFAULT 'activa',
  secreto_cifrado bytea       NOT NULL,
  iv              bytea       NOT NULL,
  etiqueta        bytea       NOT NULL,
  confirmado_en   timestamptz,
  ultimo_paso     bigint,
  creado_en       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT mfa_totp_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT mfa_totp_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado),
  CONSTRAINT mfa_totp_secreto_longitud CHECK (octet_length(secreto_cifrado) BETWEEN 16 AND 64),
  CONSTRAINT mfa_totp_iv_gcm CHECK (octet_length(iv) = 12),
  CONSTRAINT mfa_totp_etiqueta_gcm CHECK (octet_length(etiqueta) = 16),
  CONSTRAINT mfa_totp_paso_positivo CHECK (ultimo_paso IS NULL OR ultimo_paso > 0)
);

CREATE FUNCTION mfa_totp_anti_replay() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.ultimo_paso IS NOT NULL AND (NEW.ultimo_paso IS NULL OR NEW.ultimo_paso <= OLD.ultimo_paso) THEN
    RAISE EXCEPTION 'Código TOTP ya usado o anterior al último aceptado (anti-replay)'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER mfa_totp_fijar_creado_en BEFORE INSERT ON mfa_totp
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER mfa_totp_anti_replay BEFORE UPDATE ON mfa_totp
  FOR EACH ROW EXECUTE FUNCTION mfa_totp_anti_replay();
CREATE TRIGGER mfa_totp_secreto_inmutable BEFORE UPDATE ON mfa_totp
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('secreto_cifrado', 'iv', 'etiqueta', 'confirmado_en', 'creado_en');

-- Códigos de respaldo: solo el hash, un solo uso, como máximo 10 por cuenta. Dependen del MFA
-- (borrar el MFA los borra), así que su ligadura a una cuenta activa es TRANSITIVA vía mfa_totp.
CREATE TABLE codigos_respaldo (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id  uuid        NOT NULL,
  hash_codigo bytea       NOT NULL,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  usado_en    timestamptz,

  CONSTRAINT codigos_respaldo_de_su_mfa FOREIGN KEY (usuario_id) REFERENCES mfa_totp (usuario_id) ON DELETE CASCADE,
  CONSTRAINT codigos_respaldo_hash_sha256 CHECK (octet_length(hash_codigo) = 32),
  CONSTRAINT codigos_respaldo_unico UNIQUE (usuario_id, hash_codigo)
);

CREATE FUNCTION codigos_respaldo_maximo_10() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Serializa inserciones concurrentes de la misma cuenta antes de contar.
  PERFORM 1 FROM mfa_totp WHERE usuario_id = NEW.usuario_id FOR UPDATE;
  IF (SELECT count(*) FROM codigos_respaldo WHERE usuario_id = NEW.usuario_id) >= 10 THEN
    RAISE EXCEPTION 'Una cuenta tiene como máximo 10 códigos de respaldo'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER codigos_respaldo_fijar_creado_en BEFORE INSERT ON codigos_respaldo
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER codigos_respaldo_maximo_10 BEFORE INSERT ON codigos_respaldo
  FOR EACH ROW EXECUTE FUNCTION codigos_respaldo_maximo_10();
CREATE TRIGGER codigos_respaldo_uso_unico BEFORE UPDATE ON codigos_respaldo
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('usado_en', 'hash_codigo', 'usuario_id');

-- Un admin activo debe tener MFA confirmado. Se revisa al COMMIT (restricción diferida).
CREATE FUNCTION admin_requiere_mfa() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  uid uuid;
BEGIN
  IF TG_TABLE_NAME = 'usuarios' THEN
    uid := NEW.id;
  ELSE
    uid := OLD.usuario_id;
  END IF;
  IF EXISTS (
    SELECT 1 FROM usuarios u
    WHERE u.id = uid AND u.rol = 'admin' AND u.estado = 'activa'
      AND NOT EXISTS (SELECT 1 FROM mfa_totp m WHERE m.usuario_id = u.id AND m.confirmado_en IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Un admin activo debe tener MFA TOTP confirmado' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER usuarios_admin_requiere_mfa
  AFTER INSERT OR UPDATE OF estado, rol ON usuarios
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION admin_requiere_mfa();
CREATE CONSTRAINT TRIGGER mfa_totp_admin_requiere_mfa
  AFTER DELETE OR UPDATE OF confirmado_en ON mfa_totp
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION admin_requiere_mfa();
