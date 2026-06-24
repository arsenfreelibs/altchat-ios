# Deferred Upstream Integration

Tracks upstream (deltachat-ios) work that was **intentionally not merged** because it
requires real integration, not just conflict resolution. See [CLAUDE.md](CLAUDE.md) for the
normal sync workflow.

---

## 1. Liquid Glass chat-input rewrite (PR #3104, #3155) — **HIGH effort, HIGH risk**

> **HARD BLOCKER: requires Xcode 26 / iOS 26 SDK.** Any Liquid Glass adoption (`UIGlassEffect`
> in UIKit *or* SwiftUI `.glassEffect`) needs the iOS 26 SDK. As of 2026-06-24 the build machine
> has **Xcode 16.4 / iOS 18.5 SDK only** — these symbols don't exist, so nothing glass-related
> compiles. Also note: even on an iOS 26 *device*, an app built with the 18.5 SDK renders in
> compatibility mode (no glass). Upgrade Xcode first. This blocker applies to both this rewrite
> AND the cheaper "glass on our existing UIKit buttons" idea below.

**Status:** deferred on 2026-06-24. Rust core was synced (submodule `ae71b5e0d`); the iOS
`upstream/main` merge (19 commits up to `db5bbb667`) was **rolled back** because PR #3104
structurally rewrote the entire chat-input subsystem and is incompatible with our fork's
custom UIKit input bar (video/audio notes, locked recording, preview bars).

### Why a plain merge breaks
Upstream **deleted ~26 files** that our kept `ChatViewController` depends on, and replaced
them with a SwiftUI stack:

Deleted by upstream (we still depend on these):
- `deltachat-ios/Chat/InputBarAccessoryView/` — entire UIKit lib: `InputBarAccessoryView.swift`,
  `InputStackView.swift`, `InputTextView.swift`, `Controls/InputBarButtonItem.swift`,
  `Controls/InputBarSendButton.swift`, `Protocols/InputItem.swift`, `Protocols/InputPlugin.swift`,
  `Protocols/InputBarAccessoryViewDelegate.swift`, `Models/NSConstraintLayoutSet.swift`,
  `Models/HorizontalEdgePadding.swift`, `Extensions/*`, `KeyboardManager/*`, `SeparatorLine.swift`
- `deltachat-ios/Chat/Views/` — `DraftArea.swift`, `DraftPreview.swift`, `MediaPreview.swift`,
  `QuotePreview.swift`, `DocumentPreview.swift`, `ContactCardPreview.swift`
- `deltachat-ios/Controller/PartialScreenPresentationController.swift`

Added by upstream (the SwiftUI replacement):
- `InputBarAccessoryView/InputBarView.swift` (real iOS 26 `.glassEffect` / `GlassEffectContainer`
  / `.buttonStyle(.glass)`, gated on `isLiquidGlassEnabled` = iOS 26+), `InputBarTextView.swift`
- `Chat/Views/QuoteViewSwiftUI.swift`, `FileViewRepresentable.swift`, `ContactCardViewRepresentable.swift`
- `Helper/SwiftUI/UncachedMenu.swift`, `View+calculatedSize.swift`, `View+modifier.swift`
- Moved: `KeyboardManager/*`, `Helper/UIView+AutoLayout.swift`, `Helper/UIToolbar+AutoLayout.swift`

### What integration requires (option 3)
Port our custom features (video notes, inline audio notes, locked recording, preview bars,
custom attach/send/media buttons) onto upstream's new SwiftUI input architecture.

> **Tried & rejected (2026-06-25):** the cheaper shortcut — wrapping our existing UIKit
> attach/send/media buttons in `UIGlassEffect` (tinted with `DcColors.primary`, gated on
> `if #available(iOS 26.0, *)`) — compiled fine under Xcode 26.5 but was **disliked visually**
> and reverted. So the only remaining path to Liquid Glass is the full upstream SwiftUI rewrite
> (this section), not a quick glass-on-our-buttons patch.

---

## 2. Smaller upstream features colliding with our forks — **MEDIUM effort**

These touch files we keep as ours, so they conflict and need manual porting (not clean cherry-picks):

- **Background voice/audio playback (#3090)** — ✅ **DONE (2026-06-24).** Ported into our
  `AudioController`: `MPNowPlayingInfoCenter` (lock screen / Control Center — title, chat name,
  sender-avatar artwork, duration/elapsed/rate), `MPRemoteCommandCenter` (play/pause/toggle/stop,
  ±15s skip, draggable scrubber; next/previous-track disabled), and audio-session interruption
  handling (pause on interruption, resume after). Background `audio` mode was already in Info.plist.
  Manually verified on device (background playback + headphone pause/resume + skip). Our in-app
  side (mini-player, waveform, playback rate, autoplay) was kept.
  - ✅ Headphone-unplug bug also fixed: `audioRouteChanged` now pauses instead of resuming.
- **Outgoing ringback + call status (#3094)** — **ALREADY COVERED in our fork, do NOT port.**
  Our `CallViewController` has its own `RingbackPlayer` (synthetic 440+480 Hz US ringback via
  AVAudioEngine, started on outgoing call, stopped on connect) plus a `statusLabel` with localized
  connecting/ringing text + animated dots + a call-duration timer. This is equivalent-or-better than
  upstream's `.caf`-based `OutgoingRingbackPlayer` + `CallStatus` label. Nothing to gain.
- **Audio recorder session routing (#3151)** — overlaps recorder/audio session handling.

## 3. Clean / isolated upstream improvements — safe to cherry-pick

- **Cache thumbnails (#3143)** — `Helper/Thumbnails.swift` + hook points.
- **Fix incorrect "contact is me" check (#3145)** — isolated logic fix.
- **Cancel-button `.cancel`/destructive semantics** — mechanical, broad but low-risk.

---

## How to resume
1. `scripts/check-upstream.sh` to see current upstream state.
2. For option 3, branch off and integrate the input-bar rewrite deliberately (do **not** take
   upstream's file deletions while keeping our `ChatViewController`).
3. Re-merge `upstream/main` once the input subsystem is reconciled.
