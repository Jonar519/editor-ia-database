-- 0008 · Espacios de trabajo y sus miembros.
--
-- Un espacio agrupa documentos. Sus miembros tienen un rol de espacio (propietario, editor, lector) que
-- da acceso base a todos los documentos del espacio. Reglas:
--   - Solo cuentas ACTIVAS son miembros (CHECK + clave foránea compuesta, como en el bloque B). Para
--     anonimizar una cuenta hay que sacarla antes de sus espacios.
--   - Exactamente un propietario por espacio (índice único parcial + restricción diferida al COMMIT).
--   - Una cuenta con rol "lector" nunca recibe un rol que escriba (techo de rol de cuenta).

-- Niveles de los roles de espacio y documento, para comparar: lector < editor < propietario.
CREATE FUNCTION nivel_rol(rol text) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE rol WHEN 'propietario' THEN 3 WHEN 'editor' THEN 2 WHEN 'lector' THEN 1 ELSE 0 END
$$;

CREATE TABLE espacios (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre      text        NOT NULL,
  creado_por  uuid        NOT NULL REFERENCES usuarios (id),
  creado_en   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT espacios_nombre_formato CHECK (nombre = btrim(nombre) AND length(nombre) BETWEEN 1 AND 80)
);

CREATE TABLE miembros_espacio (
  espacio_id     uuid        NOT NULL REFERENCES espacios (id) ON DELETE CASCADE,
  usuario_id     uuid        NOT NULL,
  estado_usuario text        NOT NULL DEFAULT 'activa',
  rol            text        NOT NULL,
  creado_en      timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (espacio_id, usuario_id),
  CONSTRAINT miembros_espacio_rol_valido CHECK (rol IN ('propietario', 'editor', 'lector')),
  CONSTRAINT miembros_espacio_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT miembros_espacio_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado)
);

CREATE UNIQUE INDEX miembros_espacio_un_propietario ON miembros_espacio (espacio_id) WHERE rol = 'propietario';
CREATE INDEX miembros_espacio_por_usuario ON miembros_espacio (usuario_id);

CREATE TRIGGER espacios_fijar_creado_en BEFORE INSERT ON espacios
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER miembros_espacio_fijar_creado_en BEFORE INSERT ON miembros_espacio
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();

-- Techo por rol de cuenta: una cuenta "lector" solo puede ser lectora. Se reutiliza en permisos_documento.
CREATE FUNCTION techo_rol_cuenta() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.rol <> 'lector' AND (SELECT rol FROM usuarios WHERE id = NEW.usuario_id) = 'lector' THEN
    RAISE EXCEPTION 'Una cuenta lectora solo puede tener rol lector (pidió %)', NEW.rol
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER miembros_espacio_techo_rol_cuenta BEFORE INSERT OR UPDATE OF rol, usuario_id ON miembros_espacio
  FOR EACH ROW EXECUTE FUNCTION techo_rol_cuenta();

-- Todo espacio existente tiene un propietario. Se revisa al COMMIT: al crear un espacio, la fila del
-- espacio y la de su propietario se insertan en la misma transacción.
CREATE FUNCTION espacio_con_propietario() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  eid uuid;
BEGIN
  IF TG_TABLE_NAME = 'espacios' THEN
    eid := NEW.id;
  ELSE
    eid := OLD.espacio_id;
  END IF;
  IF EXISTS (SELECT 1 FROM espacios WHERE id = eid)
     AND NOT EXISTS (SELECT 1 FROM miembros_espacio WHERE espacio_id = eid AND rol = 'propietario') THEN
    RAISE EXCEPTION 'Todo espacio necesita exactamente un propietario' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER espacios_con_propietario
  AFTER INSERT ON espacios
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION espacio_con_propietario();
CREATE CONSTRAINT TRIGGER miembros_espacio_con_propietario
  AFTER DELETE OR UPDATE OF rol, espacio_id ON miembros_espacio
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION espacio_con_propietario();
