#!/bin/bash
# Auto-installs gstack (https://github.com/garrytan/gstack) as a Claude Code
# skill pack in Claude Code on the web. Remote-only, idempotent, and must
# never fail or block session startup — every step is best-effort.

# Only run in Claude Code on the web (remote) sessions.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

set +e

GSTACK_DIR="$HOME/.claude/skills/gstack"
GSTACK_REPO="https://github.com/garrytan/gstack.git"

log() { echo "[gstack-hook] $*"; }

# ─── 1. Clone gstack if it isn't already present ──────────────────────────
if [ ! -d "$GSTACK_DIR" ]; then
  log "cloning gstack to $GSTACK_DIR"
  git clone --depth 1 "$GSTACK_REPO" "$GSTACK_DIR" >/dev/null 2>&1
  if [ ! -d "$GSTACK_DIR" ]; then
    log "clone failed, skipping gstack install for this session"
    exit 0
  fi
fi

if ! command -v bun >/dev/null 2>&1; then
  log "bun not found, skipping gstack install"
  exit 0
fi

# ─── 2. Bridge the pre-installed Chromium to whatever revision gstack's ───
#        pinned Playwright expects, so `./setup` never has to reach
#        cdn.playwright.dev (blocked by this environment's network policy).
bridge_playwright_chromium() {
  local browsers_path="${PLAYWRIGHT_BROWSERS_PATH:-}"
  [ -n "$browsers_path" ] && [ -d "$browsers_path" ] || return 0
  command -v node >/dev/null 2>&1 || return 0

  # Materialize node_modules/playwright-core so we can read the exact
  # chromium revision gstack's pinned playwright resolves to. Skip any
  # browser download here — we only want the package metadata.
  (
    cd "$GSTACK_DIR" || exit 1
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bun install >/dev/null 2>&1
  )

  local browsers_json="$GSTACK_DIR/node_modules/playwright-core/browsers.json"
  [ -f "$browsers_json" ] || return 0

  local chromium_rev headless_rev
  chromium_rev=$(node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const b = j.browsers.find(b => b.name === "chromium");
    if (b) process.stdout.write(b.revision);
  ' "$browsers_json" 2>/dev/null)
  headless_rev=$(node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const b = j.browsers.find(b => b.name === "chromium-headless-shell");
    if (b) process.stdout.write(b.revision);
  ' "$browsers_json" 2>/dev/null)

  [ -n "$chromium_rev" ] || return 0

  # Find the highest-revision chromium/headless-shell dirs already on disk.
  local chromium_src headless_src
  chromium_src=$(ls -d "$browsers_path"/chromium-[0-9]* 2>/dev/null | sort -V | tail -1)
  headless_src=$(ls -d "$browsers_path"/chromium_headless_shell-[0-9]* 2>/dev/null | sort -V | tail -1)

  # Bridge regular chromium: only the containing directory name changed
  # across Playwright versions ("chrome-linux" -> "chrome-linux64" on
  # x64); the executable inside is still named "chrome" either way.
  if [ -n "$chromium_src" ] && [ -d "$chromium_src/chrome-linux" ]; then
    local target="$browsers_path/chromium-$chromium_rev"
    if [ ! -e "$target/INSTALLATION_COMPLETE" ]; then
      mkdir -p "$target"
      touch "$target/INSTALLATION_COMPLETE" "$target/DEPENDENCIES_VALIDATED" 2>/dev/null
      ln -sfn "$chromium_src/chrome-linux" "$target/chrome-linux" 2>/dev/null
      ln -sfn "$chromium_src/chrome-linux" "$target/chrome-linux64" 2>/dev/null
    fi
  fi

  # Bridge headless shell: both the directory name and the executable's
  # own filename changed across Playwright versions ("headless_shell" vs
  # "chrome-headless-shell"). Add a same-directory alias for the binary
  # (additive, doesn't touch anything else) plus both directory aliases.
  if [ -n "$headless_rev" ] && [ -n "$headless_src" ] && [ -d "$headless_src/chrome-linux" ]; then
    if [ -e "$headless_src/chrome-linux/headless_shell" ] && [ ! -e "$headless_src/chrome-linux/chrome-headless-shell" ]; then
      ln -s headless_shell "$headless_src/chrome-linux/chrome-headless-shell" 2>/dev/null
    fi
    local htarget="$browsers_path/chromium_headless_shell-$headless_rev"
    if [ ! -e "$htarget/INSTALLATION_COMPLETE" ]; then
      mkdir -p "$htarget"
      touch "$htarget/INSTALLATION_COMPLETE" "$htarget/DEPENDENCIES_VALIDATED" 2>/dev/null
      ln -sfn "$headless_src/chrome-linux" "$htarget/chrome-linux" 2>/dev/null
      ln -sfn "$headless_src/chrome-linux" "$htarget/chrome-headless-shell-linux64" 2>/dev/null
    fi
  fi
}

bridge_playwright_chromium

# ─── 3. Run gstack's own installer ─────────────────────────────────────────
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD is a defense-in-depth belt: the bridge
# above should make gstack's internal Chromium launch check succeed on the
# first try, so its "not found -> bunx playwright install chromium" fallback
# (which would hit the blocked CDN) is never reached.
(
  cd "$GSTACK_DIR" || exit 1
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bash ./setup --quiet
) >/tmp/gstack-setup.log 2>&1
if [ $? -ne 0 ]; then
  log "gstack ./setup exited non-zero, see /tmp/gstack-setup.log (non-fatal)"
fi

exit 0
