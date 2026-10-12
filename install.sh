#!/bin/bash
# Builds Act, then installs the root helper (LaunchDaemon, starts at boot) and the
# menu bar app (LaunchAgent, starts at login). Asks for an admin password once.
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  ./build.sh
  exec sudo "$PWD/$(basename "$0")"
fi

HELPER=com.brunoskvorc.act.helper
AGENT=com.brunoskvorc.act
[[ -x build/$HELPER && -d build/Act.app ]] || { echo "Missing build output. Run ./build.sh first." >&2; exit 1; }
console_uid=$(stat -f %u /dev/console)

stop() {
  launchctl bootout "$1" 2>/dev/null || true
  for _ in {1..50}; do
    launchctl print "$1" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

(( console_uid != 0 )) && stop "gui/$console_uid/$AGENT"
stop "system/$HELPER"

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "build/$HELPER" "/Library/PrivilegedHelperTools/$HELPER"
rm -rf /Applications/Act.app
ditto build/Act.app /Applications/Act.app
chown -R root:wheel /Applications/Act.app
install -o root -g wheel -m 644 "launchd/$HELPER.plist" "/Library/LaunchDaemons/$HELPER.plist"
install -o root -g wheel -m 644 "launchd/$AGENT.plist" "/Library/LaunchAgents/$AGENT.plist"

launchctl enable "system/$HELPER"
launchctl bootstrap system "/Library/LaunchDaemons/$HELPER.plist"
if (( console_uid != 0 )); then
  launchctl enable "gui/$console_uid/$AGENT"
  launchctl bootstrap "gui/$console_uid" "/Library/LaunchAgents/$AGENT.plist"
fi
echo "Act installed."
