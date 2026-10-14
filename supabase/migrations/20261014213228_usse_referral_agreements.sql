-- Additive USSE-wide referral agreements. No existing commerce tables are changed.
-- Browser roles can only SELECT admin records; all writes use guarded RPCs.
BEGIN;
CREATE TABLE public.referral_program_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  settings jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings) = 'object'),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.referral_agreements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference text NOT NULL UNIQUE DEFAULT ('USSE-REF-' || to_char(now(),'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
  snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','pending','signed','cancelled')),
  token_hash text UNIQUE,
  expires_at timestamptz,
  issued_at timestamptz,
  signed_at timestamptz,
  signer_name text,
  partner_signature text,
  acknowledgements jsonb,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'pending' OR (token_hash IS NOT NULL AND expires_at IS NOT NULL)),
  CHECK (status <> 'signed' OR (signed_at IS NOT NULL AND signer_name IS NOT NULL AND partner_signature IS NOT NULL AND acknowledgements IS NOT NULL))
);
CREATE INDEX referral_agreements_status_created ON public.referral_agreements(status,created_at DESC);
CREATE TABLE public.referral_register (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id uuid NOT NULL REFERENCES public.referral_agreements(id),
  client_name text NOT NULL CHECK (length(trim(client_name)) BETWEEN 2 AND 300),
  opportunity_ref text NOT NULL CHECK (length(trim(opportunity_ref)) BETWEEN 2 AND 300),
  unit text NOT NULL CHECK (unit IN ('consultancy','ajm','pistol')),
  project_value numeric(16,2) NOT NULL CHECK (project_value > 0),
  cleared_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (cleared_amount >= 0),
  refunded_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (refunded_amount BETWEEN 0 AND cleared_amount),
  commission_amount numeric(16,2) NOT NULL CHECK (commission_amount >= 0),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','qualified','paid','rejected')),
  notes text NOT NULL DEFAULT '' CHECK (length(notes) <= 4000),
  payout_reference text CHECK (length(payout_reference) <= 300),
  paid_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (unit,opportunity_ref),
  CHECK (cleared_amount <= project_value),
  CHECK (status <> 'paid' OR (paid_at IS NOT NULL AND length(trim(payout_reference)) >= 2))
);
CREATE INDEX referral_register_agreement_id ON public.referral_register(agreement_id);
CREATE TABLE public.referral_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id uuid REFERENCES public.referral_agreements(id),
  referral_id uuid REFERENCES public.referral_register(id),
  action text NOT NULL,
  actor_id uuid REFERENCES public.profiles(id),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX referral_audit_events_agreement_id ON public.referral_audit_events(agreement_id,created_at DESC);
CREATE INDEX referral_audit_events_referral_id ON public.referral_audit_events(referral_id);
ALTER TABLE public.referral_program_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_register ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_audit_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.referral_program_settings,public.referral_agreements,public.referral_register,public.referral_audit_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.referral_program_settings,public.referral_agreements,public.referral_register,public.referral_audit_events TO authenticated;
CREATE POLICY referral_settings_admin_read ON public.referral_program_settings FOR SELECT TO authenticated USING (private.is_admin((SELECT auth.uid())));
CREATE POLICY referral_agreements_admin_read ON public.referral_agreements FOR SELECT TO authenticated USING (private.is_admin((SELECT auth.uid())));
CREATE POLICY referral_register_admin_read ON public.referral_register FOR SELECT TO authenticated USING (private.is_admin((SELECT auth.uid())));
CREATE POLICY referral_audit_admin_read ON public.referral_audit_events FOR SELECT TO authenticated USING (private.is_admin((SELECT auth.uid())));

CREATE FUNCTION private.validate_referral_snapshot(s jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE k text; n numeric;
BEGIN
  IF jsonb_typeof(s) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Agreement terms are required.'; END IF;
  FOREACH k IN ARRAY ARRAY['company_name','company_signer','company_position','company_email','partner_name','partner_email','partner_address','partner_phone','effective_date'] LOOP
    IF coalesce(length(trim(s->>k)),0) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Complete the contact and effective date fields.'; END IF;
  END LOOP;
  IF s->>'partner_email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' OR s->>'company_email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN RAISE EXCEPTION 'Valid email addresses are required.'; END IF;
  IF s->>'effective_date' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'Choose an effective date.'; END IF;
  PERFORM (s->>'effective_date')::date;
  IF jsonb_typeof(s->'units') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Choose covered subsidiaries.'; END IF;
  IF jsonb_array_length(s->'units') NOT BETWEEN 1 AND 3 OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(s->'units') u WHERE u NOT IN ('consultancy','ajm','pistol')) THEN RAISE EXCEPTION 'Invalid subsidiary scope.'; END IF;
  IF coalesce(s->>'currency','') NOT IN ('JMD','USD') OR coalesce(s->>'commission_mode','') NOT IN ('percentage','flat','tiered') THEN RAISE EXCEPTION 'Invalid commission structure.'; END IF;
  FOREACH k IN ARRAY ARRAY['commission_percent','flat_amount','threshold_amount','payment_days','notice_days'] LOOP
    IF jsonb_typeof(s->k) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Numeric commission terms are required.'; END IF;
    n := (s->>k)::numeric;
    IF n < 0 OR n > (CASE k WHEN 'commission_percent' THEN 100 WHEN 'flat_amount' THEN 100000000 WHEN 'threshold_amount' THEN 10000000000 ELSE 365 END) THEN RAISE EXCEPTION 'Commission terms are outside the permitted range.'; END IF;
    IF k IN ('payment_days','notice_days') AND n <> trunc(n) THEN RAISE EXCEPTION 'Use whole days.'; END IF;
  END LOOP;
  IF (s->>'payment_days')::numeric < 1 THEN RAISE EXCEPTION 'Payment days must be positive.'; END IF;
  IF s->>'commission_mode' = 'tiered' AND (s->>'threshold_amount')::numeric <= 0 THEN RAISE EXCEPTION 'Tier threshold must be positive.'; END IF;
  IF (s->>'commission_mode' = 'percentage' AND (s->>'commission_percent')::numeric <= 0) OR (s->>'commission_mode' = 'flat' AND (s->>'flat_amount')::numeric <= 0) OR (s->>'commission_mode' = 'tiered' AND (s->>'flat_amount')::numeric <= 0 AND (s->>'commission_percent')::numeric <= 0) THEN RAISE EXCEPTION 'Set a commission rate.'; END IF;
  IF jsonb_typeof(s->'document_sections') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Agreement document sections are required.'; END IF;
  IF jsonb_array_length(s->'document_sections') NOT BETWEEN 11 AND 12 OR length((s->'document_sections')::text)>24000 THEN RAISE EXCEPTION 'Invalid agreement document.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(s->'document_sections') section WHERE jsonb_typeof(section) <> 'array' OR jsonb_array_length(section) <> 2 OR jsonb_typeof(section->0) <> 'string' OR jsonb_typeof(section->1) <> 'string') THEN RAISE EXCEPTION 'Invalid document section.'; END IF;
  IF coalesce(s->>'template_version','') <> 'usse-referral-v1' THEN RAISE EXCEPTION 'Unsupported agreement template.'; END IF;
  IF coalesce(length(s->>'additional_terms'),0) > 6000 THEN RAISE EXCEPTION 'Additional terms are too long.'; END IF;
  IF coalesce(s->>'company_signature','') !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$' OR length(s->>'company_signature') > 400000 THEN RAISE EXCEPTION 'Upload a valid company signature.'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.validate_referral_snapshot(jsonb) FROM PUBLIC,anon,authenticated;

-- Admin writes deliberately bypass RLS only after verifying the trusted profiles role.
CREATE FUNCTION private.manage_referrals(p_action text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.referral_agreements; r public.referral_register; s jsonb; rid uuid; v numeric; c numeric; f numeric; commission numeric;
BEGIN
  PERFORM private.require_admin(auth.uid());
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid request.'; END IF;
  IF p_action = 'settings' THEN
    s := p_payload->'settings';
    IF jsonb_typeof(s) IS DISTINCT FROM 'object' OR length(s::text) > 410000 THEN RAISE EXCEPTION 'Invalid settings.'; END IF;
    IF coalesce(s->>'company_signature','') !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$' OR length(s->>'company_signature') > 400000 THEN RAISE EXCEPTION 'Upload a valid PNG signature.'; END IF;
    INSERT INTO public.referral_program_settings(id,settings) VALUES (true,s) ON CONFLICT (id) DO UPDATE SET settings=excluded.settings,updated_at=now();
    INSERT INTO public.referral_audit_events(action,actor_id) VALUES ('settings_updated',auth.uid());
    RETURN s;
  ELSIF p_action = 'create' THEN
    s := p_payload->'snapshot'; PERFORM private.validate_referral_snapshot(s);
    INSERT INTO public.referral_agreements(snapshot,created_by) VALUES(s,auth.uid()) RETURNING * INTO a;
  ELSIF p_action IN ('edit','issue','cancel') THEN
    SELECT * INTO a FROM public.referral_agreements WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Agreement not found.'; END IF;
    IF p_action='edit' THEN
      IF a.status <> 'draft' THEN RAISE EXCEPTION 'Only drafts can be edited. Create a new agreement to change issued terms.'; END IF;
      s := p_payload->'snapshot'; PERFORM private.validate_referral_snapshot(s);
      UPDATE public.referral_agreements SET snapshot=s,updated_at=now() WHERE id=a.id RETURNING * INTO a;
    ELSIF p_action='issue' THEN
      IF a.status NOT IN ('draft','pending') THEN RAISE EXCEPTION 'This agreement cannot be issued.'; END IF;
      PERFORM private.validate_referral_snapshot(a.snapshot);
      IF coalesce(p_payload->>'token','') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid signing token.'; END IF;
      UPDATE public.referral_agreements SET status='pending',token_hash=encode(sha256(convert_to(p_payload->>'token','UTF8')),'hex'),expires_at=now()+interval '30 days',issued_at=coalesce(issued_at,now()),updated_at=now() WHERE id=a.id RETURNING * INTO a;
    ELSE
      IF a.status NOT IN ('draft','pending') THEN RAISE EXCEPTION 'Only unsigned agreements can be cancelled.'; END IF;
      UPDATE public.referral_agreements SET status='cancelled',token_hash=NULL,updated_at=now() WHERE id=a.id RETURNING * INTO a;
    END IF;
  ELSIF p_action='referral_save' THEN
    rid := nullif(p_payload->>'id','')::uuid;
    IF rid IS NOT NULL THEN
      SELECT * INTO r FROM public.referral_register WHERE id=rid FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Referral not found.'; END IF;
      IF r.status='paid' THEN RAISE EXCEPTION 'Paid referral records are locked. Record an adjustment separately.'; END IF;
    END IF;
    SELECT * INTO a FROM public.referral_agreements WHERE id=(p_payload->>'agreement_id')::uuid;
    IF NOT FOUND OR a.status <> 'signed' THEN RAISE EXCEPTION 'Choose a signed agreement.'; END IF;
    IF NOT (a.snapshot->'units' ? (p_payload->>'unit')) THEN RAISE EXCEPTION 'This subsidiary is outside the signed agreement.'; END IF;
    v := (p_payload->>'project_value')::numeric; c := (p_payload->>'cleared_amount')::numeric; f := (p_payload->>'refunded_amount')::numeric;
    IF v IS NULL OR c IS NULL OR f IS NULL OR v<=0 OR v>10000000000 OR c<0 OR c>v OR f<0 OR f>c THEN RAISE EXCEPTION 'Check the project, cleared and refunded amounts.'; END IF;
    s := a.snapshot;
    commission := CASE WHEN s->>'commission_mode'='flat' OR (s->>'commission_mode'='tiered' AND v<(s->>'threshold_amount')::numeric) THEN CASE WHEN c-f>=v THEN (s->>'flat_amount')::numeric ELSE 0 END ELSE round((c-f)*(s->>'commission_percent')::numeric/100,2) END;
    IF coalesce(p_payload->>'status','') NOT IN ('pending','qualified','rejected') THEN RAISE EXCEPTION 'Invalid referral status.'; END IF;
    INSERT INTO public.referral_register(id,agreement_id,client_name,opportunity_ref,unit,project_value,cleared_amount,refunded_amount,commission_amount,status,notes,created_by)
    VALUES(coalesce(rid,gen_random_uuid()),a.id,trim(p_payload->>'client_name'),trim(p_payload->>'opportunity_ref'),p_payload->>'unit',v,c,f,commission,p_payload->>'status',coalesce(p_payload->>'notes',''),auth.uid())
    ON CONFLICT(id) DO UPDATE SET agreement_id=excluded.agreement_id,client_name=excluded.client_name,opportunity_ref=excluded.opportunity_ref,unit=excluded.unit,project_value=excluded.project_value,cleared_amount=excluded.cleared_amount,refunded_amount=excluded.refunded_amount,commission_amount=excluded.commission_amount,status=excluded.status,notes=excluded.notes,updated_at=now() RETURNING * INTO r;
    INSERT INTO public.referral_audit_events(agreement_id,referral_id,action,actor_id,detail) VALUES(a.id,r.id,p_action,auth.uid(),jsonb_build_object('commission',r.commission_amount,'status',r.status));
    RETURN to_jsonb(r);
  ELSIF p_action='referral_paid' THEN
    SELECT * INTO r FROM public.referral_register WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
    IF NOT FOUND OR r.status <> 'qualified' OR r.commission_amount <= 0 THEN RAISE EXCEPTION 'Only qualified referrals with earned commission can be marked paid.'; END IF;
    IF coalesce(length(trim(p_payload->>'payout_reference')),0) NOT BETWEEN 2 AND 300 THEN RAISE EXCEPTION 'Enter the payment reference.'; END IF;
    UPDATE public.referral_register SET status='paid',payout_reference=trim(p_payload->>'payout_reference'),paid_at=now(),updated_at=now() WHERE id=r.id RETURNING * INTO r;
    INSERT INTO public.referral_audit_events(agreement_id,referral_id,action,actor_id,detail) VALUES(r.agreement_id,r.id,p_action,auth.uid(),jsonb_build_object('payout_reference',r.payout_reference,'commission',r.commission_amount));
    RETURN to_jsonb(r);
  ELSE RAISE EXCEPTION 'Unsupported action.';
  END IF;
  INSERT INTO public.referral_audit_events(agreement_id,action,actor_id) VALUES(a.id,p_action,auth.uid());
  RETURN to_jsonb(a)-'token_hash';
END;
$$;
REVOKE ALL ON FUNCTION private.manage_referrals(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.manage_referrals(text,jsonb) TO authenticated;
CREATE FUNCTION public.admin_manage_referrals(p_action text,p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.manage_referrals(p_action,p_payload); $$;
REVOKE ALL ON FUNCTION public.admin_manage_referrals(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_manage_referrals(text,jsonb) TO authenticated;

-- Capability access: anonymous partners do not need a USSE account. A 256-bit
-- token is mandatory, stored only as SHA-256. These definer functions live in
-- the unexposed private schema; the public wrappers are SECURITY INVOKER.
CREATE FUNCTION private.referral_by_token(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.referral_agreements;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'This signing link is invalid or unavailable.'; END IF;
  SELECT * INTO a FROM public.referral_agreements WHERE token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
  IF NOT FOUND OR a.status NOT IN ('pending','signed') OR a.expires_at<=now() THEN RAISE EXCEPTION 'This signing link is invalid, expired or cancelled. Contact USSE for a new link.'; END IF;
  RETURN jsonb_build_object('id',a.id,'reference',a.reference,'snapshot',a.snapshot,'status',a.status,'expires_at',a.expires_at,'signed_at',a.signed_at,'signer_name',a.signer_name,'partner_signature',a.partner_signature,'acknowledgements',a.acknowledgements);
END;
$$;
CREATE FUNCTION private.sign_referral(p_token text,p_name text,p_email text,p_signature text,p_acknowledgements jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.referral_agreements; k text;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid signing link.'; END IF;
  SELECT * INTO a FROM public.referral_agreements WHERE token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') FOR UPDATE;
  IF NOT FOUND OR a.status<>'pending' OR a.expires_at<=now() THEN RAISE EXCEPTION 'This agreement is already signed, expired or unavailable.'; END IF;
  IF coalesce(length(trim(p_name)),0) NOT BETWEEN 2 AND 200 OR lower(trim(coalesce(p_email,''))) <> lower(trim(a.snapshot->>'partner_email')) THEN RAISE EXCEPTION 'Enter your full name and the email address on the agreement.'; END IF;
  IF coalesce(p_signature,'') !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$' OR length(p_signature)>400000 THEN RAISE EXCEPTION 'A valid signature image is required.'; END IF;
  IF jsonb_typeof(p_acknowledgements) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Confirm every acknowledgement.'; END IF;
  FOREACH k IN ARRAY ARRAY['commission','independent','conduct','signature'] LOOP
    IF p_acknowledgements->k IS DISTINCT FROM 'true'::jsonb THEN RAISE EXCEPTION 'Confirm every acknowledgement.'; END IF;
  END LOOP;
  UPDATE public.referral_agreements SET status='signed',signed_at=now(),signer_name=trim(p_name),partner_signature=p_signature,acknowledgements=p_acknowledgements,updated_at=now() WHERE id=a.id;
  INSERT INTO public.referral_audit_events(agreement_id,action,detail) VALUES(a.id,'signed',jsonb_build_object('signer_name',trim(p_name),'email',lower(trim(p_email)),'template_version',a.snapshot->>'template_version'));
  RETURN private.referral_by_token(p_token);
END;
$$;
REVOKE ALL ON FUNCTION private.referral_by_token(text),private.sign_referral(text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA private TO anon,authenticated;
GRANT EXECUTE ON FUNCTION private.referral_by_token(text),private.sign_referral(text,text,text,text,jsonb) TO anon,authenticated;
CREATE FUNCTION public.get_referral_agreement(p_token text) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.referral_by_token(p_token); $$;
CREATE FUNCTION public.sign_referral_agreement(p_token text,p_name text,p_email text,p_signature text,p_acknowledgements jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.sign_referral(p_token,p_name,p_email,p_signature,p_acknowledgements); $$;
REVOKE ALL ON FUNCTION public.get_referral_agreement(text),public.sign_referral_agreement(text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_referral_agreement(text),public.sign_referral_agreement(text,text,text,text,jsonb) TO anon,authenticated;
COMMIT;
