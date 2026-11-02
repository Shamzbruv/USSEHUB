export const APP_CATEGORIES={enquiries:'Enquiries & follow-ups',members:'Members & account access',listings:'Directory listings',commerce:'Orders, payments & advertising',referrals:'Partners & referrals',system:'JobZone & app notices'};
export function safeAdminPath(value){
 const url=new URL(String(value||'/admin-app'),'https://ussehub.com');
 const paths=['/admin-app','/master-admin','/lead-inbox','/ajm-admin-panel','/ajm-ad-management','/referral-agreements','/ajm-marketplace-admin','/ajm-jobzone-admin'];
 return url.origin==='https://ussehub.com'&&paths.some(p=>url.pathname===p||url.pathname===p+'.html')?url.pathname+url.search+url.hash:'/admin-app';
}
export function allowedPushEndpoint(value){
 try{const url=new URL(value);return url.protocol==='https:'&&!url.username&&!url.password&&!url.port&&!url.hash&&url.pathname!=='/'&&
  (url.hostname==='fcm.googleapis.com'||url.hostname==='updates.push.services.mozilla.com'||/^[a-z0-9-]+\.push\.apple\.com$/.test(url.hostname)||/^[a-z0-9.-]+\.notify\.windows\.com$/.test(url.hostname));}catch{return false;}
}
export const pushResult=status=>status>=200&&status<300?'accepted':[404,410].includes(status)?'gone':'failed';
export function pushPayload(input){return JSON.stringify({id:input.id,title:String(input.title||'USSE activity').slice(0,100),body:String(input.body||'Open your USSE workspace to review.').slice(0,180),url:safeAdminPath(input.url),category:input.category,unread:Math.max(0,Number(input.unread)||0)});}
