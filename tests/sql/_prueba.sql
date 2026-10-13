-- Funciones de aserción para las pruebas SQL. Solo se instalan en la base de pruebas.
-- Un fallo de aserción lanza SQLSTATE 'PT001', para distinguirlo de los errores de la propia base.

CREATE SCHEMA IF NOT EXISTS prueba;

-- Las pruebas del rol de aplicación llaman a las aserciones como cuaderno_app (solo en la base de pruebas).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cuaderno_app') THEN
    GRANT USAGE ON SCHEMA prueba TO cuaderno_app;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION prueba.afirmar(condicion boolean, mensaje text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condicion IS NOT TRUE THEN
    RAISE EXCEPTION 'Afirmación fallida: %', mensaje USING ERRCODE = 'PT001';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION prueba.afirmar_igual(obtenido anyelement, esperado anyelement, mensaje text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF obtenido IS DISTINCT FROM esperado THEN
    RAISE EXCEPTION 'Afirmación fallida: % (esperado %, obtenido %)', mensaje, esperado, obtenido
      USING ERRCODE = 'PT001';
  END IF;
END
$$;

-- Ejecuta la sentencia y exige que falle con exactamente el SQLSTATE esperado.
-- Corre en un subbloque: si la sentencia falla, sus efectos se revierten y la prueba continúa.
CREATE OR REPLACE FUNCTION prueba.afirmar_error(sentencia text, sqlstate_esperado text, mensaje text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  obtenido text;
BEGIN
  BEGIN
    EXECUTE sentencia;
  EXCEPTION WHEN OTHERS THEN
    obtenido := SQLSTATE;
  END;
  IF obtenido IS NULL THEN
    RAISE EXCEPTION 'Afirmación fallida: % (se esperaba el error % y la sentencia funcionó)', mensaje, sqlstate_esperado
      USING ERRCODE = 'PT001';
  ELSIF obtenido <> sqlstate_esperado THEN
    RAISE EXCEPTION 'Afirmación fallida: % (se esperaba el error % y llegó %)', mensaje, sqlstate_esperado, obtenido
      USING ERRCODE = 'PT001';
  END IF;
END
$$;
