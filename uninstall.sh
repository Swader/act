#!/bin/bash
# Stops Act and removes the helper, the app, and both launchd definitions.
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  exec sudo "$PWD/$(basename "$0")"
fi

HELPER=com.brunoskvorc.act.helper
AGENT=com.brunoskvorc.act
console_uid=$(stat -f %u /dev/console)

(( console_uid != 0 )) && launchctl bootout "gui/$console_uid/$AGENT" 2>/dev/null || true
launchctl bootout "system/$HELPER" 2>/dev/null || true
rm -f "/Library/LaunchAgents/$AGENT.plist" "/Library/LaunchDaemons/$HELPER.plist"
rm -f "/Library/PrivilegedHelperTools/$HELPER" "/var/run/$HELPER.sock"
rm -rf /Applications/Act.app
echo "Act removed."
