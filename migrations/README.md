# Migraciones

- Nombre: `NNNN_nombre_en_minusculas.sql`, numeración consecutiva desde `0001`, sin huecos ni duplicados.
- SQL puro. Cada archivo se aplica en **una transacción**, junto con su registro en `schema_migrations` (versión, nombre y SHA-256 del contenido con finales LF).
- **Una migración aplicada no se edita.** Si su checksum cambia, el runner se niega a continuar. Para corregir algo, se crea una migración nueva.
- Un bloqueo consultivo (`pg_advisory_lock`) serializa dos ejecuciones simultáneas sobre la misma base.
