# Verificación de cobros y tickets

Ejecutar con Node 24 o posterior:

```sh
cd tests
npm install
npm test
```

La prueba crea una base PostgreSQL WASM aislada (PGlite); nunca conecta con producción. `fixtures/parking-schema.json` contiene únicamente metadatos del esquema y definiciones de las funciones anteriores a esta migración, sin registros de clientes ni credenciales.

Verifica cálculo de rotación, lectura normalizada de matrícula, total editable, desglose de IVA, numeración y reintento de recibos, factura con datos completos e inmutabilidad al reimprimir, conversión atómica con la entrada original, saldo de bonos insuficiente, cobro de estancia sin duplicados, precios de hoteles para 199 y 200 bonos, hoja de caja y controles de acceso.

Comprobación realizada adicionalmente en Chromium con backend simulado: lectura USB por teclado y Enter, apertura automática de cobro, selección de tarjeta y casilla de ticket, formulario único de factura y renderización de ambos tickets en papel de 80 mm.

Las pruebas de lista negra comprueban normalización, bloqueo real de entradas en Rotación y Estancias, retirada de bloqueo, salida de un coche ya dentro, mensajes con la observación y alta desde el formulario.

`individual-vouchers.cjs` verifica además numeración H/E, migración sin variación de saldos, titularidad, códigos duplicados/inexistentes/usados, cantidad exacta por estancia, ampliaciones, conversión desde Rotación, reimpresión estable y rechazo de pagos sin códigos individuales.

`bank-invoice-mail.cjs` usa dobles locales de pg_net/pg_cron y verifica pago sin duplicados, factura y cola únicas, actualización de email pendiente, exclusión de clientes no habilitados y pruebas sin cobro real. Se ha comprobado además un PDF sintético de una página, con el PNG original y sin el recibo interno. No se envían facturas reales para ejecutar las pruebas.

`rotation-enter-ui.cjs` comprueba las dos acciones de Intro, conservación del formulario, fallo de consulta, protección ante doble pulsación y presencia de la leyenda completa. Las pruebas de banco comprueban además que Banco se conserva aunque se solicite tarjeta o se edite el método habitual.

`free-hours-ui.cjs` ejecuta las funciones reales de la ventana de cobro contra el calculador PostgreSQL aislado: 3 horas con 1 o 2 bonos, restablecer cero, exceso de horas gratuitas, descuento adicional, orden de respuestas y error de cálculo.
