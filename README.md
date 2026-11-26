<!--
SPDX-FileCopyrightText: © 2020 The River Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
  <img src="logo/logo_text_adaptive_color.svg" width="600em">
</div>

## river-fx

This is **river-fx**, a fork of [river](https://codeberg.org/river/river)
that draws with [SceneFX](https://github.com/wlrfx/scenefx) instead of
wlroots' scene graph, to give window managers what river's protocol cannot
express: translucent windows, rounded corners and blur.

It differs from river in two things, and tracks it otherwise (branch `fx`,
currently on river 0.5.2):

- it links SceneFX (0.5, with wlroots 0.20) and uses its renderer;
- it adds one protocol, [river-fx-v1](protocol/river-fx-v1.xml), with which
  the window manager sets the opacity, the corner radius, the blur and the
  shadow of each window, and has windows fade out when they close. Borders
  and shadows follow the rounded corners. Layer surfaces (bars, launchers,
  desktop widgets) take rounded corners, blur and shadows by namespace. The
  look of the blur (passes, radius, noise, saturation) can be set too. Windows
  can be dimmed, shrink as they close and cross-fade when they change size;
  layer surfaces can fade in and out; menus can blur what is behind them.

Window managers that do not know the protocol work exactly as on river. It
was written for [rivermonad](https://github.com/prietus/rivermonad), which
uses it when the compositor offers it.

Building needs `scenefx` besides river's dependencies; the commands are the
same as for river, below. river-fx is not affiliated with the river project:
please report its problems here, not to river.

## Overview

River is a non-monolithic Wayland compositor. Unlike other Wayland compositors,
river does not combine the compositor and window manager into one program.
Instead, users can choose any window manager implementing the
[river-window-management-v1] protocol.

Read my blog post, [Separating the Wayland Compositor and Window Manager](https://isaacfreund.com/blog/river-window-management/),
for an in-depth explanation.

There is a [list of compatible window managers] on our [wiki](https://codeberg.org/river/wiki).

> *If you are looking for the old dynamic tiling version of river, see
[river-classic](https://codeberg.org/river/river-classic).*

## Links

- [Protocol Docs](https://isaacfreund.com/docs/wayland/)
- [tinyrwm](https://codeberg.org/river/tinyrwm) example window manager
- [Wiki](https://codeberg.org/river/wiki)
- IRC: [#river](https://web.libera.chat/?channels=#river) on irc.libera.chat ([logs](https://libera.catirclogs.org/river))
- [Zulip](https://river-compositor.zulipchat.com) (new)
- [Issue Tracker](https://codeberg.org/river/river/issues)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Features

River defers all window management policy to a separate window manager
implementing the [river-window-management-v1] protocol. This includes window
position/size, pointer/keyboard bindings, focus management, window decorations,
desktop shell graphics, and more.

River itself provides frame perfect rendering, good performance, support for
many Wayland protocol extensions, robust Xwayland support, the ability to
hot-swap window managers, and more.

The [river-window-management-v1] protocol and other river protocol extensions
are stable.  We do not break window managers.

## Motivation

Why split the window manager to a separate process?

- Significantly lower the barrier to entry for writing a Wayland window manager.
- Allow implementing Wayland window managers in high-level garbage collected
  languages without impacting compositor performance and latency.
- Allow hot-swapping between window managers without restarting the compositor
  and all Wayland programs.
- Promote diversity and experimentation in window manager design.

## Building

Note: If you are packaging river for distribution, see [PACKAGING.md](PACKAGING.md).

To compile river first ensure that you have the following dependencies
installed. The "development" versions are required if applicable to your
distribution.

- [zig](https://ziglang.org/download/) 0.17.1
- wayland
- wayland-protocols
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20
- xkbcommon 1.12 or newer
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:
```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```
To enable Xwayland support pass the `-Dxwayland` option as well.
Run `zig build -h` to see a list of all options.

## Usage

River can either be run nested in an X11/Wayland session or directly
from a tty using KMS/DRM. Simply run the `river` command.

On startup river will run an executable file at `$XDG_CONFIG_HOME/river/init`
if such an executable exists. If `$XDG_CONFIG_HOME` is not set,
`~/.config/river/init` will be used instead.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs.

See also:

- The `river(1)` man page
- The [wiki FAQ](https://codeberg.org/river/wiki)
- The [list of compatible window managers]
- The [list of useful companion software]

## Strict No LLM / No AI Policy

Use of generative AI/LLMs is strictly forbidden for all contributions to river.

This includes bug reports and comments on the issue tracker.

## Hacking

See [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the code base.

See [CONTRIBUTING.md](CONTRIBUTING.md) for information on submitting patches.

## Donate

If my work on river adds value to your life please consider setting up a
recurring donation through [liberapay]. This is the best way to make river's
development sustainable in the long term.

You can also support me with a one-time or monthly donation on [github sponsors]
or [ko-fi] though I prefer liberapay as it is run by a non-profit.

Thank you for your support!

## Funding

River is funded in part through the [NGI0 Commons Fund](https://nlnet.nl/commonsfund),
a fund established by NLnet with financial support from the European
Commission's [Next Generation Internet](https://ngi.eu/) programme.

Learn more at the [NLnet project page](https://nlnet.nl/project/River-protocol/).

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information.

In overview:

- River's source code is released under the GPL-3.0-only license.
- River's Wayland protocols are released under the MIT license.
- River's logo and documentation are released under the CC-BY-SA-4.0 license.

[river-window-management-v1]: https://isaacfreund.com/docs/wayland/river-window-management-v1
[liberapay]: https://liberapay.com/ifreund
[github sponsors]: https://github.com/sponsors/ifreund
[ko-fi]: https://ko-fi.com/ifreund
[list of compatible window managers]: https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md
[list of useful companion software]: https://codeberg.org/river/wiki/src/branch/main/pages/useful-software.md
