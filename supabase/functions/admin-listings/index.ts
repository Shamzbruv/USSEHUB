import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    // Verify caller is admin
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    if (profileError || profile.role !== 'admin') {
      return new Response(JSON.stringify({ error: 'Access denied: admin role required' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Now use service role for privileged ops
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { action, listing_id, rejection_reason, admin_note } = await req.json()
    if (!listing_id) throw new Error('listing_id is required')

    let updatePayload: any = { updated_at: new Date().toISOString() }
    let newStatus = ''

    if (action === 'approve') {
      newStatus = 'approved'
      updatePayload = { ...updatePayload, status: newStatus, approved_at: new Date().toISOString(), approved_by: user.id, published_at: new Date().toISOString() }
    } else if (action === 'reject') {
      newStatus = 'rejected'
      if (!rejection_reason) throw new Error('rejection_reason required')
      updatePayload = { ...updatePayload, status: newStatus, rejection_reason }
    } else if (action === 'request_changes') {
      newStatus = 'changes_requested'
      if (!admin_note) throw new Error('admin_note required')
      updatePayload = { ...updatePayload, status: newStatus, admin_note }
    } else if (action === 'expire') {
      newStatus = 'expired'
      updatePayload = { ...updatePayload, status: newStatus, expires_at: new Date().toISOString() }
    } else if (action === 'feature') {
      updatePayload = { ...updatePayload, is_featured: true, featured_until: new Date(Date.now() + 30*24*60*60*1000).toISOString() }
    } else if (action === 'unfeature') {
      updatePayload = { ...updatePayload, is_featured: false, featured_until: null }
    } else if (action === 'update_listing') {
      const { business_name, category, subcategory, description, location, contact_phone, whatsapp, email, website, listing_type, image_url, extra_notes } = await req.json();
      updatePayload = {
        ...updatePayload,
        business_name,
        category,
        subcategory,
        description,
        location,
        contact_phone,
        whatsapp,
        email,
        website,
        listing_type,
        extra_notes,
        ...(image_url !== undefined && { image_url })
      }
    } else {
      throw new Error('Invalid action')
    }

    // Get old listing for audit
    const { data: oldListing } = await supabaseAdmin.from('listings').select('*').eq('id', listing_id).single()

    const { data: newListing, error: updateError } = await supabaseAdmin
      .from('listings')
      .update(updatePayload)
      .eq('id', listing_id)
      .select()
      .single()

    if (updateError) throw updateError

    // Log status change if status changed
    if (newStatus && oldListing?.status !== newStatus) {
      await supabaseAdmin.from('listing_status_history').insert({
        listing_id,
        old_status: oldListing?.status,
        new_status: newStatus,
        changed_by: user.id,
        reason: action === 'reject' ? rejection_reason : action === 'request_changes' ? admin_note : null,
        snapshot: newListing
      })
    }

    // Write audit log
    await supabaseAdmin.from('admin_audit_log').insert({
      actor_user_id: user.id,
      entity_type: 'listing',
      entity_id: listing_id,
      action: \`admin_\${action}\`,
      before_state: oldListing,
      after_state: newListing
    })

    return new Response(JSON.stringify(newListing), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
