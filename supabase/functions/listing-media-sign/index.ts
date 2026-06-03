import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { listing_ids, paths } = await req.json()

    // Depending on logic, we either sign paths directly or fetch listing media paths then sign
    let storagePaths: string[] = []
    
    if (paths && Array.isArray(paths)) {
      storagePaths = paths
    } else if (listing_ids && Array.isArray(listing_ids)) {
      // Fetch paths for given listing IDs (only if approved)
      // Since public can only access approved, verify status
      const { data: media } = await supabaseAdmin
        .from('listing_media')
        .select('storage_path, listings!inner(status, expires_at)')
        .in('listing_id', listing_ids)
        .eq('listings.status', 'approved')

      if (media) {
        storagePaths = media
          .filter(m => !m.listings?.expires_at || new Date(m.listings.expires_at) > new Date())
          .map(m => m.storage_path)
      }
    }

    if (storagePaths.length === 0) {
      return new Response(JSON.stringify([]), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Sign URLs for 1 hour
    const { data: signedUrls, error } = await supabaseAdmin.storage
      .from('listing-images')
      .createSignedUrls(storagePaths, 3600)

    if (error) throw error

    return new Response(JSON.stringify(signedUrls), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
