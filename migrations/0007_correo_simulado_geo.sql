-- 0007 · Buzón del proveedor de correo simulado y tabla local de rangos IP → ubicación aproximada.
--
-- correos_simulados: lo que el EmailProvider "mock" habría enviado. Solo existe para desarrollo y demo
-- (producción se niega a arrancar con el proveedor mock). Retención máxima de 7 días, fijada por la base.
-- rangos_ip_geo: geolocalización aproximada SIN servicios externos. Los rangos no se solapan, así que
-- cada IP tiene como mucho una ubicación.

CREATE TABLE correos_simulados (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  para         citext      NOT NULL,
  plantilla    text        NOT NULL,
  asunto       text        NOT NULL,
  cuerpo_texto text        NOT NULL,
  creado_en    timestamptz NOT NULL DEFAULT now(),
  expira_en    timestamptz NOT NULL,

  CONSTRAINT correos_simulados_para_formato CHECK (para ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(para) <= 254),
  CONSTRAINT correos_simulados_plantilla_valida CHECK (plantilla IN ('invitacion', 'recuperacion', 'cambio_correo', 'aviso_cambio_correo', 'aviso_cambio_contrasena')),
  CONSTRAINT correos_simulados_asunto_longitud CHECK (length(asunto) BETWEEN 1 AND 200),
  CONSTRAINT correos_simulados_cuerpo_longitud CHECK (length(cuerpo_texto) BETWEEN 1 AND 20000),
  CONSTRAINT correos_simulados_retencion_7d CHECK (expira_en > creado_en AND expira_en <= creado_en + interval '7 days')
);

CREATE INDEX correos_simulados_por_destinatario ON correos_simulados (para, creado_en DESC);
CREATE INDEX correos_simulados_expira_en ON correos_simulados (expira_en);

CREATE TRIGGER correos_simulados_fijar_creado_en BEFORE INSERT ON correos_simulados
  FOR EACH ROW EXECUTE FUNCTION fijar_creado_en();
CREATE TRIGGER correos_simulados_plazos_solo_se_acortan BEFORE UPDATE ON correos_simulados
  FOR EACH ROW EXECUTE FUNCTION plazos_solo_se_acortan();

CREATE TABLE rangos_ip_geo (
  red    cidr PRIMARY KEY,
  pais   text NOT NULL,
  region text,
  ciudad text,

  CONSTRAINT rangos_ip_geo_pais_iso CHECK (pais ~ '^[A-Z]{2}$'),
  CONSTRAINT rangos_ip_geo_textos_cortos CHECK (length(coalesce(region, '')) <= 80 AND length(coalesce(ciudad, '')) <= 80),
  CONSTRAINT rangos_ip_geo_sin_solapamiento EXCLUDE USING gist (red inet_ops WITH &&)
);
