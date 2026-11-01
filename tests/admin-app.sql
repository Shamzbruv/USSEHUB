-- Run inside a rolled-back transaction against the installed production schema.
DO $checks$ DECLARE actor uuid; other_admin uuid; lead uuid:=gen_random_uuid(); device uuid; event_id uuid; sid uuid:=gen_random_uuid(); r jsonb; jobs jsonb;
BEGIN
 IF has_table_privilege('anon','public.admin_app_notifications','SELECT') OR has_table_privilege('authenticated','private.admin_push_subscriptions','SELECT') OR has_function_privilege('authenticated','public.process_admin_push(text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Notification privacy check failed'; END IF;
 IF has_function_privilege('anon','public.admin_app(text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous app RPC access'; END IF;
 IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relrowsecurity AND ((n.nspname='private' AND c.relname IN('admin_app_preferences','admin_push_subscriptions','admin_push_deliveries','admin_app_config')) OR (n.nspname='public' AND c.relname='admin_app_notifications')))<>5 THEN RAISE EXCEPTION 'App RLS missing'; END IF;
 SELECT id INTO actor FROM public.profiles WHERE role='admin' AND account_status='active' ORDER BY id LIMIT 1;
 SELECT id INTO other_admin FROM public.profiles WHERE role='admin' AND account_status='active' AND id<>actor ORDER BY id LIMIT 1;
 IF actor IS NULL OR other_admin IS NULL THEN RAISE EXCEPTION 'Two active administrators are required for isolation verification'; END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.admin_app('feed'); RAISE EXCEPTION 'Unauthorized app access'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal) VALUES(sid,actor,now(),now(),'aal1');
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','session_id',sid)::text,true);
 INSERT INTO private.admin_app_preferences(user_id,push_enabled) VALUES(actor,true) ON CONFLICT(user_id) DO UPDATE SET push_enabled=true,categories=ARRAY['enquiries','members','listings','commerce','referrals','system'],last_test_at=NULL;
 -- Subscriptions never expose their endpoint or browser encryption keys to the settings response.
 r:=public.admin_app('subscribe',jsonb_build_object('label','USSE verification device','subscription',jsonb_build_object('endpoint','https://fcm.googleapis.com/fcm/send/usse-rolled-back-verification','keys',jsonb_build_object('p256dh','B'||repeat('A',86),'auth',repeat('A',22)))));
 device:=(r->>'id')::uuid;
 IF public.admin_app('settings')::text LIKE '%usse-rolled-back-verification%' OR public.admin_app('settings')::text LIKE '%p256dh%' THEN RAISE EXCEPTION 'Subscription capability leaked'; END IF;
 BEGIN PERFORM public.admin_app('subscribe','{"subscription":{"endpoint":"https://127.0.0.1/private","keys":{"p256dh":"bad","auth":"bad"}}}');RAISE EXCEPTION 'Push SSRF accepted';EXCEPTION WHEN raise_exception THEN IF SQLERRM='Push SSRF accepted' THEN RAISE; END IF;END;
 INSERT INTO public.consultations(id,customer_name,phone,source,notes,capture_origin) VALUES(lead,'USSE rolled-back app verification','8765550199','phone','Synthetic verification. Never commit.','manual');
 IF (SELECT count(*) FROM public.admin_app_notifications WHERE entity_table='consultations' AND entity_id=lead)<>(SELECT count(*) FROM public.profiles WHERE role='admin' AND account_status='active') THEN RAISE EXCEPTION 'New enquiry did not fan out to active administrators'; END IF;
 SELECT id INTO event_id FROM public.admin_app_notifications WHERE entity_id=lead AND user_id=actor;
 r:=public.admin_app('feed');IF NOT r->'rows' @> jsonb_build_array(jsonb_build_object('id',event_id)) THEN RAISE EXCEPTION 'Feed omitted new enquiry'; END IF;
 PERFORM set_config('request.jwt.claim.sub',other_admin::text,true);
 PERFORM public.admin_app('read',jsonb_build_object('id',event_id));
 IF (SELECT read_at FROM public.admin_app_notifications WHERE id=event_id) IS NOT NULL THEN RAISE EXCEPTION 'Cross-admin read mutation'; END IF;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 PERFORM public.admin_app('read',jsonb_build_object('id',event_id));
 IF (SELECT read_at FROM public.admin_app_notifications WHERE id=event_id) IS NULL THEN RAISE EXCEPTION 'Own read state did not save'; END IF;
 jobs:=public.process_admin_push('claim');
 IF NOT jobs @> jsonb_build_array(jsonb_build_object('payload',jsonb_build_object('id',event_id))) THEN RAISE EXCEPTION 'Push queue omitted enquiry'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(jobs) j WHERE j->'payload' ? 'email' OR j->'payload' ? 'customer_name' OR j->'payload' ? 'notes') THEN RAISE EXCEPTION 'Customer data in lock-screen payload'; END IF;
 PERFORM public.process_admin_push('complete',jsonb_build_object('id',j->>'id','claim_token',j->>'claim_token','result','failed','error','Verification retry')) FROM jsonb_array_elements(jobs) j WHERE j->'payload'->>'id'=event_id::text;
 IF NOT EXISTS(SELECT 1 FROM private.admin_push_deliveries WHERE notification_id=event_id AND status='failed' AND available_at>now()) THEN RAISE EXCEPTION 'Retry not scheduled'; END IF;
 UPDATE public.consultations SET lead_stage='spam' WHERE id=lead;
 IF EXISTS(SELECT 1 FROM private.admin_push_deliveries WHERE notification_id=event_id AND status IN ('pending','failed','processing')) THEN RAISE EXCEPTION 'Spam notification not cancelled'; END IF;
 IF EXISTS(SELECT 1 FROM public.admin_app_notifications WHERE entity_id=lead AND dismissed_at IS NULL) THEN RAISE EXCEPTION 'Spam remains in activity'; END IF;
 PERFORM public.admin_app('preferences','{"push_enabled":false,"categories":["enquiries"]}');
 PERFORM private.app_emit('enquiries','Preference verification','Synthetic verification','/admin-app','test',gen_random_uuid(),actor);
 IF EXISTS(SELECT 1 FROM private.admin_push_deliveries WHERE subscription_id=device AND status='pending') THEN RAISE EXCEPTION 'Paused preference ignored'; END IF;
 PERFORM public.admin_app('test');
 IF NOT EXISTS(SELECT 1 FROM private.admin_push_deliveries d JOIN public.admin_app_notifications n ON n.id=d.notification_id WHERE d.subscription_id=device AND n.entity_table='test' AND d.status='pending') THEN RAISE EXCEPTION 'Device test was not queued'; END IF;
 PERFORM public.admin_app('remove_device',jsonb_build_object('id',device));
 IF EXISTS(SELECT 1 FROM private.admin_push_subscriptions WHERE id=device) THEN RAISE EXCEPTION 'Device removal failed'; END IF;
 -- A subscription bound to a revoked login session is removed by its foreign key.
 INSERT INTO private.admin_push_subscriptions(user_id,session_id,endpoint,p256dh,auth_key,device_label) VALUES(actor,sid,'https://fcm.googleapis.com/fcm/send/usse-signout-verification','B'||repeat('A',86),repeat('A',22),'Sign-out verification') RETURNING id INTO device;
 DELETE FROM auth.sessions WHERE id=sid;
 IF EXISTS(SELECT 1 FROM private.admin_push_subscriptions WHERE id=device) THEN RAISE EXCEPTION 'Revoked session kept device access'; END IF;
 RAISE NOTICE 'App checks passed: admin isolation, durable enquiry event, private subscription, spam cancellation, retry, pause, device test and removal';
END $checks$;
SET LOCAL ROLE authenticated;
DO $rls$ BEGIN
 IF EXISTS(SELECT 1 FROM public.admin_app_notifications WHERE user_id<>auth.uid()) THEN RAISE EXCEPTION 'RLS exposed another administrator inbox'; END IF;
 BEGIN PERFORM 1 FROM private.admin_push_subscriptions;RAISE EXCEPTION 'Private subscriptions readable';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.process_admin_push('claim');RAISE EXCEPTION 'Member reached delivery worker';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $rls$;
RESET ROLE;
