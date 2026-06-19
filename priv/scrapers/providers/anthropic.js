/**
 * Anthropic Invoice Provider
 *
 * Scrapes invoices from console.anthropic.com/settings/billing
 * Auth: email/password + optional TOTP
 */

const { TOTP } = require("otpauth");

function log(msg) {
  process.stderr.write(`[anthropic] ${msg}\n`);
}

module.exports = {
  name: "Anthropic",
  fields: ["email", "password"],
  optionalFields: ["totp_secret"],

  async login(page, credentials) {
    // Navigate to login
    await page.goto("https://console.anthropic.com/login", {
      waitUntil: "networkidle",
    });

    // Fill email
    const emailInput = await page
      .locator('input[type="email"], input[name="email"], input[id="email"]')
      .first();
    await emailInput.fill(credentials.email);

    // Fill password
    const passwordInput = await page
      .locator('input[type="password"], input[name="password"]')
      .first();
    await passwordInput.fill(credentials.password);

    // Submit
    const submitBtn = await page
      .locator(
        'button[type="submit"], button:has-text("Log in"), button:has-text("Sign in"), button:has-text("Continue")',
      )
      .first();
    await submitBtn.click();

    await page.waitForLoadState("networkidle", { timeout: 15000 });

    // Handle TOTP if needed
    const totpInput = await page
      .locator(
        'input[name="code"], input[name="totp"], input[autocomplete="one-time-code"], input[inputmode="numeric"]',
      )
      .first();
    const totpVisible = await totpInput.isVisible().catch(() => false);

    if (totpVisible) {
      if (!credentials.totp_secret) {
        throw new Error("2FA required but no totp_secret provided");
      }

      log("2FA detected, generating TOTP...");
      const totp = new TOTP({ secret: credentials.totp_secret, digits: 6, period: 30 });
      const code = totp.generate();
      await totpInput.fill(code);

      const verifyBtn = await page
        .locator('button[type="submit"], button:has-text("Verify")')
        .first();
      await verifyBtn.click();
      await page.waitForLoadState("networkidle", { timeout: 15000 });
    }
  },

  async extractInvoices(page) {
    // Navigate to billing
    await page.goto("https://console.anthropic.com/settings/billing", {
      waitUntil: "networkidle",
      timeout: 20000,
    });

    // Wait for content to load
    await page.waitForTimeout(3000);

    // Extract invoice data from the page
    const invoices = await page.evaluate(() => {
      const results = [];
      const seen = new Set();

      // Look for table rows or list items with invoice data
      const elements = document.querySelectorAll(
        "table tbody tr, [role='row'], [class*='invoice' i], [class*='Invoice'], li, article",
      );

      for (const el of elements) {
        const text = el.textContent || "";
        if (text.length > 500 || text.length < 5) continue;

        const dateMatch = text.match(
          /(\w{3,9}\s+\d{1,2},?\s+\d{4}|\d{4}-\d{2}-\d{2})/,
        );
        const amountMatch = text.match(/\$[\d,]+\.?\d*/);

        if (dateMatch && amountMatch) {
          const key = `${dateMatch[1]}-${amountMatch[0]}`;
          if (seen.has(key)) continue;
          seen.add(key);

          const link = el.querySelector("a[href*='stripe'], a[href*='invoice'], a[href]");
          const statusMatch = text.match(/(paid|unpaid|open|draft|void)/i);

          results.push({
            id: `anthropic-${dateMatch[1].replace(/[^a-zA-Z0-9]/g, "")}`,
            date: dateMatch[1],
            amount: amountMatch[0].replace("$", "").replace(",", ""),
            currency: "USD",
            status: statusMatch ? statusMatch[1].toLowerCase() : "paid",
            url: link ? link.href : null,
          });
        }
      }

      return results;
    });

    return invoices;
  },
};
