#!/bin/bash
# Safe Exam Browser preflight + install/update + launch â€” macOS
#
# Usage (after uploading to S3):
#   curl -fsSL https://s3.us-east-1.amazonaws.com/staging_shared/seb-launch/seb-launch.sh | bash -s -- "SEB"
#
# The single argument is the contest code (e.g. "SEB"), not the full seb:// URL.
# It's substituted into the fixed exam-config URL template below.
# If no contest code is given, SEB is just installed/updated and opened normally.

set -euo pipefail

# ---- Pinned fallback, used only if the GitHub API lookup below fails/is blocked ----
FALLBACK_MAC_VERSION="3.7"
FALLBACK_MAC_DMG_URL="https://github.com/SafeExamBrowser/seb-mac/releases/download/3.7/SafeExamBrowser-3.7.dmg"

# ---- Exam config URL template; only the contest code varies per exam ----
SEB_URL_TEMPLATE="seb://www.codechef.com/api/assess/%s/seb-config"

CONTEST_CODE="${1:-}"
START_URL=""
if [[ -n "$CONTEST_CODE" ]]; then
  START_URL=$(printf "$SEB_URL_TEMPLATE" "$CONTEST_CODE")
fi
LOG_FILE="/tmp/seb-launch-$(date +%Y%m%d-%H%M%S).log"
APP_PATH="/Applications/Safe Exam Browser.app"
BUNDLE_ID_PRIMARY="org.safeexambrowser.SafeExamBrowser"
BUNDLE_ID_ALT="org.safeexambrowser.Safe-Exam-Browser"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ---- 0. OS guard ----
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only supports macOS. Safe Exam Browser has no native Linux client." >&2
  exit 1
fi

log "Safe Exam Browser preflight starting on macOS $(sw_vers -productVersion) ($(uname -m))"

# ---- 1. Quit any running SEB cleanly ----
if pgrep -x "Safe Exam Browser" >/dev/null 2>&1; then
  log "Quitting running Safe Exam Browser..."
  osascript -e 'tell application "Safe Exam Browser" to quit' >/dev/null 2>&1 || true
  sleep 2
  pkill -x "Safe Exam Browser" >/dev/null 2>&1 || true
fi

# ---- 2. Determine installed vs. latest version ----
installed_version=""
if [[ -d "$APP_PATH" ]]; then
  installed_version=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
fi

latest_version="$FALLBACK_MAC_VERSION"
dmg_url="$FALLBACK_MAC_DMG_URL"
api_json=$(curl -fsSL --max-time 6 "https://api.github.com/repos/SafeExamBrowser/seb-mac/releases/latest" 2>/dev/null || true)
if [[ -n "$api_json" ]]; then
  api_tag=$(echo "$api_json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  api_dmg=$(echo "$api_json" | grep -m1 '"browser_download_url":[^,]*\.dmg"' | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
  if [[ -n "$api_tag" && -n "$api_dmg" ]]; then
    latest_version="$api_tag"
    dmg_url="$api_dmg"
  else
    log "Could not parse GitHub release info, using pinned fallback version $FALLBACK_MAC_VERSION"
  fi
else
  log "GitHub API unreachable, using pinned fallback version $FALLBACK_MAC_VERSION"
fi

version_ge() { [ "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -n1)" ]; }

needs_install=true
if [[ -n "$installed_version" ]] && version_ge "$installed_version" "$latest_version"; then
  needs_install=false
  log "Installed SEB $installed_version is up to date (latest: $latest_version)."
else
  log "Installed SEB version: ${installed_version:-none}. Latest available: $latest_version. Will (re)install."
fi

# ---- 3. Install/update if needed ----
if $needs_install; then
  # Only clear prefs on reinstall â€” wiping them every launch trips SEB's own
  # tamper check, which shows "SEB local preference has been reset".
  log "Clearing cached SEB preferences/logs..."
  defaults delete "$BUNDLE_ID_PRIMARY" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID_ALT" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Logs/Safe Exam Browser" 2>/dev/null || true

  TMP_DIR=$(mktemp -d /tmp/seb-install.XXXXXX)
  MOUNT_DIR=$(mktemp -d /tmp/seb-mount.XXXXXX)
  cleanup() {
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR" "$MOUNT_DIR"
  }
  trap cleanup EXIT

  if [[ -d "$APP_PATH" ]]; then
    log "Removing existing Safe Exam Browser installation..."
    sudo rm -rf "$APP_PATH"
  fi

  log "Downloading Safe Exam Browser $latest_version..."
  DMG_PATH="$TMP_DIR/SafeExamBrowser.dmg"
  curl -fsSL "$dmg_url" -o "$DMG_PATH"

  log "Mounting installer image..."
  hdiutil attach -nobrowse -noautoopen -quiet -mountpoint "$MOUNT_DIR" "$DMG_PATH"

  SRC_APP=$(find "$MOUNT_DIR" -maxdepth 1 -iname "*.app" | head -1)
  if [[ -z "$SRC_APP" ]]; then
    log "ERROR: no .app bundle found inside installer image."
    exit 1
  fi

  log "Installing to /Applications..."
  sudo ditto "$SRC_APP" "$APP_PATH"
  sudo xattr -cr "$APP_PATH" || true

  log "Safe Exam Browser $latest_version installed."
fi

# ---- 4. Known-conflict reminder (TCC permissions cannot be granted non-interactively) ----
log "NOTE: if SEB hangs on first launch, grant it Screen Recording/Accessibility access in"
log "      System Settings > Privacy & Security, then relaunch."

# ---- 5. Launch with the exam start URL ----
if [[ -n "$START_URL" ]]; then
  log "Launching Safe Exam Browser with start URL..."

  # Force-kill the terminal we're running in ourselves, right after the open
  # request is dispatched â€” no confirmation, no Automation permission needed â€”
  # so SEB's own "close Terminal" kiosk prompt never fires (that prompt is what
  # makes people re-run the command and double-launch). `open` runs in the
  # foreground first: backgrounding it alongside the killall raced the two, and
  # killall could win before `open` had actually handed the launch request to
  # Launch Services, killing the terminal (and this script, and the in-flight
  # open) before SEB ever launched.
  open "$START_URL"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      killall -9 Terminal >/dev/null 2>&1 &
      wait
      ;;
    iTerm.app)
      killall -9 iTerm2 >/dev/null 2>&1 &
      wait
      ;;
  esac
else
  log "No start URL supplied, opening Safe Exam Browser normally."
  open -a "Safe Exam Browser"
fi

log "Done. Log saved to $LOG_FILE"
