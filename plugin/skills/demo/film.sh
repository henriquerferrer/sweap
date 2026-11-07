#!/bin/sh
# film.sh: record a project's tours and turn them into MP4s + contact sheets. Run it as
# `sweap-film` (bin/sweap-film execs this file); the demo skill's SKILL.md says how tours are made.
#
#   sweap-film <e2e-package-dir> [playwright filter ...]
#
# Runs Playwright with <dir>/.tours/tours.config.{ts,mjs,js}, one worker, against the project's
# own e2e harness (a local app, throwaway data). For every tour recorded THIS run it writes
# <dir>/.tours/out/<name>.mp4 and <name>.contact.png (a frame every 3 s) and prints
#   FILMED <mp4> (<seconds>s) contact: <png>
# An optional <dir>/.tours/env holds KEY=VALUE lines, sourced first.
#
# Exit: Playwright's own status, or 2 = not supported here (no config, no ffmpeg, no installed
# @playwright/test >= 1.61), 3 = another Playwright run is going on this machine.
set -eu

pkg=${1:?usage: sweap-film <e2e-package-dir> [filter ...]}
shift
pkg=$(CDPATH='' cd -P -- "$pkg" && pwd -P)
tours=$pkg/.tours

config=
for c in tours.config.ts tours.config.mjs tours.config.js; do
  if [ -f "$tours/$c" ]; then config=.tours/$c; break; fi
done
[ -n "$config" ] || { echo "sweap-film: no $tours/tours.config.{ts,mjs,js}; set the folder up first (see the demo skill)" >&2; exit 2; }
for t in ffmpeg ffprobe; do
  command -v "$t" >/dev/null 2>&1 || { echo "sweap-film: $t is required (brew install ffmpeg)" >&2; exit 2; }
done

# The INSTALLED @playwright/test, not the declared range: page.screencast arrived in 1.61.
dir=$pkg
pw=
while :; do
  if [ -f "$dir/node_modules/@playwright/test/package.json" ]; then pw=$dir/node_modules/@playwright/test/package.json; break; fi
  [ "$dir" = / ] && break
  dir=$(dirname "$dir")
done
[ -n "$pw" ] || { echo "sweap-film: @playwright/test is not installed for $pkg (install the e2e package's dependencies first)" >&2; exit 2; }
ver=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' "$pw" | head -1)
major=${ver% *}
minor=${ver#* }
if [ -z "$ver" ] || [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 61 ]; }; then
  echo "sweap-film: @playwright/test ${major:-?}.${minor:-?} is installed; demos need 1.61 or newer (page.screencast)" >&2
  exit 2
fi

# Which runner: the one whose lockfile sits nearest the package.
runner="npx --no-install playwright"
dir=$pkg
while :; do
  if [ -f "$dir/pnpm-lock.yaml" ]; then runner="pnpm exec playwright"; break; fi
  if [ -f "$dir/yarn.lock" ]; then runner="yarn playwright"; break; fi
  if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then runner="bunx playwright"; break; fi
  if [ -f "$dir/package-lock.json" ]; then runner="npx --no-install playwright"; break; fi
  [ "$dir" = / ] && break
  dir=$(dirname "$dir")
done

# A second Playwright run in the same checkout fights over build output, ports and databases.
if pgrep -f 'playwright[^ ]* test' >/dev/null 2>&1; then
  echo "sweap-film: a Playwright run is already going on this machine; wait for it to finish" >&2
  pgrep -fl 'playwright[^ ]* test' >&2 || true
  exit 3
fi

unset PLAYWRIGHT_BASE_URL
export PLAYWRIGHT_WORKERS=1
if [ -f "$tours/env" ]; then set -a; . "$tours/env"; set +a; fi
TOURS_OUT=$tours/out
export TOURS_OUT
mkdir -p "$TOURS_OUT"
stamp=$tours/.stamp
: > "$stamp"
sleep 1 # mtime granularity: a video written this second must read as newer than the stamp

cd "$pkg"
status=0
# shellcheck disable=SC2086 # the runner is a command plus its arguments
$runner test -c "$config" "$@" || status=$?

found=0
for webm in "$TOURS_OUT"/*.webm; do
  [ -e "$webm" ] || continue
  [ "$webm" -nt "$stamp" ] || continue
  found=1
  name=${webm%.webm}
  ffmpeg -loglevel error -y -i "$webm" -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$name.mp4"
  ffmpeg -loglevel error -y -i "$name.mp4" -vf "fps=1/3,scale=640:-1,tile=4x4" -frames:v 1 "$name.contact.png"
  secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$name.mp4" | cut -d. -f1)
  echo "FILMED $name.mp4 (${secs}s) contact: $name.contact.png"
done
[ "$found" = 1 ] || echo "sweap-film: no tour recorded a video this run" >&2
exit "$status"
