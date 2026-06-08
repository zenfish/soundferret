# soundferret
Detects what is making sounds (or made sounds recently) on a mac (Sonoma+/14.2+), and which output device each one is routed to.

Ever wonder what was making that odd background noise or whatever on your mac? Took 3 mins to put this together with claude code.

# install

Need xcode - just type `make`, or `swiftc -O -framework CoreAudio -framework Foundation -o soundferret soundferret.swift`.

# usage

    $ ./soundferret
    PID     I/O  NAME                         BUNDLE                           ROUTE
    22700   O    Wrath.exe                    com.codeweavers.CrossOver.wineloader  MacBook Pro Speakers*
    52446   O    Brave Browser Helper         com.brave.Browser.helper         External Headphones*
    64425   O    Qobuz                        com.qobuz.desktop                External Headphones*, MacBook Pro Speakers

`-h` / `--help` prints full usage. Highlights:

| flag              | what it does                                                      |
|-------------------|-------------------------------------------------------------------|
| (none)            | one-shot scan                                                     |
| `--watch [secs]`  | live refresh (default 1.0s), Ctrl-C to quit                       |
| `--rms`           | sample each emitter ~150 ms, add a `dBFS` column to filter silence (triggers a one-time TCC "System Audio Recording" prompt) |
| `--debug`         | verbose tap diagnostics on stderr                                 |
| `-h`, `--help`    | show help and exit                                                |

# columns

- **PID** — process id
- **I/O** — `O` = output active, `I` = input active
- **NAME** — process short name
- **dBFS** — (with `--rms`) sample-level RMS, `-inf` = silent
- **BUNDLE** — `CFBundleIdentifier` if known, else `-`
- **ROUTE** — output device(s) the process has open. `*` marks the one actually emitting. `? d1, d2` if it can't be determined (zero or multiple devices currently running for that process).

# notes

- macOS 14.2+ required — uses CoreAudio process objects (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyDevices`).
- Deny the `--rms` TCC prompt and the `dBFS` column will just show `-`.
- Headphone jack vs internal speakers: same `AudioObjectID`, name flips between "MacBook Pro Speakers" and "External Headphones" as the jack DataSource changes.
