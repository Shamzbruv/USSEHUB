-- One durable lead record across USSE contact channels, with a private email outbox.
ALTER TABLE public.consultations
  ADD COLUMN lead_reference text GENERATED ALWAYS AS ('USSE-' || upper(substr(replace(id::text,'-',''),1,16))) STORED,
  ADD COLUMN request_id uuid UNIQUE,
  ADD COLUMN request_fingerprint text,
  ADD COLUMN listing_name text NOT NULL DEFAULT '',
  ADD COLUMN company text NOT NULL DEFAULT '',
  ADD COLUMN branch text NOT NULL DEFAULT 'USSE',
  ADD COLUMN service text NOT NULL DEFAULT '',
  ADD COLUMN source_page text NOT NULL DEFAULT '',
  ADD COLUMN attribution jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN lead_stage text NOT NULL DEFAULT 'new' CHECK (lead_stage IN ('new','contacted','qualified','won','lost','spam')),
  ADD COLUMN priority text NOT NULL DEFAULT 'urgent' CHECK (priority IN ('normal','urgent')),
  ADD COLUMN assigned_to uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN follow_up_at timestamptz,
  ADD COLUMN first_contacted_at timestamptz,
  ADD COLUMN consent_at timestamptz,
  ADD COLUMN capture_origin text NOT NULL DEFAULT 'legacy' CHECK (capture_origin IN ('legacy','website','manual'));
DO $checks$ DECLARE c record; BEGIN
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.consultations'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%source = ANY%' LOOP
    EXECUTE format('ALTER TABLE public.consultations DROP CONSTRAINT %I',c.conname);
  END LOOP;
END $checks$;
DO $fk$ DECLARE c record; BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.consultations'::regclass AND confrelid='public.listings'::regclass AND contype='f' LOOP EXECUTE format('ALTER TABLE public.consultations DROP CONSTRAINT %I',c.conname); END LOOP;
END $fk$;
ALTER TABLE public.consultations ADD CONSTRAINT lead_listing_reference FOREIGN KEY(listing_id) REFERENCES public.listings(id) ON DELETE SET NULL;
ALTER TABLE public.consultations ADD CONSTRAINT lead_source_check CHECK (source IN ('whatsapp','email','website','subscription','phone','walk_in','other'));
UPDATE public.consultations SET lead_stage=CASE status WHEN 'contacted' THEN 'contacted' WHEN 'completed' THEN 'won' WHEN 'cancelled' THEN 'lost' ELSE 'new' END,
 branch=CASE WHEN listing_id IS NOT NULL THEN 'AJM' ELSE 'USSE' END;
UPDATE public.consultations c SET listing_name=l.business_name FROM public.listings l WHERE l.id=c.listing_id;
CREATE INDEX lead_stage_created_idx ON public.consultations(lead_stage,created_at DESC,id DESC);
CREATE INDEX lead_follow_up_idx ON public.consultations(follow_up_at) WHERE lead_stage IN ('new','contacted','qualified');

CREATE TABLE public.lead_notification_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK(id),
  enabled boolean NOT NULL DEFAULT true,
  recipients text[] NOT NULL DEFAULT '{}',
  configured boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL
);
INSERT INTO public.lead_notification_settings(id) VALUES(true);
ALTER TABLE public.lead_notification_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lead_notification_settings FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.lead_notification_settings TO authenticated;
GRANT SELECT ON public.lead_notification_settings TO service_role;
CREATE POLICY lead_settings_admin_read ON public.lead_notification_settings FOR SELECT TO authenticated USING(private.is_admin((SELECT auth.uid())));

CREATE TABLE private.lead_activity (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),lead_id uuid NOT NULL REFERENCES public.consultations(id) ON DELETE CASCADE,
 actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,kind text NOT NULL,detail text NOT NULL DEFAULT '',created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_activity_lead_idx ON private.lead_activity(lead_id,created_at);
CREATE TABLE private.lead_alert_deliveries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),lead_id uuid NOT NULL REFERENCES public.consultations(id) ON DELETE CASCADE,
 recipient_email text NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','processing','accepted','failed')),
 attempts integer NOT NULL DEFAULT 0,available_at timestamptz NOT NULL DEFAULT now(),locked_at timestamptz,claim_token uuid,
 provider_id text,accepted_at timestamptz,last_error text,created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lead_id,recipient_email)
);
CREATE INDEX lead_alert_due_idx ON private.lead_alert_deliveries(available_at) WHERE status IN ('pending','failed','processing');
CREATE TABLE private.lead_rate_limits(key_hash text NOT NULL,bucket timestamptz NOT NULL,hits integer NOT NULL DEFAULT 1,PRIMARY KEY(key_hash,bucket));
ALTER TABLE private.lead_activity ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.lead_alert_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.lead_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.lead_activity,private.lead_alert_deliveries,private.lead_rate_limits FROM PUBLIC,anon,authenticated;

-- Public table inserts previously bypassed CAPTCHA. All public intake now uses
-- the validated Edge handler; members retain their existing owner SELECT policy.
DROP POLICY IF EXISTS "Public can insert consultations" ON public.consultations;
REVOKE ALL ON public.consultations FROM anon;
REVOKE INSERT,UPDATE,DELETE ON public.consultations FROM authenticated;
GRANT SELECT ON public.consultations TO authenticated;

CREATE FUNCTION private.queue_lead_alert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO private.lead_activity(lead_id,kind,detail) VALUES(NEW.id,'received','Enquiry recorded via ' || coalesce(NEW.source,'website'));
 INSERT INTO private.lead_alert_deliveries(lead_id,recipient_email)
 SELECT NEW.id,r FROM public.lead_notification_settings s CROSS JOIN LATERAL unnest(s.recipients) r WHERE s.id AND s.enabled;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.queue_lead_alert() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER queue_lead_alert AFTER INSERT ON public.consultations FOR EACH ROW EXECUTE FUNCTION private.queue_lead_alert();

CREATE FUNCTION private.record_lead(p_data jsonb,p_request_id uuid,p_fingerprint text,p_ip_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.consultations;hits integer; k text;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,991));
 SELECT * INTO l FROM public.consultations WHERE request_id=p_request_id;
 IF FOUND THEN
  IF l.request_fingerprint IS DISTINCT FROM p_fingerprint THEN RAISE EXCEPTION 'This request has already been used for another enquiry.' USING ERRCODE='23505'; END IF;
  RETURN jsonb_build_object('lead_id',l.id,'reference',l.lead_reference,'created',false);
 END IF;
 IF length(trim(coalesce(p_data->>'customer_name',''))) NOT BETWEEN 2 AND 100 OR length(trim(coalesce(p_data->>'notes',''))) NOT BETWEEN 5 AND 4000
 OR length(coalesce(p_data->>'phone',''))>50 OR length(coalesce(p_data->>'email',''))>254 OR (nullif(p_data->>'phone','') IS NULL AND nullif(p_data->>'email','') IS NULL)
 THEN RAISE EXCEPTION 'Please provide your name, contact details and enquiry.'; END IF;
 IF p_data->>'source' NOT IN ('email','whatsapp','website','subscription','phone') THEN RAISE EXCEPTION 'Invalid contact channel.'; END IF;
 IF nullif(p_data->>'listing_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.listings WHERE id=(p_data->>'listing_id')::uuid AND status='approved') THEN RAISE EXCEPTION 'This listing is not available for enquiries.'; END IF;
 IF p_data->>'consent' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Please agree to be contacted about this enquiry.'; END IF;
 IF nullif(p_ip_hash,'') IS NULL THEN RAISE EXCEPTION 'Request verification failed.'; END IF;
 FOREACH k IN ARRAY ARRAY['ip:'||p_ip_hash,'contact:'||md5(lower(coalesce(nullif(p_data->>'email',''),p_data->>'phone')))] LOOP
  INSERT INTO private.lead_rate_limits(key_hash,bucket) VALUES(k,date_trunc('hour',now())) ON CONFLICT(key_hash,bucket) DO UPDATE SET hits=private.lead_rate_limits.hits+1 RETURNING lead_rate_limits.hits INTO hits;
  IF hits>12 THEN RAISE EXCEPTION 'Too many enquiries. Please try again later.' USING ERRCODE='P0429'; END IF;
 END LOOP;
 DELETE FROM private.lead_rate_limits WHERE bucket<now()-interval '2 days';
 INSERT INTO public.consultations(listing_id,listing_name,customer_name,phone,email,source,notes,request_id,request_fingerprint,company,branch,service,source_page,attribution,consent_at,capture_origin)
 VALUES(nullif(p_data->>'listing_id','')::uuid,coalesce((SELECT business_name FROM public.listings WHERE id=nullif(p_data->>'listing_id','')::uuid),''),trim(p_data->>'customer_name'),nullif(p_data->>'phone',''),nullif(lower(p_data->>'email'),''),p_data->>'source',trim(p_data->>'notes'),p_request_id,p_fingerprint,
 left(coalesce(p_data->>'company',''),150),left(coalesce(p_data->>'branch','USSE'),80),left(coalesce(p_data->>'service',''),150),left(coalesce(p_data->>'source_page',''),200),coalesce(p_data->'attribution','{}'),now(),'website') RETURNING * INTO l;
 RETURN jsonb_build_object('lead_id',l.id,'reference',l.lead_reference,'created',true);
END $$;
CREATE FUNCTION public.capture_usse_lead(p_data jsonb,p_request_id uuid,p_fingerprint text,p_ip_hash text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.record_lead(p_data,p_request_id,p_fingerprint,p_ip_hash)$$;
REVOKE ALL ON FUNCTION private.record_lead(jsonb,uuid,text,text),public.capture_usse_lead(jsonb,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA private TO service_role;
GRANT EXECUTE ON FUNCTION private.record_lead(jsonb,uuid,text,text),public.capture_usse_lead(jsonb,uuid,text,text) TO service_role;

CREATE FUNCTION private.manage_leads(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
     AND (stage='' OR c.lead_stage=stage)
     AND (src='' OR c.source=src)
     AND (bid='' OR c.branch=bid)
     AND (NOT due OR (c.follow_up_at<now() AND c.lead_stage IN ('new','contacted','qualified')))
     AND (p_payload->>'as_of' IS NULL OR c.created_at<=(p_payload->>'as_of')::timestamptz)
  ), page AS (SELECT * FROM matched ORDER BY created_at DESC,id DESC LIMIT lim OFFSET off)
  SELECT jsonb_build_object('total',(SELECT count(*) FROM matched),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page)-'request_fingerprint'-'request_id' ORDER BY created_at DESC,id DESC) FROM page),'[]'),'metrics',(SELECT jsonb_build_object('new',count(*) FILTER(WHERE lead_stage='new'),'open',count(*) FILTER(WHERE lead_stage IN ('new','contacted','qualified')),'overdue',count(*) FILTER(WHERE follow_up_at<now() AND lead_stage IN ('new','contacted','qualified')),'failed_alerts',(SELECT count(*) FROM private.lead_alert_deliveries WHERE status='failed')) FROM public.consultations)) INTO result;
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
 ELSIF p_action='update' THEN
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
  UPDATE private.lead_alert_deliveries SET status='pending',attempts=0,available_at=now(),locked_at=NULL,claim_token=NULL,last_error=NULL WHERE lead_id=l.id AND status='failed';
  INSERT INTO private.lead_alert_deliveries(lead_id,recipient_email) SELECT l.id,r FROM public.lead_notification_settings s CROSS JOIN LATERAL unnest(s.recipients) r WHERE s.id AND s.enabled ON CONFLICT DO NOTHING;
  INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'alert_retry','Failed or missing alerts queued; already accepted emails are not resent.');
 ELSE RAISE EXCEPTION 'Unknown lead action.';
 END IF;
 RETURN jsonb_build_object('ok',true);
END $$;
CREATE FUNCTION public.admin_manage_leads(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_leads(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_leads(text,jsonb),public.admin_manage_leads(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.manage_leads(text,jsonb),public.admin_manage_leads(text,jsonb) TO authenticated;

CREATE FUNCTION private.lead_mail_worker(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;d private.lead_alert_deliveries;rs text[];
BEGIN
 IF p_action='initialize' THEN
  SELECT array_agg(DISTINCT lower(trim(x))) INTO rs FROM jsonb_array_elements_text(coalesce(p_payload->'recipients','[]')) x WHERE x ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$';
  IF cardinality(rs) BETWEEN 1 AND 10 THEN UPDATE public.lead_notification_settings SET recipients=rs,configured=true WHERE id AND NOT configured; END IF;
  RETURN jsonb_build_object('configured',(SELECT configured FROM public.lead_notification_settings WHERE id));
 ELSIF p_action='claim' THEN
  UPDATE private.lead_alert_deliveries SET status='failed',locked_at=NULL,claim_token=NULL,last_error='The email worker was interrupted. Retrying is safe within the provider idempotency window.' WHERE status='processing' AND locked_at<now()-interval '5 minutes';
  WITH picked AS (SELECT id FROM private.lead_alert_deliveries WHERE ((status IN ('pending','failed') AND available_at<=now()) OR (status='processing' AND locked_at<now()-interval '5 minutes')) AND attempts<8 AND EXISTS(SELECT 1 FROM public.lead_notification_settings s WHERE s.id AND s.enabled AND recipient_email=ANY(s.recipients)) ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 8), claimed AS (UPDATE private.lead_alert_deliveries SET status='processing',attempts=attempts+1,locked_at=now(),claim_token=gen_random_uuid() WHERE id IN(SELECT id FROM picked) RETURNING *)
  SELECT coalesce(jsonb_agg(jsonb_build_object('delivery',to_jsonb(claimed),'lead',to_jsonb(c)-'request_fingerprint'-'request_id')),'[]') INTO result FROM claimed JOIN public.consultations c ON c.id=claimed.lead_id;
  RETURN result;
 ELSIF p_action='finish' THEN
  SELECT * INTO d FROM private.lead_alert_deliveries WHERE id=(p_payload->>'id')::uuid AND claim_token=(p_payload->>'claim')::uuid AND status='processing' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
  UPDATE private.lead_alert_deliveries SET status=CASE WHEN (p_payload->>'accepted')::boolean THEN 'accepted' ELSE 'failed' END,provider_id=left(p_payload->>'provider_id',100),accepted_at=CASE WHEN (p_payload->>'accepted')::boolean THEN now() ELSE NULL END,last_error=left(p_payload->>'error',250),locked_at=NULL,claim_token=NULL,
   available_at=now()+make_interval(secs=>least(21600,(30*power(4,greatest(0,d.attempts-1)))::integer)) WHERE id=d.id;
  RETURN jsonb_build_object('ok',true);
 END IF;
 RAISE EXCEPTION 'Invalid mail worker action.';
END $$;
CREATE FUNCTION public.process_lead_mail(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.lead_mail_worker(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.lead_mail_worker(text,jsonb),public.process_lead_mail(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.lead_mail_worker(text,jsonb),public.process_lead_mail(text,jsonb) TO service_role;

CREATE FUNCTION private.request_lead_mail_dispatch() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE secret text;
BEGIN
 SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name='USSE_LEAD_DISPATCH_SECRET' LIMIT 1;
 IF nullif(secret,'') IS NOT NULL THEN PERFORM net.http_post(url:='https://zcptuqrlovflcpqszery.supabase.co/functions/v1/dispatch-lead-alerts',headers:=jsonb_build_object('Content-Type','application/json','X-Lead-Dispatch-Secret',secret),body:='{}'::jsonb,timeout_milliseconds:=10000); END IF;
END $$;
REVOKE ALL ON FUNCTION private.request_lead_mail_dispatch() FROM PUBLIC,anon,authenticated;
DO $cron$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='usse-lead-alert-retry') THEN PERFORM cron.schedule('usse-lead-alert-retry','* * * * *','SELECT private.request_lead_mail_dispatch();'); END IF;
END $cron$;
NOTIFY pgrst,'reload schema';
