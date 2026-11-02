-- Client marketplace and employer portal feedback, November 2026.
ALTER TABLE public.consultations ADD COLUMN archived_at timestamptz, ADD COLUMN archived_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL, ADD COLUMN archive_reason text;
CREATE INDEX consultations_archive_idx ON public.consultations(archived_at,created_at DESC);
CREATE INDEX consultations_archived_by_idx ON public.consultations(archived_by) WHERE archived_by IS NOT NULL;
CREATE OR REPLACE FUNCTION private.manage_leads(p_action text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE l public.consultations;v_settings public.lead_notification_settings;v_recipients text[];v text;result jsonb;off integer;lim integer;search text;stage text;src text;bid text;due boolean;
BEGIN
 PERFORM private.require_admin(auth.uid());
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='admin' AND account_status='active') THEN RAISE EXCEPTION 'Active administrator access required.' USING ERRCODE='42501'; END IF;
 IF p_action='settings' THEN
  SELECT * INTO v_settings FROM public.lead_notification_settings WHERE id;
  RETURN to_jsonb(v_settings) || jsonb_build_object('admins',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',coalesce(nullif(full_name,''),email))),'[]') FROM public.profiles WHERE role='admin' AND account_status='active'));
 ELSIF p_action='save_settings' THEN
  SELECT array_agg(DISTINCT lower(trim(x))) INTO v_recipients FROM jsonb_array_elements_text(coalesce(p_payload->'recipients','[]')) x WHERE trim(x)<>'';
  IF cardinality(v_recipients) IS NULL OR cardinality(v_recipients)>10 THEN RAISE EXCEPTION 'Choose between 1 and 10 alert recipients.'; END IF;
  FOREACH v IN ARRAY v_recipients LOOP IF length(v)>254 OR v !~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN RAISE EXCEPTION 'One or more recipient email addresses are invalid.'; END IF; END LOOP;
  UPDATE public.lead_notification_settings SET recipients=v_recipients,enabled=coalesce((p_payload->>'enabled')::boolean,true),configured=true,updated_at=now(),updated_by=auth.uid() WHERE id RETURNING * INTO v_settings;
  INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(auth.uid(),'lead_settings','global','lead_alert_recipients_updated');
  RETURN to_jsonb(v_settings);
 ELSIF p_action IN ('list','export') THEN
  off:=greatest(0,coalesce((p_payload->>'offset')::integer,0));lim:=least(100,greatest(1,coalesce((p_payload->>'limit')::integer,25)));
  search:=left(coalesce(p_payload->>'search',''),100);stage:=coalesce(p_payload->>'stage','');src:=coalesce(p_payload->>'source','');bid:=coalesce(p_payload->>'branch','');due:=coalesce((p_payload->>'overdue')::boolean,false);
  WITH matched AS (
   SELECT c.* FROM public.consultations c
   WHERE (search='' OR concat_ws(' ',c.customer_name,c.company,c.email,c.phone,c.notes,c.lead_reference) ILIKE '%'||search||'%')
     AND (CASE WHEN coalesce((p_payload->>'archived')::boolean,false) THEN c.archived_at IS NOT NULL ELSE c.archived_at IS NULL END)
     AND (stage='' OR c.lead_stage=stage)
     AND (src='' OR c.source=src)
     AND (bid='' OR c.branch=bid)
     AND (NOT due OR (c.follow_up_at<now() AND c.lead_stage IN ('new','contacted','qualified')))
     AND (p_payload->>'as_of' IS NULL OR c.created_at<=(p_payload->>'as_of')::timestamptz)
  ), page AS (SELECT * FROM matched ORDER BY created_at DESC,id DESC LIMIT lim OFFSET off)
  SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page)-'request_fingerprint'-'request_id' ORDER BY created_at DESC,id DESC) FROM page),'[]'),'metrics',(SELECT jsonb_build_object('new',count(*) FILTER(WHERE lead_stage='new'),'open',count(*) FILTER(WHERE lead_stage IN ('new','contacted','qualified')),'overdue',count(*) FILTER(WHERE follow_up_at<now() AND lead_stage IN ('new','contacted','qualified')),'failed_alerts',(SELECT count(*) FROM private.lead_alert_deliveries WHERE status='failed')) FROM public.consultations WHERE archived_at IS NULL)) INTO result;
  IF p_action='export' AND off=0 THEN INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(auth.uid(),'leads','filtered','leads_exported'); END IF;
  RETURN result;
 ELSIF p_action='create' THEN
  IF length(trim(coalesce(p_payload->>'customer_name',''))) NOT BETWEEN 2 AND 100 OR length(trim(coalesce(p_payload->>'notes',''))) NOT BETWEEN 5 AND 4000 OR (nullif(p_payload->>'phone','') IS NULL AND nullif(p_payload->>'email','') IS NULL) THEN RAISE EXCEPTION 'Name, a contact method and enquiry are required.'; END IF;
  IF length(coalesce(p_payload->>'email',''))>254 OR length(coalesce(p_payload->>'phone',''))>50 THEN RAISE EXCEPTION 'Contact details are too long.'; END IF;
  IF nullif(p_payload->>'email','') IS NOT NULL AND p_payload->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN RAISE EXCEPTION 'Enter a valid email address.'; END IF;
  INSERT INTO public.consultations(customer_name,phone,email,source,notes,company,branch,service,capture_origin,source_page)
  VALUES(trim(p_payload->>'customer_name'),nullif(p_payload->>'phone',''),nullif(lower(p_payload->>'email'),''),coalesce(p_payload->>'source','other'),trim(p_payload->>'notes'),left(coalesce(p_payload->>'company',''),150),left(coalesce(p_payload->>'branch','USSE'),80),left(coalesce(p_payload->>'service',''),150),'manual','Recorded by administrator') RETURNING * INTO l;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'manual','Recorded from an external conversation');
  RETURN jsonb_build_object('lead_id',l.id,'reference',l.lead_reference);
 END IF;
 SELECT * INTO l FROM public.consultations WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found.'; END IF;
 IF p_action='detail' THEN
  RETURN jsonb_build_object('lead',to_jsonb(l)-'request_fingerprint'-'request_id','activity',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC),'[]') FROM private.lead_activity a WHERE lead_id=l.id),'alerts',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'recipient',recipient_email,'status',status,'attempts',attempts,'last_error',last_error,'accepted_at',accepted_at,'next_attempt',available_at)),'[]') FROM private.lead_alert_deliveries WHERE lead_id=l.id));
 ELSIF p_action IN ('archive','restore') THEN
  IF p_action='archive' THEN
   IF l.archived_at IS NOT NULL THEN RETURN '{"ok":true}'; END IF;
   UPDATE public.consultations SET archived_at=now(),archived_by=auth.uid(),archive_reason=left(coalesce(nullif(trim(p_payload->>'reason'),''),'Removed from active inbox'),300) WHERE id=l.id;
   UPDATE private.lead_alert_deliveries SET status='cancelled',locked_at=NULL,claim_token=NULL,last_error='Cancelled because this enquiry was removed from the active inbox.' WHERE lead_id=l.id AND status IN ('pending','failed','processing');
   UPDATE public.admin_app_notifications SET dismissed_at=now() WHERE entity_table='consultations' AND entity_id=l.id AND dismissed_at IS NULL;
   UPDATE private.admin_push_deliveries SET status='cancelled',claim_token=NULL WHERE notification_id IN(SELECT id FROM public.admin_app_notifications WHERE entity_table='consultations' AND entity_id=l.id) AND status IN ('pending','failed','processing');
  ELSE
   UPDATE public.consultations SET archived_at=NULL,archived_by=NULL,archive_reason=NULL WHERE id=l.id;
  END IF;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),p_action,CASE WHEN p_action='archive' THEN 'Removed from active inbox: '||left(coalesce(p_payload->>'reason',''),300) ELSE 'Restored to active inbox. Previously cancelled alerts were not resent.' END);
  INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(auth.uid(),'lead',l.id::text,'lead_'||p_action);
 ELSIF p_action='update' THEN
  IF l.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Restore this lead before updating its follow-up.'; END IF;
  IF nullif(p_payload->>'assigned_to','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=(p_payload->>'assigned_to')::uuid AND role='admin' AND account_status='active') THEN RAISE EXCEPTION 'Assign an active administrator.'; END IF;
  UPDATE public.consultations SET lead_stage=coalesce(p_payload->>'stage',lead_stage),priority=coalesce(p_payload->>'priority',priority),assigned_to=nullif(p_payload->>'assigned_to','')::uuid,follow_up_at=nullif(p_payload->>'follow_up_at','')::timestamptz,
   first_contacted_at=CASE WHEN coalesce(p_payload->>'stage',lead_stage)<>'new' THEN coalesce(first_contacted_at,now()) ELSE first_contacted_at END,
   status=CASE coalesce(p_payload->>'stage',lead_stage) WHEN 'won' THEN 'completed' WHEN 'lost' THEN 'cancelled' WHEN 'spam' THEN 'cancelled' WHEN 'new' THEN 'pending' ELSE 'contacted' END WHERE id=l.id;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'updated','Stage: '||coalesce(p_payload->>'stage',l.lead_stage)||'; priority: '||coalesce(p_payload->>'priority',l.priority));
 ELSIF p_action='note' THEN
  v:=trim(coalesce(p_payload->>'note',''));IF length(v) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'Enter a note of up to 4000 characters.'; END IF;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'note',v);
 ELSIF p_action='contact_action' THEN
  IF p_payload->>'channel' NOT IN ('phone','email','whatsapp') THEN RAISE EXCEPTION 'Invalid contact action.'; END IF;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'contact_opened','Opened '||(p_payload->>'channel')||'. Contact is not confirmed until marked by the administrator.');
 ELSIF p_action='retry_alerts' THEN
  IF l.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Restore this lead before queuing alerts.'; END IF;
  UPDATE private.lead_alert_deliveries SET status='pending',attempts=0,available_at=now(),locked_at=NULL,claim_token=NULL,last_error=NULL WHERE lead_id=l.id AND status='failed';
  INSERT INTO private.lead_alert_deliveries(lead_id,recipient_email) SELECT l.id,r FROM public.lead_notification_settings s CROSS JOIN LATERAL unnest(s.recipients) r WHERE s.id AND s.enabled ON CONFLICT DO NOTHING;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'alert_retry','Failed or missing alerts queued; already accepted emails are not resent.');
 ELSE RAISE EXCEPTION 'Unknown lead action.';
 END IF;
 RETURN jsonb_build_object('ok',true);
END $function$
;
CREATE OR REPLACE FUNCTION private.prevent_spam_lead_alerts() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.status IN ('pending','processing','failed') AND EXISTS(SELECT 1 FROM public.consultations WHERE id=NEW.lead_id AND (lead_stage='spam' OR archived_at IS NOT NULL)) THEN
  NEW.status:='cancelled';NEW.locked_at:=NULL;NEW.claim_token:=NULL;NEW.last_error:='Cancelled because this enquiry is spam or removed from the active inbox.';
 END IF;RETURN NEW;
END $$;

-- JobZone keeps applications private to the posting employer. USSE receives counts and moderation controls only.
CREATE TABLE public.jobzone_posts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),employer_id uuid NOT NULL REFERENCES public.profiles(id),
 company_name text NOT NULL,title text NOT NULL,industry text NOT NULL,department text NOT NULL,location text NOT NULL,
 employment_type text NOT NULL CHECK(employment_type IN ('Full-time','Part-time','Contract','Temporary','Internship','Freelance')),
 work_mode text NOT NULL DEFAULT 'On-site' CHECK(work_mode IN ('On-site','Hybrid','Remote')),
 description text NOT NULL,requirements text NOT NULL,salary_text text NOT NULL DEFAULT '',
 status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','pending','published','closed','rejected')),
 closes_at timestamptz NOT NULL DEFAULT(now()+interval '30 days'),moderation_note text NOT NULL DEFAULT '',
 promotion_requested boolean NOT NULL DEFAULT false,promotion_order_id uuid REFERENCES public.ad_orders(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobzone_owner_idx ON public.jobzone_posts(employer_id,created_at DESC);
CREATE INDEX jobzone_public_idx ON public.jobzone_posts(status,closes_at,created_at DESC);
CREATE INDEX jobzone_promotion_order_idx ON public.jobzone_posts(promotion_order_id) WHERE promotion_order_id IS NOT NULL;
ALTER TABLE public.jobzone_posts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.jobzone_posts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.jobzone_posts TO authenticated;
CREATE POLICY jobzone_own_posts ON public.jobzone_posts FOR SELECT TO authenticated USING(employer_id=(SELECT auth.uid()) OR private.app_is_admin((SELECT auth.uid())));
CREATE TABLE private.jobzone_applications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_id uuid NOT NULL REFERENCES public.jobzone_posts(id),applicant_id uuid NOT NULL REFERENCES public.profiles(id),
 applicant_name text NOT NULL,email text NOT NULL,phone text NOT NULL DEFAULT '',statement text NOT NULL,cv_url text NOT NULL DEFAULT '',
 stage text NOT NULL DEFAULT 'received' CHECK(stage IN ('received','reviewing','contacted','shortlisted','hired','declined','withdrawn')),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(job_id,applicant_id)
);
CREATE INDEX jobzone_applicant_idx ON private.jobzone_applications(applicant_id,created_at DESC);
CREATE INDEX jobzone_application_job_idx ON private.jobzone_applications(job_id,created_at DESC);
CREATE TABLE private.jobzone_events (
 job_id uuid NOT NULL REFERENCES public.jobzone_posts(id),day date NOT NULL DEFAULT current_date,session_hash text NOT NULL,
 kind text NOT NULL CHECK(kind IN ('view','apply_open')),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(job_id,day,session_hash,kind)
);
ALTER TABLE private.jobzone_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.jobzone_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.jobzone_applications,private.jobzone_events FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.jobzone_public(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'company_name',p.company_name,'title',p.title,'industry',p.industry,'department',p.department,'location',p.location,'employment_type',p.employment_type,'work_mode',p.work_mode,'description',p.description,'requirements',p.requirements,'salary_text',p.salary_text,'closes_at',p.closes_at,'created_at',p.created_at,'promoted',p.promoted) ORDER BY p.promoted DESC,p.created_at DESC,p.id DESC) FROM page p),'[]')) INTO result;
 RETURN result;
END $$;
CREATE FUNCTION public.jobzone_public(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.jobzone_public(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.jobzone_public(text,jsonb),public.jobzone_public(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.jobzone_public(text,jsonb),public.jobzone_public(text,jsonb) TO anon,authenticated;

CREATE FUNCTION private.manage_jobzone(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();is_admin boolean;j public.jobzone_posts;a private.jobzone_applications;result jsonb;v_name text;v_email text;off int:=greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000));v_id uuid;v_status text;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND account_status='active') THEN RAISE EXCEPTION 'Sign in with an active account to use this workspace.' USING ERRCODE='42501'; END IF;
 is_admin:=private.app_is_admin(uid);
 IF p_action='save_post' THEN
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
  INSERT INTO public.jobzone_posts(id,employer_id,company_name,title,industry,department,location,employment_type,work_mode,description,requirements,salary_text,closes_at,status)
  VALUES(coalesce(j.id,gen_random_uuid()),uid,trim(p_payload->>'company_name'),trim(p_payload->>'title'),trim(p_payload->>'industry'),trim(p_payload->>'department'),trim(p_payload->>'location'),p_payload->>'employment_type',coalesce(p_payload->>'work_mode','On-site'),trim(p_payload->>'description'),trim(p_payload->>'requirements'),coalesce(p_payload->>'salary_text',''),(p_payload->>'closes_at')::timestamptz,v_status)
  ON CONFLICT(id) DO UPDATE SET company_name=excluded.company_name,title=excluded.title,industry=excluded.industry,department=excluded.department,location=excluded.location,employment_type=excluded.employment_type,work_mode=excluded.work_mode,description=excluded.description,requirements=excluded.requirements,salary_text=excluded.salary_text,closes_at=excluded.closes_at,status=excluded.status,moderation_note='',updated_at=now() RETURNING * INTO j;
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
CREATE FUNCTION public.manage_jobzone(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_jobzone(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_jobzone(text,jsonb),public.manage_jobzone(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_jobzone(text,jsonb),public.manage_jobzone(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';

-- Removing a lead is not a spam block; fresh submissions can still be recorded.
CREATE OR REPLACE FUNCTION private.guarded_record_lead(p_data jsonb, p_request_id uuid, p_fingerprint text, p_ip_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE keys text[]:=private.lead_contact_keys(p_data->>'email',p_data->>'phone');k text;n integer;
 ts timestamptz:=clock_timestamp();minute_bucket timestamptz:=date_trunc('minute',clock_timestamp());hour_bucket timestamptz:=date_trunc('hour',clock_timestamp());
 v_duplicate_key text;prior public.consultations;receipt jsonb;
BEGIN
 -- All routes use the same lock order. Idempotent retries never consume quotas.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,991));
 IF EXISTS(SELECT 1 FROM public.consultations WHERE request_id=p_request_id) THEN
  RETURN private.record_lead(p_data,p_request_id,p_fingerprint,p_ip_hash);
 END IF;
 IF nullif(p_ip_hash,'') IS NULL THEN RAISE EXCEPTION 'Request verification failed.';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('spam:ip:'||p_ip_hash,5413));
 FOR k IN SELECT unnest(keys) ORDER BY 1 LOOP PERFORM pg_advisory_xact_lock(hashtextextended('spam:contact:'||k,5413));END LOOP;
 IF EXISTS(SELECT 1 FROM private.lead_spam_blocks WHERE kind='contact' AND key_hash=ANY(keys) AND removed_at IS NULL AND (expires_at IS NULL OR expires_at>ts)) THEN
  PERFORM private.count_lead_spam('blocked_contact');RETURN jsonb_build_object('blocked',true,'reason','blocked_contact');
 END IF;
 IF EXISTS(SELECT 1 FROM private.lead_spam_blocks WHERE kind='connection' AND key_hash=p_ip_hash AND removed_at IS NULL AND expires_at>ts) THEN
  PERFORM private.count_lead_spam('blocked_connection');RETURN jsonb_build_object('blocked',true,'reason','blocked_connection');
 END IF;
 -- Persist rejected attempts by returning an outcome instead of raising/rolling back.
 INSERT INTO private.lead_rate_limits(key_hash,bucket) VALUES('spam:minute:ip:'||p_ip_hash,minute_bucket)
 ON CONFLICT(key_hash,bucket) DO UPDATE SET hits=private.lead_rate_limits.hits+1 RETURNING hits INTO n;
 IF n>3 THEN PERFORM private.count_lead_spam('rate_limit');RETURN jsonb_build_object('blocked',true,'reason','rate_limit','retry_after',greatest(1,ceil(extract(epoch FROM minute_bucket+interval '1 minute'-ts))::integer));END IF;
 FOREACH k IN ARRAY keys LOOP
  INSERT INTO private.lead_rate_limits(key_hash,bucket) VALUES('spam:minute:'||k,minute_bucket)
  ON CONFLICT(key_hash,bucket) DO UPDATE SET hits=private.lead_rate_limits.hits+1 RETURNING hits INTO n;
  IF n>2 THEN PERFORM private.count_lead_spam('rate_limit');RETURN jsonb_build_object('blocked',true,'reason','rate_limit','retry_after',greatest(1,ceil(extract(epoch FROM minute_bucket+interval '1 minute'-ts))::integer));END IF;
  INSERT INTO private.lead_rate_limits(key_hash,bucket) VALUES('spam:hour:'||k,hour_bucket)
  ON CONFLICT(key_hash,bucket) DO UPDATE SET hits=private.lead_rate_limits.hits+1 RETURNING hits INTO n;
  IF n>6 THEN PERFORM private.count_lead_spam('rate_limit');RETURN jsonb_build_object('blocked',true,'reason','rate_limit','retry_after',greatest(1,ceil(extract(epoch FROM hour_bucket+interval '1 hour'-ts))::integer));END IF;
 END LOOP;
 v_duplicate_key:=md5(array_to_string(keys,'|')||'|'||lower(regexp_replace(trim(p_data->>'notes'),'[[:space:]]+',' ','g'))||'|'||coalesce(p_data->>'branch','USSE')||'|'||coalesce(p_data->>'listing_id',''));
 SELECT c.* INTO prior FROM private.lead_submission_guard g JOIN public.consultations c ON c.id=g.lead_id
 WHERE g.duplicate_key=v_duplicate_key AND g.received_at>ts-interval '15 minutes' AND c.lead_stage<>'spam' AND c.archived_at IS NULL ORDER BY g.received_at DESC LIMIT 1;
 IF FOUND THEN PERFORM private.count_lead_spam('duplicate');RETURN jsonb_build_object('created',false,'duplicate',true,'lead_id',prior.id,'reference',prior.lead_reference);END IF;
 receipt:=private.record_lead(p_data,p_request_id,p_fingerprint,p_ip_hash);
 INSERT INTO private.lead_submission_guard(lead_id,ip_hash,duplicate_key) VALUES((receipt->>'lead_id')::uuid,p_ip_hash,v_duplicate_key);
 DELETE FROM private.lead_submission_guard WHERE received_at<ts-interval '90 days';
 DELETE FROM private.lead_spam_counts WHERE bucket<ts-interval '30 days';
 RETURN receipt;
END $function$
;
