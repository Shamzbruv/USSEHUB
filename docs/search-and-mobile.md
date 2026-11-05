# Search presentation and mobile directory

The public origin is https://ussehub.com. All six public landing pages now have unique titles/descriptions, consistent brand metadata and social previews. Contact forms and dialogs are excluded from snippets. Private workspaces use noindex. Google ultimately chooses snippets, titles, site names and sitelinks; deployment does not instantly update search results.

`npm start` runs `server.mjs`, preserving serve.json rewrites and PWA headers. It renders `/jobs`, paginated results and individual `/jobs/<id>/<slug>` pages from the existing anonymous published-vacancy RPC. No privileged database credentials are required. Legacy job links redirect. Public data is explicitly selected, closed/expired jobs return 404, and temporary data-service failures return 503 with Retry-After instead of indexing an empty error page.

JobPosting structured data appears only on complete individual employer vacancies with an explicitly stated country. Image-only flyers remain readable shareable pages without invented job details, salary, employer logos or JobPosting markup. Application permissions remain enforced by existing Supabase functions and Storage policies. Flyer images are proxied only from the existing published-vacancy storage path, with signed access, MIME/size checks and a short cache.

The sitemap is an index of static public pages and 25-vacancy partitions. It excludes drafts, private applicant data and expired vacancies. Optional lastmod is emitted only for a real updated_at value. No artificial publication dates are used. Filtered results are noindex/follow.

Directory table cells retain native table layout on larger screens. The business logo/text flex layout is nested inside the first cell, so row borders line up. At 760px and below, each listing becomes one complete card with labeled services, location and contact fields, wrapping text and accessible tap targets. The WhatsApp control becomes compact to avoid covering content. Shared navigation, homepage cards and job pages adapt to narrow screens.

Validation: `npm test`, including SEO schema/escaping/routes, public data allowlisting, sitemaps, flyer isolation, outage behavior, existing application/privacy workflows and production route/PWA checks. Live Google reindexing is outside this test suite.

After deployment, a verified Search Console owner can submit https://ussehub.com/sitemap.xml and request indexing for the homepage, jobs page and important landing pages. Use URL Inspection and Rich Results Test on a real complete published job. No Search Console account or verification tokens are introduced by this update.
