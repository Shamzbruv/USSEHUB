-- ============================================
-- SECURITY FIXES & ENHANCEMENTS
-- ============================================

-- 1. Prevent users from updating their own 'role' and 'subscription_status'
CREATE OR REPLACE FUNCTION protect_profile_sensitive_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- If the user is NOT an admin, prevent them from changing role or subscription_status
    IF NOT private.is_admin(auth.uid()) THEN
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            RAISE EXCEPTION 'Access denied: You do not have permission to change your role.';
        END IF;
        IF NEW.subscription_status IS DISTINCT FROM OLD.subscription_status THEN
            RAISE EXCEPTION 'Access denied: You do not have permission to change your subscription_status.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

DROP TRIGGER IF EXISTS trg_protect_profile_sensitive_fields ON profiles;
CREATE TRIGGER trg_protect_profile_sensitive_fields
    BEFORE UPDATE ON profiles
    FOR EACH ROW EXECUTE PROCEDURE protect_profile_sensitive_fields();


-- 2. Allow new users to insert their initial profile row
-- Existing profiles RLS only has SELECT and UPDATE policies.
DROP POLICY IF EXISTS "Users insert own profile" ON profiles;
CREATE POLICY "Users insert own profile" ON profiles FOR INSERT
WITH CHECK (
    id = (SELECT auth.uid()) 
    AND role = 'member'
    AND subscription_status = 'inactive'
    AND (account_status = 'active' OR account_status IS NULL)
);


-- 3. RLS for consultations, ad_subscriptions, and ad_packages
ALTER TABLE consultations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ad_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ad_packages ENABLE ROW LEVEL SECURITY;

-- Consultations: Public can insert (from the frontend form), Admins can read/update/delete.
DROP POLICY IF EXISTS "Public can insert consultations" ON consultations;
CREATE POLICY "Public can insert consultations" ON consultations FOR INSERT
WITH CHECK (true); -- Publicly accessible form

DROP POLICY IF EXISTS "Admins can manage consultations" ON consultations;
CREATE POLICY "Admins can manage consultations" ON consultations FOR ALL
USING (private.is_admin((SELECT auth.uid())));


-- Ad Packages: Public can read active packages, only admins can manage
DROP POLICY IF EXISTS "Public can read ad packages" ON ad_packages;
CREATE POLICY "Public can read ad packages" ON ad_packages FOR SELECT
USING (true);

DROP POLICY IF EXISTS "Admins can manage ad packages" ON ad_packages;
CREATE POLICY "Admins can manage ad packages" ON ad_packages FOR ALL
USING (private.is_admin((SELECT auth.uid())));


-- Ad Subscriptions: Users can see/insert their own, admins can manage all
DROP POLICY IF EXISTS "Users can read own subscriptions" ON ad_subscriptions;
CREATE POLICY "Users can read own subscriptions" ON ad_subscriptions FOR SELECT
USING (
    user_id = (SELECT auth.uid()) 
    OR private.is_admin((SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Users can insert own subscriptions" ON ad_subscriptions;
CREATE POLICY "Users can insert own subscriptions" ON ad_subscriptions FOR INSERT
WITH CHECK (
    user_id = (SELECT auth.uid())
    AND status = 'pending'
);

DROP POLICY IF EXISTS "Admins can update subscriptions" ON ad_subscriptions;
CREATE POLICY "Admins can update subscriptions" ON ad_subscriptions FOR UPDATE
USING (private.is_admin((SELECT auth.uid())));
