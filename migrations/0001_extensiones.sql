-- 0001 · Extensiones base de Cuaderno.
-- vector: embeddings del contenido para la búsqueda semántica del asistente de IA (pgvector).
-- citext: correos comparados sin distinguir mayúsculas/minúsculas.
-- gen_random_uuid() es nativo desde PostgreSQL 13; no hace falta pgcrypto.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS citext;
