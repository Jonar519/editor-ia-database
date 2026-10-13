# Esquema de identidad (migraciones 0002–0007)

Las reglas de identidad viven **en la base**, no solo en el backend: aunque el backend tenga un error, la base rechaza el estado inválido.

Cada regla tiene:

- una prueba SQL que intenta violarla (`tests/sql/`), y
- una mutación que la quita y comprueba que esa prueba falla (`mutations/catalogo.json`).

## Ciclo de vida de una cuenta

```
            invitación (admin)            completar registro                 eliminar cuenta
  (nada) ─────────────────────▶ pendiente ──────────────────▶ activa ──────────────────▶ eliminada (lápida)
                                   │ sin contraseña              contraseña                 sin correo, nombre,
                                   │ solo puede tener            (+ MFA si es admin)        teléfono ni contraseña
                                   │ su invitación               sesiones y tokens
                                   └─ cancelar = DELETE (solo pendientes)
```

## Cómo se impide que una cuenta pendiente tenga sesiones o tokens

Cada tabla de sesión o token tiene una columna `estado_usuario` con dos reglas:

- **`CHECK (estado_usuario = 'activa')`**: la columna solo admite ese valor.
- **Clave foránea compuesta** `(usuario_id, estado_usuario) → usuarios (id, estado)`: la fila tiene que coincidir con el estado real de la cuenta.

Juntas, solo pueden apuntar a una cuenta que esté activa ahora mismo. Hacen falta las dos:

- Sin el CHECK, una fila podría declararse `'pendiente'` y la clave foránea la aceptaría.
- Sin la clave foránea compuesta, una fila que dice `'activa'` podría apuntar a una cuenta pendiente.

La clave foránea no se actualiza en cascada. Por eso, mientras existan esas filas, la cuenta no puede cambiar de estado. Para anonimizarla hay que borrar antes sus sesiones y tokens.

Las invitaciones usan el mismo mecanismo, pero al revés (`'pendiente'`). Activar la cuenta exige borrar antes la invitación, así que el enlace es de un solo uso por construcción.

| Tabla | Liga directa (CHECK + FK compuesta) | Mutaciones |
|---|---|---|
| `invitaciones` | solo cuentas **pendientes** | B01, B02 |
| `sesiones` | solo cuentas activas | B03, B04 |
| `tokens_recuperacion` | solo cuentas activas | B05, B06 |
| `cambios_correo` | solo cuentas activas | B07, B08 |
| `mfa_totp` | solo cuentas activas | B09, B10 |

Dos tablas quedan ligadas a una cuenta activa de forma **transitiva**:

| Tabla | Cómo queda ligada | Mutación |
|---|---|---|
| `tokens_refresco` | FK compuesta `(sesion_id, usuario_id) → sesiones (id, usuario_id)`, y una sesión solo existe para una cuenta activa | B12 |
| `codigos_respaldo` | FK `usuario_id → mfa_totp`, y el MFA solo existe para una cuenta activa | B11 |

En estas dos tablas no repetí el CHECK + FK a `usuarios` a propósito. Habría sido redundante, y sus mutaciones habrían resultado **equivalentes**: quitarlo no cambiaría nada, porque la cadena ya lo impide.

## Reglas y su cobertura

| Regla | Dónde | Mutación |
|---|---|---|
| Toda cuenta nace pendiente (no hay alta directa de cuentas activas) | trigger `usuarios_nacen_pendientes` | B13 |
| Transiciones válidas: solo pendiente→activa y activa→eliminada | trigger `usuarios_transicion_estado` | B14 |
| Una cuenta pendiente no tiene contraseña | CHECK `usuarios_pendiente_sin_contrasena` | B15 |
| Una cuenta activa tiene contraseña y fecha de activación | CHECK `usuarios_activa_completa` | B16 |
| La eliminación es una lápida sin datos personales | CHECK `usuarios_eliminada_es_lapida` | B17 |
| La contraseña solo se guarda como hash `$scrypt$...` | CHECK `usuarios_hash_scrypt` | B18 |
| Correo único sin distinguir mayúsculas; una lápida libera el correo | índice único parcial sobre `citext` | B19 |
| Solo un admin activo puede invitar | trigger `usuarios_invitada_por_admin` | B20 |
| Solo se borran cuentas pendientes | trigger `usuarios_solo_se_borran_pendientes` | B21 |
| `creado_en` lo fija la base, así que no se fabrican plazos más largos | función `fijar_creado_en` | B22 |
| Token usado, sesión revocada o MFA confirmado no se pueden deshacer | función `una_sola_vez` | B23 |
| Los plazos solo se acortan | función `plazos_solo_se_acortan` | B24 |
| Invitación: 72 h como máximo | CHECK | B25 |
| Los tokens se guardan como SHA-256 (32 bytes), nunca en claro | CHECK por tabla | B26 (representativa) |
| Sesión: 30 días como máximo | CHECK | B27 |
| Revocación de sesión con motivo válido | CHECK | B28 |
| IP truncada: `/24` en IPv4, `/48` en IPv6 | CHECK + tipo `cidr` | B29 |
| Rotación: como máximo un token de refresco vigente por sesión | exclusión parcial (0013) | B30 |
| No se emiten tokens de refresco para una sesión revocada | trigger | B31 |
| Recuperación: 15 min como máximo y uno vigente por cuenta | CHECK + exclusión parcial (0013) | B32, B33 |
| Cambio de correo: como máximo uno pendiente por cuenta | exclusión parcial (0013) | B41 |
| Anti-replay TOTP: `ultimo_paso` solo crece | trigger `mfa_totp_anti_replay` | B34 |
| Secreto MFA inmutable (reconfigurar = borrar y crear) | `una_sola_vez` | B35 |
| AES-256-GCM: IV de 12 bytes y etiqueta de 16 | CHECK | B36 |
| Como máximo 10 códigos de respaldo | trigger con bloqueo de fila | B37 |
| Un admin activo siempre tiene MFA confirmado | trigger de restricción diferido al `COMMIT` | B38 |
| Correo simulado: retención de 7 días como máximo | CHECK | B39 |
| Rangos IP→ubicación sin solapamiento | `EXCLUDE USING gist` | B40 |

## Decisiones y límites (para los bloques del backend)

- **Activación de un admin.** El MFA se crea en la misma transacción que la activación: primero `UPDATE` a `activa`, después `INSERT` en `mfa_totp`. La regla "un admin activo tiene MFA" se revisa al `COMMIT`, por eso es diferida.
- **Inscripción MFA de un admin pendiente (bloque F).** Un admin pendiente no puede tener fila en `mfa_totp`. El secreto que se le muestra antes de confirmar el primer código tiene que vivir en otro lugar. En el bloque F propondré dónde (por ejemplo, ligado a la invitación) y traeré la decisión.
- **Bloqueo de cuenta.** `fallos_login` y `bloqueada_hasta` están en `usuarios`. La política progresiva (cuántos fallos y cuánto tiempo) es del backend (bloque E). La base solo exige que `fallos_login` no sea negativo.
- **Correo simulado.** Guarda el cuerpo del correo, incluido el enlace con el token, porque es el "buzón" de la demo. Solo existe con el proveedor mock (producción no arranca con mock) y se borra a los 7 días como máximo.
- **No implementado en este bloque.** No hay permisos de rol de base de datos (usuario de aplicación con privilegios mínimos): se evaluará en el bloque D. Tampoco hay política de reintentos de login por IP: es rate limiting en Redis, en el bloque E.

## Nota: índices únicos parciales → restricciones de exclusión (migración 0013)

Las reglas del tipo "como máximo uno vigente" nacieron como índices únicos parciales. En la migración 0013 pasaron a ser restricciones `EXCLUDE USING btree (col WITH =) WHERE (...)`.

- **Qué hacen:** exactamente lo mismo. El único cambio visible es que la violación da `23P01` en lugar de `23505`.
- **Por qué cambiaron:** con índices únicos parciales, `prisma db pull` (el backend usa Prisma como cliente) deducía relaciones uno a uno que no existen. Unas producían un esquema inválido y otras un modelo falso en silencio.
- **Lo que se agregó:** `invitaciones` y `mfa_totp`, cuya relación sí es uno a uno, tienen además un `UNIQUE (usuario_id, estado_usuario)` redundante, que es lo que Prisma exige.
