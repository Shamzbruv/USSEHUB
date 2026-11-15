import { miniAdDuration } from './mp4.mjs';

const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const filePath = /^[0-9a-f-]{36}\/[0-9a-f-]{36}\.mp4$/i;
const base = Deno.env.get('SUPABASE_URL')!;
const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
const maxBytes = 20 * 1024 * 1024;

function json(message: Record<string, unknown>, status = 200) {
    return Response.json(message, { status, headers: { ...cors, 'Cache-Control': 'no-store' } });
}

Deno.serve(async (request: Request) => {
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
    const bearer = request.headers.get('Authorization');
    if (!bearer?.startsWith('Bearer ')) return json({ error: 'Sign in to validate your mini-ad.' }, 401);

    try {
        const headers = { apikey: anon, Authorization: bearer };
        const auth = await fetch(base + '/auth/v1/user', { headers });
        if (!auth.ok || !(await auth.json()).email_confirmed_at) {
            return json({ error: 'Sign in with a verified account.' }, 401);
        }
        const input = await request.text();
        if (input.length > 512) return json({ error: 'Invalid post reference.' }, 400);
        const { id } = JSON.parse(input);
        if (typeof id !== 'string' || !uuid.test(id)) return json({ error: 'Invalid post reference.' }, 400);

        // Use the caller's access for the draft and immutable uploaded object.
        const draft = await fetch(
            base + '/rest/v1/marketplace_flyers?select=image_path,file_size,video_duration_ms&id=eq.' +
                id + '&status=eq.draft&mime=eq.video/mp4',
            { headers }
        );
        const post = draft.ok ? (await draft.json())[0] : null;
        if (!post || !filePath.test(post.image_path) || post.file_size <= 0 || post.file_size > maxBytes) {
            return json({ error: 'This mini-ad draft is unavailable.' }, 404);
        }
        if (post.video_duration_ms) return json({ duration_ms: post.video_duration_ms });
        const media = await fetch(base + '/storage/v1/object/authenticated/marketplace-flyers/' + post.image_path, { headers });
        if (!media.ok || Number(media.headers.get('content-length')) > post.file_size) {
            return json({ error: 'The mini-ad upload is incomplete. Retry the upload.' }, 409);
        }
        const bytes = await media.arrayBuffer();
        if (bytes.byteLength !== post.file_size) return json({ error: 'The mini-ad upload is incomplete.' }, 409);

        let duration;
        try {
            duration = miniAdDuration(bytes);
        } catch (error) {
            return json({ error: error instanceof Error ? error.message : 'This MP4 could not be verified.' }, 422);
        }
        const saved = await fetch(base + '/rest/v1/rpc/mark_marketplace_video_verified', {
            method: 'POST',
            headers: { apikey: service, Authorization: 'Bearer ' + service, 'Content-Type': 'application/json' },
            body: JSON.stringify({ p_flyer_id: id, p_image_path: post.image_path, p_duration_ms: duration })
        });
        if (!saved.ok || !await saved.json()) return json({ error: 'This mini-ad could not be marked ready. Please retry.' }, 409);
        return json({ duration_ms: duration });
    } catch {
        return json({ error: 'The mini-ad could not be verified. Please retry.' }, 400);
    }
});
