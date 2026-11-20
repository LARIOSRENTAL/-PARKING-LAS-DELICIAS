/* Selector de idioma para la web publica de Parking Las Delicias. */
(function(){
'use strict';
var languages={es:{flag:'🇪🇸',name:'Español'},en:{flag:'🇬🇧',name:'English'},fr:{flag:'🇫🇷',name:'Français'},it:{flag:'🇮🇹',name:'Italiano'},de:{flag:'🇩🇪',name:'Deutsch'}};
var key='parking_delicias_language';
var selected='es';
try{selected=localStorage.getItem(key)||'es'}catch(e){}
if(!languages[selected])selected='es';
var style=document.createElement('style');
style.textContent='.parking-language{position:absolute;right:max(12px,calc((100vw - 980px)/2));top:calc(13px + env(safe-area-inset-top,0px));z-index:100;text-align:left;font-family:inherit}.parking-language button{cursor:pointer;font:inherit}.parking-language-current{display:flex;align-items:center;gap:5px;padding:6px 9px;border:1px solid #d7e1ea;border-radius:9px;background:white;color:#153047;box-shadow:0 2px 8px #142c4212;font-size:23px;line-height:1}.parking-language-chevron{font-size:12px}.parking-language-menu{position:absolute;right:0;top:calc(100% + 6px);min-width:145px;background:#fff;border:1px solid #d7e1ea;border-radius:10px;box-shadow:0 12px 28px #1233;overflow:hidden}.parking-language-menu[hidden]{display:none!important}.parking-language-menu button{display:flex;align-items:center;gap:9px;border:0;background:#fff;width:100%;padding:9px 12px;color:#153047;text-align:left;font-size:14px}.parking-language-menu button:hover,.parking-language-menu button:focus-visible{background:#eef5fb}.parking-language-menu .flag{font-size:22px}.goog-te-banner-frame,.goog-te-gadget,.goog-te-gadget-simple,#goog-gt-tt,.skiptranslate{display:none!important}body{top:0!important}@media(max-width:550px){.parking-language{right:8px;top:calc(10px + env(safe-area-inset-top,0px))}.parking-language-current{font-size:20px;padding:5px}}';
document.head.appendChild(style);
function setTranslateCookie(lang){
 var val=lang==='es'?'/es/es':'/es/'+lang;
 document.cookie='googtrans='+val+';path=/;SameSite=Lax';
 var parts=location.hostname.split('.');
 if(parts.length>2){document.cookie='googtrans='+val+';path=/;domain=.'+parts.slice(-2).join('.')+';SameSite=Lax';}
}
function select(lang){if(!languages[lang])return;try{localStorage.setItem(key,lang)}catch(e){}setTranslateCookie(lang);location.reload();}
function init(){
 var header=document.querySelector('header.header')||document.querySelector('header');
 if(!header)return;
 if(getComputedStyle(header).position==='static')header.style.position='relative';
 var root=document.createElement('div');root.className='parking-language notranslate';root.setAttribute('translate','no');
 var current=document.createElement('button');current.type='button';current.className='parking-language-current';current.setAttribute('aria-label','Seleccionar idioma / Select language');current.setAttribute('aria-haspopup','true');current.setAttribute('aria-expanded','false');
 var menu=document.createElement('div');menu.className='parking-language-menu';menu.hidden=true;
 function toggle(open){menu.hidden=!open;current.setAttribute('aria-expanded',String(open));}
 current.textContent=languages[selected].flag+' ⌄';
 current.addEventListener('click',function(e){e.stopPropagation();toggle(menu.hidden);});
 Object.keys(languages).forEach(function(code){var b=document.createElement('button');b.type='button';b.innerHTML='<span class="flag">'+languages[code].flag+'</span><span>'+languages[code].name+'</span>';b.addEventListener('click',function(){select(code)});menu.appendChild(b)});
 root.appendChild(current);root.appendChild(menu);header.appendChild(root);
 document.addEventListener('click',function(e){if(!root.contains(e.target))toggle(false)});
 document.addEventListener('keydown',function(e){if(e.key==='Escape')toggle(false)});
 document.documentElement.lang=selected;
 if(selected!=='es'){
  var target=document.createElement('div');target.id='google_translate_element';target.style.display='none';document.body.appendChild(target);
  window.googleTranslateElementInit=function(){new google.translate.TranslateElement({pageLanguage:'es',includedLanguages:'en,fr,it,de',autoDisplay:false},'google_translate_element');};
  var script=document.createElement('script');script.src='https://translate.google.com/translate_a/element.js?cb=googleTranslateElementInit';script.async=true;document.head.appendChild(script);
 }
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
