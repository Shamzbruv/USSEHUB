-- Administrator-managed, additive categories for Marketplace and business listings.
CREATE TABLE private.business_taxonomies (
    scope text PRIMARY KEY CHECK (scope IN ('directory', 'marketplace')),
    data jsonb NOT NULL CHECK (jsonb_typeof(data) = 'object'),
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES auth.users(id)
);
ALTER TABLE private.business_taxonomies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.business_taxonomies FROM PUBLIC, anon, authenticated;
INSERT INTO private.business_taxonomies(scope, data)
SELECT key, value FROM jsonb_each('{"directory":{"GENERAL":{"TRANSPORT - PUBLIC":{"tertiary":["MAINTENANCE","REPAIRS","CONSTRUCTION","DELIVERY / PICKUPS","CATERING"],"specific":["LAND","AIR","SEA","GARAGES","CENTRES","FOODS","NON-FOODS"]},"TRANSPORT - PRIVATE":{"tertiary":["RENTALS & LEASES","CHARTERS","MAINTENANCE & REPAIRS"],"specific":["LAND","AIR","SEA","COURIER","DELIVERY / PICKUPS","CATERING (FOODS)","CATERING (NON-FOODS)"]},"HEALTH & WELLNESS":{"tertiary":["WELLNESS & FITNESS"],"specific":["GYMS","SPAS","MEDITATION","MARTIAL ARTS (YOGA / TM)","TRACK & FIELD"]},"PERSONAL CARE":{"tertiary":["GROOMING","COSMETICS"],"specific":["SALONS","BARBER SHOPS"]},"MEDICAL":{"tertiary":["CLINICS","HOSPITALS"],"notes":["General medical facilities"]},"EDUCATIONAL":{"tertiary":["PUBLIC & PRIVATE SERVICES"],"specific":["DAY CARE","KINDERGARTEN / PRE-SCHOOL","PRIMARY","SECONDARY","TRAINING CENTRES","LIBRARY SERVICES","COMMUNITY CENTRES","INFIRMARIES","TERTIARY - COMMUNITY COLLEGES","TERTIARY - UNIVERSITIES"]},"COMMUNICATIONS":{"tertiary":["TELEPHONY","MEDIA NEWS","INTERNET","SATELLITE"],"specific":["WEB DEVELOPMENT","NETWORK CAFES","INSTALLATIONS","SERVICING & REPAIRS"]},"AUDIO / VISUAL":{"tertiary":["GRAPHIC DESIGNS","MUSICAL STUDIOS","PHOTO STUDIO SERVICES"],"specific":["MARKETING / PROMOTIONS"]},"BEAUTY & PERSONAL CARE":{"tertiary":["HAIR GROOMING SERVICES","COSMETIC SERVICES","NAIL TECHNICIANS","HAIR STYLISTS"],"specific":[]},"TRANSPORT & LOGISTICS":{"tertiary":["DELIVERY SERVICES","HAULAGE SERVICES","IMPORT & EXPORT SERVICES","CAR RENTAL SERVICES"],"specific":[]},"EDUCATION & COACHING":{"tertiary":["EDUCATIONAL SERVICES","COACHING SERVICES"],"specific":[]}},"PROPERTY MANAGEMENT SERVICES":{"RESIDENTIAL / COMMERCIAL":{"tertiary":["VENUE PLANNING","EVENTS PLANNING"],"notes":["Property administration and events"]}},"FINANCIAL SERVICES":{"INSTITUTIONS - LOCAL & INTERNATIONAL":{"tertiary":["BANKS","INSURANCE","INVESTMENTS","DIGITAL"],"notes":["Financial instruments and banking"]},"LENDING":{"tertiary":["MICRO LOAN SERVICES"],"specific":[]}},"NGO / SERVICE CLUBS":{"LOCAL & INTERNATIONAL":{"tertiary":["RELIGIOUS CENTRES & BRANCHES","CIVIC / SERVICE CLUBS"],"notes":["Community and global organizations"]}},"REAL ESTATE":{"PROPERTY MANAGEMENT - SALES, RENTALS, LEASES, ROOMS & VENUES":{"tertiary":["ACCOMMODATIONS","CONVENTIONAL VENUES","WAREHOUSES","LAND LOTS"],"specific":["RESORT / LEISURE","MEETINGS / CONFERENCES","PARKS","RESIDENTIAL","COMMERCIAL","ENTERTAINMENT","BUSINESS","STADIUMS","ATTRACTIONS","AUDITORIUMS / CENTRES"]},"RETAIL":{"tertiary":["SHOPPING STORE OUTLETS","SUPPLY CENTRES","STORAGE FACILITIES"],"specific":["SUPERMARKETS","FLORISTS","ELECTRONICS","PHARMACEUTICAL","HEALTH FOOD & BEVERAGE SUPPLIES","BOOK STORES / CLUBS","CONVENIENCE / COMMISSARIES","HARDWARE & CONSTRUCTION SUPPLIES","COMMERCIAL EQUIPMENT & DEVICES","MARKETS & STALLS","CRAFT MARKETS"]}},"FOOD & BEVERAGE":{"DINING OUTLETS":{"tertiary":["BARS","RESTAURANTS","TO-GO OUTLETS / DELIS"],"specific":["FULL SERVICE","CAFES","REST STOPS","DRIVE-THROUGH"]},"STORAGE & DISTRIBUTION":{"tertiary":["DEPOTS - ALL TYPES","DISTRIBUTION OUTLETS"],"specific":["COLD STORAGE","DRY STORAGE","FOOD & BEVERAGE","HONEY","MEATS"]},"CATERING & FOOD SERVICES":{"tertiary":["CATERING SERVICES","COOKING SERVICES"],"specific":[]},"FOOD PRODUCTION & SUPPLY":{"tertiary":["BAKERY SUPPLIER","ICE PRODUCTION SERVICES"],"specific":[]}},"FARMING & AGRICULTURE":{"AGRICULTURE":{"tertiary":["LIVESTOCK & POULTRY","CROPS & PRODUCE","HORTICULTURE"],"specific":["CATTLE","POULTRY","HERBS & SPICES","VEGETABLES","FRUITS","GROUND PROVISIONS","GENERAL CROPS"]},"FISHERIES":{"tertiary":["FRESHWATER PONDS","SEA CATCHMENTS"],"notes":["Commercial and local fishing"]}},"CONSTRUCTION":{"RESIDENTIAL & COMMERCIAL":{"tertiary":["TRADES & MASONRY","CARPENTRY & WELDING","PAINTING & SURVEYING"],"specific":["PROPERTY VALUATION","BUILDER / CONTRACTOR","STRUCTURAL MAINTENANCE"]}},"AUTO CARE SERVICES":{"CAR CARE CENTRES":{"tertiary":["MAINTENANCE & REPAIRS","CLEANING & DETAILING"],"specific":["ENGINE REPAIRS","TRANSMISSION","ALIGNMENT","TYRES","CAR WASH","INTERIOR CAR DETAILING"]}},"ENTERTAINMENT":{"LIVE & PRE-RECORDED":{"tertiary":["HOSTED EVENTS","VENUES & SHOWS"],"specific":["CLUBS","PARTIES","CINEMA","ARENAS","STAGE SHOWS","AUDITORIUMS","PARKS"],"qualifiers":["ADULT","GENERAL","KIDS","SEASONAL"]},"MUSIC PRODUCTION":{"tertiary":["MUSICAL STUDIO SERVICES"],"specific":[]},"RELIGIOUS EVENTS & ACTIVITIES":{"tertiary":["RELIGIOUS EVENTS / ACTIVITIES","GOSPEL CONCERTS"],"specific":[]}},"BUSINESS OPERATORS":{"HUMAN RESOURCES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MAINTENANCE":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"ACCOUNTING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"HOUSEKEEPING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PROMOTIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MARKETING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"SALES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PUBLIC RELATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"DUTY OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OTHER DEPARTMENTS":{"tertiary":["GENERAL SERVICES & SUPPORT"],"specific":[]},"CLEANING & FACILITY SERVICES":{"tertiary":["CLEANING SERVICES"],"specific":[]}},"TOURISM INDUSTRY":{"HUMAN RESOURCES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MAINTENANCE":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"ACCOUNTING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"HOUSEKEEPING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PROMOTIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MARKETING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"SALES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PUBLIC RELATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"DUTY OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OTHER DEPARTMENTS":{"tertiary":["GENERAL SERVICES & SUPPORT"],"specific":[]},"VISITOR EXPERIENCES":{"tertiary":["ATTRACTIONS"],"specific":[]}},"HOTEL OPERATIONS":{"HUMAN RESOURCES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MAINTENANCE":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"ACCOUNTING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"HOUSEKEEPING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PROMOTIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MARKETING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"SALES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PUBLIC RELATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"DUTY OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OTHER DEPARTMENTS":{"tertiary":["GENERAL SERVICES & SUPPORT"],"specific":[]}},"RETAIL OPERATIONS / INDUSTRY":{"HUMAN RESOURCES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MAINTENANCE":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"ACCOUNTING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"HOUSEKEEPING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PROMOTIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MARKETING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"SALES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PUBLIC RELATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"DUTY OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OTHER DEPARTMENTS":{"tertiary":["GENERAL SERVICES & SUPPORT"],"specific":[]},"FASHION & CLOTHING":{"tertiary":["FASHION INDUSTRY","RETAIL CLOTHING"],"specific":[]}},"RESTAURANT SERVICES":{"HUMAN RESOURCES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MAINTENANCE":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"ACCOUNTING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"HOUSEKEEPING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PROMOTIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"MARKETING":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"SALES":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"PUBLIC RELATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"DUTY OPERATIONS":{"tertiary":["SERVICES & SUPPORT","SUPPLIES & EQUIPMENT","TRAINING & DEVELOPMENT"],"specific":[]},"OTHER DEPARTMENTS":{"tertiary":["GENERAL SERVICES & SUPPORT"],"specific":[]}}},"marketplace":{"Farm Products":[],"Motor Vehicles":[],"Hardware":[],"Suppliers":[],"Fashion & Retail":["Fashion Industry","Retail Clothing"],"Events & Entertainment":["Attractions","Musical Studio Services","Religious Events / Activities","Gospel Concerts"],"Food & Catering":["Catering Services","Cooking Services","Bakery Supplier","Ice Production Services"],"Business Services":["Cleaning Services"],"Beauty & Personal Care":["Hair Grooming Services","Cosmetic Services","Nail Technicians","Hair Stylists"],"Transport & Logistics":["Delivery Services","Haulage Services","Import & Export Services","Car Rental Services"],"Financial Services":["Micro Loan Services"],"Education & Coaching":["Educational Services","Coaching Services"],"General":[]}}'::jsonb);

CREATE FUNCTION private.business_taxonomy() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
    SELECT jsonb_object_agg(scope, data) FROM private.business_taxonomies;
$function$;
CREATE FUNCTION public.business_taxonomy() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $function$
    SELECT private.business_taxonomy();
$function$;
REVOKE ALL ON FUNCTION private.business_taxonomy(), public.business_taxonomy() FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.business_taxonomy(), public.business_taxonomy() TO anon, authenticated;

CREATE FUNCTION private.add_business_taxonomy_entry(p_scope text, p_parent text[], p_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
    uid uuid := auth.uid();
    catalog jsonb;
    name text := regexp_replace(trim(p_name), '[[:space:]]+', ' ', 'g');
    depth integer := cardinality(p_parent) + 1;
    choices jsonb;
    target text[];
BEGIN
    IF uid IS NULL OR NOT private.app_is_admin(uid) OR NOT EXISTS (
        SELECT 1 FROM auth.users WHERE id = uid AND email_confirmed_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'An active, verified administrator account is required.' USING ERRCODE = '42501';
    END IF;
    IF p_scope IS NULL OR p_scope NOT IN ('directory', 'marketplace')
        OR p_parent IS NULL OR array_ndims(p_parent) > 1 OR array_position(p_parent, NULL) IS NOT NULL
        OR depth < 1 OR depth > (CASE WHEN p_scope = 'marketplace' THEN 2 ELSE 4 END) THEN
        RAISE EXCEPTION 'Choose a catalogue and a valid parent path.';
    END IF;
    IF name IS NULL OR length(name) NOT BETWEEN 2 AND 100 OR name ~ '[[:cntrl:]]'
        OR position('›' in name) > 0 OR lower(name) IN ('__proto__', 'prototype', 'constructor') THEN
        RAISE EXCEPTION 'Use a name between 2 and 100 characters without control characters or path separators.';
    END IF;
    SELECT data INTO catalog FROM private.business_taxonomies WHERE scope = p_scope FOR UPDATE;
    IF catalog IS NULL THEN RAISE EXCEPTION 'The category catalogue is unavailable.'; END IF;
    IF depth > 1 AND NOT catalog ? p_parent[1] THEN RAISE EXCEPTION 'Choose an existing parent category.'; END IF;
    IF p_scope = 'directory' AND depth > 2 AND NOT (catalog -> p_parent[1]) ? p_parent[2] THEN
        RAISE EXCEPTION 'Choose a subcategory in the selected category.';
    END IF;
    IF depth = 4 AND NOT (catalog #> ARRAY[p_parent[1], p_parent[2], 'tertiary']) ? p_parent[3] THEN
        RAISE EXCEPTION 'Choose a specialization in the selected subcategory.';
    END IF;
    IF depth = 1 THEN
        IF EXISTS (SELECT 1 FROM jsonb_object_keys(catalog) value WHERE lower(value) = lower(name)) THEN
            RETURN catalog;
        END IF;
        catalog := jsonb_set(catalog, ARRAY[name], CASE WHEN p_scope = 'marketplace' THEN '[]' ELSE '{}' END::jsonb);
    ELSIF p_scope = 'directory' AND depth = 2 THEN
        IF EXISTS (SELECT 1 FROM jsonb_object_keys(catalog -> p_parent[1]) value WHERE lower(value) = lower(name)) THEN
            RETURN catalog;
        END IF;
        catalog := jsonb_set(catalog, p_parent || name, '{"tertiary":[],"specific":[]}'::jsonb);
    ELSE
        target := CASE WHEN p_scope = 'marketplace' THEN p_parent
            ELSE ARRAY[p_parent[1], p_parent[2], CASE WHEN depth = 3 THEN 'tertiary' ELSE 'specific' END] END;
        choices := coalesce(catalog #> target, '[]'::jsonb);
        IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(choices) value WHERE lower(value) = lower(name)) THEN
            RETURN catalog;
        END IF;
        catalog := jsonb_set(catalog, target, choices || to_jsonb(name));
    END IF;
    UPDATE private.business_taxonomies SET data = catalog, revision = revision + 1, updated_at = now(), updated_by = uid
    WHERE scope = p_scope;
    RETURN catalog;
END;
$function$;
CREATE FUNCTION public.add_business_taxonomy_entry(p_scope text, p_parent text[], p_name text) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $function$
    SELECT private.add_business_taxonomy_entry(p_scope, p_parent, p_name);
$function$;
REVOKE ALL ON FUNCTION private.add_business_taxonomy_entry(text,text[],text), public.add_business_taxonomy_entry(text,text[],text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.add_business_taxonomy_entry(text,text[],text), public.add_business_taxonomy_entry(text,text[],text) TO authenticated;

ALTER TABLE public.marketplace_flyers DROP CONSTRAINT marketplace_flyers_category_check;
ALTER TABLE public.marketplace_flyers ADD CONSTRAINT marketplace_flyers_category_check CHECK (length(category) BETWEEN 1 AND 100);

CREATE OR REPLACE FUNCTION private.manage_marketplace(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();adm boolean;f public.marketplace_flyers;v_id uuid;v_path text;v_hash text;v_status text;v_mime text;v_url text;v_days int;v_size bigint;v_segment text;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.id=uid AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'Sign in with an active, verified account.' USING ERRCODE='42501'; END IF;
 adm:=private.app_is_admin(uid);
 IF p_action='list' THEN
  RETURN jsonb_build_object('admin',adm,'rows',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT * FROM public.marketplace_flyers WHERE adm OR owner_id=uid ORDER BY created_at DESC LIMIT 100 OFFSET greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000)))x),'[]'));
 END IF;
 v_id:=(p_payload->>'id')::uuid;
 IF v_id IS NULL THEN RAISE EXCEPTION 'A flyer reference is required.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,10110));
 SELECT * INTO f FROM public.marketplace_flyers WHERE id=v_id FOR UPDATE;
 IF FOUND AND NOT(adm OR f.owner_id=uid) THEN RAISE EXCEPTION 'You can manage only your own flyers.' USING ERRCODE='42501'; END IF;
 IF p_action='edit' THEN
  IF f.id IS NULL OR f.status NOT IN ('published','pending','draft') THEN
   RAISE EXCEPTION 'Choose a published, pending or draft upload.';
  END IF;
  IF f.published_at IS NOT NULL AND f.expires_at <= now() THEN
   RAISE EXCEPTION 'This post has expired. Upload a new post to publish it again.';
  END IF;
 END IF;

 IF p_action IN ('reserve','edit') THEN
  v_url:=trim(coalesce(p_payload->>'contact_url',''));
  IF length(trim(coalesce(p_payload->>'business_name',''))) NOT BETWEEN 2 AND 150 OR length(trim(coalesce(p_payload->>'title',''))) NOT BETWEEN 3 AND 150 OR length(trim(coalesce(p_payload->>'tagline',''))) NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Complete the business name, title and brief market tagline.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM private.business_taxonomies t WHERE t.scope='marketplace' AND t.data ? coalesce(p_payload->>'category','')) THEN
   RAISE EXCEPTION 'Choose a Marketplace category.';
  END IF;
  v_segment:=trim(coalesce(p_payload->>'segment',''));
  IF v_segment<>'' AND NOT EXISTS (
   SELECT 1 FROM private.business_taxonomies t WHERE t.scope='marketplace' AND (t.data -> (p_payload->>'category')) ? v_segment
  ) THEN
   RAISE EXCEPTION 'Choose a subsegment in the selected category.';
  END IF;
  IF length(v_url)>2000 OR(v_url<>'' AND (v_url !~ '^https://[^/?#[:space:]@]+' OR v_url ~ '^https://[^/]*@' OR v_url ~ '[[:cntrl:][:space:]]')) THEN RAISE EXCEPTION 'Use a secure https contact or business link without credentials.'; END IF;
 END IF;

 IF p_action='edit' THEN
  -- A repeated request with the same values succeeds after a lost response.
  IF ROW(f.business_name,f.title,f.tagline,f.category,f.contact_url,f.segment) IS NOT DISTINCT FROM
     ROW(trim(p_payload->>'business_name'),trim(p_payload->>'title'),trim(p_payload->>'tagline'),p_payload->>'category',v_url,v_segment) THEN
   RETURN jsonb_build_object('id',f.id,'status',f.status,'updated_at',f.updated_at);
  END IF;
  IF f.updated_at IS DISTINCT FROM (p_payload->>'expected_updated_at')::timestamptz THEN
   RAISE EXCEPTION 'This flyer changed since you opened it. Refresh the register and reopen the editor.' USING ERRCODE='40001';
  END IF;
  UPDATE public.marketplace_flyers SET
   business_name=trim(p_payload->>'business_name'),
   title=trim(p_payload->>'title'),
   tagline=trim(p_payload->>'tagline'),
   category=p_payload->>'category',
   contact_url=v_url,
   segment=v_segment,
   status=CASE WHEN NOT adm AND f.status='published' THEN 'pending' ELSE f.status END,
   review_note='',
   updated_at=clock_timestamp()
  WHERE id=f.id RETURNING * INTO f;
  RETURN jsonb_build_object('id',f.id,'status',f.status,'updated_at',f.updated_at);
 END IF;

 IF p_action='reserve' THEN
  v_mime:=p_payload->>'mime';
  v_size:=(p_payload->>'file_size')::bigint;
  v_days:=coalesce((p_payload->>'display_days')::int,30);
  IF coalesce(v_mime,'') NOT IN('image/jpeg','image/png','image/webp','video/mp4') OR v_size IS NULL OR v_size < 1 OR v_size > (CASE WHEN v_mime='video/mp4' THEN 20971520 ELSE 5242880 END) THEN RAISE EXCEPTION 'Choose a supported image up to 5 MB or an MP4 up to 20 MB.'; END IF;
  IF v_days NOT IN(15,30) THEN RAISE EXCEPTION 'Choose a 15 or 30 day display period.'; END IF;
  IF p_payload->>'permission_confirmed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm permission to publish this business flyer and contact link.'; END IF;
  IF coalesce((p_payload->>'ajm_sponsored')::boolean,false) AND NOT adm THEN RAISE EXCEPTION 'Only AJM administrators can publish sponsored introductions.' USING ERRCODE='42501'; END IF;
  v_hash:=md5((p_payload-'request_id')::text);
  IF f.id IS NOT NULL THEN
   IF f.request_id=(p_payload->>'request_id')::uuid AND f.payload_hash=v_hash THEN RETURN jsonb_build_object('id',f.id,'path',f.image_path,'status',f.status,'duplicate',true); END IF;
   RAISE EXCEPTION 'This flyer reference is already used. Withdraw it and submit a new flyer.';
  END IF;
  IF NOT adm AND(SELECT count(*) FROM public.marketplace_flyers WHERE owner_id=uid AND created_at>now()-interval '1 day')>=10 THEN RAISE EXCEPTION 'Daily draft limit reached. Please try again tomorrow.'; END IF;
  v_path:=v_id::text||'/'||gen_random_uuid()::text||CASE v_mime WHEN 'image/png' THEN '.png' WHEN 'image/jpeg' THEN '.jpg' WHEN 'video/mp4' THEN '.mp4' ELSE '.webp' END;
  INSERT INTO public.marketplace_flyers(id,owner_id,business_name,title,tagline,category,segment,contact_url,image_path,mime,file_size,ajm_sponsored,permission_confirmed,display_days,request_id,payload_hash)
  VALUES(v_id,uid,trim(p_payload->>'business_name'),trim(p_payload->>'title'),trim(p_payload->>'tagline'),p_payload->>'category',v_segment,v_url,v_path,v_mime,v_size,adm AND coalesce((p_payload->>'ajm_sponsored')::boolean,false),true,v_days,(p_payload->>'request_id')::uuid,v_hash);
  RETURN jsonb_build_object('id',v_id,'path',v_path,'status','draft');
 END IF;
 IF f.id IS NULL THEN RAISE EXCEPTION 'Flyer not found.'; END IF;
 IF p_action='submit' THEN
  IF f.status IN('pending','published') THEN RETURN jsonb_build_object('id',f.id,'status',f.status,'duplicate',true); END IF;
  IF f.mime='video/mp4' AND f.video_duration_ms IS NULL THEN
   RAISE EXCEPTION 'The mini-ad must pass video validation before it can be submitted.';
  END IF;
  IF f.status<>'draft' THEN RAISE EXCEPTION 'Only a draft can be submitted.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='marketplace-flyers' AND o.name=f.image_path AND o.metadata->>'mimetype'=f.mime AND(o.metadata->>'size')::bigint=f.file_size) THEN RAISE EXCEPTION 'The image upload is incomplete. Retry the upload before submitting.'; END IF;
  IF NOT adm AND EXISTS(SELECT 1 FROM public.marketplace_flyers WHERE owner_id=uid AND id<>f.id AND submitted_at>now()-interval '7 days') THEN RAISE EXCEPTION 'Members may submit one flyer per seven days. Your draft is saved for later.'; END IF;
  v_status:=CASE WHEN adm THEN 'published' ELSE 'pending' END;
  UPDATE public.marketplace_flyers SET status=v_status,submitted_at=now(),published_at=CASE WHEN adm THEN now() END,expires_at=CASE WHEN adm THEN now()+make_interval(days=>display_days) END,reviewed_by=CASE WHEN adm THEN uid END,updated_at=now() WHERE id=f.id;
 ELSIF p_action='review' THEN
  IF NOT adm THEN RAISE EXCEPTION 'Administrator access is required.' USING ERRCODE='42501'; END IF;
  v_status:=p_payload->>'status';
  IF f.status<>'pending' OR v_status IS NULL OR v_status NOT IN('published','rejected') THEN RAISE EXCEPTION 'Choose publish or reject for a pending flyer.'; END IF;
  IF v_status='rejected' AND length(trim(coalesce(p_payload->>'note','')))<5 THEN RAISE EXCEPTION 'Explain why this flyer was returned.'; END IF;
  IF v_status='published' AND f.published_at IS NOT NULL AND f.expires_at <= now() THEN
   RAISE EXCEPTION 'This post has expired. Upload a new post to publish it again.';
  END IF;
  IF v_status='published' AND f.mime='video/mp4' AND f.video_duration_ms IS NULL THEN
   RAISE EXCEPTION 'The mini-ad must pass video validation before publication.';
  END IF;
  IF v_status='published' AND NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='marketplace-flyers' AND o.name=f.image_path AND o.metadata->>'mimetype'=f.mime AND(o.metadata->>'size')::bigint=f.file_size) THEN RAISE EXCEPTION 'The image upload is incomplete.'; END IF;
  UPDATE public.marketplace_flyers SET status=v_status,review_note=left(coalesce(p_payload->>'note',''),1000),reviewed_by=uid,published_at=CASE WHEN v_status='published' THEN coalesce(f.published_at,now()) ELSE f.published_at END,expires_at=CASE WHEN v_status='published' THEN coalesce(f.expires_at,now()+make_interval(days=>display_days)) ELSE f.expires_at END,updated_at=now() WHERE id=f.id;
 ELSIF p_action='withdraw' THEN
  UPDATE public.marketplace_flyers SET status='withdrawn',updated_at=now() WHERE id=f.id;
 ELSE RAISE EXCEPTION 'Unknown Marketplace action.'; END IF;
 RETURN(SELECT jsonb_build_object('id',id,'status',status) FROM public.marketplace_flyers WHERE id=f.id);
END $$;


NOTIFY pgrst, 'reload schema';
