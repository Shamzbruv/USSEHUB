import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),filename='20261101020019_lead_spam_protection.sql';
const validate=process.argv.includes('--validate'),apply=process.argv.includes('--apply');
if(!validate&&!apply){console.log('Dry run: additive lead spam controls. Use --validate or --apply with a JSON management credential on stdin.');process.exit(0);}
const {token}=JSON.parse(fs.readFileSync(0,'utf8'));if(!token)throw new Error('Management credential required on stdin.');
async function api(endpoint,body){const response=await fetch('https://api.supabase.com/v1/projects/zcptuqrlovflcpqszery'+endpoint,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,...body?{'Content-Type':'application/json'}:{}},body:body?JSON.stringify(body):undefined});if(!response.ok)throw new Error('Supabase '+endpoint+': HTTP '+response.status);return response.json();}
const sql=(query,read_only=false)=>api('/database/query',{query,read_only});
const source=fs.readFileSync(path.join(root,'supabase/migrations',filename),'utf8'),checksum=crypto.createHash('sha256').update(source).digest('hex');
const assertions=`DO $check$ BEGIN
 IF has_function_privilege('anon','public.capture_usse_lead(jsonb,uuid,text,text)','EXECUTE') OR has_function_privilege('authenticated','public.capture_usse_lead(jsonb,uuid,text,text)','EXECUTE') THEN RAISE EXCEPTION 'Public intake bypass';END IF;
 IF has_function_privilege('anon','public.admin_manage_lead_spam(text,jsonb)','EXECUTE') OR has_table_privilege('authenticated','private.lead_spam_blocks','SELECT') THEN RAISE EXCEPTION 'Spam controls exposed';END IF;
 IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='private' AND c.relname IN ('lead_spam_blocks','lead_submission_guard','lead_spam_counts') AND c.relrowsecurity)<>3 THEN RAISE EXCEPTION 'RLS protection missing';END IF;
END $check$;`;
if(validate){await sql('BEGIN;'+source+assertions+'ROLLBACK;');console.log('Live-schema trial passed and was rolled back. No leads or alerts changed.');process.exit(0);}
const before=await api('/advisors/security');const baseline=new Set((before.lints||[]).filter(l=>l.level!=='INFO').map(l=>l.cache_key));
const installed=await sql(`SELECT checksum FROM private.ajm_schema_migrations WHERE filename='${filename}'`,true);
if(installed.length){if(installed[0].checksum!==checksum)throw new Error('Installed migration checksum mismatch.');console.log('Spam migration already installed.');}
else{await sql(`BEGIN;${source}${assertions} INSERT INTO private.ajm_schema_migrations(filename,checksum) VALUES('${filename}','${checksum}');COMMIT;`);console.log('Spam protection schema, guard and administration RPC installed.');}
await sql(assertions);const after=await api('/advisors/security');
const newWarnings=(after.lints||[]).filter(l=>l.level!=='INFO'&&!baseline.has(l.cache_key));
console.log(JSON.stringify({privateTablesRLS:true,publicWriteBypass:false,newSecurityWarnings:newWarnings.map(l=>({name:l.name,detail:l.detail,remediation:l.remediation}))}));
if(newWarnings.length)throw new Error('New security warnings require review.');
