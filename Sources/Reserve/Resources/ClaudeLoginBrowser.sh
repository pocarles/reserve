#!/bin/sh
# Return the helper's automatic callback URL to Reserve through a private pipe.
# The pipe carries bytes in memory; no authorization URL is saved to disk.
test -n "$RESERVE_LOGIN_PIPE" && test -p "$RESERVE_LOGIN_PIPE" || exit 1
printf '%s\n' "$1" > "$RESERVE_LOGIN_PIPE"
