-- Quick image-based vacancy posts, kept separate from employer-owned applications.
ALTER TABLE public.jobzone_posts
 ADD COLUMN post_kind text NOT NULL DEFAULT 'vacancy' CHECK(post_kind IN ('vacancy','flyer')),
 ADD COLUMN flyer_path text NOT NULL DEFAULT '',
 ADD COLUMN flyer_mime text NOT NULL DEFAULT '',
 ADD COLUMN flyer_size bigint NOT NULL DEFAULT 0 CHECK(flyer_size BETWEEN 0 AND 5242880),
 ADD COLUMN flyer_request_id uuid,
 ADD COLUMN flyer_payload_hash text,
 ADD COLUMN flyer_deadline_known boolean NOT NULL DEFAULT true,
 ADD COLUMN application_url text NOT NULL DEFAULT '';
ALTER TABLE public.jobzone_posts DROP CONSTRAINT jobzone_posts_employment_type_check;
ALTER TABLE public.jobzone_posts ADD CONSTRAINT jobzone_posts_employment_type_check CHECK(employment_type IN ('Full-time','Part-time','Contract','Temporary','Internship','Freelance','Not specified'));
ALTER TABLE public.jobzone_posts DROP CONSTRAINT jobzone_posts_work_mode_check;
ALTER TABLE public.jobzone_posts ADD CONSTRAINT jobzone_posts_work_mode_check CHECK(work_mode IN ('On-site','Hybrid','Remote','Not specified'));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('jobzone-vacancy-flyers','jobzone-vacancy-flyers',false,5242880,ARRAY['image/jpeg','image/png','image/webp']);
CREATE FUNCTION private.jobzone_flyer_access(p_path text,p_upload boolean) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.jobzone_posts j WHERE j.post_kind='flyer' AND j.flyer_path=p_path AND
 CASE WHEN p_upload THEN j.status='draft' AND j.updated_at>now()-interval '30 minutes' AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.account_status='active' AND (p.id=j.employer_id OR p.role='admin'))
 ELSE (j.status='published' AND j.closes_at>now()) OR EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.account_status='active' AND (p.id=j.employer_id OR p.role='admin')) END)
$$;
REVOKE ALL ON FUNCTION private.jobzone_flyer_access(text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.jobzone_flyer_access(text,boolean) TO anon,authenticated;
CREATE POLICY "Reserved vacancy flyer uploads" ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='jobzone-vacancy-flyers' AND private.jobzone_flyer_access(name,true));
CREATE POLICY "Published or owned vacancy flyer reads" ON storage.objects FOR SELECT TO anon,authenticated
 USING(bucket_id='jobzone-vacancy-flyers' AND private.jobzone_flyer_access(name,false));
-- No public bucket, arbitrary writes, overwrites, or document/PDF uploads.
CREATE OR REPLACE FUNCTION private.jobzone_public(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE off int:=greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000));j public.jobzone_posts;q text:=left(trim(coalesce(p_payload->>'search','')),100);result jsonb;
BEGIN
 IF p_action='event' THEN
  IF p_payload->>'kind' NOT IN ('view','apply_open') OR length(coalesce(p_payload->>'session','')) NOT BETWEEN 16 AND 200 THEN RAISE EXCEPTION 'Invalid activity event.'; END IF;
  IF EXISTS(SELECT 1 FROM public.jobzone_posts WHERE id=(p_payload->>'id')::uuid AND status='published' AND closes_at>now()) THEN
   INSERT INTO private.jobzone_events(job_id,session_hash,kind) VALUES((p_payload->>'id')::uuid,md5(p_payload->>'session'),p_payload->>'kind') ON CONFLICT DO NOTHING;
  END IF;RETURN '{"ok":true}';
 ELSIF p_action NOT IN ('browse','detail') THEN RAISE EXCEPTION 'Unknown JobZone action.'; END IF;
 WITH matched AS (
  SELECT p.*,EXISTS(SELECT 1 FROM public.ad_orders o WHERE o.id=p.promotion_order_id AND o.user_id=p.employer_id AND o.product_type_snapshot='display_ad' AND o.status='approved' AND o.starts_at<=now() AND o.expires_at>now()) AS promoted
  FROM public.jobzone_posts p WHERE p.status='published' AND p.closes_at>now()
   AND (p_action<>'detail' OR p.id=(p_payload->>'id')::uuid)
   AND (q='' OR concat_ws(' ',p.title,p.company_name,p.location,p.description) ILIKE '%'||q||'%')
   AND (coalesce(p_payload->>'industry','')='' OR p.industry=p_payload->>'industry')
   AND (coalesce(p_payload->>'department','')='' OR p.department=p_payload->>'department')
   AND (coalesce(p_payload->>'employment_type','')='' OR p.employment_type=p_payload->>'employment_type')
 ),page AS (SELECT * FROM matched ORDER BY promoted DESC,created_at DESC,id DESC LIMIT 25 OFFSET off)
 SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'company_name',p.company_name,'title',p.title,'industry',p.industry,'department',p.department,'location',p.location,'employment_type',p.employment_type,'work_mode',p.work_mode,'description',p.description,'requirements',p.requirements,'salary_text',p.salary_text,'closes_at',p.closes_at,'created_at',p.created_at,'promoted',p.promoted,'application_email',p.application_email,'application_url',p.application_url,'post_kind',p.post_kind,'flyer_path',p.flyer_path,'flyer_deadline_known',p.flyer_deadline_known) ORDER BY p.promoted DESC,p.created_at DESC,p.id DESC) FROM page p),'[]')) INTO result;
 RETURN result;
END $$;


CREATE OR REPLACE FUNCTION private.manage_jobzone(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();is_admin boolean;j public.jobzone_posts;a private.jobzone_applications;result jsonb;v_name text;v_email text;off int:=greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000));v_id uuid;v_status text;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND account_status='active') THEN RAISE EXCEPTION 'Sign in with an active account to use this workspace.' USING ERRCODE='42501'; END IF;
 is_admin:=private.app_is_admin(uid);
 IF p_action='save_post' THEN
  IF nullif(trim(p_payload->>'application_email'),'') IS NOT NULL THEN
   IF length(trim(p_payload->>'application_email'))>254 OR trim(p_payload->>'application_email') !~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN RAISE EXCEPTION 'Enter a valid employer application email.'; END IF;
   IF p_payload->>'publish_contact_email' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm that this application email may be displayed publicly on the vacancy.'; END IF;
  END IF;
  IF nullif(p_payload->>'id','') IS NOT NULL THEN
   SELECT * INTO j FROM public.jobzone_posts WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
   IF FOUND AND j.post_kind='flyer' THEN RAISE EXCEPTION 'Use Edit flyer to update a shared vacancy flyer.'; END IF;
   IF NOT FOUND OR j.employer_id<>uid THEN RAISE EXCEPTION 'Only the posting employer can edit this vacancy.' USING ERRCODE='42501'; END IF;
  ELSE
   PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,903));
   IF (SELECT count(*) FROM public.jobzone_posts WHERE employer_id=uid AND created_at>now()-interval '1 day')>=10 THEN RAISE EXCEPTION 'You have reached today''s vacancy posting limit. Please try again tomorrow.'; END IF;
  END IF;
  IF length(trim(coalesce(p_payload->>'company_name',''))) NOT BETWEEN 2 AND 150 OR length(trim(coalesce(p_payload->>'title',''))) NOT BETWEEN 3 AND 150
   OR length(trim(coalesce(p_payload->>'description',''))) NOT BETWEEN 30 AND 10000 OR length(trim(coalesce(p_payload->>'requirements',''))) NOT BETWEEN 10 AND 6000
   OR length(trim(coalesce(p_payload->>'location',''))) NOT BETWEEN 2 AND 150 OR length(coalesce(p_payload->>'industry','')) NOT BETWEEN 2 AND 100 OR length(coalesce(p_payload->>'department','')) NOT BETWEEN 2 AND 100 OR length(coalesce(p_payload->>'salary_text',''))>150 THEN RAISE EXCEPTION 'Complete the vacancy title, employer, sector, department, location, description and requirements.'; END IF;
  IF (p_payload->>'closes_at')::timestamptz<=now() OR (p_payload->>'closes_at')::timestamptz>now()+interval '180 days' OR nullif(p_payload->>'closes_at','') IS NULL THEN RAISE EXCEPTION 'Choose a closing date within the next 180 days.'; END IF;
  v_status:=CASE WHEN coalesce((p_payload->>'submit')::boolean,false) THEN 'pending' ELSE 'draft' END;
  INSERT INTO public.jobzone_posts(id,employer_id,company_name,title,industry,department,location,employment_type,work_mode,description,requirements,salary_text,closes_at,status,application_email)
  VALUES(coalesce(j.id,gen_random_uuid()),uid,trim(p_payload->>'company_name'),trim(p_payload->>'title'),trim(p_payload->>'industry'),trim(p_payload->>'department'),trim(p_payload->>'location'),p_payload->>'employment_type',coalesce(p_payload->>'work_mode','On-site'),trim(p_payload->>'description'),trim(p_payload->>'requirements'),coalesce(p_payload->>'salary_text',''),(p_payload->>'closes_at')::timestamptz,v_status,lower(trim(coalesce(p_payload->>'application_email',''))))
  ON CONFLICT(id) DO UPDATE SET company_name=excluded.company_name,title=excluded.title,industry=excluded.industry,department=excluded.department,location=excluded.location,employment_type=excluded.employment_type,work_mode=excluded.work_mode,description=excluded.description,requirements=excluded.requirements,salary_text=excluded.salary_text,closes_at=excluded.closes_at,status=excluded.status,application_email=excluded.application_email,moderation_note='',updated_at=now() RETURNING * INTO j;
  IF v_status='pending' THEN PERFORM private.app_emit('system','JobZone vacancy awaiting review','An employer submitted a vacancy for publication.','/ajm-jobzone-admin','jobzone_posts',j.id); END IF;
  RETURN jsonb_build_object('id',j.id,'status',j.status);
 ELSIF p_action IN ('my_posts','monitor') THEN
  IF p_action='monitor' AND NOT is_admin THEN RAISE EXCEPTION 'Administrator access required.' USING ERRCODE='42501'; END IF;
  WITH matched AS (SELECT p.*,(SELECT count(*) FROM private.jobzone_applications WHERE job_id=p.id AND stage<>'withdrawn') AS application_count,
   (SELECT count(*) FROM private.jobzone_events WHERE job_id=p.id AND kind='view') AS views,
   (SELECT count(*) FROM private.jobzone_events WHERE job_id=p.id AND kind='apply_open') AS apply_opens
   FROM public.jobzone_posts p WHERE (p_action='monitor' OR p.employer_id=uid) AND (coalesce(p_payload->>'status','')='' OR p.status=p_payload->>'status')),
  page AS(SELECT * FROM matched ORDER BY created_at DESC,id DESC LIMIT 25 OFFSET off)
  SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY created_at DESC,id DESC) FROM page),'[]')) INTO result;
  RETURN result;
 ELSIF p_action='my_applications' THEN
  SELECT jsonb_build_object('rows',coalesce(jsonb_agg(jsonb_build_object('id',app.id,'job_id',post.id,'title',post.title,'company_name',post.company_name,'stage',app.stage,'created_at',app.created_at) ORDER BY app.created_at DESC),'[]')) INTO result
  FROM private.jobzone_applications app JOIN public.jobzone_posts post ON post.id=app.job_id WHERE app.applicant_id=uid;
  RETURN result;
 ELSIF p_action IN ('application_stage','withdraw') THEN
  SELECT * INTO a FROM private.jobzone_applications WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Application not found.'; END IF;
  SELECT * INTO j FROM public.jobzone_posts WHERE id=a.job_id;
  IF p_action='withdraw' THEN
   IF a.applicant_id<>uid THEN RAISE EXCEPTION 'You can only withdraw your own application.' USING ERRCODE='42501'; END IF;v_status:='withdrawn';
  ELSE
   IF j.employer_id<>uid THEN RAISE EXCEPTION 'Only the posting employer can manage applicants.' USING ERRCODE='42501'; END IF;
   IF a.stage='withdrawn' THEN RAISE EXCEPTION 'The applicant withdrew this application.'; END IF;
   v_status:=p_payload->>'stage';IF v_status NOT IN ('received','reviewing','contacted','shortlisted','hired','declined') THEN RAISE EXCEPTION 'Choose a valid application stage.'; END IF;
  END IF;
  UPDATE private.jobzone_applications SET stage=v_status,updated_at=now() WHERE id=a.id;RETURN '{"ok":true}';
 END IF;
 SELECT * INTO j FROM public.jobzone_posts WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Vacancy not found.'; END IF;
 IF p_action='apply' THEN
  IF j.post_kind='flyer' THEN RAISE EXCEPTION 'Use the advertiser contact details or instructions on the vacancy flyer to apply.'; END IF;
  IF j.employer_id=uid THEN RAISE EXCEPTION 'You cannot apply to your own vacancy.'; END IF;
  IF j.status<>'published' OR j.closes_at<=now() THEN RAISE EXCEPTION 'This vacancy is no longer accepting applications.'; END IF;
  SELECT * INTO a FROM private.jobzone_applications WHERE job_id=j.id AND applicant_id=uid;
  IF FOUND THEN RETURN jsonb_build_object('id',a.id,'duplicate',true,'stage',a.stage); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,904));
  IF (SELECT count(*) FROM private.jobzone_applications WHERE applicant_id=uid AND created_at>now()-interval '1 day')>=20 THEN RAISE EXCEPTION 'You have reached today''s application limit. Please try again tomorrow.'; END IF;
  SELECT coalesce(nullif(trim(p_payload->>'name'),''),p.full_name),u.email INTO v_name,v_email FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.id=uid AND u.email_confirmed_at IS NOT NULL;
  IF length(coalesce(v_name,'')) NOT BETWEEN 2 AND 150 OR nullif(v_email,'') IS NULL OR length(trim(coalesce(p_payload->>'statement',''))) NOT BETWEEN 20 AND 6000 OR length(coalesce(p_payload->>'phone',''))>50 OR length(coalesce(p_payload->>'cv_url',''))>2048 THEN RAISE EXCEPTION 'Confirm your account email and provide your name and application statement.'; END IF;
  IF nullif(p_payload->>'cv_url','') IS NOT NULL AND p_payload->>'cv_url' !~ '^https://[^[:space:]]+$' THEN RAISE EXCEPTION 'Use an https link for an optional CV or portfolio.'; END IF;
  IF p_payload->>'consent' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm that this application may be shared with the posting employer.'; END IF;
  INSERT INTO private.jobzone_applications(job_id,applicant_id,applicant_name,email,phone,statement,cv_url) VALUES(j.id,uid,v_name,v_email,coalesce(p_payload->>'phone',''),trim(p_payload->>'statement'),coalesce(p_payload->>'cv_url','')) RETURNING * INTO a;
  PERFORM private.app_emit('system','JobZone application activity','A vacancy received a new application. Applicant details are available only to its posting employer.','/ajm-jobzone-admin','jobzone_posts',j.id);
  RETURN jsonb_build_object('id',a.id,'duplicate',false,'stage',a.stage);
 ELSIF p_action='applications' THEN
  IF j.employer_id<>uid THEN RAISE EXCEPTION 'Applicant details are private to the posting employer. USSE monitoring shows counts only.' USING ERRCODE='42501'; END IF;
  SELECT jsonb_build_object('total',(SELECT count(*) FROM private.jobzone_applications WHERE job_id=j.id),'rows',coalesce((SELECT jsonb_agg(CASE WHEN app_row.stage='withdrawn' THEN jsonb_build_object('id',app_row.id,'job_id',app_row.job_id,'applicant_name','Withdrawn applicant','email','','phone','','statement','This applicant withdrew their application.','cv_url','','stage',app_row.stage,'created_at',app_row.created_at) ELSE to_jsonb(app_row) END ORDER BY app_row.created_at DESC,app_row.id DESC) FROM(SELECT * FROM private.jobzone_applications WHERE job_id=j.id ORDER BY created_at DESC,id DESC LIMIT 50 OFFSET off)app_row),'[]')) INTO result;RETURN result;
 ELSIF p_action='close' THEN
  IF j.employer_id<>uid AND NOT is_admin THEN RAISE EXCEPTION 'You cannot close this vacancy.' USING ERRCODE='42501'; END IF;
  UPDATE public.jobzone_posts SET status='closed',updated_at=now() WHERE id=j.id;
 ELSIF p_action='review' THEN
  IF NOT is_admin THEN RAISE EXCEPTION 'Administrator access required.' USING ERRCODE='42501'; END IF;
  v_status:=p_payload->>'status';IF v_status NOT IN ('published','rejected','closed') THEN RAISE EXCEPTION 'Choose a valid review decision.'; END IF;
  IF v_status='published' AND j.closes_at<=now() THEN RAISE EXCEPTION 'The closing date has passed. Ask the employer to update this vacancy.'; END IF;
  IF v_status='published' AND j.post_kind='flyer' AND NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='jobzone-vacancy-flyers' AND name=j.flyer_path AND metadata->>'mimetype'=j.flyer_mime AND (metadata->>'size')::bigint=j.flyer_size) THEN RAISE EXCEPTION 'The vacancy flyer upload is incomplete.'; END IF;
  UPDATE public.jobzone_posts SET status=v_status,moderation_note=left(coalesce(p_payload->>'note',''),1000),updated_at=now() WHERE id=j.id;
 ELSIF p_action='request_promotion' THEN
  IF j.employer_id<>uid THEN RAISE EXCEPTION 'Only the posting employer can request promotion.' USING ERRCODE='42501'; END IF;
  IF NOT j.promotion_requested THEN
   UPDATE public.jobzone_posts SET promotion_requested=true,updated_at=now() WHERE id=j.id;
   SELECT email INTO v_email FROM auth.users WHERE id=uid;
   INSERT INTO public.consultations(customer_name,email,source,notes,company,branch,service,capture_origin,source_page) VALUES(j.company_name,v_email,'website','Employer requested paid promotion for JobZone vacancy: '||j.title||' ('||j.id||'). Applications remain with the employer.',j.company_name,'AJM','JobZone employer promotion','manual','/ajm-jobzone-employer');
  END IF;
 ELSIF p_action='link_promotion' THEN
  IF NOT is_admin THEN RAISE EXCEPTION 'Administrator access required.' USING ERRCODE='42501'; END IF;
  v_id:=nullif(p_payload->>'order_id','')::uuid;
  IF v_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.ad_orders WHERE id=v_id AND user_id=j.employer_id AND product_type_snapshot='display_ad' AND status='approved' AND expires_at>now()) THEN RAISE EXCEPTION 'Choose this employer''s approved, current banner order. Unpaid orders cannot promote a vacancy.'; END IF;
  UPDATE public.jobzone_posts SET promotion_order_id=v_id,updated_at=now() WHERE id=j.id;
 ELSE RAISE EXCEPTION 'Unknown employer workspace action.'; END IF;
 INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(uid,'jobzone_post',j.id::text,'jobzone_'||p_action);
 RETURN '{"ok":true}';
END $$;


CREATE FUNCTION private.manage_jobzone_flyer(p_action text,p_payload jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();is_admin boolean;j public.jobzone_posts;v_id uuid;v_request uuid;v_hash text;v_mime text;v_ext text;v_size bigint;
 v_title text;v_company text;v_note text;v_email text;v_url text;v_closes timestamptz;v_path text;v_status text;v_days integer;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.id=uid AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'Sign in with an active, confirmed account to post a flyer.' USING ERRCODE='42501'; END IF;
 is_admin:=private.app_is_admin(uid);v_id:=(p_payload->>'id')::uuid;
 SELECT * INTO j FROM public.jobzone_posts WHERE id=v_id FOR UPDATE;
 IF FOUND AND (j.post_kind<>'flyer' OR (j.employer_id<>uid AND NOT is_admin)) THEN RAISE EXCEPTION 'You can only edit your own flyer posts.' USING ERRCODE='42501'; END IF;
 IF p_action='reserve' THEN
  v_request:=(p_payload->>'request_id')::uuid;v_hash:=md5((p_payload-'request_id')::text);
  IF v_id IS NULL OR v_request IS NULL THEN RAISE EXCEPTION 'Start a new flyer post.'; END IF;
  IF j.id IS NOT NULL AND j.flyer_request_id=v_request THEN
   IF j.flyer_payload_hash<>v_hash THEN RAISE EXCEPTION 'This upload reference is already used. Start a new save.'; END IF;
   RETURN jsonb_build_object('id',j.id,'path',j.flyer_path,'status',j.status);
  END IF;
  v_title:=trim(p_payload->>'title');v_company:=trim(p_payload->>'company_name');v_note:=trim(coalesce(p_payload->>'caption',''));v_email:=lower(trim(coalesce(p_payload->>'application_email','')));v_url:=trim(coalesce(p_payload->>'application_url',''));
  IF coalesce(length(v_title),0) NOT BETWEEN 3 AND 150 OR coalesce(length(v_company),0) NOT BETWEEN 2 AND 150 OR length(v_note)>6000 THEN RAISE EXCEPTION 'Add a vacancy title, employer name and an optional note up to 6000 characters.'; END IF;
  IF v_email<>'' AND (length(v_email)>254 OR v_email !~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' OR p_payload->>'publish_contact_email' IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'Enter a valid advertiser email and confirm that it can be displayed with this flyer.'; END IF;
  IF v_url<>'' AND (length(v_url)>2048 OR v_url !~ '^https://[^/@?#[:space:]]+([/?#][^[:space:]]*)?$') THEN RAISE EXCEPTION 'Use an https advertiser or application link without account credentials.'; END IF;
  v_mime:=coalesce(nullif(p_payload->>'mime',''),j.flyer_mime);v_size:=coalesce(nullif(p_payload->>'file_size','')::bigint,j.flyer_size);
  IF v_mime IS NULL OR v_mime NOT IN ('image/jpeg','image/png','image/webp') OR v_size IS NULL OR v_size NOT BETWEEN 1 AND 5242880 THEN RAISE EXCEPTION 'Choose a JPG, PNG or WebP image up to 5 MB.'; END IF;
  v_ext:=CASE v_mime WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'webp' END;
  v_path:=CASE WHEN coalesce((p_payload->>'new_image')::boolean,false) THEN v_id::text||'/'||v_request::text||'.'||v_ext ELSE j.flyer_path END;
  IF coalesce(v_path,'')='' THEN RAISE EXCEPTION 'Choose or paste a vacancy flyer image.'; END IF;
  v_days:=coalesce(nullif(p_payload->>'display_days','')::integer,30);
  IF v_days NOT IN (7,14,30,60) THEN RAISE EXCEPTION 'Choose a listing duration of 7, 14, 30 or 60 days.'; END IF;
  v_closes:=coalesce(nullif(p_payload->>'closes_at','')::timestamptz,now()+v_days*interval '1 day');
  IF v_closes<=now() OR v_closes>now()+interval '180 days' THEN RAISE EXCEPTION 'Choose a future closing date within 180 days.'; END IF;
  IF j.id IS NULL THEN
   PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,903));
   IF (SELECT count(*) FROM public.jobzone_posts WHERE employer_id=uid AND created_at>now()-interval '1 day')>=20 THEN RAISE EXCEPTION 'Today''s vacancy posting limit has been reached. Please try again tomorrow.'; END IF;
  END IF;
  INSERT INTO public.jobzone_posts(id,employer_id,company_name,title,industry,department,location,employment_type,work_mode,description,requirements,closes_at,status,application_email,post_kind,flyer_path,flyer_mime,flyer_size,flyer_request_id,flyer_payload_hash,flyer_deadline_known,application_url)
  VALUES(v_id,coalesce(j.employer_id,uid),v_company,v_title,'OTHER INDUSTRY','OTHER',coalesce(nullif(trim(p_payload->>'location'),''),'See flyer'),'Not specified','Not specified',coalesce(nullif(v_note,''),'Read the attached vacancy flyer for the employer''s role details and application instructions.'),'Apply using the advertiser''s contact details or the instructions printed on the vacancy flyer.',v_closes,'draft',v_email,'flyer',v_path,v_mime,v_size,v_request,v_hash,nullif(p_payload->>'closes_at','') IS NOT NULL,v_url)
  ON CONFLICT(id) DO UPDATE SET company_name=excluded.company_name,title=excluded.title,location=excluded.location,description=excluded.description,closes_at=excluded.closes_at,status='draft',application_email=excluded.application_email,flyer_path=excluded.flyer_path,flyer_mime=excluded.flyer_mime,flyer_size=excluded.flyer_size,flyer_request_id=excluded.flyer_request_id,flyer_payload_hash=excluded.flyer_payload_hash,flyer_deadline_known=excluded.flyer_deadline_known,application_url=excluded.application_url,moderation_note='',updated_at=now() RETURNING * INTO j;
  RETURN jsonb_build_object('id',j.id,'path',j.flyer_path,'status',j.status);
 ELSIF p_action='publish' THEN
  IF j.id IS NULL THEN RAISE EXCEPTION 'Flyer post not found.'; END IF;
  IF j.status IN ('published','pending') THEN RETURN jsonb_build_object('id',j.id,'status',j.status,'duplicate',true); END IF;
  IF j.status<>'draft' THEN RAISE EXCEPTION 'Edit this flyer before posting it again.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='jobzone-vacancy-flyers' AND name=j.flyer_path AND metadata->>'mimetype'=j.flyer_mime AND (metadata->>'size')::bigint=j.flyer_size) THEN RAISE EXCEPTION 'The flyer upload is incomplete. Please choose the image and save again.'; END IF;
  IF j.closes_at<=now() THEN RAISE EXCEPTION 'The vacancy or listing closing date has passed.'; END IF;
  v_status:=CASE WHEN NOT coalesce((p_payload->>'submit')::boolean,false) THEN 'draft' WHEN is_admin THEN 'published' ELSE 'pending' END;
  UPDATE public.jobzone_posts SET status=v_status,updated_at=now() WHERE id=j.id;
  IF v_status='pending' THEN PERFORM private.app_emit('system','Vacancy flyer awaiting review','A shared vacancy flyer is ready for review.','/ajm-jobzone-admin','jobzone_posts',j.id); END IF;
  INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(uid,'jobzone_post',j.id::text,'jobzone_flyer_'||v_status);
  RETURN jsonb_build_object('id',j.id,'status',v_status);
 ELSE RAISE EXCEPTION 'Unknown vacancy flyer action.'; END IF;
END $$;
CREATE FUNCTION public.manage_jobzone_flyer(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
 LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_jobzone_flyer(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_jobzone_flyer(text,jsonb),public.manage_jobzone_flyer(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_jobzone_flyer(text,jsonb),public.manage_jobzone_flyer(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
