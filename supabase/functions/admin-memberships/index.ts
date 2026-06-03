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

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { action, target_user_id, role, plan_id, status } = await req.json()
    if (!target_user_id) throw new Error('target_user_id is required')

    let result = null

    if (action === 'assign_role') {
      if (!['admin','member','subscriber'].includes(role)) throw new Error('Invalid role')
      
      const { data, error } = await supabaseAdmin
        .from('profiles')
        .update({ role, updated_at: new Date().toISOString() })
        .eq('id', target_user_id)
        .select()
        .single()
      if (error) throw error
      result = data
      
      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'profile_role', entity_id: target_user_id, action: 'assign_role', after_state: data
      })
      
    } else if (action === 'manage_membership') {
      if (!plan_id) throw new Error('plan_id required')
      
      const { data: existing } = await supabaseAdmin.from('memberships').select('*').eq('user_id', target_user_id).eq('plan_id', plan_id).maybeSingle()
      
      if (existing) {
        const { data, error } = await supabaseAdmin
          .from('memberships')
          .update({ status, updated_at: new Date().toISOString() })
          .eq('id', existing.id)
          .select()
          .single()
        if (error) throw error
        result = data
      } else {
        const { data, error } = await supabaseAdmin
          .from('memberships')
          .insert({ user_id: target_user_id, plan_id, status, starts_at: new Date().toISOString() })
          .select()
          .single()
        if (error) throw error
        result = data
      }
      
      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'membership', entity_id: target_user_id, action: 'manage_membership', after_state: result
      })
    } else {
      throw new Error('Invalid action')
    }

    return new Response(JSON.stringify(result), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
