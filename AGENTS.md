# screenRIG for KDE Plasma

Plasma 6 widget `ai.screenrig.plasma` (`package/`), ported from the Omarchy
plugin (`screenrig/omarchy`), which stays the source of truth for features and
wording. `package/contents/bin/screenrig-kde` began as a copy of that repo's
`bin/screenrig-omarchy`; carry API, auth and live-cast fixes across in both
directions.

- The widget runs commands through Plasma's executable engine, which returns
  output only when a command exits: `serve` follows the project in the
  background and writes `feed.json`, and `Service.qml` keeps one `wait`
  running, which returns as soon as the feed or a summon changes. `serve`
  exits a while after the last `wait`.
- Desktop parts are freedesktop or KDE: `notify-send` (actions run through a
  detached `notice`), Spectacle, kdialog, the ScreenCast portal and
  GStreamer. A cast always goes through Plasma's screen-share dialog; never
  answer the portal for the person or keep a restore token.
- Opening the panel never asks for a password: firewalld zones are read over
  D-Bus only when `pkcheck` says `config.info` is allowed without one.
  `firewall-cmd` runs only after Allow and in teardown.
- Teardown removes everything the widget made (README "What it changes").
- Auth: the helper reads the screenRIG CLI config and never refreshes tokens
  itself; a free CLI call lets the CLI rotate the refresh token.
- Never print fleet links.

Gate: `python3 -m unittest discover -s tests`. Check UI changes from a
screenshot of the real widget (`plasmawindowed ai.screenrig.plasma`).
