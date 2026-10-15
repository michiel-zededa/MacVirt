#!/bin/sh
# SSH_ASKPASS helper: forwards the prompt to MacVirt's native dialog.
exec "$(dirname "$0")/../MacOS/MacVirt" --askpass "$1"
