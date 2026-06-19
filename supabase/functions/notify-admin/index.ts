import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

serve(async (req) => {
  try {
    const webhookSecret = Deno.env.get('NOTIFY_WEBHOOK_SECRET')
    if (webhookSecret) {
      const authHeader = req.headers.get('X-Webhook-Secret')
      if (authHeader !== webhookSecret) {
        return new Response('Unauthorized', { status: 401 })
      }
    } else {
      console.warn('NOTIFY_WEBHOOK_SECRET is not set. Webhook is unprotected!')
    }

    const payload = await req.json()
    const { type, table, record } = payload

    if (type !== 'INSERT') {
      return new Response('Ignored', { status: 200 })
    }

    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const adminEmail = Deno.env.get('ADMIN_NOTIFICATION_EMAIL') || 'admin@ussehub.com'

    if (!resendApiKey) {
      console.warn('RESEND_API_KEY is not set. Admin notification email skipped.')
      return new Response('Success (No Email Sent)', { status: 200 })
    }

    let subject = ''
    let html = ''

    if (table === 'profiles') {
      subject = `New Account Signup: ${record.email}`
      html = `
        <h2>New Account Signup</h2>
        <p><strong>Email:</strong> ${record.email}</p>
        <p><strong>Role:</strong> ${record.role}</p>
        <p><strong>User ID:</strong> ${record.id}</p>
      `
    } else if (table === 'listings') {
      subject = `New Listing Submitted: ${record.business_name}`
      html = `
        <h2>New Listing Submitted</h2>
        <p><strong>Business Name:</strong> ${record.business_name}</p>
        <p><strong>Category:</strong> ${record.category}</p>
        <p><strong>Location:</strong> ${record.location}</p>
        <p><strong>Status:</strong> ${record.status}</p>
        <p><strong>Owner ID:</strong> ${record.owner_user_id}</p>
      `
    } else {
      return new Response('Ignored Table', { status: 200 })
    }

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: 'USSE Hub System <admin@ussehub.com>',
        to: adminEmail,
        subject: subject,
        html: html
      })
    })

    if (!emailRes.ok) {
      const errorText = await emailRes.text()
      console.error('Failed to send email:', errorText)
      return new Response('Failed to send email', { status: 500 })
    }

    return new Response('Notification sent', { status: 200 })
  } catch (error: any) {
    console.error('Webhook processing error:', error.message)
    return new Response(JSON.stringify({ error: error.message }), { status: 400 })
  }
})
