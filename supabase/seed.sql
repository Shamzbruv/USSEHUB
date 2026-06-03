-- ============================================
-- SEED DATA
-- ============================================

-- 1. Category Groups
INSERT INTO category_groups (id, slug, name, sort_order, is_active) VALUES
(1, 'services', 'Services', 10, true),
(2, 'rooms-venue', 'Rooms & Venue', 20, true),
(3, 'farming', 'Farming', 30, true),
(4, 'retail-wholesale', 'Retail & Wholesale Trade', 40, true),
(5, 'food-beverage', 'Food & Beverage', 50, true),
(6, 'events-entertainment', 'Events & Entertainment', 60, true)
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;

-- 2. Category Options (Partial example list)
INSERT INTO category_options (group_id, slug, name, sort_order, is_active) VALUES
(1, 'creative-design', 'Creative Design', 10, true),
(1, 'corporate-advisory', 'Corporate Advisory', 20, true),
(1, 'logistics-it', 'Logistics & IT', 30, true),
(2, 'health-wellness', 'Health & Wellness', 10, true),
(5, 'frozen-products', 'Frozen Products', 10, true)
ON CONFLICT (group_id, slug) DO UPDATE SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;

-- 3. Membership Plans
INSERT INTO membership_plans (code, name, member_stats_access, price_amount, billing_interval, is_active) VALUES
('basic-free', 'Basic Listing', false, 0, 'monthly', true),
('premium-featured', 'Premium Featured', true, 50, 'monthly', true)
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, member_stats_access = EXCLUDED.member_stats_access, price_amount = EXCLUDED.price_amount;

-- Update existing demo listings to use taxonomy IDs instead of text fields if they exist
DO $$
BEGIN
    UPDATE listings SET 
        category_group_id = (SELECT id FROM category_groups WHERE slug = 'food-beverage'),
        category_option_id = (SELECT id FROM category_options WHERE slug = 'frozen-products'),
        slug = 'pure-ice',
        status = 'approved',
        published_at = now()
    WHERE business_name = 'Pure Ice';

    UPDATE listings SET 
        category_group_id = (SELECT id FROM category_groups WHERE slug = 'services'),
        category_option_id = (SELECT id FROM category_options WHERE slug = 'corporate-advisory'),
        slug = 'usse-consultancy',
        status = 'approved',
        published_at = now()
    WHERE business_name = 'USSE Consultancy';

    UPDATE listings SET 
        category_group_id = (SELECT id FROM category_groups WHERE slug = 'rooms-venue'),
        category_option_id = (SELECT id FROM category_options WHERE slug = 'health-wellness'),
        slug = 'negril-yoga-centre',
        status = 'approved',
        published_at = now()
    WHERE business_name = 'Negril Yoga Centre';

    UPDATE listings SET 
        category_group_id = (SELECT id FROM category_groups WHERE slug = 'services'),
        category_option_id = (SELECT id FROM category_options WHERE slug = 'creative-design'),
        slug = 'aloe-jamaica-agency',
        status = 'approved',
        published_at = now()
    WHERE business_name = 'Aloe Jamaica Agency';

    UPDATE listings SET 
        category_group_id = (SELECT id FROM category_groups WHERE slug = 'services'),
        category_option_id = (SELECT id FROM category_options WHERE slug = 'logistics-it'),
        slug = 'pistol-operations',
        status = 'approved',
        published_at = now()
    WHERE business_name = 'PISTOL Operations';
END $$;
