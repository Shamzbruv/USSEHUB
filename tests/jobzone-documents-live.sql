-- Rolled-back verification only. Never commit synthetic applications or object metadata.
DO $checks$ DECLARE candidate uuid;admin_id uuid;other_id uuid;r jsonb;sid uuid:=gen_random_uuid();key text;
BEGIN
 SELECT p.id INTO candidate FROM public.profiles p JOIN auth.users u ON u.id=p.id WHERE p.account_status='active' AND p.role<>'admin' AND u.email_confirmed_at IS NOT NULL ORDER BY p.id LIMIT 1;
 SELECT id INTO admin_id FROM public.profiles WHERE role='admin' AND account_status='active' ORDER BY id LIMIT 1;
 SELECT id INTO other_id FROM public.profiles WHERE account_status='active' AND role<>'admin' AND id<>candidate ORDER BY id LIMIT 1;
 IF candidate IS NULL OR admin_id IS NULL OR other_id IS NULL THEN RAISE EXCEPTION 'Verified member, administrator and another active account required for verification.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.buckets WHERE id='jobzone-usse-applications' AND NOT public AND file_size_limit=5242880 AND allowed_mime_types=ARRAY['application/pdf']) THEN RAISE EXCEPTION 'Private PDF bucket limits missing';END IF;
 IF has_table_privilege('authenticated','private.jobzone_usse_submissions','SELECT') OR has_function_privilege('anon','public.manage_jobzone_documents(text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Document privileges too broad'; END IF;
 PERFORM set_config('request.jwt.claim.sub',candidate::text,true);
 r:=public.manage_jobzone_documents('begin',jsonb_build_object('id',sid,'name','USSE rolled-back PDF verification','statement','Synthetic private PDF workflow verification. Must not be committed.','file_name','verification.pdf','file_size',32,'consent',true));key:=r->>'object_key';
 IF NOT private.jobzone_pdf_access(key,true) THEN RAISE EXCEPTION 'Applicant cannot upload reserved PDF'; END IF;
 BEGIN PERFORM public.manage_jobzone_documents('submit',jsonb_build_object('id',sid));RAISE EXCEPTION 'Incomplete upload accepted';EXCEPTION WHEN raise_exception THEN IF SQLERRM='Incomplete upload accepted' THEN RAISE; END IF;END;
 -- Metadata exists solely within this transaction; no Storage bytes are uploaded or retained.
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('jobzone-usse-applications',key,'{"mimetype":"application/pdf","size":32}');
 PERFORM public.manage_jobzone_documents('submit',jsonb_build_object('id',sid));
 IF (public.manage_jobzone_documents('submit',jsonb_build_object('id',sid))->>'duplicate')<>'true' THEN RAISE EXCEPTION 'Receipt is not idempotent'; END IF;
 PERFORM set_config('request.jwt.claim.sub',other_id::text,true);
 IF private.jobzone_pdf_access(key,false) THEN RAISE EXCEPTION 'Another account can read private USSE PDF'; END IF;
 BEGIN PERFORM public.manage_jobzone_documents('list_usse');RAISE EXCEPTION 'Member entered USSE PDF inbox';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 IF NOT private.jobzone_pdf_access(key,false) THEN RAISE EXCEPTION 'Admin cannot read submitted USSE PDF'; END IF;
 PERFORM public.manage_jobzone_documents('review',jsonb_build_object('id',sid,'status','reviewing'));
 PERFORM set_config('request.jwt.claim.sub',candidate::text,true);
 PERFORM public.manage_jobzone_documents('withdraw',jsonb_build_object('id',sid));
 PERFORM set_config('request.jwt.claim.sub',admin_id::text,true);
 IF private.jobzone_pdf_access(key,false) THEN RAISE EXCEPTION 'Withdrawn PDF remains accessible to USSE'; END IF;
END $checks$;
