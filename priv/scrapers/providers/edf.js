/**
 * EDF Invoice Provider
 *
 * Logs into the espace client particulier (two-step email then password)
 * and scrapes the invoice/payment history. On unknown devices EDF sends
 * a one-time code by email, which a headless recipe cannot receive: it
 * fails with a clear message.
 */

function log(msg) {
  process.stderr.write(`[edf] ${msg}\n`);
}

module.exports = {
  name: "EDF",
  fields: ["email", "password"],
  optionalFields: [],

  async login(page, credentials) {
    await page.goto("https://particulier.edf.fr/fr/accueil/connexion.html", {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    const consent = page
      .locator('#footer_tc_privacy_button_2, button:has-text("Tout accepter"), button:has-text("Accepter")')
      .first();
    if (await consent.isVisible().catch(() => false)) {
      await consent.click().catch(() => {});
    }

    // Step 1: identifier
    const emailInput = page
      .locator('input[type="email"], input[name="email"], input[name="login"], #email')
      .first();
    await emailInput.fill(credentials.email);
    await page
      .locator('button[type="submit"], button:has-text("Suivant"), button:has-text("Continuer"), button:has-text("Me connecter")')
      .first()
      .click();
    await page.waitForLoadState("networkidle", { timeout: 20000 });

    // Step 2: password (or a one-time code screen we cannot handle)
    const passwordInput = page
      .locator('input[type="password"], input[name="password"]')
      .first();
    if (!(await passwordInput.isVisible().catch(() => false))) {
      const otpVisible = await page
        .locator('input[autocomplete="one-time-code"], input[inputmode="numeric"]')
        .first()
        .isVisible()
        .catch(() => false);
      if (otpVisible) {
        throw new Error("EDF asked for an email code; approve this device once from a browser, then retry");
      }
      throw new Error("Login flow changed (no password field found)");
    }

    await passwordInput.fill(credentials.password);
    await page
      .locator('button[type="submit"], button:has-text("Me connecter"), button:has-text("Se connecter"), button:has-text("Valider")')
      .first()
      .click();
    await page.waitForLoadState("networkidle", { timeout: 20000 });

    if (page.url().includes("connexion")) {
      throw new Error("Login failed (still on the login page)");
    }
  },

  async extractInvoices(page) {
    await page.goto(
      "https://particulier.edf.fr/fr/accueil/espace-client/factures-et-paiements.html",
      { waitUntil: "networkidle", timeout: 30000 },
    );
    await page.waitForTimeout(5000);

    return page.evaluate(() => {
      const MONTHS = {
        janvier: "01", fevrier: "02", février: "02", mars: "03", avril: "04",
        mai: "05", juin: "06", juillet: "07", aout: "08", août: "08",
        septembre: "09", octobre: "10", novembre: "11", decembre: "12", décembre: "12",
      };
      const results = [];
      const seen = new Set();
      const elements = document.querySelectorAll("table tbody tr, [role='row'], li, article, [class*='facture' i], [class*='invoice' i], [class*='paiement' i]");

      for (const el of elements) {
        const text = el.textContent || "";
        if (text.length > 500 || text.length < 5) continue;

        let date = null;
        const numMatch = text.match(/(\d{2})\/(\d{2})\/(\d{4})/) || text.match(/(\d{4})-(\d{2})-(\d{2})/);
        const monthMatch = text.toLowerCase().match(/(\d{1,2})?\s*(janvier|f[ée]vrier|mars|avril|mai|juin|juillet|ao[uû]t|septembre|octobre|novembre|d[ée]cembre)\s+(\d{4})/);
        if (numMatch) {
          date = numMatch[0].includes("/")
            ? `${numMatch[3]}-${numMatch[2]}-${numMatch[1]}`
            : numMatch[0];
        } else if (monthMatch) {
          const day = (monthMatch[1] || "1").padStart(2, "0");
          date = `${monthMatch[3]}-${MONTHS[monthMatch[2]]}-${day}`;
        }

        const amountMatch = text.match(/([\d\s]+[,.][\d]{2})\s*€/);
        if (!date || !amountMatch) continue;

        const amount = amountMatch[1].replace(/\s/g, "").replace(",", ".");
        const key = `${date}-${amount}`;
        if (seen.has(key)) continue;
        seen.add(key);

        const link = el.querySelector("a[href*='facture'], a[href*='pdf'], a[href]");
        results.push({
          id: `edf-${date}-${amount}`,
          date,
          amount,
          currency: "EUR",
          status: "paid",
          url: link ? link.href : null,
        });
      }

      return results;
    });
  },
};
