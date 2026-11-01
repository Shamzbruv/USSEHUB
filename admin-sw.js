/* Deliberately network-only for administration: no customer records, tokens or API responses are cached. */
const OFFLINE_CACHE='usse-admin-offline-v1';
self.addEventListener('install',event=>event.waitUntil(caches.open(OFFLINE_CACHE).then(cache=>cache.add('/admin-offline.html')).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(names=>Promise.all(names.filter(n=>n.startsWith('usse-admin-offline-')&&n!==OFFLINE_CACHE).map(n=>caches.delete(n)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.mode==='navigate'&&url.origin===self.location.origin&&/^\/(admin-app|master-admin|lead-inbox|ajm-admin-panel|ajm-ad-management|referral-agreements)(\.html)?$/.test(url.pathname)){
  event.respondWith(fetch(event.request).catch(()=>caches.match('/admin-offline.html')));
 }
});
function safeTarget(value){
 try{const u=new URL(value,self.location.origin);return u.origin===self.location.origin&&/^\/(admin-app|master-admin|lead-inbox|ajm-admin-panel|ajm-ad-management|referral-agreements)(\.html)?$/.test(u.pathname)?u.href:new URL('/admin-app',self.location.origin).href;}catch{return new URL('/admin-app',self.location.origin).href;}
}
self.addEventListener('push',event=>{
 let data={};try{data=event.data?.json()||{};}catch{}
 event.waitUntil(Promise.all([
  self.registration.showNotification(String(data.title||'New USSE activity'),{body:String(data.body||'Open your USSE workspace to review.'),icon:'/assets/app/icon-192.png',badge:'/assets/app/badge-96.png',tag:data.id||'usse-activity',data:{url:safeTarget(data.url)},actions:[{action:'open',title:'Open workspace'}]}),
  self.navigator.setAppBadge?self.navigator.setAppBadge(Math.max(0,Number(data.unread)||0)):Promise.resolve()
 ]));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();const url=safeTarget(event.notification.data?.url);
 event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async windows=>{
  const tab=windows.find(c=>c.url===url);if(tab)return tab.focus();
  const admin=windows.find(c=>/^\/(admin-app|master-admin|lead-inbox|ajm-admin-panel|ajm-ad-management|referral-agreements)(\.html)?$/.test(new URL(c.url).pathname));
  if(admin){await admin.navigate(url);return admin.focus();}return self.clients.openWindow(url);
 }));
});
// Subscription refresh requires an authenticated administrator; do not store a login token in the worker.
self.addEventListener('pushsubscriptionchange',event=>event.waitUntil(self.clients.matchAll({type:'window'}).then(clients=>clients.forEach(c=>c.postMessage({type:'USSE_PUSH_CHANGED'})))));
