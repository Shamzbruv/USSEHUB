import {leadAlertEmail} from './lead-email.mjs';
import {isEmail} from '../../../assets/usse-leads-core.mjs';
export async function dispatchLeadAlerts(client,{apiKey,defaultRecipients='',fetchImpl=fetch}={}){
 apiKey=String(apiKey||'').trim();
 const recipients=String(defaultRecipients).split(/[,;\n]+/).map(s=>s.trim().toLowerCase()).filter(isEmail).slice(0,10);
 const init=await client.rpc('process_lead_mail',{p_action:'initialize',p_payload:{recipients}});if(init.error)throw new Error('Lead alert setup unavailable.');
 if(!apiKey)return {accepted:0,failed:0,configured:false};
 const {data:jobs,error}=await client.rpc('process_lead_mail',{p_action:'claim',p_payload:{}});if(error)throw new Error('Lead alert queue unavailable.');
 let accepted=0,failed=0;
 await Promise.all((jobs||[]).map(async({delivery,lead})=>{
  let ok=false,providerId=null,errorMessage=null;
  try{
   const response=await fetchImpl('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${apiKey}`,'Content-Type':'application/json','Idempotency-Key':`usse-lead-${delivery.id}`},body:JSON.stringify(leadAlertEmail(lead,delivery.recipient_email)),signal:AbortSignal.timeout(12000)});
   const body=await response.json().catch(()=>({}));ok=response.ok&&typeof body.id==='string';providerId=ok?body.id:null;
   if(!ok)errorMessage=`Email provider returned HTTP ${response.status}. ${response.status===401||response.status===403?'Check the sending credential and verified sender domain.':'The alert will retry automatically.'}`;
  }catch{errorMessage='Email provider connection timed out or failed. The alert will retry automatically.';}
  const result=await client.rpc('process_lead_mail',{p_action:'finish',p_payload:{id:delivery.id,claim:delivery.claim_token,accepted:ok,provider_id:providerId,error:errorMessage}});
  if(result.error)throw new Error('Could not record alert delivery status.');if(ok)accepted++;else failed++;
 }));
 return {accepted,failed,configured:init.data?.configured===true};
}
