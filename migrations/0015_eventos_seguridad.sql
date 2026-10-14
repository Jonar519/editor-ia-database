-- 0015 · Registro de auditoría de seguridad (eventos_seguridad), de SOLO INSERCIÓN.
--
-- Guarda SOLO: tipo de evento (lista cerrada), cuenta (si se conoce), IP truncada y fecha. No hay
-- columnas de texto libre: por construcción no puede guardar tokens, contraseñas ni códigos.
--
-- Solo inserción, con dos excepciones acotadas por la base (mismo estilo que versiones, bloque C):
--   - ANONIMIZAR: un UPDATE solo puede poner en NULL usuario_id y/o ip_red (eliminación de cuenta,
--     bloque G). Cualquier otro cambio se rechaza.
--   - RETENCIÓN: un DELETE solo puede borrar eventos de más de 180 días (limpieza diaria, bloque G).
-- TRUNCATE prohibido. El rol de la aplicación solo tiene SELECT, INSERT, UPDATE(usuario_id, ip_red) y DELETE.

CREATE TABLE eventos_seguridad (
  id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tipo       text        NOT NULL,
  usuario_id uuid        REFERENCES usuarios (id) ON DELETE SET NULL,
  ip_red     cidr,
  creado_en  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT eventos_seguridad_tipo_valido CHECK (tipo IN (
    'inicio_sesion', 'inicio_fallido', 'cuenta_bloqueada', 'cierre_sesion', 'refresco_reutilizado',
    'mfa_desafio', 'mfa_correcto', 'mfa_fallido', 'codigo_respaldo_usado',
    'mfa_activado', 'mfa_desactivado', 'codigos_respaldo_regenerados',
    'invitacion_creada', 'invitacion_reenviada', 'invitacion_cancelada', 'invitacion_completada',
    'recuperacion_solicitada', 'contrasena_restablecida'
  )),
  CONSTRAINT eventos_seguridad_ip_truncada CHECK (ip_red IS NULL OR (family(ip_red) = 4 AND masklen(ip_red) = 24) OR (family(ip_red) = 6 AND masklen(ip_red) = 48))
);

CREATE INDEX eventos_seguridad_por_usuario ON eventos_seguridad (usuario_id, creado_en);
CREATE INDEX eventos_seguridad_por_fecha ON eventos_seguridad (creado_en);

/** Días que se conservan los eventos (retención; la limpieza diaria es del bloque G). */
CREATE FUNCTION retencion_eventos_seguridad() RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT interval '180 days'
$$;

CREATE FUNCTION eventos_seguridad_solo_insercion() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.creado_en < now() - retencion_eventos_seguridad() THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Solo se borran eventos de seguridad más antiguos que la retención'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.id = OLD.id AND NEW.tipo = OLD.tipo AND NEW.creado_en = OLD.creado_en
       AND (NEW.usuario_id IS NOT DISTINCT FROM OLD.usuario_id OR NEW.usuario_id IS NULL)
       AND (NEW.ip_red IS NOT DISTINCT FROM OLD.ip_red OR NEW.ip_red IS NULL) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Un evento de seguridad solo se puede anonimizar (usuario_id e ip_red a NULL)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RAISE EXCEPTION 'El registro de eventos de seguridad es de solo inserción (% prohibido)', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

CREATE TRIGGER eventos_seguridad_fijar_creado_en BEFORE INSERT ON eventos_seguridad
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER eventos_seguridad_solo_insercion BEFORE UPDATE OR DELETE ON eventos_seguridad
  FOR EACH ROW EXECUTE FUNCTION eventos_seguridad_solo_insercion();
CREATE TRIGGER eventos_seguridad_sin_truncate BEFORE TRUNCATE ON eventos_seguridad
  FOR EACH STATEMENT EXECUTE FUNCTION eventos_seguridad_solo_insercion();

GRANT SELECT, INSERT, DELETE ON eventos_seguridad TO cuaderno_app;
GRANT UPDATE (usuario_id, ip_red) ON eventos_seguridad TO cuaderno_app;
