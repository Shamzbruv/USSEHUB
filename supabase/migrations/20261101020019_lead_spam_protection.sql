-- Server-side spam controls shared by every public enquiry route.
CREATE TABLE private.lead_spam_blocks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),kind text NOT NULL CHECK(kind IN ('contact','connection')),
 key_hash text NOT NULL,label text NOT NULL,lead_id uuid REFERENCES public.consultations(id) ON DELETE SET NULL,
 created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz,removed_at timestamptz,UNIQUE(kind,key_hash)
);
CREATE TABLE private.lead_submission_guard (
 lead_id uuid PRIMARY KEY REFERENCES public.consultations(id) ON DELETE CASCADE,ip_hash text NOT NULL,
 duplicate_key text NOT NULL,received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_guard_duplicate_idx ON private.lead_submission_guard(duplicate_key,received_at DESC);
CREATE TABLE private.lead_spam_counts (
 bucket timestamptz NOT NULL,reason text NOT NULL,hits bigint NOT NULL DEFAULT 1,PRIMARY KEY(bucket,reason)
);
ALTER TABLE private.lead_spam_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.lead_submission_guard ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.lead_spam_counts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.lead_spam_blocks,private.lead_submission_guard,private.lead_spam_counts FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.lead_contact_keys(p_email text,p_phone text) RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE digits text:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');result text[]:='{}';
BEGIN
 IF length(trim(coalesce(p_email,'')))>0 THEN result:=array_append(result,'email:'||md5(lower(trim(p_email))));END IF;
 IF length(digits)=7 THEN digits:='1876'||digits;ELSIF length(digits)=10 AND left(digits,3) IN ('876','658') THEN digits:='1'||digits;END IF;
 IF length(digits)>=7 THEN result:=array_append(result,'phone:'||md5(digits));END IF;
 RETURN result;
END $$;
CREATE FUNCTION private.count_lead_spam(p_reason text) RETURNS void LANGUAGE sql SET search_path='' AS $$
 INSERT INTO private.lead_spam_counts(bucket,reason) VALUES(date_trunc('hour',clock_timestamp()),p_reason)
 ON CONFLICT(bucket,reason) DO UPDATE SET hits=private.lead_spam_counts.hits+1;
$$;
REVOKE ALL ON FUNCTION private.lead_contact_keys(text,text),private.count_lead_spam(text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.guarded_record_lead(p_data jsonb,p_request_id uuid,p_fingerprint text,p_ip_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 WHERE g.duplicate_key=v_duplicate_key AND g.received_at>ts-interval '15 minutes' AND c.lead_stage<>'spam' ORDER BY g.received_at DESC LIMIT 1;
 IF FOUND THEN PERFORM private.count_lead_spam('duplicate');RETURN jsonb_build_object('created',false,'duplicate',true,'lead_id',prior.id,'reference',prior.lead_reference);END IF;
 receipt:=private.record_lead(p_data,p_request_id,p_fingerprint,p_ip_hash);
 INSERT INTO private.lead_submission_guard(lead_id,ip_hash,duplicate_key) VALUES((receipt->>'lead_id')::uuid,p_ip_hash,v_duplicate_key);
 DELETE FROM private.lead_submission_guard WHERE received_at<ts-interval '90 days';
 DELETE FROM private.lead_spam_counts WHERE bucket<ts-interval '30 days';
 RETURN receipt;
END $$;
REVOKE ALL ON FUNCTION private.guarded_record_lead(jsonb,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.guarded_record_lead(jsonb,uuid,text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.capture_usse_lead(p_data jsonb,p_request_id uuid,p_fingerprint text,p_ip_hash text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.guarded_record_lead(p_data,p_request_id,p_fingerprint,p_ip_hash)$$;
REVOKE ALL ON FUNCTION public.capture_usse_lead(jsonb,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.capture_usse_lead(jsonb,uuid,text,text) TO service_role;

-- Marking a lead as spam stops outstanding alerts. Already accepted mail remains recorded.
ALTER TABLE private.lead_alert_deliveries DROP CONSTRAINT lead_alert_deliveries_status_check;
ALTER TABLE private.lead_alert_deliveries ADD CONSTRAINT lead_alert_deliveries_status_check CHECK(status IN ('pending','processing','accepted','failed','cancelled'));
CREATE FUNCTION private.suppress_spam_lead_alerts() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.lead_stage='spam' AND OLD.lead_stage IS DISTINCT FROM 'spam' THEN
  UPDATE private.lead_alert_deliveries SET status='cancelled',locked_at=NULL,claim_token=NULL,last_error='Cancelled because this enquiry was marked as spam.' WHERE lead_id=NEW.id AND status<>'accepted';
 END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.suppress_spam_lead_alerts() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER suppress_spam_lead_alerts AFTER UPDATE OF lead_stage ON public.consultations FOR EACH ROW EXECUTE FUNCTION private.suppress_spam_lead_alerts();
CREATE FUNCTION private.prevent_spam_lead_alerts() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.status IN ('pending','processing','failed') AND EXISTS(SELECT 1 FROM public.consultations WHERE id=NEW.lead_id AND lead_stage='spam') THEN
  NEW.status:='cancelled';NEW.locked_at:=NULL;NEW.claim_token:=NULL;NEW.last_error:='Cancelled because this enquiry was marked as spam.';
 END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.prevent_spam_lead_alerts() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER prevent_spam_lead_alerts BEFORE INSERT OR UPDATE OF status ON private.lead_alert_deliveries FOR EACH ROW EXECUTE FUNCTION private.prevent_spam_lead_alerts();

CREATE FUNCTION private.manage_lead_spam(p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.consultations;k text;keys text[];ip text;off integer:=greatest(0,coalesce((p_payload->>'offset')::integer,0));result jsonb;
BEGIN
 PERFORM private.require_admin(auth.uid());
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='admin' AND account_status='active') THEN RAISE EXCEPTION 'Active administrator access required.' USING ERRCODE='42501';END IF;
 IF p_action='list' THEN
  SELECT jsonb_build_object('total',(SELECT count(*) FROM private.lead_spam_blocks WHERE removed_at IS NULL AND (expires_at IS NULL OR expires_at>now())),
   'rows',(SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT id,kind,label,created_at,expires_at FROM private.lead_spam_blocks WHERE removed_at IS NULL AND (expires_at IS NULL OR expires_at>now()) ORDER BY created_at DESC,id LIMIT 25 OFFSET off)x),
   'blocked_24h',(SELECT coalesce(sum(hits),0) FROM private.lead_spam_counts WHERE bucket>=now()-interval '24 hours' AND reason<>'duplicate'),
   'duplicates_24h',(SELECT coalesce(sum(hits),0) FROM private.lead_spam_counts WHERE bucket>=now()-interval '24 hours' AND reason='duplicate')) INTO result;RETURN result;
 ELSIF p_action='unblock' THEN
  UPDATE private.lead_spam_blocks SET removed_at=now() WHERE id=(p_payload->>'block_id')::uuid;
  INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(auth.uid(),'lead_spam_block',p_payload->>'block_id','lead_spam_block_removed');
  RETURN jsonb_build_object('ok',true);
 END IF;
 SELECT * INTO l FROM public.consultations WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found.';END IF;
 SELECT ip_hash INTO ip FROM private.lead_submission_guard WHERE lead_id=l.id;
 IF p_action='detail' THEN
  keys:=private.lead_contact_keys(l.email,l.phone);
  RETURN jsonb_build_object('can_block_contact',cardinality(keys)>0,'can_block_connection',ip IS NOT NULL,
   'contact_blocked',cardinality(keys)>0 AND NOT EXISTS(SELECT 1 FROM unnest(keys) AS identifiers(candidate_key) WHERE NOT EXISTS(SELECT 1 FROM private.lead_spam_blocks WHERE kind='contact' AND key_hash=identifiers.candidate_key AND removed_at IS NULL AND (expires_at IS NULL OR expires_at>now()))),
   'connection_blocked',EXISTS(SELECT 1 FROM private.lead_spam_blocks WHERE kind='connection' AND key_hash=ip AND removed_at IS NULL AND expires_at>now()));
 ELSIF p_action='block_contact' THEN
  keys:=private.lead_contact_keys(l.email,l.phone);IF cardinality(keys)=0 THEN RAISE EXCEPTION 'This lead has no contact details to block.';END IF;
  FOREACH k IN ARRAY keys LOOP
   INSERT INTO private.lead_spam_blocks(kind,key_hash,label,lead_id,created_by) VALUES('contact',k,l.customer_name||' · '||CASE WHEN k LIKE 'email:%' THEN l.email ELSE l.phone END,l.id,auth.uid())
   ON CONFLICT(kind,key_hash) DO UPDATE SET label=excluded.label,lead_id=excluded.lead_id,created_by=auth.uid(),created_at=now(),removed_at=NULL,expires_at=NULL;
  END LOOP;
 ELSIF p_action='block_connection' THEN
  IF ip IS NULL THEN RAISE EXCEPTION 'Connection information is only available for recent website enquiries.';END IF;
  INSERT INTO private.lead_spam_blocks(kind,key_hash,label,lead_id,created_by,expires_at) VALUES('connection',ip,'Connection used for '||l.lead_reference,l.id,auth.uid(),now()+interval '24 hours')
  ON CONFLICT(kind,key_hash) DO UPDATE SET label=excluded.label,lead_id=excluded.lead_id,created_by=auth.uid(),created_at=now(),removed_at=NULL,expires_at=excluded.expires_at;
 ELSE RAISE EXCEPTION 'Unknown spam-protection action.';END IF;
 UPDATE public.consultations SET lead_stage='spam',status='cancelled' WHERE id=l.id;
 INSERT INTO private.lead_activity(lead_id,actor_id,kind,detail) VALUES(l.id,auth.uid(),'spam_block',CASE WHEN p_action='block_contact' THEN 'Blocked future enquiries from this email address and phone number. Manage blocks in Spam protection.' ELSE 'Blocked this connection for 24 hours. Manage blocks in Spam protection.' END);
 INSERT INTO public.admin_audit_log(actor_user_id,entity_type,entity_id,action) VALUES(auth.uid(),'lead_spam_block',l.id::text,p_action);
 RETURN jsonb_build_object('ok',true);
END $$;
CREATE FUNCTION public.admin_manage_lead_spam(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.manage_lead_spam(p_action,p_payload)$$;
REVOKE ALL ON FUNCTION private.manage_lead_spam(text,jsonb),public.admin_manage_lead_spam(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.manage_lead_spam(text,jsonb),public.admin_manage_lead_spam(text,jsonb) TO authenticated;
