# Contrato de impresión de bonos

Los bonos de estancias y hotel se envían a la misma cola `RICOH MP 2003`, con el formato existente de 100 × 210 mm. `print-profiles.js` fija el documento en vertical, giro cero y tamaño personalizado, desactiva el escalado automático y proporciona al renderizador HTML las dos dimensiones de la página. Se utiliza una instantánea rasterizada para no depender de la adaptación de página del camino vectorial JavaFX. Cada bono hotel sigue siendo un trabajo separado.

El perfil base es inmutable y se copia para cada trabajo. No se invoca `qz.configs.setDefaults`, no se modifica la impresora predeterminada y no se envían nuevas opciones de bandeja, grosor o tipo de papel. Tampoco se cambian los ajustes de las otras dos colas ni el diseño del bono. Las opciones son locales al documento, no se escriben en Windows.

La orientación vertical ya figuraba en el código anterior; por tanto no se atribuye el incidente a un cambio de preferencias de Windows sin comprobarlas. Se eliminan las dimensiones automáticas y el escalado del envío, pero la comprobación física de la salida depende del equipo y controlador locales.

La prueba `node tests/print-profiles.cjs`, incluida también en `npm test --prefix tests`, intercepta los trabajos sin imprimir. Comprueba la secuencia factura → bono → ticket → bono, los bonos hotel, la independencia entre objetos de configuración y los errores de cola sin reintento automático. La documentación oficial de QZ describe las opciones de documento en https://qz.io/api/qz.configs y las dimensiones de renderizado HTML en https://qz.io/docs/pixel.

No se crean estancias, cobros ni impresiones reales durante la validación. Para comprobar el equipo debe reimprimirse el bono ya registrado, no crear otra estancia.
