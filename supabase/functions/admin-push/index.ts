import {createClient} from 'npm:@supabase/supabase-js@2.108.2';
import webpush from 'npm:web-push@3.6.7';
import {dispatchAdminPush} from '../_shared/admin-push.mjs';
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
Deno.serve(async req=>{
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 const secret=Deno.env.get('USSE_ADMIN_PUSH_DISPATCH_SECRET');
 if(!secret||req.headers.get('X-USSE-Push-Secret')!==secret)return json({error:'Unauthorized'},401);
 const publicKey=Deno.env.get('USSE_ADMIN_VAPID_PUBLIC_KEY'),privateKey=Deno.env.get('USSE_ADMIN_VAPID_PRIVATE_KEY');
 if(!publicKey||!privateKey)return json({error:'Device delivery is not configured.'},503);
 try{
  const supabase=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const result=await dispatchAdminPush({rpc:(action:string,payload:unknown)=>supabase.rpc('process_admin_push',{p_action:action,p_payload:payload}),
   send:async(subscription:unknown,payload:string)=>{
    const request=webpush.generateRequestDetails(subscription,payload,{TTL:3600,urgency:'high',vapidDetails:{subject:'mailto:info@ussehub.com',publicKey,privateKey}});
    const response=await fetch(request.endpoint,{method:'POST',headers:request.headers,body:request.body,redirect:'error',signal:AbortSignal.timeout(10000)});
    await response.body?.cancel();return response.status;
   }});
  return json(result);
 }catch{return json({error:'Device delivery will retry automatically.'},503);}
});
