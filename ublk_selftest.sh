#!/bin/bash
# Run ublk selftests inside VM
# Usage: ~/git/linux/vmtest/run_vm ~/git/linux ~/git/linux/vmtest/ublk_selftest.sh [test_pattern]

set -e

cd tools/testing/selftests/ublk || exit 1

pattern="${1:-test_null_01.sh}"

echo "=== Running ublk selftest: $pattern ==="

if [ -f "./$pattern" ]; then
	./"$pattern"
	ret=$?
else
	ret=0
	for t in $pattern; do
		if [ -f "./$t" ]; then
			./"$t" || ret=$?
		fi
	done
fi

echo "=== ublk selftest done, ret=$ret ==="
exit $ret
