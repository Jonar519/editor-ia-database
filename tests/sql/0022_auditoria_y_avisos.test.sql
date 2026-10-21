-- Auditoría de permisos (0022): a quién (objetivo_id) y sobre qué (recurso_id, un id); la anonimización
-- alcanza a objetivo_id pero nunca reescribe recurso_id; una lápida deja de ser objetivo identificable.

-- @test registra los tipos nuevos con objetivo y recurso (como la app)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  SET LOCAL ROLE cuaderno_app;
  INSERT INTO eventos_seguridad (tipo, usuario_id, objetivo_id, recurso_id)
  VALUES ('miembro_agregado', ana, bruno, e), ('documento_eliminado', ana, NULL, gen_random_uuid());
  RESET ROLE;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE objetivo_id = bruno AND recurso_id = e), 1::bigint, 'con objetivo y recurso');
  PERFORM prueba.afirmar_error($q$INSERT INTO eventos_seguridad (tipo) VALUES ('espacio_creado')$q$, '23514', 'las creaciones no se registran');
END $$;

-- @test se puede anonimizar objetivo_id, pero recurso_id no se reescribe
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  ev bigint;
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id, objetivo_id, recurso_id) VALUES ('permiso_documento_dado', ana, bruno, gen_random_uuid()) RETURNING id INTO ev;
  SET LOCAL ROLE cuaderno_app;
  UPDATE eventos_seguridad SET objetivo_id = NULL WHERE id = ev;
  RESET ROLE;
  PERFORM prueba.afirmar((SELECT objetivo_id IS NULL FROM eventos_seguridad WHERE id = ev), 'objetivo anonimizado');
  PERFORM prueba.afirmar_error(format($q$UPDATE eventos_seguridad SET recurso_id = gen_random_uuid() WHERE id = %s$q$, ev), '42501', 'recurso_id inmutable');
END $$;

-- @test eliminar_cuenta() deja de identificar a la cuenta también como objetivo
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
BEGIN
  INSERT INTO eventos_seguridad (tipo, usuario_id, objetivo_id, recurso_id) VALUES ('miembro_quitado', ana, bruno, gen_random_uuid());
  SET LOCAL ROLE cuaderno_app;
  PERFORM eliminar_cuenta(bruno);
  RESET ROLE;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE objetivo_id = bruno), 0::bigint, 'sin rastro como objetivo');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM eventos_seguridad WHERE tipo = 'miembro_quitado' AND usuario_id = ana AND objetivo_id IS NULL), 1::bigint, 'el evento sigue, sin objetivo');
END $$;
