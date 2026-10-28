/* A keyboard-wedge reader's suffix must never confirm a payment. */
(function(){
 let burst=null,lastCharacter=-Infinity;
 function checkoutOpen(){const modal=document.getElementById('rotationCheckoutModal');return modal&&!modal.classList.contains('hidden')&&getComputedStyle(modal).display!=='none'?modal:null;}
 window.addEventListener('keydown',event=>{
  const modal=checkoutOpen();
  if(!modal||!modal.contains(event.target)){burst=null;lastCharacter=-Infinity;return;}
  if(event.ctrlKey||event.altKey||event.metaKey||event.isComposing)return;
  const now=performance.now(),target=event.target;
  if(event.key.length===1){
   if(!burst||now-burst.last>100||burst.target!==target)burst={text:'',first:now,last:now,target,before:typeof target.value==='string'?target.value:null};
   burst.text+=event.key;burst.last=now;lastCharacter=now;return;
  }
  if(event.key==='Shift')return;
  if(event.key==='Enter'||event.key==='Tab'){
   const sameTicket=burst&&typeof currentRotationSession!=='undefined'&&currentRotationSession&&burst.text.toUpperCase().replace(/[^A-Z0-9]/g,'')===String(currentRotationSession.plate||'').toUpperCase().replace(/[^A-Z0-9]/g,'');
   const fast=burst&&burst.text.length>=3&&now-burst.last<150&&burst.last-burst.first<burst.text.length*45;
   // Also guard a short/slow scan suffix or an Enter immediately after editing.
   const recent=now-lastCharacter<300;
   if(fast||sameTicket||(event.key==='Enter'&&recent)){
    event.preventDefault();event.stopImmediatePropagation();
    if((fast||sameTicket)&&burst.before!==null&&burst.target instanceof HTMLInputElement&&!burst.target.readOnly&&!['checkbox','radio','button','submit'].includes(burst.target.type)){
     burst.target.value=burst.before;
     burst.target.dispatchEvent(new Event('input',{bubbles:true}));
    }
    if(fast||sameTicket){let status=document.getElementById('rotationRescanStatus');if(!status){status=document.createElement('p');status.id='rotationRescanStatus';status.className='muted';status.setAttribute('role','status');modal.querySelector('.modalBody').appendChild(status);}status.textContent='Ticket leído. El cobro sigue pendiente: revisa los datos y confirma o cancela.';}
    burst=null;return;
   }
   burst=null;
  }else burst=null;
 },true);
})();
