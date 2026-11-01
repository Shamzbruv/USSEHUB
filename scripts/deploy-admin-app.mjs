import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {fileURLToPath} from 'node:url';import webpush from 'web-push';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),filename='20261101202955_admin_app_notifications.sql';
const validate=process.argv.includes('--validate'),apply=process.argv.includes('--apply'),functionsOnly=process.argv.includes('--functions');
if(!validate&&!apply&&!functionsOnly){console.log('Dry run. Use --validate for a rolled-back schema and workflow trial, --apply to install, or --functions to redeploy the push worker. Credential is accepted only as JSON on stdin.');process.exit(0);}
const {token}=JSON.parse(fs.readFileSync(0,'utf8'));if(!token)throw new Error('Management credential required on stdin.');
async function api(endpoint,body,method){const response=await fetch('https://api.supabase.com/v1/projects/zcptuqrlovflcpqszery'+endpoint,{method:method||(body?'POST':'GET'),headers:{Authorization:`Bearer ${token}`,...body?{'Content-Type':'application/json'}:{}},body:body?JSON.stringify(body):undefined});if(!response.ok){const detail=endpoint==='/database/query'?(await response.json()).message||'Query failed':'';throw new Error('Supabase '+endpoint+': HTTP '+response.status+' '+detail);}const raw=await response.text();return raw?JSON.parse(raw):null;}
const sql=(query,read_only=false)=>api('/database/query',{query,read_only});
const source=fs.readFileSync(path.join(root,'supabase/migrations',filename),'utf8'),checksum=crypto.createHash('sha256').update(source).digest('hex'),checks=fs.readFileSync(path.join(root,'tests/admin-app.sql'),'utf8');
const installed=await sql(`SELECT checksum FROM private.ajm_schema_migrations WHERE filename='${filename}'`,true);
if(installed.length&&installed[0].checksum!==checksum)throw new Error('Installed app migration checksum mismatch. Add a new migration instead of modifying installed SQL.');
if(validate){await sql('BEGIN;'+(installed.length?'':source)+checks+'ROLLBACK;');console.log('Rolled-back app verification passed: per-admin isolation, enquiry events, device privacy, retry, spam cancellation, alert preferences, test and removal. No verification records or messages were committed.');process.exit(0);}
const before=await api('/advisors/security'),baseline=new Set((before.lints||[]).filter(l=>l.level!=='INFO').map(l=>l.cache_key));
if(apply&&!installed.length){
 const keys=webpush.generateVAPIDKeys(),dispatchSecret=crypto.randomBytes(32).toString('hex');
 // Only newly generated app keys are written. Existing email, SMTP and platform secrets are untouched.
 await api('/secrets',[{name:'USSE_ADMIN_VAPID_PUBLIC_KEY',value:keys.publicKey},{name:'USSE_ADMIN_VAPID_PRIVATE_KEY',value:keys.privateKey},{name:'USSE_ADMIN_PUSH_DISPATCH_SECRET',value:dispatchSecret}]);
 await sql(`BEGIN;${source} INSERT INTO private.admin_app_config(id,vapid_public_key) VALUES(true,'${keys.publicKey}');SELECT vault.create_secret('${dispatchSecret}','usse_admin_push_dispatch_secret','USSE admin device push dispatcher');INSERT INTO private.ajm_schema_migrations(filename,checksum) VALUES('${filename}','${checksum}');COMMIT;`);
 console.log('Admin app schema, event triggers, private device storage and dispatch credentials installed.');
}
const files=['supabase/functions/admin-push/index.ts','supabase/functions/_shared/admin-push.mjs','assets/usse-admin-app-core.mjs'],form=new FormData();for(const file of files)form.append('file',new Blob([fs.readFileSync(path.join(root,file))],{type:'application/typescript'}),file);
form.append('metadata',JSON.stringify({name:'admin-push',entrypoint_path:files[0],verify_jwt:false}));
const response=await fetch('https://api.supabase.com/v1/projects/zcptuqrlovflcpqszery/functions/deploy?slug=admin-push',{method:'POST',headers:{Authorization:`Bearer ${token}`},body:form});if(!response.ok)throw new Error('Push worker deploy HTTP '+response.status);const deployed=await response.json();if(deployed.status!=='ACTIVE')throw new Error('Push worker did not become active.');console.log('admin-push: ACTIVE, version '+deployed.version+' (authenticated by its dedicated dispatch secret)');
await sql('BEGIN;'+checks+'ROLLBACK;');
const after=await api('/advisors/security'),warnings=(after.lints||[]).filter(l=>l.level!=='INFO'&&!baseline.has(l.cache_key));console.log(JSON.stringify({workflowChecksPassed:true,verificationDataRolledBack:true,newSecurityWarnings:warnings.map(l=>({name:l.name,detail:l.detail,remediation:l.remediation}))}));if(warnings.length)throw new Error('New security warnings require review.');
