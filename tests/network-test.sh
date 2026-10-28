#!/bin/bash
# Stub-driven tests for the container networking rework in lib/common.sh and
# lib/container-egress-guard.sh. No sudo, no host mutation: see tests/lib.sh.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap sandbox_cleanup EXIT
sandbox_init

reset_fw() {
  rm -f "$SANDBOX"/fw.rt_rules "$SANDBOX"/fw.perm_rules "$SANDBOX"/fw.zone \
    "$SANDBOX"/fw.policies "$SANDBOX"/fw.calls "$SANDBOX"/systemctl.calls \
    "$SANDBOX"/docker.calls
  : >"$SANDBOX/fw.rt_rules"
  : >"$SANDBOX/fw.perm_rules"
  : >"$SANDBOX/fw.zone"
  : >"$SANDBOX/fw.policies"
  rm -f "$DOCKER_FIREWALLD_ZONE_FILE"
}

reset_guard() {
  rm -f "$SANDBOX"/ip.rules "$SANDBOX"/ip.t100 "$SANDBOX"/ip.calls
  : >"$SANDBOX/ip.rules"
  : >"$SANDBOX/ip.t100"
  printf '172.17.0.0/16 dev docker0 proto kernel scope link\n' >"$SANDBOX/ip.routes"
}

# ---------------------------------------------------------------- forwarding
echo '== forwarding: fresh host'
reset_fw
printf 'tailscale0\n' >"$SANDBOX/fw.zone"
echo docker-tailscale-forward >"$SANDBOX/fw.policies"
out="$(run_fn ensure_docker_firewalld_forwarding 2>&1)"
assert_file_contains "$DOCKER_FIREWALLD_ZONE_FILE" '<interface name="docker0"/>' 'zone file written'
assert_not_contains "$(cat "$SANDBOX/fw.zone")" tailscale0 'tailscale0 removed from zone'
assert_eq "$(cat "$SANDBOX/fw.policies")" '' 'legacy policy deleted'
assert_eq "$(grep -c . "$SANDBOX/fw.rt_rules")" 6 'six runtime rules'
assert_eq "$(grep -c . "$SANDBOX/fw.perm_rules")" 6 'six permanent rules'
assert_contains "$(cat "$SANDBOX/fw.calls")" 'firewall-cmd --reload' 'reload applied'
assert_contains "$(cat "$SANDBOX/systemctl.calls")" 'restart docker' 'docker restarted'
assert_contains "$out" '[ok]' 'reports success'

echo '== forwarding: second run is a no-op'
rm -f "$SANDBOX/systemctl.calls" "$SANDBOX/fw.calls"
out="$(run_fn ensure_docker_firewalld_forwarding 2>&1)"
assert_contains "$out" 'already configured' 'idempotent'
assert_eq "$(count_lines "$SANDBOX/systemctl.calls" 'restart docker')" 0 'no docker restart'
assert_eq "$(count_lines "$SANDBOX/fw.calls" '--reload')" 0 'no reload'

echo '== forwarding: idempotent when --query-rule is unsupported (fallback)'
reset_fw
NO_QUERY_RULE=1 run_fn ensure_docker_firewalld_forwarding >/dev/null 2>&1
rm -f "$SANDBOX/systemctl.calls" "$SANDBOX/fw.calls"
out="$(NO_QUERY_RULE=1 run_fn ensure_docker_firewalld_forwarding 2>&1)"
assert_contains "$out" 'already configured' 'fallback comparison idempotent'
assert_eq "$(count_lines "$SANDBOX/systemctl.calls" 'restart docker')" 0 'no docker restart (fallback)'

echo '== forwarding: root-only paths are probed through sudo'
# /etc/firewalld is 0750 root:root on Fedora; a plain [ -f ] returns false for
# the normal user, which would rewrite + reload on every run.
rm -f "$SANDBOX/sudo.calls"
run_fn ensure_docker_firewalld_forwarding >/dev/null 2>&1
assert_file_contains "$SANDBOX/sudo.calls" "test -f $DOCKER_FIREWALLD_ZONE_FILE" 'zone probed as root'

# --------------------------------------------------------------- egress guard
echo '== guard: exit node configured'
reset_guard
printf '172.17.0.0/16 dev docker0 proto kernel scope link\n172.18.0.0/16 dev br-abc proto kernel scope link\n' >"$SANDBOX/ip.routes"
FAKE_TS_MODE=on run_guard
assert_eq "$(grep -c 'lookup 100' "$SANDBOX/ip.rules")" 2 'one rule per bridge subnet'
assert_file_contains "$SANDBOX/ip.t100" 'throw 172.17.0.0/16 table 100' 'throw for docker0'
assert_file_contains "$SANDBOX/ip.t100" 'throw 172.18.0.0/16 table 100' 'throw for br-*'
assert_file_contains "$SANDBOX/ip.t100" 'default dev tailscale0 table 100' 'tunnel default'

echo '== guard: exit node switched off'
reset_guard
FAKE_TS_MODE=off run_guard
assert_eq "$(cat "$SANDBOX/ip.t100")" '' 'table 100 flushed'
assert_eq "$(grep -c 'lookup 100' "$SANDBOX/ip.rules")" 1 'rule kept (harmless)'

echo '== guard: prefs unreadable => fail closed'
reset_guard
FAKE_TS_MODE=fail run_guard
assert_file_contains "$SANDBOX/ip.t100" 'default dev tailscale0 table 100' 'fail-closed to tunnel'

echo '== guard: tailscale absent => no tunnel, direct'
reset_guard
PATH="/usr/bin:/bin" run_guard
assert_eq "$(cat "$SANDBOX/ip.t100")" '' 'table 100 empty without tailscale'

echo '== guard: tunnel interface missing => blackhole'
reset_guard
FAKE_TS_MODE=on FAKE_LINK_TS=0 run_guard
assert_file_contains "$SANDBOX/ip.t100" 'blackhole default' 'blackhole when tun absent'

echo '== guard: tunnel absent + TUNNEL_ABSENT=direct => uplink'
reset_guard
FAKE_TS_MODE=on FAKE_LINK_TS=0 CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=direct run_guard
assert_eq "$(cat "$SANDBOX/ip.t100")" '' 'direct fallback honoured'

echo '== guard: stale bridge rule/throw removed'
reset_guard
echo '5260: from 172.19.0.0/16 lookup 100' >"$SANDBOX/ip.rules"
echo 'throw 172.19.0.0/16 table 100' >"$SANDBOX/ip.t100"
FAKE_TS_MODE=on run_guard
assert_not_contains "$(cat "$SANDBOX/ip.rules")" '172.19.0.0/16' 'stale rule removed'
assert_not_contains "$(cat "$SANDBOX/ip.t100")" 'throw 172.19.0.0/16' 'stale throw removed'

echo '== guard: lookup 1000 is not mistaken for lookup 100 (anchored match)'
reset_guard
echo '5260: from 172.17.0.0/16 lookup 1000' >"$SANDBOX/ip.rules"
FAKE_TS_MODE=on run_guard
assert_file_contains "$SANDBOX/ip.rules" 'from 172.17.0.0/16 lookup 100' 'adds lookup 100 despite lookup 1000'

# ------------------------------------------------------------ guard installer
echo '== guard installer: installs repo file + unit + timer'
rm -f "$CONTAINER_EGRESS_GUARD_SCRIPT" "$CONTAINER_EGRESS_GUARD_UNIT" "$CONTAINER_EGRESS_GUARD_TIMER" "$SANDBOX/systemctl.calls"
run_fn ensure_container_egress_guard >/dev/null 2>&1
if cmp -s "$REPO_ROOT/lib/container-egress-guard.sh" "$CONTAINER_EGRESS_GUARD_SCRIPT"; then
  pass
else
  fail 'installed guard differs from repo file'
fi
assert_file_contains "$CONTAINER_EGRESS_GUARD_UNIT" "ExecStart=$CONTAINER_EGRESS_GUARD_SCRIPT" 'unit ExecStart'
assert_file_contains "$CONTAINER_EGRESS_GUARD_UNIT" 'TUNNEL_ABSENT=block' 'unit environment default'
assert_file_contains "$CONTAINER_EGRESS_GUARD_TIMER" 'OnUnitActiveSec=5s' 'timer interval'
assert_eq "$(count_lines "$SANDBOX/systemctl.calls" 'daemon-reload')" 1 'one daemon-reload'

echo '== guard installer: second run is a no-op'
rm -f "$SANDBOX/systemctl.calls"
run_fn ensure_container_egress_guard >/dev/null 2>&1
assert_eq "$(count_lines "$SANDBOX/systemctl.calls" 'daemon-reload')" 0 'no daemon-reload'

echo '== guard installer: TUNNEL_ABSENT=direct recorded in the unit'
CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=direct run_fn ensure_container_egress_guard >/dev/null 2>&1
assert_file_contains "$CONTAINER_EGRESS_GUARD_UNIT" 'TUNNEL_ABSENT=direct' 'unit environment override'

echo '== guard installer: invalid TUNNEL_ABSENT rejected'
out="$(CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=bogus run_fn ensure_container_egress_guard 2>&1)"
assert_contains "$out" 'must be block or direct' 'invalid value rejected'

# ------------------------------------------------------------------------ DNS
echo '== DNS: creates the missing docker config directory'
rm -rf "$SANDBOX/etc/docker"
run_fn configure_docker_dns >/dev/null 2>&1
if [ -d "$SANDBOX/etc/docker" ]; then pass; else fail 'docker config dir not created'; fi

echo '== DNS: pins 1.1.1.1 and ipv6:false by default'
rm -f "$DOCKER_DAEMON_JSON"
run_fn configure_docker_dns >/dev/null 2>&1
assert_file_contains "$DOCKER_DAEMON_JSON" '"dns": ["1.1.1.1"]' 'default resolver'
assert_file_contains "$DOCKER_DAEMON_JSON" '"ipv6": false' 'ipv6 pinned off'

echo '== DNS: DOCKER_DNS override'
rm -f "$DOCKER_DAEMON_JSON"
DOCKER_DNS='194.242.2.2 1.1.1.1' run_fn configure_docker_dns >/dev/null 2>&1
assert_file_contains "$DOCKER_DAEMON_JSON" '194.242.2.2' 'override applied'

echo '== DNS: explicitly empty DOCKER_DNS is an error'
rm -f "$DOCKER_DAEMON_JSON"
out="$(DOCKER_DNS='' run_fn configure_docker_dns 2>&1)"
assert_contains "$out" 'DOCKER_DNS is set but empty' 'empty value named'
assert_file_missing "$DOCKER_DAEMON_JSON" 'no file written'

echo '== DNS: SKIP_DOCKER_DNS leaves it alone'
rm -f "$DOCKER_DAEMON_JSON"
SKIP_DOCKER_DNS=1 run_fn configure_docker_dns >/dev/null 2>&1
assert_file_missing "$DOCKER_DAEMON_JSON" 'skipped'

echo '== DNS: unwritable target fails loudly'
: >"$SANDBOX/blocker"
out="$(DOCKER_DAEMON_JSON="$SANDBOX/blocker/daemon.json" run_fn configure_docker_dns 2>&1)"
assert_contains "$out" 'could not write' 'write failure reported'
rm -f "$SANDBOX/blocker"

echo '== DNS: existing daemon.json is never modified'
printf '{"dns":["9.9.9.9"]}\n' >"$DOCKER_DAEMON_JSON"
run_fn configure_docker_dns >/dev/null 2>&1
assert_eq "$(cat "$DOCKER_DAEMON_JSON")" '{"dns":["9.9.9.9"]}' 'existing file untouched'
rm -f "$DOCKER_DAEMON_JSON"

echo '== DNS: clean resolv.conf is a no-op'
printf 'nameserver 192.168.1.254\n' >"$DOCKER_RESOLV_CONF"
run_fn configure_docker_dns >/dev/null 2>&1
assert_file_missing "$DOCKER_DAEMON_JSON" 'no pin without a tailnet stub'
printf 'nameserver 100.100.100.100\nnameserver 192.168.1.254\n' >"$DOCKER_RESOLV_CONF"

# ------------------------------------------------------------- hint regression
echo '== smoke-test hints describe the shipped mechanism'
assert_file_contains "$REPO_ROOT/lib/common.sh" 'container-egress-guard' 'hint names the guard'
assert_file_contains "$REPO_ROOT/lib/common.sh" "ip rule show | grep 'lookup 100'" 'hint names the guard rule'
assert_not_contains "$(cat "$REPO_ROOT/lib/common.sh")" 'Two common causes' 'old hint removed'

summary
