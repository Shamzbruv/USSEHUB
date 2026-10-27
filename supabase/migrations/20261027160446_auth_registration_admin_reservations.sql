-- Verified email reservations are provisioned by an operator, never by the browser.
CREATE TABLE IF NOT EXISTS private.admin_email_grants (
  email text PRIMARY KEY CHECK (email = lower(btrim(email)) AND position('@' in email) > 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  claimed_user_id uuid,
  claimed_at timestamptz
);
ALTER TABLE private.admin_email_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.admin_email_grants FROM PUBLIC, anon, authenticated;

-- Trigger guards run as the caller. A guarded SECURITY DEFINER lifecycle RPC
-- remains trusted; direct member updates cannot approve or promote themselves.
CREATE OR REPLACE FUNCTION public.protect_profile_sensitive_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF current_user IN ('postgres','supabase_admin','supabase_auth_admin','service_role') OR private.is_admin(auth.uid()) THEN RETURN NEW; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.email IS DISTINCT FROM OLD.email
     OR NEW.role IS DISTINCT FROM OLD.role
     OR NEW.subscription_status IS DISTINCT FROM OLD.subscription_status
     OR NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    RAISE EXCEPTION 'Account identity and access fields can only be changed by an authorized administrator.' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION public.protect_profile_privileged_columns()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF current_user IN ('postgres','supabase_admin','supabase_auth_admin','service_role') OR private.is_admin(auth.uid()) THEN RETURN NEW; END IF;
  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    RAISE EXCEPTION 'Administrator access is required to change account permissions.' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION public.protect_listing_privileged_columns()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF current_user IN ('postgres','supabase_admin','supabase_auth_admin','service_role') OR private.is_admin(auth.uid()) THEN RETURN NEW; END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (OLD.status IN ('draft','changes_requested') AND NEW.status='pending') THEN
    RAISE EXCEPTION 'Use the authorized listing lifecycle action to change this status.' USING ERRCODE='42501';
  END IF;
  IF NEW.is_featured IS DISTINCT FROM OLD.is_featured OR NEW.admin_note IS DISTINCT FROM OLD.admin_note
     OR NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at OR NEW.published_at IS DISTINCT FROM OLD.published_at THEN
    RAISE EXCEPTION 'Listing access and approval fields can only be changed through an authorized lifecycle action.' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$$;

-- Old permissive policies were ORed with the strict policy and allowed an
-- owner to insert an arbitrary role when a profile was missing.
DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users insert own profile" ON public.profiles;
CREATE POLICY "Users insert own profile" ON public.profiles FOR INSERT TO authenticated WITH CHECK (
  id = (SELECT auth.uid()) AND lower(email) = lower((SELECT auth.jwt()->>'email'))
  AND role = 'member' AND coalesce(subscription_status,'inactive')='inactive'
  AND coalesce(account_status,'active')='active'
);
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
DROP POLICY IF EXISTS "Profiles updatable by owner or admin" ON public.profiles;
CREATE POLICY "Profiles updatable by owner or admin" ON public.profiles FOR UPDATE TO authenticated
USING (id=(SELECT auth.uid()) OR private.is_admin((SELECT auth.uid())))
WITH CHECK (id=(SELECT auth.uid()) OR private.is_admin((SELECT auth.uid())));

-- This private invoker helper is callable only by trusted database routines
-- and operators. It checks Auth's verified email, never editable profile data.
CREATE OR REPLACE FUNCTION private.apply_reserved_admin(p_uid uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_email text; v_previous_role text; v_claim uuid;
BEGIN
  SELECT lower(btrim(email)) INTO v_email FROM auth.users
    WHERE id=p_uid AND email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN RETURN false; END IF;
  SELECT role INTO v_previous_role FROM public.profiles WHERE id=p_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  UPDATE private.admin_email_grants SET claimed_user_id=p_uid, claimed_at=coalesce(claimed_at,now())
    WHERE email=v_email AND (claimed_user_id IS NULL OR claimed_user_id=p_uid)
    RETURNING claimed_user_id INTO v_claim;
  IF NOT FOUND THEN RETURN false; END IF;
  UPDATE public.profiles SET role='admin',account_status='active',email=v_email WHERE id=p_uid;
  IF v_previous_role IS DISTINCT FROM 'admin' THEN
    INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action,before_state,after_state)
      VALUES (p_uid,'profile',p_uid::text,'reserved_admin_activated',jsonb_build_object('role',v_previous_role),jsonb_build_object('role','admin'));
  END IF;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION private.apply_reserved_admin(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.profiles(id,email,full_name,role,subscription_status)
    VALUES (NEW.id,NEW.email,left(coalesce(NEW.raw_user_meta_data->>'full_name',''),120),'member','inactive')
    ON CONFLICT(id) DO NOTHING;
  PERFORM private.apply_reserved_admin(NEW.id);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.after_auth_email_verified()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  -- Only the Auth service can update auth.users. The function is not an API.
  IF NEW.email_confirmed_at IS NOT NULL THEN
    UPDATE public.profiles SET email=NEW.email WHERE id=NEW.id AND email IS DISTINCT FROM NEW.email;
    PERFORM private.apply_reserved_admin(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.after_auth_email_verified() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS on_auth_email_verified_admin_grant ON auth.users;
CREATE TRIGGER on_auth_email_verified_admin_grant AFTER UPDATE OF email,email_confirmed_at ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.after_auth_email_verified();

-- Restore missing member profiles with server-controlled access defaults.
INSERT INTO public.profiles(id,email,full_name,role,subscription_status)
SELECT id,email,left(coalesce(raw_user_meta_data->>'full_name',''),120),'member','inactive' FROM auth.users
ON CONFLICT(id) DO NOTHING;

-- Safe search paths and no client EXECUTE grants on internal trigger functions.
ALTER FUNCTION public.update_updated_at() SET search_path='';
ALTER FUNCTION public.update_search_document() SET search_path='';
REVOKE ALL ON FUNCTION public.protect_profile_sensitive_fields() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.protect_profile_privileged_columns() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.protect_listing_privileged_columns() FROM PUBLIC,anon,authenticated;
