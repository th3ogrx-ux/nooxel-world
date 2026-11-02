// Double authentification (application d'authentification, code à 6 chiffres) pour un compte normal.
// Activer : QR code + premier code. Désactiver : on redemande un code. Utilisé par « Mon compte » et « Modifier mon profil ».
async function mfaFactor() { const { data } = await sb.auth.mfa.listFactors(); return (data && data.totp || []).find((f) => f.status === "verified") || null; }
function sheet(...kids) {
  const old = document.getElementById("sheet2"); if (old) old.remove();
  const d = el("dialog", { class: "sheet2", id: "sheet2" }, el("div", {}, ...kids)); document.body.append(d); d.showModal();
  d.addEventListener("click", (e) => { if (e.target === d) d.close(); }); d.addEventListener("close", () => d.remove()); return d;
}
function codeBox(onSubmit, label) {
  const input = el("input", { type: "text", inputmode: "numeric", autocomplete: "one-time-code", maxlength: 6, placeholder: "000000", id: "mfa-code", "aria-label": "Code à 6 chiffres" });
  const err = el("p", { class: "msg", id: "mfa-err" }); const go = el("button", { class: "b", type: "button", id: "mfa-go", text: label });
  go.addEventListener("click", async () => { err.textContent = ""; if (!/^\d{6}$/.test(input.value.trim())) { err.textContent = "Entrez les 6 chiffres affichés par l'application."; return; } go.disabled = true; try { await onSubmit(input.value.trim()); } catch (e) { err.textContent = /invalid|expired/i.test(String(e && e.message)) ? "Code incorrect ou expiré. Réessayez." : "Vérification impossible pour le moment."; } go.disabled = false; });
  return { input, err, go };
}
// Renvoie true si la double authentification est active à la fin.
async function enableMfa() {
  const f0 = await sb.auth.mfa.listFactors(); for (const x of (f0.data && f0.data.all) || []) if (x.status !== "verified") await sb.auth.mfa.unenroll({ factorId: x.id });      // restes d'une configuration abandonnée
  const { data, error } = await sb.auth.mfa.enroll({ factorType: "totp", issuer: "Nooxel World", friendlyName: "Nooxel " + Date.now() }); if (error) throw error;
  return new Promise((done) => {
    const box = codeBox(async (code) => { const r = await sb.auth.mfa.challengeAndVerify({ factorId: data.id, code }); if (r.error) throw r.error; d.close(); done(true); }, "Activer");
    const d = sheet(el("h3", { text: "Activer la double authentification" }), el("p", { text: "1. Installez une application d'authentification (Google Authenticator, Microsoft Authenticator, Authy…). 2. Scannez ce QR code. 3. Saisissez le code à 6 chiffres affiché." }),
      el("img", { class: "qr", id: "mfa-qr", alt: "QR code à scanner", src: data.totp.qr_code }), el("p", { text: "Impossible de scanner ? Saisissez cette clé :" }), el("div", { class: "secret", id: "mfa-secret", text: data.totp.secret }),
      box.input, box.err, box.go, el("button", { class: "b g", type: "button", text: "Annuler", onclick: () => d.close() }));
    d.addEventListener("close", () => done(false), { once: true });
  });
}
async function disableMfa(factor) {
  return new Promise((done) => {
    const box = codeBox(async (code) => {
      const ch = await sb.auth.mfa.challengeAndVerify({ factorId: factor.id, code }); if (ch.error) throw ch.error;
      const r = await sb.auth.mfa.unenroll({ factorId: factor.id }); if (r.error) throw r.error; d.close(); done(true);
    }, "Désactiver");
    const d = sheet(el("h3", { text: "Désactiver la double authentification" }), el("p", { text: "Saisissez le code à 6 chiffres de votre application pour confirmer." }), box.input, box.err, box.go, el("button", { class: "b g", type: "button", text: "Annuler", onclick: () => d.close() }));
    d.addEventListener("close", () => done(false), { once: true });
  });
}
// Interrupteur : sw = bouton role=switch. Met à jour son état et appelle onChange(état).
async function wireMfaSwitch(sw, onChange) {
  const paint = (on) => sw.setAttribute("aria-checked", String(!!on));
  let f = null; try { f = await mfaFactor(); } catch (e) {} paint(f);
  sw.addEventListener("click", async () => {
    sw.disabled = true;
    try { if (f) { if (await disableMfa(f)) { f = null; paint(false); onChange && onChange(false); } } else if (await enableMfa()) { f = await mfaFactor(); paint(true); onChange && onChange(true); } }
    catch (e) { onChange && onChange(!!f, e); }
    sw.disabled = false;
  });
}
