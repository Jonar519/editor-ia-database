-- 0009 · Documentos, permisos por documento y rol efectivo.
--
-- - Un documento pertenece a un espacio para siempre (espacio_id inmutable): sus embeddings, permisos y
--   versiones heredan ese aislamiento.
-- - Un permiso de documento solo se da a un MIEMBRO del espacio del documento (claves foráneas compuestas):
--   no hay forma de compartir un documento fuera de su espacio. Sacar a alguien del espacio borra sus
--   permisos de documento en cascada.
-- - Exactamente un propietario por documento (índice único parcial + restricción diferida).
-- - rol_efectivo_documento(usuario, documento) es LA respuesta a "¿qué puede hacer?". El backend la
--   consulta en cada mensaje del WebSocket y la base la usa en sus propios triggers de escritura.
-- - Cualquier cambio o retiro de permiso emite NOTIFY 'cuaderno_permisos' para cortar conexiones en curso.

CREATE TABLE documentos (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  espacio_id     uuid        NOT NULL REFERENCES espacios (id) ON DELETE CASCADE,
  titulo         text        NOT NULL,
  creado_por     uuid        NOT NULL REFERENCES usuarios (id),
  estado_yjs     bytea,
  creado_en      timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT documentos_titulo_formato CHECK (titulo = btrim(titulo) AND length(titulo) BETWEEN 1 AND 200),
  CONSTRAINT documentos_estado_tamano CHECK (estado_yjs IS NULL OR octet_length(estado_yjs) <= 10485760),
  -- Destino de las claves foráneas compuestas (documento_id, espacio_id) de permisos y embeddings.
  CONSTRAINT documentos_id_espacio_unico UNIQUE (id, espacio_id)
);

CREATE INDEX documentos_por_espacio ON documentos (espacio_id);

CREATE TRIGGER documentos_fijar_creado_en BEFORE INSERT ON documentos
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER documentos_fijar_actualizado_en BEFORE UPDATE ON documentos
  FOR EACH ROW EXECUTE FUNCTION fijar_actualizado_en();
CREATE TRIGGER documentos_espacio_inmutable BEFORE UPDATE ON documentos
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('espacio_id', 'creado_por', 'creado_en');

CREATE TABLE permisos_documento (
  documento_id uuid        NOT NULL,
  espacio_id   uuid        NOT NULL,
  usuario_id   uuid        NOT NULL,
  rol          text        NOT NULL,
  creado_en    timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (documento_id, usuario_id),
  CONSTRAINT permisos_documento_rol_valido CHECK (rol IN ('propietario', 'editor', 'lector')),
  CONSTRAINT permisos_documento_del_documento FOREIGN KEY (documento_id, espacio_id) REFERENCES documentos (id, espacio_id) ON DELETE CASCADE,
  CONSTRAINT permisos_documento_solo_miembros FOREIGN KEY (espacio_id, usuario_id) REFERENCES miembros_espacio (espacio_id, usuario_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX permisos_documento_un_propietario ON permisos_documento (documento_id) WHERE rol = 'propietario';
CREATE INDEX permisos_documento_por_usuario ON permisos_documento (usuario_id);

CREATE TRIGGER permisos_documento_fijar_creado_en BEFORE INSERT ON permisos_documento
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER permisos_documento_techo_rol_cuenta BEFORE INSERT OR UPDATE OF rol, usuario_id ON permisos_documento
  FOR EACH ROW EXECUTE FUNCTION techo_rol_cuenta();

-- Bajar una cuenta a lectora exige quitarle antes todo rol que escriba, en espacios y en documentos.
CREATE FUNCTION usuarios_lector_sin_roles_de_escritura() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.rol = 'lector' AND OLD.rol <> 'lector' AND (
       EXISTS (SELECT 1 FROM miembros_espacio WHERE usuario_id = NEW.id AND rol <> 'lector')
    OR EXISTS (SELECT 1 FROM permisos_documento WHERE usuario_id = NEW.id AND rol <> 'lector')
  ) THEN
    RAISE EXCEPTION 'La cuenta tiene roles de escritura: quítalos antes de pasarla a lector'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER usuarios_lector_sin_roles_de_escritura BEFORE UPDATE OF rol ON usuarios
  FOR EACH ROW EXECUTE FUNCTION usuarios_lector_sin_roles_de_escritura();

-- Rol efectivo de una cuenta sobre un documento: el mayor entre su rol en el documento y su rol en el
-- espacio (ser propietario del espacio da "editor" en sus documentos, no "propietario"), con dos topes:
-- sin membresía en el espacio no hay acceso, y una cuenta lectora nunca pasa de "lector".
-- Devuelve NULL si no hay acceso (cuenta no activa, no miembro, documento inexistente).
CREATE FUNCTION rol_efectivo_documento(p_usuario uuid, p_documento uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN x.rol_cuenta = 'lector' THEN 'lector'
           WHEN x.nivel = 3 THEN 'propietario'
           WHEN x.nivel = 2 THEN 'editor'
           ELSE 'lector'
         END
  FROM (
    SELECT u.rol AS rol_cuenta,
           greatest(nivel_rol(pd.rol), least(nivel_rol(me.rol), 2)) AS nivel
    FROM documentos d
    JOIN usuarios u ON u.id = p_usuario AND u.estado = 'activa'
    JOIN miembros_espacio me ON me.espacio_id = d.espacio_id AND me.usuario_id = u.id
    LEFT JOIN permisos_documento pd ON pd.documento_id = d.id AND pd.usuario_id = u.id
    WHERE d.id = p_documento
  ) AS x
$$;

-- Crear documentos exige poder escribir en el espacio (propietario o editor del espacio).
CREATE FUNCTION documentos_creador_puede_escribir() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM miembros_espacio me JOIN usuarios u ON u.id = me.usuario_id
    WHERE me.espacio_id = NEW.espacio_id AND me.usuario_id = NEW.creado_por
      AND me.rol IN ('propietario', 'editor') AND u.estado = 'activa' AND u.rol <> 'lector'
  ) THEN
    RAISE EXCEPTION 'Solo un editor o propietario del espacio puede crear documentos'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER documentos_creador_puede_escribir BEFORE INSERT ON documentos
  FOR EACH ROW EXECUTE FUNCTION documentos_creador_puede_escribir();

-- Todo documento existente tiene un propietario (revisado al COMMIT).
CREATE FUNCTION documento_con_propietario() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  did uuid;
BEGIN
  IF TG_TABLE_NAME = 'documentos' THEN
    did := NEW.id;
  ELSE
    did := OLD.documento_id;
  END IF;
  IF EXISTS (SELECT 1 FROM documentos WHERE id = did)
     AND NOT EXISTS (SELECT 1 FROM permisos_documento WHERE documento_id = did AND rol = 'propietario') THEN
    RAISE EXCEPTION 'Todo documento necesita exactamente un propietario' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER documentos_con_propietario
  AFTER INSERT ON documentos
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION documento_con_propietario();
CREATE CONSTRAINT TRIGGER permisos_documento_con_propietario
  AFTER DELETE OR UPDATE OF rol, documento_id ON permisos_documento
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION documento_con_propietario();

-- Aviso de cambio de permisos: el backend escucha (LISTEN cuaderno_permisos) y vuelve a evaluar o corta
-- las conexiones de esa cuenta. El aviso sale al COMMIT; si la transacción se revierte, no sale.
CREATE FUNCTION avisar_cambio_permisos() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  fila record;
BEGIN
  IF TG_OP = 'INSERT' THEN
    RETURN NULL;
  END IF;
  fila := OLD;
  PERFORM pg_notify('cuaderno_permisos', json_build_object(
    'tabla', TG_TABLE_NAME,
    'operacion', TG_OP,
    'usuario_id', fila.usuario_id,
    'espacio_id', fila.espacio_id,
    'documento_id', CASE WHEN TG_TABLE_NAME = 'permisos_documento' THEN to_jsonb(fila) ->> 'documento_id' END
  )::text);
  RETURN NULL;
END
$$;

CREATE TRIGGER miembros_espacio_avisar_cambio AFTER UPDATE OR DELETE ON miembros_espacio
  FOR EACH ROW EXECUTE FUNCTION avisar_cambio_permisos();
CREATE TRIGGER permisos_documento_avisar_cambio AFTER UPDATE OR DELETE ON permisos_documento
  FOR EACH ROW EXECUTE FUNCTION avisar_cambio_permisos();
