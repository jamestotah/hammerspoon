# Repository instructions

- This is a personal Hammerspoon configuration, not a packaged Lua project. `init.lua` is the live entry point; it loads both Spoons and wires their menu-bar and display-watcher behavior.
- `Spoons/ArrangeDesktop.spoon/config.json` is machine-specific state (display UUIDs, coordinates, app names) and is intentionally Git-ignored. Never add live contents to commits; use `config.example.json` for portable examples.
- `Spoons/ArrangeDesktop.spoon` is an upstream Spoon; keep its attribution and license metadata intact. Repository-specific switcher behavior lives in `Spoons/UnifiedCommandTab.spoon/init.lua`.
- Run the isolated regression suite from the repository root with `lua tests/run.lua` (Lua 5.2+), or with Hammerspoon's runtime using `hs -c 'dofile("/absolute/checkout/tests/run.lua")'`. Tests use private globals and mocks; they do not verify native macOS focus, accessibility, or browser automation.
- Live verification scripts under `scripts/` require a running Hammerspoon and relevant macOS apps. Read `docs/unified-command-tab-verification.md` before running them: some tests change focus temporarily, and benchmarks have specific prerequisites. Prefer the isolated suite for routine changes.
- Keep machine-specific or privacy-sensitive test output outside the repository; verification scripts may require a writable report path.
