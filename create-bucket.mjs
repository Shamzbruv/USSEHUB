// create-bucket.mjs — Create the listing-images storage bucket via Supabase Management API
// Using service role to call the storage management endpoint
const SUPABASE_URL = 'https://zcptuqrlovflcpqszery.supabase.co';
const SVC_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpjcHR1cXJsb3ZmbGNwcXN6ZXJ5Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MDAwMzEzNywiZXhwIjoyMDk1NTc5MTM3fQ.bstDgIr-f6MpqOxKAUuexH7TYBKDgR5Un8uYqfX58Lc';

async function main() {
    console.log('Creating listing-images storage bucket...');

    // First try to get it
    const getRes = await fetch(`${SUPABASE_URL}/storage/v1/bucket/listing-images`, {
        headers: {
            'apikey': SVC_KEY,
            'Authorization': `Bearer ${SVC_KEY}`
        }
    });

    if (getRes.ok) {
        const bucket = await getRes.json();
        console.log('✅ Bucket already exists:', bucket.name);
        return;
    }

    // Create it
    const res = await fetch(`${SUPABASE_URL}/storage/v1/bucket`, {
        method: 'POST',
        headers: {
            'apikey': SVC_KEY,
            'Authorization': `Bearer ${SVC_KEY}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            id: 'listing-images',
            name: 'listing-images',
            public: true,
            file_size_limit: 5242880,
            allowed_mime_types: ['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
        })
    });

    const data = await res.json();
    if (res.ok) {
        console.log('✅ Bucket created:', data.name);
    } else {
        console.log('Result:', JSON.stringify(data));
    }
}

main().catch(console.error);
