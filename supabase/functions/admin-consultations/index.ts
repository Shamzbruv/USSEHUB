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

    const { action, consultation_id, note } = await req.json()
    if (!consultation_id) throw new Error('consultation_id is required')

    let result = null

    if (action === 'delete_consultation') {
      const { data, error } = await supabaseAdmin
        .from('consultations')
        .delete()
        .eq('id', consultation_id)
        .select()
        .single()
      if (error) throw error
      result = data

      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'consultation', entity_id: consultation_id, action: 'delete_consultation', before_state: data
      })

    } else if (action === 'mark_contacted') {
      const { data, error } = await supabaseAdmin
        .from('consultations')
        .update({ status: 'contacted', updated_at: new Date().toISOString() })
        .eq('id', consultation_id)
        .select()
        .single()
      if (error) throw error
      result = data

      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'consultation', entity_id: consultation_id, action: 'mark_contacted', after_state: data
      })

    } else if (action === 'mark_resolved') {
      const { data, error } = await supabaseAdmin
        .from('consultations')
        .update({ status: 'resolved', updated_at: new Date().toISOString() })
        .eq('id', consultation_id)
        .select()
        .single()
      if (error) throw error
      result = data

      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'consultation', entity_id: consultation_id, action: 'mark_resolved', after_state: data
      })

    } else if (action === 'add_note') {
      if (!note) throw new Error('note is required')
      // Assuming 'notes' field is appended or there's a specific way to add a note
      const { data: existing } = await supabaseAdmin.from('consultations').select('notes').eq('id', consultation_id).single()
      const newNotes = existing?.notes ? `${existing.notes}\n[Admin]: ${note}` : `[Admin]: ${note}`

      const { data, error } = await supabaseAdmin
        .from('consultations')
        .update({ notes: newNotes, updated_at: new Date().toISOString() })
        .eq('id', consultation_id)
        .select()
        .single()
      if (error) throw error
      result = data

      await supabaseAdmin.from('admin_audit_log').insert({
        actor_user_id: user.id, entity_type: 'consultation', entity_id: consultation_id, action: 'add_note', after_state: data
      })

    } else {
      throw new Error('Invalid action')
    }

    return new Response(JSON.stringify(result), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
