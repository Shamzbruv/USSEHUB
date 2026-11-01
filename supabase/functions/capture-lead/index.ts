import {createClient} from '@supabase/supabase-js';
import {createLeadHandler} from '../_shared/lead-intake.mjs';
import {dispatchLeadAlerts} from '../_shared/lead-dispatch.mjs';
const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const options={apiKey:Deno.env.get('RESEND_API_KEY'),defaultRecipients:Deno.env.get('ADMIN_NOTIFICATION_EMAIL')};
Deno.serve(createLeadHandler({client,turnstileSecret:Deno.env.get('TURNSTILE_SECRET_KEY'),dispatchSecret:Deno.env.get('LEAD_DISPATCH_SECRET'),dispatch:()=>dispatchLeadAlerts(client,options),waitUntil:promise=>EdgeRuntime.waitUntil(promise)}));
