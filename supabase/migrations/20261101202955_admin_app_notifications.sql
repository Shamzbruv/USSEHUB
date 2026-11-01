-- Installable administration: private device subscriptions and durable, per-admin activity.
-- New activity only. Existing business records and email settings are not changed.
CREATE FUNCTION private.app_is_admin(p_uid uuid DEFAULT auth.uid()) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_uid AND role='admin' AND account_status='active')
$$;
REVOKE ALL ON FUNCTION private.app_is_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.app_is_admin(uuid) TO authenticated,service_role;

CREATE TABLE public.admin_app_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 category text NOT NULL CHECK(category IN ('enquiries','members','listings','commerce','referrals','system')),
 title text NOT NULL, body text NOT NULL, target_path text NOT NULL,
 entity_table text NOT NULL, entity_id uuid, read_at timestamptz, dismissed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_app_notifications_feed ON public.admin_app_notifications(user_id,created_at DESC,id DESC) WHERE dismissed_at IS NULL;
CREATE INDEX admin_app_notifications_unread ON public.admin_app_notifications(user_id) WHERE read_at IS NULL AND dismissed_at IS NULL;
CREATE INDEX admin_app_notifications_entity ON public.admin_app_notifications(entity_table,entity_id);
ALTER TABLE public.admin_app_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_app_notifications FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.admin_app_notifications TO authenticated;
CREATE POLICY admin_app_own_activity ON public.admin_app_notifications FOR SELECT TO authenticated
 USING(user_id=(SELECT auth.uid()) AND private.app_is_admin((SELECT auth.uid())));

CREATE TABLE private.admin_app_preferences (
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 push_enabled boolean NOT NULL DEFAULT true,
 categories text[] NOT NULL DEFAULT ARRAY['enquiries','members','listings','commerce','referrals','system'],
 updated_at timestamptz NOT NULL DEFAULT now(), last_test_at timestamptz
);
CREATE TABLE private.admin_push_subscriptions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 session_id uuid NOT NULL REFERENCES auth.sessions(id) ON DELETE CASCADE,
 endpoint text NOT NULL UNIQUE, p256dh text NOT NULL, auth_key text NOT NULL, device_label text NOT NULL,
 enabled boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 last_accepted_at timestamptz,last_error text
);
CREATE INDEX admin_push_user_idx ON private.admin_push_subscriptions(user_id);
CREATE INDEX admin_push_session_idx ON private.admin_push_subscriptions(session_id);
CREATE TABLE private.admin_push_deliveries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),notification_id uuid NOT NULL REFERENCES public.admin_app_notifications(id) ON DELETE CASCADE,
 subscription_id uuid NOT NULL REFERENCES private.admin_push_subscriptions(id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','processing','accepted','failed','cancelled')),
 attempts int NOT NULL DEFAULT 0,available_at timestamptz NOT NULL DEFAULT now(),locked_at timestamptz,claim_token uuid,
 accepted_at timestamptz,last_error text, UNIQUE(notification_id,subscription_id)
);
CREATE INDEX admin_push_due_idx ON private.admin_push_deliveries(available_at) WHERE status IN ('pending','processing','failed');
CREATE TABLE private.admin_app_config(id boolean PRIMARY KEY DEFAULT true CHECK(id),vapid_public_key text NOT NULL);
ALTER TABLE private.admin_app_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.admin_push_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.admin_push_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.admin_app_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.admin_app_preferences,private.admin_push_subscriptions,private.admin_push_deliveries,private.admin_app_config FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.request_admin_push_dispatch() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE secret text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.admin_push_deliveries WHERE status IN ('pending','failed') AND available_at<=now() AND attempts<8) THEN RETURN; END IF;
 SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name='usse_admin_push_dispatch_secret' LIMIT 1;
 IF nullif(secret,'') IS NOT NULL THEN
  PERFORM net.http_post(url:='https://zcptuqrlovflcpqszery.supabase.co/functions/v1/admin-push',
   headers:=jsonb_build_object('Content-Type','application/json','X-USSE-Push-Secret',secret),body:='{}'::jsonb,timeout_milliseconds:=10000);
 END IF;
EXCEPTION WHEN OTHERS THEN
 -- Notification delivery must never prevent a customer enquiry or payment from saving.
 RAISE LOG 'USSE admin push dispatch deferred';
END $$;
REVOKE ALL ON FUNCTION private.request_admin_push_dispatch() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.app_emit(p_category text,p_title text,p_body text,p_path text,p_table text,p_id uuid,p_user uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 WITH added AS (
  INSERT INTO public.admin_app_notifications(user_id,category,title,body,target_path,entity_table,entity_id)
  SELECT id,p_category,p_title,p_body,p_path,p_table,p_id FROM public.profiles
  WHERE role='admin' AND account_status='active' AND (p_user IS NULL OR id=p_user) RETURNING *
 )
 INSERT INTO private.admin_push_deliveries(notification_id,subscription_id)
 SELECT n.id,s.id FROM added n JOIN private.admin_push_subscriptions s ON s.user_id=n.user_id AND s.enabled
 LEFT JOIN private.admin_app_preferences p ON p.user_id=n.user_id
 WHERE coalesce(p.push_enabled,true) AND n.category=ANY(coalesce(p.categories,ARRAY['enquiries','members','listings','commerce','referrals','system']));
 PERFORM private.request_admin_push_dispatch();
END $$;
REVOKE ALL ON FUNCTION private.app_emit(text,text,text,text,text,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.app_track_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n jsonb:=to_jsonb(NEW); o jsonb:=CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 title text; category text; dest text; rid uuid:=(n->>'id')::uuid;
BEGIN
 CASE TG_TABLE_NAME
 WHEN 'consultations' THEN
  IF n->>'lead_stage'='spam' THEN
   UPDATE public.admin_app_notifications SET dismissed_at=now() WHERE entity_table='consultations' AND entity_id=rid AND dismissed_at IS NULL;
   UPDATE private.admin_push_deliveries d SET status='cancelled',claim_token=NULL WHERE d.notification_id IN(SELECT id FROM public.admin_app_notifications WHERE entity_table='consultations' AND entity_id=rid) AND d.status IN ('pending','failed','processing');
   RETURN NEW;
  END IF;
  IF TG_OP='INSERT' THEN title:='New enquiry received';
  ELSIF n->>'lead_stage' IS DISTINCT FROM o->>'lead_stage' OR n->>'assigned_to' IS DISTINCT FROM o->>'assigned_to' OR n->>'follow_up_at' IS DISTINCT FROM o->>'follow_up_at' OR n->>'priority' IS DISTINCT FROM o->>'priority' THEN title:='Enquiry follow-up updated';
  ELSE RETURN NEW; END IF;
  category:='enquiries';dest:='/lead-inbox?lead='||rid;
 WHEN 'profiles' THEN
  IF TG_OP='UPDATE' AND (n->>'role'<>'admin' OR n->>'account_status'<>'active') THEN
   UPDATE private.admin_push_subscriptions SET enabled=false,updated_at=now() WHERE user_id=rid;
   UPDATE private.admin_push_deliveries d SET status='cancelled',claim_token=NULL WHERE subscription_id IN(SELECT id FROM private.admin_push_subscriptions WHERE user_id=rid) AND status IN ('pending','failed','processing');
  END IF;
  IF TG_OP='INSERT' THEN title:='New member registered';
  ELSIF n->>'role' IS DISTINCT FROM o->>'role' OR n->>'account_status' IS DISTINCT FROM o->>'account_status' THEN title:='Member access updated';
  ELSE RETURN NEW; END IF;
  category:='members';dest:='/master-admin?section=members';
 WHEN 'listings' THEN
  IF TG_OP='INSERT' THEN title:='New listing submitted';
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' THEN title:='Listing status updated';
  ELSIF n->>'business_name' IS DISTINCT FROM o->>'business_name' OR n->>'description' IS DISTINCT FROM o->>'description' THEN title:='Listing details updated';
  ELSE RETURN NEW; END IF;
  category:='listings';dest:='/ajm-admin-panel';
 WHEN 'ad_orders' THEN
  IF TG_OP='INSERT' THEN title:='New advertising order';
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' OR n->>'payment_submitted_at' IS DISTINCT FROM o->>'payment_submitted_at' THEN title:='Order or payment updated';
  ELSE RETURN NEW; END IF;
  category:='commerce';dest:='/ajm-ad-management';
 WHEN 'ad_subscriptions' THEN
  IF TG_OP='INSERT' THEN title:='New advertising subscription';
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' THEN title:='Subscription status updated';
  ELSE RETURN NEW; END IF;
  -- Orders already produce their own event; suppress derived subscription duplicates.
  IF n->>'ad_order_id' IS NOT NULL THEN RETURN NEW; END IF;
  category:='commerce';dest:='/ajm-ad-management';
 WHEN 'advertisements' THEN
  IF TG_OP='INSERT' THEN RETURN NEW;
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' THEN title:='Advertisement status updated';
  ELSE RETURN NEW; END IF;
  category:='commerce';dest:='/ajm-ad-management';
 WHEN 'referral_agreements' THEN
  IF TG_OP='INSERT' THEN title:='Partner agreement created';
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' THEN title:=CASE WHEN n->>'status'='signed' THEN 'Partner agreement signed' ELSE 'Partner agreement updated' END;
  ELSE RETURN NEW; END IF;
  category:='referrals';dest:='/referral-agreements';
 WHEN 'referral_register' THEN
  IF TG_OP='INSERT' THEN title:='New referral recorded';
  ELSIF n->>'status' IS DISTINCT FROM o->>'status' OR n->>'paid_at' IS DISTINCT FROM o->>'paid_at' THEN title:='Referral or commission updated';
  ELSE RETURN NEW; END IF;
  category:='referrals';dest:='/referral-agreements';
 ELSE RETURN NEW;
 END CASE;
 PERFORM private.app_emit(category,title,'Open your USSE workspace to review this activity.',dest,TG_TABLE_NAME,rid);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.app_track_change() FROM PUBLIC,anon,authenticated;
DO $triggers$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['consultations','profiles','listings','ad_orders','ad_subscriptions','advertisements','referral_agreements','referral_register'] LOOP
  EXECUTE format('CREATE TRIGGER usse_admin_app_activity AFTER INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION private.app_track_change()',t);
 END LOOP;
END $triggers$;

CREATE FUNCTION private.manage_admin_app(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); result jsonb; cats text[]; sub private.admin_push_subscriptions; ep text; nid uuid; device_count int; pref private.admin_app_preferences; page_offset int; sid uuid:=nullif(auth.jwt()->>'session_id','')::uuid;
BEGIN
 IF NOT private.app_is_admin(uid) THEN RAISE EXCEPTION 'An active administrator account is required.' USING ERRCODE='42501'; END IF;
 IF p_action='feed' THEN
  page_offset:=greatest(0,least(coalesce((p_payload->>'offset')::int,0),100000));
  SELECT jsonb_build_object('rows',coalesce((SELECT jsonb_agg(to_jsonb(n) ORDER BY n.created_at DESC,n.id DESC) FROM(SELECT id,category,title,body,target_path,read_at,created_at FROM public.admin_app_notifications WHERE user_id=uid AND dismissed_at IS NULL ORDER BY created_at DESC,id DESC LIMIT 25 OFFSET page_offset)n),'[]'::jsonb),
   'unread',(SELECT count(*) FROM public.admin_app_notifications WHERE user_id=uid AND dismissed_at IS NULL AND read_at IS NULL),
   'total',(SELECT count(*) FROM public.admin_app_notifications WHERE user_id=uid AND dismissed_at IS NULL)) INTO result;
  RETURN result;
 ELSIF p_action='read' THEN
  UPDATE public.admin_app_notifications SET read_at=coalesce(read_at,now()) WHERE user_id=uid AND (coalesce((p_payload->>'all')::boolean,false) OR id=(p_payload->>'id')::uuid);
  RETURN '{"ok":true}';
 ELSIF p_action='settings' THEN
  SELECT * INTO pref FROM private.admin_app_preferences WHERE user_id=uid;
  RETURN jsonb_build_object('push_enabled',coalesce(pref.push_enabled,true),'categories',coalesce(pref.categories,ARRAY['enquiries','members','listings','commerce','referrals','system']),
   'public_key',(SELECT vapid_public_key FROM private.admin_app_config WHERE id),
   'devices',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',device_label,'enabled',enabled,'created_at',created_at,'last_accepted_at',last_accepted_at,'last_error',last_error) ORDER BY created_at DESC) FROM private.admin_push_subscriptions WHERE user_id=uid),'[]'::jsonb));
 ELSIF p_action='preferences' THEN
  IF jsonb_typeof(p_payload->'categories') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload->'push_enabled') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Choose your alert categories.'; END IF;
  SELECT coalesce(array_agg(DISTINCT value),'{}'::text[]) INTO cats FROM jsonb_array_elements_text(p_payload->'categories');
  IF NOT cats <@ ARRAY['enquiries','members','listings','commerce','referrals','system'] THEN RAISE EXCEPTION 'Unknown alert category.'; END IF;
  INSERT INTO private.admin_app_preferences(user_id,push_enabled,categories) VALUES(uid,(p_payload->>'push_enabled')::boolean,cats)
  ON CONFLICT(user_id) DO UPDATE SET push_enabled=excluded.push_enabled,categories=excluded.categories,updated_at=now();
  UPDATE private.admin_push_deliveries d SET status='cancelled',claim_token=NULL WHERE status IN ('pending','failed','processing')
  AND notification_id IN(SELECT id FROM public.admin_app_notifications WHERE user_id=uid AND (NOT (p_payload->>'push_enabled')::boolean OR NOT category=ANY(cats)));
  RETURN '{"ok":true}';
 ELSIF p_action='subscribe' THEN
  IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid AND user_id=uid AND (not_after IS NULL OR not_after>now())) THEN RAISE EXCEPTION 'Sign in again before connecting device alerts.' USING ERRCODE='42501'; END IF;
  ep:=p_payload->'subscription'->>'endpoint';
  -- Only recognized browser push services may be contacted by the delivery worker.
  IF length(ep)>2048 OR ep !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]#]+$'
   OR coalesce(p_payload->'subscription'->'keys'->>'p256dh','') !~ '^[A-Za-z0-9_-]{87}=?$'
   OR coalesce(p_payload->'subscription'->'keys'->>'auth','') !~ '^[A-Za-z0-9_-]{22}={0,2}$' OR ep IS NULL THEN RAISE EXCEPTION 'This browser did not provide a valid push subscription.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(uid::text,801));
  SELECT * INTO sub FROM private.admin_push_subscriptions WHERE endpoint=ep FOR UPDATE;
  IF FOUND AND sub.user_id<>uid THEN RAISE EXCEPTION 'Remove this device subscription from the previous account first.'; END IF;
  SELECT count(*) INTO device_count FROM private.admin_push_subscriptions WHERE user_id=uid;
  IF sub.id IS NULL AND device_count>=10 THEN RAISE EXCEPTION 'Remove an old device before adding another. You can connect up to 10 devices.'; END IF;
  INSERT INTO private.admin_push_subscriptions(user_id,session_id,endpoint,p256dh,auth_key,device_label)
  VALUES(uid,sid,ep,p_payload->'subscription'->'keys'->>'p256dh',p_payload->'subscription'->'keys'->>'auth',left(coalesce(nullif(trim(p_payload->>'label'),''),'My device'),80))
  ON CONFLICT(endpoint) DO UPDATE SET session_id=excluded.session_id,p256dh=excluded.p256dh,auth_key=excluded.auth_key,device_label=excluded.device_label,enabled=true,updated_at=now(),last_error=NULL RETURNING * INTO sub;
  RETURN jsonb_build_object('id',sub.id);
 ELSIF p_action IN ('unsubscribe','remove_device') THEN
  UPDATE private.admin_push_deliveries SET status='cancelled',claim_token=NULL WHERE subscription_id IN(SELECT id FROM private.admin_push_subscriptions WHERE user_id=uid AND (CASE WHEN p_action='unsubscribe' THEN endpoint=p_payload->>'endpoint' ELSE id=(p_payload->>'id')::uuid END)) AND status IN ('pending','failed','processing');
  DELETE FROM private.admin_push_subscriptions WHERE user_id=uid AND (CASE WHEN p_action='unsubscribe' THEN endpoint=p_payload->>'endpoint' ELSE id=(p_payload->>'id')::uuid END);
  RETURN '{"ok":true}';
 ELSIF p_action='test' THEN
  IF NOT EXISTS(SELECT 1 FROM private.admin_push_subscriptions WHERE user_id=uid AND enabled) THEN RAISE EXCEPTION 'Enable notifications on this device first.'; END IF;
  INSERT INTO private.admin_app_preferences(user_id) VALUES(uid) ON CONFLICT DO NOTHING;
  SELECT * INTO pref FROM private.admin_app_preferences WHERE user_id=uid FOR UPDATE;
  IF pref.last_test_at>now()-interval '30 seconds' THEN RAISE EXCEPTION 'Please wait 30 seconds before sending another test.'; END IF;
  UPDATE private.admin_app_preferences SET last_test_at=now() WHERE user_id=uid;
  INSERT INTO public.admin_app_notifications(user_id,category,title,body,target_path,entity_table) VALUES(uid,'system','Your USSE alerts are connected','Your device is ready for USSE activity alerts.','/admin-app','test') RETURNING id INTO nid;
  INSERT INTO private.admin_push_deliveries(notification_id,subscription_id) SELECT nid,id FROM private.admin_push_subscriptions WHERE user_id=uid AND enabled;
  PERFORM private.request_admin_push_dispatch();
  RETURN jsonb_build_object('notification_id',nid);
 ELSIF p_action='test_status' THEN
  RETURN jsonb_build_object('results',coalesce((SELECT jsonb_agg(jsonb_build_object('device',s.device_label,'status',d.status,'error',d.last_error)) FROM private.admin_push_deliveries d JOIN private.admin_push_subscriptions s ON s.id=d.subscription_id JOIN public.admin_app_notifications n ON n.id=d.notification_id WHERE n.user_id=uid AND n.entity_table='test' AND n.id=(p_payload->>'id')::uuid),'[]'::jsonb));
 ELSE RAISE EXCEPTION 'Unknown app action.';
 END IF;
END $$;
CREATE FUNCTION public.admin_app(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_admin_app(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_admin_app(text,jsonb),public.admin_app(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_admin_app(text,jsonb),public.admin_app(text,jsonb) TO authenticated;

CREATE FUNCTION private.process_admin_push(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; item private.admin_push_deliveries;
BEGIN
 IF p_action='claim' THEN
  UPDATE private.admin_push_deliveries d SET status='cancelled',claim_token=NULL WHERE status IN ('pending','failed','processing') AND (
   d.attempts>=8 OR d.available_at<now()-interval '24 hours' OR NOT EXISTS(
    SELECT 1 FROM private.admin_push_subscriptions s JOIN public.admin_app_notifications n ON n.id=d.notification_id
    JOIN public.profiles u ON u.id=s.user_id LEFT JOIN private.admin_app_preferences p ON p.user_id=u.id
    WHERE s.id=d.subscription_id AND s.enabled AND EXISTS(SELECT 1 FROM auth.sessions a WHERE a.id=s.session_id AND a.user_id=u.id AND (a.not_after IS NULL OR a.not_after>now())) AND u.role='admin' AND u.account_status='active' AND n.dismissed_at IS NULL
    AND (n.entity_table='test' OR (coalesce(p.push_enabled,true) AND n.category=ANY(coalesce(p.categories,ARRAY['enquiries','members','listings','commerce','referrals','system']))))
   ));
  WITH due AS(SELECT id FROM private.admin_push_deliveries WHERE (status IN ('pending','failed') AND available_at<=now() OR status='processing' AND locked_at<now()-interval '2 minutes') AND attempts<8 ORDER BY available_at LIMIT 50 FOR UPDATE SKIP LOCKED),
  claimed AS(UPDATE private.admin_push_deliveries d SET status='processing',attempts=attempts+1,locked_at=now(),claim_token=gen_random_uuid() FROM due WHERE d.id=due.id RETURNING d.*)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',d.id,'claim_token',d.claim_token,'attempts',d.attempts,'subscription',jsonb_build_object('endpoint',s.endpoint,'keys',jsonb_build_object('p256dh',s.p256dh,'auth',s.auth_key)),
   'payload',jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'url',n.target_path,'category',n.category,
   'unread',(SELECT count(*) FROM public.admin_app_notifications x WHERE x.user_id=n.user_id AND x.read_at IS NULL AND x.dismissed_at IS NULL)))),'[]'::jsonb)
   INTO result FROM claimed d JOIN private.admin_push_subscriptions s ON s.id=d.subscription_id JOIN public.admin_app_notifications n ON n.id=d.notification_id;
  RETURN result;
 ELSIF p_action='complete' THEN
  SELECT * INTO item FROM private.admin_push_deliveries WHERE id=(p_payload->>'id')::uuid AND claim_token=(p_payload->>'claim_token')::uuid AND status='processing' FOR UPDATE;
  IF NOT FOUND THEN RETURN '{"stale":true}'; END IF;
  UPDATE private.admin_push_deliveries SET status=CASE WHEN p_payload->>'result'='accepted' THEN 'accepted' WHEN p_payload->>'result'='gone' THEN 'cancelled' ELSE 'failed' END,
   accepted_at=CASE WHEN p_payload->>'result'='accepted' THEN now() ELSE NULL END,last_error=left(p_payload->>'error',200),claim_token=NULL,
   available_at=now()+make_interval(secs=>least(3600,30*power(2,item.attempts)::int)) WHERE id=item.id;
  UPDATE private.admin_push_subscriptions SET last_accepted_at=CASE WHEN p_payload->>'result'='accepted' THEN now() ELSE last_accepted_at END,
   enabled=CASE WHEN p_payload->>'result'='gone' THEN false ELSE enabled END,last_error=left(p_payload->>'error',200) WHERE id=item.subscription_id;
  RETURN '{"ok":true}';
 ELSE RAISE EXCEPTION 'Unknown push worker action.'; END IF;
END $$;
CREATE FUNCTION public.process_admin_push(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.process_admin_push(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.process_admin_push(text,jsonb),public.process_admin_push(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.process_admin_push(text,jsonb),public.process_admin_push(text,jsonb) TO service_role;

DO $realtime$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='admin_app_notifications') THEN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.admin_app_notifications;
 END IF;
END $realtime$;
SELECT cron.schedule('usse-admin-push-retry','* * * * *','SELECT private.request_admin_push_dispatch();');
