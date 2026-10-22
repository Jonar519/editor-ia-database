-- 0023: presupuesto diario del indexado automático por espacio, búsqueda por modelo con umbral y tope por
-- documento, y retención del uso diario de IA (400 días). Datos SOLO ficticios.

-- @test presupuesto por espacio: la app lo usa; contadores no negativos; se va con el espacio
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
BEGIN
  SET LOCAL ROLE cuaderno_app;
  INSERT INTO uso_ia_indexado_diario (espacio_id, dia, tokens) VALUES (e, current_date, 10);
  UPDATE uso_ia_indexado_diario SET tokens = tokens + 5 WHERE espacio_id = e;
  RESET ROLE;
  PERFORM prueba.afirmar_igual((SELECT tokens FROM uso_ia_indexado_diario WHERE espacio_id = e), 15::bigint, 'sumó');
  PERFORM prueba.afirmar_error(format($q$UPDATE uso_ia_indexado_diario SET tokens = -1 WHERE espacio_id = %L$q$, e), '23514', 'negativo');
  DELETE FROM espacios WHERE id = e;
  PERFORM prueba.afirmar(NOT EXISTS (SELECT 1 FROM uso_ia_indexado_diario WHERE espacio_id = e), 'en cascada con el espacio');
END $$;

-- @test búsqueda: solo vectores del modelo pedido
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d1 uuid := prueba.documento(e, ana, 'Uno');
  d2 uuid := prueba.documento(e, ana, 'Dos');
BEGIN
  PERFORM prueba.embedding(d1, ana, 1, 0, 'modelo-a');
  PERFORM prueba.embedding(d2, ana, 1, 0, 'modelo-b');
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(documento_id) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10, 'modelo-a', 2.0, 3)),
    ARRAY[d1], 'solo modelo-a');
END $$;

-- @test búsqueda: el umbral deja fuera lo que está lejos (distancia coseno)
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  igual uuid := prueba.documento(e, ana, 'Igual');
  cerca uuid := prueba.documento(e, ana, 'Cerca');
  lejos uuid := prueba.documento(e, ana, 'Lejos');
BEGIN
  PERFORM prueba.embedding(igual, ana, 1);                                                          -- distancia 0
  PERFORM prueba.embedding(cerca, ana, 9, 0, 'mock-1024', prueba.vector_base(1) + prueba.vector_base(2)); -- ≈ 0,29
  PERFORM prueba.embedding(lejos, ana, 3);                                                          -- distancia 1
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(documento_id ORDER BY distancia) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10, 'mock-1024', 0.5, 3)),
    ARRAY[igual, cerca], 'el lejano queda fuera, en orden de distancia');
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10, 'mock-1024', 0.0, 3)), 1::bigint, 'umbral estricto');
END $$;

-- @test búsqueda: como máximo N fragmentos por documento, los más parecidos
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  largo uuid := prueba.documento(e, ana, 'Largo');
  otro uuid := prueba.documento(e, ana, 'Otro');
BEGIN
  FOR i IN 0..4 LOOP
    PERFORM prueba.embedding(largo, ana, 1, i);
  END LOOP;
  PERFORM prueba.embedding(otro, ana, 9, 0, 'mock-1024', prueba.vector_base(1) + prueba.vector_base(2));
  PERFORM prueba.afirmar_igual(
    (SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3) WHERE documento_id = largo), 3::bigint, 'tres del largo');
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(fragmento ORDER BY fragmento) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3) WHERE documento_id = largo),
    ARRAY[0, 1, 2], 'a igual distancia, los primeros fragmentos');
  PERFORM prueba.afirmar(
    EXISTS (SELECT 1 FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 4, 'mock-1024', 2.0, 3) WHERE documento_id = otro), 'el otro documento aparece');
END $$;

-- @test búsqueda: sigue aislada por espacio y por el acceso de HOY de quien busca
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  intrusa uuid := prueba.cuenta_activa('intrusa@example.com');
  ex uuid := prueba.cuenta_activa('ex@example.com');
  e1 uuid := prueba.espacio(ana, 'Uno');
  e2 uuid := prueba.espacio(ana, 'Dos');
  d1 uuid := prueba.documento(e1, ana);
  d2 uuid := prueba.documento(e2, ana);
BEGIN
  PERFORM prueba.miembro(e1, ex, 'lector');
  PERFORM prueba.embedding(d1, ana, 1);
  PERFORM prueba.embedding(d2, ana, 1);
  PERFORM prueba.afirmar_igual((SELECT array_agg(documento_id) FROM buscar_fragmentos(ana, e1, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3)), ARRAY[d1], 'solo el espacio pedido');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(intrusa, e1, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3)), 0::bigint, 'intrusa sin resultados');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(ex, e1, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3)), 1::bigint, 'miembro ve');
  DELETE FROM miembros_espacio WHERE espacio_id = e1 AND usuario_id = ex;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(ex, e1, prueba.vector_base(1), 10, 'mock-1024', 2.0, 3)), 0::bigint, 'al salir deja de ver');
END $$;

-- @test búsqueda: el límite queda entre 1 y 50
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d uuid;
BEGIN
  FOR i IN 1..60 LOOP
    d := prueba.documento(e, ana, 'Doc ' || i);
    PERFORM prueba.embedding(d, ana, 1);
  END LOOP;
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 1000, 'mock-1024', 2.0, 3)), 50::bigint, 'tope 50');
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 0, 'mock-1024', 2.0, 3)), 1::bigint, 'mínimo 1');
END $$;

-- @test la búsqueda de 4 parámetros (0011) sigue funcionando para el backend anterior
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  d uuid := prueba.documento(e, ana);
BEGIN
  PERFORM prueba.embedding(d, ana, 1);
  PERFORM prueba.afirmar_igual((SELECT count(*) FROM buscar_fragmentos(ana, e, prueba.vector_base(1), 10)), 1::bigint, 'compatibilidad');
END $$;

-- @test retención: borra el uso de IA de hace más de 400 días y conserva el de 400 o menos
DO $$
DECLARE
  ana uuid := prueba.cuenta_activa('ana@example.com');
  e uuid := prueba.espacio(ana);
  hoy date := (now() AT TIME ZONE 'UTC')::date;
  r record;
BEGIN
  INSERT INTO uso_ia_diario (usuario_id, dia, peticiones) VALUES (ana, hoy - 401, 1), (ana, hoy - 400, 1), (ana, hoy, 1);
  INSERT INTO uso_ia_indexado_diario (espacio_id, dia, tokens) VALUES (e, hoy - 401, 1), (e, hoy - 400, 1), (e, hoy, 1);
  SET LOCAL ROLE cuaderno_app;
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'uso_ia_diario';
  PERFORM prueba.afirmar_igual(r.borradas, 1::bigint, 'uso por cuenta: uno');
  SELECT borradas INTO r FROM purgar_retencion() WHERE tabla = 'uso_ia_indexado_diario';
  RESET ROLE;
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(hoy - dia ORDER BY dia) FROM uso_ia_diario WHERE usuario_id = ana), ARRAY[400, 0], 'quedan 400 y hoy (cuenta)');
  PERFORM prueba.afirmar_igual(
    (SELECT array_agg(hoy - dia ORDER BY dia) FROM uso_ia_indexado_diario WHERE espacio_id = e), ARRAY[400, 0], 'quedan 400 y hoy (espacio)');
END $$;

-- @test retención: purgar_retencion sigue devolviendo todos los pasos, en orden
SELECT prueba.afirmar_igual(
  (SELECT array_agg(tabla) FROM purgar_retencion()),
  ARRAY['sesiones', 'tokens_recuperacion', 'cambios_correo', 'correos_simulados', 'eventos_seguridad', 'cuentas_pendientes', 'uso_ia_diario', 'uso_ia_indexado_diario'],
  'pasos de la retención');
