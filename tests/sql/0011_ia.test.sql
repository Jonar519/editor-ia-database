-- Embeddings: aislamiento entre espacios y entre cuentas garantizado por la base.

-- @test quien tiene acceso indexa su documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  PERFORM prueba.embedding(d, ana, 1);
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM embeddings), 1::bigint, 'indexado');
END $$;

-- @test AISLAMIENTO trigger: nadie indexa un documento al que no tiene acceso
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  intrusa uuid := prueba.cuenta_activa('intrusa@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
BEGIN
  PERFORM prueba.espacio(intrusa, 'De la intrusa');
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.embedding(%L, %L, 1)$q$, d, intrusa), '42501', 'indexa contenido ajeno');
END $$;

-- @test AISLAMIENTO trigger: tampoco al actualizar un fragmento existente
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  intrusa uuid := prueba.cuenta_activa('intrusa@example.com');
  d uuid := prueba.documento(prueba.espacio(ana), ana);
  f uuid;
BEGIN
  f := prueba.embedding(d, ana, 1);
  PERFORM prueba.afirmar_error(format($q$UPDATE embeddings SET indexado_por = %L WHERE id = %L$q$, intrusa, f), '42501', 'reasignar a una intrusa');
END $$;

-- @test AISLAMIENTO FK compuesta: un fragmento no puede declarar otro espacio que el de su documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e1 uuid := prueba.espacio(ana, 'Uno');
  e2 uuid := prueba.espacio(ana, 'Dos');
  d uuid := prueba.documento(e1, ana);
BEGIN
  -- Ana tiene acceso al documento y es miembro de ambos espacios: aun así no puede etiquetarlo en el 2.
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO embeddings (documento_id, espacio_id, fragmento, texto, hash_texto, modelo, embedding, indexado_por)
       VALUES (%L, %L, 0, 'x', sha256('x'), 'mock-1024', prueba.vector_base(1), %L)$q$, d, e2, ana),
    '23503', 'fragmento en el espacio equivocado');
END $$;

-- @test búsqueda: solo devuelve fragmentos del espacio pedido
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e1 uuid := prueba.espacio(ana, 'Uno');
  e2 uuid := prueba.espacio(ana, 'Dos');
  d1 uuid := prueba.documento(e1, ana);
  d2 uuid := prueba.documento(e2, ana);
BEGIN
  PERFORM prueba.embedding(d1, ana, 1);
  PERFORM prueba.embedding(d2, ana, 1);
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(documento_id) FROM buscar_fragmentos(ana, e1, prueba.vector_base(1), 10)),
    ARRAY[d1], 'solo el espacio 1');
END $$;

-- @test búsqueda: no devuelve nada de un espacio donde no se es miembro
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  intrusa uuid := prueba.cuenta_activa('intrusa@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.embedding(d, ana, 1);
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(intrusa, e, prueba.vector_base(1), 10)), 0::bigint, 'intrusa sin resultados');
END $$;

-- @test búsqueda: perder el acceso oculta los fragmentos ya indexados
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  bruno uuid := prueba.cuenta_activa('bruno@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.miembro(e, bruno, 'editor');
  PERFORM prueba.embedding(d, bruno, 1);
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(bruno, e, prueba.vector_base(1), 10)), 1::bigint, 'con acceso');
  DELETE FROM miembros_espacio WHERE espacio_id = e AND usuario_id = bruno;
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(bruno, e, prueba.vector_base(1), 10)), 0::bigint, 'sin acceso');
END $$;

-- @test búsqueda: ordena por similitud y limita entre 1 y 50
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.embedding(d, ana, 1, 0);
  PERFORM prueba.embedding(d, ana, 2, 1);
  PERFORM prueba.afirmar_igual(
    (SELECT fragmento FROM buscar_fragmentos(ana, e, prueba.vector_base(2), 1)), 1, 'el más parecido primero');
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(2), 0)), 1::bigint, 'límite mínimo 1');
END $$;

-- @test embeddings: dimensión fija de 1024 y fragmento único por documento
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.afirmar_error(format(
    $q$INSERT INTO embeddings (documento_id, espacio_id, fragmento, texto, hash_texto, modelo, embedding, indexado_por)
       VALUES (%L, %L, 0, 'x', sha256('x'), 'mock', '[1,2,3]', %L)$q$, d, e, ana),
    '22000', 'dimensión 3');
  PERFORM prueba.embedding(d, ana, 1, 0);
  PERFORM prueba.afirmar_error(format($q$SELECT prueba.embedding(%L, %L, 2, 0)$q$, d, ana), '23505', 'fragmento repetido');
END $$;

-- @test uso diario de IA: contadores no negativos
DO $$
DECLARE ana uuid := prueba.cuenta_activa('ana@example.com');
BEGIN
  INSERT INTO uso_ia_diario (usuario_id, dia, peticiones, tokens_entrada, tokens_salida) VALUES (ana, '2026-01-01', 1, 10, 5);
  PERFORM prueba.afirmar_error(format(
    $q$UPDATE uso_ia_diario SET tokens_salida = -1 WHERE usuario_id = %L$q$, ana), '23514', 'tokens negativos');
END $$;
