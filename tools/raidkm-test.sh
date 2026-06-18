#!/bin/bash
# raidkm-test.sh — run the full raidkm (md level 71) test suite.
#
# Runs, in order: functional (create/write/read/scrub), degraded
# (max-degraded reconstruction), and grow (--add-data online reshape incl.
# degraded-read-after-grow, --add-parity offline recreate).  Exits non-zero
# if any sub-test fails.
#
#   sudo bash tools/raidkm-test.sh
#
# Configuration is via the environment — see raidkm-test-lib.sh.  Typical:
#   sudo RK_RELOAD=1 MDADM=~/projects/mdraid/mdadm/mdadm bash tools/raidkm-test.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/raidkm-test-lib.sh"

# Bring up modules + ramdisks once; the sub-scripts also do this idempotently.
rk_load_modules || exit 1
rk_setup_brd 9 || exit 1
echo "raidkm-test: MD=$MD  MDADM=$MDADM  raidkm=$(lsmod | awk '/^raidkm /{print "loaded"}')"

rc=0
for t in ec-mds functional degraded replace grow grow-traditional grow-parity-rotating reshape-concurrent; do
	echo
	echo "######## raidkm-test-$t ########"
	bash "$DIR/raidkm-test-$t.sh" || rc=1
done

echo
if [ "$rc" = 0 ]; then
	echo "######## ALL raidkm tests PASSED ########"
else
	echo "######## SOME raidkm tests FAILED ########"
fi
exit "$rc"
