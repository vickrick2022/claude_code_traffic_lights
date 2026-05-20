#!/bin/bash
trap '' INT TERM
python3 "$(dirname "$0")/write_status.py" "$1" 2>/dev/null
