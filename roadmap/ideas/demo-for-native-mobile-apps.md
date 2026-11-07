---
title: Demo for native mobile apps
created: 2026-11-07T18:02:44.143Z
---

/sweap:demo films web apps only; on an Expo / React Native project it says 'not supported' and stops. Showing a PM or a domain expert what a mobile milestone delivered matters as much as on the web.
Two routes, in order of cost: (1) film the web build (react-native-web / Expo web) with the existing Playwright recorder: works today once the project has a Playwright setup and a local API with test data, but viewers see the browser version, not the phone app (gestures and native pickers differ). (2) a second recorder in the demo skill that drives the real app in a simulator and records it locally (Maestro: supports Expo, 'record --local'; never its cloud upload). Needs a simulator device, Maestro installed and the project's first simulator build, none of which exist yet; the cursor and chapter cards need a native equivalent.
Build (2) only when there is a simulator build to witness it against (the refute round killed designing the slot before that, 3–0).
