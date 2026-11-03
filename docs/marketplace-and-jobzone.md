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

Applications use the verified account email, explicit consent, one application per person per vacancy and daily limits. A CV/portfolio may be supplied as an optional HTTPS share link; employer workspace applications retain the optional shared-link flow. Applicants may also use an employer-approved public email address to compose a message in their own email app and attach files there. This does not send automatically or add an email application to the platform register. Withdrawn applications are redacted in the employer register and excluded from exports. There are no automated hiring decisions or candidate rankings. Expired/closed/unpublished roles cannot accept applications.

Standard employer posting and applications are free. An employer may request paid promotion; that request enters the ordinary lead inbox once. Admin may link the employer’s current, approved display-ad order. Promoted status follows actual approval and expiry; an unpaid or another employer’s order cannot grant promotion. Existing commercial package pricing is used; no new fee is invented.

Employer applications refresh while the employer workspace is open. USSE receives privacy-safe activity notices through the existing admin activity/push system. This change does not promise employer email alerts or background push to non-admin member accounts.

## Verification and deployment

`npm run test:marketplace` executes the actual migration in PGlite and checks archive/restoration, role boundaries, fresh enquiries after removal, duplicate applications, private employer registers, moderation, verified account email, withdrawal, expiry and payment-gated promotion. The existing app test exercises the actual production static handler for every route, without relying on OS network-interface enumeration.

`scripts/deploy-marketplace.mjs` reads a management credential from stdin. `--validate` runs migration/workflow checks in a rolled-back transaction. `--apply` installs the immutable, checksum-recorded additive migration and then runs the same rolled-back workflow verification plus a security-advisor comparison. No synthetic records or verification emails are committed. Frontend changes are published through GitHub main for the existing automatic deployment; Railway is not accessed directly.

## Direct USSE PDF applications and employer contact

The public JobZone page has **Submit an application to USSE** and **My USSE submissions**. Verified active accounts can upload a completed PDF application form or CV up to 5 MB, with an explicit choice to share contact information and the document with USSE. There is no fee. This separate inbox does not expose applications to other employers.

Uploads reserve an owner-bound reference first, accept only a PDF in a private Storage bucket, and show success only after the backend confirms stored size/MIME metadata. Client validation checks the PDF header. A failed or repeated submission can retry without generating duplicate receipt notices. Up to five reservations per account per day are allowed; pending uploads expire after 30 minutes.

The JobZone admin workspace links to **USSE PDF applications**. Active admins can download explicitly submitted PDFs, contact the applicant, and mark received/reviewing/closed. Applicants can view their own submissions and withdraw them. Withdrawal removes the submission from the USSE inbox and immediately blocks future admin downloads. Previously downloaded copies cannot be recalled. Storage objects have no client overwrite/delete permission and are never public. Downloads require a current authenticated request rather than a reusable public or signed URL.

The employer vacancy form has **Use my account email on file** and an explicit checkbox to display that address publicly. A different business address may be entered. The email is part of the moderated vacancy and remains hidden while draft/pending or closed/expired. An existing employer login email is never published automatically. On a published vacancy, **Email employer** opens the applicant’s own email composer with the recipient and vacancy subject. The applicant adds attachments and sends there; the UI does not claim email delivery or track these emails as platform applications.

Migration: `20261102200729_jobzone_pdf_submissions_and_employer_email.sql`. `npm run test:marketplace` covers both the existing employer workflows and the added consent, verified identity, file limits, idempotent receipt, Storage RLS, inbox isolation, withdrawal, administrator review and public-contact moderation. `scripts/deploy-jobzone-documents.mjs --validate` checks the live workflow inside a rolled-back transaction; no applications, uploaded-object metadata or alerts are committed by verification.

## Vacancy flyers: paste, drop or upload

**Post vacancy flyer** appears in the JobZone admin and employer workspaces. Choose a JPG, PNG or WebP image up to 5 MB, drag it onto the preview area, or focus that area and paste a copied image with Ctrl+V / Command+V. A vacancy title and advertised employer name are the only required text fields. The full advert remains in the picture; optional location, note, email and source/application link improve discovery and contact. The preview uses the original proportions.

An active, verified administrator can publish directly; other active, verified accounts submit for moderation. Both can save drafts. Flyer posts appear in the existing vacancy register with a flyer badge, a full-size image view and a shareable JobZone link. **Edit flyer** returns a published post to draft until it is published or approved again; **Close vacancy** stops public listing and new public image links. Images live in a separate private bucket. Anonymous read access is limited by RLS to current, published flyer posts; generated image URLs last five minutes. Pending/draft images can only be read by the owner or active administrator. The client can retry uploads without overwriting image objects or generating duplicate publication events.

Flyers are shared adverts, not employer-owned application forms. Visitors apply using the advertiser’s instructions, the explicitly displayed email, or the original advert/application link. The platform rejects internal application submissions to flyer posts, keeping third-party applicants out of the publisher’s employer inbox and USSE PDF inbox. No advertiser email is extracted or invented.

If a genuine closing date is entered, the listing shows **Closes** and expires then. Otherwise the publisher chooses a 7/14/30/60-day display period, labeled **Listing shown until**; it is not presented as an employer-supplied deadline.

`tests/jobzone-flyers.test.mjs` exercises the migration, role/RLS boundaries, malformed/oversized inputs, incomplete upload publication, retry receipts, moderation, edits, closing/expiry, direct-application separation, signed-image hydration and safe sharing links. `scripts/deploy-jobzone-flyers.mjs --validate` includes the existing JobZone and PDF checks and rolls every synthetic record and Storage metadata row back.
