-- Live-schema smoke test. No email is sent; every temporary record is rolled back.
BEGIN;
DO $$
DECLARE
  v_member uuid:=gen_random_uuid(); v_admin uuid:=gen_random_uuid(); v_listing uuid:=gen_random_uuid();
  v_email text:='usse-smoke-'||gen_random_uuid()::text||'@example.invalid';
  v_admin_email text:='usse-smoke-admin-'||gen_random_uuid()::text||'@example.invalid';
  v_result jsonb;
BEGIN
  INSERT INTO private.admin_email_grants(email) VALUES(v_admin_email);
  INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data,aud,role)
    VALUES(v_member,v_email,now(),'{"full_name":"Transactional member","role":"admin"}','authenticated','authenticated'),
          (v_admin,v_admin_email,now(),'{"full_name":"Transactional admin"}','authenticated','authenticated');
  IF (SELECT role FROM public.profiles WHERE id=v_member) <> 'member' THEN RAISE EXCEPTION 'Signup metadata changed access'; END IF;
  IF (SELECT role FROM public.profiles WHERE id=v_admin) <> 'admin' THEN RAISE EXCEPTION 'Verified reservation was not activated'; END IF;
  INSERT INTO public.listings(id,owner_user_id,business_name,location,category,status,expires_at)
    VALUES(v_listing,v_member,'Transactional smoke listing','kingston','SERVICES','expired',now()-interval '1 day');

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_member,'email',v_email,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_member::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  UPDATE public.profiles SET full_name='Transactional member updated' WHERE id=v_member;
  BEGIN
    UPDATE public.profiles SET role='admin' WHERE id=v_member;
    RAISE EXCEPTION 'Member role escalation was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.admin_get_ad_configuration();
    RAISE EXCEPTION 'Member accessed administrator configuration';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE public.listings SET status='approved' WHERE id=v_listing;
    IF FOUND THEN RAISE EXCEPTION 'Direct member approval was allowed'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  SELECT public.renew_free_listing(v_listing) INTO v_result;
  IF v_result->>'status' <> 'approved' THEN RAISE EXCEPTION 'Member listing renewal failed'; END IF;

  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'email',v_admin_email,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.admin_get_ad_configuration();

  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims','{"role":"anon"}',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  EXECUTE 'SET LOCAL ROLE anon';
  IF EXISTS(SELECT 1 FROM public.profiles) THEN RAISE EXCEPTION 'Anonymous profile access was allowed'; END IF;
  PERFORM public.get_ad_catalog();
  EXECUTE 'RESET ROLE';
END;
$$;
ROLLBACK;
