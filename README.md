# Act

Act is a small macOS menu bar app that shows which apps use your CPU and memory. It adds up every process that belongs to an app, so you see one line for Cursor or Chrome instead of a hundred helper processes. It refreshes every second and keeps working when the Mac is under full load, which is exactly when Activity Monitor tends to stop responding.

```
CPU 1249% of 1800%    Memory 56.5 GB of 128.0 GB
Compressed 30.3 GB into 9.7 GB    Swap 8.3 GB

App                        CPU     Memory   Procs
Cursor                    1070%   22.1 GB    118  ›
Google Chrome              23%     8.8 GB     52  ›
Microsoft Edge             2.7%    6.8 GB     42  ›
WindowServer               15%     1.1 GB      2  ›
fseventsd                  3.2%    369 MB      1

  Sort by CPU
✓ Sort by Memory
```

The menu bar shows the top app, for example `Cursor 22.1 GB`. Hover an app to see its top 10 processes with their PIDs. Hold ⌘ and those rows turn red; click one to force kill that process.

## Install

You need macOS 26 on Apple silicon and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/Swader/act.git
cd act
./install.sh
```

The script builds Act, asks for your password once, and installs two parts: a root helper that starts at boot, and the menu bar app that starts when you log in. To update, run `git pull` and `./install.sh` again. To remove everything, run `./uninstall.sh`. If you use Bartender or a similar tool, it may hide the new menu bar item at first.

## How it works

The helper runs as root, because only root can read the CPU and memory of every process. Once per second it reads each process with `libproc`, groups the processes by app, and sends the totals to the menu bar app over a Unix socket. It samples only while the app is connected. On an 18-core Mac with about 1,000 processes, the helper uses less than 1% of one core and about 2 MB of memory, and the app uses about 0.2% and 12 MB. Both run at interactive priority, so macOS keeps scheduling them when the CPU is busy.

A process counts toward an app by the first rule that matches:

1. If it runs from inside a `.app` bundle, it belongs to the outermost bundle. All Chrome helpers count as Google Chrome.
2. If it runs in the background with no terminal, it belongs to the app that macOS holds responsible for it. A language server that your editor starts counts as the editor.
3. Otherwise it counts as itself. A `node` command that you start in a terminal shows as `node`.

When a process exits between two samples, its CPU time goes to the app of its parent, so short build steps do not vanish from the totals.

## Good to know

- **Memory** is the memory footprint, the same value as the Memory column in Activity Monitor. It counts compressed and swapped data at full size, so one runaway process can show more memory than your Mac has. The second summary line shows how much data is compressed and how much is in swap.
- **CPU** uses the Activity Monitor scale, where 100% is one full core.
- **Force kill** runs with your user rights. Act cannot kill root processes such as WindowServer; you hear a beep instead. Apps with only one process have no process list.
- **The socket** at `/var/run/com.brunoskvorc.act.helper.sock` is readable by all local users. It gives about the same information that `ps` gives any user, and the helper ignores anything sent to it.
- **Grouping** uses a private macOS function, `responsibility_get_pid_responsible_for_pid`. If a future macOS removes it, background processes count as themselves.
- **Signing**: Act is ad-hoc signed and built on your own Mac, so Gatekeeper does not block it. It is not notarized.

## Code

| Path | What it holds |
| --- | --- |
| `Sources/Helper/main.swift` | Root helper: sampling, grouping, socket server. The top of the file documents the frame format. |
| `Sources/App/` | Menu bar app: socket client, frame parser, menu. |
| `Sources/Shared/` | Socket path used by both parts. |
| `launchd/` | LaunchDaemon (helper) and LaunchAgent (app) definitions. |
| `build.sh`, `install.sh`, `uninstall.sh` | Build, install, and remove. |
