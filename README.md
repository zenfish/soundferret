# soundferret
Detects what is making sounds (or made sounds recently) on a mac (Sonoma+/14.2+)

Ever wonder what was making that odd background noise or whatever on your mac? Took 3 mins to put this together with claude code.

# install

Need xcode - just type `make`, or `swiftc -O -framework CoreAudio -framework Foundation -o soundferret soundferret.swift`.

# usage

    $ ./soundferret
    PID     I/O  NAME                         BUNDLE
    22700   O    C:\Program Files (x86)\Steam\steamapps\common\Pathfinder Second Adventure\Wrath.exe com.codeweavers.CrossOver.wineloader
    52446   O    Brave Browser Helper         com.brave.Browser.helper

