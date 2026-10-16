# Contrato de impresión de bonos

Los bonos de estancias y hotel se envían a la misma cola `RICOH MP 2003`, con el formato existente de 100 × 210 mm. `print-profiles.js` fija el documento en vertical, giro cero y tamaño personalizado, ajusta la instantánea a la hoja física y proporciona al renderizador HTML las dos dimensiones de la página. Se utiliza una instantánea rasterizada y `scaleContent:true`: no se debe combinar raster de alta resolución con `scaleContent:false`. El contenido mantiene la misma proporción 100:210. Cada bono hotel sigue siendo un trabajo separado.

El perfil base es inmutable y se copia para cada trabajo. No se invoca `qz.configs.setDefaults`, no se modifica la impresora predeterminada y no se envían nuevas opciones de bandeja, grosor o tipo de papel. Tampoco se cambian los ajustes de las otras dos colas ni el diseño del bono. Las opciones son locales al documento, no se escriben en Windows.

La orientación vertical ya figuraba en el código anterior; por tanto no se atribuye el incidente a un cambio de preferencias de Windows sin comprobarlas. Se fijan las dimensiones y la orientación del envío, pero la comprobación física de la salida depende del equipo y controlador locales.

La prueba `node tests/print-profiles.cjs`, incluida también en `npm test --prefix tests`, intercepta los trabajos sin imprimir. Comprueba la secuencia factura → bono → ticket → bono, los bonos hotel, la independencia entre objetos de configuración y los errores de cola sin reintento automático. La documentación oficial de QZ describe las opciones de documento en https://qz.io/api/qz.configs y las dimensiones de renderizado HTML en https://qz.io/docs/pixel.

No se crean estancias, cobros ni impresiones reales durante la validación. Para comprobar el equipo debe reimprimirse el bono ya registrado, no crear otra estancia.

## Hoja de caja al cerrar turno

Cerrar turno imprime obligatoriamente una consulta fresca por el UUID del turno propio, incluso para gerente/administrador, sin reutilizar la consulta de pantalla por fecha. Se envía antes del cierre; si falla la consulta o el envío, no se cierra ni se termina la sesión. Se bloquean dobles pulsaciones. La aceptación de QZ significa enviado a la cola, no confirma la salida física del papel.

El trabajo `cashbook` usa exclusivamente RICOH MP 2003, A5 horizontal (perfil HOJA DE CAJA), bandeja 1 (`printerTray:1`), márgenes de 6 mm. El HTML tiene anchura imprimible de 198 mm, sin altura fija y con renderizado vectorial (`rasterize:false`, `scaleContent:false`), para permitir varias hojas si hay muchos cobros. Estos ajustes son locales al trabajo y nunca modifican las preferencias de Windows, los bonos verticales, las facturas ni los tickets. También se aplican al botón de reimpresión del resumen. La prueba cashbook-close.cjs verifica turno exacto, datos frescos, fallos, cancelación y doble clic, sin cerrar turnos reales.

## Corrección del recorte ampliado (16/10, segunda comprobación física)

La foto del usuario demostró que el raster sin escalado no era correcto. En QZ PrintHTML.parseData se renderiza con zoom DPI/72 y se deriva a PrintImage, cuyo dpiScale parte de 1; sin ajuste físico la imagen puede quedar ampliada según la resolución. Los bonos de una hoja usan ajuste a página conservando la proporción, vertical, giro cero, 100×210 y las dimensiones HTML existentes. La caja multipágina usa el camino vectorial para no sufrir la misma amplificación y mantener paginación sin escalado.

La regresión comprueba las dimensiones físicas de los trabajos normales y hotel a 203/300/600/1200 dpi y muestra que la configuración anterior supera 800 mm de anchura a 600 dpi. Fuente revisada: https://github.com/qzind/tray/blob/master/src/qz/printer/action/PrintHTML.java y PrintImage.java. Estas pruebas no sustituyen la impresión física con el controlador del puesto.

## Resumen de cierre

El cierre y el botón Imprimir resumen de caja imprimen únicamente los totales de Abonados, Estancias y Rotación, total cobrado y desglose por Tarjeta, Efectivo, Banco y Online. Incluyen fecha, turno y empleado en el cierre. No se imprimen matrículas, referencias ni movimientos individuales. El listado completo sigue disponible en pantalla. Se conserva el envío A5 horizontal por bandeja 1 de Ricoh y los ajustes locales ya definidos. La prueba usa 5000 cobros para comprobar que el tamaño del resumen no crece con los movimientos.
