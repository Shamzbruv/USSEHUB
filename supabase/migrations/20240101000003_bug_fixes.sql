-- 1. ad_packages: Only expose active packages to public, admins see all
DROP POLICY IF EXISTS "Public can read ad packages" ON ad_packages;
CREATE POLICY "Public can read ad packages" ON ad_packages FOR SELECT
USING (is_active = true OR private.is_admin((SELECT auth.uid())));

-- 2. ad_subscriptions: Give admins full access including DELETE
DROP POLICY IF EXISTS "Admins can delete subscriptions" ON ad_subscriptions;
CREATE POLICY "Admins can delete subscriptions" ON ad_subscriptions FOR DELETE
USING (private.is_admin((SELECT auth.uid())));
