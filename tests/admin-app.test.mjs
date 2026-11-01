import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';import crypto from 'node:crypto';import webpush from 'web-push';
import {allowedPushEndpoint,pushResult,pushPayload,safeAdminPath} from '../assets/usse-admin-app-core.mjs';
import {dispatchAdminPush} from '../supabase/functions/_shared/admin-push.mjs';
assert.equal(allowedPushEndpoint('https://fcm.googleapis.com/fcm/send/example'),true);
assert.equal(allowedPushEndpoint('https://web.push.apple.com/example'),true);
assert.equal(allowedPushEndpoint('https://updates.push.services.mozilla.com/wpush/v2/test'),true);
for(const endpoint of ['http://fcm.googleapis.com/fcm/send/x','https://fcm.googleapis.com.evil.test/x','https://fcm.googleapis.com:444/x','https://fcm.googleapis.com@127.0.0.1/x','https://127.0.0.1/private','https://web.push.apple.com/x#secret'])assert.equal(allowedPushEndpoint(endpoint),false,endpoint);
assert.equal(safeAdminPath('https://evil.test/lead-inbox'),'/admin-app');assert.equal(safeAdminPath('/lead-inbox?lead=abc'),'/lead-inbox?lead=abc');assert.equal(safeAdminPath('/ajm-advertising-hub'),'/admin-app');
assert.deepEqual([201,204,410,404,429,401,500].map(pushResult),['accepted','accepted','gone','gone','failed','failed','failed']);
assert.equal(JSON.parse(pushPayload({url:'https://evil.test',notes:'private',email:'private'})).url,'/admin-app');assert.ok(!pushPayload({notes:'private',email:'private'}).includes('private'));
const device=crypto.createECDH('prime256v1');device.generateKeys();const keys=webpush.generateVAPIDKeys(),subscription={endpoint:'https://fcm.googleapis.com/fcm/send/test',keys:{p256dh:device.getPublicKey().toString('base64url'),auth:crypto.randomBytes(16).toString('base64url')}};
const details=webpush.generateRequestDetails(subscription,pushPayload({id:'test',url:'/lead-inbox?lead=test',title:'New enquiry received'}),{TTL:3600,vapidDetails:{subject:'mailto:info@ussehub.com',...keys}});
assert.equal(details.headers['Content-Encoding'],'aes128gcm');assert.equal(details.headers.TTL,3600);assert.ok(details.body.length>100);assert.ok(details.headers.Authorization.startsWith('vapid '));
let jobs=[201,429,410,0].map((status,i)=>({id:String(i),claim_token:'claim-'+i,subscription,payload:{id:'event-'+i,url:'/admin-app'},status})),completed=[];
const outcome=await dispatchAdminPush({rpc:async(action,payload)=>action==='claim'?{data:jobs}:{data:completed.push(payload)},send:async(sub,payload)=>{const i=Number(JSON.parse(payload).id.split('-')[1]);if(!jobs[i].status)throw new Error('network offline');return jobs[i].status;}});
assert.deepEqual(outcome,{processed:4,accepted:1,expired:1,failed:2});assert.deepEqual(completed.map(r=>r.result),['accepted','failed','gone','failed']);assert.ok(completed.every(r=>r.claim_token==='claim-'+r.id));
let sent=false;jobs=[{id:'bad',claim_token:'x',subscription:{endpoint:'https://127.0.0.1/private'},payload:{}}];await dispatchAdminPush({rpc:async a=>a==='claim'?{data:jobs}:{},send:async()=>{sent=true;return 200;}});assert.equal(sent,false,'SSRF endpoint reached sender');
await assert.rejects(dispatchAdminPush({rpc:async()=>({error:{message:'db'}}),send:async()=>201}),/claim/);
// Exercise worker events without a browser: network-only privacy, push display and safe click routing.
const handlers={},shown=[],opened=[],network=[],cached=[];
const scope={location:{origin:'https://ussehub.com'},navigator:{setAppBadge:async()=>{}},registration:{showNotification:async(...args)=>shown.push(args)},addEventListener:(type,fn)=>handlers[type]=fn,clients:{matchAll:async()=>[],openWindow:async url=>opened.push(url)}};
vm.runInNewContext(fs.readFileSync(new URL('../admin-sw.js',import.meta.url),'utf8'),{self:scope,URL,Promise,caches:{match:async url=>cached.push(url)},fetch:async req=>network.push(req)});
let pending;handlers.push({data:{json:()=>({title:'New enquiry received',url:'https://evil.test/steal',id:'one',unread:2})},waitUntil:p=>pending=p});await pending;assert.equal(shown[0][1].data.url,'https://ussehub.com/admin-app');
handlers.notificationclick({notification:{close(){},data:{url:'/lead-inbox?lead=123'}},waitUntil:p=>pending=p});await pending;assert.equal(opened[0],'https://ussehub.com/lead-inbox?lead=123');
handlers.fetch({request:{url:'https://zcptuqrlovflcpqszery.supabase.co/rest/v1/admin_app_notifications',mode:'cors'},respondWith(){throw new Error('API response intercepted');}});
handlers.fetch({request:{url:'https://ussehub.com/index.html',mode:'navigate'},respondWith(){throw new Error('Public navigation intercepted');}});
handlers.fetch({request:{url:'https://ussehub.com/admin-app',mode:'navigate'},respondWith:p=>pending=p});await pending;assert.equal(network.length,1);assert.equal(cached.length,0);
const manifest=JSON.parse(fs.readFileSync(new URL('../admin-app.webmanifest',import.meta.url),'utf8'));assert.equal(manifest.display,'standalone');assert.equal(manifest.scope,'/');assert.ok(manifest.start_url.startsWith('/admin-app'));
for(const icon of manifest.icons)assert.ok(fs.existsSync(new URL('..'+icon.src,import.meta.url)));
const routes=JSON.parse(fs.readFileSync(new URL('../serve.json',import.meta.url),'utf8'));assert.ok(routes.rewrites.some(r=>r.source==='/admin-app'));assert.ok(routes.headers.some(h=>h.source==='admin-sw.js'&&h.headers.some(x=>x.key==='Cache-Control'&&x.value==='no-cache')));
console.log('Admin app passed: encrypted push request, provider failures, retries, SSRF and URL protection, worker events, network-only records, manifest and icons.');
// Verify the exact production static handler without requiring OS network-interface enumeration.
const {default:serveHandler}=await import('serve-handler');const {Writable}=await import('node:stream');
async function served(url){const chunks=[],headers={};const response=new Writable({write(chunk,encoding,callback){chunks.push(Buffer.from(chunk));callback();}});response.setHeader=(k,v)=>headers[k.toLowerCase()]=v;response.writeHead=(status,h)=>{response.statusCode=status;for(const[k,v]of Object.entries(h||{}))response.setHeader(k,v);};const finished=new Promise((resolve,reject)=>{response.on('finish',resolve);response.on('error',reject);});await serveHandler({url,method:'GET',headers:{}},response,{...routes,public:new URL('..',import.meta.url).pathname});await finished;return {status:response.statusCode,headers,body:Buffer.concat(chunks).toString()};}
for(const url of ['/admin-app?source=installed','/admin-app.html?source=installed']){const r=await served(url);assert.equal(r.status,200);assert.ok(r.body.includes('<title>USSE Hub · Your operations app</title>'));assert.equal(r.headers.location,undefined);}
const sw=await served('/admin-sw.js');assert.equal(sw.headers['cache-control'],'no-cache');assert.equal(sw.headers['service-worker-allowed'],'/');const mf=await served('/admin-app.webmanifest');assert.equal(mf.headers['content-type'],'application/manifest+json');
console.log('Production handler passed: app routes preserve queries; manifest and worker headers are correct.');
for(const rewrite of routes.rewrites.filter(r=>r.source!=='/')){const r=await served(rewrite.source+'?verification=preserved');assert.equal(r.status,200,rewrite.source);assert.equal(r.headers.location,undefined,rewrite.source);assert.equal(r.body,fs.readFileSync(new URL('..'+rewrite.destination,import.meta.url),'utf8'),rewrite.source);}
console.log('All existing static route rewrites passed against the production handler.');
