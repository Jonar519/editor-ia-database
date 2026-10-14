-- El anti-replay solo mira ultimo_paso: confirmar el MFA después del primer código no choca.

-- @test confirmar después de aceptar el primer código (flujo del MFA opcional)
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta) VALUES (uid, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16));
  UPDATE mfa_totp SET ultimo_paso = 100 WHERE usuario_id = uid;
  UPDATE mfa_totp SET confirmado_en = now() WHERE usuario_id = uid;
  PERFORM prueba.afirmar((SELECT confirmado_en IS NOT NULL AND ultimo_paso = 100 FROM mfa_totp WHERE usuario_id = uid), 'confirmado');
END $$;

-- @test el anti-replay sigue intacto cuando el UPDATE toca ultimo_paso
DO $$
DECLARE uid uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  PERFORM prueba.mfa(uid);
  UPDATE mfa_totp SET ultimo_paso = 100 WHERE usuario_id = uid;
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET ultimo_paso = 100 WHERE usuario_id = %L$q$, uid), '23514', 'mismo paso');
  PERFORM prueba.afirmar_error(format($q$UPDATE mfa_totp SET ultimo_paso = 99, confirmado_en = confirmado_en WHERE usuario_id = %L$q$, uid), '23514', 'paso anterior junto con otra columna');
END $$;
