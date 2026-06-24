# Alt Chat iOS — Claude Rules

## Project Overview

This is **alt.chat** (`me.alt.chat`), a fork of [deltachat/deltachat-ios](https://github.com/deltachat/deltachat-ios).

- **iOS repo (this):** `arsenfreelibs/altchat-ios` — branch `main`
- **Rust core submodule:** `arsenfreelibs/core.git` — branch `develop` (at `deltachat-ios/libraries/deltachat-core-rust/`)
- **Upstream iOS:** `upstream` remote → `deltachat/deltachat-ios`
- **Upstream rust:** `upstream` remote → `deltachat/deltachat-core-rust`
- **Support email:** `child.aplic@gmail.com`

---

## Full Upstream Sync Checklist

Сначала проверь что нового:
```bash
scripts/check-upstream.sh
```

Выполнять строго по порядку:

```
[ ] 1. Rust: fetch + merge upstream/main в arsenfreelibs/core develop
[ ] 2. Rust: проверить брендинг (grep), починить если нужно
[ ] 3. Rust: push origin develop
[ ] 4. iOS: обновить submodule pointer → git add + commit
[ ] 5. iOS: пересобрать libdeltachat.a (см. раздел Building)
[ ] 6. iOS: fetch + merge upstream/main в origin/main
[ ] 7. iOS: проверить брендинг (grep), починить если нужно
[ ] 8. iOS: push origin main
```

Детальные команды — в секциях ниже.

---

## CRITICAL: Branding Rules

**NEVER** let any of the following appear in user-facing strings, UI, or `.strings` files:

| Forbidden | Replace with |
|-----------|-------------|
| `Delta Chat` | `alt.chat` |
| `DeltaChat` | `alt.chat` |
| `Delta-Chat` | `alt.chat` |
| `delta.chat/download` | `alt-chat.me/app/` |
| `get.delta.chat` | `alt-chat.me/app/` |
| `delta.chat/help` | `alt-chat.me/help` |
| `delta.chat/donate` | `alt-chat.me/donate` |
| `providers.delta.chat` | `alt-chat.me/providers` |
| `securejoin.delta.chat` | `alt-chat.me/securejoin` |
| `support.delta.chat` | `alt-chat.me` |
| `deltachat.org` | *(remove)* |
| `delta@merlinux.eu` | `child.aplic@gmail.com` |

**Do NOT change:**
- `github.com/deltachat/` links (source references)
- Rust crate names (`deltachat`, `deltachat-rpc-server`)
- `i.delta.chat` protocol invitation links
- HTML anchor IDs like `#what-is-delta-chat`

After every merge, scan for leaks:
```bash
grep -rn "Delta Chat\|DeltaChat\|delta\.chat\|deltachat\.org\|delta@merlinux\|support\.delta\.chat\|get\.delta\.chat" \
  deltachat-ios/ \
  --include="*.swift" --include="*.strings" --include="*.html" --include="*.rs" \
  --exclude-dir=".git" --exclude-dir="target"
```

---

## Workflow: Merging Upstream Rust (Step 1)

Rust submodule lives at `deltachat-ios/libraries/deltachat-core-rust/`, branch `develop`.

```bash
# 1. Check what's new
git -C deltachat-ios/libraries/deltachat-core-rust fetch upstream
git -C deltachat-ios/libraries/deltachat-core-rust log HEAD..upstream/main --oneline

# 2. Merge
git -C deltachat-ios/libraries/deltachat-core-rust merge upstream/main

# 3. Resolve conflicts:
#    - User-facing strings → keep our branding (manually edit)
#    - Logic/bug fixes → take upstream

# 4. Scan for branding leaks (see above)

# 5. Fix any leaked strings, commit
git -C deltachat-ios/libraries/deltachat-core-rust add -p
git -C deltachat-ios/libraries/deltachat-core-rust merge --continue

# 6. Push rust fork
git -C deltachat-ios/libraries/deltachat-core-rust push origin develop
```

### Known rust branding fixes (re-check after each merge):

| File | What to fix |
|------|-------------|
| `src/accounts.rs` | "Delta Chat is already running..." → "Alt Chat is already running..." |
| `src/sql.rs` | DB update error → use `child.aplic@gmail.com` |
| `src/receive_imf.rs` | "using Delta Chat on multiple devices" → "Alt Chat" |
| `src/imex.rs` | "newer version of Delta Chat" + test assertions → "Alt Chat" |
| `src/webxdc.rs` | "requires a newer Delta Chat version" → "alt.chat version" |
| `src/qr/dclogin_scheme.rs` | "DeltaChat does not understand this QR Code" → "alt.chat" |

---

## Workflow: Updating iOS Submodule Pointer + Rebuild (Step 2)

After pushing rust, update the iOS repo to point to the new rust commit and rebuild the library:

```bash
# Verify submodule is on latest develop
git -C deltachat-ios/libraries/deltachat-core-rust log --oneline -1

# Stage the new submodule pointer
git add deltachat-ios/libraries/deltachat-core-rust
git commit -m "chore: update rust submodule to latest develop"

# Rebuild libdeltachat.a (required — Xcode does NOT do this automatically)
ACTION=build \
PLATFORM_NAME=iphoneos \
CONFIGURATION=Debug \
ARCHS="arm64" \
IPHONEOS_DEPLOYMENT_TARGET=14.0 \
CARGO_PROFILE_DEV_LTO=true \
RUSTFLAGS="-C embed-bitcode=yes" \
cargo +1.91.1 lipo \
  --xcode-integ \
  --no-sanitize-env \
  --manifest-path deltachat-ios/libraries/deltachat-core-rust/deltachat-ffi/Cargo.toml
```

---

## Workflow: Merging Upstream iOS (Step 3)

```bash
# 1. Check what's new
git fetch upstream
git log HEAD..upstream/main --oneline

# 2. Merge
git merge upstream/main

# 3. Conflict resolution strategy:

#    ALWAYS keep ours:
#    - deltachat-ios/**/*.strings  (all languages — we have branding replacements)
#    - deltachat-ios/*/Help/**/*.html  (help pages — we have URL replacements)
#    - deltachat-ios/libraries/deltachat-core-rust  (submodule pointer — we control this)
#    - deltachat-ios.xcodeproj/project.pbxproj  (MARKETING_VERSION, CURRENT_PROJECT_VERSION)

#    TAKE upstream (new strings/features):
#    - If upstream adds NEW keys to Localizable.strings that we don't have → take them
#    - Logic fixes in Swift files → take upstream, then verify our custom code still present

# 4. After merge: scan for branding leaks (see above)

# 5. Push
git push origin main
```

### Key custom features to preserve during iOS merges:

- **`AutoProxyManager.swift` / `AutoProxyConstants.swift`** — auto-proxy obfuscated logic
- **`scripts/gen_autoproxy_obf.py`** — proxy config obfuscation script
- **Version scheme** `MARKETING_VERSION = 1.0.xx` / `CURRENT_PROJECT_VERSION = 1` — never take upstream's versioning

---

## Building libdeltachat.a

The static library must be rebuilt manually after rust submodule updates. Run from the iOS project root:

```bash
ACTION=build \
PLATFORM_NAME=iphoneos \
CONFIGURATION=Debug \
ARCHS="arm64" \
IPHONEOS_DEPLOYMENT_TARGET=14.0 \
CARGO_PROFILE_DEV_LTO=true \
RUSTFLAGS="-C embed-bitcode=yes" \
cargo +1.91.1 lipo \
  --xcode-integ \
  --no-sanitize-env \
  --manifest-path deltachat-ios/libraries/deltachat-core-rust/deltachat-ffi/Cargo.toml
```

Output: `deltachat-ios/libraries/deltachat-core-rust/target/universal/debug/libdeltachat.a`

Requires: Rust 1.91.1 toolchain + `cargo-lipo` + iOS targets (`aarch64-apple-ios`, `x86_64-apple-ios`).

---

## Checking for New Upstream Commits

```bash
# iOS
git fetch upstream
git log HEAD..upstream/main --oneline

# Rust
git -C deltachat-ios/libraries/deltachat-core-rust fetch upstream
git -C deltachat-ios/libraries/deltachat-core-rust log HEAD..upstream/main --oneline
```

---

## Quick Build Commands

```bash
# Установить/обновить зависимости (после изменений Podfile):
pod install

# Открыть проект в Xcode:
open deltachat-ios.xcworkspace

# Сборка из командной строки:
xcodebuild -workspace deltachat-ios.xcworkspace \
  -scheme deltachat-ios \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## Code Style (SwiftLint / SwiftFormat)

SwiftLint и SwiftFormat запускаются **автоматически при каждой сборке в Xcode** (через Run Script фазы CocoaPods).

Запустить вручную перед коммитом:
```bash
Pods/SwiftLint/swiftlint
Pods/SwiftFormat/CommandLineTool/swiftformat .
```

Конфиги: `.swiftlint.yml` и `.swiftformat` в корне проекта.

---

## Version Bumping

- `deltachat-ios.xcodeproj/project.pbxproj`: bump `MARKETING_VERSION` (e.g. `1.0.20`) before release
- `CURRENT_PROJECT_VERSION` stays `1`
- Never adopt upstream's version numbers

---

## Android Fork Sync

Android project at `/Users/romanvalchuk/Projects/alt-chat-android` also uses the same rust submodule.
After pushing rust `develop`, check if Android needs updating too:
```bash
git -C /Users/romanvalchuk/Projects/alt-chat-android/jni/deltachat-core-rust log --oneline -1
```
