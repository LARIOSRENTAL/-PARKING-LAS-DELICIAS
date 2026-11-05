/* Notes belong to the stay, including before its first parking movement. */
(function(){
 const previousHistory=openHistory;
 openHistory=async function(id,...args){
  await previousHistory(id,...args);
  const stay=reservations.find(r=>r.id===id),body=document.getElementById('historyBody');if(!stay?.notes||!body)return;
  const box=document.createElement('div');box.className='panel';box.style.whiteSpace='pre-wrap';
  const label=document.createElement('strong');label.textContent='Notas de la estancia';box.append(label,document.createElement('br'),document.createTextNode(stay.notes));body.prepend(box);
 };
})();
