# Unified Command-Tab

The `UnifiedCommandTab` Spoon makes application windows and selected browser
tabs share one most-recently-used history. Its implementation is in
`Spoons/UnifiedCommandTab.spoon/init.lua`; load and start it with
`hs.loadSpoon("UnifiedCommandTab")` and
`spoon.UnifiedCommandTab:start()`.

## Supported targets

| Target | Identity tracked | Selection mechanism |
| --- | --- | --- |
| Ordinary app window | Bundle ID or application name + window ID | Focus the window after verifying its application identity |
| Google Chrome tab | Browser + tab ID | Activate the window and tab index |
| Dia tab | Browser + tab ID | Use Dia's `focus tab` AppleScript command |
| Spokenly | Application bundle ID | Activate the visible app |

The history is capped at 100 entries. Closed windows are removed when Hammerspoon
reports their destruction; periodic browser snapshots prune closed tabs. Browser
titles are refreshed asynchronously so the key event path does not block on
AppleScript.

## Keyboard behavior

- `⌘Tab`: begin or advance the switcher in MRU order.
- `⌘⇧Tab`: move backward.
- Release `⌘`: activate the highlighted target and close the overlay.
- Press `Tab` repeatedly while holding `⌘`: change the highlight without
  activating every intermediate window.

The native switcher's relevant key events are suppressed only while this
switcher is active. Other combinations, such as `⌘⌥Tab`, pass through.

## Menu and persistence

The second menu-bar item is labeled `⌘Tab`. Its menu can toggle the feature on
or off. The setting is stored using Hammerspoon's settings API under
`unifiedCmdTab.enabled`, so a reload keeps the last choice.

## Permissions

Accessibility permission is required for event monitoring and window focus.
Automation permission may be requested for Google Chrome and Dia because the
module uses `/usr/bin/osascript` to read active tabs and select a tab. If a
browser does not appear in the switcher:

1. confirm the browser has at least one window;
2. reload Hammerspoon;
3. check **System Settings → Privacy & Security → Automation**; and
4. use the menu to confirm **Unified ⌘Tab** is enabled.

## Performance design

Browser reads run as Hammerspoon tasks rather than synchronously in the event
tap. A 500 ms polling interval balances fresh tab history with responsiveness.
Overlay redraws are coalesced onto the next run-loop turn, and the selected
target is activated exactly once when the modifier is released.

## Extending the switcher

To add a browser or accessory application, update the allowlist near the top of
`Spoons/UnifiedCommandTab.spoon/init.lua`, then implement its read and selection
AppleScript paths.
Keep these rules intact:

- never block the keyboard event callback with a browser query;
- use a stable identity for each target;
- avoid recording intermediate focus changes during a cycle; and
- remove targets when their window or application disappears.

## Synthetic illustration

![Synthetic Unified Command-Tab overlay illustration](../docs/assets/unified-command-tab.svg)

This SVG is a made-up illustration for documentation. It is not a capture of
Chrome, Dia, Spokenly, or any actual browser session.
