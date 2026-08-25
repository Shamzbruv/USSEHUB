-- Admin order completion (hard delete + pending-payment override approval),
-- the free 30-day directory listing lifecycle (auto-expiry + self-service
-- renewal, extended for free by any active paid webpage package), and a
-- customer-facing ad performance summary (impressions/clicks per listing
-- owner). All functions below are full CREATE OR REPLACE redefinitions of
-- existing objects plus a small number of new, additive ones; nothing here
-- drops or narrows an existing capability.

-- ---------------------------------------------------------------------------
-- 1. admin_manage_advertising: allow a hard delete of non-live orders, and
--    let an administrator confirm payment for an order still sitting in
--    pending_payment (a manual/complimentary/phone-confirmed transfer that
--    never had a receipt uploaded). Both changes also keep the underlying
--    free directory listing alive for as long as its paid webpage package
--    remains active (confirm_payment and renew_subscription now bump
--    listings.expires_at, never shrink it).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_manage_advertising(p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'renew_subscription', 'pause_ad', 'resume_ad', 'expire_ad', 'delete_order'
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
    IF v_before.status NOT IN ('payment_submitted', 'pending_payment') THEN
      RAISE EXCEPTION 'Only a submitted or pending bank transfer can be confirmed.';
    END IF;
    -- A pending order has no submitted proof yet. Confirming it anyway is a
    -- deliberate administrator override (phone confirmation, complimentary
    -- access, etc.), so the audit trail records that explicitly.
    IF v_before.status = 'pending_payment' AND v_admin_note IS NULL THEN
      v_admin_note := 'Approved by an administrator without a submitted bank-transfer proof.';
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

      -- A paid webpage package keeps the underlying free directory listing
      -- alive for at least as long as the package is active, so the listing
      -- never lapses out from under a paying customer.
      UPDATE public.listings
      SET expires_at = greatest(coalesce(expires_at, v_expires), v_expires)
      WHERE id = v_after.listing_id;
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
    IF v_after.product_type_snapshot = 'webpage' AND v_after.listing_id IS NOT NULL THEN
      UPDATE public.listings
      SET expires_at = greatest(coalesce(expires_at, v_expires), v_expires)
      WHERE id = v_after.listing_id;
    END IF;
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

  ELSIF v_action = 'delete_order' THEN
    -- Only terminal or not-yet-live orders can be hard deleted. A live
    -- campaign must be cancelled first so its advertisement/subscription
    -- rows are stopped in an auditable way before the order disappears.
    IF v_before.status IN ('approved', 'paused') THEN
      RAISE EXCEPTION 'Cancel this order before deleting it. Approved or paused orders must be cancelled first.';
    END IF;

    PERFORM private.audit_advertising_change(
      v_uid,
      'ad_order',
      v_before.id::text,
      'admin_advertising_delete_order',
      private.ad_order_audit_state(v_before),
      jsonb_build_object('deleted', true)
    );

    DELETE FROM public.ad_orders WHERE id = v_order_id;

    RETURN jsonb_build_object(
      'deleted', true,
      'order_id', v_order_id,
      'order_number', v_before.order_number
    );
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
$function$;

-- ---------------------------------------------------------------------------
-- 2. admin_manage_listing_webpage: the direct admin activation/renewal tool
--    now also keeps listings.expires_at extended to at least the package's
--    new expiry, for the same reason as above.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_manage_listing_webpage(p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      market_segment = v_market_segment,
      expires_at = greatest(coalesce(expires_at, v_expires), v_expires)
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
      market_segment = v_market_segment,
      expires_at = greatest(coalesce(expires_at, v_expires), v_expires)
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
$function$;

-- ---------------------------------------------------------------------------
-- 3. Free directory listings now run on a 30-day clock. A listing owner may
--    self-renew (only moving expired -> approved, never any other status),
--    so the privileged-column trigger needs to allow that one extra
--    self-service transition.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.protect_listing_privileged_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
            BEGIN
                IF NOT private.is_admin((SELECT auth.uid())) THEN
                    IF NEW.status IS DISTINCT FROM OLD.status THEN
                        -- Allow users to move from draft to pending, or changes_requested to pending,
                        -- or to self-renew a listing that lapsed out of the free 30-day window.
                        IF NOT (
                            (OLD.status IN ('draft', 'changes_requested') AND NEW.status = 'pending')
                            OR (OLD.status = 'expired' AND NEW.status = 'approved')
                        ) THEN
                            RAISE EXCEPTION 'You do not have permission to change the status to %.', NEW.status;
                        END IF;
                    END IF;

                    IF NEW.is_featured IS DISTINCT FROM OLD.is_featured THEN
                        RAISE EXCEPTION 'You cannot change the is_featured flag.';
                    END IF;

                    IF NEW.admin_note IS DISTINCT FROM OLD.admin_note THEN
                        RAISE EXCEPTION 'You cannot modify admin_note.';
                    END IF;

                    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
                        RAISE EXCEPTION 'You cannot modify approved_by.';
                    END IF;
                END IF;
                RETURN NEW;
            END;
            $function$;

-- ---------------------------------------------------------------------------
-- 4. Self-service (or admin) renewal of a free directory listing: extends
--    expires_at by 30 days from now, reviving a lapsed listing back to
--    'approved' if needed.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.renew_free_listing(p_listing_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_listing public.listings%ROWTYPE;
  v_old_status text;
  v_expires timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to renew a listing.';
  END IF;
  IF p_listing_id IS NULL THEN
    RAISE EXCEPTION 'Listing id is required.';
  END IF;

  SELECT * INTO v_listing
  FROM public.listings
  WHERE id = p_listing_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found.';
  END IF;
  IF v_listing.owner_user_id IS DISTINCT FROM v_uid AND NOT private.is_admin(v_uid) THEN
    RAISE EXCEPTION 'You do not have permission to renew this listing.';
  END IF;
  IF v_listing.status NOT IN ('approved', 'expired') THEN
    RAISE EXCEPTION 'Only an approved or recently expired listing can be renewed.';
  END IF;

  v_old_status := v_listing.status;
  v_expires := clock_timestamp() + interval '30 days';

  UPDATE public.listings
  SET
    status = 'approved',
    expires_at = v_expires,
    published_at = coalesce(published_at, clock_timestamp())
  WHERE id = p_listing_id
  RETURNING * INTO v_listing;

  IF v_old_status IS DISTINCT FROM 'approved' THEN
    INSERT INTO public.listing_status_history (listing_id, old_status, new_status, changed_by, reason)
    VALUES (p_listing_id, v_old_status, 'approved', v_uid, 'Self-service free listing renewal.');
  END IF;

  RETURN jsonb_build_object(
    'listing_id', v_listing.id,
    'status', v_listing.status,
    'expires_at', v_listing.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.renew_free_listing(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_free_listing(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Automatic expiry of free listings whose 30-day window has passed,
--    wired into the existing 5-minute advertising maintenance cron.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.expire_stale_listings(
  p_now timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_listing public.listings%ROWTYPE;
  v_count integer := 0;
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public.listings
    WHERE status = 'approved'
      AND expires_at IS NOT NULL
      AND expires_at <= p_now
    ORDER BY expires_at, id
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.listings
    SET status = 'expired'
    WHERE id = v_listing.id;

    INSERT INTO public.listing_status_history (listing_id, old_status, new_status, changed_by, reason)
    VALUES (v_listing.id, 'approved', 'expired', NULL, 'Automatically expired after the free 30-day listing period.');

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('expired_count', v_count, 'ran_at', p_now);
END;
$$;

REVOKE ALL ON FUNCTION private.expire_stale_listings(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.run_advertising_maintenance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expiry jsonb;
  v_listings jsonb;
  v_notifications jsonb;
BEGIN
  v_expiry := private.expire_advertising_state(clock_timestamp());
  v_listings := private.expire_stale_listings(clock_timestamp());
  v_notifications := private.process_ad_notification_outbox(50);
  RETURN jsonb_build_object(
    'expiry', v_expiry,
    'listings', v_listings,
    'notifications', v_notifications,
    'ran_at', clock_timestamp()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Ad performance summary for the signed-in advertiser: impressions,
--    clicks and lead-style engagement per advertisement they own, so a
--    listing owner can see how their advertising is performing.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_my_ad_performance()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN jsonb_build_object('advertisements', '[]'::jsonb)
    ELSE jsonb_build_object(
      'advertisements',
      coalesce(jsonb_agg(row_data ORDER BY (row_data->>'starts_at') DESC), '[]'::jsonb)
    )
  END
  FROM (
    SELECT jsonb_build_object(
      'advertisement_id', a.id,
      'order_id', a.order_id,
      'order_number', o.order_number,
      'package_name', o.package_name_snapshot,
      'placement', a.placement,
      'status', a.status,
      'headline', a.headline,
      'listing_id', a.listing_id,
      'business_name', l.business_name,
      'starts_at', a.starts_at,
      'expires_at', a.expires_at,
      'impressions', coalesce(ev.impressions, 0),
      'clicks', coalesce(ev.clicks, 0),
      'leads', coalesce(ev.leads, 0)
    ) AS row_data
    FROM public.advertisements a
    JOIN public.ad_orders o ON o.id = a.order_id
    LEFT JOIN public.listings l ON l.id = a.listing_id
    LEFT JOIN LATERAL (
      SELECT
        count(*) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
        count(*) FILTER (WHERE e.event_type = 'click') AS clicks,
        count(*) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads
      FROM public.ad_events e
      WHERE e.advertisement_id = a.id
    ) ev ON true
    WHERE a.user_id = auth.uid()
  ) ranked;
$$;

REVOKE ALL ON FUNCTION public.get_my_ad_performance() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_ad_performance() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. One-time backfill for listings approved before this migration existed.
--    Give every currently-approved free listing a fresh 30-day runway
--    starting today (never an instant, surprise expiry), and make sure any
--    listing with an active paid webpage package is covered through at
--    least that package's expiry.
-- ---------------------------------------------------------------------------

UPDATE public.listings
SET expires_at = clock_timestamp() + interval '30 days'
WHERE status = 'approved'
  AND expires_at IS NULL;

UPDATE public.listings l
SET expires_at = greatest(l.expires_at, s.max_expires_at)
FROM (
  SELECT listing_id, max(expires_at) AS max_expires_at
  FROM public.ad_subscriptions
  WHERE status IN ('active', 'paused')
    AND listing_id IS NOT NULL
  GROUP BY listing_id
) s
WHERE l.id = s.listing_id
  AND l.status = 'approved';
