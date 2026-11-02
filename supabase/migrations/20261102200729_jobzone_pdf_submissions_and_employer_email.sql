-- Employer-approved public contact and private, explicit submissions to USSE.
ALTER TABLE public.jobzone_posts ADD COLUMN application_email text NOT NULL DEFAULT '';
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
 SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'company_name',p.company_name,'title',p.title,'industry',p.industry,'department',p.department,'location',p.location,'employment_type',p.employment_type,'work_mode',p.work_mode,'description',p.description,'requirements',p.requirements,'salary_text',p.salary_text,'closes_at',p.closes_at,'created_at',p.created_at,'promoted',p.promoted,'application_email',p.application_email) ORDER BY p.promoted DESC,p.created_at DESC,p.id DESC) FROM page p),'[]')) INTO result;
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

CREATE TABLE private.jobzone_usse_submissions (
 id uuid PRIMARY KEY, applicant_id uuid NOT NULL REFERENCES public.profiles(id),
 applicant_name text NOT NULL, email text NOT NULL, phone text NOT NULL DEFAULT '', statement text NOT NULL,
 object_key text NOT NULL UNIQUE, file_name text NOT NULL, file_size bigint NOT NULL CHECK(file_size BETWEEN 1 AND 5242880),
 status text NOT NULL DEFAULT 'uploading' CHECK(status IN ('uploading','received','reviewing','closed','withdrawn')),
 consent_at timestamptz NOT NULL DEFAULT now(), created_at timestamptz NOT NULL DEFAULT now(), submitted_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobzone_usse_owner_idx ON private.jobzone_usse_submissions(applicant_id,created_at DESC);
CREATE INDEX jobzone_usse_status_idx ON private.jobzone_usse_submissions(status,created_at DESC);
ALTER TABLE private.jobzone_usse_submissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.jobzone_usse_submissions FROM PUBLIC,anon,authenticated;

INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('jobzone-usse-applications','jobzone-usse-applications',false,5242880,ARRAY['application/pdf']);
CREATE FUNCTION private.jobzone_pdf_access(p_name text,p_upload boolean) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(
  SELECT 1 FROM private.jobzone_usse_submissions s JOIN public.profiles p ON p.id=auth.uid()
  WHERE p.account_status='active' AND s.object_key=p_name AND
   CASE WHEN p_upload THEN s.applicant_id=p.id AND s.status='uploading' AND s.created_at>now()-interval '30 minutes'
   ELSE s.applicant_id=p.id OR (p.role='admin' AND s.status IN ('received','reviewing','closed')) END
 )
$$;
REVOKE ALL ON FUNCTION private.jobzone_pdf_access(text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.jobzone_pdf_access(text,boolean) TO authenticated;
CREATE POLICY "Applicant reserves own USSE PDF upload" ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='jobzone-usse-applications' AND private.jobzone_pdf_access(name,true));
CREATE POLICY "Private USSE application PDF access" ON storage.objects FOR SELECT TO authenticated
 USING(bucket_id='jobzone-usse-applications' AND private.jobzone_pdf_access(name,false));
-- No client UPDATE or DELETE policy: PDFs cannot be silently replaced after submission.

CREATE FUNCTION private.manage_jobzone_documents(p_action text,p_payload jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();is_admin boolean;s private.jobzone_usse_submissions;v_email text;v_name text;
 v_file text;v_size bigint;v_id uuid;off int:=greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000));result jsonb;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND account_status='active') THEN RAISE EXCEPTION 'Sign in with an active account.' USING ERRCODE='42501'; END IF;
 is_admin:=private.app_is_admin(uid);
 IF p_action='begin' THEN
  SELECT u.email,coalesce(nullif(trim(p_payload->>'name'),''),p.full_name) INTO v_email,v_name FROM auth.users u JOIN public.profiles p ON p.id=u.id WHERE u.id=uid AND u.email_confirmed_at IS NOT NULL;
  IF nullif(v_email,'') IS NULL THEN RAISE EXCEPTION 'Confirm your account email before submitting a PDF.'; END IF;
  IF length(coalesce(v_name,'')) NOT BETWEEN 2 AND 150 OR length(trim(coalesce(p_payload->>'statement',''))) NOT BETWEEN 20 AND 6000 OR length(coalesce(p_payload->>'phone',''))>50 THEN RAISE EXCEPTION 'Provide your name, a message of 20–6000 characters and valid contact details.'; END IF;
  IF p_payload->>'consent' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Confirm that this PDF and your contact details may be shared directly with USSE.'; END IF;
  v_file:=trim(p_payload->>'file_name');v_size:=(p_payload->>'file_size')::bigint;v_id:=(p_payload->>'id')::uuid;
  IF v_id IS NULL OR v_file IS NULL OR length(v_file) NOT BETWEEN 5 AND 200 OR v_file !~* '\.pdf$' OR v_file ~ '[[:cntrl:]/\\]' OR v_size IS NULL OR v_size NOT BETWEEN 1 AND 5242880 THEN RAISE EXCEPTION 'Choose a PDF file of up to 5 MB with a valid filename.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,905));
  SELECT * INTO s FROM private.jobzone_usse_submissions WHERE id=v_id;
  IF FOUND THEN
   IF s.applicant_id<>uid THEN RAISE EXCEPTION 'This upload reference cannot be used.' USING ERRCODE='42501'; END IF;
   IF s.status NOT IN ('uploading','received','reviewing','closed') THEN RAISE EXCEPTION 'Start a new submission.'; END IF;
   IF s.status='uploading' AND s.created_at<=now()-interval '30 minutes' THEN RAISE EXCEPTION 'This upload expired. Reopen the form and choose the PDF again.'; END IF;
   IF s.file_name<>v_file OR s.file_size<>v_size OR s.statement<>trim(p_payload->>'statement') OR s.applicant_name<>v_name OR s.phone<>coalesce(p_payload->>'phone','') THEN RAISE EXCEPTION 'The upload reference is already used. Start a new submission.'; END IF;
   RETURN jsonb_build_object('id',s.id,'object_key',s.object_key,'status',s.status);
  END IF;
  IF (SELECT count(*) FROM private.jobzone_usse_submissions WHERE applicant_id=uid AND created_at>now()-interval '1 day')>=5 THEN RAISE EXCEPTION 'You have reached today''s PDF submission limit. Please try again tomorrow.'; END IF;
  INSERT INTO private.jobzone_usse_submissions(id,applicant_id,applicant_name,email,phone,statement,object_key,file_name,file_size)
   VALUES(v_id,uid,v_name,v_email,coalesce(p_payload->>'phone',''),trim(p_payload->>'statement'),uid::text||'/'||v_id::text||'.pdf',v_file,v_size) RETURNING * INTO s;
  RETURN jsonb_build_object('id',s.id,'object_key',s.object_key,'status',s.status);
 ELSIF p_action IN ('list_own','list_usse') THEN
  IF p_action='list_usse' AND NOT is_admin THEN RAISE EXCEPTION 'USSE administrator access required.' USING ERRCODE='42501'; END IF;
  WITH matched AS(SELECT * FROM private.jobzone_usse_submissions WHERE
   CASE WHEN p_action='list_own' THEN applicant_id=uid AND status<>'uploading' ELSE status IN ('received','reviewing','closed') END),
  page AS(SELECT * FROM matched ORDER BY created_at DESC,id DESC LIMIT 25 OFFSET off)
  SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY created_at DESC,id DESC) FROM page),'[]')) INTO result;
  RETURN result;
 END IF;
 SELECT * INTO s FROM private.jobzone_usse_submissions WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Submission not found.'; END IF;
 IF p_action='submit' THEN
  IF s.applicant_id<>uid THEN RAISE EXCEPTION 'You can only submit your own PDF.' USING ERRCODE='42501'; END IF;
  IF s.status IN ('received','reviewing','closed') THEN RETURN jsonb_build_object('id',s.id,'status',s.status,'duplicate',true); END IF;
  IF s.status<>'uploading' OR s.created_at<=now()-interval '30 minutes' THEN RAISE EXCEPTION 'This upload expired or was withdrawn. Start a new submission.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='jobzone-usse-applications' AND name=s.object_key AND metadata->>'mimetype'='application/pdf' AND (metadata->>'size')::bigint=s.file_size) THEN RAISE EXCEPTION 'The PDF upload is incomplete. Upload the selected file and try again.'; END IF;
  UPDATE private.jobzone_usse_submissions SET status='received',submitted_at=now(),updated_at=now() WHERE id=s.id;
  PERFORM private.app_emit('system','New application sent to USSE','A PDF application was submitted directly to USSE. Open the private USSE applications inbox to review it.','/ajm-jobzone-admin','jobzone_usse_submissions',s.id);
 ELSIF p_action='withdraw' THEN
  IF s.applicant_id<>uid THEN RAISE EXCEPTION 'You can only withdraw your own submission.' USING ERRCODE='42501'; END IF;
  UPDATE private.jobzone_usse_submissions SET status='withdrawn',updated_at=now() WHERE id=s.id;
 ELSIF p_action='review' THEN
  IF NOT is_admin THEN RAISE EXCEPTION 'USSE administrator access required.' USING ERRCODE='42501'; END IF;
  IF s.status NOT IN ('received','reviewing','closed') OR coalesce(p_payload->>'status','') NOT IN ('received','reviewing','closed') THEN RAISE EXCEPTION 'Choose a valid review status for a submitted application.'; END IF;
  UPDATE private.jobzone_usse_submissions SET status=p_payload->>'status',updated_at=now() WHERE id=s.id;
 ELSE RAISE EXCEPTION 'Unknown PDF application action.'; END IF;
 INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(uid,'jobzone_usse_submission',s.id::text,'jobzone_pdf_'||p_action);
 RETURN jsonb_build_object('id',s.id,'status',(SELECT status FROM private.jobzone_usse_submissions WHERE id=s.id));
END $$;
CREATE FUNCTION public.manage_jobzone_documents(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
 LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.manage_jobzone_documents(p_action,p_payload) $$;
REVOKE ALL ON FUNCTION private.manage_jobzone_documents(text,jsonb),public.manage_jobzone_documents(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_jobzone_documents(text,jsonb),public.manage_jobzone_documents(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
