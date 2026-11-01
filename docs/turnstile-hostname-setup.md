# Enquiry form: Cloudflare hostname authorization

On 1 November 2026, the live `https://ussehub.com/index.html#booking` form emitted Cloudflare Turnstile error **110200**. Cloudflare defines this as **Domain not authorized**. The public widget key used by the enquiry and directory forms is `0x4AAAAAADny2ngXsIdv_AkO`.

The remaining production fix requires the Cloudflare account that owns that widget:

1. Open Cloudflare → Turnstile → the widget matching that public key → Settings.
2. Under Hostname Management, add **ussehub.com**. Enter the hostname alone, without `https://` or a page path. Keep any other valid hostnames in place.
3. Save the setting. Cloudflare includes `www.ussehub.com` automatically when the root hostname is authorized.
4. Open the live form and confirm that 110200 no longer appears. Test an authorized enquiry and verify its saved receipt and lead-inbox entry; deleting the error message alone is not verification.

Adding the correct hostname to the existing widget keeps the current key and corresponding server secret in place. The Supabase access token cannot edit Cloudflare account settings. Do not disable server-side verification or replace the live widget with a testing key.

Until corrected, the shared public-form error state states explicitly that no enquiry has been sent and offers native Call, WhatsApp and Email links to USSE. Those are direct contact routes and do not claim a lead record was saved. An error reference is shown so support can distinguish permanent configuration errors from a connection failure. The verified-success callback clears stale security-error text.

References:
- https://developers.cloudflare.com/turnstile/troubleshooting/client-side-errors/error-codes/
- https://developers.cloudflare.com/turnstile/additional-configuration/hostname-management/
