// Run from the GitHub checkout with a short-lived Supabase management token.
// Never reads or changes SMTP credentials or Edge Function secrets.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {authEmailConfig} from './email-templates.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const ref = process.env.SUPABASE_PROJECT_REF || 'zcptuqrlovflcpqszery';
const token = process.env.SUPABASE_ACCESS_TOKEN;
const apply = process.argv.includes('--apply');
const config = authEmailConfig();
const slugs = ['notify-admin','submit-consultation'];
if (!apply) {
  console.log(`Dry run: ${Object.keys(config).filter(k=>k.endsWith('_content')).length} branded Auth templates, sender name USSE Hub and ${slugs.length} notification functions. Add --apply to deploy.`);
  process.exit(0);
}
if (!token || !/^[a-z]{20}$/.test(ref)) throw new Error('A valid SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN are required.');
async function api(endpoint,options={}) {
  const response=await fetch(`https://api.supabase.com/v1/projects/${ref}${endpoint}`,{...options,headers:{Authorization:`Bearer ${token}`,...options.headers}});
  if (!response.ok) throw new Error(`Supabase ${endpoint}: HTTP ${response.status}`);
  return response.json();
}
const before=await api('/config/auth');
await api('/config/auth',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify(config)});
const after=await api('/config/auth');
for (const [key,value] of Object.entries(config)) if (after[key] !== value) throw new Error(`Auth branding verification failed: ${key}`);
for (const key of ['mailer_autoconfirm','site_url','uri_allow_list',...Object.keys(before).filter(k=>k.startsWith('mailer_notifications_'))]) {
  if (JSON.stringify(before[key])!==JSON.stringify(after[key])) throw new Error(`Unrelated Auth setting changed: ${key}`);
}
console.log('Verified: all 13 Auth email templates and branded sender name are live.');
for (const slug of slugs) {
  const form=new FormData();
  const entry=`supabase/functions/${slug}/index.ts`;
  for (const relative of [entry,'supabase/functions/_shared/email.mjs','supabase/functions/email-import-map.json']) {
    form.append('file',new Blob([fs.readFileSync(path.join(root,relative))],{type:relative.endsWith('.json')?'application/json':'application/typescript'}),relative);
  }
  // Preserve the existing gateway JWT enforcement; webhook/CAPTCHA checks stay
  // inside the handlers. Imports are pinned in the committed import map.
  form.append('metadata',JSON.stringify({name:slug,entrypoint_path:entry,import_map_path:'supabase/functions/email-import-map.json',verify_jwt:true}));
  const deployed=await api(`/functions/deploy?slug=${encodeURIComponent(slug)}`,{method:'POST',body:form});
  if (deployed.status!=='ACTIVE') throw new Error(`Function ${slug} did not become active.`);
  console.log(`Verified: ${slug} is active, version ${deployed.version}.`);
}
