#!/bin/sh
# Writes the template with all texts to translate, and merges it into each translation.
set -eu
export LC_ALL=C.UTF-8
cd "$(dirname "$0")/.."
po/extract.sh po/spacestate.pot
for po in po/*.po; do
    msgmerge --quiet --update --backup=none --no-wrap "$po" po/spacestate.pot
done
