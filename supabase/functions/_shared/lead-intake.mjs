import {normalizeLead} from '../../../assets/usse-leads-core.mjs';
const ORIGINS=['https://ussehub.com','https://www.ussehub.com'];
const sha=async value=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(b=>b.toString(16).padStart(2,'0')).join('');
export function createLeadHandler({client,dispatchSecret,dispatch,waitUntil}){
 return async req=>{
  const origin=req.headers.get('Origin'),headers={'Access-Control-Allow-Origin':ORIGINS.includes(origin)?origin:ORIGINS[0],'Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
  const reply=(status,body)=>new Response(JSON.stringify(body),{status,headers});
  if(origin&&!ORIGINS.includes(origin))return reply(403,{error:'This form can only be submitted from USSE Hub.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'Use the enquiry form to submit your request.'});
  let input,data;
  try{const text=await req.text();if(text.length>16000)return reply(413,{error:'Your enquiry is too long.'});input=JSON.parse(text);if(input.website_url)return reply(400,{error:'Request could not be verified.'});data=normalizeLead(input);if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input.request_id||''))throw new Error('Please refresh the form and try again.');}catch(error){return reply(400,{error:error instanceof SyntaxError?'Invalid enquiry.':error.message});}
  if(!dispatchSecret)return reply(503,{error:'The enquiry service is temporarily unavailable. Please call 876-422-1277.'});
  try{
   const fingerprint=await sha(JSON.stringify(data)),ip=req.headers.get('cf-connecting-ip')||req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()||'unknown';
   const {data:receipt,error}=await client.rpc('capture_usse_lead',{p_data:data,p_request_id:input.request_id,p_fingerprint:fingerprint,p_ip_hash:await sha(dispatchSecret+'|'+ip)});
   if(error){const status=error.code==='P0429'?429:error.code==='23505'?409:400;return reply(status,{error:/too many|already been used|not available/i.test(error.message)?error.message:'Could not save your enquiry. Please check your details and try again.'});}
   const pending=dispatch().catch(()=>{console.error('Lead alert dispatch deferred to the retry queue.');});if(waitUntil)waitUntil(pending);else await pending;
   return reply(receipt.created?201:200,{...receipt,saved:true,message:'Your enquiry is saved. The USSE team will follow up using your contact details.'});
  }catch{return reply(503,{error:'Could not confirm that your enquiry was saved. Please retry; the same request will not create a duplicate.'});}
 };
}
