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

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    if (profileError) throw new Error('Profile not found')

    // Check membership
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { data: memberships } = await supabaseAdmin
      .from('memberships')
      .select('status, ends_at')
      .eq('user_id', user.id)
      .eq('status', 'active')

    const hasActiveMembership = memberships && memberships.length > 0 && 
      (!memberships[0].ends_at || new Date(memberships[0].ends_at) > new Date())

    if (profile.role !== 'admin' && !hasActiveMembership) {
      return new Response(JSON.stringify({ error: 'Access denied: Active membership or admin role required' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Return safe stats
    const { count: totalMembers } = await supabaseAdmin.from('profiles').select('*', { count: 'exact', head: true })
    const { count: activeListings } = await supabaseAdmin.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'approved')
    
    let stats: any = { totalMembers, activeListings }

    if (profile.role === 'admin') {
      const { count: pendingListings } = await supabaseAdmin.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'pending')
      const { count: rejectedListings } = await supabaseAdmin.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'rejected')
      const { count: expiredListings } = await supabaseAdmin.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'expired')
      stats = { ...stats, pendingListings, rejectedListings, expiredListings }
    }

    return new Response(JSON.stringify(stats), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
