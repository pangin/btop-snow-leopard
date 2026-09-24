# Mac OS X Snow Leopard backport

This branch backports btop 1.4.7 to Mac OS X 10.6.8 on 32-bit Intel Macs.
It is tested on Darwin 10.8.0 (`i386`) and is intended for MacPorts installed
under `/opt/local`.

## Tested toolchain

- Mac OS X 10.6.8 / Darwin 10.8.0 / i386
- MacPorts 2.12.6
- `clang-16 @16.0.6_9`
- `gmake @4.4.1_1`
- `legacy-support @1.5.2_0`
- `libcxx @5.0.1_5+emulated_tls+universal`

Install the build dependencies with MacPorts:

```sh
sudo /opt/local/bin/port install clang-16 gmake legacy-support
```

The build uses the modern libc++ and libc++abi static archives shipped with
MacPorts Clang 16. The resulting binary does not depend on Snow Leopard's old
`/usr/lib/libc++.1.dylib`; it does retain a runtime dependency on
`/opt/local/lib/libMacportsLegacySupport.dylib`.

## Build and install

```sh
./build-snow-leopard.sh distclean
./build-snow-leopard.sh
./bin/btop --version
sudo ./build-snow-leopard.sh install PREFIX=/opt/local
```

Open a new login shell after installing and run:

```sh
btop
```

## Compatibility changes

- Use Clang 16's `-std=c++2b` mode and replace the two uses of
  `std::ranges::to`, which libc++ 16 does not provide.
- Link Clang 16's libc++ and libc++abi statically and use MacPorts
  LegacySupport for APIs absent from Snow Leopard.
- Disable the modern macOS GPU/IOReport backend.
- Include the socket definitions required by Snow Leopard's network headers.
- Use `inactive_count` as the cached-memory metric because
  `external_page_count` is not present in the 10.6 SDK.
- Report detailed per-process disk I/O as unavailable because
  `proc_pid_rusage` and `RUSAGE_INFO_CURRENT` are not present in 10.6.
- Fall back to `fcntl(FD_CLOEXEC)` because `O_CLOEXEC` is not defined.
- Widen `statvfs` counters before multiplication to prevent 32-bit disk-size
  overflow.
- Use 256 colors under iTerm2 2.x, the last iTerm2 for 10.6. It reads SGR
  38/48 only in the `38;5;N` form. For a 24-bit `38;2;R;G;B` it sets no color
  and applies R, G and B as plain attributes (0 resets, 1 bolds, 4 underlines,
  7 inverts), which garbles btop's default truecolor screen. btop detects it
  the way the terminal identifies itself: `TERM_PROGRAM=iTerm.app` with
  `TERM_PROGRAM_VERSION` unset or empty (iTerm2 3.x sets one). It then uses the
  same 256-color mode as `--low-color`, at startup, on a config reload, and
  after `truecolor` is toggled in the options menu. The detection never changes
  `truecolor` in `btop.conf`, so elsewhere btop still follows that setting
  (24-bit by default). Toggling `truecolor` in the options menu is still saved
  on exit as before, even though under iTerm2 2.x it has no visible effect.
  Detection sees only btop's own environment. `ssh` does not pass
  `TERM_PROGRAM` by default and `sudo` usually drops it, so btop started over
  SSH from an iTerm2 2.x window, or under `sudo`, is not detected: use
  `btop --low-color` there.
- Build the main menu's six label colors (Esc or `m`) with the low-color
  setting too. They were sent as 24-bit even with `--low-color` or
  `truecolor = false`.

## Verified behavior

The release build was verified as a Mach-O i386 executable on the target Mac.
`--version`, CPU, memory, disk, network, and process collection were exercised
in a real terminal. The interactive process exited cleanly through btop's `q`
command. Disk totals and percentages were checked after the i386 overflow fix.

The iTerm2 2.x color fallback was checked by running btop in a pty under the
exact environment iTerm2 2.0 sets on the target (`TERM_PROGRAM=iTerm.app`,
`ITERM_PROFILE`, `ITERM_SESSION_ID`, `TERM=xterm`) and counting SGR colors in
the captured bytes. The previous binary sent 1904 24-bit colors in one screen
(814 leftover R/G/B values that iTerm2 2.0 would apply as plain SGR, 519 of
them resets). The patched binary sent none, and 1696 256-color codes instead.
The result was the same with `TERM=xterm-256color`, with an empty
`TERM_PROGRAM_VERSION`, with the owner's `btop.conf` (`truecolor = true`, left
unchanged), and after toggling `truecolor` once or twice in the options menu.
With the main menu open, the previous binary sent 2788 24-bit colors in the
screen under iTerm2 2.0 and 27 under `--low-color`; the patched binary sends
none in either case. In the same pty test with `TERM_PROGRAM_VERSION` also set
(as iTerm2 3.x does), with no `TERM_PROGRAM` (as in a typical SSH session), and
with Apple Terminal's environment, btop still sent 24-bit color, as before.

GPU metrics are intentionally unavailable. Some per-core temperature sensors
may display `-1 C` on this hardware; the package CPU temperature reported by
the SMC backend remains available.
