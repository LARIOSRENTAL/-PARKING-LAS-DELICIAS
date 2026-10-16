# Gestión de usuarios y contraseñas

Administrador y gerente ven **Usuarios**. Pueden crear cuentas, abrir la ficha de cada usuario, cambiar nombre, permiso o estado de acceso, asignar una contraseña nueva y eliminar el acceso. El listado no muestra accesos eliminados.

Cada empleado tiene **Mi usuario**, con su nombre, correo y permiso. Para cambiar su contraseña debe indicar la actual y confirmar la nueva. Gerentes y administradores pueden asignar una nueva desde la ficha sin conocer la anterior. Nunca se muestran contraseñas existentes; los campos son de tipo contraseña y se vacían tras guardar o cerrar.

Eliminar significa retirar el acceso, conservando las referencias del usuario en sus turnos y cobros. La cuenta no se borra de Auth ni se libera su dirección de correo para otra alta. Un acceso desactivado sí puede activarse desde la ficha; uno eliminado no se reactiva desde este panel. No se permite eliminar el acceso propio ni dejar el sistema sin administrador activo.

La función `staff-admin` valida cada JWT mediante `auth.getUser` y consulta el permiso y acceso vigentes en `staff_profiles`. Los empleados no pueden listar ni modificar otras cuentas, aunque cambien los parámetros de la petición o sus metadatos. `my_password` ignora cualquier identificador de usuario enviado y cambia exclusivamente la cuenta autenticada, tras verificar su contraseña actual. La clave de servicio permanece en el servidor. La función conserva su autenticación propia y la configuración previa `verify_jwt=false`.

La migración añade `deleted_at` y un trigger privado para proteger al último administrador y evitar reactivar accesos eliminados. No modifica usuarios existentes. La comprobación funcional usa perfiles y contraseñas ficticios; no se han creado, eliminado ni cambiado contraseñas de empleados reales para probar.

Validación desde la raíz:

```sh
node tests/staff-users-api.cjs
node tests/staff-users-db.cjs
node tests/staff-users-ui.cjs
npm test --prefix tests
```

Las pruebas cubren permisos de gerente/empleado, sesiones inexistentes/inactivas/eliminadas, contraseña propia y ajena, confirmación de contraseña, protección del último administrador y conservación de turnos al eliminar acceso. Las pruebas de regresión incluyen estancias vigentes hasta finalización manual, ocupación de plazas, bonos y cobros pendientes de hotel.
