#!/usr/bin/env bash
# Run a single named case from tests/fm-watch-arm.test.sh against whatever bin/ is checked out.
set -u
name=$1
drv="tests/.nm-single-$name.test.sh"
sed '/^test_[a-z_]*$/d' tests/fm-watch-arm.test.sh > "$drv"
printf '%s\n' "$name" >> "$drv"
bash "$drv"
rc=$?
rm -f "$drv"
exit $rc
