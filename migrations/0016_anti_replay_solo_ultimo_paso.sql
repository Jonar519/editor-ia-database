-- 0016 · El anti-replay de mfa_totp solo se evalúa cuando el UPDATE toca ultimo_paso.
--
-- Defecto de 0006 encontrado en el bloque F: el trigger se disparaba en CUALQUIER UPDATE de la fila.
-- Tras aceptar el primer código (ultimo_paso con valor), confirmar el MFA (SET confirmado_en = now(),
-- sin tocar ultimo_paso) llegaba con NEW.ultimo_paso = OLD.ultimo_paso y se rechazaba como "replay".
--
-- Con UPDATE OF ultimo_paso el trigger corre solo si la sentencia incluye esa columna en el SET:
--   - SET ultimo_paso = <igual o menor>  → sigue rechazado (anti-replay intacto);
--   - SET confirmado_en = now()          → ya no choca.
-- La función no cambia.

DROP TRIGGER mfa_totp_anti_replay ON mfa_totp;
CREATE TRIGGER mfa_totp_anti_replay BEFORE UPDATE OF ultimo_paso ON mfa_totp
  FOR EACH ROW EXECUTE FUNCTION mfa_totp_anti_replay();
