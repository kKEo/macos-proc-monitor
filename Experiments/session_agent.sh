#!/bin/zsh
# 0.4.1 — run the session probe as a temporary UI-less LaunchAgent, switch apps once, then remove the agent.
cd "$(dirname "$0")"
DIR=$(pwd); LABEL=dev.pmon.probe.session; PLIST=~/Library/LaunchAgents/$LABEL.plist
rm -f out/session.csv
cat > $PLIST <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/out/probe</string><string>session</string><string>$DIR/out/session.csv</string><string>24</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$DIR/out/session.err</string>
</dict></plist>
P
FRONT=$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed -E 's/.*="?([^"]*)"?/\1/')
echo "frontmost before: $FRONT"
launchctl bootstrap gui/$(id -u) $PLIST && echo "agent loaded"
sleep 6;  open -b com.apple.finder; echo "activated Finder"
sleep 6;  [[ -n "$FRONT" ]] && open -b "$FRONT" && echo "returned focus to $FRONT"
sleep 14
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null; rm -f $PLIST
echo "agent removed: $([[ -e $PLIST ]] && echo NO || echo yes); still loaded: $(launchctl list | grep -c $LABEL)"
echo "--- session.csv"; cat out/session.csv; [[ -s out/session.err ]] && { echo "--- stderr"; cat out/session.err; }
