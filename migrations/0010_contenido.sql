-- 0010 · Contenido: actualizaciones Yjs, versiones encadenadas, comentarios y sesiones de edición.
--
-- Escritura protegida por la base: insertar una actualización o una versión exige que su autor tenga rol
-- efectivo editor o propietario EN ESE MOMENTO. Un lector no escribe aunque el backend se equivoque.
--
-- Historial de versiones a prueba de manipulación:
--   - SOLO INSERCIÓN: UPDATE, DELETE y TRUNCATE están prohibidos (las versiones solo desaparecen junto con
--     su documento).
--   - CADENA DE HASH: la base calcula número, hash_previo y hash de cada versión (el cliente no los
--     elige). hash = SHA-256(hash_previo ‖ documento ‖ número ‖ SHA-256(estado) ‖ SHA-256(texto) ‖
--     autor ‖ motivo ‖ restaurada_de ‖ creado_en). verificar_cadena_versiones() recalcula la cadena y
--     devuelve el primer número alterado, así que incluso un superusuario que desactive los triggers y
--     edite una versión queda en evidencia.

CREATE TABLE actualizaciones_documento (
  id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  documento_id uuid        NOT NULL REFERENCES documentos (id) ON DELETE CASCADE,
  autor_id     uuid        NOT NULL REFERENCES usuarios (id),
  actualizacion bytea      NOT NULL,
  creado_en    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT actualizaciones_tamano CHECK (octet_length(actualizacion) BETWEEN 1 AND 1048576)
);

CREATE INDEX actualizaciones_por_documento ON actualizaciones_documento (documento_id, id);

-- Escribir contenido exige rol efectivo editor o propietario. Se reutiliza en versiones.
CREATE FUNCTION exigir_escritura(p_usuario uuid, p_documento uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(rol_efectivo_documento(p_usuario, p_documento), '') NOT IN ('editor', 'propietario') THEN
    RAISE EXCEPTION 'Sin permiso de escritura sobre el documento' USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

CREATE FUNCTION actualizaciones_exigen_escritura() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_escritura(NEW.autor_id, NEW.documento_id);
  RETURN NEW;
END
$$;

CREATE TRIGGER actualizaciones_fijar_creado_en BEFORE INSERT ON actualizaciones_documento
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER actualizaciones_exigen_escritura BEFORE INSERT ON actualizaciones_documento
  FOR EACH ROW EXECUTE FUNCTION actualizaciones_exigen_escritura();
CREATE TRIGGER actualizaciones_inmutables BEFORE UPDATE ON actualizaciones_documento
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('documento_id', 'autor_id', 'actualizacion', 'creado_en');

-- ─── Versiones ──────────────────────────────────────────────────────────────────

CREATE TABLE versiones (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id     uuid        NOT NULL REFERENCES documentos (id) ON DELETE CASCADE,
  numero           bigint      NOT NULL,
  motivo           text        NOT NULL,
  creado_por       uuid        REFERENCES usuarios (id),
  restaurada_de    uuid,
  estado_yjs       bytea       NOT NULL,
  contenido_texto  text        NOT NULL,
  hash_previo      bytea       NOT NULL,
  hash             bytea       NOT NULL,
  creado_en        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT versiones_motivo_valido CHECK (motivo IN ('automatica', 'manual', 'restauracion')),
  -- Las automáticas las crea el sistema (sin autor); las manuales y restauraciones tienen autor.
  CONSTRAINT versiones_autor_segun_motivo CHECK ((motivo = 'automatica') = (creado_por IS NULL)),
  CONSTRAINT versiones_restauracion_coherente CHECK ((motivo = 'restauracion') = (restaurada_de IS NOT NULL)),
  CONSTRAINT versiones_numero_positivo CHECK (numero > 0),
  CONSTRAINT versiones_hashes_sha256 CHECK (octet_length(hash_previo) = 32 AND octet_length(hash) = 32),
  CONSTRAINT versiones_estado_tamano CHECK (octet_length(estado_yjs) <= 10485760),
  CONSTRAINT versiones_numero_unico UNIQUE (documento_id, numero),
  CONSTRAINT versiones_hash_unico UNIQUE (hash),
  CONSTRAINT versiones_id_documento_unico UNIQUE (id, documento_id),
  -- Solo se restaura una versión del MISMO documento.
  CONSTRAINT versiones_restaura_su_documento FOREIGN KEY (restaurada_de, documento_id) REFERENCES versiones (id, documento_id)
);

-- Hash canónico de una versión. Se usa al insertar y al verificar.
CREATE FUNCTION hash_version(
  p_hash_previo bytea, p_documento uuid, p_numero bigint, p_estado bytea, p_texto text,
  p_autor uuid, p_motivo text, p_restaurada_de uuid, p_creado_en timestamptz
) RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
  SELECT sha256(
    p_hash_previo
    || uuid_send(p_documento)
    || int8send(p_numero)
    || sha256(p_estado)
    || sha256(convert_to(p_texto, 'UTF8'))
    || coalesce(uuid_send(p_autor), '\x'::bytea)
    || convert_to(p_motivo, 'UTF8')
    || coalesce(uuid_send(p_restaurada_de), '\x'::bytea)
    || int8send((extract(epoch FROM p_creado_en) * 1000000)::bigint)
  )
$$;

-- La base encadena: el cliente no elige número, hash_previo, hash ni fecha.
CREATE FUNCTION versiones_encadenar() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  previa record;
BEGIN
  IF NEW.creado_por IS NOT NULL THEN
    PERFORM exigir_escritura(NEW.creado_por, NEW.documento_id);
  END IF;
  -- Serializa versiones concurrentes del mismo documento.
  PERFORM 1 FROM documentos WHERE id = NEW.documento_id FOR UPDATE;
  SELECT numero, hash INTO previa FROM versiones
  WHERE documento_id = NEW.documento_id ORDER BY numero DESC LIMIT 1;
  NEW.creado_en := now();
  NEW.numero := coalesce(previa.numero, 0) + 1;
  NEW.hash_previo := coalesce(previa.hash, decode(repeat('00', 32), 'hex'));
  NEW.hash := hash_version(NEW.hash_previo, NEW.documento_id, NEW.numero, NEW.estado_yjs, NEW.contenido_texto,
                           NEW.creado_por, NEW.motivo, NEW.restaurada_de, NEW.creado_en);
  RETURN NEW;
END
$$;

CREATE FUNCTION versiones_solo_insercion() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Única excepción: la versión desaparece porque su documento ya no existe (borrado en cascada).
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM documentos WHERE id = OLD.documento_id) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'El historial de versiones es de solo inserción (% prohibido)', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

CREATE TRIGGER versiones_encadenar BEFORE INSERT ON versiones
  FOR EACH ROW EXECUTE FUNCTION versiones_encadenar();
CREATE TRIGGER versiones_solo_insercion BEFORE UPDATE OR DELETE ON versiones
  FOR EACH ROW EXECUTE FUNCTION versiones_solo_insercion();
CREATE TRIGGER versiones_sin_truncate BEFORE TRUNCATE ON versiones
  FOR EACH STATEMENT EXECUTE FUNCTION versiones_solo_insercion();

-- Recalcula la cadena de un documento. Devuelve el número de la primera versión alterada, o NULL si
-- la cadena está íntegra.
CREATE FUNCTION verificar_cadena_versiones(p_documento uuid) RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
  v record;
  esperado_previo bytea := decode(repeat('00', 32), 'hex');
  esperado_numero bigint := 1;
BEGIN
  FOR v IN SELECT * FROM versiones WHERE documento_id = p_documento ORDER BY numero LOOP
    IF v.numero <> esperado_numero
       OR v.hash_previo <> esperado_previo
       OR v.hash <> hash_version(v.hash_previo, v.documento_id, v.numero, v.estado_yjs, v.contenido_texto,
                                 v.creado_por, v.motivo, v.restaurada_de, v.creado_en) THEN
      RETURN v.numero;
    END IF;
    esperado_previo := v.hash;
    esperado_numero := esperado_numero + 1;
  END LOOP;
  RETURN NULL;
END
$$;

-- ─── Comentarios ────────────────────────────────────────────────────────────────

CREATE TABLE comentarios (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id  uuid        NOT NULL REFERENCES documentos (id) ON DELETE CASCADE,
  autor_id      uuid        NOT NULL REFERENCES usuarios (id),
  padre_id      uuid,
  ancla         bytea,
  cuerpo        text        NOT NULL,
  resuelto_en   timestamptz,
  creado_en     timestamptz NOT NULL DEFAULT now(),
  editado_en    timestamptz,

  CONSTRAINT comentarios_cuerpo_longitud CHECK (length(btrim(cuerpo)) BETWEEN 1 AND 5000),
  CONSTRAINT comentarios_ancla_tamano CHECK (ancla IS NULL OR octet_length(ancla) <= 1024),
  -- Las respuestas no llevan ancla propia: heredan la del hilo.
  CONSTRAINT comentarios_ancla_solo_en_hilo CHECK (padre_id IS NULL OR ancla IS NULL),
  CONSTRAINT comentarios_id_documento_unico UNIQUE (id, documento_id),
  -- Una respuesta pertenece al mismo documento que su hilo.
  CONSTRAINT comentarios_responde_su_documento FOREIGN KEY (padre_id, documento_id) REFERENCES comentarios (id, documento_id) ON DELETE CASCADE
);

CREATE INDEX comentarios_por_documento ON comentarios (documento_id, creado_en);

-- Comentar exige acceso al documento (un lector puede comentar).
CREATE FUNCTION comentarios_exigen_acceso() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF rol_efectivo_documento(NEW.autor_id, NEW.documento_id) IS NULL THEN
    RAISE EXCEPTION 'Sin acceso al documento' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER comentarios_fijar_creado_en BEFORE INSERT ON comentarios
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER comentarios_exigen_acceso BEFORE INSERT ON comentarios
  FOR EACH ROW EXECUTE FUNCTION comentarios_exigen_acceso();
CREATE TRIGGER comentarios_autor_inmutable BEFORE UPDATE ON comentarios
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('documento_id', 'autor_id', 'padre_id', 'creado_en');

-- ─── Sesiones de edición (presencia) ────────────────────────────────────────────

CREATE TABLE sesiones_edicion (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id     uuid        NOT NULL REFERENCES documentos (id) ON DELETE CASCADE,
  usuario_id       uuid        NOT NULL,
  sesion_id        uuid        NOT NULL,
  rol              text        NOT NULL,
  conectado_en     timestamptz NOT NULL DEFAULT now(),
  ultimo_latido_en timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT sesiones_edicion_rol_valido CHECK (rol IN ('propietario', 'editor', 'lector')),
  -- La sesión de edición cuelga de una sesión de login del MISMO usuario; cerrarla la borra.
  CONSTRAINT sesiones_edicion_de_su_sesion FOREIGN KEY (sesion_id, usuario_id) REFERENCES sesiones (id, usuario_id) ON DELETE CASCADE
);

CREATE INDEX sesiones_edicion_por_documento ON sesiones_edicion (documento_id);
CREATE INDEX sesiones_edicion_por_sesion ON sesiones_edicion (sesion_id);

-- Al conectar: la sesión de login sigue viva y el rol registrado es exactamente el rol efectivo
-- (nadie se registra con más permisos de los que tiene).
CREATE FUNCTION sesiones_edicion_validar() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.conectado_en := now();
  IF EXISTS (SELECT 1 FROM sesiones WHERE id = NEW.sesion_id AND (revocada_en IS NOT NULL OR expira_en <= now())) THEN
    RAISE EXCEPTION 'La sesión de login no está viva' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.rol IS DISTINCT FROM rol_efectivo_documento(NEW.usuario_id, NEW.documento_id) THEN
    RAISE EXCEPTION 'El rol de la sesión de edición no coincide con el rol efectivo'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER sesiones_edicion_validar BEFORE INSERT ON sesiones_edicion
  FOR EACH ROW EXECUTE FUNCTION sesiones_edicion_validar();
CREATE TRIGGER sesiones_edicion_inmutables BEFORE UPDATE ON sesiones_edicion
  FOR EACH ROW EXECUTE FUNCTION una_sola_vez('documento_id', 'usuario_id', 'sesion_id', 'rol', 'conectado_en');
