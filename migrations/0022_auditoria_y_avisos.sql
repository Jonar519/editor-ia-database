-- 0022 · Bloque K2: auditoría de permisos y avisos de todo lo que quita acceso.
--
-- 1. AUDITORÍA. eventos_seguridad suma dos columnas para saber A QUIÉN y SOBRE QUÉ:
--      objetivo_id  la cuenta afectada (queda en NULL si esa cuenta se borra, y se anonimiza cuando pasa
--                   a lápida: ver el trigger de abajo, que corre dentro de eliminar_cuenta()).
--      recurso_id   el espacio o documento. Es un ID, nunca contenido (ni nombres ni títulos). Sin clave
--                   foránea a propósito: el evento sobrevive al borrado del recurso.
--    Y nueve tipos: concesión y revocación de miembros, de permisos de documento y de propiedad. Las
--    creaciones de espacios y documentos NO se registran (decisión escrita del bloque K2).
--
-- 2. AVISOS. Además de cuaderno_permisos (0009: miembros y permisos de documento), la base avisa en el
--    mismo canal cuando se pierde acceso por otra vía:
--      sesiones    una sesión viva se revoca o se borra (salir, otra sesión, cambio de contraseña,
--                  reutilización del refresh, eliminar la cuenta...);
--      usuarios    una cuenta deja de estar activa o cambia de rol de cuenta;
--      documentos  un documento se borra (también en cascada, al borrar su espacio).
--    El backend escucha el canal y lo reenvía a Redis (ADR 0002). Cada aviso lleva SOLO ids.
--    Como sale de la base, cubre también cambios hechos por SQL directo. Sale al COMMIT; si la
--    transacción se revierte, no sale.

-- ─── Auditoría ──────────────────────────────────────────────────────────────────

ALTER TABLE eventos_seguridad
  ADD COLUMN objetivo_id uuid REFERENCES usuarios (id) ON DELETE SET NULL,
  ADD COLUMN recurso_id uuid;

COMMENT ON COLUMN eventos_seguridad.recurso_id IS 'Id del espacio o documento afectado. Solo un id: nunca nombres, títulos ni contenido.';

ALTER TABLE eventos_seguridad DROP CONSTRAINT eventos_seguridad_tipo_valido;
ALTER TABLE eventos_seguridad ADD CONSTRAINT eventos_seguridad_tipo_valido CHECK (tipo IN (
  'inicio_sesion', 'inicio_fallido', 'cuenta_bloqueada', 'cierre_sesion', 'refresco_reutilizado',
  'mfa_desafio', 'mfa_correcto', 'mfa_fallido', 'codigo_respaldo_usado',
  'mfa_activado', 'mfa_desactivado', 'codigos_respaldo_regenerados',
  'invitacion_creada', 'invitacion_reenviada', 'invitacion_cancelada', 'invitacion_completada',
  'recuperacion_solicitada', 'contrasena_restablecida',
  'perfil_actualizado', 'cambio_correo_solicitado', 'correo_cambiado', 'contrasena_cambiada',
  'sesion_cerrada', 'otras_sesiones_cerradas', 'avatar_actualizado', 'avatar_eliminado',
  'datos_exportados', 'cuenta_eliminada',
  -- Bloque K2: permisos sobre el contenido.
  'miembro_agregado', 'miembro_rol_cambiado', 'miembro_quitado', 'espacio_transferido', 'espacio_eliminado',
  'permiso_documento_dado', 'permiso_documento_quitado', 'documento_transferido', 'documento_eliminado'
));

-- Solo inserción (0015), ahora con objetivo_id entre lo que se puede anonimizar. recurso_id no se toca.
CREATE OR REPLACE FUNCTION eventos_seguridad_solo_insercion() RETURNS trigger LANGUAGE plpgsql AS $$
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
       AND NEW.recurso_id IS NOT DISTINCT FROM OLD.recurso_id
       AND (NEW.usuario_id IS NOT DISTINCT FROM OLD.usuario_id OR NEW.usuario_id IS NULL)
       AND (NEW.objetivo_id IS NOT DISTINCT FROM OLD.objetivo_id OR NEW.objetivo_id IS NULL)
       AND (NEW.ip_red IS NOT DISTINCT FROM OLD.ip_red OR NEW.ip_red IS NULL) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Un evento de seguridad solo se puede anonimizar (usuario_id, objetivo_id e ip_red a NULL)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RAISE EXCEPTION 'El registro de eventos de seguridad es de solo inserción (% prohibido)', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

GRANT UPDATE (objetivo_id) ON eventos_seguridad TO cuaderno_app;

CREATE INDEX eventos_seguridad_por_objetivo ON eventos_seguridad (objetivo_id) WHERE objetivo_id IS NOT NULL;

-- Una cuenta que pasa a lápida deja de ser objetivo identificable. eliminar_cuenta() (0018) ya anonimiza
-- usuario_id; este trigger corre dentro de esa misma transacción (con su UPDATE a 'eliminada') y cubre
-- objetivo_id.
CREATE FUNCTION anonimizar_objetivo_de_lapida() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE eventos_seguridad SET objetivo_id = NULL WHERE objetivo_id = NEW.id;
  RETURN NULL;
END
$$;

CREATE TRIGGER usuarios_anonimizar_objetivo AFTER UPDATE OF estado ON usuarios
  FOR EACH ROW WHEN (NEW.estado = 'eliminada' AND OLD.estado <> 'eliminada')
  EXECUTE FUNCTION anonimizar_objetivo_de_lapida();

-- ─── Avisos de pérdida de acceso ────────────────────────────────────────────────

CREATE FUNCTION avisar_perdida_acceso() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  aviso json;
BEGIN
  IF TG_TABLE_NAME = 'sesiones' THEN
    aviso := json_build_object('tabla', 'sesiones', 'operacion', TG_OP, 'usuario_id', OLD.usuario_id, 'sesion_id', OLD.id);
  ELSIF TG_TABLE_NAME = 'usuarios' THEN
    aviso := json_build_object('tabla', 'usuarios', 'operacion', TG_OP, 'usuario_id', OLD.id);
  ELSE
    aviso := json_build_object('tabla', 'documentos', 'operacion', TG_OP, 'espacio_id', OLD.espacio_id, 'documento_id', OLD.id);
  END IF;
  PERFORM pg_notify('cuaderno_permisos', aviso::text);
  RETURN NULL;
END
$$;

-- Solo sesiones VIVAS: la retención diaria borra miles de sesiones ya terminadas y no hay nada que cortar.
CREATE TRIGGER sesiones_avisar_revocacion AFTER UPDATE OF revocada_en ON sesiones
  FOR EACH ROW WHEN (OLD.revocada_en IS NULL AND NEW.revocada_en IS NOT NULL)
  EXECUTE FUNCTION avisar_perdida_acceso();
CREATE TRIGGER sesiones_avisar_borrado AFTER DELETE ON sesiones
  FOR EACH ROW WHEN (OLD.revocada_en IS NULL AND OLD.expira_en > now())
  EXECUTE FUNCTION avisar_perdida_acceso();

-- Solo lo que puede QUITAR acceso: una cuenta que deja de estar activa, o un cambio de rol de cuenta.
-- Activar una cuenta pendiente no quita nada (y no tiene sesiones).
CREATE TRIGGER usuarios_avisar_cambio AFTER UPDATE OF estado, rol ON usuarios
  FOR EACH ROW WHEN ((OLD.estado = 'activa' AND NEW.estado <> 'activa') OR OLD.rol IS DISTINCT FROM NEW.rol)
  EXECUTE FUNCTION avisar_perdida_acceso();

CREATE TRIGGER documentos_avisar_borrado AFTER DELETE ON documentos
  FOR EACH ROW EXECUTE FUNCTION avisar_perdida_acceso();
