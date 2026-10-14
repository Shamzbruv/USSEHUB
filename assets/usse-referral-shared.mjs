import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.108.2/+esm";
import { agreementHtml, escapeHtml } from "./usse-referral-core.mjs";
export const supabase = createClient(
  "https://zcptuqrlovflcpqszery.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpjcHR1cXJsb3ZmbGNwcXN6ZXJ5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMDMxMzcsImV4cCI6MjA5NTU3OTEzN30.kl9BwGqwWEVWYtxYWrG7xigK_EOGZxLQBNbZZp7tfPw",
);
export const $ = (id) => document.getElementById(id);
export function notice(message, error = false) {
  $("notice").textContent = message;
  $("notice").classList.toggle("error", error);
  $("notice").hidden = false;
}
export async function rpc(action, payload) {
  const { data, error } = await supabase.rpc("admin_manage_referrals", {
    p_action: action,
    p_payload: payload,
  });
  if (error) throw error;
  return data;
}
export function friendlyError(error) {
  if (["42P01", "PGRST202", "PGRST205", "42883"].includes(error.code))
    return "Referral programme setup is pending. The USSE database migration must be applied before this feature can be used.";
  return error.message || "The request failed. Please try again.";
}
export async function downloadCopy(contract) {
  const response = await fetch("./assets/usse-referrals.css");
  if (!response.ok)
    throw new Error(
      "Could not load the document styling. Please use Print / Save PDF.",
    );
  const css = await response.text();
  const source = `<!doctype html><html lang="en-JM"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(contract.reference || "USSE draft")}</title><style>${css}body{background:white}main{max-width:900px}.agreement{border-radius:0}</style></head><body><main>${agreementHtml(contract)}</main></body></html>`;
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([source], { type: "text/html" }));
  link.download = `${contract.reference || "USSE-referral-draft"}.html`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}
export async function busy(form, action, errorId) {
  const buttons = [...form.querySelectorAll("button")];
  buttons.forEach((b) => (b.disabled = true));
  if (errorId) $(errorId).textContent = "";
  try {
    return await action();
  } catch (error) {
    if (errorId) $(errorId).textContent = friendlyError(error);
    else notice(friendlyError(error), true);
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}
