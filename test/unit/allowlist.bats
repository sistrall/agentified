#!/usr/bin/env bats

load helper

setup() { load_ag; }

@test "exact host compiles to an anchored ERE" {
  run ag_host_to_ere "example.com"
  [ "$status" -eq 0 ]
  [ "$output" = '^example\.com$' ]
}

@test "leading dot compiles to host-or-subdomain" {
  run ag_host_to_ere ".example.com"
  [ "$status" -eq 0 ]
  [ "$output" = '(^|\.)example\.com$' ]
}

@test "dots are escaped so they cannot match arbitrary characters" {
  # Without escaping, ^example.com$ would also match "exampleXcom" — and, worse,
  # an attacker-registered "examplexcom.evil" style host in some proxies.
  run ag_host_to_ere "api.github.com"
  [ "$output" = '^api\.github\.com$' ]
}

@test "the exact-host ERE does not match a subdomain" {
  ere="$(ag_host_to_ere 'example.com')"
  run grep -Eq "$ere" <<< "evil.example.com"
  [ "$status" -ne 0 ]
  run grep -Eq "$ere" <<< "example.com"
  [ "$status" -eq 0 ]
}

@test "the subdomain ERE matches the apex and its children but not a lookalike" {
  ere="$(ag_host_to_ere '.example.com')"
  for host in example.com a.example.com a.b.example.com; do
    run grep -Eq "$ere" <<< "$host"
    [ "$status" -eq 0 ] || { echo "should match: $host"; return 1; }
  done
  for host in notexample.com example.com.evil.net exampleXcom; do
    run grep -Eq "$ere" <<< "$host"
    [ "$status" -ne 0 ] || { echo "should NOT match: $host"; return 1; }
  done
}

@test "host_to_ere rejects comments and invalid hosts" {
  run ag_host_to_ere "# a comment"; [ "$status" -ne 0 ]
  run ag_host_to_ere "evil|.*";     [ "$status" -ne 0 ]
  run ag_host_to_ere "";            [ "$status" -ne 0 ]
}

@test "profiles strip comments, blank lines and inline comments" {
  run ag_read_profile "$AG_FIXTURES/profiles" commented
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "kept.example.com" ]
  [ "${lines[1]}" = ".also-kept.example.com" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "an unknown profile fails loudly instead of narrowing the allowlist" {
  # Silently ignoring a typo is the failure mode we most want to avoid: the
  # container would come up with a *narrower* policy than the author asked for
  # and the symptom would be a random tool hanging days later.
  run ag_read_profile "$AG_FIXTURES/profiles" nosuchprofile
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown profile"
}

@test "a profile name with metacharacters is rejected before touching the filesystem" {
  run ag_read_profile "$AG_FIXTURES/profiles" "../../../etc/passwd"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid profile name"
}

@test "profiles compose and deduplicate" {
  run ag_collect_hosts "$AG_FIXTURES/profiles" "alpha,beta" ""
  [ "$status" -eq 0 ]
  # shared.example.com appears in both fixtures; it must appear once.
  [ "$(grep -c '^shared\.example\.com$' <<< "$output")" -eq 1 ]
  assert_contains "$output" "alpha.example.com"
  assert_contains "$output" "beta.example.com"
}

@test "extra allow entries are merged in" {
  run ag_collect_hosts "$AG_FIXTURES/profiles" "alpha" "gems.mycompany.internal, .cdn.internal"
  [ "$status" -eq 0 ]
  assert_contains "$output" "gems.mycompany.internal"
  assert_contains "$output" ".cdn.internal"
}

@test "an invalid allow entry fails the compile" {
  run ag_compile_allowlist "$AG_FIXTURES/profiles" "alpha" "good.com,evil|.*"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid host"
}

@test "compiling an empty allowlist is refused" {
  # An empty filter file with FilterDefaultDeny Yes denies everything, which
  # would look like a broken container rather than a policy decision.
  run ag_compile_allowlist "$AG_FIXTURES/profiles" "" ""
  [ "$status" -ne 0 ]
  assert_contains "$output" "empty"
}

@test "every shipped profile compiles" {
  for f in "$AG_PROFILES"/*.txt; do
    name="$(basename "$f" .txt)"
    run ag_compile_allowlist "$AG_PROFILES" "$name" ""
    [ "$status" -eq 0 ] || { echo "profile $name failed to compile: $output"; return 1; }
  done
}

@test "every shipped profile entry is a valid host" {
  for f in "$AG_PROFILES"/*.txt; do
    while IFS= read -r host; do
      run ag_valid_host "$host"
      [ "$status" -eq 0 ] || { echo "$f contains invalid host: '$host'"; return 1; }
    done < <(ag_read_profile "$AG_PROFILES" "$(basename "$f" .txt)")
  done
}

@test "the shipped defaults are coherent with each other" {
  # The Feature shipped `agents: claude` with `profiles: base,editor` — which
  # installs Claude Code and then blocks its API. That is precisely the mistake
  # ADR-0017 exists to catch, sitting unnoticed in our own defaults, and it was
  # found by CI running the Feature out of the box rather than by review.
  manifest="$AG_LIB/../../devcontainer-feature.json"
  [ -f "$manifest" ]

  default_of() {
    awk -v key="\"$1\": {" '
      index($0, key) { found = 1 }
      found && /"default":/ {
        sub(/.*"default": *"/, ""); sub(/".*/, ""); print; exit
      }' "$manifest"
  }

  agents="$(default_of agents)"
  profiles="$(default_of profiles)"
  [ -n "$agents" ]   || { echo "could not read the default agents"; return 1; }
  [ -n "$profiles" ] || { echo "could not read the default profiles"; return 1; }

  while IFS= read -r agent; do
    [ "$agent" = "none" ] && continue
    case ",$profiles," in
      *",$agent,"*) ;;
      *) echo "default agents='$agents' but default profiles='$profiles' omits '$agent'"
         echo "out of the box, $agent would install and be unable to reach its own API"
         return 1 ;;
    esac
  done < <(ag_split_csv "$agents")
}

@test "the Claude Code deny list covers the escape routes" {
  # A deny rule with the wrong syntax is worse than none: it looks like
  # protection and silently matches nothing. Claude Code's documented form is
  # `Bash(cmd *)` — and `Bash(command:rm *)` is explicitly ignored with a
  # startup warning, so the prefixed form must never appear here.
  # (JSON well-formedness is checked by `make lint`, which has a parser.)
  settings="$AG_LIB/../policy/claude-managed-settings.json"
  [ -f "$settings" ]
  body="$(cat "$settings")"
  for rule in 'Bash(sudo \*)' 'Bash(su \*)' 'Bash(iptables \*)' 'Bash(ip6tables \*)'; do
    assert_contains "$body" "$(printf '%s' "$rule" | sed 's/\\//g')"
  done
  # Bypass mode must be unavailable, or the deny list can be sidestepped.
  assert_contains "$body" '"disableBypassPermissionsMode": "disable"'
  # The ignored-with-a-warning form.
  assert_not_contains "$body" 'Bash(command:'
}

@test "the policy notes tell the agent what to do instead of routing around" {
  notes="$AG_LIB/../policy/agent-notes.md"
  [ -f "$notes" ]
  body="$(cat "$notes")"
  # The notes are only useful if they offer an alternative action; an
  # instruction that only forbids leaves the agent with nothing better to do.
  assert_contains "$body" "agentified denied"
  assert_contains "$body" "tell your user"
  assert_contains "$body" "deliberate"
}

@test "every profile declares where its hosts came from" {
  # A profile is a security policy, and a policy nobody can trace is a policy
  # nobody can review. Each file must say what it was derived from and when it
  # was last checked. "unverified" is an acceptable answer — an unknown one is
  # not, because that is how a stale list survives unnoticed.
  for f in "$AG_PROFILES"/*.txt; do
    name="$(basename "$f")"
    grep -qE '^# source: .+'   "$f" || { echo "$name has no '# source:' line"; return 1; }
    grep -qE '^# verified: .+' "$f" || { echo "$name has no '# verified:' line"; return 1; }
    value="$(sed -n 's/^# verified: //p' "$f" | head -1)"
    [[ "$value" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}|unverified) ]] \
      || { echo "$name: '# verified: $value' is neither a YYYY-MM-DD date nor 'unverified'"; return 1; }
  done
}

@test "the claude profile covers what Claude Code documents as required" {
  # Regression guard. Claude Code moved its auth to platform.claude.com and the
  # profile still listed a set of hosts from an older release, so `claude` came
  # up and immediately failed with "403 ... platform.claude.com" — a failure the
  # container could not diagnose for you. Source of truth:
  # https://code.claude.com/docs/en/network-config
  run ag_compile_allowlist "$AG_PROFILES" "claude" ""
  [ "$status" -eq 0 ]
  for host in api.anthropic.com claude.ai claude.com platform.claude.com \
              downloads.claude.ai mcp-proxy.anthropic.com registry.npmjs.org; do
    escaped="${host//./\\.}"
    assert_contains "$output" "^$escaped\$"
  done
}

@test "the claude profile does not ship optional telemetry or a whole CDN" {
  # storage.googleapis.com would permit every bucket on Google Cloud Storage,
  # which is a large hole in an allowlist whose purpose is limiting exfiltration.
  run ag_compile_allowlist "$AG_PROFILES" "claude" ""
  assert_not_contains "$output" "googleapis"
  assert_not_contains "$output" "datadoghq"
}

@test "the default profile set produces a usable allowlist" {
  run ag_compile_allowlist "$AG_PROFILES" "base,editor" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" '^github\.com$'
  assert_contains "$output" '^marketplace\.visualstudio\.com$'
}

@test "compiled output is one anchored regex per line with no blanks" {
  compiled="$(ag_compile_allowlist "$AG_PROFILES" "base,claude,editor,ruby" "extra.internal")"
  [ -n "$compiled" ]
  while IFS= read -r line; do
    [ -n "$line" ] || { echo "blank line in filter"; return 1; }
    [[ "$line" == *'$' ]] || { echo "unanchored line: $line"; return 1; }
    [[ "$line" == '^'* || "$line" == '(^|\.)'* ]] || { echo "unanchored line: $line"; return 1; }
  done <<< "$compiled"
}

@test "ag_extract_hosts pulls CONNECT targets out of a tinyproxy log" {
  run ag_extract_hosts < "$AG_FIXTURES/tinyproxy.log"
  [ "$status" -eq 0 ]
  assert_contains "$output" "api.anthropic.com"
  assert_contains "$output" "registry.npmjs.org"
  assert_contains "$output" "plain-http.example.com"
  assert_not_contains "$output" ":443"
}

@test "ag_extract_denied pulls filtered hosts out of a tinyproxy log" {
  run ag_extract_denied < "$AG_FIXTURES/tinyproxy.log"
  [ "$status" -eq 0 ]
  assert_contains "$output" "blocked.example.com"
  assert_not_contains "$output" "api.anthropic.com"
}
