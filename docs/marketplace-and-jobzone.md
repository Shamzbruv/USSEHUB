# Gary’s marketplace feedback — implemented November 2026

## Three offerings

`/ajm-marketplace-admin` provides independent **Directory listings**, **Business webpages** and **Web banners** registers. A directory record can have a related paid webpage, but neither is counted as a banner campaign. The banner register includes pending/unpaid orders, approval status, run dates, each delivered placement and its last-30-day views/clicks/leads. Existing package prices and payment approval remain authoritative.

The public directory also explains all three offerings and opens the appropriate filtered package catalogue. A featured directory logo is a thumbnail, while a banner uses its uploaded campaign artwork. The local banner preview shows actual uploaded artwork with a choice of leaderboard (728×90), wide (970×250), medium rectangle (300×250), vertical skyscraper (160×600) and mobile (320×100) formats. Artwork is contained rather than cropped or stretched. No campaign is published by the preview tool.

Packages can target top, bottom, left and right positions on USSE Home, the AJM directory, Aloe Jamaica, Consultancy, PISTOL, business webpages and JobZone. The package editor’s picker writes the existing placement keys. No paid price, payment destination or package is created automatically. Legacy placements continue to work. On screens below 1280px, left/right rail ads move into the content flow; ads never cover page controls. Existing automatic webpage promotions remain separate from independent display-ad orders.

## Leads

**Remove from inbox** records a reason, cancels outstanding email/push alerts and retains the record and audit trail. **Removed leads only** shows removed entries; **Restore** returns one to the active register without resending old cancelled alerts. This is reversible removal, not permanent deletion or a spam block. Fresh legitimate customer enquiries are still accepted. The enterprise consultations view and active inbox metrics exclude removed records; the export follows the selected active/removed filter.

## Categories

The supplied screenshot’s named additions are available in the shared listing taxonomy: Business Operators, Tourism Industry, Hotel Operations, Retail Operations / Industry, and Restaurant Services, with Human Resources, Maintenance, Operations, Accounting, Housekeeping, Promotions, Marketing, Sales, Public Relations, Duty Operations and Other Departments. Secondary/tertiary selections persist through the existing readable category path. Existing categories and legacy saved selections are retained. These are the additions visible in the supplied feedback; this does not claim to recreate an unavailable earlier category document word for word.

## AJM JobZone

- `/ajm-jobzone`: public vacancies, sector/department filters, vacancy details, signed-in applications and the applicant’s own application register/withdrawal.
- `/ajm-jobzone-employer`: existing active member account; create/edit drafts, submit free vacancies for moderation, close vacancies, receive private applications, contact applicants through the employer’s own apps, update application stages and export the private candidate register.
- `/ajm-jobzone-admin`: active USSE administrators moderate vacancy content and monitor views, apply opens and application totals. It contains no candidate contact details, statements or CV links. Even an administrator who is not the posting employer cannot call the employer application RPC.

Applications use the verified account email, explicit consent, one application per person per vacancy and daily limits. A CV/portfolio may be supplied as an optional HTTPS share link; the platform does not upload or email CV files. Withdrawn applications are redacted in the employer register and excluded from exports. There are no automated hiring decisions or candidate rankings. Expired/closed/unpublished roles cannot accept applications.

Standard employer posting and applications are free. An employer may request paid promotion; that request enters the ordinary lead inbox once. Admin may link the employer’s current, approved display-ad order. Promoted status follows actual approval and expiry; an unpaid or another employer’s order cannot grant promotion. Existing commercial package pricing is used; no new fee is invented.

Employer applications refresh while the employer workspace is open. USSE receives privacy-safe activity notices through the existing admin activity/push system. This change does not promise employer email alerts or background push to non-admin member accounts.

## Verification and deployment

`npm run test:marketplace` executes the actual migration in PGlite and checks archive/restoration, role boundaries, fresh enquiries after removal, duplicate applications, private employer registers, moderation, verified account email, withdrawal, expiry and payment-gated promotion. The existing app test exercises the actual production static handler for every route, without relying on OS network-interface enumeration.

`scripts/deploy-marketplace.mjs` reads a management credential from stdin. `--validate` runs migration/workflow checks in a rolled-back transaction. `--apply` installs the immutable, checksum-recorded additive migration and then runs the same rolled-back workflow verification plus a security-advisor comparison. No synthetic records or verification emails are committed. Frontend changes are published through GitHub main for the existing automatic deployment; Railway is not accessed directly.
