// Deploy committed function sources without changing schema, recipients or secrets.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
if(!process.argv.includes('--apply')){console.log('Dry run: deploy lead intake, dispatch and consultation alias only. Use --apply with the management credential as JSON on stdin.');process.exit(0);}
const {token}=JSON.parse(fs.readFileSync(0,'utf8'));if(!token)throw new Error('Management credential required on stdin.');
const shared=['supabase/functions/_shared/lead-intake.mjs','supabase/functions/_shared/lead-dispatch.mjs','supabase/functions/_shared/lead-test.mjs','supabase/functions/_shared/lead-email.mjs','supabase/functions/_shared/email.mjs','assets/usse-leads-core.mjs','supabase/functions/email-import-map.json','supabase/functions/capture-lead/index.ts'];
for(const [slug,verify_jwt] of [['capture-lead',false],['dispatch-lead-alerts',false],['submit-consultation',true]]){
 const entry=`supabase/functions/${slug}/index.ts`,form=new FormData();
 for(const file of new Set([entry,...shared]))form.append('file',new Blob([fs.readFileSync(path.join(root,file))],{type:file.endsWith('.json')?'application/json':'application/typescript'}),file);
 form.append('metadata',JSON.stringify({name:slug,entrypoint_path:entry,import_map_path:'supabase/functions/email-import-map.json',verify_jwt}));
 const response=await fetch(`https://api.supabase.com/v1/projects/zcptuqrlovflcpqszery/functions/deploy?slug=${slug}`,{method:'POST',headers:{Authorization:`Bearer ${token}`},body:form});
 if(!response.ok)throw new Error(`${slug}: deployment HTTP ${response.status}`);
 const deployed=await response.json();if(deployed.status!=='ACTIVE')throw new Error(`${slug}: deployment not active`);
 console.log(`${slug}: ACTIVE, version ${deployed.version}`);
}
