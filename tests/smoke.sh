#!/usr/bin/env bash
# Historical destructive smoke is retired. No override re-enables it.
printf '%s\n' 'REFUSED: legacy smoke overwrote shared state and restarted the fixed user service.' >&2
printf '%s\n' 'See docs/OWNED-NATIVE-ACCEPTANCE.md for the separately reviewed owned runner and its explicit limits.' >&2
printf '%s\n' 'No acceptance operation was started.' >&2
exit 64
