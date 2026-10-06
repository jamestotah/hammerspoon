# James Totah's Hammerspoon configuration

Personal macOS automation for restoring multi-monitor workspaces and making
`⌘Tab` useful across applications and browser tabs.

This repository is intentionally personal-account-owned and contains the
portable parts of the configuration. Machine-specific window layouts are not
tracked: `Spoons/ArrangeDesktop.spoon/config.json` is ignored because it can
contain display UUIDs, window coordinates, and the names of locally used apps.

## Features

### Desktop arrangements

The `ArrangeDesktop` Spoon records the current application-window layout for
each connected display. From the `⊞` menu-bar item you can:

- save the current layout under a name;
- restore a saved layout;
- delete an arrangement; and
- automatically reapply the first saved arrangement after displays change.

The first time you use this feature, Hammerspoon creates
`Spoons/ArrangeDesktop.spoon/config.json`. That file remains local to the Mac.
See [the arrangement guide](docs/arrange-desktop.md) for the complete workflow.

### Unified Command-Tab

The `UnifiedCommandTab` Spoon replaces the native application-only switcher
with a most-recently-used list containing:

- ordinary application windows;
- active tabs in Google Chrome;
- active tabs in Dia; and
- Spokenly, when it has a visible window.

Hold `⌘` and press `Tab` to move forward, or `⌘⇧Tab` to move backward. The
switcher draws a lightweight overlay, updates browser metadata asynchronously,
and activates only the selected target when `⌘` is released. Its enabled state
is persisted in Hammerspoon settings and can be toggled from the `⌘Tab` menu.

See [the unified switcher guide](docs/unified-command-tab.md) for behavior,
permissions, troubleshooting, and extension points.

## Install

1. Install [Hammerspoon](https://www.hammerspoon.org/).
2. Clone this repository into Hammerspoon's configuration directory:

   ```sh
   git clone https://github.com/jamestotah/hammerspoon.git ~/.hammerspoon
   ```

   If the directory already contains a configuration, back it up before
   cloning or copy the files into place instead.

3. Open Hammerspoon and choose **Reload Config**.
4. Grant the requested macOS permissions in **System Settings → Privacy &
   Security → Accessibility** and **Automation**. Automation permission is
   needed for the AppleScript calls that inspect and select Chrome or Dia tabs.

## Repository layout

```text
.
├── init.lua                              # Hammerspoon entry point
├── Spoons/UnifiedCommandTab.spoon/
│   ├── init.lua                          # Cross-app/tab MRU switcher Spoon
│   └── README.md                         # Standalone installation and API
├── Spoons/ArrangeDesktop.spoon/
│   ├── init.lua                          # Vendored ArrangeDesktop Spoon
│   ├── config.example.json               # Safe, portable layout example
│   └── config.json                       # Local state; ignored by Git
├── LICENSE                               # MIT license
└── docs/
    ├── arrange-desktop.md
    └── unified-command-tab.md
```

## Privacy and portability

The checked-in code does not contain credentials. Do not commit your live
`config.json`: it is intended to describe one Mac, not to be a portable
profile. When sharing a layout, copy `config.example.json` and replace the
example display identifier and app names with generic values.

The screenshots in this repository are synthetic illustrations of the UI and
are not captures of a real browser session or personal desktop.

## License and upstream attribution

The root configuration is personal work. `UnifiedCommandTab.spoon` is MIT
licensed. The `ArrangeDesktop.spoon` directory retains its upstream attribution
and MIT license metadata.
