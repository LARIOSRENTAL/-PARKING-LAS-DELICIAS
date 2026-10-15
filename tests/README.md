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
