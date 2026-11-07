// .tours/tours.config.ts: EXAMPLE wrapper. Copy it into the project's `.tours/` folder and adapt
// it. It loads the project's own Playwright config and narrows it to the tours.
//
// Why a wrapper and not the project's own config:
//  - tours are opt-in; the project's config (and its CI) never sees them.
//  - Playwright resolves testDir / globalSetup / globalTeardown / outputDir against the
//    directory of the config it LOADS, so each is set absolute here, from the parent config's
//    directory. A bare `...base` would point them inside .tours/.
//  - outputDir must be our own: Playwright empties it at the start of a run, and the default
//    (`test-results`) would wipe the project's last e2e failure artifacts.
//  - never name it playwright.config.* (lint globs often match that name).
//
// Two kinds of project:
//  (1) the project's config brings the app up itself (a `webServer` entry, maybe a disposable
//      database in globalSetup): keep `...base` and the absolute paths below; done.
//  (2) something else starts the app (a test in another language starts a binary and passes its
//      URL in an environment variable, and the config throws without it): set that variable in
//      `.tours/env` and add a `webServer` here that starts the app the same way that test does,
//      on a local port, with throwaway data. Copy the start command and flags from that test.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, devices } from '@playwright/test'
import base from '../playwright.config' // or '../playwright.config.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const pkg = path.resolve(here, '..')
const abs = (p: unknown) => (typeof p === 'string' ? path.resolve(pkg, p) : p)

export default defineConfig({
  ...base,
  testDir: here,
  testMatch: /.*\.tour\.(ts|mjs|js)$/,
  globalSetup: abs(base.globalSetup) as string | undefined,
  globalTeardown: abs(base.globalTeardown) as string | undefined,
  outputDir: path.join(here, 'test-results'),
  reporter: 'list',
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 240_000,
  // (2) only — start the app the way the project's own harness does, e.g.:
  // webServer: {
  //   command: '<start command> --listen 127.0.0.1:4317 --data-dir <a temp dir>',
  //   url: 'http://127.0.0.1:4317/<a page or health route>',
  //   reuseExistingServer: false,
  // },
  projects: [
    {
      name: 'tours',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1280, height: 800 },
        storageState: { cookies: [], origins: [] },
        video: 'off',
        trace: 'off',
        screenshot: 'off',
        launchOptions: { slowMo: 120 },
      },
    },
  ],
})
