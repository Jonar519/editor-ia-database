-- 0023 · IA, bloque P2: presupuesto diario del indexado automático por espacio, búsqueda por modelo
-- (con umbral y tope por documento) y retención del uso diario de IA. Decisiones escritas de P2.
--
-- 1. uso_ia_indexado_diario: tokens del indexado AUTOMÁTICO (al dejar de editar) por espacio y día UTC.
--    Va aparte de uso_ia_diario a propósito: el indexado automático no gasta la cuota de la persona que
--    editó. El tope (200 000 por día) lo aplica el backend con un UPDATE condicional, como el de
--    uso_ia_diario; la base garantiza contadores no negativos. Se va en cascada con el espacio.
--
-- 2. buscar_fragmentos(usuario, espacio, consulta, limite, modelo, distancia_maxima, por_documento):
--    lo mismo que la de 0011 (espacio Y acceso de HOY de quien busca) y además:
--      - solo vectores del MODELO pedido (los de modelos distintos no se comparan);
--      - solo los que están a una distancia coseno de hasta distancia_maxima (umbral de similitud);
--      - como máximo por_documento fragmentos de cada documento (un documento largo no tapa al resto).
--    La versión de 4 parámetros de 0011 se conserva: la usa el backend hasta P2 (el orden de despliegue
--    es base primero). Se quita en una migración posterior, cuando ningún backend la llame.
--
-- 3. Retención: purgar_retencion() borra además uso_ia_diario y uso_ia_indexado_diario de hace más de
--    400 días. Se reemplaza ENTERA (la de 0020 + los pasos nuevos al final): las mutaciones del cuerpo
--    de la función apuntan a esta migración, que es la definición vigente.

CREATE TABLE uso_ia_indexado_diario (
  espacio_id uuid   NOT NULL REFERENCES espacios (id) ON DELETE CASCADE,
  dia        date   NOT NULL,
  tokens     bigint NOT NULL DEFAULT 0,

  PRIMARY KEY (espacio_id, dia),
  CONSTRAINT uso_ia_indexado_tokens_no_negativos CHECK (tokens >= 0)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON uso_ia_indexado_diario TO cuaderno_app;

CREATE FUNCTION buscar_fragmentos(
  p_usuario uuid,
  p_espacio uuid,
  p_consulta vector(1024),
  p_limite integer,
  p_modelo text,
  p_distancia_maxima double precision,
  p_por_documento integer
)
RETURNS TABLE (documento_id uuid, fragmento integer, texto text, distancia double precision)
LANGUAGE sql STABLE AS $$
  SELECT x.documento_id, x.fragmento, x.texto, x.distancia
  FROM (
    SELECT e.documento_id, e.fragmento, e.texto, e.embedding <=> p_consulta AS distancia,
           row_number() OVER (PARTITION BY e.documento_id ORDER BY e.embedding <=> p_consulta, e.fragmento) AS orden
    FROM embeddings e
    WHERE e.espacio_id = p_espacio
      AND e.modelo = p_modelo
      AND rol_efectivo_documento(p_usuario, e.documento_id) IS NOT NULL
  ) AS x
  WHERE x.distancia <= p_distancia_maxima
    AND x.orden <= greatest(p_por_documento, 1)
  ORDER BY x.distancia, x.documento_id, x.fragmento
  LIMIT least(greatest(p_limite, 1), 50)
$$;

CREATE FUNCTION retencion_uso_ia() RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT interval '400 days'
$$;

CREATE OR REPLACE FUNCTION purgar_retencion() RETURNS TABLE (tabla text, borradas bigint) LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
BEGIN
  -- Terminada = revocada o vencida; cuenta lo que haya ocurrido primero.
  DELETE FROM sesiones
  WHERE least(coalesce(revocada_en, 'infinity'::timestamptz), expira_en) < now() - retencion_sesiones_terminadas();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'sesiones'; borradas := n; RETURN NEXT;

  DELETE FROM tokens_recuperacion WHERE expira_en < now() - retencion_tokens_vencidos();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'tokens_recuperacion'; borradas := n; RETURN NEXT;

  DELETE FROM cambios_correo WHERE expira_en < now() - retencion_tokens_vencidos();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'cambios_correo'; borradas := n; RETURN NEXT;

  DELETE FROM correos_simulados WHERE expira_en <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'correos_simulados'; borradas := n; RETURN NEXT;

  DELETE FROM eventos_seguridad WHERE creado_en < now() - retencion_eventos_seguridad();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'eventos_seguridad'; borradas := n; RETURN NEXT;

  -- Cuentas pendientes sin una invitación vigente o vencida hace poco. "Hace poco" = menos de 7 días.
  -- creado_en evita tocar una cuenta recién creada cuya invitación aún no se inserta (misma transacción).
  DELETE FROM usuarios u
  WHERE u.estado = 'pendiente'
    AND u.creado_en < now() - retencion_invitaciones_vencidas()
    AND NOT EXISTS (
      SELECT 1 FROM invitaciones i
      WHERE i.usuario_id = u.id AND i.expira_en >= now() - retencion_invitaciones_vencidas()
    );
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'cuentas_pendientes'; borradas := n; RETURN NEXT;

  -- Uso diario de IA (por cuenta y por espacio): más de 400 días. El día es UTC, como al registrarlo.
  DELETE FROM uso_ia_diario WHERE dia < (now() AT TIME ZONE 'UTC')::date - retencion_uso_ia();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'uso_ia_diario'; borradas := n; RETURN NEXT;

  DELETE FROM uso_ia_indexado_diario WHERE dia < (now() AT TIME ZONE 'UTC')::date - retencion_uso_ia();
  GET DIAGNOSTICS n = ROW_COUNT;
  tabla := 'uso_ia_indexado_diario'; borradas := n; RETURN NEXT;
END
$$;
