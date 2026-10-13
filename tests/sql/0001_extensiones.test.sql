-- @test vector está instalada y calcula distancias
SELECT prueba.afirmar(EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector'), 'extensión vector');
SELECT prueba.afirmar_igual('[1,2,3]'::vector <-> '[1,2,4]'::vector, 1::float8, 'distancia L2');
SELECT prueba.afirmar_igual(('[1,0]'::vector <=> '[0,1]'::vector)::numeric, 1::numeric, 'distancia coseno ortogonal');

-- @test vector rechaza dimensiones distintas
SELECT prueba.afirmar_error($$SELECT '[1,2]'::vector <-> '[1,2,3]'::vector$$, '22000', 'dimensiones distintas');

-- @test citext compara sin distinguir mayúsculas
SELECT prueba.afirmar(EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'citext'), 'extensión citext');
SELECT prueba.afirmar('Ana@Example.com'::citext = 'ana@example.com'::citext, 'citext insensible');

-- @test schema_migrations registra 0001 con checksum de 64 hex
SELECT prueba.afirmar_igual(
  (SELECT nombre FROM schema_migrations WHERE version = 1), 'extensiones'::text, 'nombre de la 0001');
SELECT prueba.afirmar((SELECT checksum ~ '^[0-9a-f]{64}$' FROM schema_migrations WHERE version = 1), 'checksum sha256');
