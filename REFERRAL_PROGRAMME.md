# USSE referral agreements and commission register

The admin entry point is `/referral-agreements`, linked from Master Admin, Standard Admin and Advertising Management. It covers USSE Consultancy, AJM / Aloe Jamaica (including advertising and paid business webpages), and PISTOL. It adapts the ICSS Command Center's referral agreement workflow without copying ICSS contact details, signature or default commission rates.

## Activation

The frontend is additive and can be deployed normally. Until the database migration is applied, the new admin page displays a setup-pending message. Existing admin, directory, consultancy and commerce features continue to work.

Apply **only** `supabase/migrations/20261014213228_usse_referral_agreements.sql` to the USSE project **`zcptuqrlovflcpqszery`**. The current GitHub/Supabase connector account may not have this project: a token with access to this USSE project is required. Do not apply the migration to ICSS Ledger or Grace Connect. There are no new Edge Functions, storage buckets, email-provider secrets or external payment integrations to deploy.

After application, inspect Supabase security advisors and verify:

- All four `referral_*` tables have RLS and administrator-only SELECT policies.
- `anon` has no table privileges; `authenticated` has SELECT only. Members cannot read programme data.
- The three public RPC wrappers are security invokers; private admin writes verify `private.require_admin(auth.uid())`.
- The two private partner functions require the signing capability token; they do not grant anonymous table access.
- Sign in as a real USSE admin and complete company details/signature, create a test draft, issue a link, sign it as the test partner, and inspect the audit history. Cancel unused test links.

The migration relies on USSE's existing `profiles`, `private.is_admin` and `private.require_admin` functions. A missing prerequisite fails the migration transaction rather than granting broader access.

## Admin workflow

1. Open Company & signature. Enter the contracting company's identity, authorized signatory and title. Upload a PNG/WebP signature under 2 MB. The page asks for a transparent background and previews it over a checkerboard. Raster uploads are resized and normalized to PNG; SVG is not accepted.
2. Create an agreement with the partner's contact details, covered subsidiaries and an explicitly chosen commission structure: percentage, flat, or tiered. Review payment timing, termination notice and any additional terms.
3. Save and review the draft. Issuing a signing link freezes the structured terms, document wording and company signature. A new settings upload cannot alter prior agreements. Only unsigned drafts can be edited; issue a new agreement for amendments.
4. Copy the signing link and share it with the intended partner. No email is sent automatically. Links expire after 30 days. A replacement link invalidates the previous token, and cancellation disables signing.
5. The partner reviews the full agreement, confirms four acknowledgements, draws or uploads a signature, and accepts it. Their name, email, signature, acknowledgements and server timestamp are retained. Signing is atomic and cannot be repeated.
6. Download the self-contained HTML copy or use Print / Save PDF. Copies include both signatures and the recorded acknowledgements. The admin can retain copies even after a partner link expires.
7. Register referred clients under signed agreements. Record a unique opportunity/invoice reference, covered subsidiary, contracted value, cumulative cleared receipts, refunds and qualification status. The database calculates commissions using that agreement's frozen terms. Flat commissions accrue once a referral is fully paid; percentage commissions accrue on net cleared receipts. Record a payment reference after paying externally; the system does not transfer money. Paid records are locked.

Use the agreement currency for every register amount. Do not mix currencies or include more cleared receipts than the recorded project value. Recurring work or materially changed commercial terms should have a separately documented opportunity/engagement, rather than changing an already paid record.

## Security and maintenance

Tokens have 256 bits of randomness, are placed in URL fragments (not hosting logs/query strings), and are stored only as SHA-256 hashes. Treat the signing link as a private bearer credential. The email field confirms the agreed contact detail; it is not an identity-verification service. No company signature is placed in a public asset bucket.

Document wording is stored as `snapshot.document_sections`. Rendering escapes all text and only accepts bounded PNG data URLs. Preserve the `usse-referral-v1` terms for existing agreements. New templates should use a new version rather than modifying frozen documents.

All writes go through guarded RPCs, and create/edit/issue/cancel/sign/settings/referral/payment events are recorded. Signed agreements cannot be changed through these RPCs. The SQL tests use an isolated PostgreSQL engine (PGlite), never production records.

## Validation

Run `npm ci`, then `npm test`. This runs static validation, isolated PostgreSQL access/lifecycle/commission tests and route tests. These tests cover anonymous/member/admin access, signature acknowledgements, terms immutability, token replacement and expiry, repeat signing, subsidiary scope, commission thresholds/refunds, duplicate opportunities and paid-record locks. Live-project validation still needs USSE database access.
