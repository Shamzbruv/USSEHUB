import { serve } from 'server'
import { createClient } from '@supabase/supabase-js'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

type SubscriptionAction = 'activate' | 'cancel'

serve(async (req: Request) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } }
    )

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    if (profileError || profile?.role !== 'admin') {
      return new Response(JSON.stringify({ error: 'Access denied: admin role required' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const body = await req.json()
    const action = body.action as SubscriptionAction
    const listingId = String(body.listing_id ?? '')
    if (!listingId) throw new Error('listing_id is required')
    if (!['activate', 'cancel'].includes(action)) throw new Error('Invalid action')

    const { data: listing, error: listingError } = await supabaseAdmin
      .from('listings')
      .select('id, owner_user_id, requested_tier, market_segment')
      .eq('id', listingId)
      .single()

    if (listingError || !listing) throw new Error('Listing not found')
    if (!listing.owner_user_id) throw new Error('The listing must have an owner before a webpage package can be activated')

    const { data: beforeState } = await supabaseAdmin
      .from('ad_subscriptions')
      .select('*, ad_packages(code, webpage_tier)')
      .eq('listing_id', listingId)
      .eq('status', 'active')

    if (action === 'cancel') {
      const { data, error } = await supabaseAdmin
        .from('ad_subscriptions')
        .update({ status: 'cancelled', updated_at: new Date().toISOString() })
        .eq('listing_id', listingId)
        .eq('status', 'active')
        .select()

      if (error) throw error
      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id,
        entity_type: 'ad_subscription',
        entity_id: listingId,
        action: 'cancel_ajm_webpage_package',
        before_state: beforeState,
        after_state: data
      })
      return new Response(JSON.stringify({ subscriptions: data }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    const packageCode = String(body.package_code ?? '')
    const marketSegment = String(body.market_segment ?? listing.market_segment ?? '')
    const allowedSegments = [
      'local-business',
      'professional-services',
      'b2b-supplier',
      'hospitality-events',
      'automotive-collectibles'
    ]
    if (!packageCode) throw new Error('package_code is required')
    if (!allowedSegments.includes(marketSegment)) throw new Error('A valid market segment is required')

    const { data: adPackage, error: packageError } = await supabaseAdmin
      .from('ad_packages')
      .select('id, code, name, duration_days, webpage_enabled, webpage_tier, is_active')
      .eq('code', packageCode)
      .eq('webpage_enabled', true)
      .eq('is_active', true)
      .single()

    if (packageError || !adPackage?.webpage_tier) throw new Error('Webpage package not found or inactive')

    const durationDays = Math.max(1, Math.min(3650, Number(body.duration_days || adPackage.duration_days || 30)))
    const startsAt = new Date()
    const expiresAt = new Date(startsAt.getTime() + durationDays * 24 * 60 * 60 * 1000)

    const { data: subscription, error: subscriptionError } = await supabaseAdmin
      .from('ad_subscriptions')
      .insert({
        user_id: listing.owner_user_id,
        listing_id: listingId,
        package_id: adPackage.id,
        status: 'active',
        payment_method: 'admin',
        payment_reference: body.payment_reference ? String(body.payment_reference) : null,
        expires_at: expiresAt.toISOString()
      })
      .select()
      .single()

    if (subscriptionError) throw subscriptionError

    const { error: cancelError } = await supabaseAdmin
      .from('ad_subscriptions')
      .update({ status: 'cancelled', updated_at: startsAt.toISOString() })
      .eq('listing_id', listingId)
      .eq('status', 'active')
      .neq('id', subscription.id)

    if (cancelError) {
      await supabaseAdmin.from('ad_subscriptions').delete().eq('id', subscription.id)
      throw cancelError
    }

    const { error: listingUpdateError } = await supabaseAdmin
      .from('listings')
      .update({
        requested_tier: adPackage.webpage_tier,
        market_segment: marketSegment,
        updated_at: startsAt.toISOString()
      })
      .eq('id', listingId)
    if (listingUpdateError) throw listingUpdateError

    await supabaseAdmin.from('admin_audit_log').insert({
      actor_user_id: user.id,
      entity_type: 'ad_subscription',
      entity_id: listingId,
      action: 'activate_ajm_webpage_package',
      before_state: beforeState,
      after_state: { subscription, package: adPackage, market_segment: marketSegment }
    })

    return new Response(JSON.stringify({ subscription, package: adPackage }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  } catch (error: unknown) {
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})
