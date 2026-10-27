import assert from 'node:assert/strict';
import fs from 'node:fs';
import {passwordProblem,authErrorMessage,authRedirectURL,deferAuthChanges,createAuthUI} from '../assets/usse-auth.mjs';
assert.match(passwordProblem('short'),/8/);assert.match(passwordProblem('longpassword'),/uppercase/);assert.equal(passwordProblem('Strong-Password9'),'');
assert.match(authErrorMessage({message:'Error sending confirmation email'}),/could not send/);
assert.match(authErrorMessage({code:'email_not_confirmed'}),/Confirm your email/);
assert.equal(authRedirectURL('https://ussehub.com','recovery'),'https://ussehub.com/ajm-advertising-hub?auth=recovery');
let listener,callbacks=0;const deferred=[];
deferAuthChanges({auth:{onAuthStateChange:fn=>{listener=fn;}}},async()=>callbacks++,()=>assert.fail('unexpected callback error'),fn=>deferred.push(fn));
assert.equal(listener('SIGNED_IN',{user:{id:'member'}}),undefined);assert.equal(callbacks,0);await deferred[0]();assert.equal(callbacks,1,'Database work must run after the auth callback releases its lock');
class Element {
  constructor(){this.value='';this.disabled=false;this.hidden=false;this.textContent='';this.style={};this.attrs={};this.events={};this.classes=new Set();this.classList={add:v=>this.classes.add(v),remove:v=>this.classes.delete(v),contains:v=>this.classes.has(v)};}
  setAttribute(k,v){this.attrs[k]=v;}removeAttribute(k){delete this.attrs[k];}focus(){this.focused=true;}addEventListener(k,v){this.events[k]=v;}checkValidity(){return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.value);}
}
function fixture(url='https://ussehub.com/ajm-advertising-hub') {
 const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};const calls=[],toasts=[],history=[];let session=null,authListener;
 const api={};for(const name of ['signUp','signInWithPassword','resetPasswordForEmail','resend','updateUser','signOut'])api[name]=async payload=>{calls.push({name,payload});return{data:{user:{id:'member'}},error:null};};
 api.getSession=async()=>({data:{session},error:null});api.onAuthStateChange=cb=>{authListener=cb;};
 const location=new URL(url);const ui=createAuthUI({client:{auth:api},document:{getElementById:get,querySelector:()=>get('tabs')},location,history:{replaceState:(...args)=>history.push(args)},onSignedIn:async()=>calls.push({name:'hydrate'}),onSignedOut:()=>calls.push({name:'signedOut'}),showToast:(...args)=>toasts.push(args),openModal:()=>calls.push({name:'openModal'}),closeModal:()=>calls.push({name:'closeModal'})});
 return{ui,get,calls,toasts,history,api,setSession:value=>session=value,event:(...args)=>authListener(...args)};
}
const f=fixture();f.get('modal-reg-name').value='New member';f.get('modal-reg-email').value='member@example.com';f.get('modal-reg-password').value='Strong-Password9';f.get('modal-reg-password-confirm').value='Strong-Password9';
let finish;f.api.signUp=payload=>{f.calls.push({name:'signUp',payload});return new Promise(resolve=>finish=resolve);};
const registration=f.ui.register();assert.equal(f.get('modal-reg-btn').disabled,true);await f.ui.register();assert.equal(f.calls.filter(c=>c.name==='signUp').length,1);
finish({data:null,error:{message:'Error sending confirmation email'}});await registration;
assert.equal(f.get('modal-reg-btn').disabled,false);assert.match(f.get('register-error').textContent,/could not send/);assert.equal(f.get('register-success').textContent,'');
f.api.signUp=async payload=>{f.calls.push({name:'signUp',payload});return{data:{user:{id:'member'},session:null},error:null};};
await f.ui.register();assert.match(f.get('register-success').textContent,/Check your inbox/);assert.equal(f.get('auth-confirmation-tools').hidden,false);assert.equal(f.get('modal-reg-password-confirm').value,'');
assert.match(f.calls.filter(c=>c.name==='signUp').at(-1).payload.options.emailRedirectTo,/auth=confirmed$/);
await f.ui.resend();await f.ui.resend();assert.equal(f.calls.filter(c=>c.name==='resend').length,1,'Confirmation resends must observe the cooldown');
f.get('sidebar-email').value='member@example.com';f.get('sidebar-password').value='Strong-Password9';f.api.signInWithPassword=async()=>{throw new TypeError('Failed to fetch');};await f.ui.sidebarLogin();assert.equal(f.get('sidebar-login-btn').disabled,false);assert.match(f.get('sidebar-login-error').textContent,/connection/);
const recovery=fixture('https://ussehub.com/ajm-advertising-hub?auth=recovery&advertise=1');recovery.setSession({user:{id:'member'}});await recovery.ui.init();assert.equal(recovery.get('auth-panel-reset').style.display,'block');assert.match(recovery.history.at(-1)[2],/advertise=1/);
recovery.get('modal-reset-password').value='Updated-Password7';recovery.get('modal-reset-confirm').value='Updated-Password7';await recovery.ui.reset();assert.equal(recovery.calls.filter(c=>c.name==='updateUser').length,1);assert.match(recovery.toasts.at(-1)[0],/password has been updated/);
const expired=fixture('https://ussehub.com/ajm-advertising-hub?auth=recovery');await expired.ui.init();assert.match(expired.get('forgot-error').textContent,/expired/);assert.equal(expired.get('tab-forgot').attrs['aria-selected'],'true');assert.equal(expired.get('tab-login').attrs['aria-selected'],'false');await expired.ui.reset();assert.equal(expired.calls.filter(c=>c.name==='updateUser').length,0);
const html=fs.readFileSync('ajm-advertising-hub.html','utf8');assert.ok(html.includes('await authUI.init()'));assert.ok(!/onAuthStateChange\(async/.test(html));
console.log('Auth flows passed: email failure/retry, duplicate clicks, password rules, confirmation resend, recovery, network recovery and deferred session callbacks.');
