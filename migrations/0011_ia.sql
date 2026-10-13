-- 0011 · Embeddings para la búsqueda semántica y uso diario de IA.
--
-- AISLAMIENTO GARANTIZADO POR LA BASE:
--   1. Un fragmento indexado pertenece al espacio de su documento: clave foránea compuesta
--      (documento_id, espacio_id) → documentos (id, espacio_id). No existe un embedding con el espacio
--      equivocado.
--   2. Solo indexa quien tiene acceso al documento: el trigger embeddings_aislamiento rechaza cualquier
--      embedding cuyo indexado_por no tenga rol efectivo sobre el documento (contenido ajeno = rechazado).
--   3. La búsqueda (buscar_fragmentos) filtra por espacio Y por acceso actual de quien busca, así que
--      perder el permiso hoy oculta los fragmentos hoy, aunque se hayan indexado ayer.
--
-- Dimensión fija de 1024 (la del proveedor mock; un proveedor real con otra dimensión exige migración).

CREATE TABLE embeddings (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id uuid         NOT NULL,
  espacio_id   uuid         NOT NULL,
  fragmento    integer      NOT NULL,
  texto        text         NOT NULL,
  hash_texto   bytea        NOT NULL,
  modelo       text         NOT NULL,
  embedding    vector(1024) NOT NULL,
  indexado_por uuid         NOT NULL REFERENCES usuarios (id),
  creado_en    timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT embeddings_mismo_espacio_que_documento FOREIGN KEY (documento_id, espacio_id) REFERENCES documentos (id, espacio_id) ON DELETE CASCADE,
  CONSTRAINT embeddings_fragmento_no_negativo CHECK (fragmento >= 0),
  CONSTRAINT embeddings_texto_longitud CHECK (length(texto) BETWEEN 1 AND 4000),
  CONSTRAINT embeddings_hash_sha256 CHECK (octet_length(hash_texto) = 32),
  CONSTRAINT embeddings_modelo_longitud CHECK (length(modelo) BETWEEN 1 AND 100),
  CONSTRAINT embeddings_fragmento_unico UNIQUE (documento_id, fragmento)
);

CREATE INDEX embeddings_por_espacio ON embeddings (espacio_id);
CREATE INDEX embeddings_vector_coseno ON embeddings USING hnsw (embedding vector_cosine_ops);

CREATE FUNCTION embeddings_aislamiento() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF rol_efectivo_documento(NEW.indexado_por, NEW.documento_id) IS NULL THEN
    RAISE EXCEPTION 'Aislamiento: % no tiene acceso al documento %; no puede indexarlo', NEW.indexado_por, NEW.documento_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER embeddings_fijar_creado_en BEFORE INSERT ON embeddings
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER embeddings_aislamiento BEFORE INSERT OR UPDATE ON embeddings
  FOR EACH ROW EXECUTE FUNCTION embeddings_aislamiento();

-- Búsqueda semántica restringida a un espacio y a los documentos que quien busca puede leer HOY.
CREATE FUNCTION buscar_fragmentos(p_usuario uuid, p_espacio uuid, p_consulta vector(1024), p_limite integer)
RETURNS TABLE (documento_id uuid, fragmento integer, texto text, distancia double precision)
LANGUAGE sql STABLE AS $$
  SELECT e.documento_id, e.fragmento, e.texto, e.embedding <=> p_consulta
  FROM embeddings e
  WHERE e.espacio_id = p_espacio
    AND rol_efectivo_documento(p_usuario, e.documento_id) IS NOT NULL
  ORDER BY e.embedding <=> p_consulta
  LIMIT least(greatest(p_limite, 1), 50)
$$;

-- Uso diario de IA por cuenta (día en UTC). El tope lo aplica el backend con un UPDATE condicional;
-- la base garantiza contadores no negativos.
CREATE TABLE uso_ia_diario (
  usuario_id     uuid    NOT NULL REFERENCES usuarios (id),
  dia            date    NOT NULL,
  peticiones     integer NOT NULL DEFAULT 0,
  tokens_entrada bigint  NOT NULL DEFAULT 0,
  tokens_salida  bigint  NOT NULL DEFAULT 0,

  PRIMARY KEY (usuario_id, dia),
  CONSTRAINT uso_ia_contadores_no_negativos CHECK (peticiones >= 0 AND tokens_entrada >= 0 AND tokens_salida >= 0)
);
