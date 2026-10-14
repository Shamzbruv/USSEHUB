import {
  UNITS,
  escapeHtml as e,
  money,
  validateSnapshot,
  agreementSections,
  agreementHtml,
  newSigningToken,
  signatureFromFile,
  calculateCommission,
} from "./usse-referral-core.mjs";
import {
  supabase,
  $,
  notice,
  rpc,
  friendlyError,
  downloadCopy,
  busy,
} from "./usse-referral-shared.mjs";
let agreements = [],
  referrals = [],
  settings = {},
  companySignature = "",
  viewed = null;
function tab(name) {
  for (const b of document.querySelectorAll("[data-tab]"))
    b.setAttribute("aria-selected", String(b.dataset.tab === name));
  for (const n of ["agreements", "register", "settings"])
    $(`${n}-tab`).hidden = n !== name;
}
for (const b of document.querySelectorAll("[data-tab]"))
  b.addEventListener("click", () => tab(b.dataset.tab));
for (const b of document.querySelectorAll("[data-close]"))
  b.addEventListener("click", () => $(b.dataset.close).close());
async function reload() {
  const results = await Promise.all([
    supabase
      .from("referral_agreements")
      .select(
        "id,reference,snapshot,status,expires_at,issued_at,signed_at,signer_name,partner_signature,acknowledgements,created_at",
      )
      .order("created_at", { ascending: false }),
    supabase
      .from("referral_register")
      .select("*")
      .order("created_at", { ascending: false }),
    supabase
      .from("referral_program_settings")
      .select("settings")
      .eq("id", true)
      .maybeSingle(),
  ]);
  for (const r of results) if (r.error) throw r.error;
  agreements = results[0].data || [];
  referrals = results[1].data || [];
  settings = results[2].data?.settings || {};
  companySignature = settings.company_signature || "";
  for (const key of ["name", "email", "signer", "position"])
    if (settings[`company_${key}`])
      $(`company-${key}`).value = settings[`company_${key}`];
  $("company-signature-preview").src = companySignature;
  $("company-signature-preview").hidden = !companySignature;
  $("count-all").textContent = agreements.length;
  $("count-pending").textContent = agreements.filter(
    (a) => a.status === "pending",
  ).length;
  $("count-signed").textContent = agreements.filter(
    (a) => a.status === "signed",
  ).length;
  $("count-referrals").textContent = referrals.length;
  renderAgreements();
  renderReferrals();
}
function renderAgreements() {
  const q = $("search").value.toLowerCase(),
    status = $("status-filter").value;
  const rows = agreements.filter(
    (a) =>
      (!status || a.status === status) &&
      `${a.reference} ${a.snapshot.partner_name} ${a.snapshot.partner_email}`
        .toLowerCase()
        .includes(q),
  );
  $("agreements-list").innerHTML = rows.length
    ? `<div class="table-wrap"><table><thead><tr><th>Partner / agreement</th><th>Subsidiaries</th><th>Status</th><th>Actions</th></tr></thead><tbody>${rows.map((a) => `<tr><td><strong>${e(a.snapshot.partner_name)}</strong><br><small>${e(a.snapshot.partner_email)}<br>${e(a.reference)}</small></td><td>${a.snapshot.units.map((u) => e(UNITS[u].name)).join("<br>")}</td><td><span class="badge ${e(a.status)}">${e(a.status)}</span>${a.status === "pending" && Date.parse(a.expires_at) <= Date.now() ? "<br><small>Link expired</small>" : ""}</td><td><div class="actions"><button data-action="view" data-id="${a.id}">View</button>${a.status === "draft" ? `<button data-action="edit" data-id="${a.id}">Edit</button>` : ""}${["draft", "pending"].includes(a.status) ? `<button data-action="issue" data-id="${a.id}">${a.status === "draft" ? "Issue signing link" : "New signing link"}</button><button class="danger" data-action="cancel" data-id="${a.id}">Cancel</button>` : ""}</div></td></tr>`).join("")}</tbody></table></div>`
    : '<div class="empty">No agreements found. Add the company signature, then create your first referral agreement.</div>';
}
$("search").addEventListener("input", renderAgreements);
$("status-filter").addEventListener("change", renderAgreements);
$("agreements-list").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-action]");
  if (!button) return;
  const a = agreements.find((a) => a.id === button.dataset.id);
  if (!a) return;
  if (button.dataset.action === "view") return view(a);
  if (button.dataset.action === "edit") return editor(a);
  if (
    button.dataset.action === "cancel" &&
    !confirm("Cancel this unsigned agreement and disable its signing link?")
  )
    return;
  if (
    button.dataset.action === "issue" &&
    a.status === "pending" &&
    !confirm(
      "Create a new link? The previous signing link will stop working. The agreement terms remain fixed.",
    )
  )
    return;
  await busy($("agreements-tab"), async () => {
    if (button.dataset.action === "cancel") {
      await rpc("cancel", { id: a.id });
      notice("Agreement cancelled.");
    } else {
      const token = await newSigningToken();
      await rpc("issue", { id: a.id, token });
      const url = new URL("./sign-referral-agreement", location.href);
      url.hash = token;
      $("signing-link").value = url.href;
      $("open-link").href = url.href;
      $("link-dialog").showModal();
      notice("Signing link created. Share it with the intended partner.");
    }
    await reload();
  });
});
async function view(a) {
  viewed = a;
  $("agreement-document").innerHTML = agreementHtml(a);
  $("agreement-audit").textContent = "";
  $("viewer").showModal();
  if (a.id) {
    const { data, error } = await supabase
      .from("referral_audit_events")
      .select("action,created_at,detail")
      .eq("agreement_id", a.id)
      .order("created_at", { ascending: true });
    $("agreement-audit").innerHTML = error
      ? `<p>${e(friendlyError(error))}</p>`
      : `<h3 style="margin-top:24px">Activity record</h3>${data.map((ev) => `<p><strong>${e(ev.action)}</strong> · ${e(new Date(ev.created_at).toLocaleString("en-JM"))}${ev.detail?.payout_reference ? ` · ${e(ev.detail.payout_reference)}` : ""}</p>`).join("")}`;
  }
}
$("download-copy").addEventListener("click", () =>
  busy($("viewer"), () => downloadCopy(viewed)),
);
$("print-copy").addEventListener("click", () => window.print());
$("copy-link").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("signing-link").value);
    $("copy-link").textContent = "Copied";
  } catch {
    $("signing-link").select();
    $("copy-link").textContent = "Select & copy the link";
  }
});
function modeFields() {
  const mode = $("commission-mode").value;
  $("percent-field").hidden = mode === "flat";
  $("flat-field").hidden = mode === "percentage";
  $("threshold-field").hidden = mode !== "tiered";
  $("commission-percent").required = mode !== "flat";
  $("flat-amount").required = mode !== "percentage";
  $("threshold-amount").required = mode === "tiered";
}
$("commission-mode").addEventListener("change", modeFields);
function editor(a = null) {
  if (!settings.company_signature) {
    tab("settings");
    notice("Save USSE’s company details and authorized signature first.");
    return;
  }
  $("agreement-form").reset();
  $("agreement-id").value = a?.id || "";
  $("editor-title").textContent = a
    ? "Edit draft agreement"
    : "New referral agreement";
  $("editor-error").textContent = "";
  if (a) {
    const s = a.snapshot;
    for (const key of [
      "partner_name",
      "partner_email",
      "partner_address",
      "partner_phone",
      "effective_date",
      "currency",
      "commission_mode",
      "commission_percent",
      "flat_amount",
      "threshold_amount",
      "payment_days",
      "notice_days",
      "additional_terms",
    ])
      $(key.replaceAll("_", "-")).value = s[key] ?? "";
    for (const c of document.querySelectorAll("[name=unit]"))
      c.checked = s.units.includes(c.value);
  } else
    $("effective-date").value = new Date().toLocaleDateString("en-CA", {
      timeZone: "America/Jamaica",
    });
  modeFields();
  $("editor").showModal();
}
$("new-agreement").addEventListener("click", () => editor());
function snapshotFromForm() {
  const existing = agreements.find((a) => a.id === $("agreement-id").value);
  const s = {
    ...(existing?.snapshot || settings),
    template_version: "usse-referral-v1",
  };
  for (const key of [
    "partner_name",
    "partner_email",
    "partner_address",
    "partner_phone",
    "effective_date",
    "currency",
    "commission_mode",
    "additional_terms",
  ])
    s[key] = $(key.replaceAll("_", "-")).value.trim();
  for (const key of [
    "commission_percent",
    "flat_amount",
    "threshold_amount",
    "payment_days",
    "notice_days",
  ])
    s[key] = Number($(key.replaceAll("_", "-")).value || 0);
  s.units = [...document.querySelectorAll("[name=unit]:checked")].map(
    (c) => c.value,
  );
  validateSnapshot(s);
  s.document_sections = agreementSections(s);
  return s;
}
$("agreement-form").addEventListener("submit", (event) => {
  event.preventDefault();
  busy(
    event.currentTarget,
    async () => {
      const snapshot = snapshotFromForm(),
        id = $("agreement-id").value;
      await rpc(id ? "edit" : "create", { id, snapshot });
      await reload();
      $("editor").close();
      notice("Draft saved. Review it, then issue the signing link.");
    },
    "editor-error",
  );
});
$("preview-draft").addEventListener("click", () => {
  try {
    view({ snapshot: snapshotFromForm(), status: "draft" });
  } catch (error) {
    $("editor-error").textContent = error.message;
  }
});
$("company-signature").addEventListener("change", async (event) => {
  try {
    const result = await signatureFromFile(event.target.files[0]);
    companySignature = result.data;
    $("company-signature-preview").src = companySignature;
    $("company-signature-preview").hidden = false;
    $("signature-note").textContent = result.transparent
      ? "Transparent background detected."
      : "This image has an opaque background. Please upload a transparent version for a cleaner agreement.";
  } catch (error) {
    $("signature-note").textContent = error.message;
    event.target.value = "";
  }
});
$("settings-form").addEventListener("submit", (event) => {
  event.preventDefault();
  busy(event.currentTarget, async () => {
    if (!companySignature)
      throw new Error("Upload the authorized company signature.");
    const s = { company_signature: companySignature };
    for (const key of ["name", "email", "signer", "position"])
      s[`company_${key}`] = $(`company-${key}`).value.trim();
    await rpc("settings", { settings: s });
    await reload();
    notice("Company details saved. These will be used for new agreements.");
  });
});
function renderReferrals() {
  $("referrals-list").innerHTML = referrals.length
    ? `<div class="table-wrap"><table><thead><tr><th>Client / opportunity</th><th>Partner / subsidiary</th><th>Cleared / refunded</th><th>Commission</th><th>Status / actions</th></tr></thead><tbody>${referrals
        .map((r) => {
          const a = agreements.find((a) => a.id === r.agreement_id),
            currency = a?.snapshot.currency || "JMD";
          return `<tr><td><strong>${e(r.client_name)}</strong><br><small>${e(r.opportunity_ref)}</small></td><td>${e(a?.snapshot.partner_name)}<br><small>${e(UNITS[r.unit].name)}</small></td><td>${e(money(r.cleared_amount, currency))}<br><small>Refunded ${e(money(r.refunded_amount, currency))}</small></td><td>${e(money(r.commission_amount, currency))}</td><td><span class="badge ${e(r.status)}">${e(r.status)}</span><div class="actions">${r.status !== "paid" ? `<button data-referral-action="edit" data-id="${r.id}">Edit</button>` : `<small>${e(r.payout_reference)}</small>`}${r.status === "qualified" && Number(r.commission_amount) > 0 ? `<button data-referral-action="paid" data-id="${r.id}">Record payment</button>` : ""}</div></td></tr>`;
        })
        .join("")}</tbody></table></div>`
    : '<div class="empty">No referrals registered. A signed partner agreement is required.</div>';
}
function referralScope() {
  const a = agreements.find((a) => a.id === $("referral-agreement").value);
  $("referral-unit").innerHTML = (a?.snapshot.units || [])
    .map((u) => `<option value="${u}">${e(UNITS[u].name)}</option>`)
    .join("");
  estimate();
}
function estimate() {
  const a = agreements.find((a) => a.id === $("referral-agreement").value);
  $("commission-estimate").textContent = a
    ? money(
        calculateCommission(
          a.snapshot,
          Number($("project-value").value),
          Number($("cleared-amount").value),
          Number($("refunded-amount").value),
        ),
        a.snapshot.currency,
      )
    : "—";
}
function referralEditor(r = null) {
  const signed = agreements.filter((a) => a.status === "signed");
  if (!signed.length) {
    notice(
      "A partner must sign an agreement before referrals can be registered.",
    );
    return;
  }
  $("referral-form").reset();
  $("referral-id").value = r?.id || "";
  $("referral-error").textContent = "";
  $("referral-agreement").innerHTML = signed
    .map(
      (a) =>
        `<option value="${a.id}">${e(a.snapshot.partner_name)} · ${e(a.reference)} · ${e(a.snapshot.currency)}</option>`,
    )
    .join("");
  if (r) $("referral-agreement").value = r.agreement_id;
  referralScope();
  if (r)
    for (const key of [
      "client_name",
      "opportunity_ref",
      "unit",
      "status",
      "project_value",
      "cleared_amount",
      "refunded_amount",
      "notes",
    ])
      $(
        key === "unit"
          ? "referral-unit"
          : key === "status"
            ? "referral-status"
            : key === "notes"
              ? "referral-notes"
              : key.replaceAll("_", "-"),
      ).value = r[key];
  estimate();
  $("referral-editor").showModal();
}
$("new-referral").addEventListener("click", () => referralEditor());
$("referral-agreement").addEventListener("change", referralScope);
for (const id of ["project-value", "cleared-amount", "refunded-amount"])
  $(id).addEventListener("input", estimate);
$("referral-form").addEventListener("submit", (event) => {
  event.preventDefault();
  busy(
    event.currentTarget,
    async () => {
      const payload = {
        id: $("referral-id").value,
        agreement_id: $("referral-agreement").value,
        unit: $("referral-unit").value,
        status: $("referral-status").value,
        notes: $("referral-notes").value,
      };
      for (const key of ["client_name", "opportunity_ref"])
        payload[key] = $(key.replaceAll("_", "-")).value;
      for (const key of ["project_value", "cleared_amount", "refunded_amount"])
        payload[key] = Number($(key.replaceAll("_", "-")).value);
      await rpc("referral_save", payload);
      await reload();
      $("referral-editor").close();
      notice("Referral saved. Commission calculated from the signed terms.");
    },
    "referral-error",
  );
});
$("referrals-list").addEventListener("click", (event) => {
  const b = event.target.closest("[data-referral-action]");
  if (!b) return;
  const r = referrals.find((r) => r.id === b.dataset.id);
  if (b.dataset.referralAction === "edit") return referralEditor(r);
  const payout_reference = prompt(
    "Enter the reference for the commission payment already made:",
  );
  if (!payout_reference) return;
  busy($("register-tab"), async () => {
    await rpc("referral_paid", { id: r.id, payout_reference });
    await reload();
    notice("External commission payment recorded.");
  });
});
async function init() {
  try {
    const {
      data: { user },
      error,
    } = await supabase.auth.getUser();
    if (error || !user)
      throw new Error(
        "Sign in to the USSE admin platform, then return to Referral Agreements.",
      );
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    if (profileError || profile?.role !== "admin")
      throw new Error("Administrator access is required.");
    await reload();
    $("workspace").hidden = false;
    $("new-agreement").disabled = false;
    notice(
      settings.company_signature
        ? "Programme ready. Create a draft or manage your existing partners."
        : "Start by saving the company identity and signature.",
    );
    if (!settings.company_signature) tab("settings");
  } catch (error) {
    notice(friendlyError(error), true);
  }
}
init();
