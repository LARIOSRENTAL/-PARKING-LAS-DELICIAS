# Bonos hotel pendientes de pago

«Pendiente de pago» prepara, numera e imprime los bonos sin generar un movimiento de caja. El listado muestra la deuda en rojo por hotel y por compra e incluye todos los pendientes aunque sean antiguos. Los registros H y sus propietarios no cambian al cobrar.

«Generar pago» abre un formulario con Efectivo, Tarjeta y Banco, ticket opcional y factura completa para administrador/gerente. Tarjeta marca el ticket automáticamente. Al elegir factura se desactiva la simplificada y se piden nombre, NIF/CIF y domicilio en la misma ventana. Importes superiores al límite admitido por el sistema para factura simplificada requieren factura completa.

El servidor bloquea la compra durante el cobro y registra empleado, fecha y turno actuales. La caja incluye el importe únicamente al pagar. Repetir una petición o reimprimir devuelve los documentos existentes y no duplica caja ni cambia el medio de pago original. Si falla imprimir, el cobro permanece guardado y puede recuperarse con «Ticket / factura».

Las compras históricas conservan sus movimientos y su condición de pagadas; no se reinterpretan como deudas. Los lotes de prueba y anulados no pueden cobrarse. Las pruebas PostgreSQL aisladas verifican preparación sin caja, pago tres días después en otro turno, reintentos, rollback, permisos, factura/ticket excluyentes, pago inmediato y conservación de códigos. Las pruebas de interfaz verifican el rojo y la selección automática de ticket.

Las colas y preferencias de impresora no se modifican: bonos en RICOH MP 2003, tickets en BIXOLON SRP-350III y facturas en FACTURAS.
