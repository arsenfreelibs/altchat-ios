#!/bin/bash
# Check for new upstream commits in rust + iOS and scan for branding issues.

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$IOS_ROOT/deltachat-ios/libraries/deltachat-core-rust"

echo -e "${BOLD}=== Fetching upstreams ===${NC}"
git -C "$RUST_DIR" fetch upstream --quiet
git -C "$IOS_ROOT" fetch upstream --quiet
echo "Done."

# ── Rust ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}=== Rust: new upstream commits ===${NC}"
RUST_COMMITS=$(git -C "$RUST_DIR" log origin/develop..upstream/main --oneline)

if [ -z "$RUST_COMMITS" ]; then
  echo -e "${GREEN}✓ No new rust commits${NC}"
else
  echo "$RUST_COMMITS"
  RUST_COUNT=$(echo "$RUST_COMMITS" | wc -l | tr -d ' ')
  echo -e "${YELLOW}→ $RUST_COUNT new commit(s)${NC}"
fi

# ── iOS ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}=== iOS: new upstream commits ===${NC}"
IOS_COMMITS=$(git -C "$IOS_ROOT" log origin/main..upstream/main --oneline)

if [ -z "$IOS_COMMITS" ]; then
  echo -e "${GREEN}✓ No new iOS commits${NC}"
else
  echo "$IOS_COMMITS"
  IOS_COUNT=$(echo "$IOS_COMMITS" | wc -l | tr -d ' ')
  echo -e "${YELLOW}→ $IOS_COUNT new commit(s)${NC}"
fi

# ── Branding scan ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}=== Branding scan ===${NC}"
BRANDING_HITS=$(grep -rn \
  "Delta Chat\|DeltaChat\|Delta-Chat\|delta\.chat\|deltachat\.org\|delta@merlinux\|support\.delta\.chat\|get\.delta\.chat" \
  "$IOS_ROOT/deltachat-ios/" \
  --include="*.swift" --include="*.strings" --include="*.html" --include="*.rs" \
  --exclude-dir=".git" --exclude-dir="target" --exclude-dir="deltachat-repl" \
  --exclude-dir="deltachat-contact-tools" --exclude="data.rs" \
  2>/dev/null \
  | grep -v "i\.delta\.chat" \
  | grep -v "github\.com/deltachat" \
  | grep -v "[[:space:]]*//" \
  | grep -v "isDeltaChat\|handleDeltaChat\|DeltaChatInvitation" \
  | grep -v "_tests\.rs:" \
  || true)

if [ -z "$BRANDING_HITS" ]; then
  echo -e "${GREEN}✓ No branding issues${NC}"
else
  echo -e "${RED}⚠ Branding issues found:${NC}"
  echo "$BRANDING_HITS"
fi

# ── AI summary ────────────────────────────────────────────────────────────────
if [ -z "$RUST_COMMITS" ] && [ -z "$IOS_COMMITS" ]; then
  echo ""
  echo -e "${GREEN}Nothing to summarize — all up to date.${NC}"
  exit 0
fi

echo ""
echo -e "${BOLD}${CYAN}=== Summary ===${NC}"

CLAUDE_BIN="${CLAUDE_CODE_EXECPATH:-$(command -v claude 2>/dev/null)}"
if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
  PROMPT="You are helping a developer who maintains 'alt.chat', an iOS fork of Delta Chat. Summarize the following new upstream commits in 2-3 sentences. Focus on user-facing features and important bug fixes. Be concise."

  [ -n "$RUST_COMMITS" ] && PROMPT="$PROMPT

Rust core new commits:
$RUST_COMMITS"

  [ -n "$IOS_COMMITS" ] && PROMPT="$PROMPT

iOS app new commits:
$IOS_COMMITS"

  "$CLAUDE_BIN" -p "$PROMPT"
else
  echo -e "${YELLOW}(install claude CLI to get AI summary)${NC}"
  [ -n "$RUST_COMMITS" ] && echo -e "\nRust: $RUST_COUNT new commit(s)" && echo "$RUST_COMMITS"
  [ -n "$IOS_COMMITS" ] && echo -e "\niOS: $IOS_COUNT new commit(s)" && echo "$IOS_COMMITS"
fi
