-- Autopruebas de las funciones de aserción: si estas mienten, todas las demás pruebas mienten.
-- Los casos de "debe fallar" NO usan prueba.afirmar_error para comprobarse: capturan PT001
-- directamente en un bloque DO, para que una función rota no pueda taparse a sí misma.

-- @test afirmar acepta verdadero
SELECT prueba.afirmar(true, 'verdadero');

-- @test afirmar rechaza falso
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar(false, 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar(false) no falló';
END $$;

-- @test afirmar rechaza nulo
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar(NULL, 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar(NULL) no falló';
END $$;

-- @test afirmar_igual acepta iguales y dos nulos
SELECT prueba.afirmar_igual(1, 1, 'iguales');
SELECT prueba.afirmar_igual(NULL::int, NULL::int, 'dos nulos son iguales');

-- @test afirmar_igual rechaza distintos
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar_igual(1, 2, 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar_igual(1, 2) no falló';
END $$;

-- @test afirmar_igual rechaza valor contra nulo
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar_igual(1, NULL::int, 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar_igual(1, NULL) no falló';
END $$;

-- @test afirmar_error acepta el SQLSTATE exacto
SELECT prueba.afirmar_error('SELECT 1/0', '22012', 'división por cero');

-- @test afirmar_error falla si la sentencia funciona
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar_error('SELECT 1', '22012', 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar_error no falló con una sentencia exitosa';
END $$;

-- @test afirmar_error falla con un SQLSTATE distinto
DO $$
BEGIN
  BEGIN
    PERFORM prueba.afirmar_error('SELECT 1/0', '23505', 'x');
  EXCEPTION WHEN SQLSTATE 'PT001' THEN RETURN;
  END;
  RAISE EXCEPTION 'afirmar_error no falló con un SQLSTATE distinto';
END $$;

-- @test afirmar_error revierte los efectos de la sentencia fallida
CREATE TEMP TABLE t_efectos (n int);
SELECT prueba.afirmar_error($$INSERT INTO t_efectos VALUES (1); SELECT 1/0$$, '22012', 'inserta y falla');
SELECT prueba.afirmar_igual((SELECT count(*) FROM t_efectos), 0::bigint, 'el insert quedó revertido');
