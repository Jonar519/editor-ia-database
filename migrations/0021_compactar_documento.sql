-- 0021 · Compactación del log Yjs (ADR 0003 del backend, bloque K1).
--
-- actualizaciones_documento es un log de solo inserción: cada cambio aceptado del editor colaborativo es
-- una fila. Sin compactar crece sin límite y abrir un documento obliga a aplicar miles de filas. Compactar
-- es: escribir en documentos.estado_yjs el estado que ya incluye esas filas, y borrarlas.
--
-- La base no puede leer el formato de Yjs, así que no puede comprobar que el estado nuevo contenga las
-- filas que se borran. Eso lo comprueba el backend antes de llamar (y sus pruebas). Lo que SÍ garantiza la
-- base:
--   - el backend ya NO puede borrar actualizaciones directamente (REVOKE DELETE): la única forma es
--     compactar_documento(), que en la MISMA llamada escribe el estado y borra;
--   - solo se borran filas de ESE documento con id <= hasta_id (las que llegaron durante la compactación
--     se quedan para la siguiente);
--   - hasta_id tiene que ser una actualización existente de ese documento (si otra compactación ya la
--     borró, falla y el job vuelve a leer);
--   - el documento se bloquea con FOR NO KEY UPDATE: dos compactaciones del mismo documento se esperan,
--     pero las inserciones de cambios nuevos (que toman KEY SHARE por la clave foránea) no se bloquean.
--
-- Nota: el trigger documentos_fijar_actualizado_en (0009) actualiza actualizado_en en cada UPDATE de la
-- fila, así que compactar también lo mueve. actualizado_en es "último cambio de la fila del documento"
-- (título o estado compactado), no "última edición del texto".
--
-- Borrar un documento sigue borrando sus actualizaciones: la cascada de la clave foránea la ejecuta el
-- dueño de la tabla, no cuaderno_app (lo comprueba una prueba).

CREATE FUNCTION compactar_documento(p_documento uuid, p_hasta bigint, p_estado bytea) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
-- SECURITY DEFINER corre con los privilegios del dueño: el search_path fijo evita que alguien haga que
-- resuelva "documentos" o "actualizaciones_documento" a una tabla suya.
SET search_path = public, pg_temp
AS $$
DECLARE
  n bigint;
BEGIN
  IF p_estado IS NULL OR octet_length(p_estado) = 0 THEN
    RAISE EXCEPTION 'La compactación necesita el estado nuevo del documento' USING ERRCODE = 'check_violation';
  END IF;
  IF p_hasta IS NULL THEN
    RAISE EXCEPTION 'La compactación necesita hasta qué actualización llega' USING ERRCODE = 'check_violation';
  END IF;

  PERFORM 1 FROM documentos WHERE id = p_documento FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El documento no existe' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM actualizaciones_documento WHERE documento_id = p_documento AND id = p_hasta) THEN
    RAISE EXCEPTION 'hasta_id no es una actualización vigente de este documento' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE documentos SET estado_yjs = p_estado WHERE id = p_documento;
  DELETE FROM actualizaciones_documento WHERE documento_id = p_documento AND id <= p_hasta;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$$;

-- Solo la app la ejecuta (las funciones nuevas son ejecutables por PUBLIC si no se dice otra cosa).
REVOKE ALL ON FUNCTION compactar_documento(uuid, bigint, bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION compactar_documento(uuid, bigint, bytea) TO cuaderno_app;

-- El backend ya no borra actualizaciones por su cuenta.
REVOKE DELETE ON actualizaciones_documento FROM cuaderno_app;
