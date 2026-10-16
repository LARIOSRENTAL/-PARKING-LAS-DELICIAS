# Finalización manual de estancias

Una estancia iniciada conserva su plaza hasta «Finalizar estancia», tanto dentro como fuera y aunque haya vencido su hora prevista. La fecha prevista sigue visible y permite destacar el tiempo excedido. El listado total, su impresión y el planning incluyen las estancias vencidas sin finalizar.

«Marcar salida» registra una salida temporal y conserva la plaza. El vehículo puede volver a entrar después de la fecha prevista. PostgreSQL impide dar esa plaza a otro vehículo, incluso si se utiliza una pantalla antigua.

«Finalizar estancia» pide confirmación, registra quién y cuándo la termina, añade una nota al histórico y libera la plaza. Si está dentro, registra también su salida. Si está dentro y excedió el periodo contratado, conserva el tratamiento existente del exceso mediante Rotación, activado solo al finalizar explícitamente. Si ya estaba fuera, finalizar no inventa una salida nueva ni genera ese recargo.

La finalización es idempotente: repetir la petición no duplica el registro ni el cargo de Rotación. Se mantienen los permisos de empleado con turno abierto y administrador. No se reactivan estancias históricas ya terminadas ni se modifican cobros anteriores.
