-- Belt-and-braces enforcement of the free 30-day listing clock: whichever
-- code path flips a listing to 'approved' (the admin-listings Edge
-- Function, a future replacement for it, or a direct administrative
-- update), this trigger guarantees a first-time approval always gets an
-- expiry instead of silently running forever. It never overwrites an
-- expiry that is already set, so it cannot shorten a listing whose expiry
-- was already extended by an active paid webpage package.

CREATE OR REPLACE FUNCTION private.set_listing_free_expiry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'approved'
     AND NEW.expires_at IS NULL
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'approved') THEN
    NEW.expires_at := clock_timestamp() + interval '30 days';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_listing_free_expiry ON public.listings;
CREATE TRIGGER trg_set_listing_free_expiry
BEFORE INSERT OR UPDATE ON public.listings
FOR EACH ROW
EXECUTE FUNCTION private.set_listing_free_expiry();
