export const UNITS = {
  consultancy: {
    name: "USSE Consultancy",
    services:
      "strategy consultancy, strategic research, brainstorming, real estate advisory and virtual consultations",
  },
  ajm: {
    name: "AJM – Aloe Jamaica",
    services:
      "creative direction, branding, digital design, campaign graphics, presentation assets, directory advertising and paid business webpages",
  },
  pistol: {
    name: "PISTOL",
    services:
      "operations support, HR structure, logistics planning, administration and workflow coordination",
  },
};
export const ACKS = {
  commission:
    "I understand the commission structure, qualifying referral requirements and payment timing stated in this agreement.",
  independent:
    "I am an independent referral partner. I cannot bind USSE, negotiate prices, promise outcomes or collect client payments.",
  conduct:
    "I agree to the conduct, confidentiality, data protection and branding terms in this agreement.",
  signature:
    "I have read this agreement. This electronic signature is mine and I intend to accept its terms.",
};
export const escapeHtml = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
export const money = (value, currency = "JMD") =>
  new Intl.NumberFormat("en-JM", { style: "currency", currency }).format(
    Number(value || 0),
  );
export function validateSnapshot(s) {
  for (const key of [
    "company_name",
    "company_signer",
    "company_position",
    "company_email",
    "partner_name",
    "partner_email",
    "partner_address",
    "partner_phone",
    "effective_date",
  ]) {
    if (!String(s[key] || "").trim())
      throw new Error(`Please complete ${key.replaceAll("_", " ")}.`);
    if (String(s[key]).length > 500)
      throw new Error("A contact field is too long.");
  }
  for (const key of ["company_email", "partner_email"])
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s[key]))
      throw new Error("Enter valid email addresses.");
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(s.effective_date) ||
    !Number.isFinite(Date.parse(s.effective_date))
  )
    throw new Error("Choose an effective date.");
  if (!s.units?.length || s.units.some((u) => !UNITS[u]))
    throw new Error("Choose at least one USSE subsidiary.");
  if (
    !["JMD", "USD"].includes(s.currency) ||
    !["percentage", "flat", "tiered"].includes(s.commission_mode)
  )
    throw new Error("Choose a valid currency and commission structure.");
  for (const [key, max] of [
    ["commission_percent", 100],
    ["flat_amount", 1e8],
    ["threshold_amount", 1e10],
    ["payment_days", 365],
    ["notice_days", 365],
  ]) {
    if (!Number.isFinite(s[key]) || s[key] < 0 || s[key] > max)
      throw new Error(`Enter a valid ${key.replaceAll("_", " ")}.`);
  }
  if (
    !Number.isInteger(s.payment_days) ||
    !Number.isInteger(s.notice_days) ||
    s.payment_days < 1
  )
    throw new Error("Payment and notice days must be whole numbers.");
  if (s.commission_mode === "tiered" && s.threshold_amount <= 0)
    throw new Error("The tier threshold must be greater than zero.");
  if (
    (s.commission_mode === "percentage" && s.commission_percent <= 0) ||
    (s.commission_mode === "flat" && s.flat_amount <= 0) ||
    (s.commission_mode === "tiered" &&
      s.flat_amount <= 0 &&
      s.commission_percent <= 0)
  )
    throw new Error("Set the commission rate before creating an agreement.");
  if (String(s.additional_terms || "").length > 6000)
    throw new Error("Additional terms must be under 6,000 characters.");
  if (!isPng(s.company_signature))
    throw new Error(
      "Upload the company signature in Settings before creating an agreement.",
    );
  return s;
}
export function isPng(value) {
  return (
    typeof value === "string" &&
    value.length <= 400000 &&
    /^data:image\/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$/.test(value)
  );
}
export function calculateCommission(s, projectValue, received, refunded = 0) {
  const net = Math.max(0, Number(received) - Number(refunded));
  if (!net) return 0;
  const tierFlat =
    s.commission_mode === "flat" ||
    (s.commission_mode === "tiered" &&
      Number(projectValue) < s.threshold_amount);
  const result = tierFlat
    ? net >= Number(projectValue)
      ? s.flat_amount
      : 0
    : (net * s.commission_percent) / 100;
  return Math.round(result * 100) / 100;
}
export function commissionText(s) {
  const flat = `${money(s.flat_amount, s.currency)} per fully paid qualifying referral`;
  const percent = `${s.commission_percent}% of qualifying cleared receipts, excluding refunds, reversals, chargebacks and unpaid amounts`;
  return s.commission_mode === "flat"
    ? flat
    : s.commission_mode === "percentage"
      ? percent
      : `${flat} for contracted values below ${money(s.threshold_amount, s.currency)}; ${percent} for contracted values at or above that threshold`;
}
export function agreementSections(s) {
  const sections = [
    [
      "1. Purpose and covered services",
      `The partner may introduce genuine prospective clients for ${s.units.map((u) => UNITS[u].name).join(", ")}. Covered services: ${s.units.map((u) => UNITS[u].services).join("; ")}. The Company decides whether to accept any opportunity.`,
    ],
    [
      "2. Partner responsibilities",
      "Find legitimate leads, make introductions and provide accurate information. Obtain permission before sharing client contact details. Do not make guarantees, misrepresent services, negotiate prices, sign on behalf of the Company or collect client payments. Refer opportunities through the Company’s approved contact channels.",
    ],
    [
      "3. Commission structure",
      commissionText(s) +
        ". Commission applies to qualifying work under the covered subsidiaries, in the agreement currency. Different currencies require a written conversion agreement. Flat commissions are payable once per fully paid referral; percentage commissions accrue as cleared receipts are recorded.",
    ],
    [
      "4. When a referral qualifies",
      "The introduction must be documented and attributed to this partner, relate to a new opportunity not already actively pursued by the Company, lead to an accepted quotation or engagement and result in cleared payment. Duplicate claims are resolved using evidence of the original introduction. A contact name alone does not earn commission.",
    ],
    [
      "5. Payment, refunds and expenses",
      `Earned commission is normally payable within ${s.payment_days} business days after the qualifying payment clears. Unpaid, cancelled, fraudulent, refunded or charged-back amounts do not qualify. Overpaid commission may be recovered or offset against future earnings. The partner supplies accurate payout details and pays their own expenses unless approved in writing beforehand.`,
    ],
    [
      "6. Independent relationship and authority",
      "This is a non-exclusive independent referral relationship. It creates no employment, partnership, joint venture or agency. Only the Company may quote, price, discount, contract or approve payment plans. Client payments go directly to Company-approved accounts. The partner is responsible for their own applicable tax obligations.",
    ],
    [
      "7. Confidentiality and client information",
      "Use business and personal information only for legitimate referrals. Do not sell, misuse or disclose client details or confidential pricing, processes or proposals. Confidentiality continues after termination. Both parties shall handle personal information responsibly.",
    ],
    [
      "8. Fair dealing and professional conduct",
      "Neither party may divert a documented opportunity or deny properly earned commission to avoid this agreement. Fraud, harassment, misleading advertising and unauthorized promises are prohibited. Company branding and materials may be used only with permission and remain the owner’s property.",
    ],
    [
      "9. Term, termination and changes",
      `This agreement starts on ${s.effective_date} and continues until terminated. Either party may give ${s.notice_days} days’ written notice. The Company may terminate immediately for fraud, serious misconduct, unlawful conduct or material breach. Properly earned commission on qualifying prior referrals remains payable. Changes must be agreed in writing and cannot retroactively reduce earned commission.`,
    ],
    [
      "10. Disputes and entire agreement",
      "The parties shall first attempt to resolve a disagreement in good faith. Jamaican law governs this agreement. This document and its additional terms are the complete agreement for this referral relationship. If one provision is unenforceable, the others remain effective to the extent permitted by applicable law.",
    ],
    [
      "11. Electronic acceptance",
      "The parties agree to electronic signatures and transmitted copies as evidence of acceptance to the extent permitted by applicable law. The signer must review and affirm all acknowledgements before signing.",
    ],
  ];
  if (s.additional_terms)
    sections.push(["12. Additional agreed terms", s.additional_terms]);
  return sections;
}
export function agreementHtml(contract) {
  const s = contract.snapshot,
    e = escapeHtml;
  const sections = s.document_sections || agreementSections(s);
  return `<article class="agreement"><div class="document-brand">USSE / PARTNER PROGRAMME</div><h1>Referral Partner<br>Commission Agreement</h1><p class="document-ref">${e(contract.reference || "DRAFT")} · ${e(contract.status || "draft")} · Template ${e(s.template_version || "usse-referral-v1")}</p><div class="parties"><div><small>THE COMPANY</small><h3>${e(s.company_name)}</h3><p>${e(s.company_signer)} · ${e(s.company_position)}<br>${e(s.company_email)}</p></div><div><small>THE REFERRAL PARTNER</small><h3>${e(s.partner_name)}</h3><p>${e(s.partner_email)}<br>${e(s.partner_address)}<br>${e(s.partner_phone)}</p></div></div><p>Effective date: <strong>${e(s.effective_date)}</strong></p>${sections.map(([title, body]) => `<section><h2>${e(title)}</h2><p>${e(body)}</p></section>`).join("")}<div class="signatures"><section><h2>For the Company</h2><img class="signature-image" src="${isPng(s.company_signature) ? s.company_signature : ""}" alt="Company signature"><p>${e(s.company_signer)}<br>${e(s.company_position)}</p></section><section><h2>Referral partner</h2>${isPng(contract.partner_signature) ? `<img class="signature-image" src="${contract.partner_signature}" alt="Partner signature">` : "<p>Awaiting signature</p>"}<p>${e(contract.signer_name || s.partner_name)}${contract.signed_at ? `<br>Signed ${e(new Date(contract.signed_at).toLocaleString("en-JM", { timeZone: "America/Jamaica" }))} (Jamaica)` : ""}</p></section></div>${
    contract.signed_at
      ? `<h2>Recorded acknowledgements</h2>${Object.entries(ACKS)
          .map(
            ([key, label]) =>
              `<p>${contract.acknowledgements?.[key] === true ? "✓" : "—"} ${e(label)}</p>`,
          )
          .join("")}`
      : ""
  }</article>`;
}
export async function newSigningToken() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}
export async function signatureFromFile(file) {
  if (
    !file ||
    !["image/png", "image/webp"].includes(file.type) ||
    file.size > 2000000
  )
    throw new Error(
      "Choose a PNG or WebP signature under 2 MB, with a transparent background.",
    );
  const bitmap = await createImageBitmap(file);
  try {
    if (bitmap.width * bitmap.height > 16000000)
      throw new Error("The image dimensions are too large.");
    const canvas = document.createElement("canvas");
    const scale = Math.min(1, 1000 / bitmap.width, 350 / bitmap.height);
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    const ctx = canvas.getContext("2d");
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    let ink = false,
      transparent = false;
    for (let i = 0; i < pixels.length; i += 4) {
      if (pixels[i + 3] < 250) transparent = true;
      if (
        pixels[i + 3] > 20 &&
        Math.min(pixels[i], pixels[i + 1], pixels[i + 2]) < 230
      )
        ink = true;
    }
    if (!ink) throw new Error("The image has no visible signature.");
    const data = canvas.toDataURL("image/png");
    if (!isPng(data))
      throw new Error("The signature is too large. Try a smaller image.");
    return { data, transparent };
  } finally {
    bitmap.close();
  }
}
