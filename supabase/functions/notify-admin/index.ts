import { serve } from 'server'
import { businessNotification } from '../_shared/email.mjs'

serve(async (req: Request) => {
  try {
    const webhookSecret = Deno.env.get('NOTIFY_WEBHOOK_SECRET')
    
    // Fail closed: Webhook secret MUST be configured
    if (!webhookSecret) {
      return new Response('Webhook secret not configured', { status: 500 })
    }

    const authHeader = req.headers.get('X-Webhook-Secret')
    if (authHeader !== webhookSecret) {
      return new Response('Unauthorized', { status: 401 })
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
    let emailContent = { html: '', text: '' }

    // Note: Consultations are explicitly NOT handled here.
    // Consultations are handled directly by the submit-consultation Edge Function,
    // which does its own specialized validation and emailing.
    if (table === 'profiles') {
      subject = `USSE Hub | New account: ${record.email}`
      emailContent = businessNotification({ title: 'A new connection has joined.', message: 'A new account has been created on USSE Hub. Review the account in your admin workspace.', fields: [['Email', record.email], ['Role', record.role], ['User ID', record.id]], admin: true })
    } else if (table === 'listings') {
      subject = `USSE Hub | New listing: ${record.business_name}`
      emailContent = businessNotification({ title: 'A business is ready for review.', message: 'A new business listing has been submitted to Aloe Jamaica. Open your admin workspace to review its details.', fields: [['Business', record.business_name], ['Category', record.category], ['Location', record.location], ['Status', record.status], ['Owner ID', record.owner_user_id]], admin: true })
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
        from: 'USSE Hub <admin@ussehub.com>',
        to: adminEmail,
        subject: subject,
        ...emailContent
      })
    })

    if (!emailRes.ok) {
      const errorText = await emailRes.text()
      console.error('Failed to send email:', errorText)
      return new Response('Failed to send email', { status: 500 })
    }

    return new Response('Notification sent', { status: 200 })
  } catch (error: unknown) {
    console.error('Webhook processing error:', (error as Error).message)
    return new Response(JSON.stringify({ error: (error as Error).message }), { status: 400 })
  }
})
