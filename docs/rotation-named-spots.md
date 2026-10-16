# Rotación por plaza real

1. Se escribe o escanea la matrícula y se pulsa Enter. Si ya tiene un ticket activo, se abre el cobro de salida. Si no, el cursor pasa a **Número de plaza** sin registrar todavía ninguna entrada.
2. Se selecciona el tamaño/tarifa y, opcionalmente, el grupo. Se escribe el código completo (por ejemplo `J-18`) o solo el número dentro del grupo seleccionado. Solo se admiten plazas reales disponibles y compatibles con ese tamaño.
3. Otro Enter registra la entrada e imprime el ticket por la BIXOLON existente. La matrícula y la plaza quedan vacías para el siguiente vehículo. Una impresión fallida no crea una segunda entrada.

El usuario confirmó que **A corresponde al Salón Alto**. En ese grupo no se dejan llaves. En todos los demás grupos se marca automáticamente «Deja llaves». El número de llave se sustituye en el panel por el número de plaza; el ticket muestra la plaza incluso si no se dejan llaves.

Se utilizan las plazas del inventario compartido, incluidas las disponibles de A, B, C, J, LL, M, P, motos y la reserva polivalente. Se excluyen plazas fijas de abonados, bloqueadas, códigos antiguos pendientes de ubicar, vehículos dentro y plazas retenidas por estancias temporalmente fuera. La tarifa Turismo usa plazas de Turismo, Cochera las de XL, Camión las de XXL y Moto las de Moto; las polivalentes admiten las cuatro categorías. Los antiguos cupos de 30/15/5 no limitan nuevas entradas.

La ocupación se guarda en `rotation_sessions.spot_id`, con el código de plaza del momento en `spot_code`. La admisión bloquea la fila de la plaza y comprueba ocupación compartida; un índice único impide dos tickets físicos activos en una misma plaza. Los triggers también impiden asignar a una estancia una plaza ocupada en Rotación o convertir su estado de inventario en fijo/bloqueado mientras tiene un coche dentro. El planning y la disponibilidad web incluyen esta ocupación.

Los tickets anteriores se conservan sin inventar su ubicación. Si no tienen plaza, se señala en el panel y el planning; siguen descontando una unidad de capacidad de su categoría. El empleado puede localizar el vehículo en **Ocupación**, cerrar la ventana de salida si se abre, seleccionar la plaza y pulsar **Actualizar datos**. Dar salida a estos tickets sigue funcionando.

Al convertir a estancia, la plaza de Rotación se libera dentro de la misma transacción que crea y ocupa la estancia. Si fallan los bonos o la entrada, todo se revierte. No se modifica la configuración de Windows, las colas de impresión, los formatos existentes ni las tarifas.

Validación:

```sh
npm test --prefix tests
node tests/rotation-spots-ui.cjs
node tests/staff-users-api.cjs
node tests/staff-users-db.cjs
node tests/staff-users-ui.cjs
```

Las pruebas utilizan una base de datos aislada y perfiles ficticios. Cubren todos los grupos/tamaños, matrícula → plaza → entrada, limpieza de campos, regla de llaves de A, doble pulsación, código inválido, ocupación simultánea con estancias, capacidad web, cambio de plaza, salida y conversión válida/fallida con bonos. No se crean entradas ni se imprimen tickets reales durante estas pruebas.
