#!/bin/zsh
# Double-click in Finder to start hand gestures in Terminal (with the camera preview).
cd "$(dirname "$0")"
exec .venv/bin/python -m handgestures --preview "$@"
