# Invoice scraper providers

`invoice_scraper.js` runs a **provider recipe** to log into a billing portal and
extract invoices. Recipes live in `providers/<name>.js`; the connector's
`provider` config value selects one.

## Adding a provider

Create `providers/<name>.js` exporting:

```js
module.exports = {
  name: "Display Name",
  fields: ["email", "password"],        // required credential keys
  optionalFields: ["totp_secret"],      // optional keys
  async login(page, credentials) { /* Playwright: log in */ },
  async extractInvoices(page) {
    // return [{ id, date, amount, currency, status, url }, ...]
  },
};
```

- `<name>` **must match `^[a-z0-9_]+$`** — it is turned into a filesystem path
  (`providers/<name>.js`), so anything else is rejected to prevent path traversal
  into arbitrary JS. The Elixir connector (`InvoiceScraperConnector`) enforces the
  same allowlist before invoking the script.
- Secrets are passed via environment variables (`SCRAPER_EMAIL`,
  `SCRAPER_PASSWORD`, `SCRAPER_TOTP_SECRET`), never on the command line.
- Output goes to stdout as `{ "invoices": [...] }`; logs go to stderr.

Run `npm install` in this directory to install Playwright/otpauth before use.
