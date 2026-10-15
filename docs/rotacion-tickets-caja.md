# Rotación, tickets y hoja de caja

- La entrada de Rotación genera un ticket con el PNG original y un código Code 128 que contiene la matrícula normalizada. El lector debe funcionar como teclado USB y terminar la lectura con Intro. También se puede escribir la matrícula y pulsar Intro.
- El lector abre el cobro sin registrar aún una salida. La tarifa se calcula automáticamente; el empleado puede aplicar horas gratuitas, un descuento en euros o editar directamente el total final. El importe de tarifa y el ajuste se conservan.
- Tarjeta marca automáticamente «Imprimir ticket · factura simplificada»; efectivo permite marcarlo manualmente. Se guarda el cobro antes de imprimir. Una impresión fallida se recupera desde Tickets emitidos → Ticket de cobro; no se debe repetir la salida.
- «Mandar a estancia» selecciona bonos hotel, solicita hotel, categoría, plaza, días y modelo. Crea la estancia ya dentro con la entrada original y cancela el ticket de Rotación sin cobrarlo. Si no hay bonos o plaza válida, no modifica ninguno de los dos registros.
- En reservas de días, la opción de ticket queda guardada hasta marcar la entrada y cobrar. «Cobrar / Ticket» permite cobrar antes y «Ticket de cobro» permite reimprimir. Un canje de bonos hotel no se cobra otra vez.
- «Generar factura» usa una sola ventana con nombre, NIF/CIF y domicilio. Se conservan los permisos existentes de administrador/gerente. En Rotación se emite al confirmar el cobro. La factura y su recibo quedan relacionados.
- La hoja de caja registra cada cobro una sola vez y lo separa en Abonados, Estancias y Rotación, con totales por medio de pago. Incluye compras de bonos hotel en Estancias. Se puede imprimir antes de cerrar turno; si falla el envío solicitado, el turno permanece abierto. Empieza a registrar cobros al activar la migración; no inventa importes ni formas de pago de operaciones históricas.

Los tickets usan la cola existente `BIXOLON SRP-350III`, en 80 mm. Facturas y caja conservan `FACTURAS`; bonos conservan `RICOH MP 2003`. Las opciones del trabajo no cambian las preferencias ni la impresora predeterminada de Windows. La firma local de QZ se conserva y debe estar configurada en ese ordenador.

Los recibos usan una serie separada `PLDFS-año-correlativo`, base e IVA del 21 % incluidos en el total cobrado. La reimpresión recupera el mismo número y no suma otro movimiento de caja.

## Lista negra

La pestaña «Lista negra» permite incorporar matrículas y una observación obligatoria, editar el motivo y retirar o reactivar el bloqueo. Los empleados necesitan un turno abierto para modificarla; el administrador conserva el acceso operativo existente. Las matrículas se comparan sin espacios ni guiones.

Al introducir una matrícula bloqueada se muestra el motivo y un aviso para no emitir ticket. La base de datos impide una nueva entrada tanto en Rotación como en Estancias, incluso desde una pantalla desactualizada. Un vehículo que ya estaba dentro puede salir y pagar normalmente. Retirar un bloqueo conserva el registro y sus fechas de auditoría.

## Bonos individuales H y registros E

Cada bono hotel representa un día y tiene un registro global único H-1, H-2… con código Code 128. Los registros de nuevas estancias usan E-1, E-2…; las referencias históricas se conservan.

Al seleccionar «Bonos hotel», sitúa el cursor en el campo de códigos y escanea los bonos con el lector (terminador Intro), o escribe sus registros separados por comas, espacios o saltos de línea. El hotel propietario aparece automáticamente. Debe haber un bono por día y todos deben ser del mismo hotel. Se rechazan registros inexistentes, repetidos, ya utilizados o pertenecientes a un hotel desactivado.

El canje registra los códigos concretos y descuenta los días del hotel en una sola transacción. Ampliar una estancia exige los bonos de los días adicionales. «Mandar a estancia» desde Rotación pide también los códigos y conserva la entrada original. Las pantallas antiguas no pueden seguir canjeando únicamente por nombre de hotel.

Las compras anteriores se numeran individualmente respetando los saldos y canjes existentes. Sus bonos pendientes deben reimprimirse con «Reimprimir disponibles» para obtener los códigos H individuales; las hojas antiguas compartían el número de compra. Reimprimir conserva los registros H y excluye los ya canjeados. Una reimpresión no crea una compra ni suma caja.

## Prueba del lector y correo de abonados por banco

Las compras de prueba se marcan `is_test`: sirven para validar la impresión y el canje, pero no crean un cobro de caja. Las compras de prueba retiradas se marcan `is_void`; no aparecen como disponibles, no se imprimen ni se canjean, y sus códigos no se reutilizan.

Para probar el lector: abre Bloc de notas y escanea un bono nuevo. Si escribe, por ejemplo, H-21 y termina con Intro, funciona como teclado USB. Después, en Nueva estancia → Bonos hotel, sitúa el cursor en el campo de códigos y escanea tantos bonos como días. Debe aparecer PRUEBAS LECTOR CÓDIGOS y descontarse únicamente los códigos utilizados al confirmar la estancia.

Los abonados habilitados con `auto_email_bank` generan una única factura y una tarea de correo al marcar el mes como pagado por banco. No se envían facturas antiguas solo por habilitar el flag. Los destinatarios se leen de la ficha del abonado; el navegador no proporciona una dirección arbitraria. Marcar el mismo mes dos veces no duplica el envío. El proceso se ejecuta en servidor y continúa aunque se cierre el navegador.

La función `bank-invoice-mail` genera el PDF A4 con el PNG original y exclusivamente la copia del cliente. Requiere `RESEND_API_KEY` y un remitente de dominio verificado en `INVOICE_EMAIL_FROM` (o `BOOKING_EMAIL_FROM`); `INVOICE_EMAIL_REPLY_TO` es opcional. Las direcciones personales de Gmail se pueden usar como Reply-To, pero no como dominio de envío de Resend. La opción «Comprobar correo de facturas» muestra el estado real de configuración. Las facturas sin email o sin datos fiscales quedan pendientes; completar la ficha desbloquea esos trabajos. El error de correo nunca debe cancelar el registro del pago.

La cola tiene RLS, funciones internas exclusivas del rol de servicio, autenticación del empleado o del trabajador interno y reintentos limitados. Resend recibe una clave de idempotencia fija por trabajo. Los trabajos ya enviados no se vuelven a despachar y las situaciones antiguas ambiguas requieren revisión antes de reintentar.

Los abonados del listado de banco mantienen Banco fijado en la tabla, la edición de ficha y los cobros en grupo. Dos disparadores lo garantizan también en base de datos antes de registrar caja o correo. No se reescriben cobros históricos.

En Rotación, Intro consulta primero la matrícula: si está dentro abre el cobro; si no está dentro registra e imprime la entrada. Conserva tarifa y datos de llaves elegidos. Los errores de consulta no se interpretan como matrícula nueva y el bloqueo de lista negra sigue activo. La leyenda de retirada, extravío y tarifa del ticket se reproduce completa.
