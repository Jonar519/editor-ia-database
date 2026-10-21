-- Compactación del log Yjs: escribe el estado y borra hasta hasta_id EN LA MISMA LLAMADA; la app ya no
-- puede borrar actualizaciones por su cuenta; nada de otros documentos; hasta_id tiene que existir.

-- @test la app compacta: escribe el estado, borra las filas hasta hasta_id y conserva las posteriores
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a1 bigint; a2 bigint; a3 bigint;
  n bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a1;
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x02') RETURNING id INTO a2;
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x03') RETURNING id INTO a3;

  SET LOCAL ROLE cuaderno_app;
  n := compactar_documento(d, a2, '\xc0ffee');
  RESET ROLE;

  PERFORM prueba.afirmar_igual(n, 2::bigint, 'borró dos filas');
  PERFORM prueba.afirmar_igual((SELECT estado_yjs FROM documentos WHERE id = d), '\xc0ffee'::bytea, 'estado escrito');
  PERFORM prueba.afirmar_igual((SELECT array_agg(id ORDER BY id) FROM actualizaciones_documento WHERE documento_id = d), ARRAY[a3], 'la posterior sigue');
END $$;

-- @test la app ya no puede borrar actualizaciones directamente (privilegio)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a;
  SET LOCAL ROLE cuaderno_app;
  PERFORM prueba.afirmar_error(format($q$DELETE FROM actualizaciones_documento WHERE id = %s$q$, a), '42501', 'DELETE por privilegio');
  RESET ROLE;
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM actualizaciones_documento WHERE id = a), 'la fila sigue');
END $$;

-- @test no toca otro documento, y un hasta_id de otro documento no compacta nada
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d1 uuid := prueba.documento(e, ana, 'Uno');
  d2 uuid := prueba.documento(e, ana, 'Dos');
  x1 bigint; x2 bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d2, ana, '\x02') RETURNING id INTO x2;
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d1, ana, '\x01') RETURNING id INTO x1;

  SET LOCAL ROLE cuaderno_app;
  -- Compactar d1 hasta su fila (id mayor que la de d2): la de d2 no se toca.
  PERFORM compactar_documento(d1, x1, '\x00');
  -- hasta_id de d2 usado para d1: error, nada cambia.
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, %s, '\x00')$q$, d1, x2), '23514', 'hasta_id de otro documento');
  RESET ROLE;

  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM actualizaciones_documento WHERE id = x2), 'la de otro documento sigue');
  PERFORM prueba.afirmar((SELECT estado_yjs IS NULL FROM documentos WHERE id = d2), 'el estado del otro documento no cambió');
END $$;

-- @test hasta_id ya compactado (otra compactación lo borró): error, para que el job vuelva a leer
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a;
  SET LOCAL ROLE cuaderno_app;
  PERFORM compactar_documento(d, a, '\x01');
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, %s, '\x02')$q$, d, a), '23514', 'segunda compactación con el mismo hasta_id');
  RESET ROLE;
  PERFORM prueba.afirmar_igual((SELECT estado_yjs FROM documentos WHERE id = d), '\x01'::bytea, 'el estado de la primera se mantiene');
END $$;

-- @test sin estado o sin hasta_id no compacta; un documento inexistente tampoco
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  a bigint;
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01') RETURNING id INTO a;
  SET LOCAL ROLE cuaderno_app;
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, %s, NULL)$q$, d, a), '23514', 'estado nulo');
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, %s, ''::bytea)$q$, d, a), '23514', 'estado vacío');
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, NULL, '\x01')$q$, d), '23514', 'sin hasta_id');
  PERFORM prueba.afirmar_error(format($q$SELECT compactar_documento(%L, %s, '\x01')$q$, gen_random_uuid(), a), 'P0002', 'documento inexistente');
  RESET ROLE;
  PERFORM prueba.afirmar(EXISTS (SELECT 1 FROM actualizaciones_documento WHERE id = a), 'nada se borró');
END $$;

-- @test borrar un documento (como la app) sigue borrando sus actualizaciones en cascada
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  INSERT INTO actualizaciones_documento (documento_id, autor_id, actualizacion) VALUES (d, ana, '\x01');
  SET LOCAL ROLE cuaderno_app;
  DELETE FROM documentos WHERE id = d;
  RESET ROLE;
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM actualizaciones_documento WHERE documento_id = d), 'cascada');
END $$;

-- @test la función solo la ejecuta la app (no PUBLIC) y tiene search_path fijo
DO $$
DECLARE
  f oid := 'compactar_documento(uuid, bigint, bytea)'::regprocedure;
BEGIN
  PERFORM prueba.afirmar(has_function_privilege('cuaderno_app', f, 'EXECUTE'), 'la app la ejecuta');
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = f AND a.grantee = 0), 'PUBLIC no');
  PERFORM prueba.afirmar((SELECT prosecdef FROM pg_proc WHERE oid = f), 'SECURITY DEFINER');
  PERFORM prueba.afirmar((SELECT 'search_path=public, pg_temp' = ANY (proconfig) FROM pg_proc WHERE oid = f), 'search_path fijo');
END $$;
