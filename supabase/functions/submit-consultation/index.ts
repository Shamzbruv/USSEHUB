import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function handleCors(req: Request) {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  return null;
}

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const { listing_id, customer_name, phone, email, source, notes, turnstile_token } = await req.json()

    if (!turnstile_token) {
      return new Response(JSON.stringify({ error: 'Turnstile token missing' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Verify Turnstile
    const turnstileSecret = Deno.env.get('TURNSTILE_SECRET_KEY')
    if (turnstileSecret) {
      const formData = new FormData();
      formData.append('secret', turnstileSecret);
      formData.append('response', turnstile_token);

      const verification = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
        method: 'POST',
        body: formData,
      });
      const verificationJson = await verification.json();

      if (!verificationJson.success) {
        return new Response(JSON.stringify({ error: 'Turnstile verification failed' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }
    } else {
      console.warn('TURNSTILE_SECRET_KEY is not set. Skipping verification (OK for local dev if intended).')
    }

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { data, error } = await supabaseClient.from('consultations').insert([{
      listing_id, customer_name, phone, email, source, notes
    }]).select().single()

    if (error) throw error

    // Send Admin Notification Email via Resend
    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const adminEmail = Deno.env.get('ADMIN_NOTIFICATION_EMAIL') || 'admin@ussehub.com'
    if (resendApiKey) {
      const emailBody = `
        <h2>New Consultation Request</h2>
        <p><strong>Customer:</strong> ${customer_name}</p>
        <p><strong>Phone:</strong> ${phone}</p>
        <p><strong>Email:</strong> ${email}</p>
        <p><strong>Source:</strong> ${source}</p>
        <p><strong>Listing ID:</strong> ${listing_id || 'N/A'}</p>
        <p><strong>Message:</strong> ${notes}</p>
      `
      await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${resendApiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          from: 'USSE Hub System <admin@ussehub.com>',
          to: adminEmail,
          reply_to: email,
          subject: `New Consultation from ${customer_name}`,
          html: emailBody
        })
      })
    } else {
      console.warn('RESEND_API_KEY is not set. Admin notification email skipped.')
    }

    return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
