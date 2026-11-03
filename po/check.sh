#!/bin/sh
# Fails when a text in the sources has no translation, or a translation has format errors.
set -eu
export LC_ALL=C.UTF-8
cd "$(dirname "$0")/.."
template="$(mktemp)"
trap 'rm -f "$template"' EXIT
po/extract.sh "$template"
# Meson's spacestate-pot target reads the files from POTFILES.
{ grep -rl 'translate("' Sources --include='*.swift' | sort; echo Sources/SpaceStateSettings/settings.ui; } \
    | diff -u po/POTFILES - || { echo 'po/POTFILES is out of date.' >&2; exit 1; }
for po in po/*.po; do
    msgcmp "$po" "$template"
    msgfmt --check --output-file=/dev/null "$po"
done
