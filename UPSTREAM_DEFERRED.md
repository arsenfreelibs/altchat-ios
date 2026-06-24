# Deferred Upstream Integration

Tracks upstream (deltachat-ios) work that was **intentionally not merged** because it
requires real integration, not just conflict resolution. See [CLAUDE.md](CLAUDE.md) for the
normal sync workflow.

---

## 1. Liquid Glass chat-input rewrite (PR #3104, #3155) — **HIGH effort, HIGH risk**

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
custom attach/send/media buttons) onto upstream's new SwiftUI input architecture — OR apply
iOS 26 glass styling to our existing UIKit buttons without adopting the rewrite (cheaper, keeps
our features; wrap buttons/containers in `UIGlassEffect` / `.glassEffect` on iOS 26 only).

---

## 2. Smaller upstream features colliding with our forks — **MEDIUM effort**

These touch files we keep as ours, so they conflict and need manual porting (not clean cherry-picks):

- **Background voice/audio playback (#3090)** — `AudioController`. Upstream adds
  `MPNowPlayingInfoCenter` (lock screen / Control Center), `MPRemoteCommandCenter`
  (play/pause/stop/scrub from lock screen, headphones, CarPlay), and audio-session interruption
  handling. Our `AudioController` has the richer in-app side (mini-player, waveform, playback
  rate, autoplay, seek). These are complementary — port upstream's OS-integration block in.
  - **Bug to fix regardless:** our `audioRouteChanged` calls `resumeSound()` on headphone unplug
    ([AudioController.swift](deltachat-ios/Chat/AudioController.swift)); it should **pause**
    (upstream behavior). Apple HIG: pause when the route's old device becomes unavailable.
- **Outgoing ringback + call status (#3094)** — `CallViewController`. LOW effort: the helper
  (`OutgoingRingbackPlayer.swift`), the `outgoing-ringback.caf` asset, and strings
  (`call_ringing`, `call_status_*`) are simple to add. Port the `CallStatus { connecting,
  ringing, accepted }` enum + the few `updateCallStatus()` calls and wire to our existing
  `statusLabel` / `ringingDots`. Gains the audible dial tone + explicit connecting/ringing states
  (our UI already has gradient/glow/avatar).
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
