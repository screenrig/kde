# screenRIG for KDE Plasma

**[screenRIG](https://screenrig.ai) is free digital signage driven by your AI
agent.** Tell Claude Code, Codex or another agent what to show, and it puts
menus, dashboards, announcements, photos, video and live web pages on any TV,
kiosk or display, with 200+ ready-made apps and
[a Player for every screen](https://screenrig.ai/docs/players). Start at
**[screenrig.ai](https://screenrig.ai)**.

This Plasma 6 widget brings your screenRIG screens to the KDE desktop: see every
screen, cast your desktop or an app window live to the TVs around you, and send
a capture, a link or a file to any screen.

## What it does

- **Panel chip**: the screenRIG mark in your panel with the online and offline
  counts, and a red dot when a screen drops, credits run low or a cast is live.
  Click for the panel, middle-click to stop a live cast; right-click to cast a
  region capture or the clipboard.
- **Screens**: every screen with its latest screenshot, what it plays and when
  it was last seen. Reload, switch playlist, turn the display off, override
  for a while, take a fresh screenshot, restart, or open it in the dashboard.
- **Cast**: a live cast of your desktop or one app window to Android and Linux
  Players on your network, chosen in Plasma's own screen-share dialog, until
  you stop it or for a set time; or a region capture, the clipboard (an https
  link or an image) or a file, for 5 to 60 minutes. Images and video also
  have **Open With > Cast to a screenRIG screen** in Dolphin.
- **Project switcher** in the panel's header, and notifications when a screen
  goes offline or comes back, a publish reaches its screens, credits run low,
  an ad booking needs review, or a live cast starts or stops.

## Install

From Plasma: right-click the panel, **Add Widgets > Get New Widgets > Download
New Plasma Widgets**, search for **screenRIG** and install it, then drag it
onto your panel.

From a checkout:

```sh
./install.sh
```

On first open the panel detects the official
[screenRIG plugin](https://github.com/screenrig/plugin) in Claude Code, Codex
and Grok. If it needs installing, **Install** adds its skill and CLI to the
agent named in the panel. **Sign in** approves this computer at screenrig.ai.
Already have the plugin and `screenrig login`? The panel uses that sign-in
(`~/.config/screenrig/config.json`) and lets the CLI renew it.

## Remove

Right-click the chip, choose **Undo screenRIG's changes to this computer**,
then remove the widget. From a checkout, `./install.sh --uninstall` does both.

## What it changes on your system

On first load it adds, and **Undo screenRIG's changes** removes:

- an **Open With** entry, `~/.local/share/applications/screenrig-kde-send.desktop`;
- its own folders: `~/.local/state/screenrig-kde` (cast history, the
  background follower's state), `~/.cache/screenrig-kde` (screenshots,
  captures, logs) and `~/.local/share/screenrig-kde` (mediamtx, below).

**Install** on the first-run card runs Claude Code, Codex or Grok's own
plugin installer for github.com/screenrig/plugin; remove it with that agent's
plugin commands.

Live casting changes one more thing, only after you press **Allow** in the
Cast tab: a firewall rule letting your LAN subnet reach TCP 8554 (the stream).
With firewalld (Fedora, openSUSE) it is a rich rule in the zone of your
network connection, runtime and permanent, and Plasma asks for your password;
with ufw (Kubuntu, KDE neon) it is a `ufw allow` rule. The rule is recorded,
and Undo removes exactly that rule.

A cast asks which screen or window through Plasma's own screen-share dialog,
the same consent every other app gets, and Plasma shows that the screen is
shared while it runs; its Stop ends the cast. The widget does not touch the
portal's configuration or remember a choice.

## Requirements

- KDE Plasma 6, Python 3 with PyGObject (`python3-gobject`).
- The screenRIG agent plugin and its bundled CLI (Node.js), signed in: the
  first-run card installs both.
- Spectacle for region captures, kdialog for files, and wl-clipboard for
  images on the clipboard (links work without it).
- Live casting: GStreamer with its PipeWire plugin and an H.264 encoder (VA-API,
  NVENC, x264 or OpenH264; the widget uses the first that works), and ffmpeg.
  On the first cast the widget downloads
  [mediamtx](https://github.com/bluenviron/mediamtx) v1.21.3, checks it against
  the SHA-256 pinned in its source and keeps it in
  `~/.local/share/screenrig-kde/bin`; it serves RTSP over TCP on port 8554 and
  nothing else. Each cast has its own random login, which the screens receive
  in the stream address, and a second one that publishing needs, used only by
  the capture on this computer. Screens reach it on the same network: Android
  and Linux Players.

## Development

```sh
python3 -m unittest discover -s tests
kpackagetool6 -t Plasma/Applet -u package   # or -i the first time
plasmawindowed ai.screenrig.plasma          # the panel in a window
```

## License

MIT, see [LICENSE](LICENSE).
