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

function escHtml(value: unknown) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const { listing_id, customer_name, phone, email, source, notes, turnstile_token } = await req.json()

    // 1. Validate inputs server-side
    const allowedSources = ['email', 'whatsapp', 'subscription', 'website'];
    if (!allowedSources.includes(source)) throw new Error('Invalid source');
    if (!customer_name || customer_name.length > 100) throw new Error('Invalid name');
    if (!phone || phone.length < 7 || phone.length > 50) throw new Error('Invalid phone');
    if (!notes || notes.length > 2000) throw new Error('Invalid message');
    if (email && email.length > 255) throw new Error('Invalid email');

    if (!turnstile_token) {
      return new Response(JSON.stringify({ error: 'Turnstile token missing' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // 2. Verify Turnstile (Fail closed)
    const turnstileSecret = Deno.env.get('TURNSTILE_SECRET_KEY')
    if (!turnstileSecret) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration: Turnstile secret missing.' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }
    
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

    // 3. Insert into Supabase
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { data, error } = await supabaseClient.from('consultations').insert([{
      listing_id, customer_name, phone, email, source, notes
    }]).select().single()

    if (error) throw error

    // 4. Send Admin Notification Email via Resend
    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const adminEmail = Deno.env.get('ADMIN_NOTIFICATION_EMAIL') || 'admin@ussehub.com'
    
    if (resendApiKey) {
      const emailBody = `
        <h2>New Consultation Request</h2>
        <p><strong>Customer:</strong> ${escHtml(customer_name)}</p>
        <p><strong>Phone:</strong> ${escHtml(phone)}</p>
        <p><strong>Email:</strong> ${escHtml(email)}</p>
        <p><strong>Source:</strong> ${escHtml(source)}</p>
        <p><strong>Listing ID:</strong> ${escHtml(listing_id || 'N/A')}</p>
        <p><strong>Message:</strong> ${escHtml(notes)}</p>
      `
      const emailRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${resendApiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          from: 'USSE Hub System <admin@ussehub.com>',
          to: adminEmail,
          reply_to: email || undefined,
          subject: `New Consultation from ${escHtml(customer_name)}`,
          html: emailBody
        })
      })
      
      if (!emailRes.ok) {
        const errorText = await emailRes.text();
        console.error('Failed to send admin email:', errorText);
      }
    } else {
      console.warn('RESEND_API_KEY is not set. Admin notification email skipped.')
    }

    return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
