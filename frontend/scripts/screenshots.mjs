// Docs screenshots: logs into a running Servant as the seeded demo user, turns
// every built-in app on, and captures WebP files into docs/screenshots/: the
// README gallery (full screens) and the guide pictures (guides/, cropped to
// the part of the screen a guide talks about). Run against a seeded throwaway
// database, never a real one (see docs/development.md, "Docs screenshots"):
//
//   DEV_DB=screenshots mix servant.seed --photos 30
//   DEV_DB=screenshots PORT=4011 mix phx.server
//   cd frontend && npm run screenshots            # everything
//   cd frontend && npm run screenshots -- guides  # one group (readme, guides)
//
// The guides group tags photos, names people on them and turns agents on
// through the API before its captures.
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

// Space kept around a cropped element, so the capture shows where it sits.
const MARGIN = 12
// The guide crops render in a taller window: a long form then fits without
// a scroll, and no layout depends on where the fold is.
const TALL_VIEWPORT = { width: 1440, height: 1400 }
const SCREEN_VIEWPORT = { width: 1440, height: 900 }

// The share link of the photo-sharing guide: the dialog shows it about to be
// created, the public page shows it opened.
const SUMMER_FEED = {
  name: 'Summer 2026',
  tags: ['beach', 'sunset'],
  match: 'any'
}

// One guide picture each. `run` sets the screen up and returns the elements
// to crop to; it returns nothing for a full-screen capture.
const GUIDE_SHOTS = [
  {
    name: 'photo-sharing-dialog',
    async run(page, demo) {
      await page.goto(`${BASE}/apps/photos`, { waitUntil: 'networkidle' })
      await page.getByRole('button', { name: 'Share', exact: true }).click()
      const dialog = page.locator('dialog[open] .servant-dialog-box')
      for (const name of [...SUMMER_FEED.tags, demo.alice.name]) {
        await dialog.getByRole('button', { name, exact: true }).click()
      }
      await dialog.getByLabel('Link name').fill(SUMMER_FEED.name)
      return [dialog]
    }
  },
  {
    // The feed the dialog above was about to create, as a guest sees it.
    name: 'photo-sharing-page',
    async run(page, demo) {
      const share = await api('POST', '/api/photo_shares', {
        ...SUMMER_FEED,
        people: [demo.alice]
      })
      await page.goto(`${BASE}${share.path}`, { waitUntil: 'networkidle' })
      await page.waitForFunction(() =>
        [...document.images].every(image => image.complete)
      )
      // The page focuses the first photo for the keyboard; its ring would
      // read as a selection in a still picture.
      await page.evaluate(() => document.activeElement?.blur())
      return [page.locator('.shared-header'), page.locator('.shared-grid')]
    }
  },
  {
    name: 'phone-backup-token',
    run: page => tokenForm(page, 'Phone backup', ['Photos'])
  },
  {
    name: 'dav-token',
    run: page => tokenForm(page, 'Phone sync', ['Calendar', 'Contacts'])
  },
  {
    name: 'agent-memory-token',
    run: page => tokenForm(page, 'Laptop', ['Agent memory'])
  },
  {
    name: 'custom-apps-install',
    async run(page) {
      await page.goto(`${BASE}/settings?tab=apps`, { waitUntil: 'networkidle' })
      await page
        .getByPlaceholder('https://github.com/you/your-servant-app.git')
        .fill('https://github.com/you/todo-plus.git')
      return [page.locator('section.card', { has: page.locator('form') })]
    }
  },
  {
    name: 'custom-apps-builder',
    async run(page) {
      await page.goto(`${BASE}/agents?tab=builder`, {
        waitUntil: 'networkidle'
      })
      await page.getByPlaceholder('App name').fill('Reading list')
      await page
        .getByPlaceholder('What should the app do?')
        .fill('Track the books I want to read, with a status and a rating.')
      return [
        page.getByRole('heading', { name: 'Agents', level: 1 }),
        page.locator('section.card', { has: page.locator('form') })
      ]
    }
  }
]

// The token form with a name and the given apps set to "Read + write"; the
// capture stops before the token is created, so no secret shows.
async function tokenForm(page, name, apps) {
  await page.goto(`${BASE}/settings?tab=tokens`, { waitUntil: 'networkidle' })
  const form = page.locator('form.tk-form')
  await form.getByPlaceholder('Token name (e.g. tracker bot)').fill(name)
  for (const app of apps) {
    await form
      .locator('.tk-domain', { has: page.getByText(app, { exact: true }) })
      .getByRole('combobox')
      .click()
    await page.getByRole('option', { name: 'Read + write' }).click()
  }
  return [page.locator('section.card', { has: form })]
}

const groups = process.argv.slice(2)
const wanted = group => !groups.length || groups.includes(group)

const browser = await chromium.launch(
  process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH }
    : { channel: 'chrome' }
)
const context = await browser.newContext({
  viewport: SCREEN_VIEWPORT,
  colorScheme: 'dark',
  // English dates in the captures, whatever the machine's locale.
  locale: 'en-US'
})

async function api(method, path, data) {
  const response = await context.request.fetch(`${BASE}${path}`, {
    method,
    data
  })
  if (!response.ok()) {
    throw new Error(`${method} ${path} failed: ${response.status()}`)
  }
  return response.status() === 204 ? null : (await response.json()).data
}

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

const page = await context.newPage()
const cdp = await context.newCDPSession(page)

// Crops to the union of the elements plus MARGIN, in the viewport; without
// elements, captures the whole viewport.
async function capture(file, elements = []) {
  // Park the pointer on the bottom-right corner: no hover state leaks into
  // the capture from the last click.
  const viewport = page.viewportSize()
  await page.mouse.move(viewport.width - 1, viewport.height - 1)
  // Charts, thumbnails and the relations layout settle after the data lands.
  await page.waitForTimeout(1200)
  let clip
  if (elements.length) {
    const boxes = await Promise.all(
      elements.map(element => element.boundingBox())
    )
    const left = Math.max(0, Math.min(...boxes.map(box => box.x)) - MARGIN)
    const top = Math.max(0, Math.min(...boxes.map(box => box.y)) - MARGIN)
    const right = Math.max(...boxes.map(box => box.x + box.width)) + MARGIN
    const bottom = Math.max(...boxes.map(box => box.y + box.height)) + MARGIN
    if (bottom > viewport.height) throw new Error(`${file} does not fit`)
    clip = {
      x: left,
      y: top,
      width: Math.min(right, viewport.width) - left,
      height: bottom - top,
      scale: 1
    }
  }
  const { data } = await cdp.send('Page.captureScreenshot', {
    format: 'webp',
    quality: 82,
    ...(clip && { clip })
  })
  await writeFile(resolve(OUT, file), Buffer.from(data, 'base64'))
  console.log(file)
}

// Tags the seeded landscapes by scene, names two contacts on some of them
// and turns agents on (a local model server that the captures never call).
// Share links from an earlier run go, so the share dialog starts empty.
async function prepareGuides() {
  const photos = await api('GET', '/api/entries?kind=photo&per_page=100')
  const contacts = await api('GET', '/api/entries?kind=contact&per_page=100')
  const person = first => {
    const contact =
      contacts.find(entry => entry.data.display_name?.startsWith(first)) ||
      contacts[first === 'Alice' ? 0 : 1]
    return { id: contact.id, name: contact.data.display_name }
  }
  const alice = person('Alice')
  const ben = person('Ben')
  const sceneTags = {
    sea: ['beach'],
    sunset: ['sunset'],
    snow: ['mountains', 'winter'],
    day: ['hiking'],
    night: ['stars']
  }
  // Alice is on every beach photo and on every other sunset, so "beach" with
  // Alice under "all" differs from "any"; Ben is on the snow photos.
  let sunsets = 0
  for (const photo of photos) {
    const match = photo.title.match(/-(sea|sunset|snow|day|night)-\d+(\.jpg)?$/)
    if (!match) continue
    const scene = match[1]
    if (scene === 'sunset') sunsets += 1
    const people = []
    if (scene === 'sea' || (scene === 'sunset' && sunsets % 2 === 1)) {
      people.push(alice)
    }
    if (scene === 'snow') people.push(ben)
    await api('PUT', `/api/entries/${photo.id}`, {
      data: { ...photo.data, tags: sceneTags[scene], people }
    })
  }
  for (const share of await api('GET', '/api/photo_shares')) {
    await api('DELETE', `/api/photo_shares/${share.id}`)
  }
  await api('PUT', '/api/ai_config', {
    enabled: true,
    base_url: 'http://localhost:11434/v1',
    model: 'qwen2.5-coder'
  })
  return { alice }
}

if (wanted('readme')) {
  await mkdir(OUT, { recursive: true })
  for (const shot of SHOTS) {
    await page.goto(`${BASE}${shot.path}`, { waitUntil: 'networkidle' })
    if (shot.click) {
      await page.locator(shot.click).first().click()
      await page.waitForLoadState('networkidle')
    }
    await capture(`${shot.name}.webp`)
  }
}

if (wanted('guides')) {
  await mkdir(resolve(OUT, 'guides'), { recursive: true })
  const demo = await prepareGuides()
  for (const shot of GUIDE_SHOTS) {
    await page.setViewportSize(TALL_VIEWPORT)
    const elements = await shot.run(page, demo)
    await capture(`guides/${shot.name}.webp`, elements)
  }
}

await browser.close()
