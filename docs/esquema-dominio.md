# Esquema del dominio (migraciones 0008–0011)

Como en la identidad, las reglas del dominio viven **en la base**. Cada una tiene una prueba SQL que intenta violarla y una mutación que la quita (`mutations/catalogo.json`, ids C01–C40).

## Modelo

```
usuarios ─┬─< miembros_espacio >── espacios ──< documentos ──┬─< permisos_documento
          │      (rol de espacio)                            ├─< actualizaciones_documento   (log Yjs)
          │                                                  ├─< versiones                   (solo inserción, cadena de hash)
          │                                                  ├─< comentarios                 (hilos)
          │                                                  ├─< sesiones_edicion            (presencia; cuelga de sesiones)
          │                                                  └─< embeddings                  (pgvector 1024)
          └─< uso_ia_diario
```

## Rol efectivo

`rol_efectivo_documento(usuario, documento)` es la única respuesta a "¿qué puede hacer esta cuenta con este documento?". Devuelve `propietario`, `editor`, `lector` o `NULL` (sin acceso).

La usan los triggers de la base y la usará el backend en cada mensaje del WebSocket.

| Situación | Rol efectivo |
|---|---|
| Propietario del documento | `propietario` |
| Propietario del espacio, sin permiso propio en el documento | `editor` (ser dueño del espacio no da la propiedad del documento) |
| Editor del espacio | `editor` |
| Lector del espacio con permiso `editor` en el documento | `editor` (solo en ese documento) |
| Lector del espacio | `lector` |
| No es miembro del espacio | `NULL` |
| Cuenta con rol de cuenta `lector` | nunca pasa de `lector` |

El rol de cuenta `admin` administra cuentas e invitaciones. **No** da acceso al contenido de los documentos.

## Reglas y su cobertura

### Espacios y permisos

| Regla | Mutación |
|---|---|
| Solo cuentas activas son miembros (CHECK + FK compuesta) | C39, C40 |
| Exactamente un propietario por espacio (exclusión parcial + restricción diferida) | C37, C38 |
| Un permiso de documento solo se da a miembros del espacio del documento (FK compuesta) | C24 |
| El permiso no puede declarar un espacio distinto al del documento (FK compuesta) | C25 |
| Exactamente un propietario por documento | C32, C33 |
| Solo un editor o propietario del espacio crea documentos | C34 |
| Un documento no cambia de espacio | C35 |
| Techo por rol de cuenta: una cuenta lectora solo recibe rol lector | C30 |
| Bajar una cuenta a lectora exige quitarle antes los roles que escriben | C31 |
| Rol efectivo: sin membresía no hay acceso | C26 |
| Rol efectivo: la cuenta lectora queda en lector aunque alguien desactive el trigger del techo (segunda capa) | C27 |
| Rol efectivo: ser propietario del espacio da `editor`, no `propietario` | C28 |
| Rol efectivo: solo cuentas activas. **Mutación equivalente:** el JOIN con `miembros_espacio` ya lo garantiza, porque solo hay membresías de cuentas activas. Se conserva como defensa en profundidad. | C29 (equivalente) |
| Quitar o cambiar un permiso emite `NOTIFY cuaderno_permisos` al `COMMIT`, para que el backend corte la conexión (prueba en `tests/integracion/avisos-permisos.test.mjs`) | C36 |

### Escritura: un lector nunca escribe

| Regla | Mutación |
|---|---|
| Insertar una actualización Yjs exige rol efectivo editor o propietario | C10, C11 |
| Crear una versión manual o una restauración exige escritura | C09 |
| Las automáticas no tienen autor; las manuales y las restauraciones sí | C13 |

### Historial de versiones a prueba de manipulación

**Solo inserción.** `UPDATE`, `DELETE` y `TRUNCATE` sobre `versiones` lanzan error `42501`. La única excepción es que las versiones desaparecen cuando se borra su documento.

**Cadena de hash.** La base calcula `numero`, `hash_previo`, `hash` y `creado_en`; lo que mande el cliente en esas columnas se ignora. El hash es:

```
hash = SHA-256( hash_previo ‖ documento ‖ número ‖ SHA-256(estado Yjs) ‖ SHA-256(texto) ‖ autor ‖ motivo ‖ restaurada_de ‖ creado_en )
```

La primera versión parte de 32 bytes en cero.

**Verificación.** `verificar_cadena_versiones(documento)` recalcula la cadena y devuelve el número de la primera versión alterada, o `NULL` si está íntegra. Las pruebas desactivan a propósito el trigger, como podría hacerlo un superusuario, manipulan una versión y comprueban dos casos:

- si solo se cambia el texto, se detecta la versión manipulada;
- si además se rehace su hash, se detecta el eslabón siguiente.

| Regla | Mutación |
|---|---|
| UPDATE y DELETE prohibidos | C01 |
| TRUNCATE prohibido | C02 |
| La excepción de borrado está acotada a "documento borrado" | C03 |
| Cada versión encadena el hash de la anterior | C04 |
| El hash cubre el contenido | C05 |
| La base numera; el cliente no elige | C06 |
| La verificación recalcula cada hash | C07 |
| La verificación comprueba cada eslabón | C08 |
| Solo se restaura desde una versión del mismo documento | C12 |

### Comentarios y presencia

| Regla | Mutación |
|---|---|
| Comentar exige acceso (un lector puede comentar; un externo no) | C14 |
| Una respuesta pertenece al documento de su hilo y no lleva ancla propia | C15 |
| La sesión de edición registra exactamente el rol efectivo | C16 |
| La sesión de edición exige una sesión de login viva | C17 |
| La sesión de edición pertenece a una sesión de login del mismo usuario; cerrar la sesión de login la borra | C18 |

### IA: aislamiento de embeddings garantizado por la base

1. **FK compuesta** `(documento_id, espacio_id) → documentos (id, espacio_id)`. Un fragmento no puede quedar etiquetado en otro espacio, ni siquiera si lo indexa alguien con acceso a los dos (C20).
2. **Trigger `embeddings_aislamiento`** (al insertar y al actualizar). Quien indexa tiene que tener acceso al documento: el contenido ajeno se rechaza con `42501` (C19, C21).
3. **`buscar_fragmentos(usuario, espacio, consulta, límite)`.** Filtra por espacio (C22) y por el acceso **actual** de quien busca (C23). Quitar el permiso hoy oculta hoy los fragmentos indexados ayer. El límite queda entre 1 y 50.

La dimensión es fija, de 1024. Un proveedor real con otra dimensión exige una migración nueva.

## Decisiones

- **El rol de espacio da acceso a todos los documentos del espacio.** No hay documentos privados dentro de un espacio. Si se quisieran, se agregaría un nivel "restringido" en una migración nueva.
- **Borrado de cuenta (bloque G).** Para anonimizar una cuenta, primero hay que sacarla de sus espacios (FK compuesta). Eso borra en cascada sus permisos de documento. Si era la propietaria de un documento que sigue existiendo, la restricción diferida "todo documento tiene propietario" hace fallar el `COMMIT`. Por eso la base no deja documentos huérfanos: el backend tiene que transferir la propiedad (y responder 409 si hay colaboradores) o borrar los documentos sin colaboradores.
- **Tope diario de IA.** `uso_ia_diario` garantiza contadores no negativos. El tope por cuenta lo aplica el backend con un `UPDATE` condicional (bloque P).
