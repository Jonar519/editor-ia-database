-- 0017 · Avatares.
--
-- El backend limpia la imagen ANTES de guardarla: reconstruye el archivo copiando solo los segmentos
-- (JPEG) o chunks (PNG) de una lista blanca, así que EXIF, GPS, XMP, ICC, comentarios y cualquier dato
-- pegado al final no llegan nunca aquí. Un archivo que no se puede analizar se rechaza y no se guarda.
--
-- La base agrega sus propias barreras:
--   - Solo cuentas ACTIVAS (CHECK + clave foránea compuesta, como sesiones y tokens): eliminar la cuenta
--     exige borrar antes el avatar.
--   - Tipo de una lista cerrada (JPEG o PNG) y la firma de bytes que le corresponde: un archivo de otro
--     tipo con la extensión cambiada no entra.
--   - 1 MiB como máximo y dimensiones de 1 a 4096 px.
--   - hash = SHA-256(datos), calculado y comprobado por la base (sirve de ETag).

CREATE TABLE avatares (
  usuario_id     uuid        PRIMARY KEY,
  estado_usuario text        NOT NULL DEFAULT 'activa',
  tipo           text        NOT NULL,
  datos          bytea       NOT NULL,
  ancho          integer     NOT NULL,
  alto           integer     NOT NULL,
  hash           bytea       NOT NULL,
  actualizado_en timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT avatares_solo_cuentas_activas CHECK (estado_usuario = 'activa'),
  CONSTRAINT avatares_usuario_activo FOREIGN KEY (usuario_id, estado_usuario) REFERENCES usuarios (id, estado),
  -- Redundante (usuario_id ya es la clave primaria), pero Prisma lo exige para modelar la relación uno a
  -- uno con la clave foránea compuesta, igual que en mfa_totp (0013).
  CONSTRAINT avatares_una_por_cuenta UNIQUE (usuario_id, estado_usuario),
  CONSTRAINT avatares_tamano CHECK (octet_length(datos) BETWEEN 1 AND 1048576),
  CONSTRAINT avatares_dimensiones CHECK (ancho BETWEEN 1 AND 4096 AND alto BETWEEN 1 AND 4096),
  -- Tipo de una lista cerrada (JPEG o PNG) y la firma de bytes que le corresponde: JPEG empieza con
  -- FF D8 FF y termina en FF D9 (nada pegado después); PNG empieza con su firma de 8 bytes. Cualquier
  -- otro tipo no cumple ninguna de las dos ramas.
  CONSTRAINT avatares_firma_segun_tipo CHECK (
    (tipo = 'image/jpeg' AND substring(datos FROM 1 FOR 3) = '\xffd8ff'::bytea
                         AND substring(datos FROM octet_length(datos) - 1) = '\xffd9'::bytea)
    OR (tipo = 'image/png' AND substring(datos FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea)
  ),
  CONSTRAINT avatares_hash_de_los_datos CHECK (hash = sha256(datos))
);

CREATE TRIGGER avatares_fijar_actualizado_en BEFORE UPDATE ON avatares
  FOR EACH ROW EXECUTE FUNCTION fijar_actualizado_en();

GRANT SELECT, INSERT, UPDATE, DELETE ON avatares TO cuaderno_app;
