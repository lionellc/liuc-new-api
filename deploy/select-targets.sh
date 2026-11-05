#!/usr/bin/env bash
set -Eeuo pipefail

selected="${1:-all}"

# Validate before using fields as SSH arguments or secret names. Hostnames and
# IPv4 addresses are accepted; use a hostname for an IPv6-only server.
jq -ce --arg selected "$selected" '
  if type != "array" or length == 0 then
    error("DEPLOY_TARGETS must be a non-empty array")
  elif (all(.[];
    (.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.host | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
    (.port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.user | type == "string" and test("^[a-z_][a-z0-9_-]*$")) and
    (.ssh_key_secret | type == "string" and test("^[A-Z_][A-Z0-9_]*$"))
  ) | not) then
    error("Each site requires a valid name, host, port, user, and ssh_key_secret")
  elif ([.[].name] | length) != ([.[].name] | unique | length) then
    error("Site names must be unique")
  elif any(.[]; .name == "all") then
    error("The site name all is reserved")
  else
    .
  end
  | if $selected == "all" then . else [.[] | select(.name == $selected)] end
  | if length == 0 then error("Unknown deployment target: " + $selected) else . end
' <<< "${DEPLOY_TARGETS:?Set DEPLOY_TARGETS to the site JSON array}"
