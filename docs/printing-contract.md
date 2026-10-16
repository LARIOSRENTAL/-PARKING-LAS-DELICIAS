# Contrato de impresión de bonos

Los bonos de estancias y hotel se envían a la misma cola `RICOH MP 2003`, con el formato existente de 100 × 210 mm. `print-profiles.js` fija el documento en vertical, giro cero y tamaño personalizado, ajusta la instantánea a la hoja física y proporciona al renderizador HTML las dos dimensiones de la página. Se utiliza una instantánea rasterizada y `scaleContent:true`: no se debe combinar raster de alta resolución con `scaleContent:false`. El contenido mantiene la misma proporción 100:210. Cada bono hotel sigue siendo un trabajo separado.

El perfil base es inmutable y se copia para cada trabajo. No se invoca `qz.configs.setDefaults`, no se modifica la impresora predeterminada y no se envían nuevas opciones de bandeja, grosor o tipo de papel. Tampoco se cambian los ajustes de las otras dos colas ni el diseño del bono. Las opciones son locales al documento, no se escriben en Windows.

La orientación vertical ya figuraba en el código anterior; por tanto no se atribuye el incidente a un cambio de preferencias de Windows sin comprobarlas. Se fijan las dimensiones y la orientación del envío, pero la comprobación física de la salida depende del equipo y controlador locales.

La prueba `node tests/print-profiles.cjs`, incluida también en `npm test --prefix tests`, intercepta los trabajos sin imprimir. Comprueba la secuencia factura → bono → ticket → bono, los bonos hotel, la independencia entre objetos de configuración y los errores de cola sin reintento automático. La documentación oficial de QZ describe las opciones de documento en https://qz.io/api/qz.configs y las dimensiones de renderizado HTML en https://qz.io/docs/pixel.

No se crean estancias, cobros ni impresiones reales durante la validación. Para comprobar el equipo debe reimprimirse el bono ya registrado, no crear otra estancia.

## Hoja de caja al cerrar turno

Cerrar turno imprime obligatoriamente una consulta fresca por el UUID del turno propio, incluso para gerente/administrador, sin reutilizar la consulta de pantalla por fecha. Se envía antes del cierre; si falla la consulta o el envío, no se cierra ni se termina la sesión. Se bloquean dobles pulsaciones. La aceptación de QZ significa enviado a la cola, no confirma la salida física del papel.

El trabajo `cashbook` usa exclusivamente RICOH MP 2003, A5 horizontal (perfil HOJA DE CAJA), bandeja 1 (nombre exacto consultado con `qz.printers.details()`), márgenes de 6 mm. El HTML tiene anchura imprimible de 198 mm, con altura imprimible de 136 mm, raster ajustado a una única hoja de resumen (`rasterize:true`, `scaleContent:true`). Estos ajustes son locales al trabajo y nunca modifican las preferencias de Windows, los bonos verticales, las facturas ni los tickets. También se aplican al botón de reimpresión del resumen. La prueba cashbook-close.cjs verifica turno exacto, datos frescos, fallos, cancelación y doble clic, sin cerrar turnos reales.

## Corrección del recorte ampliado (16/10, segunda comprobación física)

La foto del usuario demostró que el raster sin escalado no era correcto. En QZ PrintHTML.parseData se renderiza con zoom DPI/72 y se deriva a PrintImage, cuyo dpiScale parte de 1; sin ajuste físico la imagen puede quedar ampliada según la resolución. Los bonos de una hoja usan ajuste a página conservando la proporción, vertical, giro cero, 100×210 y las dimensiones HTML existentes. La caja imprime solo totales y utiliza también raster ajustado al área imprimible, sin depender del selector de bandejas de JavaFX.

La regresión comprueba las dimensiones físicas de los trabajos normales y hotel a 203/300/600/1200 dpi y muestra que la configuración anterior supera 800 mm de anchura a 600 dpi. Fuente revisada: https://github.com/qzind/tray/blob/master/src/qz/printer/action/PrintHTML.java y PrintImage.java. Estas pruebas no sustituyen la impresión física con el controlador del puesto.

## Resumen de cierre

El cierre y el botón Imprimir resumen de caja imprimen únicamente los totales de Abonados, Estancias y Rotación, total cobrado y desglose por Tarjeta, Efectivo, Banco y Online. Incluyen fecha, turno y empleado en el cierre. No se imprimen matrículas, referencias ni movimientos individuales. El listado completo sigue disponible en pantalla. Se conserva el envío A5 horizontal por bandeja 1 de Ricoh y los ajustes locales ya definidos. La prueba usa 5000 cobros para comprobar que el tamaño del resumen no crece con los movimientos.

## Selección estricta de bandeja (captura Ricoh 16/10 21:01)

La selección numérica 1 se traducía a «Tray 1» y QZ podía aproximarla a una bandeja localizada diferente. Antes de cada resumen se consulta, de solo lectura, la lista de bandejas de RICOH MP 2003. Se exige un único nombre que identifique bandeja/tray/cassette 1 y se envía literalmente ese nombre. Si falta o es ambiguo no se imprime ni se elige una bandeja por defecto. La firma local permite la consulta `printers.detail` además de las operaciones ya permitidas. El trabajo usa el camino raster/AWT que comparte el inventario de bandejas con esa consulta; el resumen ocupa A5 horizontal con 6 mm de margen. La configuración del bono de estancias no cambia.

La captura muestra que el dispositivo declara bandeja 1 como A4 y solicita A5 con papel grueso 3. La selección de bandeja corregida no cambia las preferencias de Windows ni la declaración física de papel del dispositivo. Debe comprobarse A5 en la bandeja 1 en el panel Ricoh y el tipo de papel de su perfil HOJA DE CAJA. Un trabajo anterior retenido conserva sus ajustes: hay que cancelarlo antes de probar un trabajo nuevo. QZ no permite aplicar por nombre un preset guardado del controlador ni garantiza modificar el tipo de papel; no se promete corregir ese ajuste físico desde la web.

## Selector de plazas de Rotación

Se sustituye el datalist nativo por un desplegable propio de plazas disponibles por categoría/grupo y prefijo de código o número. Se puede elegir con ratón o flechas y Enter; la selección no registra una entrada hasta el siguiente Enter. Si se escribe una plaza conocida no disponible, el campo queda rojo, aria-invalid y mensaje «Plaza no disponible». La validación existente del servidor sigue evitando doble ocupación. Se conservan limpieza de matrícula/plaza tras entrada y excepciones de llaves del Salón Alto.

## Alias observado de la Ricoh (16/10, 21:27)

El controlador del puesto devuelve exactamente Automatic-Feeder, top, middle, manual. En la cola RICOH MP 2003 se admite top como la bandeja superior/1 únicamente cuando se publica también middle y no existe ya un nombre explícito de bandeja 1. No se elige Automatic-Feeder, middle ni manual como sustituto. El alias se limita a esta cola; no se modifica el perfil de estancias ni las preferencias de Windows. Las pruebas reproducen esa respuesta real, verifican el trabajo A5 por top y rechazan otras impresoras, ausencia de top, ausencia de middle y top duplicado. Referencia: OpenJDK Win32PrintService dmPaperBinToMediaTray / MediaTray.TOP (bandeja superior). Sigue pendiente confirmar la hoja física en el puesto.

## Tamaño confirmado por el usuario (16/10, 21:30)

El usuario confirma expresamente «A4 horizontal del perfil» tras mostrar HOJA DE CAJA con A4 210×297, horizontal, bandeja 1, papel normal y reciclado. Esto sustituye la petición anterior A5 y las referencias históricas A5 de este documento. El resumen se envía como A4 horizontal (área 285×198 mm, margen 6 mm), con la bandeja 1/top resuelta del controlador. Se conserva el tipo de papel configurado en el controlador; la web no cambia preferencias globales ni intenta activar por nombre un preset Ricoh. El resumen y el cierre usan la misma configuración. Las estancias/hotel 100×210 verticales no cambian.
