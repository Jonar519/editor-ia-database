-- 0002 · Cuentas de usuario y funciones genéricas de integridad.
--
-- Ciclo de vida de una cuenta:
--   pendiente  creada por invitación de un admin; existe SIN contraseña.
--   activa     la persona completó su registro (contraseña y, si es admin, MFA).
--   eliminada  lápida anonimizada: conserva el id para la autoría, sin datos personales.
-- Transiciones válidas: pendiente→activa, activa→eliminada. Toda cuenta nace pendiente.

-- ─── Funciones genéricas ────────────────────────────────────────────────────────

-- La fecha de creación la pone la base, no el cliente: así no se pueden fabricar plazos más largos.
CREATE FUNCTION fijar_creado_en() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.creado_en := now();
  RETURN NEW;
END
$$;

CREATE FUNCTION fijar_actualizado_en() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.actualizado_en := now();
  RETURN NEW;
END
$$;

-- Las columnas nombradas en los argumentos del trigger, una vez con valor, no cambian nunca más.
-- Así un token usado no vuelve a estar disponible y una sesión revocada no revive.
CREATE FUNCTION una_sola_vez() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  columna text;
  antes jsonb := to_jsonb(OLD);
  despues jsonb := to_jsonb(NEW);
BEGIN
  FOREACH columna IN ARRAY TG_ARGV LOOP
    IF NOT antes ? columna THEN
      RAISE EXCEPTION 'una_sola_vez: la tabla % no tiene la columna %', TG_TABLE_NAME, columna;
    END IF;
    IF antes -> columna <> 'null'::jsonb AND antes -> columna IS DISTINCT FROM despues -> columna THEN
      RAISE EXCEPTION '%.% ya tiene valor y no se puede cambiar', TG_TABLE_NAME, columna
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NEW;
END
$$;

-- creado_en y expira_en solo pueden moverse hacia atrás: un plazo se puede acortar, nunca alargar.
CREATE FUNCTION plazos_solo_se_acortan() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.creado_en > OLD.creado_en OR NEW.expira_en > OLD.expira_en THEN
    RAISE EXCEPTION 'Los plazos de % solo se pueden acortar', TG_TABLE_NAME
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

-- ─── Cuentas ────────────────────────────────────────────────────────────────────

CREATE TABLE usuarios (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  estado          text        NOT NULL DEFAULT 'pendiente',
  rol             text        NOT NULL,
  correo          citext,
  nombre          text,
  telefono        text,
  hash_contrasena text,
  fallos_login    integer     NOT NULL DEFAULT 0,
  bloqueada_hasta timestamptz,
  invitada_por    uuid        REFERENCES usuarios (id),
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  activada_en     timestamptz,
  eliminada_en    timestamptz,

  CONSTRAINT usuarios_estado_valido CHECK (estado IN ('pendiente', 'activa', 'eliminada')),
  CONSTRAINT usuarios_rol_valido CHECK (rol IN ('admin', 'editor', 'lector')),
  CONSTRAINT usuarios_correo_formato CHECK (correo IS NULL OR (correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(correo) <= 254)),
  CONSTRAINT usuarios_nombre_formato CHECK (nombre IS NULL OR (nombre = btrim(nombre) AND length(nombre) BETWEEN 1 AND 80)),
  CONSTRAINT usuarios_telefono_e164 CHECK (telefono IS NULL OR telefono ~ '^\+[1-9][0-9]{6,14}$'),
  -- Nunca texto plano: solo el formato de hash scrypt que produce el backend.
  CONSTRAINT usuarios_hash_scrypt CHECK (hash_contrasena IS NULL OR hash_contrasena ~ '^\$scrypt\$ln=[0-9]+,r=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$'),
  CONSTRAINT usuarios_fallos_no_negativos CHECK (fallos_login >= 0),
  CONSTRAINT usuarios_pendiente_sin_contrasena CHECK (estado <> 'pendiente' OR (hash_contrasena IS NULL AND correo IS NOT NULL AND nombre IS NOT NULL AND activada_en IS NULL)),
  CONSTRAINT usuarios_activa_completa CHECK (estado <> 'activa' OR (hash_contrasena IS NOT NULL AND correo IS NOT NULL AND nombre IS NOT NULL AND activada_en IS NOT NULL)),
  CONSTRAINT usuarios_eliminada_es_lapida CHECK (estado <> 'eliminada' OR (hash_contrasena IS NULL AND correo IS NULL AND nombre IS NULL AND telefono IS NULL AND bloqueada_hasta IS NULL)),
  CONSTRAINT usuarios_eliminada_en_coherente CHECK ((estado = 'eliminada') = (eliminada_en IS NOT NULL)),
  -- Destino de las claves foráneas compuestas (usuario_id, estado_usuario) de invitaciones, sesiones y tokens.
  CONSTRAINT usuarios_id_estado_unico UNIQUE (id, estado)
);

-- Correo único sin distinguir mayúsculas (citext). Las lápidas no tienen correo y lo liberan.
CREATE UNIQUE INDEX usuarios_correo_unico ON usuarios (correo) WHERE correo IS NOT NULL;

-- Toda cuenta nace pendiente: no hay alta directa de cuentas activas (solo por invitación).
CREATE FUNCTION usuarios_nacen_pendientes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Una cuenta solo puede crearse como pendiente (alta por invitación)'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION usuarios_transicion_estado() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado IS DISTINCT FROM OLD.estado
     AND NOT ((OLD.estado = 'pendiente' AND NEW.estado = 'activa')
           OR (OLD.estado = 'activa' AND NEW.estado = 'eliminada')) THEN
    RAISE EXCEPTION 'Transición de cuenta no permitida: % → %', OLD.estado, NEW.estado
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

-- Quien invita tiene que ser un admin activo.
CREATE FUNCTION usuarios_invitada_por_admin() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.invitada_por IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM usuarios WHERE id = NEW.invitada_por AND rol = 'admin' AND estado = 'activa'
  ) THEN
    RAISE EXCEPTION 'Solo un admin activo puede invitar' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

-- Solo se borran cuentas pendientes (invitación cancelada). Las demás se anonimizan como lápida.
CREATE FUNCTION usuarios_solo_se_borran_pendientes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Una cuenta % no se borra: se anonimiza como lápida', OLD.estado
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN OLD;
END
$$;

CREATE TRIGGER usuarios_fijar_creado_en BEFORE INSERT ON usuarios
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER usuarios_nacen_pendientes BEFORE INSERT ON usuarios
  FOR EACH ROW EXECUTE FUNCTION usuarios_nacen_pendientes();
CREATE TRIGGER usuarios_invitada_por_admin BEFORE INSERT ON usuarios
  FOR EACH ROW EXECUTE FUNCTION usuarios_invitada_por_admin();
CREATE TRIGGER usuarios_transicion_estado BEFORE UPDATE OF estado ON usuarios
  FOR EACH ROW EXECUTE FUNCTION usuarios_transicion_estado();
CREATE TRIGGER usuarios_fijar_actualizado_en BEFORE UPDATE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION fijar_actualizado_en();
CREATE TRIGGER usuarios_solo_se_borran_pendientes BEFORE DELETE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION usuarios_solo_se_borran_pendientes();
