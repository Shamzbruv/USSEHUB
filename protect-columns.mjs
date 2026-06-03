import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL || 'postgresql://postgres.zcptuqrlovflcpqszery:Shambizonly1@@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        
        const sql = `
            -- Trigger to prevent non-admins from changing privileged columns on profiles
            CREATE OR REPLACE FUNCTION public.protect_profile_privileged_columns()
            RETURNS trigger AS $$
            BEGIN
                IF NOT private.is_admin((SELECT auth.uid())) THEN
                    IF NEW.role IS DISTINCT FROM OLD.role THEN
                        RAISE EXCEPTION 'Non-admins cannot change their role.';
                    END IF;
                    IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
                        RAISE EXCEPTION 'Non-admins cannot change their account_status.';
                    END IF;
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

            DROP TRIGGER IF EXISTS trg_protect_profile_privileged_columns ON public.profiles;
            CREATE TRIGGER trg_protect_profile_privileged_columns
                BEFORE UPDATE ON public.profiles
                FOR EACH ROW
                EXECUTE PROCEDURE public.protect_profile_privileged_columns();
                
            -- Similarly, protect listings from non-admins changing status or admin_note directly
            -- (Users can only update their listings when status is draft, pending, or changes_requested.
            -- But we shouldn't let them self-approve!)
            CREATE OR REPLACE FUNCTION public.protect_listing_privileged_columns()
            RETURNS trigger AS $$
            BEGIN
                IF NOT private.is_admin((SELECT auth.uid())) THEN
                    IF NEW.status IS DISTINCT FROM OLD.status THEN
                        -- Allow users to move from draft to pending, or changes_requested to pending
                        IF NOT (OLD.status IN ('draft', 'changes_requested') AND NEW.status = 'pending') THEN
                            RAISE EXCEPTION 'You do not have permission to change the status to %.', NEW.status;
                        END IF;
                    END IF;
                    
                    IF NEW.is_featured IS DISTINCT FROM OLD.is_featured THEN
                        RAISE EXCEPTION 'You cannot change the is_featured flag.';
                    END IF;
                    
                    IF NEW.admin_note IS DISTINCT FROM OLD.admin_note THEN
                        RAISE EXCEPTION 'You cannot modify admin_note.';
                    END IF;
                    
                    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
                        RAISE EXCEPTION 'You cannot modify approved_by.';
                    END IF;
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

            DROP TRIGGER IF EXISTS trg_protect_listing_privileged_columns ON public.listings;
            CREATE TRIGGER trg_protect_listing_privileged_columns
                BEFORE UPDATE ON public.listings
                FOR EACH ROW
                EXECUTE PROCEDURE public.protect_listing_privileged_columns();
        `;
        await client.query(sql);
        console.log("Successfully created triggers to protect privileged columns.");
        
    } catch (e) {
        console.error("Error creating triggers:", e);
    } finally {
        await client.end();
    }
}
main();
