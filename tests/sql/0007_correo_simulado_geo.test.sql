-- Buzón del correo simulado y rangos IP → ubicación aproximada.

-- @test el buzón simulado acepta un correo válido
INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
VALUES ('ana@example.com', 'invitacion', 'Te invitaron a Cuaderno', 'Enlace de prueba', now() + interval '7 days');

-- @test el buzón simulado retiene como máximo 7 días
SELECT prueba.afirmar_error(
  $q$INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
     VALUES ('ana@example.com', 'invitacion', 'a', 'b', now() + interval '7 days 1 second')$q$,
  '23514', 'retención de más de 7 días');

-- @test el buzón simulado valida plantilla, destinatario y longitudes
SELECT prueba.afirmar_error(
  $q$INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
     VALUES ('ana@example.com', 'publicidad', 'a', 'b', now() + interval '1 day')$q$, '23514', 'plantilla inventada');
SELECT prueba.afirmar_error(
  $q$INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
     VALUES ('no-es-correo', 'invitacion', 'a', 'b', now() + interval '1 day')$q$, '23514', 'destinatario inválido');
SELECT prueba.afirmar_error(
  $q$INSERT INTO correos_simulados (para, plantilla, asunto, cuerpo_texto, expira_en)
     VALUES ('ana@example.com', 'invitacion', '', 'b', now() + interval '1 day')$q$, '23514', 'asunto vacío');

-- @test rangos IP: la búsqueda encuentra la red que contiene la IP
INSERT INTO rangos_ip_geo (red, pais, region, ciudad) VALUES
  ('203.0.113.0/24', 'CO', 'Región Ficticia', 'Ciudad Ficticia'),
  ('2001:db8::/32', 'CO', NULL, NULL);
SELECT prueba.afirmar_igual(
  (SELECT ciudad FROM rangos_ip_geo WHERE red >>= '203.0.113.77'::inet), 'Ciudad Ficticia'::text, 'IPv4 encontrada');
SELECT prueba.afirmar_igual(
  (SELECT pais FROM rangos_ip_geo WHERE red >>= '2001:db8:1::1'::inet), 'CO'::text, 'IPv6 encontrada');
SELECT prueba.afirmar_igual(
  (SELECT count(*) FROM rangos_ip_geo WHERE red >>= '198.51.100.1'::inet), 0::bigint, 'IP sin rango');

-- @test rangos IP: no se solapan
INSERT INTO rangos_ip_geo (red, pais) VALUES ('203.0.113.0/24', 'CO');
SELECT prueba.afirmar_error(
  $q$INSERT INTO rangos_ip_geo (red, pais) VALUES ('203.0.0.0/16', 'PE')$q$, '23P01', 'rango que contiene otro');
SELECT prueba.afirmar_error(
  $q$INSERT INTO rangos_ip_geo (red, pais) VALUES ('203.0.113.128/25', 'PE')$q$, '23P01', 'rango contenido en otro');

-- @test rangos IP: país en ISO 3166 alfa-2
SELECT prueba.afirmar_error(
  $q$INSERT INTO rangos_ip_geo (red, pais) VALUES ('198.51.100.0/24', 'Colombia')$q$, '23514', 'país sin código ISO');
SELECT prueba.afirmar_error(
  $q$INSERT INTO rangos_ip_geo (red, pais) VALUES ('198.51.100.0/24', 'co')$q$, '23514', 'país en minúsculas');
