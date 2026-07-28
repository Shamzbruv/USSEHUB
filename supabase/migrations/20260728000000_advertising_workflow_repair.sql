-- AJM advertising workflow repair.
--
-- This migration completes the database contract used by the advertising
-- management UI, removes legacy direct-write paths, adds public delivery and
-- privacy-preserving event RPCs, and installs best-effort maintenance for
-- campaign expiry and the Resend notification outbox.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE UNIQUE INDEX IF NOT EXISTS ad_events_daily_session_dedupe_idx
ON public.ad_events (advertisement_id, event_type, session_hash, occurred_on)
WHERE session_hash IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Shared redaction and notification helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.ad_order_audit_state(
  p_order public.ad_orders
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_order IS NULL THEN NULL
    ELSE (
      jsonb_set(
        to_jsonb(p_order),
        '{payment_account_snapshot}',
        private.redact_payment_account(p_order.payment_account_snapshot),
        true
      )
      - 'payment_proof_path'
    )
  END;
$$;

CREATE OR REPLACE FUNCTION private.reconcile_ad_notification_outbox()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sent integer := 0;
  v_failed integer := 0;
BEGIN
  WITH changed AS (
    UPDATE public.notification_outbox o
    SET
      status = CASE
        WHEN r.status_code BETWEEN 200 AND 299 AND NOT coalesce(r.timed_out, false)
          THEN 'sent'
        ELSE 'failed'
      END,
      last_error = CASE
        WHEN r.status_code BETWEEN 200 AND 299 AND NOT coalesce(r.timed_out, false)
          THEN NULL
        ELSE left(
          coalesce(
            nullif(r.error_msg, ''),
            nullif(r.content, ''),
            format('Resend returned HTTP %s.', coalesce(r.status_code::text, 'unknown'))
          ),
          1000
        )
      END
    FROM net._http_response r
    WHERE o.status = 'queued'
      AND o.net_request_id = r.id
    RETURNING o.status
  )
  SELECT
    count(*) FILTER (WHERE status = 'sent')::integer,
    count(*) FILTER (WHERE status = 'failed')::integer
  INTO v_sent, v_failed
  FROM changed;

  RETURN jsonb_build_object(
    'sent', coalesce(v_sent, 0),
    'failed', coalesce(v_failed, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.process_ad_notification_outbox(
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_api_key text;
  v_from text;
  v_row public.notification_outbox%ROWTYPE;
  v_request_id bigint;
  v_queued integer := 0;
  v_failed integer := 0;
  v_reconciled jsonb;
BEGIN
  v_reconciled := private.reconcile_ad_notification_outbox();

  SELECT decrypted_secret INTO v_api_key
  FROM vault.decrypted_secrets
  WHERE name IN ('RESEND_API_KEY', 'resend_api_key')
  ORDER BY CASE name WHEN 'RESEND_API_KEY' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret INTO v_from
  FROM vault.decrypted_secrets
  WHERE name IN ('RESEND_FROM_EMAIL', 'resend_from_email')
  ORDER BY CASE name WHEN 'RESEND_FROM_EMAIL' THEN 0 ELSE 1 END
  LIMIT 1;

  -- Missing Vault configuration must not roll back the business transaction
  -- which queued the notification. Leave rows pending for a later retry.
  IF nullif(v_api_key, '') IS NULL OR nullif(v_from, '') IS NULL THEN
    RETURN jsonb_build_object(
      'queued', 0,
      'failed', 0,
      'configured', false,
      'reconciled', v_reconciled
    );
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.notification_outbox
    WHERE status IN ('pending', 'failed')
      AND attempts < 5
    ORDER BY queued_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT greatest(1, least(coalesce(p_limit, 25), 100))
  LOOP
    BEGIN
      SELECT net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_api_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
          'from', v_from,
          'to', jsonb_build_array(v_row.recipient_email),
          'subject', v_row.subject,
          'text', v_row.text_body
        ),
        timeout_milliseconds := 10000
      ) INTO v_request_id;

      UPDATE public.notification_outbox
      SET
        status = 'queued',
        attempts = attempts + 1,
        net_request_id = v_request_id,
        dispatched_at = now(),
        last_error = NULL
      WHERE id = v_row.id;

      v_queued := v_queued + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.notification_outbox
      SET
        status = 'failed',
        attempts = attempts + 1,
        last_error = left(SQLERRM, 1000)
      WHERE id = v_row.id;

      v_failed := v_failed + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'queued', v_queued,
    'failed', v_failed,
    'configured', true,
    'reconciled', v_reconciled
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.trigger_ad_notification_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  BEGIN
    PERFORM private.process_ad_notification_outbox(25);
  EXCEPTION WHEN OTHERS THEN
    -- Email delivery is deliberately best effort. The inserted outbox row is
    -- retained as pending and the scheduled maintenance task can retry it.
    NULL;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_dispatch_ad_notification ON public.notification_outbox;
CREATE TRIGGER trg_auto_dispatch_ad_notification
AFTER INSERT ON public.notification_outbox
FOR EACH STATEMENT EXECUTE FUNCTION private.trigger_ad_notification_dispatch();

CREATE OR REPLACE FUNCTION private.queue_manual_webpage_notification(
  p_user_id uuid,
  p_listing_id uuid,
  p_package_id uuid,
  p_event text,
  p_expires_at timestamptz DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email text;
  v_business_name text;
  v_package_name text;
  v_subject text;
  v_body text;
BEGIN
  SELECT email INTO v_email
  FROM public.profiles
  WHERE id = p_user_id;

  SELECT business_name INTO v_business_name
  FROM public.listings
  WHERE id = p_listing_id;

  SELECT name INTO v_package_name
  FROM public.ad_packages
  WHERE id = p_package_id;

  IF nullif(v_email, '') IS NULL THEN
    RETURN;
  END IF;

  v_subject := CASE p_event
    WHEN 'activated' THEN 'Your AJM business webpage is active'
    WHEN 'renewed' THEN 'Your AJM business webpage was renewed'
    WHEN 'cancelled' THEN 'Your AJM business webpage package was cancelled'
    ELSE 'Your AJM business webpage was updated'
  END;

  v_body := format(
    'The %s package for %s was %s by AJM.%s%s',
    coalesce(v_package_name, 'business webpage'),
    coalesce(v_business_name, 'your listing'),
    p_event,
    CASE
      WHEN p_expires_at IS NOT NULL
        THEN E'\n\nAccess is scheduled through ' || to_char(p_expires_at, 'FMMonth DD, YYYY') || '.'
      ELSE ''
    END,
    CASE
      WHEN nullif(p_reason, '') IS NOT NULL THEN E'\n\nReason: ' || p_reason
      ELSE ''
    END
  );

  INSERT INTO public.notification_outbox (
    order_id,
    recipient_email,
    subject,
    text_body,
    template_key
  ) VALUES (
    NULL,
    lower(v_email),
    v_subject,
    v_body,
    'ajm_webpage_' || p_event
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatch_ad_notification_outbox(
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.request_is_service_role() THEN
    PERFORM private.require_admin(auth.uid());
  END IF;

  RETURN private.process_ad_notification_outbox(p_limit);
END;
$$;

-- ---------------------------------------------------------------------------
-- Automatic campaign and subscription expiry
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.expire_advertising_state(
  p_now timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_before public.ad_orders%ROWTYPE;
  v_after public.ad_orders%ROWTYPE;
  v_count integer := 0;
BEGIN
  FOR v_before IN
    SELECT *
    FROM public.ad_orders
    WHERE status IN ('approved', 'paused')
      AND expires_at IS NOT NULL
      AND expires_at <= p_now
    ORDER BY expires_at, id
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.ad_orders
    SET
      status = 'expired',
      admin_note = coalesce(admin_note, 'Automatically expired at the configured end date.')
    WHERE id = v_before.id
    RETURNING * INTO v_after;

    UPDATE public.advertisements
    SET status = 'expired'
    WHERE order_id = v_after.id
      AND status IN ('active', 'paused');

    UPDATE public.ad_subscriptions
    SET status = 'expired'
    WHERE ad_order_id = v_after.id
      AND status IN ('active', 'paused');

    PERFORM private.audit_advertising_change(
      NULL,
      'ad_order',
      v_after.id::text,
      'system_expire_advertising',
      private.ad_order_audit_state(v_before),
      private.ad_order_audit_state(v_after)
    );
    PERFORM private.queue_order_notifications(v_after.id, 'expired');
    v_count := v_count + 1;
  END LOOP;

  -- Also reconcile any orphaned delivery rows whose order already reached a
  -- terminal state, while preserving their order history.
  UPDATE public.advertisements a
  SET status = CASE
    WHEN o.status = 'cancelled' THEN 'cancelled'
    ELSE 'expired'
  END
  FROM public.ad_orders o
  WHERE a.order_id = o.id
    AND a.status IN ('active', 'paused')
    AND (
      o.status IN ('cancelled', 'expired')
      OR a.expires_at <= p_now
    );

  UPDATE public.ad_subscriptions s
  SET status = CASE
    WHEN o.status = 'cancelled' THEN 'cancelled'
    ELSE 'expired'
  END
  FROM public.ad_orders o
  WHERE s.ad_order_id = o.id
    AND s.status IN ('active', 'paused')
    AND (
      o.status IN ('cancelled', 'expired')
      OR s.expires_at <= p_now
    );

  RETURN jsonb_build_object('expired_orders', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION private.run_advertising_maintenance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expiry jsonb;
  v_notifications jsonb;
BEGIN
  v_expiry := private.expire_advertising_state(clock_timestamp());
  v_notifications := private.process_ad_notification_outbox(50);
  RETURN jsonb_build_object(
    'expiry', v_expiry,
    'notifications', v_notifications,
    'ran_at', clock_timestamp()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Secure administrator reads
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_get_ad_configuration()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM private.require_admin(auth.uid());

  SELECT jsonb_build_object(
    'packages', coalesce(
      (
        SELECT jsonb_agg(
          to_jsonb(p) || jsonb_build_object(
            'options', coalesce(
              (
                SELECT jsonb_agg(to_jsonb(o) ORDER BY o.sort_order, o.name)
                FROM public.ad_package_options o
                WHERE o.package_id = p.id
              ),
              '[]'::jsonb
            )
          )
          ORDER BY p.sort_order, p.name
        )
        FROM public.ad_packages p
      ),
      '[]'::jsonb
    ),
    'payment_accounts', coalesce(
      (
        SELECT jsonb_agg(to_jsonb(pa) ORDER BY pa.is_default DESC, pa.sort_order, pa.label)
        FROM public.payment_accounts pa
      ),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_ad_orders(
  p_status text DEFAULT NULL,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 250,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := greatest(1, least(coalesce(p_limit, 250), 500));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_result jsonb;
BEGIN
  PERFORM private.require_admin(auth.uid());

  IF p_status IS NOT NULL AND p_status NOT IN (
    'pending_payment', 'payment_submitted', 'approved', 'paused',
    'rejected', 'cancelled', 'expired'
  ) THEN
    RAISE EXCEPTION 'Invalid advertising order status.';
  END IF;
  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_to < p_from THEN
    RAISE EXCEPTION 'The reporting end date cannot precede the start date.';
  END IF;

  WITH filtered AS (
    SELECT o.*
    FROM public.ad_orders o
    WHERE (p_status IS NULL OR o.status = p_status)
      AND (p_from IS NULL OR o.created_at >= p_from)
      AND (p_to IS NULL OR o.created_at < p_to)
  ),
  page AS (
    SELECT f.*
    FROM filtered f
    ORDER BY f.created_at DESC, f.id
    LIMIT v_limit OFFSET v_offset
  )
  SELECT jsonb_build_object(
    'orders', coalesce(
      jsonb_agg(
        to_jsonb(page)
        || jsonb_build_object(
          'customer', jsonb_build_object(
            'id', pr.id,
            'full_name', pr.full_name,
            'email', pr.email
          ),
          'profiles', jsonb_build_object(
            'id', pr.id,
            'full_name', pr.full_name,
            'email', pr.email
          ),
          'business_name', l.business_name,
          'listing_name', l.business_name,
          'package', jsonb_build_object(
            'id', p.id,
            'code', page.package_code_snapshot,
            'name', page.package_name_snapshot,
            'currency', page.currency_snapshot,
            'product_type', page.product_type_snapshot
          ),
          'amount_due', page.total_price_snapshot,
          'duration_days', page.duration_days_snapshot,
          'currency', page.currency_snapshot
        )
        ORDER BY page.created_at DESC, page.id
      ),
      '[]'::jsonb
    ),
    'total_count', (SELECT count(*) FROM filtered),
    'limit', v_limit,
    'offset', v_offset
  ) INTO v_result
  FROM page
  LEFT JOIN public.profiles pr ON pr.id = page.user_id
  LEFT JOIN public.listings l ON l.id = page.listing_id
  LEFT JOIN public.ad_packages p ON p.id = page.package_id;

  RETURN coalesce(
    v_result,
    jsonb_build_object(
      'orders', '[]'::jsonb,
      'total_count', 0,
      'limit', v_limit,
      'offset', v_offset
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Administrator configuration and order lifecycle commands
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_manage_advertising(
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_action text := lower(trim(coalesce(p_action, '')));
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_order_id uuid;
  v_before public.ad_orders%ROWTYPE;
  v_after public.ad_orders%ROWTYPE;
  v_reason text;
  v_admin_note text;
  v_duration integer;
  v_starts timestamptz;
  v_expires timestamptz;
  v_related jsonb;
BEGIN
  PERFORM private.require_admin(v_uid);
  IF jsonb_typeof(v_payload) <> 'object' THEN
    RAISE EXCEPTION 'Payload must be a JSON object.';
  END IF;

  -- Configuration commands delegate to the canonical, audited CRUD RPCs.
  IF v_action IN (
    'package_upsert', 'package_archive', 'package_restore', 'package_delete',
    'option_upsert', 'option_archive', 'option_restore', 'option_delete',
    'bank_upsert', 'bank_archive', 'bank_restore', 'bank_delete', 'bank_set_default'
  ) THEN
    IF v_action LIKE 'bank_%' THEN
      IF v_payload ? 'branch' AND NOT (v_payload ? 'branch_name') THEN
        v_payload := jsonb_set(v_payload, '{branch_name}', v_payload->'branch', true);
      END IF;
      IF v_action = 'bank_upsert'
         AND nullif(v_payload->>'id', '') IS NULL
         AND nullif(v_payload->>'code', '') IS NULL THEN
        v_payload := jsonb_set(
          v_payload,
          '{code}',
          to_jsonb(
            lower(
              trim(both '-' FROM regexp_replace(
                coalesce(nullif(v_payload->>'label', ''), 'bank-account'),
                '[^a-zA-Z0-9]+',
                '-',
                'g'
              ))
            ) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
          ),
          true
        );
      END IF;
    END IF;

    CASE
      WHEN v_action = 'package_upsert' THEN
        RETURN public.admin_manage_ad_package('upsert', v_payload);
      WHEN v_action = 'package_archive' THEN
        RETURN public.admin_manage_ad_package('archive', v_payload);
      WHEN v_action = 'package_restore' THEN
        RETURN public.admin_manage_ad_package('restore', v_payload);
      WHEN v_action = 'package_delete' THEN
        RETURN public.admin_manage_ad_package('delete', v_payload);
      WHEN v_action = 'option_upsert' THEN
        RETURN public.admin_manage_ad_package_option('upsert', v_payload);
      WHEN v_action = 'option_archive' THEN
        RETURN public.admin_manage_ad_package_option('archive', v_payload);
      WHEN v_action = 'option_restore' THEN
        RETURN public.admin_manage_ad_package_option('restore', v_payload);
      WHEN v_action = 'option_delete' THEN
        RETURN public.admin_manage_ad_package_option('delete', v_payload);
      WHEN v_action = 'bank_upsert' THEN
        RETURN public.admin_manage_payment_account('upsert', v_payload);
      WHEN v_action = 'bank_archive' THEN
        RETURN public.admin_manage_payment_account('archive', v_payload);
      WHEN v_action = 'bank_restore' THEN
        RETURN public.admin_manage_payment_account('restore', v_payload);
      WHEN v_action = 'bank_delete' THEN
        RETURN public.admin_manage_payment_account('delete', v_payload);
      WHEN v_action = 'bank_set_default' THEN
        RETURN public.admin_manage_payment_account('set_default', v_payload);
    END CASE;
  END IF;

  IF v_action NOT IN (
    'confirm_payment', 'reject_payment', 'cancel_subscription',
    'renew_subscription', 'pause_ad', 'resume_ad', 'expire_ad'
  ) THEN
    RAISE EXCEPTION 'Unsupported advertising action: %.', v_action;
  END IF;

  IF nullif(v_payload->>'order_id', '') IS NULL THEN
    RAISE EXCEPTION 'Advertising order id is required.';
  END IF;
  v_order_id := (v_payload->>'order_id')::uuid;
  v_reason := nullif(left(trim(coalesce(v_payload->>'reason', '')), 2000), '');
  v_admin_note := nullif(left(trim(coalesce(v_payload->>'admin_note', '')), 4000), '');

  SELECT * INTO v_before
  FROM public.ad_orders
  WHERE id = v_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Advertising order not found.';
  END IF;

  IF v_action = 'confirm_payment' THEN
    IF v_before.status <> 'payment_submitted' THEN
      RAISE EXCEPTION 'Only a submitted bank transfer can be confirmed.';
    END IF;
    IF v_before.product_type_snapshot = 'display_ad' THEN
      IF char_length(trim(coalesce(v_before.creative_snapshot->>'headline', ''))) NOT BETWEEN 3 AND 240 THEN
        RAISE EXCEPTION 'Display advertisements require a headline between 3 and 240 characters.';
      END IF;
      IF char_length(trim(coalesce(
        v_before.creative_snapshot->>'body_text',
        v_before.creative_snapshot->>'body',
        ''
      ))) NOT BETWEEN 10 AND 4000 THEN
        RAISE EXCEPTION 'Display advertisements require body copy between 10 and 4000 characters.';
      END IF;
      IF char_length(trim(coalesce(v_before.creative_snapshot->>'cta_label', ''))) NOT BETWEEN 1 AND 80 THEN
        RAISE EXCEPTION 'Display advertisements require a call-to-action label.';
      END IF;
      IF char_length(trim(coalesce(v_before.creative_snapshot->>'cta_url', ''))) NOT BETWEEN 10 AND 2048
         OR trim(v_before.creative_snapshot->>'cta_url') !~* '^https?://[^[:space:]]+$' THEN
        RAISE EXCEPTION 'Display advertisements require a valid HTTP or HTTPS call-to-action URL.';
      END IF;
      -- A creative file remains optional so fully text-based advertisements
      -- can be approved without uploading an image or video.
    END IF;
    v_starts := clock_timestamp();
    v_duration := greatest(1, least(v_before.duration_days_snapshot, 3650));
    v_expires := v_starts + make_interval(days => v_duration);

    UPDATE public.ad_orders
    SET
      status = 'approved',
      approved_at = v_starts,
      approved_by = v_uid,
      starts_at = v_starts,
      expires_at = v_expires,
      rejection_reason = NULL,
      cancelled_at = NULL,
      admin_note = coalesce(v_admin_note, admin_note)
    WHERE id = v_order_id
    RETURNING * INTO v_after;

    IF v_after.product_type_snapshot = 'display_ad' THEN
      IF coalesce(array_length(v_after.placements_snapshot, 1), 0) = 0 THEN
        RAISE EXCEPTION 'The order has no advertising placement configured.';
      END IF;

      INSERT INTO public.advertisements (
        order_id, user_id, listing_id, package_id, placement, status,
        headline, body_text, cta_label, cta_url, creative_path,
        creative_metadata, starts_at, expires_at
      )
      SELECT
        v_after.id,
        v_after.user_id,
        v_after.listing_id,
        v_after.package_id,
        left(placement, 100),
        'active',
        left(nullif(trim(v_after.creative_snapshot->>'headline'), ''), 240),
        left(nullif(trim(coalesce(
          v_after.creative_snapshot->>'body_text',
          v_after.creative_snapshot->>'body'
        )), ''), 4000),
        left(nullif(trim(v_after.creative_snapshot->>'cta_label'), ''), 80),
        left(nullif(trim(v_after.creative_snapshot->>'cta_url'), ''), 2048),
        v_after.creative_path,
        CASE
          WHEN jsonb_typeof(v_after.creative_snapshot->'metadata') = 'object'
            THEN v_after.creative_snapshot->'metadata'
          ELSE '{}'::jsonb
        END,
        v_starts,
        v_expires
      FROM (
        SELECT DISTINCT nullif(trim(value), '') AS placement
        FROM unnest(v_after.placements_snapshot) value
      ) placements
      WHERE placement IS NOT NULL
      ON CONFLICT (order_id, placement) DO UPDATE SET
        status = 'active',
        headline = EXCLUDED.headline,
        body_text = EXCLUDED.body_text,
        cta_label = EXCLUDED.cta_label,
        cta_url = EXCLUDED.cta_url,
        creative_path = EXCLUDED.creative_path,
        creative_metadata = EXCLUDED.creative_metadata,
        starts_at = EXCLUDED.starts_at,
        expires_at = EXCLUDED.expires_at;
    ELSIF v_after.product_type_snapshot = 'webpage' THEN
      IF v_after.listing_id IS NULL THEN
        RAISE EXCEPTION 'A webpage order must be linked to a business listing.';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.listings l
        WHERE l.id = v_after.listing_id
          AND l.owner_user_id = v_after.user_id
      ) THEN
        RAISE EXCEPTION 'The linked listing does not belong to the advertising customer.';
      END IF;

      UPDATE public.ad_subscriptions
      SET status = 'cancelled'
      WHERE listing_id = v_after.listing_id
        AND status IN ('active', 'paused')
        AND ad_order_id IS DISTINCT FROM v_after.id;

      INSERT INTO public.ad_subscriptions (
        user_id, listing_id, package_id, status, payment_method,
        payment_reference, expires_at, ad_order_id
      ) VALUES (
        v_after.user_id,
        v_after.listing_id,
        v_after.package_id,
        'active',
        'bank_transfer',
        v_after.payment_reference,
        v_expires,
        v_after.id
      )
      ON CONFLICT (ad_order_id) WHERE ad_order_id IS NOT NULL
      DO UPDATE SET
        status = 'active',
        payment_method = EXCLUDED.payment_method,
        payment_reference = EXCLUDED.payment_reference,
        expires_at = EXCLUDED.expires_at;

      UPDATE public.listings l
      SET requested_tier = p.webpage_tier
      FROM public.ad_packages p
      WHERE l.id = v_after.listing_id
        AND p.id = v_after.package_id
        AND p.webpage_enabled = true;
    END IF;

    PERFORM private.queue_order_notifications(v_after.id, 'approved');

  ELSIF v_action = 'reject_payment' THEN
    IF v_before.status NOT IN ('pending_payment', 'payment_submitted') THEN
      RAISE EXCEPTION 'This order can no longer be rejected.';
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'A payment rejection reason is required.';
    END IF;
    UPDATE public.ad_orders
    SET
      status = 'rejected',
      rejection_reason = v_reason,
      admin_note = coalesce(v_admin_note, admin_note)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    PERFORM private.queue_order_notifications(v_after.id, 'rejected');

  ELSIF v_action = 'cancel_subscription' THEN
    IF v_before.status IN ('rejected', 'cancelled', 'expired') THEN
      RAISE EXCEPTION 'This order is already in a terminal state.';
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'A cancellation reason is required.';
    END IF;
    UPDATE public.ad_orders
    SET
      status = 'cancelled',
      cancelled_at = clock_timestamp(),
      admin_note = coalesce(v_admin_note, v_reason)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    UPDATE public.advertisements
    SET status = 'cancelled'
    WHERE order_id = v_order_id AND status IN ('active', 'paused');
    UPDATE public.ad_subscriptions
    SET status = 'cancelled'
    WHERE ad_order_id = v_order_id AND status IN ('active', 'paused');
    PERFORM private.queue_order_notifications(v_after.id, 'cancelled');

  ELSIF v_action = 'pause_ad' THEN
    IF v_before.status <> 'approved' THEN
      RAISE EXCEPTION 'Only an active advertising order can be paused.';
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'A pause reason is required.';
    END IF;
    UPDATE public.ad_orders
    SET status = 'paused', admin_note = coalesce(v_admin_note, v_reason)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    UPDATE public.advertisements SET status = 'paused'
    WHERE order_id = v_order_id AND status = 'active';
    UPDATE public.ad_subscriptions SET status = 'paused'
    WHERE ad_order_id = v_order_id AND status = 'active';
    PERFORM private.queue_order_notifications(v_after.id, 'paused');

  ELSIF v_action = 'resume_ad' THEN
    IF v_before.status <> 'paused' THEN
      RAISE EXCEPTION 'Only a paused advertising order can be resumed.';
    END IF;
    IF v_before.expires_at IS NOT NULL AND v_before.expires_at <= now() THEN
      RAISE EXCEPTION 'This advertising order has expired. Renew it before resuming.';
    END IF;
    UPDATE public.ad_orders
    SET status = 'approved', admin_note = coalesce(v_admin_note, admin_note)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    UPDATE public.advertisements SET status = 'active'
    WHERE order_id = v_order_id AND status = 'paused';
    UPDATE public.ad_subscriptions SET status = 'active'
    WHERE ad_order_id = v_order_id AND status = 'paused';
    PERFORM private.queue_order_notifications(v_after.id, 'resumed');

  ELSIF v_action = 'renew_subscription' THEN
    IF v_before.status NOT IN ('approved', 'paused') THEN
      RAISE EXCEPTION 'Only an approved or paused order can be renewed.';
    END IF;
    v_duration := greatest(1, least(coalesce((v_payload->>'duration_days')::integer, v_before.duration_days_snapshot), 3650));
    v_expires := greatest(coalesce(v_before.expires_at, now()), now())
      + make_interval(days => v_duration);
    UPDATE public.ad_orders
    SET
      expires_at = v_expires,
      renewed_at = clock_timestamp(),
      admin_note = coalesce(v_admin_note, admin_note)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    UPDATE public.advertisements SET expires_at = v_expires
    WHERE order_id = v_order_id AND status IN ('active', 'paused');
    UPDATE public.ad_subscriptions SET expires_at = v_expires
    WHERE ad_order_id = v_order_id AND status IN ('active', 'paused');
    PERFORM private.queue_order_notifications(v_after.id, 'renewed');

  ELSIF v_action = 'expire_ad' THEN
    IF v_before.status NOT IN ('approved', 'paused') THEN
      RAISE EXCEPTION 'Only an approved or paused order can be expired.';
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'An expiry reason is required.';
    END IF;
    UPDATE public.ad_orders
    SET
      status = 'expired',
      expires_at = least(coalesce(expires_at, clock_timestamp()), clock_timestamp()),
      admin_note = coalesce(v_admin_note, v_reason)
    WHERE id = v_order_id
    RETURNING * INTO v_after;
    UPDATE public.advertisements SET status = 'expired', expires_at = clock_timestamp()
    WHERE order_id = v_order_id AND status IN ('active', 'paused');
    UPDATE public.ad_subscriptions SET status = 'expired', expires_at = clock_timestamp()
    WHERE ad_order_id = v_order_id AND status IN ('active', 'paused');
    PERFORM private.queue_order_notifications(v_after.id, 'expired');
  END IF;

  SELECT jsonb_build_object(
    'advertisements', coalesce(
      (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.placement) FROM public.advertisements a WHERE a.order_id = v_after.id),
      '[]'::jsonb
    ),
    'subscriptions', coalesce(
      (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at) FROM public.ad_subscriptions s WHERE s.ad_order_id = v_after.id),
      '[]'::jsonb
    )
  ) INTO v_related;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_order',
    v_after.id::text,
    'admin_advertising_' || v_action,
    private.ad_order_audit_state(v_before),
    private.ad_order_audit_state(v_after) || jsonb_build_object('related', v_related)
  );

  RETURN to_jsonb(v_after) || jsonb_build_object('related', v_related);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_manage_listing_webpage(
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_action text := lower(trim(coalesce(p_action, '')));
  v_listing_id uuid;
  v_listing public.listings%ROWTYPE;
  v_package public.ad_packages%ROWTYPE;
  v_subscription public.ad_subscriptions%ROWTYPE;
  v_package_code text;
  v_market_segment text;
  v_payment_reference text;
  v_reason text;
  v_duration integer;
  v_expires timestamptz;
  v_before jsonb;
  v_after jsonb;
BEGIN
  PERFORM private.require_admin(v_uid);
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Payload must be a JSON object.';
  END IF;
  IF v_action NOT IN ('activate', 'renew', 'cancel') THEN
    RAISE EXCEPTION 'Unsupported listing webpage action: %.', v_action;
  END IF;
  IF nullif(p_payload->>'listing_id', '') IS NULL THEN
    RAISE EXCEPTION 'Listing id is required.';
  END IF;

  v_listing_id := (p_payload->>'listing_id')::uuid;
  v_package_code := nullif(trim(coalesce(p_payload->>'package_code', '')), '');
  v_market_segment := nullif(trim(coalesce(p_payload->>'market_segment', '')), '');
  v_payment_reference := nullif(left(trim(coalesce(p_payload->>'payment_reference', '')), 250), '');
  v_reason := nullif(left(trim(coalesce(p_payload->>'reason', '')), 2000), '');

  SELECT * INTO v_listing
  FROM public.listings
  WHERE id = v_listing_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found.';
  END IF;
  IF v_listing.owner_user_id IS NULL THEN
    RAISE EXCEPTION 'The listing must have an owner before a webpage package can be managed.';
  END IF;

  -- Lock all current subscriptions before capturing the audit snapshot.
  PERFORM 1
  FROM public.ad_subscriptions
  WHERE listing_id = v_listing_id
    AND status IN ('active', 'paused')
  FOR UPDATE;

  SELECT jsonb_build_object(
    'listing', to_jsonb(v_listing),
    'subscriptions', coalesce(
      jsonb_agg(to_jsonb(s) ORDER BY s.created_at),
      '[]'::jsonb
    )
  ) INTO v_before
  FROM public.ad_subscriptions s
  WHERE s.listing_id = v_listing_id
    AND s.status IN ('active', 'paused');

  IF v_action = 'activate' THEN
    IF v_package_code IS NULL THEN
      RAISE EXCEPTION 'Package code is required for activation.';
    END IF;
    SELECT * INTO v_package
    FROM public.ad_packages
    WHERE code = v_package_code
      AND is_active = true
      AND product_type = 'webpage'
      AND webpage_enabled = true
      AND webpage_tier IN ('silver', 'gold', 'platinum')
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The selected webpage package is unavailable.';
    END IF;

    v_market_segment := coalesce(v_market_segment, v_listing.market_segment);
    IF v_market_segment IS NULL OR v_market_segment NOT IN (
      'local-business', 'professional-services', 'b2b-supplier',
      'hospitality-events', 'automotive-collectibles'
    ) THEN
      RAISE EXCEPTION 'A valid market segment is required.';
    END IF;
    v_duration := greatest(
      1,
      least(coalesce((p_payload->>'duration_days')::integer, v_package.duration_days, 30), 3650)
    );
    v_expires := clock_timestamp() + make_interval(days => v_duration);

    UPDATE public.ad_subscriptions
    SET status = 'cancelled'
    WHERE listing_id = v_listing_id
      AND status IN ('active', 'paused');

    INSERT INTO public.ad_subscriptions (
      user_id,
      listing_id,
      package_id,
      status,
      payment_method,
      payment_reference,
      expires_at,
      ad_order_id
    ) VALUES (
      v_listing.owner_user_id,
      v_listing_id,
      v_package.id,
      'active',
      CASE WHEN v_payment_reference IS NULL THEN 'admin_manual' ELSE 'bank_transfer' END,
      v_payment_reference,
      v_expires,
      NULL
    ) RETURNING * INTO v_subscription;

    UPDATE public.listings
    SET
      requested_tier = v_package.webpage_tier,
      market_segment = v_market_segment
    WHERE id = v_listing_id
    RETURNING * INTO v_listing;

    PERFORM private.queue_manual_webpage_notification(
      v_listing.owner_user_id,
      v_listing_id,
      v_package.id,
      'activated',
      v_expires,
      NULL
    );

  ELSIF v_action = 'renew' THEN
    SELECT s.* INTO v_subscription
    FROM public.ad_subscriptions s
    JOIN public.ad_packages p ON p.id = s.package_id
    WHERE s.listing_id = v_listing_id
      AND s.status IN ('active', 'paused')
      AND (v_package_code IS NULL OR p.code = v_package_code)
      AND p.product_type = 'webpage'
      AND p.webpage_enabled = true
    ORDER BY s.created_at DESC, s.id
    LIMIT 1
    FOR UPDATE OF s;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No active webpage subscription was found for this listing.';
    END IF;

    SELECT * INTO v_package
    FROM public.ad_packages
    WHERE id = v_subscription.package_id;
    v_market_segment := coalesce(v_market_segment, v_listing.market_segment);
    IF v_market_segment IS NULL OR v_market_segment NOT IN (
      'local-business', 'professional-services', 'b2b-supplier',
      'hospitality-events', 'automotive-collectibles'
    ) THEN
      RAISE EXCEPTION 'A valid market segment is required.';
    END IF;
    v_duration := greatest(
      1,
      least(coalesce((p_payload->>'duration_days')::integer, v_package.duration_days, 30), 3650)
    );
    v_expires := greatest(coalesce(v_subscription.expires_at, now()), now())
      + make_interval(days => v_duration);

    UPDATE public.ad_subscriptions
    SET
      status = 'active',
      expires_at = v_expires,
      payment_reference = coalesce(v_payment_reference, payment_reference),
      payment_method = CASE
        WHEN v_payment_reference IS NOT NULL THEN 'bank_transfer'
        ELSE payment_method
      END
    WHERE id = v_subscription.id
    RETURNING * INTO v_subscription;

    UPDATE public.listings
    SET
      requested_tier = v_package.webpage_tier,
      market_segment = v_market_segment
    WHERE id = v_listing_id
    RETURNING * INTO v_listing;

    PERFORM private.queue_manual_webpage_notification(
      v_listing.owner_user_id,
      v_listing_id,
      v_package.id,
      'renewed',
      v_expires,
      NULL
    );

  ELSE
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'A cancellation reason is required.';
    END IF;

    SELECT p.* INTO v_package
    FROM public.ad_subscriptions s
    JOIN public.ad_packages p ON p.id = s.package_id
    WHERE s.listing_id = v_listing_id
      AND s.status IN ('active', 'paused')
      AND p.product_type = 'webpage'
    ORDER BY s.created_at DESC, s.id
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No active webpage subscription was found for this listing.';
    END IF;

    UPDATE public.ad_subscriptions
    SET status = 'cancelled'
    WHERE listing_id = v_listing_id
      AND status IN ('active', 'paused');

    UPDATE public.listings
    SET requested_tier = NULL
    WHERE id = v_listing_id
    RETURNING * INTO v_listing;

    v_expires := NULL;
    PERFORM private.queue_manual_webpage_notification(
      v_listing.owner_user_id,
      v_listing_id,
      v_package.id,
      'cancelled',
      NULL,
      v_reason
    );
  END IF;

  SELECT jsonb_build_object(
    'listing', to_jsonb(v_listing),
    'subscriptions', coalesce(
      jsonb_agg(to_jsonb(s) ORDER BY s.created_at),
      '[]'::jsonb
    ),
    'package', to_jsonb(v_package)
  ) INTO v_after
  FROM public.ad_subscriptions s
  WHERE s.listing_id = v_listing_id;

  PERFORM private.audit_advertising_change(
    v_uid,
    'listing_webpage_subscription',
    v_listing_id::text,
    'admin_listing_webpage_' || v_action,
    v_before,
    v_after || jsonb_build_object('reason', v_reason)
  );

  RETURN v_after;
END;
$$;

-- ---------------------------------------------------------------------------
-- Public advertisement delivery and event collection
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_active_advertisements(
  p_placement text DEFAULT NULL,
  p_limit integer DEFAULT 12
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'advertisements', coalesce(
      jsonb_agg(to_jsonb(delivery) ORDER BY delivery.starts_at DESC, delivery.id),
      '[]'::jsonb
    )
  )
  FROM (
    SELECT
      a.id,
      a.placement,
      a.headline,
      a.body_text,
      a.cta_label,
      a.cta_url,
      a.creative_path,
      a.creative_metadata,
      a.starts_at,
      a.expires_at,
      p.name AS package_name,
      CASE
        WHEN l.status = 'approved'
          AND (l.expires_at IS NULL OR l.expires_at > now())
          AND (l.published_at IS NULL OR l.published_at <= now())
          THEN l.business_name
        ELSE NULL
      END AS business_name
    FROM public.advertisements a
    JOIN public.ad_packages p ON p.id = a.package_id
    LEFT JOIN public.listings l ON l.id = a.listing_id
    WHERE a.status = 'active'
      AND a.starts_at <= now()
      AND a.expires_at > now()
      AND (nullif(trim(p_placement), '') IS NULL OR a.placement = trim(p_placement))
    ORDER BY a.starts_at DESC, a.id
    LIMIT greatest(1, least(coalesce(p_limit, 12), 50))
  ) delivery;
$$;

CREATE OR REPLACE FUNCTION public.record_ad_event(
  p_advertisement_id uuid,
  p_event_type text,
  p_session_token text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ad public.advertisements%ROWTYPE;
  v_event_type text := lower(trim(coalesce(p_event_type, '')));
  v_session_hash text;
  v_metadata jsonb;
  v_event_id bigint;
BEGIN
  IF v_event_type NOT IN ('impression', 'view', 'click', 'lead', 'call', 'chat', 'booking') THEN
    RAISE EXCEPTION 'Unsupported advertisement event type.';
  END IF;
  IF char_length(trim(coalesce(p_session_token, ''))) NOT BETWEEN 8 AND 512 THEN
    RAISE EXCEPTION 'A valid anonymous session token is required.';
  END IF;
  IF p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object'
     OR octet_length(p_metadata::text) > 4096 THEN
    RAISE EXCEPTION 'Event metadata must be a JSON object no larger than 4 KB.';
  END IF;

  SELECT * INTO v_ad
  FROM public.advertisements
  WHERE id = p_advertisement_id
    AND status = 'active'
    AND starts_at <= now()
    AND expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The advertisement is not active.';
  END IF;

  v_session_hash := encode(
    extensions.digest(trim(p_session_token) || ':' || p_advertisement_id::text, 'sha256'),
    'hex'
  );
  v_metadata := p_metadata
    - ARRAY['email', 'phone', 'name', 'message', 'ip', 'ip_address', 'user_agent']::text[];

  INSERT INTO public.ad_events (
    advertisement_id,
    order_id,
    placement,
    event_type,
    user_id,
    session_hash,
    metadata
  ) VALUES (
    v_ad.id,
    v_ad.order_id,
    v_ad.placement,
    v_event_type,
    auth.uid(),
    v_session_hash,
    v_metadata
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'recorded', v_event_id IS NOT NULL,
    'deduplicated', v_event_id IS NULL,
    'event_type', v_event_type
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Administrator analytics
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_admin_advertising_analytics(
  p_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_days integer := greatest(1, least(coalesce(p_days, 30), 3660));
  v_since date;
  v_currency text;
  v_result jsonb;
BEGIN
  PERFORM private.require_admin(auth.uid());
  v_since := (timezone('UTC', now()))::date - (v_days - 1);
  SELECT o.currency_snapshot INTO v_currency
  FROM public.ad_orders o
  WHERE o.approved_at IS NOT NULL
    AND (timezone('UTC', o.approved_at))::date >= v_since
  GROUP BY o.currency_snapshot
  ORDER BY count(*) DESC, o.currency_snapshot
  LIMIT 1;
  v_currency := coalesce(v_currency, 'JMD');

  SELECT jsonb_build_object(
    'days', v_days,
    'generated_at', clock_timestamp(),
    'kpis', jsonb_build_object(
      'payment_queue', (
        SELECT count(*) FROM public.ad_orders
        WHERE status IN ('pending_payment', 'payment_submitted')
      ),
      'active_ads', (
        SELECT count(*) FROM public.advertisements
        WHERE status = 'active' AND starts_at <= now() AND expires_at > now()
      ),
      'confirmed_revenue', (
        SELECT coalesce(sum(total_price_snapshot), 0) FROM public.ad_orders
        WHERE approved_at IS NOT NULL
          AND (timezone('UTC', approved_at))::date >= v_since
          AND currency_snapshot = v_currency
      ),
      'currency', v_currency,
      'impressions', (
        SELECT count(*) FROM public.ad_events
        WHERE event_type IN ('impression', 'view') AND occurred_on >= v_since
      ),
      'clicks', (
        SELECT count(*) FROM public.ad_events
        WHERE event_type = 'click' AND occurred_on >= v_since
      ),
      'ctr', (
        SELECT CASE
          WHEN count(*) FILTER (WHERE event_type IN ('impression', 'view')) = 0 THEN 0
          ELSE round(
            100.0 * count(*) FILTER (WHERE event_type = 'click')
            / count(*) FILTER (WHERE event_type IN ('impression', 'view')),
            2
          )
        END
        FROM public.ad_events
        WHERE occurred_on >= v_since
      ),
      'expiring_30_days', (
        SELECT count(*) FROM public.advertisements
        WHERE status IN ('active', 'paused')
          AND expires_at > now()
          AND expires_at <= now() + interval '30 days'
      )
    ),
    'daily_orders', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.day)
      FROM (
        SELECT
          days.day::date AS day,
          coalesce(created.orders, 0) AS orders,
          coalesce(approved.revenue, 0) AS revenue
        FROM generate_series(
          v_since::timestamp,
          (timezone('UTC', now()))::date::timestamp,
          interval '1 day'
        ) days(day)
        LEFT JOIN (
          SELECT (timezone('UTC', created_at))::date AS day, count(*) AS orders
          FROM public.ad_orders
          WHERE (timezone('UTC', created_at))::date >= v_since
          GROUP BY 1
        ) created ON created.day = days.day::date
        LEFT JOIN (
          SELECT (timezone('UTC', approved_at))::date AS day, sum(total_price_snapshot) AS revenue
          FROM public.ad_orders
          WHERE approved_at IS NOT NULL
            AND (timezone('UTC', approved_at))::date >= v_since
            AND currency_snapshot = v_currency
          GROUP BY 1
        ) approved ON approved.day = days.day::date
      ) rows
    ), '[]'::jsonb),
    'daily_events', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.day)
      FROM (
        SELECT
          days.day::date AS day,
          coalesce(events.impressions, 0) AS impressions,
          coalesce(events.clicks, 0) AS clicks,
          CASE WHEN coalesce(events.impressions, 0) = 0 THEN 0
            ELSE round(100.0 * events.clicks / events.impressions, 2)
          END AS ctr
        FROM generate_series(
          v_since::timestamp,
          (timezone('UTC', now()))::date::timestamp,
          interval '1 day'
        ) days(day)
        LEFT JOIN (
          SELECT
            occurred_on AS day,
            count(*) FILTER (WHERE event_type IN ('impression', 'view')) AS impressions,
            count(*) FILTER (WHERE event_type = 'click') AS clicks
          FROM public.ad_events
          WHERE occurred_on >= v_since
          GROUP BY occurred_on
        ) events ON events.day = days.day::date
      ) rows
    ), '[]'::jsonb),
    'revenue_by_currency', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.currency)
      FROM (
        SELECT
          currency_snapshot AS currency,
          count(*) AS orders,
          coalesce(sum(total_price_snapshot), 0) AS revenue
        FROM public.ad_orders
        WHERE approved_at IS NOT NULL
          AND (timezone('UTC', approved_at))::date >= v_since
        GROUP BY currency_snapshot
      ) rows
    ), '[]'::jsonb),
    'orders_by_status', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.status)
      FROM (
        SELECT status, count(*) AS count
        FROM public.ad_orders
        WHERE (timezone('UTC', created_at))::date >= v_since
        GROUP BY status
      ) rows
    ), '[]'::jsonb),
    'package_performance', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.orders DESC, rows.package_name)
      FROM (
        SELECT
          p.id AS package_id,
          p.name AS package_name,
          count(o.id) AS orders,
          coalesce(sum(o.total_price_snapshot) FILTER (WHERE o.approved_at IS NOT NULL), 0) AS revenue
        FROM public.ad_packages p
        LEFT JOIN public.ad_orders o ON o.package_id = p.id
          AND (timezone('UTC', o.created_at))::date >= v_since
        GROUP BY p.id, p.name
      ) rows
    ), '[]'::jsonb),
    'placement_performance', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.impressions DESC, rows.placement)
      FROM (
        SELECT
          a.placement,
          count(e.id) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
          count(e.id) FILTER (WHERE e.event_type = 'click') AS clicks,
          count(e.id) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads
        FROM public.advertisements a
        LEFT JOIN public.ad_events e ON e.advertisement_id = a.id AND e.occurred_on >= v_since
        GROUP BY a.placement
      ) rows
    ), '[]'::jsonb),
    'upcoming_expirations', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.week_start)
      FROM (
        SELECT
          date_trunc('week', expires_at)::date AS week_start,
          count(*) AS count
        FROM public.advertisements
        WHERE status IN ('active', 'paused')
          AND expires_at > now()
          AND expires_at <= now() + interval '56 days'
        GROUP BY 1
      ) rows
    ), '[]'::jsonb),
    'top_ads', coalesce((
      SELECT jsonb_agg(to_jsonb(rows) ORDER BY rows.impressions DESC, rows.clicks DESC)
      FROM (
        SELECT
          a.id,
          coalesce(a.headline, p.name) AS title,
          a.placement,
          l.business_name,
          count(e.id) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
          count(e.id) FILTER (WHERE e.event_type = 'click') AS clicks,
          count(e.id) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads,
          CASE
            WHEN count(e.id) FILTER (WHERE e.event_type IN ('impression', 'view')) = 0 THEN 0
            ELSE round(
              100.0 * count(e.id) FILTER (WHERE e.event_type = 'click')
              / count(e.id) FILTER (WHERE e.event_type IN ('impression', 'view')),
              2
            )
          END AS ctr
        FROM public.advertisements a
        JOIN public.ad_packages p ON p.id = a.package_id
        LEFT JOIN public.listings l ON l.id = a.listing_id
        LEFT JOIN public.ad_events e ON e.advertisement_id = a.id AND e.occurred_on >= v_since
        GROUP BY a.id, a.headline, a.placement, p.name, l.business_name
        ORDER BY impressions DESC, clicks DESC
        LIMIT 10
      ) rows
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Remove legacy policy overlap and direct-write grants
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "Public can read ad packages" ON public.ad_packages;
DROP POLICY IF EXISTS "Public can view active ad packages" ON public.ad_packages;
DROP POLICY IF EXISTS "Admins can manage ad packages" ON public.ad_packages;
DROP POLICY IF EXISTS "Active advertising packages are public" ON public.ad_packages;
DROP POLICY IF EXISTS "Admins manage advertising packages" ON public.ad_packages;
CREATE POLICY "Active advertising packages are public"
ON public.ad_packages FOR SELECT TO anon, authenticated
USING (is_active = true OR private.is_admin((SELECT auth.uid())));
CREATE POLICY "Admins manage advertising packages"
ON public.ad_packages FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Active package options are readable" ON public.ad_package_options;
DROP POLICY IF EXISTS "Admins manage package options" ON public.ad_package_options;
DROP POLICY IF EXISTS "Active advertising options are public" ON public.ad_package_options;
DROP POLICY IF EXISTS "Admins manage advertising options" ON public.ad_package_options;
CREATE POLICY "Active advertising options are public"
ON public.ad_package_options FOR SELECT TO anon, authenticated
USING (
  (is_active = true AND EXISTS (
    SELECT 1 FROM public.ad_packages p
    WHERE p.id = package_id AND p.is_active = true
  ))
  OR private.is_admin((SELECT auth.uid()))
);
CREATE POLICY "Admins manage advertising options"
ON public.ad_package_options FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Admins manage payment accounts" ON public.payment_accounts;
DROP POLICY IF EXISTS "admins can manage payment accounts" ON public.payment_accounts;
DROP POLICY IF EXISTS "active accounts visible to auth" ON public.payment_accounts;
DROP POLICY IF EXISTS "Admins manage advertising payment accounts" ON public.payment_accounts;
CREATE POLICY "Admins manage advertising payment accounts"
ON public.payment_accounts FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Customers read own ad orders" ON public.ad_orders;
DROP POLICY IF EXISTS "users can view own orders" ON public.ad_orders;
DROP POLICY IF EXISTS "users can insert own orders" ON public.ad_orders;
DROP POLICY IF EXISTS "admins can manage all orders" ON public.ad_orders;
DROP POLICY IF EXISTS "Customers read their advertising orders" ON public.ad_orders;
DROP POLICY IF EXISTS "Admins manage advertising orders" ON public.ad_orders;
CREATE POLICY "Customers read their advertising orders"
ON public.ad_orders FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR private.is_admin((SELECT auth.uid())));
CREATE POLICY "Admins manage advertising orders"
ON public.ad_orders FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Users can read own subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Users can view own subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Users can insert own subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Admins can update subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Admins can delete subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Admins have full access to subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Customers read their advertising subscriptions" ON public.ad_subscriptions;
DROP POLICY IF EXISTS "Admins manage advertising subscriptions" ON public.ad_subscriptions;
CREATE POLICY "Customers read their advertising subscriptions"
ON public.ad_subscriptions FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR private.is_admin((SELECT auth.uid())));
CREATE POLICY "Admins manage advertising subscriptions"
ON public.ad_subscriptions FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Public reads currently active advertisements" ON public.advertisements;
DROP POLICY IF EXISTS "Admins manage advertisements" ON public.advertisements;
DROP POLICY IF EXISTS "Public reads deliverable advertisements" ON public.advertisements;
DROP POLICY IF EXISTS "Admins manage delivered advertisements" ON public.advertisements;
DROP POLICY IF EXISTS "Owners and admins read advertisements" ON public.advertisements;
CREATE POLICY "Owners and admins read advertisements"
ON public.advertisements FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR private.is_admin((SELECT auth.uid()))
);
CREATE POLICY "Admins manage delivered advertisements"
ON public.advertisements FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Advertisers and admins read ad events" ON public.ad_events;
DROP POLICY IF EXISTS "Advertisers and admins read advertising events" ON public.ad_events;
CREATE POLICY "Advertisers and admins read advertising events"
ON public.ad_events FOR SELECT TO authenticated
USING (
  private.is_admin((SELECT auth.uid()))
  OR EXISTS (
    SELECT 1 FROM public.advertisements a
    WHERE a.id = advertisement_id
      AND a.user_id = (SELECT auth.uid())
  )
);

DROP POLICY IF EXISTS "Admins read notification outbox" ON public.notification_outbox;
DROP POLICY IF EXISTS "Admins read advertising notification outbox" ON public.notification_outbox;
CREATE POLICY "Admins read advertising notification outbox"
ON public.notification_outbox FOR SELECT TO authenticated
USING (private.is_admin((SELECT auth.uid())));

REVOKE ALL ON public.ad_packages FROM anon, authenticated;
REVOKE ALL ON public.ad_package_options FROM anon, authenticated;
REVOKE ALL ON public.payment_accounts FROM anon, authenticated;
REVOKE ALL ON public.ad_orders FROM anon, authenticated;
REVOKE ALL ON public.ad_subscriptions FROM anon, authenticated;
REVOKE ALL ON public.advertisements FROM anon, authenticated;
REVOKE ALL ON public.ad_events FROM anon, authenticated;
REVOKE ALL ON public.notification_outbox FROM anon, authenticated;
REVOKE ALL ON public.admin_audit_log FROM anon, authenticated;
REVOKE ALL ON public.listing_webpages FROM anon, authenticated;

GRANT SELECT ON public.ad_packages TO anon, authenticated;
GRANT SELECT ON public.ad_package_options TO anon, authenticated;
GRANT SELECT ON public.payment_accounts TO authenticated;
GRANT SELECT ON public.ad_orders TO authenticated;
GRANT SELECT ON public.ad_subscriptions TO authenticated;
GRANT SELECT ON public.advertisements TO authenticated;
GRANT SELECT ON public.ad_events TO authenticated;
GRANT SELECT ON public.notification_outbox TO authenticated;
GRANT SELECT ON public.admin_audit_log TO authenticated;
GRANT SELECT ON public.listing_webpages TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.listing_webpages TO authenticated;

-- ---------------------------------------------------------------------------
-- Function execution allow-list
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.get_ad_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_ad_order(uuid, uuid, uuid[], text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_ad_payment_proof(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_ad_creative(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_ad_orders() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_manage_payment_account(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_manage_ad_package(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_manage_ad_package_option(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_get_ad_configuration() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_get_ad_orders(text, timestamptz, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_manage_advertising(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_manage_listing_webpage(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_admin_advertising_analytics(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_active_advertisements(text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_ad_event(uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatch_ad_notification_outbox(integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_ad_catalog() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_ad_order(uuid, uuid, uuid[], text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_ad_payment_proof(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_ad_creative(uuid, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_ad_orders() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manage_payment_account(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manage_ad_package(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manage_ad_package_option(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_ad_configuration() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_ad_orders(text, timestamptz, timestamptz, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manage_advertising(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manage_listing_webpage(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_advertising_analytics(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_advertisements(text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_event(uuid, text, text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_ad_notification_outbox(integer) TO authenticated, service_role;

REVOKE ALL ON FUNCTION private.ad_order_audit_state(public.ad_orders) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.audit_advertising_change(uuid, text, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_order_notifications(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_manual_webpage_notification(uuid, uuid, uuid, text, timestamptz, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.reconcile_ad_notification_outbox() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.process_ad_notification_outbox(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trigger_ad_notification_dispatch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.expire_advertising_state(timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.run_advertising_maintenance() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Best-effort pg_cron installation. Supabase projects which disallow enabling
-- pg_cron still retain the insert trigger and the manually callable admin RPC.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_cron could not be enabled: %', SQLERRM;
    END;
  END IF;
END $$;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    FOR v_job_id IN
      SELECT jobid FROM cron.job WHERE jobname = 'ajm-advertising-maintenance'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;

    PERFORM cron.schedule(
      'ajm-advertising-maintenance',
      '*/5 * * * *',
      'SELECT private.run_advertising_maintenance();'
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'AJM advertising maintenance could not be scheduled: %', SQLERRM;
END $$;
