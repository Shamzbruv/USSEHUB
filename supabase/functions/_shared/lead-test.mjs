import {leadAlertEmail} from './lead-email.mjs';

// A failed recipient must not hide successful sends or stop the remaining tests.
export async function testLeadAlerts(recipients,{apiKey,fetchImpl=fetch}={}){
 const results=[];const key=String(apiKey||'').trim();
 for(const recipient of recipients){
  if(!key){results.push({recipient,accepted:false,status:0,reason:'missing_api_key',detail:'RESEND_API_KEY is not configured in Edge Function secrets.'});continue;}
  try{
   const sample={id:'00000000-0000-4000-8000-000000000000',lead_reference:'USSE-DELIVERY-TEST',customer_name:'USSE alert delivery test',email:recipient,phone:'',notes:'TEST ONLY — your lead alert service is connected. No customer enquiry has been created by this test.',branch:'USSE',service:'Lead inbox delivery verification',source:'website',created_at:new Date().toISOString()};
   const mail=leadAlertEmail(sample,recipient);mail.subject='USSE Hub — lead alert delivery test';
   const response=await fetchImpl('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:JSON.stringify(mail),signal:AbortSignal.timeout(12000)});
   const provider=await response.json().catch(()=>({}));
   if(response.ok&&typeof provider.id==='string')results.push({recipient,accepted:true,status:response.status});
   else results.push({recipient,accepted:false,status:response.status,reason:String(provider.name||'provider_error'),detail:String(provider.message||'Email provider rejected the test.').replace(/re_[A-Za-z0-9_]+/g,'[redacted]').replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+/gi,'[address]').slice(0,250)});
  }catch{results.push({recipient,accepted:false,status:0,reason:'connection_error',detail:'The email provider could not be reached. Please try the test again.'});}
 }
 const accepted=results.filter(r=>r.accepted).length;
 return {accepted,failed:results.length-accepted,results,failures:results.filter(r=>!r.accepted)};
}
