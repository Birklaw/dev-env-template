#!/bin/bash
# Container egress guard: keep Docker container traffic inside the Tailscale
# exit node when one is configured, and let it use the normal uplink when none
# is. Installed to /usr/local/sbin/container-egress-guard by the bootstrap.
# Edit THIS file (the repo copy), not the installed one.
#
# Mechanism: routing, not filtering. Every Docker bridge subnet gets an
# `ip rule` into table 100. While an exit node is configured, table 100's only
# default route is tailscale0 (or a blackhole if the tunnel interface is gone);
# each bridge subnet also gets a `throw` so local traffic keeps using the
# bridge instead of the tunnel default. With the exit node switched off the
# table is flushed, the lookup finds nothing, and traffic falls through to the
# main table.
#
# Fail-closed: if the exit-node state cannot be read, container traffic stays
# in the tunnel (or the blackhole) rather than leaking.
#
# IPv4 only: Docker's bridge network is IPv4 unless `enable_ipv6` is set, and
# the bootstrap pins that off in daemon.json. A network with IPv6 enabled would
# bypass this guard.
#
# Environment (set by the systemd unit):
#   CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=block|direct
#     block  (default) no tunnel interface => blackhole default (containers
#            offline until tailscaled is back)
#     direct           no tunnel interface => fall through to the uplink
set -uo pipefail

TABLE=100
PRIORITY=5260 # ahead of Tailscale's own "from all lookup 52" (5270)
TUNNEL_ABSENT="${CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT:-block}"

masked=0
# systemd runs with a minimal PATH; look for the binary explicitly.
TAILSCALE=$(command -v tailscale 2>/dev/null || true)
if [ -z "$TAILSCALE" ]; then
  for candidate in /usr/bin/tailscale /usr/local/bin/tailscale /usr/sbin/tailscale; do
    [ -x "$candidate" ] && TAILSCALE=$candidate && break
  done
fi
if [ -n "$TAILSCALE" ]; then
  if prefs=$(timeout 5 "$TAILSCALE" debug prefs 2>/dev/null) && [ -n "$prefs" ]; then
    printf '%s' "$prefs" | grep -q '"ExitNodeID": "[^"]' && masked=1
  else
    masked=1 # cannot determine -> keep container traffic in the tunnel
  fi
fi

# Docker bridge subnets, straight from the kernel (docker0 and br-*).
subnets=$(ip -4 route show 2>/dev/null |
  awk '$2 == "dev" && ($3 == "docker0" || $3 ~ /^br-/) { print $1 }' |
  grep -E '^[0-9]+\.' | sort -u | tr '\n' ' ')

# Anchored comparison: a rule for 172.19.0.0/16 must not match "lookup 1000".
have_rule() {
  ip rule show 2>/dev/null |
    awk -v s="$1" -v t="$TABLE" '
      $3 == s && $4 == "lookup" && $5 == t { found = 1 }
      END { exit(found ? 0 : 1) }
    '
}

for s in $subnets; do
  have_rule "$s" ||
    ip rule add from "$s" lookup "$TABLE" priority "$PRIORITY" 2>/dev/null || true
done

# Stale rules/routes for bridges that no longer exist.
for s in $(ip rule show 2>/dev/null |
  awk -v t="$TABLE" '$4 == "lookup" && $5 == t { print $3 }'); do
  case " ${subnets} " in
    *" ${s} "*) ;;
    *) ip rule del from "$s" lookup "$TABLE" 2>/dev/null || true ;;
  esac
done
for s in $(ip route show table "$TABLE" 2>/dev/null |
  awk '$1 == "throw" { print $2 }'); do
  case " ${subnets} " in
    *" ${s} "*) ;;
    *) ip route del throw "$s" table "$TABLE" 2>/dev/null || true ;;
  esac
done

if [ "$masked" = 1 ]; then
  # Local bridge subnets must NOT be swallowed by the tunnel default: `throw`
  # continues the lookup to the main table, so compose containers still reach
  # the workspace (and vice versa).
  for s in $subnets; do
    ip route replace throw "$s" table "$TABLE" 2>/dev/null ||
      {
        ip route del throw "$s" table "$TABLE" 2>/dev/null
        ip route add throw "$s" table "$TABLE" 2>/dev/null
      } || true
  done
  if ip link show tailscale0 >/dev/null 2>&1; then
    ip route replace default dev tailscale0 table "$TABLE" 2>/dev/null || true
  elif [ "$TUNNEL_ABSENT" = "direct" ]; then
    ip route flush table "$TABLE" 2>/dev/null || true
  else
    ip route replace blackhole default table "$TABLE" 2>/dev/null || true
  fi
else
  ip route flush table "$TABLE" 2>/dev/null || true
fi
exit 0
