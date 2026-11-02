#!/bin/sh
# Extracts the texts into the given file. xgettext knows no Swift, but the calls read like C.
set -eu
export LC_ALL=C.UTF-8
xgettext --from-code=UTF-8 --no-wrap --output="$1" \
    --language=C --keyword=translate $(grep -rl 'translate("' Sources --include='*.swift' | sort)
xgettext --from-code=UTF-8 --no-wrap --join-existing --output="$1" \
    --language=Glade Sources/SpaceStateSettings/settings.ui
