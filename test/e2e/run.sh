#!/bin/bash
# Inner e2e runner: invoked by netns.sh inside a fresh user+network namespace
# with ipset/iptables/wget/python3/sed/grep/sort already on PATH.
# $1 = generated script (first install, swap, fetch-failure tests)
# $2 = script variant with different create options (option-change commit test)
# $3 = script without manual IPs (for the empty-guard test)
# $4 = directory for generated artifacts (empty.txt, transient scripts)
set -u
SCRIPT="$1"
SCRIPT2="${2:-}"
SCRIPT3="${3:-}"
WORK="${4:-/tmp}"
COMMITTED_LISTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lists"
LISTS="$WORK/lists.serve"
rm -rf "$LISTS"; mkdir -p "$LISTS"; cp "$COMMITTED_LISTS"/* "$LISTS"/
pass=0 fail=0
check() { # name condition
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}
v4entries() { ipset -S blocklist-as4 2>/dev/null | grep -c '^add '; }
rulecount() { iptables-save 2>/dev/null | grep -c 'match-set blocklist-as4'; }

ip link set lo up

python3 -m http.server -d "$LISTS" 8765 >/dev/null 2>&1 &
SRV=$!
sleep 1

echo "== run 1: first install =="
bash "$SCRIPT"; rc=$?
check "run1 exits 0" "[ $rc -eq 0 ]"
check "v4 has 4 entries" "[ \$(v4entries) = 4 ]"   # all.txt 3 unique + 9.9.9.9 from blocklistedIPs
check "v6 has 2 entries" "[ \$(ipset -S blocklist-as6 2>/dev/null | grep -c '^add ') = 2 ]"
check "iptables rules installed" "[ \$(rulecount) -ge 2 ]"
check "no staging set left" "! ipset -L blocklist-as4_new >/dev/null 2>&1"
BEFORE_ENTRIES=$(v4entries); BEFORE_RULES=$(rulecount)

# Regression pins for review #7: the LOG rule must evaluate before its DROP
# (explicit chain positions 1/2, not -I insertion-order luck), and it must be
# rate limited (unthrottled LOG = kernel log flood from any scanned source).
check "LOG rule sits above DROP rule" "iptables -S INPUT | grep -m2 'match-set' | head -1 | grep -q LOG"
check "LOG rules rate limited" "iptables -S | grep FW_DROPPED | grep -q -- '--limit'"
check "raw PREROUTING pair also ordered" "iptables -S -t raw | grep -m2 'match-set' | head -1 | grep -q LOG"

echo "== run 2: swap path =="
bash "$SCRIPT"; rc=$?
check "run2 exits 0" "[ $rc -eq 0 ]"
check "entries unchanged" "[ \$(v4entries) = $BEFORE_ENTRIES ]"
check "no duplicate rules" "[ \$(rulecount) = $BEFORE_RULES ]"
check "no staging set left" "! ipset -L blocklist-as4_new >/dev/null 2>&1"

echo "== run 3: fetch failure must not touch live sets =="
kill $SRV; wait $SRV 2>/dev/null
bash "$SCRIPT" > "$WORK/run3.out" 2>&1; rc=$?
check "run3 exits nonzero" "[ $rc -ne 0 ]"
check "entries survived failure" "[ \$(v4entries) = $BEFORE_ENTRIES ]"
check "rules survived failure" "[ \$(rulecount) = $BEFORE_RULES ]"

echo "== run 4: empty payload triggers guard =="
printf '\n' > "$LISTS/empty.txt"   # generated fixture, never written into the repo
python3 -m http.server -d "$LISTS" 8765 >/dev/null 2>&1 &
SRV=$!; sleep 1
sed 's#/all.txt#/empty.txt#' "${SCRIPT3:-$SCRIPT}" > "$WORK/script-empty.sh"
bash "$WORK/script-empty.sh" > "$WORK/run4.out" 2>&1; rc=$?
check "run4 exits nonzero" "[ $rc -ne 0 ]"
check "guard message" "grep -q 'refusing to replace live sets' '$WORK'/run4.out"
check "entries untouched" "[ \$(v4entries) = $BEFORE_ENTRIES ]"
check "rules untouched" "[ \$(rulecount) = $BEFORE_RULES ]"
kill $SRV; wait $SRV 2>/dev/null

if [ -n "$SCRIPT2" ]; then
  echo "== run 5: option change commit (staged options must land on active name) =="
  python3 -m http.server -d "$LISTS" 8765 >/dev/null 2>&1 &
  SRV=$!; sleep 1
  bash "$SCRIPT2"; rc=$?
  check "run5 exits 0" "[ $rc -eq 0 ]"
  check "entries intact after option change" "[ \$(v4entries) = $BEFORE_ENTRIES ]"
  check "maxelem now 1048576 on active set" "ipset -S blocklist-as4 | head -1 | grep -q 'maxelem 1048576'"
  kill $SRV; wait $SRV 2>/dev/null
fi

echo "== RESULT: $pass pass, $fail fail =="
[ $fail -eq 0 ]
