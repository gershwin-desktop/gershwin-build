#!/bin/sh
# Run the UI test suite while sampling the top CPU consumers every 2 seconds
# into /tmp/spin.log.  If a desktop component (Menu / WindowManager /
# Workspace) busy-spins, the sampler shows it - and the harness's captureStack
# dumps its stack (ps wchan + gstack/pstack/gdb + ktrace on OpenBSD).  The
# sampler is torn down when the suite finishes, so it never leaves a stray
# process behind.
#
# Usage: sh Library/Scripts/run-uitests-debug.sh <make-test-args...>
# Passed-through to 'make test'.
set -u

(
  i=0
  while [ "$i" -lt 300 ]; do
    top -b -n 1 2>/dev/null | head -15 >> /tmp/spin.log
    echo "--- $(date +%T) ---" >> /tmp/spin.log
    i=$((i + 1))
    sleep 2
  done
) &
SAMPLER_PID=$!

trap 'kill $SAMPLER_PID 2>/dev/null || true' EXIT

make test "$@"
RC=$?

kill $SAMPLER_PID 2>/dev/null || true
wait $SAMPLER_PID 2>/dev/null || true

echo "=== UITEST DEBUG: spin.log (top CPU during tests) ==="
cat /tmp/spin.log 2>/dev/null | head -120 || true
rm -f /tmp/spin.log 2>/dev/null || true

exit $RC
