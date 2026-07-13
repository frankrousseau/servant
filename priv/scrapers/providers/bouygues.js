/**
 * Bouygues Telecom Invoice Provider
 *
 * Logs into the espace client (phone number or email + password) and
 * scrapes the invoice history. Bouygues 2FA is an SMS code, which a
 * headless recipe cannot receive: it fails with a clear message.
 */

function log(msg) {
  process.stderr.write(`[bouygues] ${msg}\n`);
}

module.exports = {
  name: "Bouygues Telecom",
  fields: ["email", "password"],
  optionalFields: [],

  async login(page, credentials) {
    await page.goto("https://www.bouyguestelecom.fr/connexion/", {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    const consent = page
      .locator('#popin_tc_privacy_button_2, button:has-text("Accepter"), button:has-text("Tout accepter")')
      .first();
    if (await consent.isVisible().catch(() => false)) {
      await consent.click().catch(() => {});
    }

    const loginInput = page
      .locator('input[name="username"], input[name="login"], input[type="email"], input[type="tel"], #username, #login')
      .first();
    await loginInput.fill(credentials.email);

    // Two-step flows show the password only after the identifier.
    const passwordInput = page
      .locator('input[name="password"], input[type="password"]')
      .first();
    if (!(await passwordInput.isVisible().catch(() => false))) {
      await page
        .locator('button[type="submit"], button:has-text("Continuer"), button:has-text("Suivant")')
        .first()
        .click();
      await page.waitForLoadState("networkidle", { timeout: 15000 });
    }

    await passwordInput.fill(credentials.password);
    await page
      .locator('button[type="submit"], button:has-text("Me connecter"), button:has-text("Se connecter"), button:has-text("Valider")')
      .first()
      .click();
    await page.waitForLoadState("networkidle", { timeout: 20000 });

    const otpVisible = await page
      .locator('input[autocomplete="one-time-code"], input[inputmode="numeric"]')
      .first()
      .isVisible()
      .catch(() => false);
    if (otpVisible) {
      throw new Error("Bouygues asked for an SMS code; approve this device once from a browser, then retry");
    }

    if (page.url().includes("/connexion")) {
      throw new Error("Login failed (still on the login page)");
    }
  },

  async extractInvoices(page) {
    await page.goto("https://www.bouyguestelecom.fr/mon-compte/factures", {
      waitUntil: "networkidle",
      timeout: 30000,
    });
    await page.waitForTimeout(5000);

    return page.evaluate(() => {
      const MONTHS = {
        janvier: "01", fevrier: "02", février: "02", mars: "03", avril: "04",
        mai: "05", juin: "06", juillet: "07", aout: "08", août: "08",
        septembre: "09", octobre: "10", novembre: "11", decembre: "12", décembre: "12",
      };
      const results = [];
      const seen = new Set();
      const elements = document.querySelectorAll("table tbody tr, [role='row'], li, article, [class*='facture' i], [class*='invoice' i]");

      for (const el of elements) {
        const text = el.textContent || "";
        if (text.length > 500 || text.length < 5) continue;

        // "15/06/2026", "2026-06-15" or "juin 2026"
        let date = null;
        const numMatch = text.match(/(\d{2})\/(\d{2})\/(\d{4})/) || text.match(/(\d{4})-(\d{2})-(\d{2})/);
        const monthMatch = text.toLowerCase().match(/(janvier|f[ée]vrier|mars|avril|mai|juin|juillet|ao[uû]t|septembre|octobre|novembre|d[ée]cembre)\s+(\d{4})/);
        if (numMatch) {
          date = numMatch[0].includes("/")
            ? `${numMatch[3]}-${numMatch[2]}-${numMatch[1]}`
            : numMatch[0];
        } else if (monthMatch) {
          date = `${monthMatch[2]}-${MONTHS[monthMatch[1]]}-01`;
        }

        const amountMatch = text.match(/([\d]+[,.][\d]{2})\s*€/);
        if (!date || !amountMatch) continue;

        const amount = amountMatch[1].replace(",", ".");
        const key = `${date}-${amount}`;
        if (seen.has(key)) continue;
        seen.add(key);

        const link = el.querySelector("a[href*='facture'], a[href*='pdf'], a[href]");
        results.push({
          id: `bouygues-${date}-${amount}`,
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
