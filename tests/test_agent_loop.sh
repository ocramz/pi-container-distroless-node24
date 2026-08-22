#!/usr/bin/env bash
# A complete agent loop, offline.
#
# The container is started with --network=none. A scripted OpenAI-compatible
# server runs on loopback inside it, so this exercises the real thing -- model
# streaming, an extension-provided tool, the built-in bash tool, session events
# -- with no API key and no external dependency of any kind.
source "$(dirname "$0")/lib.sh"

out="$(RUN_FLAGS="--network=none -v $FIXTURES:/work:ro" in_image '
	cp /work/models.json "$PI_CODING_AGENT_DIR/models.json"
	node /work/mock-llm/server.mjs >/tmp/mock.log 2>&1 &
	for _ in $(seq 50); do grep -q listening /tmp/mock.log && break; sleep 0.1; done

	pi --mode json --no-session \
		--provider mock --model mock-1 --api-key mock \
		-e /work/ext/greet.ts \
		-p "greet pi"
	echo "PI_EXIT=$?"
	echo "MARKER=$(cat /tmp/marker 2>/dev/null || echo missing)"
	echo "SYSTEM_PROMPT_HAS_BUSYBOX=$(grep -c busybox /tmp/mock-request.json)"
')"

assert_contains "pi exits cleanly"          "PI_EXIT=0" "$out"
assert_contains "emits a session header"    '{"type":"session","version":' "$out"
assert_contains "agent starts"              '{"type":"agent_start"}' "$out"

# The extension's tool was offered to the model, called, and returned its value.
assert_contains "extension tool executes"   '"type":"tool_execution_end","toolCallId":"call_greet","toolName":"greet"' "$out"
assert_contains "extension tool result"     '"text":"Hello, pi!"' "$out"
assert_not_contains "no tool errors"        '"isError":true' "$out"

# The built-in bash tool ran a real command through the real /bin/bash.
assert_contains "bash tool executes"        '"toolName":"bash"' "$out"
assert_contains "bash tool wrote its file"  "MARKER=ok" "$out"

assert_contains "final assistant text"      "MOCK_DONE both tools ran" "$out"
assert_contains "agent ends"                '"type":"agent_end"' "$out"

# The bundled container-env extension is auto-discovered from the global
# extensions dir and actually reaches the model.
assert_not_contains "busybox note reached the model" "SYSTEM_PROMPT_HAS_BUSYBOX=0" "$out"

summary
