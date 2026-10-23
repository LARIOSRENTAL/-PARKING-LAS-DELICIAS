/* Gestiona la emisión de códigos temporales desde la sesión administrativa. */
function closeReinforcementCode() {
  document.getElementById('reinforcementCodeModal')?.classList.add('hidden');
}
async function generateReinforcementCode() {
  if (!currentSession || !['admin','manager'].includes(currentProfile?.role)) return;
  const button = document.getElementById('reinforcementCodeButton');
  const message = document.getElementById('reinforcementCodeMessage');
  if (button) button.disabled = true;
  message.textContent = 'Generando código…';
  try {
    const result = await db.rpc('parking_reinforcement_issue');
    if (result.error) throw result.error;
    if (!result.data?.code || !result.data?.expires_at) throw new Error('La base de datos no devolvió el código.');
    document.getElementById('reinforcementCodeValue').value = result.data.code;
    document.getElementById('reinforcementCodeExpires').textContent =
      'Válido hasta ' + new Date(result.data.expires_at).toLocaleString('es-ES', {dateStyle:'short',timeStyle:'short'}) + '.';
    message.textContent = 'Código creado. Cópialo y entrégalo a la persona de refuerzo.';
    document.getElementById('reinforcementCodeModal').classList.remove('hidden');
  } catch (error) {
    message.textContent = error.message || 'No se pudo generar el código.';
    document.getElementById('reinforcementCodeModal').classList.remove('hidden');
  } finally {
    if (button) button.disabled = false;
  }
}
async function copyReinforcementCode() {
  const field = document.getElementById('reinforcementCodeValue');
  const message = document.getElementById('reinforcementCodeMessage');
  if (!field?.value) return;
  try {
    await navigator.clipboard.writeText(field.value);
    message.textContent = 'Código copiado.';
  } catch (_) {
    field.focus();
    field.select();
    message.textContent = 'Selecciona y copia el código manualmente.';
  }
}
