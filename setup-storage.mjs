import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL || 'postgresql://postgres.zcptuqrlovflcpqszery:Shambizonly1@@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

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

        `;
        await client.query(sql);
        console.log("Successfully created private storage bucket and policies.");
        
    } catch (e) {
        console.error("Error creating storage:", e);
    } finally {
        await client.end();
    }
}
main();
