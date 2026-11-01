import {createClient} from '@supabase/supabase-js';
import {dispatchLeadAlerts} from '../_shared/lead-dispatch.mjs';
import {leadAlertEmail} from '../_shared/lead-email.mjs';
import {isEmail} from '../../../assets/usse-leads-core.mjs';
const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
Deno.serve(async req=>{
 const origin=req.headers.get('Origin'),allowed=['https://ussehub.com','https://www.ussehub.com'];
 const headers={'Access-Control-Allow-Origin':allowed.includes(origin||'')?origin!:'https://ussehub.com','Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Content-Type':'application/json','Cache-Control':'no-store'};
 if(origin&&!allowed.includes(origin))return new Response('{}',{status:403,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return new Response('{}',{status:405,headers});
 const secret=Deno.env.get('LEAD_DISPATCH_SECRET');const secretAuthorized=!!secret&&req.headers.get('X-Lead-Dispatch-Secret')===secret;let authorized=secretAuthorized;
 if(!authorized){
  const token=req.headers.get('Authorization')?.replace(/^Bearer\s+/i,'');
  if(token){const {data:{user}}=await client.auth.getUser(token);if(user){const {data:p}=await client.from('profiles').select('role,account_status').eq('id',user.id).maybeSingle();authorized=p?.role==='admin'&&p?.account_status==='active';}}
 }
 if(!authorized)return new Response(JSON.stringify({error:'Authorized dispatch required.'}),{status:401,headers});
 const body=await req.json().catch(()=>({}));
 if(body.action==='test'){
  const{data:settings}=await client.from('lead_notification_settings').select('recipients').eq('id',true).single();
  // The server's deployment credential can test a synthetic email in an owned
  // QA mailbox without changing who receives genuine customer enquiries.
  const recipients=secretAuthorized&&isEmail(body.test_recipient)?[body.test_recipient]:(settings?.recipients||[]);
  if(!recipients.length)return new Response(JSON.stringify({error:'Set at least one alert recipient first.'}),{status:400,headers});
  let accepted=0;const failures: Array<{status:number;reason:string;detail:string}>=[];
  for(const recipient of recipients){
   const sample={id:'00000000-0000-4000-8000-000000000000',lead_reference:'USSE-DELIVERY-TEST',customer_name:'USSE alert delivery test',email:recipient,phone:'',notes:'TEST ONLY — your lead alert service is connected. No customer enquiry has been created by this test.',branch:'USSE',service:'Lead inbox delivery verification',source:'website',created_at:new Date().toISOString()};
   const mail=leadAlertEmail(sample,recipient);mail.subject='USSE Hub — lead alert delivery test';
   const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${Deno.env.get('RESEND_API_KEY')}`,'Content-Type':'application/json'},body:JSON.stringify(mail),signal:AbortSignal.timeout(12000)});
   if(response.ok)accepted++;else{const provider=await response.json().catch(()=>({}));failures.push({status:response.status,reason:String(provider.name||'provider_error'),detail:String(provider.message||'Email provider rejected the test.').replace(/re_[A-Za-z0-9_]+/g,'[redacted]').replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+/gi,'[address]').slice(0,250)});}
  }
  return new Response(JSON.stringify({accepted,failed:recipients.length-accepted,failures}),{status:accepted===recipients.length?200:502,headers});
 }
 try{const result=await dispatchLeadAlerts(client,{apiKey:Deno.env.get('RESEND_API_KEY'),defaultRecipients:Deno.env.get('ADMIN_NOTIFICATION_EMAIL')});return new Response(JSON.stringify(result),{headers});}
 catch{return new Response(JSON.stringify({error:'Lead alerts remain queued. Please check delivery status in the lead inbox.'}),{status:503,headers});}
});
