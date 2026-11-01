import {allowedPushEndpoint,pushPayload,pushResult} from '../../../assets/usse-admin-app-core.mjs';
export async function dispatchAdminPush({rpc,send}){
 const {data:jobs,error}=await rpc('claim',{});if(error)throw new Error('Could not claim device alerts.');
 let accepted=0,failed=0,expired=0;
 // Bounded parallelism limits provider load and lets the database lease recover interrupted work.
 for(let offset=0;offset<jobs.length;offset+=5){
  await Promise.all(jobs.slice(offset,offset+5).map(async job=>{
   let status=0;
   try{if(!allowedPushEndpoint(job.subscription.endpoint))status=410;
    else status=await send(job.subscription,pushPayload(job.payload));
   }catch{status=0;}
   const result=pushResult(status);
   const detail=result==='accepted'?null:result==='gone'?'Device subscription expired. Enable alerts on that device again.':status===401||status===403?'The push service rejected the app identity. Contact USSE support.':status===429?'The push service is busy. Delivery will retry.':'Device delivery could not complete. It will retry automatically.';
   const saved=await rpc('complete',{id:job.id,claim_token:job.claim_token,result,error:detail});
   if(saved.error)throw new Error('Could not save a device delivery result.');
   if(result==='accepted')accepted++;else if(result==='gone')expired++;else failed++;
  }));
 }
 return {processed:jobs.length,accepted,failed,expired};
}
