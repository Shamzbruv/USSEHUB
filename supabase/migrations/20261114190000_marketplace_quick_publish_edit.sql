-- General is the default for quick poster uploads when no category is selected.
ALTER TABLE public.marketplace_flyers
 DROP CONSTRAINT marketplace_flyers_category_check,
 ADD CONSTRAINT marketplace_flyers_category_check
 CHECK(category IN ('General','Farm Products','Motor Vehicles','Hardware','Suppliers','Events & Entertainment','Business Services'));

-- Keep the existing authenticated RPC and its private authorization boundary.
-- Copy changes affect the existing post and leave its artwork and publication dates intact.
CREATE OR REPLACE FUNCTION private.manage_marketplace(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 IF p_action='edit' THEN
  IF NOT adm THEN
   RAISE EXCEPTION 'Only active administrators can edit published flyers.' USING ERRCODE='42501';
  END IF;
  IF f.id IS NULL OR f.status<>'published' THEN
   RAISE EXCEPTION 'Choose a published flyer.';
  END IF;
 END IF;

 IF p_action IN ('reserve','edit') THEN
  v_url:=trim(coalesce(p_payload->>'contact_url',''));
  IF length(trim(coalesce(p_payload->>'business_name',''))) NOT BETWEEN 2 AND 150 OR length(trim(coalesce(p_payload->>'title',''))) NOT BETWEEN 3 AND 150 OR length(trim(coalesce(p_payload->>'tagline',''))) NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Complete the business name, title and brief market tagline.'; END IF;
  IF coalesce(p_payload->>'category','') NOT IN('General','Farm Products','Motor Vehicles','Hardware','Suppliers','Events & Entertainment','Business Services') THEN RAISE EXCEPTION 'Choose a Marketplace category.'; END IF;
  IF length(v_url)>2000 OR(v_url<>'' AND (v_url !~ '^https://[^/?#[:space:]@]+' OR v_url ~ '^https://[^/]*@' OR v_url ~ '[[:cntrl:][:space:]]')) THEN RAISE EXCEPTION 'Use a secure https contact or business link without credentials.'; END IF;
 END IF;

 IF p_action='edit' THEN
  -- A repeated request with the same values succeeds after a lost response.
  IF ROW(f.business_name,f.title,f.tagline,f.category,f.contact_url) IS NOT DISTINCT FROM
     ROW(trim(p_payload->>'business_name'),trim(p_payload->>'title'),trim(p_payload->>'tagline'),p_payload->>'category',v_url) THEN
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
   updated_at=clock_timestamp()
  WHERE id=f.id RETURNING * INTO f;
  RETURN jsonb_build_object('id',f.id,'status',f.status,'updated_at',f.updated_at);
 END IF;

 IF p_action='reserve' THEN
  v_mime:=p_payload->>'mime';
  v_size:=(p_payload->>'file_size')::bigint;
  v_days:=coalesce((p_payload->>'display_days')::int,30);
  IF coalesce(v_mime,'') NOT IN('image/jpeg','image/png','image/webp') OR v_size IS NULL OR v_size NOT BETWEEN 1 AND 5242880 THEN RAISE EXCEPTION 'Choose a JPG, PNG or WebP image up to 5 MB.'; END IF;
  IF v_days NOT IN(15,30) THEN RAISE EXCEPTION 'Choose a 15 or 30 day display period.'; END IF;
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
