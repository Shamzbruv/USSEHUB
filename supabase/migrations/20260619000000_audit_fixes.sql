-- 1. Listing Security Fix
DROP POLICY IF EXISTS "Users insert own listings" ON listings;
DROP POLICY IF EXISTS "Users can insert own listings" ON listings;

CREATE POLICY "Users can insert own pending listings" ON listings
FOR INSERT
WITH CHECK (
  owner_user_id = auth.uid()
  AND status = 'pending'
  AND COALESCE(is_featured, false) = false
);

-- 2. Profile Insert Email Mismatch Fix
DROP POLICY IF EXISTS "Users can insert their own profile" ON profiles;
DROP POLICY IF EXISTS "Users insert own profile" ON profiles;

CREATE POLICY "Users insert own profile" ON profiles
FOR INSERT
WITH CHECK (
  id = auth.uid()
  AND email = auth.jwt()->>'email'
  AND role = 'member'
  AND COALESCE(subscription_status, 'inactive') = 'inactive'
);

-- 3. Storage Policy Generic Names Fix
DROP POLICY IF EXISTS "Public Read Access" ON storage.objects;
DROP POLICY IF EXISTS "Users insert their own images" ON storage.objects;
DROP POLICY IF EXISTS "Admins manage all images" ON storage.objects;

CREATE POLICY "listing_images_public_read" ON storage.objects
FOR SELECT
USING (bucket_id = 'listing-images');

CREATE POLICY "listing_images_user_folder_insert" ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'listing-images' AND
  (auth.uid()::text = (storage.foldername(name))[1])
);

CREATE POLICY "listing_images_admin_manage" ON storage.objects
FOR ALL
USING (
  bucket_id = 'listing-images' AND
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

-- 4. Consultation Security Fix
DROP POLICY IF EXISTS "Public can insert consultations" ON consultations;

CREATE POLICY "Public can insert consultations" ON consultations
FOR INSERT
WITH CHECK (
  source IN ('email', 'whatsapp', 'subscription', 'website')
  AND char_length(COALESCE(customer_name, '')) BETWEEN 1 AND 100
  AND char_length(COALESCE(email, '')) <= 255
  AND char_length(COALESCE(phone, '')) BETWEEN 7 AND 50
  AND char_length(COALESCE(notes, '')) BETWEEN 1 AND 2000
);
