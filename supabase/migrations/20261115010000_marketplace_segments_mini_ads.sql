-- Expand the Marketplace classification and support moderated MP4 mini-ads.
CREATE TABLE private.marketplace_segments (
    category text NOT NULL CHECK (category IN ('Farm Products', 'Motor Vehicles', 'Hardware', 'Suppliers', 'Fashion & Retail', 'Events & Entertainment', 'Food & Catering', 'Business Services', 'Beauty & Personal Care', 'Transport & Logistics', 'Financial Services', 'Education & Coaching', 'General')),
    name text NOT NULL,
    PRIMARY KEY (category, name)
);
ALTER TABLE private.marketplace_segments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.marketplace_segments FROM PUBLIC, anon, authenticated;
INSERT INTO private.marketplace_segments (category, name) VALUES
 ('Fashion & Retail', 'Fashion Industry'),
 ('Fashion & Retail', 'Retail Clothing'),
 ('Events & Entertainment', 'Attractions'),
 ('Events & Entertainment', 'Musical Studio Services'),
 ('Food & Catering', 'Catering Services'),
 ('Food & Catering', 'Cooking Services'),
 ('Food & Catering', 'Bakery Supplier'),
 ('Food & Catering', 'Ice Production Services'),
 ('Business Services', 'Cleaning Services'),
 ('Beauty & Personal Care', 'Hair Grooming Services'),
 ('Beauty & Personal Care', 'Cosmetic Services'),
 ('Beauty & Personal Care', 'Nail Technicians'),
 ('Beauty & Personal Care', 'Hair Stylists'),
 ('Transport & Logistics', 'Delivery Services'),
 ('Transport & Logistics', 'Haulage Services'),
 ('Transport & Logistics', 'Import & Export Services'),
 ('Financial Services', 'Micro Loan Services'),
 ('Education & Coaching', 'Educational Services'),
 ('Education & Coaching', 'Coaching Services');

ALTER TABLE public.marketplace_flyers
 ADD COLUMN segment text NOT NULL DEFAULT '',
 ADD COLUMN video_duration_ms integer,
 DROP CONSTRAINT marketplace_flyers_category_check,
 ADD CONSTRAINT marketplace_flyers_category_check CHECK (category IN ('Farm Products', 'Motor Vehicles', 'Hardware', 'Suppliers', 'Fashion & Retail', 'Events & Entertainment', 'Food & Catering', 'Business Services', 'Beauty & Personal Care', 'Transport & Logistics', 'Financial Services', 'Education & Coaching', 'General')),
 DROP CONSTRAINT marketplace_flyers_mime_check,
 ADD CONSTRAINT marketplace_flyers_mime_check CHECK (mime IN ('image/jpeg','image/png','image/webp','video/mp4')),
 DROP CONSTRAINT marketplace_flyers_file_size_check,
 ADD CONSTRAINT marketplace_flyers_file_size_check CHECK (file_size BETWEEN 1 AND CASE WHEN mime='video/mp4' THEN 20971520 ELSE 5242880 END),
 ADD CONSTRAINT marketplace_video_duration_check CHECK (
    video_duration_ms IS NULL OR (mime='video/mp4' AND video_duration_ms BETWEEN 1 AND 15000)
 );

UPDATE storage.buckets SET file_size_limit=20971520,
 allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp','video/mp4']
 WHERE id='marketplace-flyers';

-- The validation function verifies the immutable uploaded bytes. Only the
-- service role can record a successful review of the media.
CREATE FUNCTION public.mark_marketplace_video_verified(
    p_flyer_id uuid, p_image_path text, p_duration_ms integer
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
    UPDATE public.marketplace_flyers
    SET video_duration_ms=p_duration_ms
    WHERE id=p_flyer_id AND image_path=p_image_path AND status='draft' AND mime='video/mp4'
      AND p_duration_ms BETWEEN 1 AND 15000;
    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.mark_marketplace_video_verified(uuid,text,integer) FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE (video_duration_ms) ON public.marketplace_flyers TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_marketplace_video_verified(uuid,text,integer) TO service_role;

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
  IF coalesce(p_payload->>'category','') NOT IN ('Farm Products', 'Motor Vehicles', 'Hardware', 'Suppliers', 'Fashion & Retail', 'Events & Entertainment', 'Food & Catering', 'Business Services', 'Beauty & Personal Care', 'Transport & Logistics', 'Financial Services', 'Education & Coaching', 'General') THEN
   RAISE EXCEPTION 'Choose a Marketplace category.';
  END IF;
  v_segment:=trim(coalesce(p_payload->>'segment',''));
  IF v_segment<>'' AND NOT EXISTS (
   SELECT 1 FROM private.marketplace_segments s WHERE s.category=p_payload->>'category' AND s.name=v_segment
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

CREATE OR REPLACE FUNCTION private.marketplace_public(p_payload jsonb) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH matched AS(SELECT f.id,f.business_name,f.title,f.tagline,f.category,f.segment,f.mime,f.video_duration_ms,f.contact_url,f.image_path,f.ajm_sponsored,f.published_at,f.expires_at
 FROM public.marketplace_flyers f WHERE f.status='published' AND f.expires_at>now()
 AND(coalesce(p_payload->>'id','')='' OR f.id=(p_payload->>'id')::uuid)
 AND(coalesce(p_payload->>'category','')='' OR f.category=p_payload->>'category')
 AND(coalesce(p_payload->>'segment','')='' OR f.segment=p_payload->>'segment')
 AND(coalesce(p_payload->>'format','')<>'mini-ad' OR f.mime='video/mp4')
 AND (f.mime<>'video/mp4' OR f.video_duration_ms IS NOT NULL)
 AND(coalesce(p_payload->>'search','')='' OR concat_ws(' ',f.business_name,f.title,f.tagline,f.category,f.segment) ILIKE '%'||left(p_payload->>'search',100)||'%')),
 page AS(SELECT * FROM matched ORDER BY published_at DESC,id LIMIT 24 OFFSET greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000)))
 SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY published_at DESC,id) FROM page),'[]'))
$$;
