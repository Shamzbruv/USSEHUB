-- 1. Fix insert policy for listings (force pending & not featured)
DROP POLICY IF EXISTS "Users can insert own listings" ON listings;
CREATE POLICY "Users can insert own listings" ON listings FOR INSERT
WITH CHECK (
    owner_user_id = auth.uid()
    AND status = 'pending'
    AND COALESCE(is_featured, false) = false
);

-- 2. Allow service_role to bypass profile trigger, and protect account_status
CREATE OR REPLACE FUNCTION protect_profile_sensitive_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- Allow service role (Edge Functions admin client) to update anything
    IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' THEN
        RETURN NEW;
    END IF;

    -- If the user is NOT an admin, prevent them from changing role, subscription_status, or account_status
    IF NOT private.is_admin(auth.uid()) THEN
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            RAISE EXCEPTION 'Access denied: You do not have permission to change your role.';
        END IF;
        IF NEW.subscription_status IS DISTINCT FROM OLD.subscription_status THEN
            RAISE EXCEPTION 'Access denied: You do not have permission to change your subscription_status.';
        END IF;
        IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
            RAISE EXCEPTION 'Access denied: You do not have permission to change your account_status.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- 3. Fix ad_packages policy to only show active ones to public
DROP POLICY IF EXISTS "Public can read ad packages" ON ad_packages;
CREATE POLICY "Public can read ad packages" ON ad_packages FOR SELECT
USING (is_active = true OR private.is_admin((SELECT auth.uid())));
