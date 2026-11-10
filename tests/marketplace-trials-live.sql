-- Always run inside BEGIN / ROLLBACK. No trial customer or flyer is committed.
DO $checks$
DECLARE a uuid;m uuid;o uuid;lid uuid:=gen_random_uuid();fid uuid:=gen_random_uuid();tid uuid:=gen_random_uuid();did uuid:=gen_random_uuid();
 silver uuid;premium uuid;display uuid;paid uuid;sub uuid;ad uuid;r jsonb;payload jsonb;path text;paid_exp timestamptz:=now()+interval '90 days';v_count bigint;page_before jsonb;
BEGIN
 SELECT id INTO a FROM public.profiles WHERE role='admin' AND account_status='active' ORDER BY id LIMIT 1;
 SELECT p.id INTO m FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.role<>'admin' AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL ORDER BY p.id LIMIT 1;
 SELECT p.id INTO o FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.id NOT IN(a,m) AND p.role<>'admin' AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL ORDER BY p.id LIMIT 1;
 IF a IS NULL OR m IS NULL OR o IS NULL THEN RAISE EXCEPTION 'Verified test actors missing'; END IF;
 IF has_function_privilege('anon','public.manage_marketplace(text,jsonb)','EXECUTE') OR has_table_privilege('authenticated','public.marketplace_flyers','INSERT') OR has_table_privilege('authenticated','private.ajm_package_trials','SELECT') THEN RAISE EXCEPTION 'Marketplace privilege boundary failed'; END IF;
 PERFORM set_config('request.jwt.claim.sub',m::text,true);
 payload:=jsonb_build_object('id',fid,'request_id',gen_random_uuid(),'business_name','USSE rollback verification','title','Rolled-back product flyer','tagline','Synthetic verification only; never commit this flyer.','category','Suppliers','mime','image/png','file_size',50,'permission_confirmed',true,'display_days',30);
 r:=public.manage_marketplace('reserve',payload);path:=r->>'path';
 IF(public.manage_marketplace('reserve',payload)->>'path')<>path THEN RAISE EXCEPTION 'Flyer retry changed path'; END IF;
 BEGIN PERFORM public.manage_marketplace('submit',jsonb_build_object('id',fid));RAISE EXCEPTION 'Incomplete image accepted';EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE '%incomplete%' THEN RAISE;END IF;END;
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('marketplace-flyers',path,'{"mimetype":"image/png","size":50}');
 IF(public.manage_marketplace('submit',jsonb_build_object('id',fid))->>'status')<>'pending' THEN RAISE EXCEPTION 'Member skipped review'; END IF;
 IF(public.manage_marketplace('submit',jsonb_build_object('id',fid))->>'duplicate')<>'true' THEN RAISE EXCEPTION 'Submission retry not idempotent'; END IF;
 BEGIN PERFORM public.manage_marketplace('review',jsonb_build_object('id',fid,'status','published'));RAISE EXCEPTION 'Member moderated flyer';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub',o::text,true);
 BEGIN PERFORM public.manage_marketplace('withdraw',jsonb_build_object('id',fid));RAISE EXCEPTION 'Other member changed flyer';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub',m::text,true);
 payload:=payload||jsonb_build_object('id',gen_random_uuid(),'request_id',gen_random_uuid());r:=public.manage_marketplace('reserve',payload);
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('marketplace-flyers',r->>'path','{"mimetype":"image/png","size":50}');
 BEGIN PERFORM public.manage_marketplace('submit',jsonb_build_object('id',payload->>'id'));RAISE EXCEPTION 'Weekly quota skipped';EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE '%seven days%' THEN RAISE;END IF;END;
 PERFORM set_config('request.jwt.claim.sub',a::text,true);PERFORM public.manage_marketplace('review',jsonb_build_object('id',fid,'status','published'));
 IF(public.marketplace_public(jsonb_build_object('id',fid))->>'total')::int<>1 THEN RAISE EXCEPTION 'Published flyer missing'; END IF;
 UPDATE public.marketplace_flyers SET expires_at=now()-interval '1 second' WHERE id=fid;
 IF(public.marketplace_public(jsonb_build_object('id',fid))->>'total')::int<>0 OR private.marketplace_image_access(path,false) IS DISTINCT FROM true THEN
 -- Administrator retains image review access after expiry; the anonymous check follows.
  IF(public.marketplace_public(jsonb_build_object('id',fid))->>'total')::int<>0 THEN RAISE EXCEPTION 'Expired flyer public'; END IF;
 END IF;
 PERFORM set_config('request.jwt.claim.sub','',true);IF private.marketplace_image_access(path,false) THEN RAISE EXCEPTION 'Expired image public'; END IF;
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 SELECT id INTO silver FROM public.ad_packages WHERE is_active AND product_type='webpage' AND webpage_tier='silver' AND webpage_enabled ORDER BY id LIMIT 1;
 SELECT id INTO premium FROM public.ad_packages WHERE is_active AND product_type='webpage' AND webpage_tier='platinum' AND webpage_enabled ORDER BY id LIMIT 1;
 SELECT id INTO display FROM public.ad_packages WHERE is_active AND product_type='display_ad' AND cardinality(placements)>0 ORDER BY id LIMIT 1;
 IF silver IS NULL OR premium IS NULL OR display IS NULL THEN RAISE EXCEPTION 'Trial catalog incomplete'; END IF;
 INSERT INTO public.listings(id,owner_user_id,business_name,category,description,location,status,published_at,expires_at,market_segment)
 VALUES(lid,m,'USSE rolled-back trial verification','BUSINESS SERVICES','Synthetic trial verification. This business must never be committed.','Kingston, Jamaica','approved',now(),now()+interval '100 days','local-business');
 paid:=gen_random_uuid();INSERT INTO public.ad_subscriptions(id,user_id,listing_id,package_id,status,payment_method,payment_reference,expires_at) VALUES(paid,m,lid,silver,'active','bank_transfer','ROLLED-BACK-VERIFY',paid_exp);
 SELECT to_jsonb(w) INTO page_before FROM public.listing_webpages w WHERE listing_id=lid;
 SELECT count(*) INTO v_count FROM public.ad_orders;
 r:=public.manage_ajm_trials('activate',jsonb_build_object('id',tid,'listing_id',lid,'package_id',premium,'cohort','internal','duration_days',30,'consent',true));
 IF(r->>'complimentary')::boolean IS DISTINCT FROM true OR (r->>'expires_at')::timestamptz-(r->>'starts_at')::timestamptz<>interval '30 days' THEN RAISE EXCEPTION 'Trial duration or price failed'; END IF;
 IF(public.manage_ajm_trials('activate',jsonb_build_object('id',tid,'listing_id',lid,'package_id',premium))->>'duplicate')<>'true' THEN RAISE EXCEPTION 'Trial retry duplicated'; END IF;
 IF(SELECT to_jsonb(w) FROM public.listing_webpages w WHERE listing_id=lid) IS DISTINCT FROM page_before THEN RAISE EXCEPTION 'Trial changed paid page'; END IF;
 IF(SELECT count(*) FROM public.ad_orders)<>v_count THEN RAISE EXCEPTION 'Complimentary trial created a revenue order'; END IF;
 UPDATE public.listing_webpages SET tier='platinum',booking_url='https://example.test/book',starter_generated=false WHERE listing_id=lid;
 IF public.public_entitled_webpage(lid)->>'tier'<>'platinum' THEN RAISE EXCEPTION 'Premium trial entitlement missing'; END IF;
 SELECT id INTO sub FROM public.ad_subscriptions WHERE trial_id=tid;UPDATE public.ad_subscriptions SET expires_at=now()-interval '1 second' WHERE id=sub;
 r:=public.public_entitled_webpage(lid);IF r->>'tier'<>'silver' OR r->>'booking_url' IS NOT NULL THEN RAISE EXCEPTION 'Expired trial did not fall back to paid tier'; END IF;
 IF(SELECT booking_url FROM public.listing_webpages WHERE listing_id=lid)<>'https://example.test/book' THEN RAISE EXCEPTION 'Premium content lost'; END IF;
 PERFORM public.manage_ajm_trials('end',jsonb_build_object('id',tid));IF NOT EXISTS(SELECT 1 FROM public.ad_subscriptions WHERE id=paid AND status='active' AND expires_at=paid_exp) THEN RAISE EXCEPTION 'Paid subscription changed'; END IF;
 r:=public.manage_ajm_trials('activate',jsonb_build_object('id',did,'listing_id',lid,'package_id',display,'cohort','public','duration_days',30,'consent',true,'headline','Rolled-back advertiser','body_text','Synthetic demonstration artwork verification only.','cta_url','https://example.test','media_url','https://example.test/flyer.png','banner_size','rectangle'));
 SELECT id INTO ad FROM public.advertisements WHERE creative_metadata->>'trial_id'=did::text LIMIT 1;
 IF ad IS NULL THEN RAISE EXCEPTION 'Trial ad not delivered'; END IF;
 PERFORM public.record_ad_event(ad,'click','rolled-back-marketplace-verification');
 IF NOT EXISTS(SELECT 1 FROM public.ad_events WHERE advertisement_id=ad AND metadata->>'trial_id'=did::text AND order_id IS NULL) THEN RAISE EXCEPTION 'Trial event attribution failed'; END IF;
 PERFORM public.manage_ajm_trials('end',jsonb_build_object('id',did));IF EXISTS(SELECT 1 FROM public.advertisements WHERE id=ad AND status='active') THEN RAISE EXCEPTION 'Ended trial still active'; END IF;
END $checks$;
