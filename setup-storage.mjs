import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        
        const sql = `
            -- Create the public bucket
            INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
            VALUES (
                'listing-images',
                'listing-images',
                true, -- PUBLIC BUCKET
                5242880,  -- 5MB
                ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/avif']
            )
            ON CONFLICT (id) DO UPDATE SET
                public = true,
                file_size_limit = 5242880,
                allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/avif'];

            -- Add policies
            -- 1. Public can read
            DROP POLICY IF EXISTS "Public Read Access" ON storage.objects;
            CREATE POLICY "Public Read Access" ON storage.objects
            FOR SELECT USING (bucket_id = 'listing-images');

            -- 2. Authenticated users can insert to their own folder
            DROP POLICY IF EXISTS "Users insert their own images" ON storage.objects;
            CREATE POLICY "Users insert their own images" ON storage.objects
            FOR INSERT WITH CHECK (
                bucket_id = 'listing-images' 
                AND auth.role() = 'authenticated'
                AND (storage.foldername(name))[1] = auth.uid()::text
            );

            -- 3. Admins can manage all images
            DROP POLICY IF EXISTS "Admins manage all images" ON storage.objects;
            CREATE POLICY "Admins manage all images" ON storage.objects
            FOR ALL USING (
                bucket_id = 'listing-images'
                AND EXISTS (
                    SELECT 1 FROM public.profiles 
                    WHERE id = auth.uid() AND role = 'admin'
                )
            );
        `;
        await client.query(sql);
        console.log("Successfully created public storage bucket and policies.");
        
    } catch (e) {
        console.error("Error creating storage:", e);
    } finally {
        await client.end();
    }
}
main();
