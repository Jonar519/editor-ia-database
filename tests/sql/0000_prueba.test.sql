-- Autopruebas de las funciones de aserción: si estas mienten, todas las demás pruebas mienten.

-- @test afirmar acepta verdadero
SELECT prueba.afirmar(true, 'verdadero');

-- @test afirmar rechaza falso y nulo
SELECT prueba.afirmar_error($$SELECT prueba.afirmar(false, 'x')$$, 'PT001', 'falso debe fallar');
SELECT prueba.afirmar_error($$SELECT prueba.afirmar(NULL, 'x')$$, 'PT001', 'nulo debe fallar');

-- @test afirmar_igual compara con IS DISTINCT FROM
SELECT prueba.afirmar_igual(1, 1, 'iguales');
SELECT prueba.afirmar_igual(NULL::int, NULL::int, 'dos nulos son iguales');
SELECT prueba.afirmar_error($$SELECT prueba.afirmar_igual(1, 2, 'x')$$, 'PT001', 'distintos deben fallar');
SELECT prueba.afirmar_error($$SELECT prueba.afirmar_igual(1, NULL::int, 'x')$$, 'PT001', 'valor contra nulo debe fallar');

-- @test afirmar_error acepta el SQLSTATE exacto
SELECT prueba.afirmar_error('SELECT 1/0', '22012', 'división por cero');

-- @test afirmar_error falla si la sentencia funciona
SELECT prueba.afirmar_error($$SELECT prueba.afirmar_error('SELECT 1', '22012', 'x')$$, 'PT001', 'sentencia exitosa');

-- @test afirmar_error falla con un SQLSTATE distinto
SELECT prueba.afirmar_error($$SELECT prueba.afirmar_error('SELECT 1/0', '23505', 'x')$$, 'PT001', 'sqlstate distinto');

-- @test afirmar_error revierte los efectos de la sentencia fallida
CREATE TEMP TABLE t_efectos (n int);
SELECT prueba.afirmar_error($$INSERT INTO t_efectos VALUES (1); SELECT 1/0$$, '22012', 'inserta y falla');
SELECT prueba.afirmar_igual((SELECT count(*) FROM t_efectos), 0::bigint, 'el insert quedó revertido');
