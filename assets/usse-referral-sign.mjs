import {
  ACKS,
  escapeHtml,
  agreementHtml,
  signatureFromFile,
  isPng,
} from "./usse-referral-core.mjs";
import {
  supabase,
  $,
  notice,
  friendlyError,
  downloadCopy,
  busy,
} from "./usse-referral-shared.mjs";
// Keep bearer tokens in the URL fragment so hosting logs and referrers never receive them.
const token = location.hash.slice(1);
let agreement = null,
  uploaded = "",
  drawn = false,
  activePointer = null,
  previous = null;
const canvas = $("signature-pad"),
  ctx = canvas.getContext("2d");
ctx.lineWidth = 3;
ctx.lineCap = "round";
ctx.strokeStyle = "#172134";
function position(event) {
  const box = canvas.getBoundingClientRect();
  return {
    x: ((event.clientX - box.left) * canvas.width) / box.width,
    y: ((event.clientY - box.top) * canvas.height) / box.height,
  };
}
canvas.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  activePointer = event.pointerId;
  canvas.setPointerCapture(activePointer);
  previous = position(event);
});
canvas.addEventListener("pointermove", (event) => {
  if (activePointer !== event.pointerId) return;
  const next = position(event);
  if (Math.hypot(next.x - previous.x, next.y - previous.y) > 1) {
    ctx.beginPath();
    ctx.moveTo(previous.x, previous.y);
    ctx.lineTo(next.x, next.y);
    ctx.stroke();
    drawn = true;
    uploaded = "";
    $("partner-signature-preview").hidden = true;
    $("partner-signature").value = "";
  }
  previous = next;
});
for (const eventName of ["pointerup", "pointercancel", "lostpointercapture"])
  canvas.addEventListener(eventName, () => {
    activePointer = null;
    previous = null;
  });
$("clear-signature").addEventListener("click", () => {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  drawn = false;
  uploaded = "";
  $("partner-signature").value = "";
  $("partner-signature-preview").hidden = true;
  $("partner-signature-note").textContent = "";
});
$("partner-signature").addEventListener("change", async (event) => {
  try {
    const result = await signatureFromFile(event.target.files[0]);
    uploaded = result.data;
    drawn = false;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    $("partner-signature-preview").src = uploaded;
    $("partner-signature-preview").hidden = false;
    $("partner-signature-note").textContent = result.transparent
      ? "Transparent background detected."
      : "Please keep the signature background transparent for a cleaner copy.";
  } catch (error) {
    $("partner-signature-note").textContent = error.message;
    event.target.value = "";
  }
});
function render() {
  $("agreement-document").innerHTML = agreementHtml(agreement);
  const signed = agreement.status === "signed";
  $("sign-form").hidden = signed;
  $("signed-actions").hidden = !signed;
  notice(
    signed
      ? "Agreement signed. You can download your copy or save it as a PDF."
      : `Review every section before signing. Link expires ${new Date(agreement.expires_at).toLocaleString("en-JM", { timeZone: "America/Jamaica" })} (Jamaica).`,
  );
}
$("sign-form").addEventListener("submit", (event) => {
  event.preventDefault();
  busy(
    event.currentTarget,
    async () => {
      const signature =
        uploaded || (drawn ? canvas.toDataURL("image/png") : "");
      if (!isPng(signature))
        throw new Error("Draw or upload your signature first.");
      const acknowledgements = Object.fromEntries(
        Object.keys(ACKS).map((key) => [key, $(`ack-${key}`).checked]),
      );
      if (Object.values(acknowledgements).some((v) => !v))
        throw new Error("Confirm every acknowledgement.");
      const { data, error } = await supabase.rpc("sign_referral_agreement", {
        p_token: token,
        p_name: $("signer-name").value.trim(),
        p_email: $("signer-email").value.trim(),
        p_signature: signature,
        p_acknowledgements: acknowledgements,
      });
      if (error) throw error;
      agreement = data;
      render();
      $("notice").scrollIntoView({ behavior: "smooth" });
    },
    "sign-error",
  );
});
$("download-copy").addEventListener("click", () =>
  busy($("signed-actions"), () => downloadCopy(agreement)),
);
$("print-copy").addEventListener("click", () => window.print());
async function init() {
  try {
    if (!/^[a-f0-9]{64}$/.test(token))
      throw new Error(
        "This signing link is invalid. Contact USSE for the complete link.",
      );
    const { data, error } = await supabase.rpc("get_referral_agreement", {
      p_token: token,
    });
    if (error) throw error;
    agreement = data;
    $("signer-name").value = agreement.snapshot.partner_name;
    $("signer-email").value = agreement.snapshot.partner_email;
    $("acknowledgements").innerHTML = Object.entries(ACKS)
      .map(
        ([key, text]) =>
          `<label><input id="ack-${key}" type="checkbox" required> <span>${escapeHtml(text)}</span></label>`,
      )
      .join("");
    render();
  } catch (error) {
    notice(friendlyError(error), true);
  }
}
init();
