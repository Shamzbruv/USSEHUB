-- Run inside BEGIN/ROLLBACK only. No adverts, synthetic image metadata or notifications are retained.
DO $checks$ DECLARE admin_id uuid;member_id uuid;jid uuid:=gen_random_uuid();r jsonb;key text;
BEGIN
 SELECT p.id INTO admin_id FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.role='admin' AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL ORDER BY p.id LIMIT 1;
 SELECT p.id INTO member_id FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.role<>'admin' AND p.account_status='active' AND u.email_confirmed_at IS NOT NULL ORDER BY p.id LIMIT 1;
 IF admin_id IS NULL OR member_id IS NULL THEN RAISE EXCEPTION 'A verified administrator and member are required for flyer verification.'; END IF;
 IF has_function_privilege('anon','public.manage_jobzone_flyer(text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous flyer write access is too broad'; END IF;
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 r:=public.manage_jobzone_flyer('reserve',jsonb_build_object('id',jid,'request_id',gen_random_uuid(),'title','USSE rolled-back flyer verification','company_name','Synthetic advertiser','caption','Synthetic test advert, never committed or published.','mime','image/png','file_size',40,'new_image',true,'display_days',7));key:=r->>'path';
 IF NOT private.jobzone_flyer_access(key,true) THEN RAISE EXCEPTION 'Owner cannot upload reserved flyer';END IF;
 BEGIN PERFORM public.manage_jobzone_flyer('publish',jsonb_build_object('id',jid,'submit',true));RAISE EXCEPTION 'Incomplete flyer was published';EXCEPTION WHEN raise_exception THEN IF SQLERRM='Incomplete flyer was published' THEN RAISE;END IF;END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 IF private.jobzone_flyer_access(key,false) THEN RAISE EXCEPTION 'Draft flyer is publicly readable'; END IF;
 -- Synthetic Storage metadata exists only in this rolled-back transaction; no image bytes are uploaded.
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('jobzone-vacancy-flyers',key,'{"mimetype":"image/png","size":40}');
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 r:=public.manage_jobzone_flyer('publish',jsonb_build_object('id',jid,'submit',true));IF r->>'status'<>'published' THEN RAISE EXCEPTION 'Administrator could not publish completed flyer'; END IF;
 IF (public.manage_jobzone_flyer('publish',jsonb_build_object('id',jid,'submit',true))->>'duplicate')<>'true' THEN RAISE EXCEPTION 'Flyer publication is not idempotent'; END IF;
 PERFORM set_config('request.jwt.claim.sub','',true);
 IF NOT private.jobzone_flyer_access(key,false) THEN RAISE EXCEPTION 'Published flyer is missing public image access'; END IF;
 r:=public.jobzone_public('detail',jsonb_build_object('id',jid));IF r->'rows'->0->>'post_kind'<>'flyer' OR r->'rows'->0->>'flyer_deadline_known'<>'false' THEN RAISE EXCEPTION 'Public flyer or display date label failed'; END IF;
 PERFORM set_config('request.jwt.claim.sub',member_id::text,true);
 BEGIN PERFORM public.manage_jobzone('apply',jsonb_build_object('id',jid));RAISE EXCEPTION 'Shared flyer received a platform application';EXCEPTION WHEN raise_exception THEN IF SQLERRM='Shared flyer received a platform application' THEN RAISE;END IF;END;
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 PERFORM public.manage_jobzone('close',jsonb_build_object('id',jid));
 PERFORM set_config('request.jwt.claim.sub','',true);
 IF private.jobzone_flyer_access(key,false) THEN RAISE EXCEPTION 'Closed flyer continues generating public image links'; END IF;
END $checks$;
