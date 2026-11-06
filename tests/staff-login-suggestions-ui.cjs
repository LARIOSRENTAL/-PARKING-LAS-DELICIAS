const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const root=path.join(__dirname,'../backoffice'),html=fs.readFileSync(path.join(root,'index.html'),'utf8'),script=fs.readFileSync(path.join(root,'subscriber-collection-login.js'),'utf8'),key='pld_staff_login_usernames';
function setup(saved,blocked=false){
 const dom=new JSDOM(html,{url:'https://lariosrental.github.io/-PARKING-LAS-DELICIAS/backoffice/',runScripts:'outside-only'}),w=dom.window,d=w.document;
 if(saved!==undefined)w.localStorage.setItem(key,saved);
 if(blocked)Object.defineProperty(w,'localStorage',{get(){throw Error('Storage unavailable');}});
 let accepted=true,active=true;
 Object.assign(w,{currentSession:null,currentProfile:null,openingShift:false,currentAccessMode:null,esc:x=>String(x),syncParkingReportButtons:()=>{},boot:async()=>{},db:{auth:{signInWithPassword:async()=>accepted?{data:{session:{user:{id:'employee',email:d.getElementById('loginEmail').value}}}}:{error:{message:'Wrong password'}},signOut:async()=>{}},from:()=>({select(){return this;},eq(){return this;},maybeSingle:async()=>({data:{active,role:'employee'}})}),rpc:async()=>({data:{}})}});
 const start=html.indexOf('async function login(){'),end=html.indexOf('async function chooseManagerAccess',start);
 w.eval(html.slice(start,end));w.eval(script);
 return {dom,w,d,accepted:value=>accepted=value,active:value=>active=value};
}
(async()=>{
 const env=setup(),{w,d}=env,email=d.getElementById('loginEmail'),password=d.getElementById('loginPass'),search=d.getElementById('subscriberSearch');
 assert.equal(email.autocomplete,'username');assert.equal(email.form.id,'staffLoginForm');assert.equal(password.autocomplete,'current-password');assert.equal(search.autocomplete,'off');assert.equal(search.form.getAttribute('autocomplete'),'off');assert.notEqual(search.form,email.form);assert(!search.hasAttribute('list'));
 email.value='first@example.com';password.value='NeverStoreThisPassword';await w.login();assert.deepEqual(JSON.parse(w.localStorage.getItem(key)),['first@example.com']);
 email.value='second@example.com';await w.login();email.value='first@example.com';await w.login();assert.deepEqual(JSON.parse(w.localStorage.getItem(key)),['first@example.com','second@example.com']);
 env.accepted(false);email.value='wrong@example.com';await w.login();assert(!w.localStorage.getItem(key).includes('wrong@example.com'));
 env.accepted(true);env.active(false);email.value='inactive@example.com';await w.login();assert(!w.localStorage.getItem(key).includes('inactive@example.com'));
 assert(!w.localStorage.getItem(key).includes(password.value));assert.equal(d.querySelectorAll('#staffLoginUsernames option').length,2);
 const saved=w.localStorage.getItem(key),reload=setup(saved);assert.deepEqual([...reload.d.querySelectorAll('#staffLoginUsernames option')].map(x=>x.value),['first@example.com','second@example.com']);reload.dom.window.close();
 w.localStorage.setItem(key,'["third@example.com"]');w.dispatchEvent(new w.StorageEvent('storage',{key}));assert.equal(d.querySelector('#staffLoginUsernames option').value,'third@example.com');env.dom.window.close();
 const corrupt=setup('{broken');assert.equal(corrupt.d.querySelectorAll('#staffLoginUsernames option').length,0);corrupt.dom.window.close();
 const blocked=setup(undefined,true);blocked.d.getElementById('loginEmail').value='valid@example.com';await blocked.w.login();assert.equal(blocked.w.currentProfile.role,'employee');blocked.dom.window.close();
 console.log('PASS: successful active staff logins are suggested after reload; failed/inactive logins and passwords are not stored; subscriber search stays isolated; blocked storage does not prevent login.');
})().catch(error=>{console.error(error);process.exitCode=1;});
