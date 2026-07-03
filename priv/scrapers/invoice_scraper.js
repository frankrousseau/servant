#!/usr/bin/env node

/**
 * Generic Invoice Scraper
 *
 * Loads a provider-specific recipe, launches a headless browser,
 * logs in, extracts invoices, and outputs JSON to stdout.
 *
 * Usage:
 *   node invoice_scraper.js --provider anthropic --email EMAIL --password PWD [--totp-secret SECRET]
 *
 * Output (stdout): { "invoices": [...] }
 * Logs go to stderr. Exit code 0 on success, 1 on failure.
 */

const { chromium } = require("playwright");
const path = require("path");

// -- Args parsing --

function parseArgs() {
  const args = process.argv.slice(2);
  const parsed = {};
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] && args[i + 1]) {
      const key = args[i].replace(/^--/, "").replace(/-/g, "_");
      parsed[key] = args[i + 1];
    }
  }
  return parsed;
}

function log(msg) {
  process.stderr.write(`[scraper] ${msg}\n`);
}

// -- Main --

async function main() {
  const args = parseArgs();
  const providerName = args.provider;

  if (!providerName) {
    log("ERROR: --provider is required");
    process.exit(1);
  }

  // Guard against path traversal: the provider name is turned into a filesystem
  // path below, so reject anything but a bare identifier. Without this a name
  // like "../../evil" would `require` (and execute) arbitrary JS. The Elixir
  // side allowlists too; this is defense in depth.
  if (!/^[a-z0-9_]+$/.test(providerName)) {
    log(`ERROR: invalid provider name "${providerName}"`);
    process.exit(1);
  }

  // Load provider recipe
  let provider;
  try {
    provider = require(path.join(__dirname, "providers", `${providerName}.js`));
  } catch (err) {
    log(`ERROR: Unknown provider "${providerName}": ${err.message}`);
    process.exit(1);
  }

  // Validate required fields.
  // Secrets are passed via environment variables (so they don't show up in the
  // process list / `ps`); fall back to CLI args for backward compatibility.
  const credentials = {
    email: process.env.SCRAPER_EMAIL || args.email,
    password: process.env.SCRAPER_PASSWORD || args.password,
    totp_secret: process.env.SCRAPER_TOTP_SECRET || args.totp_secret,
  };

  for (const field of provider.fields || []) {
    if (!credentials[field] && !args[field]) {
      log(`ERROR: --${field.replace(/_/g, "-")} is required for provider "${providerName}"`);
      process.exit(1);
    }
  }

  let browser;
  try {
    log(`Starting scraper for provider: ${provider.name}`);
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();

    // Step 1: Login
    log("Logging in...");
    await provider.login(page, credentials);
    log(`Logged in. URL: ${page.url()}`);

    // Step 2: Extract invoices
    log("Extracting invoices...");
    const invoices = await provider.extractInvoices(page);
    log(`Found ${invoices.length} invoices`);

    // Output JSON
    process.stdout.write(JSON.stringify({ invoices }));

    await browser.close();
    process.exit(0);
  } catch (err) {
    log(`ERROR: ${err.message}`);
    if (browser) await browser.close().catch(() => {});
    process.exit(1);
  }
}

main();
