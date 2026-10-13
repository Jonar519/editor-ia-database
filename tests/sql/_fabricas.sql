-- Fábricas de datos de prueba. Solo datos ficticios (@example.com). Siguen el flujo real:
-- toda cuenta nace pendiente; activarla exige borrar su invitación; un admin se activa con MFA.

CREATE OR REPLACE FUNCTION prueba.bytes(n int) RETURNS bytea LANGUAGE sql VOLATILE AS $$
  SELECT substring(sha256(gen_random_uuid()::text::bytea) FROM 1 FOR n)
$$;

CREATE OR REPLACE FUNCTION prueba.hash_scrypt() RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '$scrypt$ln=15,r=8,p=1$c2FscHJ1ZWJh$aGFzaHBydWViYWZpY3RpY2lv'
$$;

CREATE OR REPLACE FUNCTION prueba.cuenta_pendiente(p_correo text, p_rol text DEFAULT 'editor', p_invitada_por uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO usuarios (correo, nombre, rol, invitada_por)
  VALUES (p_correo, 'Persona Ficticia', p_rol, p_invitada_por)
  RETURNING id
$$;

CREATE OR REPLACE FUNCTION prueba.invitacion(p_usuario uuid) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO invitaciones (usuario_id, token_hash, expira_en)
  VALUES (p_usuario, prueba.bytes(32), now() + interval '72 hours')
  RETURNING id
$$;

CREATE OR REPLACE FUNCTION prueba.activar(p_usuario uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM invitaciones WHERE usuario_id = p_usuario;
  UPDATE usuarios SET estado = 'activa', hash_contrasena = prueba.hash_scrypt(), activada_en = now()
  WHERE id = p_usuario;
  IF (SELECT rol FROM usuarios WHERE id = p_usuario) = 'admin' THEN
    INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta, confirmado_en)
    VALUES (p_usuario, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now());
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION prueba.cuenta_activa(p_correo text, p_rol text DEFAULT 'editor') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  uid uuid := prueba.cuenta_pendiente(p_correo, p_rol);
BEGIN
  PERFORM prueba.activar(uid);
  RETURN uid;
END
$$;

CREATE OR REPLACE FUNCTION prueba.sesion(p_usuario uuid) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO sesiones (usuario_id, expira_en) VALUES (p_usuario, now() + interval '1 day') RETURNING id
$$;

CREATE OR REPLACE FUNCTION prueba.mfa(p_usuario uuid) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mfa_totp (usuario_id, secreto_cifrado, iv, etiqueta, confirmado_en)
  VALUES (p_usuario, prueba.bytes(20), prueba.bytes(12), prueba.bytes(16), now())
$$;

-- ─── Dominio ─────────────────────────────────────────────────────────────────────

-- Espacio con su propietario (misma transacción, como en el flujo real).
CREATE OR REPLACE FUNCTION prueba.espacio(p_propietario uuid, p_nombre text DEFAULT 'Espacio Ficticio')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  eid uuid;
BEGIN
  INSERT INTO espacios (nombre, creado_por) VALUES (p_nombre, p_propietario) RETURNING id INTO eid;
  INSERT INTO miembros_espacio (espacio_id, usuario_id, rol) VALUES (eid, p_propietario, 'propietario');
  RETURN eid;
END
$$;

CREATE OR REPLACE FUNCTION prueba.miembro(p_espacio uuid, p_usuario uuid, p_rol text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO miembros_espacio (espacio_id, usuario_id, rol) VALUES (p_espacio, p_usuario, p_rol)
$$;

-- Documento con su propietario (quien lo crea).
CREATE OR REPLACE FUNCTION prueba.documento(p_espacio uuid, p_creador uuid, p_titulo text DEFAULT 'Documento Ficticio')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  did uuid;
BEGIN
  INSERT INTO documentos (espacio_id, titulo, creado_por) VALUES (p_espacio, p_titulo, p_creador) RETURNING id INTO did;
  INSERT INTO permisos_documento (documento_id, espacio_id, usuario_id, rol) VALUES (did, p_espacio, p_creador, 'propietario');
  RETURN did;
END
$$;

CREATE OR REPLACE FUNCTION prueba.permiso(p_documento uuid, p_usuario uuid, p_rol text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO permisos_documento (documento_id, espacio_id, usuario_id, rol)
  SELECT id, espacio_id, p_usuario, p_rol FROM documentos WHERE id = p_documento
$$;

-- Vector de 1024 dimensiones que apunta en la dirección k (vectores base: ortogonales entre sí).
CREATE OR REPLACE FUNCTION prueba.vector_base(k integer) RETURNS vector LANGUAGE sql IMMUTABLE AS $$
  SELECT (SELECT array_agg(CASE WHEN i = k THEN 1.0::float8 ELSE 0.0::float8 END ORDER BY i)
          FROM generate_series(1, 1024) AS i)::vector
$$;

CREATE OR REPLACE FUNCTION prueba.embedding(p_documento uuid, p_indexa uuid, p_k integer, p_fragmento integer DEFAULT 0)
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO embeddings (documento_id, espacio_id, fragmento, texto, hash_texto, modelo, embedding, indexado_por)
  SELECT id, espacio_id, p_fragmento, 'Fragmento ficticio ' || p_k, sha256(p_k::text::bytea), 'mock-1024',
         prueba.vector_base(p_k), p_indexa
  FROM documentos WHERE id = p_documento
  RETURNING id
$$;

CREATE OR REPLACE FUNCTION prueba.version(p_documento uuid, p_autor uuid, p_texto text DEFAULT 'texto')
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO versiones (documento_id, motivo, creado_por, estado_yjs, contenido_texto)
  VALUES (p_documento, CASE WHEN p_autor IS NULL THEN 'automatica' ELSE 'manual' END, p_autor,
          convert_to(p_texto, 'UTF8'), p_texto)
  RETURNING id
$$;
