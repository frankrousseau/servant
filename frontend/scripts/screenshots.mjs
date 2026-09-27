// README screenshots: logs into a running Servant as the seeded demo user,
// turns every built-in app on, and captures each screen as WebP into
// docs/screenshots/. Run against a seeded throwaway database, never a real
// one (see docs/development.md, "README screenshots"):
//
//   DEV_DB=screenshots mix servant.seed
//   DEV_DB=screenshots PORT=4011 mix phx.server
//   cd frontend && npm run screenshots
//
// Uses the local Chrome through playwright-core (no bundled browser);
// CHROME_PATH points it elsewhere.

import { mkdir, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright-core'

const BASE = process.env.SCREENSHOT_URL || 'http://localhost:4011'
const USER = process.env.SCREENSHOT_USER || 'demo'
const PASSWORD = process.env.SCREENSHOT_PASSWORD || 'demo1234'
const OUT = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../docs/screenshots'
)

const APPS = [
  'agent_memory',
  'calendar',
  'checklists',
  'contacts',
  'files',
  'finance',
  'notes',
  'photos',
  'trackers'
]

// `click` opens an item first (Playwright selector), so list/detail apps do
// not show an empty detail pane.
const SHOTS = [
  { name: 'dashboard', path: '/' },
  { name: 'agent-memory', path: '/apps/agent_memory', click: 'text=stack.md' },
  { name: 'calendar', path: '/apps/calendar' },
  { name: 'checklists', path: '/apps/checklists', click: 'text=Groceries' },
  { name: 'contacts', path: '/apps/contacts', click: '.ct-card >> nth=2' },
  { name: 'contacts-graph', path: '/apps/contacts', click: 'text=Graph' },
  { name: 'files', path: '/apps/files', click: 'text=meeting-notes.md' },
  { name: 'finance', path: '/apps/finance' },
  { name: 'notes', path: '/apps/notes', click: 'text=Sourdough bread' },
  { name: 'photos', path: '/apps/photos' },
  { name: 'trackers', path: '/apps/trackers' },
  { name: 'sources', path: '/connectors' }
]

const browser = await chromium.launch(
  process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH }
    : { channel: 'chrome' }
)
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  colorScheme: 'dark',
  // English dates in the captures, whatever the machine's locale.
  locale: 'en-US'
})

// The session cookie comes from the login call; the SPA also checks its
// "logged in" flag before asking /auth/me.
const login = await context.request.post(`${BASE}/api/auth/login`, {
  data: { username: USER, password: PASSWORD }
})
if (!login.ok()) throw new Error(`login failed: ${login.status()}`)
await context.request.put(`${BASE}/api/auth/profile`, {
  data: { enabled_apps: [...APPS, 'agents'], theme: 'night' }
})
await context.addInitScript(() => {
  localStorage.setItem('servant_logged_in', '1')
  localStorage.setItem('servant_theme', 'night')
})

await mkdir(OUT, { recursive: true })
const page = await context.newPage()
const cdp = await context.newCDPSession(page)

for (const shot of SHOTS) {
  await page.goto(`${BASE}${shot.path}`, { waitUntil: 'networkidle' })
  if (shot.click) {
    await page.locator(shot.click).first().click()
    await page.waitForLoadState('networkidle')
  }
  // Park the pointer on the empty bottom-right corner: no hover state leaks
  // into the capture from the last click.
  await page.mouse.move(1439, 899)
  // Charts, thumbnails and the relations layout settle after the data lands.
  await page.waitForTimeout(1200)
  const { data } = await cdp.send('Page.captureScreenshot', {
    format: 'webp',
    quality: 82
  })
  await writeFile(
    resolve(OUT, `${shot.name}.webp`),
    Buffer.from(data, 'base64')
  )
  console.log(`${shot.name}.webp`)
}

await browser.close()
