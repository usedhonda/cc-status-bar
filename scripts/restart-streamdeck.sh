#!/bin/bash
# Safe Stream Deck restart - only kills the app, not plugins
# NEVER use: pkill -f "sdPlugin" or pgrep -f "Stream Deck"

pkill -x "Stream Deck"
sleep 2
open -a "Elgato Stream Deck"
echo "Stream Deck restarted safely"
