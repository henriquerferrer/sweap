// tour.ts: on-camera helpers for filming a web app flow with Playwright ≥ 1.61 (page.screencast).
// Copied into a project's `.tours/` folder by sweap's `demo` skill. Setup happens off camera BEFORE
// startTour(); everything after it should be a step a person would take, through the UI.
import type { Locator, Page } from '@playwright/test'

// A plain arrow cursor drawn in the page (headless Chromium draws none). It follows real mouse
// events, survives navigations (sessionStorage), and dips slightly on press. Nothing else:
// no boxes, dots or labels.
const CURSOR = `(() => {
  if (window.__tourCursor) return; window.__tourCursor = true;
  const mount = () => {
    const el = document.createElement('div');
    el.id = 'tour-cursor';
    el.innerHTML = '<svg width="22" height="30" viewBox="0 0 22 30"><path d="M2 2 L2 24 L8 18.5 L12.5 28 L16 26.5 L11.6 17.2 L19.5 17.2 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
    el.style.cssText = 'position:fixed;left:0;top:0;width:22px;height:30px;pointer-events:none;z-index:2147483647;transition:transform 80ms;will-change:transform;filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.35))';
    let x = +(sessionStorage.getItem('tourX') || innerWidth / 2), y = +(sessionStorage.getItem('tourY') || innerHeight / 2), s = 1;
    const draw = () => { el.style.transform = 'translate(' + (x - 2) + 'px,' + (y - 2) + 'px) scale(' + s + ')'; };
    draw(); document.documentElement.appendChild(el);
    addEventListener('mousemove', (e) => { x = e.clientX; y = e.clientY; sessionStorage.setItem('tourX', x); sessionStorage.setItem('tourY', y); draw(); }, true);
    addEventListener('mousedown', () => { s = 0.86; draw(); }, true);
    addEventListener('mouseup', () => { s = 1; draw(); }, true);
  };
  if (document.documentElement) mount(); else addEventListener('DOMContentLoaded', mount);
})()`

const LOCAL = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])
const pos = new WeakMap<Page, { x: number; y: number }>()

/** Refuse to film anything but a local app: tours create data, and the data must be throwaway. */
export function assertLocal(page: Page) {
  const host = new URL(page.url()).hostname
  if (!LOCAL.has(host)) throw new Error(`tour refused: ${host} is not a local app; tours only run against the e2e harness`)
}

export async function startTour(page: Page, name: string, size = { width: 1280, height: 800 }) {
  assertLocal(page)
  const out = process.env.TOURS_OUT
  if (!out) throw new Error('TOURS_OUT is unset; run tours through film.sh')
  await page.addInitScript(CURSOR)
  await page.evaluate(CURSOR)
  pos.set(page, { x: size.width / 2, y: size.height / 2 })
  await page.mouse.move(size.width / 2, size.height / 2)
  await page.screencast.start({ path: `${out}/${name}.webm`, size })
}

export async function endTour(page: Page, holdMs = 2500) {
  await page.waitForTimeout(holdMs)
  await page.screencast.stop()
}

export async function chapter(page: Page, title: string, description?: string) {
  assertLocal(page)
  await page.screencast.showChapter(title, { description, duration: 2200 })
  await page.waitForTimeout(2300)
}

export const beat = (page: Page, ms = 900) => page.waitForTimeout(ms)

/** Glide the cursor to a point at a human pace (~1 step per 14px). */
async function glide(page: Page, x: number, y: number) {
  const from = pos.get(page) ?? { x: 640, y: 400 }
  const steps = Math.max(8, Math.min(45, Math.round(Math.hypot(x - from.x, y - from.y) / 14)))
  await page.mouse.move(x, y, { steps })
  pos.set(page, { x, y })
}

export async function moveTo(page: Page, target: Locator) {
  await target.scrollIntoViewIfNeeded()
  const box = await target.boundingBox()
  if (box) await glide(page, box.x + box.width / 2, box.y + box.height / 2)
  await page.waitForTimeout(180)
}

export async function click(page: Page, target: Locator) {
  await moveTo(page, target)
  await target.click()
}

export async function type(page: Page, target: Locator, text: string) {
  await click(page, target)
  await target.pressSequentially(text, { delay: 75 })
}

// Native <select> popups are drawn by the OS, outside the page, so a recording never shows them.
// pick() clicks the select, draws a look-alike list under it (a window of up to 7 options around
// the choice, like a real list scrolled to it), glides to the option, then selects. The list is a
// drawing, so there is no real press on it: a click would land on whatever is beneath.
export async function pick(page: Page, select: Locator, value: string) {
  await click(page, select)
  const box = await select.boundingBox()
  const real = (
    await select.locator('option').evaluateAll((els) =>
      els.map((o) => ({ value: (o as HTMLOptionElement).value, label: (o as HTMLOptionElement).label || o.textContent || '' })),
    )
  ).filter((o) => o.value !== '')
  const at = Math.max(0, real.findIndex((o) => o.value === value))
  const from = Math.max(0, Math.min(at - 3, real.length - 7))
  const shown = real.slice(from, from + 7)
  if (box) {
    const ROW = 29
    const top = box.y + box.height + 2
    const list = (hi: number) =>
      `<div style="position:fixed;left:${box.x}px;top:${top}px;width:${box.width}px;background:#fff;border:1px solid #c8c8c8;border-radius:6px;box-shadow:0 8px 24px rgba(0,0,0,.18);font:14px system-ui,-apple-system,sans-serif;color:#1a1a1a;overflow:hidden">${shown
        .map((o, i) => `<div style="height:${ROW}px;line-height:${ROW}px;padding:0 10px;${i === hi ? 'background:#1d4ed8;color:#fff;' : ''}">${esc(o.label)}</div>`)
        .join('')}</div>`
    let overlay = await page.screencast.showOverlay(list(-1))
    await page.waitForTimeout(450)
    const i = at - from
    await glide(page, box.x + Math.min(box.width / 2, 90), top + 1 + i * ROW + ROW / 2)
    await overlay.dispose()
    overlay = await page.screencast.showOverlay(list(i))
    await page.waitForTimeout(450)
    await page.evaluate(() => { const c = document.getElementById('tour-cursor'); if (c) { c.style.scale = '0.86'; setTimeout(() => (c.style.scale = ''), 120) } })
    await overlay.dispose()
  }
  await select.selectOption({ value })
  await page.waitForTimeout(300)
}

/** Date inputs: type the digits so the viewer sees them appear. `order` is the input's locale order. */
export async function typeDate(page: Page, input: Locator, isoDate: string, order: 'dmy' | 'mdy' | 'ymd' = 'dmy') {
  const [y, m, d] = isoDate.split('-')
  const digits = order === 'dmy' ? `${d}${m}${y}` : order === 'mdy' ? `${m}${d}${y}` : `${y}${m}${d}`
  await type(page, input, digits)
}

/**
 * Show an email the flow sent (e.g. a reminder or a verification code) as a card over the page:
 * fetch its HTML off camera through the project's mail-catcher helper, then pass it here.
 */
export async function showEmail(page: Page, html: string, opts: { subject?: string; to?: string; holdMs?: number } = {}) {
  const head = opts.subject || opts.to
    ? `<div style="padding:12px 16px;border-bottom:1px solid #e5e5e5;font:13px system-ui,sans-serif;color:#444">${opts.to ? `To: ${esc(opts.to)}<br>` : ''}${opts.subject ? `<b style="color:#111">${esc(opts.subject)}</b>` : ''}</div>`
    : ''
  const card = `<div style="position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center">
    <div style="width:680px;height:86%;background:#fff;border-radius:10px;box-shadow:0 20px 60px rgba(0,0,0,.35);overflow:hidden;display:flex;flex-direction:column">${head}
    <iframe srcdoc="${esc(html)}" style="flex:1;border:0;width:100%"></iframe></div></div>`
  const overlay = await page.screencast.showOverlay(card)
  await page.waitForTimeout(opts.holdMs ?? 4500)
  await overlay.dispose()
}

function esc(s: string) {
  return s.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`)
}
