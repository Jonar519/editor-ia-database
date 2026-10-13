-- 0013 · Restricciones equivalentes que Prisma (cliente del backend) puede introspectar.
--
-- Motivo: los índices ÚNICOS PARCIALES sobre columnas que forman parte de una clave foránea hacen que
-- `prisma db pull` deduzca relaciones uno a uno que no existen. Unas producen un esquema inválido
-- (P1012) y otras, peor, un modelo silenciosamente falso (por ejemplo, "un espacio tiene un solo miembro").
--
-- Solución: cada índice único parcial pasa a ser una restricción de EXCLUSIÓN con igualdad sobre la misma
-- columna y la misma condición. Postgres hace cumplir EXACTAMENTE la misma regla (no puede haber dos filas
-- con el mismo valor que cumplan la condición; error 23P01 en vez de 23505), pero Prisma no la usa para
-- deducir relaciones. Los nombres se conservan.
--
-- Las dos relaciones que sí son uno a uno (invitaciones y mfa_totp: usuario_id ya es único) reciben el
-- UNIQUE (usuario_id, estado_usuario) que Prisma exige sobre las columnas de su clave foránea compuesta.
-- Es redundante con la unicidad de usuario_id y no cambia ninguna regla.

DROP INDEX tokens_refresco_uno_vigente_por_sesion;
ALTER TABLE tokens_refresco ADD CONSTRAINT tokens_refresco_uno_vigente_por_sesion
  EXCLUDE USING btree (sesion_id WITH =) WHERE (usado_en IS NULL);

DROP INDEX tokens_recuperacion_uno_vigente_por_cuenta;
ALTER TABLE tokens_recuperacion ADD CONSTRAINT tokens_recuperacion_uno_vigente_por_cuenta
  EXCLUDE USING btree (usuario_id WITH =) WHERE (usado_en IS NULL);

DROP INDEX cambios_correo_uno_pendiente_por_cuenta;
ALTER TABLE cambios_correo ADD CONSTRAINT cambios_correo_uno_pendiente_por_cuenta
  EXCLUDE USING btree (usuario_id WITH =) WHERE (confirmado_en IS NULL);

DROP INDEX permisos_documento_un_propietario;
ALTER TABLE permisos_documento ADD CONSTRAINT permisos_documento_un_propietario
  EXCLUDE USING btree (documento_id WITH =) WHERE (rol = 'propietario');

DROP INDEX miembros_espacio_un_propietario;
ALTER TABLE miembros_espacio ADD CONSTRAINT miembros_espacio_un_propietario
  EXCLUDE USING btree (espacio_id WITH =) WHERE (rol = 'propietario');

ALTER TABLE invitaciones ADD CONSTRAINT invitaciones_usuario_estado_unico UNIQUE (usuario_id, estado_usuario);
ALTER TABLE mfa_totp ADD CONSTRAINT mfa_totp_usuario_estado_unico UNIQUE (usuario_id, estado_usuario);
