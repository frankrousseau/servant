/**
 * OVH Invoice Provider
 *
 * Logs into www.ovh.com with email/password + optional TOTP, then reads
 * bills through the manager's own session API (/engine/apiv6/me/bill),
 * falling back to scraping the billing history page if that fails.
 */

const { TOTP } = require("otpauth");

function log(msg) {
  process.stderr.write(`[ovh] ${msg}\n`);
}

const API_BASE = "https://www.ovh.com/engine/apiv6";
const MAX_BILLS = 50;

module.exports = {
  name: "OVH",
  fields: ["email", "password"],
  optionalFields: ["totp_secret"],

  async login(page, credentials) {
    await page.goto("https://www.ovh.com/auth/", {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    // Cookie consent banner blocks the form when shown.
    const consent = page
      .locator(
        'button:has-text("Accept"), button:has-text("Accepter"), #header_tc_privacy_button_2',
      )
      .first();
    if (await consent.isVisible().catch(() => false)) {
      await consent.click().catch(() => {});
    }

    const accountInput = page
      .locator('input[name="account"], input[name="login"], input[type="email"], #account-login')
      .first();
    await accountInput.fill(credentials.email);

    const passwordInput = page
      .locator('input[name="password"], input[type="password"]')
      .first();
    await passwordInput.fill(credentials.password);

    const submitBtn = page
      .locator(
        'button[type="submit"], input[type="submit"], button:has-text("Log in"), button:has-text("Connexion"), button:has-text("Se connecter")',
      )
      .first();
    await submitBtn.click();

    await page.waitForLoadState("networkidle", { timeout: 20000 });

    // 2FA (TOTP) step, when enabled on the account.
    const totpInput = page
      .locator(
        'input[name="codeValue"], input[name="code"], input[autocomplete="one-time-code"], input[inputmode="numeric"]',
      )
      .first();
    const totpVisible = await totpInput.isVisible().catch(() => false);

    if (totpVisible) {
      if (!credentials.totp_secret) {
        throw new Error("2FA required but no totp_secret provided");
      }

      log("2FA detected, generating TOTP...");
      const totp = new TOTP({ secret: credentials.totp_secret, digits: 6, period: 30 });
      await totpInput.fill(totp.generate());

      const verifyBtn = page
        .locator(
          'button[type="submit"], button:has-text("Verify"), button:has-text("Valider"), button:has-text("Confirmer")',
        )
        .first();
      await verifyBtn.click();
      await page.waitForLoadState("networkidle", { timeout: 20000 });
    }

    if (page.url().includes("/auth")) {
      throw new Error("Login failed (still on the auth page)");
    }
  },

  async extractInvoices(page) {
    try {
      const invoices = await extractViaApi(page);
      log(`Session API returned ${invoices.length} bills`);
      return invoices;
    } catch (err) {
      log(`Session API failed (${err.message}), falling back to page scraping`);
      return extractViaPage(page);
    }
  },
};

// The manager SPA talks to /engine/apiv6 with plain session cookies, so a
// fetch from the page context is authenticated. JSON beats DOM scraping.
async function extractViaApi(page) {
  const bills = await page.evaluate(
    async ({ apiBase, maxBills }) => {
      const get = async (path) => {
        const res = await fetch(apiBase + path, {
          headers: { Accept: "application/json" },
          credentials: "include",
        });
        if (!res.ok) throw new Error(`GET ${path} -> ${res.status}`);
        return res.json();
      };

      const ids = await get("/me/bill");
      const recent = ids.slice(-maxBills).reverse();
      const details = [];
      for (const id of recent) {
        details.push(await get(`/me/bill/${encodeURIComponent(id)}`));
      }
      return details;
    },
    { apiBase: API_BASE, maxBills: MAX_BILLS },
  );

  return bills.map((bill) => ({
    id: `ovh-${bill.billId}`,
    date: (bill.date || "").slice(0, 10),
    amount: String(bill.priceWithTax?.value ?? bill.priceWithTax?.text ?? "0"),
    currency: bill.priceWithTax?.currencyCode || "EUR",
    status: "paid",
    url: bill.pdfUrl || bill.url || null,
  }));
}

// Same heuristic style as the anthropic provider: rows with a date and an
// amount on the billing history page.
async function extractViaPage(page) {
  await page.goto("https://www.ovh.com/manager/#/dedicated/billing/history", {
    waitUntil: "networkidle",
    timeout: 30000,
  });
  await page.waitForTimeout(5000);

  return page.evaluate(() => {
    const results = [];
    const seen = new Set();
    const elements = document.querySelectorAll("table tbody tr, [role='row'], li, article");

    for (const el of elements) {
      const text = el.textContent || "";
      if (text.length > 500 || text.length < 5) continue;

      const dateMatch = text.match(/(\d{4}-\d{2}-\d{2}|\d{2}\/\d{2}\/\d{4})/);
      const amountMatch = text.match(/([\d\s,.]+)\s*€|EUR\s*([\d\s,.]+)/);

      if (dateMatch && amountMatch) {
        let date = dateMatch[1];
        if (date.includes("/")) {
          const [d, m, y] = date.split("/");
          date = `${y}-${m}-${d}`;
        }

        const rawAmount = (amountMatch[1] || amountMatch[2] || "")
          .replace(/\s/g, "")
          .replace(",", ".");
        const key = `${date}-${rawAmount}`;
        if (seen.has(key)) continue;
        seen.add(key);

        const link = el.querySelector("a[href*='bill'], a[href*='pdf'], a[href]");
        results.push({
          id: `ovh-${date}-${rawAmount}`,
          date,
          amount: rawAmount,
          currency: "EUR",
          status: "paid",
          url: link ? link.href : null,
        });
      }
    }

    return results;
  });
}
