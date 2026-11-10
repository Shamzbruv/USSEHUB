-- Public commercial flyers and explicitly complimentary, time-limited package trials.
-- Existing paid orders and subscriptions are never rewritten by trial operations.
CREATE TABLE public.marketplace_flyers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES public.profiles(id),
 business_name text NOT NULL CHECK(length(business_name) BETWEEN 2 AND 150),
 title text NOT NULL CHECK(length(title) BETWEEN 3 AND 150),
 tagline text NOT NULL CHECK(length(tagline) BETWEEN 5 AND 240),
 category text NOT NULL CHECK(category IN ('Farm Products','Motor Vehicles','Hardware','Suppliers','Events & Entertainment','Business Services')),
 contact_url text NOT NULL DEFAULT '', image_path text NOT NULL UNIQUE, mime text NOT NULL CHECK(mime IN ('image/jpeg','image/png','image/webp')),
 file_size bigint NOT NULL CHECK(file_size BETWEEN 1 AND 5242880),
 status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','pending','published','rejected','withdrawn')),
 ajm_sponsored boolean NOT NULL DEFAULT false, permission_confirmed boolean NOT NULL,
 display_days integer NOT NULL DEFAULT 30 CHECK(display_days IN (15,30)),
 request_id uuid NOT NULL UNIQUE, payload_hash text NOT NULL,
 submitted_at timestamptz, published_at timestamptz, expires_at timestamptz,
 review_note text NOT NULL DEFAULT '', reviewed_by uuid REFERENCES public.profiles(id),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX marketplace_public_idx ON public.marketplace_flyers(status,expires_at,category,published_at DESC);
CREATE INDEX marketplace_owner_idx ON public.marketplace_flyers(owner_id,submitted_at DESC);
ALTER TABLE public.marketplace_flyers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketplace_flyers FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.marketplace_flyers TO authenticated;
CREATE POLICY marketplace_owner_read ON public.marketplace_flyers FOR SELECT TO authenticated
 USING(owner_id=(SELECT auth.uid()) OR private.app_is_admin((SELECT auth.uid())));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('marketplace-flyers','marketplace-flyers',false,5242880,ARRAY['image/jpeg','image/png','image/webp']);
CREATE FUNCTION private.marketplace_image_access(p_path text,p_upload boolean) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.marketplace_flyers f WHERE f.image_path=p_path AND
 CASE WHEN p_upload THEN f.status='draft' AND f.updated_at>now()-interval '30 minutes' AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.account_status='active' AND(p.id=f.owner_id OR p.role='admin'))
 ELSE (f.status='published' AND f.expires_at>now()) OR EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.account_status='active' AND(p.id=f.owner_id OR p.role='admin')) END)
$$;
REVOKE ALL ON FUNCTION private.marketplace_image_access(text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.marketplace_image_access(text,boolean) TO anon,authenticated;
CREATE POLICY marketplace_reserved_upload ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='marketplace-flyers' AND private.marketplace_image_access(name,true));
CREATE POLICY marketplace_authorized_read ON storage.objects FOR SELECT TO anon,authenticated
 USING(bucket_id='marketplace-flyers' AND private.marketplace_image_access(name,false));
CREATE FUNCTION private.marketplace_public(p_payload jsonb) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH matched AS(SELECT f.id,f.business_name,f.title,f.tagline,f.category,f.contact_url,f.image_path,f.ajm_sponsored,f.published_at,f.expires_at
 FROM public.marketplace_flyers f WHERE f.status='published' AND f.expires_at>now()
 AND(coalesce(p_payload->>'id','')='' OR f.id=(p_payload->>'id')::uuid)
 AND(coalesce(p_payload->>'category','')='' OR f.category=p_payload->>'category')
 AND(coalesce(p_payload->>'search','')='' OR concat_ws(' ',f.business_name,f.title,f.tagline) ILIKE '%'||left(p_payload->>'search',100)||'%')),
 page AS(SELECT * FROM matched ORDER BY published_at DESC,id LIMIT 24 OFFSET greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000)))
 SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY published_at DESC,id) FROM page),'[]'))
$$;
CREATE FUNCTION public.marketplace_public(p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.marketplace_public(p_payload)$$;
REVOKE ALL ON FUNCTION private.marketplace_public(jsonb),public.marketplace_public(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.marketplace_public(jsonb),public.marketplace_public(jsonb) TO anon,authenticated;
CREATE FUNCTION private.manage_marketplace(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();adm boolean;f public.marketplace_flyers;v_id uuid;v_path text;v_hash text;v_status text;v_mime text;v_url text;v_days int;v_size bigint;
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
 IF p_action='reserve' THEN
  v_mime:=p_payload->>'mime';v_size:=(p_payload->>'file_size')::bigint;v_days:=coalesce((p_payload->>'display_days')::int,30);v_url:=trim(coalesce(p_payload->>'contact_url',''));
  IF length(trim(coalesce(p_payload->>'business_name',''))) NOT BETWEEN 2 AND 150 OR length(trim(coalesce(p_payload->>'title',''))) NOT BETWEEN 3 AND 150 OR length(trim(coalesce(p_payload->>'tagline',''))) NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Complete the business name, title and brief market tagline.'; END IF;
  IF coalesce(p_payload->>'category','') NOT IN('Farm Products','Motor Vehicles','Hardware','Suppliers','Events & Entertainment','Business Services') THEN RAISE EXCEPTION 'Choose a Marketplace category.'; END IF;
  IF coalesce(v_mime,'') NOT IN('image/jpeg','image/png','image/webp') OR v_size IS NULL OR v_size NOT BETWEEN 1 AND 5242880 THEN RAISE EXCEPTION 'Choose a JPG, PNG or WebP image up to 5 MB.'; END IF;
  IF v_days NOT IN(15,30) THEN RAISE EXCEPTION 'Choose a 15 or 30 day display period.'; END IF;
  IF length(v_url)>2000 OR(v_url<>'' AND (v_url !~ '^https://[^/?#[:space:]@]+' OR v_url ~ '^https://[^/]*@' OR v_url ~ '[[:cntrl:][:space:]]')) THEN RAISE EXCEPTION 'Use a secure https contact or business link without credentials.'; END IF;
  IF p_payload->>'permission_confirmed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm permission to publish this business flyer and contact link.'; END IF;
  IF coalesce((p_payload->>'ajm_sponsored')::boolean,false) AND NOT adm THEN RAISE EXCEPTION 'Only AJM administrators can publish sponsored introductions.' USING ERRCODE='42501'; END IF;
  v_hash:=md5((p_payload-'request_id')::text);
  IF f.id IS NOT NULL THEN
   IF f.request_id=(p_payload->>'request_id')::uuid AND f.payload_hash=v_hash THEN RETURN jsonb_build_object('id',f.id,'path',f.image_path,'status',f.status,'duplicate',true); END IF;
   RAISE EXCEPTION 'This flyer reference is already used. Withdraw it and submit a new flyer.';
  END IF;
  IF NOT adm AND(SELECT count(*) FROM public.marketplace_flyers WHERE owner_id=uid AND created_at>now()-interval '1 day')>=10 THEN RAISE EXCEPTION 'Daily draft limit reached. Please try again tomorrow.'; END IF;
  v_path:=v_id::text||'/'||gen_random_uuid()::text||CASE v_mime WHEN 'image/png' THEN '.png' WHEN 'image/jpeg' THEN '.jpg' ELSE '.webp' END;
  INSERT INTO public.marketplace_flyers(id,owner_id,business_name,title,tagline,category,contact_url,image_path,mime,file_size,ajm_sponsored,permission_confirmed,display_days,request_id,payload_hash)
  VALUES(v_id,uid,trim(p_payload->>'business_name'),trim(p_payload->>'title'),trim(p_payload->>'tagline'),p_payload->>'category',v_url,v_path,v_mime,v_size,adm AND coalesce((p_payload->>'ajm_sponsored')::boolean,false),true,v_days,(p_payload->>'request_id')::uuid,v_hash);
  RETURN jsonb_build_object('id',v_id,'path',v_path,'status','draft');
 END IF;
 IF f.id IS NULL THEN RAISE EXCEPTION 'Flyer not found.'; END IF;
 IF p_action='submit' THEN
  IF f.status IN('pending','published') THEN RETURN jsonb_build_object('id',f.id,'status',f.status,'duplicate',true); END IF;
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
  IF v_status='published' AND NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='marketplace-flyers' AND o.name=f.image_path AND o.metadata->>'mimetype'=f.mime AND(o.metadata->>'size')::bigint=f.file_size) THEN RAISE EXCEPTION 'The image upload is incomplete.'; END IF;
  UPDATE public.marketplace_flyers SET status=v_status,review_note=left(coalesce(p_payload->>'note',''),1000),reviewed_by=uid,published_at=CASE WHEN v_status='published' THEN now() END,expires_at=CASE WHEN v_status='published' THEN now()+make_interval(days=>display_days) END,updated_at=now() WHERE id=f.id;
 ELSIF p_action='withdraw' THEN
  UPDATE public.marketplace_flyers SET status='withdrawn',updated_at=now() WHERE id=f.id;
 ELSE RAISE EXCEPTION 'Unknown Marketplace action.'; END IF;
 RETURN(SELECT jsonb_build_object('id',id,'status',status) FROM public.marketplace_flyers WHERE id=f.id);
END $$;
CREATE FUNCTION public.manage_marketplace(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_marketplace(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_marketplace(text,jsonb),public.manage_marketplace(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_marketplace(text,jsonb),public.manage_marketplace(text,jsonb) TO authenticated;

CREATE TABLE private.ajm_package_trials(
 id uuid PRIMARY KEY,listing_id uuid NOT NULL REFERENCES public.listings(id),package_id uuid NOT NULL REFERENCES public.ad_packages(id),
 package_snapshot jsonb NOT NULL,cohort text NOT NULL CHECK(cohort IN('internal','public')),
 duration_days int NOT NULL CHECK(duration_days IN(15,30)),starts_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'active' CHECK(status IN('active','ended')),created_by uuid NOT NULL REFERENCES public.profiles(id),
 subscription_id uuid NOT NULL UNIQUE,created_at timestamptz NOT NULL DEFAULT now(),ended_at timestamptz,
 CHECK(expires_at>starts_at)
);
ALTER TABLE private.ajm_package_trials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.ajm_package_trials FROM PUBLIC,anon,authenticated;
ALTER TABLE public.ad_subscriptions ADD COLUMN trial_id uuid UNIQUE REFERENCES private.ajm_package_trials(id);
CREATE INDEX ajm_trial_listing_idx ON private.ajm_package_trials(listing_id,status,expires_at);
-- Preserve the paid page and all its authored content on activation. A trial
-- subscription grants temporary access without running paid-tier reconciliation.
DO $$DECLARE def text;BEGIN
 SELECT pg_get_functiondef('private.ensure_active_webpage_draft()'::regprocedure) INTO def;
 def:=replace(def,E'BEGIN\n',E'BEGIN\n  IF NEW.trial_id IS NOT NULL THEN RETURN NEW; END IF;\n');
 EXECUTE def;
END $$;
CREATE FUNCTION private.manage_ajm_trials(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();t private.ajm_package_trials;l public.listings;p public.ad_packages;v_id uuid;v_sub uuid;v_days int;v_url text;v_media text;v_place text;v_now timestamptz:=now();
BEGIN
 IF NOT private.app_is_admin(uid) THEN RAISE EXCEPTION 'Active administrator access is required.' USING ERRCODE='42501'; END IF;
 IF p_action='catalog' THEN
  RETURN jsonb_build_object('listings',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',business_name)) FROM public.listings WHERE status='approved' AND owner_user_id IS NOT NULL AND(expires_at IS NULL OR expires_at>now())),'[]'),
   'packages',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'type',product_type,'tier',webpage_tier,'placements',placements) ORDER BY sort_order) FROM public.ad_packages WHERE is_active AND product_type IN('display_ad','webpage')),'[]'));
 ELSIF p_action='list' THEN
  RETURN jsonb_build_object('report_from',(timezone('UTC',now()))::date-29,'report_to',(timezone('UTC',now()))::date,'rows',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(
   SELECT tr.id,tr.listing_id,ls.business_name,tr.package_snapshot,tr.cohort,tr.starts_at,tr.expires_at,CASE WHEN tr.status='ended' THEN 'ended' WHEN tr.expires_at<=now() THEN 'expired' ELSE 'active' END AS status,
   (SELECT count(*) FROM public.ad_events e JOIN public.advertisements a ON a.id=e.advertisement_id WHERE a.subscription_id=tr.subscription_id AND e.event_type IN('impression','view') AND e.occurred_on>=(timezone('UTC',now()))::date-29) AS impressions,
   (SELECT count(*) FROM public.ad_events e JOIN public.advertisements a ON a.id=e.advertisement_id WHERE a.subscription_id=tr.subscription_id AND e.event_type='click' AND e.occurred_on>=(timezone('UTC',now()))::date-29) AS clicks,
   (SELECT count(*) FROM public.ad_events e JOIN public.advertisements a ON a.id=e.advertisement_id WHERE a.subscription_id=tr.subscription_id AND e.event_type IN('lead','call','chat','booking') AND e.occurred_on>=(timezone('UTC',now()))::date-29) AS leads
   FROM private.ajm_package_trials tr JOIN public.listings ls ON ls.id=tr.listing_id ORDER BY tr.created_at DESC LIMIT 100)x),'[]'));
 END IF;
 v_id:=(p_payload->>'id')::uuid;IF v_id IS NULL THEN RAISE EXCEPTION 'A stable trial reference is required.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(coalesce(p_payload->>'listing_id',v_id::text),10111));
 SELECT * INTO t FROM private.ajm_package_trials WHERE id=v_id FOR UPDATE;
 IF p_action='end' THEN
  IF t.id IS NULL THEN RAISE EXCEPTION 'Trial not found.'; END IF;
  UPDATE private.ajm_package_trials SET status='ended',ended_at=v_now WHERE id=t.id;
  UPDATE public.ad_subscriptions SET status='cancelled' WHERE id=t.subscription_id;
  UPDATE public.advertisements SET status='cancelled' WHERE subscription_id=t.subscription_id;
  RETURN jsonb_build_object('id',t.id,'status','ended');
 ELSIF p_action<>'activate' THEN RAISE EXCEPTION 'Unknown trial action.'; END IF;
 IF t.id IS NOT NULL THEN
  IF t.listing_id=(p_payload->>'listing_id')::uuid AND t.package_id=(p_payload->>'package_id')::uuid THEN RETURN jsonb_build_object('id',t.id,'duplicate',true,'expires_at',t.expires_at); END IF;
  RAISE EXCEPTION 'Trial reference already used.';
 END IF;
 IF p_payload->>'consent' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm the real business has agreed to this complimentary trial.'; END IF;
 SELECT * INTO l FROM public.listings WHERE id=(p_payload->>'listing_id')::uuid AND status='approved' AND owner_user_id IS NOT NULL AND(expires_at IS NULL OR expires_at>now()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Choose a current approved business with an account owner.'; END IF;
 SELECT * INTO p FROM public.ad_packages WHERE id=(p_payload->>'package_id')::uuid AND is_active;
 IF NOT FOUND OR p.product_type NOT IN('webpage','display_ad') THEN RAISE EXCEPTION 'Choose an active advertising or webpage package.'; END IF;
 v_days:=coalesce((p_payload->>'duration_days')::int,30);
 IF v_days NOT IN(15,30) OR(p.product_type='display_ad' AND v_days<>30) THEN RAISE EXCEPTION 'Banner package trials run for 30 days. Webpage trials allow 15 or 30 days.'; END IF;
 IF coalesce(p_payload->>'cohort','') NOT IN('internal','public') THEN RAISE EXCEPTION 'Identify an internal or public demonstration candidate.'; END IF;
 IF EXISTS(SELECT 1 FROM private.ajm_package_trials x JOIN public.ad_packages xp ON xp.id=x.package_id WHERE x.listing_id=l.id AND x.status='active' AND x.expires_at>now() AND xp.product_type=p.product_type) THEN RAISE EXCEPTION 'This business already has an active trial of this product type.'; END IF;
 IF p.product_type='webpage' AND(NOT coalesce(p.webpage_enabled,false) OR private.ajm_tier_rank(p.webpage_tier)=0) THEN RAISE EXCEPTION 'This package does not enable a webpage.'; END IF;
 IF p.product_type='webpage' AND EXISTS(SELECT 1 FROM public.ad_subscriptions s JOIN public.ad_packages sp ON sp.id=s.package_id WHERE s.listing_id=l.id AND s.status='active' AND(s.expires_at IS NULL OR s.expires_at>now()) AND sp.webpage_enabled AND sp.is_active AND private.ajm_tier_rank(sp.webpage_tier)>=private.ajm_tier_rank(p.webpage_tier)) THEN RAISE EXCEPTION 'Choose an upgrade above the business''s current webpage entitlement.'; END IF;
 v_url:=trim(coalesce(p_payload->>'cta_url',''));v_media:=trim(coalesce(p_payload->>'media_url',''));
 IF p.product_type='display_ad' THEN
  IF coalesce(array_length(p.placements,1),0)=0 THEN RAISE EXCEPTION 'Configure this package''s placements first.'; END IF;
  IF length(trim(coalesce(p_payload->>'headline',''))) NOT BETWEEN 3 AND 150 OR length(trim(coalesce(p_payload->>'body_text',''))) NOT BETWEEN 10 AND 1000 THEN RAISE EXCEPTION 'Provide the actual advertiser headline and description.'; END IF;
  IF v_url !~ '^https://[^/?#[:space:]@]+' OR v_media !~ '^https://[^/?#[:space:]@]+' OR v_url ~ '^https://[^/]*@' OR v_media ~ '^https://[^/]*@' OR length(v_url)>2000 OR length(v_media)>2000 OR v_url ~ '[[:cntrl:][:space:]]' OR v_media ~ '[[:cntrl:][:space:]]' THEN RAISE EXCEPTION 'Provide secure artwork and destination URLs without credentials.'; END IF;
  IF coalesce(p_payload->>'banner_size','') NOT IN('leaderboard','wide','rectangle','skyscraper','mobile') THEN RAISE EXCEPTION 'Choose the artwork format.'; END IF;
 END IF;
 v_sub:=gen_random_uuid();
 INSERT INTO private.ajm_package_trials(id,listing_id,package_id,package_snapshot,cohort,duration_days,starts_at,expires_at,created_by,subscription_id)
 VALUES(v_id,l.id,p.id,jsonb_build_object('name',p.name,'type',p.product_type,'tier',p.webpage_tier,'placements',p.placements,'complimentary',true,'price',0),p_payload->>'cohort',v_days,v_now,v_now+make_interval(days=>v_days),uid,v_sub);
 INSERT INTO public.ad_subscriptions(id,user_id,listing_id,package_id,status,payment_method,payment_reference,expires_at,trial_id)
 VALUES(v_sub,l.owner_user_id,l.id,p.id,'active','complimentary','AJM trial '||v_id::text,v_now+make_interval(days=>v_days),v_id);
 IF p.product_type='webpage' THEN
  INSERT INTO public.listing_webpages(listing_id,tier,market_segment,page_status,tagline,logo_url,address,about_text,created_by,starter_generated)
  VALUES(l.id,p.webpage_tier,coalesce(l.market_segment,'local-business'),'published',left(l.description,140),l.image_url,l.location,l.description,uid,true) ON CONFLICT(listing_id) DO NOTHING;
  PERFORM private.sync_listing_webpage_promotion(l.id);
 ELSE
  FOREACH v_place IN ARRAY p.placements LOOP
   INSERT INTO public.advertisements(subscription_id,user_id,listing_id,package_id,placement,headline,body_text,cta_label,cta_url,creative_metadata,starts_at,expires_at)
   VALUES(v_sub,l.owner_user_id,l.id,p.id,v_place,trim(p_payload->>'headline'),trim(p_payload->>'body_text'),'View business',v_url,jsonb_build_object('media_url',v_media,'banner_size',p_payload->>'banner_size','source','complimentary_trial','trial_id',v_id),v_now,v_now+make_interval(days=>v_days));
  END LOOP;
 END IF;
 RETURN jsonb_build_object('id',v_id,'status','active','starts_at',v_now,'expires_at',v_now+make_interval(days=>v_days),'complimentary',true);
END $$;
CREATE FUNCTION public.manage_ajm_trials(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_ajm_trials(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_ajm_trials(text,jsonb),public.manage_ajm_trials(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_ajm_trials(text,jsonb),public.manage_ajm_trials(text,jsonb) TO authenticated;
-- Render only the currently entitled tier. Premium content remains saved for a
-- later upgrade; after expiry the paid tier continues without a destructive edit.
CREATE FUNCTION private.public_entitled_webpage(p_listing_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.listing_webpages;v_tier text;r jsonb;
BEGIN
 SELECT p.webpage_tier INTO v_tier FROM public.ad_subscriptions s JOIN public.ad_packages p ON p.id=s.package_id JOIN public.listings l ON l.id=s.listing_id AND l.owner_user_id=s.user_id
 WHERE s.listing_id=p_listing_id AND s.status='active' AND(s.expires_at IS NULL OR s.expires_at>now()) AND p.is_active AND p.webpage_enabled AND l.status='approved' AND(l.expires_at IS NULL OR l.expires_at>now()) AND(l.published_at IS NULL OR l.published_at<=now()) ORDER BY private.ajm_tier_rank(p.webpage_tier) DESC LIMIT 1;
 IF v_tier IS NULL THEN RETURN NULL; END IF;
 SELECT * INTO w FROM public.listing_webpages WHERE listing_id=p_listing_id AND page_status='published';IF NOT FOUND THEN RETURN NULL; END IF;
 IF private.ajm_tier_rank(w.tier)<private.ajm_tier_rank(v_tier) THEN v_tier:=w.tier; END IF;
 r:=to_jsonb(w)-'created_by';r:=r||jsonb_build_object('tier',v_tier);
 IF v_tier<>'platinum' THEN r:=r||jsonb_build_object('booking_url',null,'virtual_tour_url',null,'call_tracking_phone',null,'live_chat_url',null); END IF;
 IF v_tier='silver' THEN r:=r||jsonb_build_object('hero_media_url',null,'video_url',null,'map_embed_url',null,'offer_title',null,'offer_details',null,'offer_code',null,'testimonials','[]'::jsonb,'lead_form_enabled',false,'gallery_urls',to_jsonb(w.gallery_urls[1:3]));
 ELSE r:=r||jsonb_build_object('gallery_urls',to_jsonb(w.gallery_urls[1:12])); END IF;
 IF v_tier='platinum' THEN r:=r||jsonb_build_object('gallery_urls',to_jsonb(w.gallery_urls)); END IF;
 RETURN r;
END $$;
CREATE FUNCTION public.public_entitled_webpage(p_listing_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.public_entitled_webpage(p_listing_id)$$;
REVOKE ALL ON FUNCTION private.public_entitled_webpage(uuid),public.public_entitled_webpage(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.public_entitled_webpage(uuid),public.public_entitled_webpage(uuid) TO anon,authenticated;
-- Attribute events at the moment of activity rather than reclassifying historic
-- paid activity when the listing's single network promotion changes package.
CREATE FUNCTION private.tag_ajm_trial_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_trial uuid;
BEGIN
 NEW.metadata:=NEW.metadata-'trial_id';
 SELECT t.id INTO v_trial FROM private.ajm_package_trials t JOIN public.advertisements a ON a.id=NEW.advertisement_id
 WHERE t.status='active' AND t.starts_at<=now() AND t.expires_at>now() AND
 (a.subscription_id=t.subscription_id OR(a.placement='webpage-network' AND a.listing_id=t.listing_id AND t.package_snapshot->>'type'='webpage')) ORDER BY t.created_at DESC LIMIT 1;
 IF v_trial IS NOT NULL THEN NEW.metadata:=NEW.metadata||jsonb_build_object('trial_id',v_trial); END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.tag_ajm_trial_event() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER tag_complimentary_trial_event BEFORE INSERT ON public.ad_events FOR EACH ROW EXECUTE FUNCTION private.tag_ajm_trial_event();
-- Keep a paid promotion tied to its paid subscription while a temporary tier
-- upgrade is running. The dedicated trial register reports tagged activity.
DO $$DECLARE def text;BEGIN
 SELECT pg_get_functiondef('private.sync_listing_webpage_promotion(uuid)'::regprocedure) INTO def;
 def:=replace(def,'private.ajm_tier_rank(p.webpage_tier) DESC,','CASE WHEN s.trial_id IS NULL THEN 0 ELSE 1 END, private.ajm_tier_rank(p.webpage_tier) DESC,');
 EXECUTE def;
 SELECT pg_get_functiondef('private.manage_ajm_trials(text,jsonb)'::regprocedure) INTO def;
 def:=replace(def,'a.subscription_id=tr.subscription_id AND e.event_type','e.metadata->>''trial_id''=tr.id::text AND e.event_type');
 EXECUTE def;
END $$;
-- Owners can still open saved premium content after a trial expires. Saving a
-- changed page must pass the current-tier guard and normal feature validation.
CREATE POLICY "Owners retain saved webpage drafts" ON public.listing_webpages FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.listings l JOIN public.profiles p ON p.id=l.owner_user_id WHERE l.id=listing_id AND l.owner_user_id=(SELECT auth.uid()) AND p.account_status='active'));
CREATE POLICY "Owners can return to current webpage tier" ON public.listing_webpages FOR UPDATE TO authenticated
 USING(EXISTS(SELECT 1 FROM public.listings l JOIN public.profiles p ON p.id=l.owner_user_id WHERE l.id=listing_id AND l.owner_user_id=(SELECT auth.uid()) AND p.account_status='active'))
 WITH CHECK(private.can_manage_listing_webpage(listing_id,tier,(SELECT auth.uid())));
