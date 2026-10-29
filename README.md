<div align="center">
<pre>
   ~
  .-.
  (   )
  |o|
  '-'
</pre>
</div>

<h1 align="center">lantern</h1>

<p align="center">A terminal multiplexer built on <a href="https://github.com/ghostty-org/ghostty">libghostty</a>.</p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jetcuhh/lantern/main/install.sh | sh
```

## Use

```sh
lantern        # open the UI, starting the session if needed
lantern help   # the overview and full key list
```

| Key | Action |
| --- | --- |
| `C-w r` | new tab |
| `C-w Tab` / `C-w Shift-Tab` | next / previous tab |
| `C-w 1`..`9` | select a tab |
| `C-w w` | close the tab |
| `C-w y` | copy the selection |
| `C-w l` | redraw |
| `C-w q` | detach, keeping every tab running |
| `C-w d` | end the session |

## Build

Requires Zig 0.17.0.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/lantern
```

Run `zig build test-all` for the unit and PTY integration suites.
