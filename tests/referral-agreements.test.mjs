process.on("uncaughtException", (error) => {
  console.error(
    error.message,
    error.detail || "",
    error.where || "",
    error.position || "",
  );
  process.exit(1);
});
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";
import {
  UNITS,
  ACKS,
  validateSnapshot,
  agreementSections,
  agreementHtml,
  calculateCommission,
  newSigningToken,
} from "../assets/usse-referral-core.mjs";
const signature =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
const snapshot = {
  template_version: "usse-referral-v1",
  company_name: "USSE",
  company_email: "info@ussehub.com",
  company_signer: "USSE Authorized Signer",
  company_position: "Director",
  company_signature: signature,
  partner_name: "Test Partner",
  partner_email: "partner@example.com",
  partner_address: "Kingston, Jamaica",
  partner_phone: "876-555-0123",
  effective_date: "2026-10-14",
  units: Object.keys(UNITS),
  currency: "JMD",
  commission_mode: "tiered",
  commission_percent: 5,
  flat_amount: 2000,
  threshold_amount: 120000,
  payment_days: 14,
  notice_days: 30,
  additional_terms: "",
};
snapshot.document_sections = agreementSections(snapshot);
assert.equal(validateSnapshot(snapshot), snapshot);
assert.throws(() => validateSnapshot({ ...snapshot, commission_percent: 101 }));
assert.throws(() => validateSnapshot({ ...snapshot, units: ["other"] }));
assert.throws(() =>
  validateSnapshot({
    ...snapshot,
    company_signature: "data:image/svg+xml;base64,abc",
  }),
);
assert.throws(() =>
  validateSnapshot({
    ...snapshot,
    commission_mode: "percentage",
    commission_percent: 0,
  }),
);
assert.equal(calculateCommission(snapshot, 119999, 119999), 2000);
assert.equal(calculateCommission(snapshot, 119999, 50000), 0);
assert.equal(calculateCommission(snapshot, 120000, 60000), 3000);
assert.equal(calculateCommission(snapshot, 120000, 120000, 10000), 5500);
assert.equal(calculateCommission(snapshot, 120000, 0), 0);
assert.equal(calculateCommission(snapshot, 119999, 119999, 10), 0);
const html = agreementHtml({
  snapshot: { ...snapshot, partner_name: "<script>alert(1)</script>" },
  status: "draft",
});
assert(!html.includes("<script>"));
assert(html.includes("&lt;script&gt;"));
for (const u of Object.values(UNITS)) assert(html.includes(u.services));
assert(!html.includes("iCreate"));
const token = await newSigningToken(),
  token2 = await newSigningToken();
assert.match(token, /^[a-f0-9]{64}$/);
assert.notEqual(token, token2);
const db = new PGlite();
const admin = "11111111-1111-4111-8111-111111111111",
  member = "22222222-2222-4222-8222-222222222222";
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth; CREATE SCHEMA private;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.test_uid',true),'')::uuid $$;
CREATE TABLE public.profiles(id uuid PRIMARY KEY,role text);INSERT INTO public.profiles VALUES('${admin}','admin'),('${member}','member');
CREATE FUNCTION private.is_admin(p_uid uuid) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_uid AND role='admin') $$;
CREATE FUNCTION private.require_admin(p_uid uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF p_uid IS NULL OR NOT private.is_admin(p_uid) THEN RAISE EXCEPTION 'Administrator access is required.' USING ERRCODE='42501'; END IF; END $$;
GRANT USAGE ON SCHEMA auth,private TO anon,authenticated;GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated;`);
const migration = readFileSync(
  new URL(
    "../supabase/migrations/20261014213228_usse_referral_agreements.sql",
    import.meta.url,
  ),
  "utf8",
);
await db.exec(migration);
async function role(name, id = "") {
  await db.exec(
    `RESET ROLE; SELECT set_config('request.test_uid','${id}',false); SET ROLE ${name};`,
  );
}
const rpc = async (action, payload) =>
  (
    await db.query(
      "SELECT public.admin_manage_referrals($1,$2::jsonb) AS result",
      [action, JSON.stringify(payload)],
    )
  ).rows[0].result;
const read = async (t) =>
  (await db.query("SELECT public.get_referral_agreement($1) AS result", [t]))
    .rows[0].result;
const sign = async (
  t,
  email = "partner@example.com",
  acks = Object.fromEntries(Object.keys(ACKS).map((k) => [k, true])),
) =>
  (
    await db.query(
      "SELECT public.sign_referral_agreement($1,$2,$3,$4,$5::jsonb) AS result",
      [t, "Test Partner", email, signature, JSON.stringify(acks)],
    )
  ).rows[0].result;
await role("anon");
await assert.rejects(
  db.query("SELECT * FROM public.referral_agreements"),
  /permission denied/,
);
await assert.rejects(rpc("create", { snapshot }), /permission denied/);
await assert.rejects(read("x"), /invalid/);
await role("authenticated", member);
assert.equal(
  (await db.query("SELECT * FROM public.referral_agreements")).rows.length,
  0,
);
await assert.rejects(rpc("create", { snapshot }), /Administrator/);
await assert.rejects(
  db.query(
    "INSERT INTO public.referral_program_settings(settings) VALUES('{}')",
  ),
  /permission denied/,
);
await role("authenticated", admin);
await assert.rejects(
  rpc("create", { snapshot: { ...snapshot, commission_percent: 101 } }),
  /range/,
);
const draft = await rpc("create", { snapshot });
assert.equal(draft.status, "draft");
await rpc("settings", {
  settings: { company_name: "NEW USSE NAME", company_signature: signature },
});
const issued = await rpc("issue", { id: draft.id, token });
assert.equal(issued.snapshot.company_name, "USSE");
assert(!("token_hash" in issued));
await assert.rejects(
  rpc("edit", {
    id: draft.id,
    snapshot: { ...snapshot, commission_percent: 6 },
  }),
  /Only drafts/,
);
await assert.rejects(
  db.query("UPDATE public.referral_agreements SET status='signed'"),
  /permission denied/,
);
await role("authenticated", member);
assert.equal(
  (await db.query("SELECT * FROM public.referral_agreements")).rows.length,
  0,
);
await assert.rejects(read(token2), /invalid/);
await role("anon");
const publicAgreement = await read(token);
assert.equal(publicAgreement.snapshot.company_name, "USSE");
assert(!("token_hash" in publicAgreement));
assert(!("created_by" in publicAgreement));
await assert.rejects(sign(token, "wrong@example.com"), /email/);
await assert.rejects(
  sign(token, "partner@example.com", { commission: true }),
  /acknowledgement/,
);
const signed = await sign(token);
assert.equal(signed.status, "signed");
assert(signed.signed_at);
await assert.rejects(sign(token), /already signed/);
await role("authenticated", admin);
await assert.rejects(
  rpc("issue", { id: draft.id, token: token2 }),
  /cannot be issued/,
);
await assert.rejects(rpc("cancel", { id: draft.id }), /unsigned/);
const changed = await rpc("settings", {
  settings: { company_name: "Another company", company_signature: signature },
});
assert.equal((await read(token)).snapshot.company_name, "USSE");
const ref = {
  agreement_id: draft.id,
  client_name: "Client",
  opportunity_ref: "OP-001",
  unit: "ajm",
  project_value: 120000,
  cleared_amount: 60000,
  refunded_amount: 10000,
  status: "qualified",
  notes: "Introduced by partner",
};
const r = await rpc("referral_save", ref);
assert.equal(Number(r.commission_amount), 2500);
await assert.rejects(
  rpc("referral_save", {
    ...ref,
    opportunity_ref: "OP-002",
    cleared_amount: 130000,
  }),
  /amounts/,
);
await assert.rejects(rpc("referral_save", ref), /unique constraint/);
const paid = await rpc("referral_paid", {
  id: r.id,
  payout_reference: "BANK-01",
});
assert.equal(paid.status, "paid");
await assert.rejects(rpc("referral_save", { ...ref, id: r.id }), /locked/);
await assert.rejects(
  rpc("referral_paid", { id: r.id, payout_reference: "BANK-02" }),
  /qualified/,
);
const d2 = await rpc("create", {
  snapshot: { ...snapshot, units: ["consultancy"] },
});
await rpc("issue", { id: d2.id, token: token2 });
await role("anon");
await sign(token2);
await role("authenticated", admin);
await assert.rejects(
  rpc("referral_save", {
    ...ref,
    agreement_id: d2.id,
    opportunity_ref: "OP-002",
  }),
  /outside/,
);
const d3 = await rpc("create", { snapshot });
const old = await newSigningToken(),
  fresh = await newSigningToken();
await rpc("issue", { id: d3.id, token: old });
await rpc("issue", { id: d3.id, token: fresh });
await assert.rejects(read(old), /invalid/);
assert.equal((await read(fresh)).status, "pending");
await rpc("cancel", { id: d3.id });
await assert.rejects(read(fresh), /cancelled/);
const d4 = await rpc("create", { snapshot });
const exp = await newSigningToken();
await rpc("issue", { id: d4.id, token: exp });
await db.exec(
  `RESET ROLE; UPDATE public.referral_agreements SET expires_at=now()-interval '1 minute' WHERE id='${d4.id}';`,
);
await role("anon");
await assert.rejects(read(exp), /expired/);
await assert.rejects(sign(exp), /expired/);
await role("authenticated", admin);
assert(
  (
    await db.query(
      "SELECT * FROM public.referral_audit_events WHERE action='signed'",
    )
  ).rows.length === 2,
);
await db.close();
console.log(
  "Referral tests passed: PostgreSQL migration, admin/member/anon access, immutable terms, signature validation, token rotation/expiry, repeat signing, subsidiary scope, commission thresholds/refunds, duplicate leads and payment locks.",
);
