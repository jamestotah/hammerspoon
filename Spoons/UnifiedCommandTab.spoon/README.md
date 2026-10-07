# UnifiedCommandTab Spoon

`UnifiedCommandTab` combines ordinary application windows, Google Chrome tabs,
Dia tabs, and visible Spokenly windows in one most-recently-used Command-Tab
switcher.

## Install

Copy the `UnifiedCommandTab.spoon` folder into `~/.hammerspoon/Spoons/`, then
load and start it from `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("UnifiedCommandTab")
spoon.UnifiedCommandTab:start()
```

The repository's own `init.lua` also adds an optional `⌘Tab` menu-bar item.
Other configurations can omit that menu; the Spoon works without it.

## API

- `spoon.UnifiedCommandTab:start()` starts the event tap, window/application
  watchers, and browser metadata polling. It is safe to call more than once.
- `spoon.UnifiedCommandTab:stop()` stops those resources.
- `spoon.UnifiedCommandTab:isEnabled()` reports whether the custom switcher is
  enabled.
- `spoon.UnifiedCommandTab:addMenuItems(items)` appends a toggle and status item
  to an existing Hammerspoon menu item list.
- `spoon.UnifiedCommandTab:setMenuRefresh(callback)` registers a callback used
  to refresh a host configuration's menu after the toggle changes.

The enabled state is stored in Hammerspoon settings under
`unifiedCmdTab.enabled`, preserving the setting used by the original module.
The Spoon requires macOS Accessibility permission for keyboard/window events
and may request Automation permission to read and select browser tabs.

## Supported targets

| Target | Identity | Selection |
| --- | --- | --- |
| Ordinary app window | Bundle ID or application name + window ID | Focus the window after verifying its application identity |
| Google Chrome tab | Browser + tab ID | Activate its window and tab index |
| Dia tab | Browser + tab ID | Use Dia's `focus tab` AppleScript command |
| Spokenly | Application bundle ID | Activate the visible app |

See the repository's [Unified Command-Tab guide](../../docs/unified-command-tab.md)
for keyboard behavior, permissions, performance details, and extension guidance.

## License

MIT. See the repository's `LICENSE` file.
