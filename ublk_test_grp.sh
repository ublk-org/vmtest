#!/bin/bash
# Run ublk selftests inside VM
# Usage: ~/git/linux/vmtest/run_vm ~/git/linux ~/git/linux/vmtest/ublk_selftest.sh [test_pattern]

set -e

GRP=$1

export TMPDIR=/home/ming/git/linux/temp/data
echo "first round"
make -C tools/testing/selftests/ublk JOBS=6 $GRP
#echo "second round"
#make -C tools/testing/selftests/ublk JOBS=2 $GRP

echo "=== ublk selftest done, ret=$ret ==="
exit $ret
