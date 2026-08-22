#!/usr/bin/env bash
# The image can be used to develop extensions, not just run them:
# type-check them, install their dependencies, and load them from a project.
source "$(dirname "$0")/lib.sh"

# --- type checking ---------------------------------------------------------
# Extensions need no node_modules at runtime (Pi's jiti loader aliases the
# @earendil-works packages and typebox to its own copies), but authoring one
# means type-checking it against those same copies.
tsc_out="$(RUN_FLAGS="--network=none -v $FIXTURES:/work:ro" in_image '
	cd /work/ext && tsc --noEmit -p tsconfig.json
	echo "CLEAN_EXIT=$?"

	# And prove the types actually resolve rather than degrading to `any`:
	# the same file with a deliberate error must fail to compile.
	cp -r /work/ext /tmp/ext && cd /tmp/ext
	printf "\nconst bad: number = pi_is_not_defined;\n" >> greet.ts
	tsc --noEmit -p tsconfig.json >/tmp/tsc-err.txt 2>&1
	echo "BROKEN_EXIT=$?"
	head -2 /tmp/tsc-err.txt
')"
assert_contains "a valid extension type-checks"     "CLEAN_EXIT=0" "$tsc_out"
assert_not_contains "type errors are actually caught" "BROKEN_EXIT=0" "$tsc_out"
assert_contains "and reported against the source"   "greet.ts" "$tsc_out"

# --- npm -------------------------------------------------------------------
# Extensions with a package.json get their dependencies installed by Pi via npm,
# so npm has to work as the unprivileged container user with a writable cache.
npm_out="$(RUN_FLAGS="--network=none" in_image '
	echo "version=$(npm --version)"
	echo "cache=$(npm config get cache)"
	mkdir -p /tmp/extpkg && cd /tmp/extpkg
	npm init -y >/dev/null 2>&1 && echo "init=ok"
	touch "$(npm config get cache)/.probe" && echo "cache_writable=yes"
')"
assert_contains "npm runs"              "version=1" "$npm_out"
assert_contains "npm cache is writable" "cache_writable=yes" "$npm_out"
assert_contains "npm can scaffold"      "init=ok" "$npm_out"

# --- project-local extension discovery + trust ------------------------------
# `.pi/extensions/*.ts` loads only after the project is trusted. Both halves are
# observable in what Pi sends the model, which the mock server records.
discover() { # <extra pi args...>
	RUN_FLAGS="--network=none -v $FIXTURES:/work:ro -v $FIXTURES/project:/workspace:ro" in_image "
		cp /work/models.json \"\$PI_CODING_AGENT_DIR/models.json\"
		node /work/mock-llm/server.mjs >/tmp/mock.log 2>&1 &
		for _ in \$(seq 50); do grep -q listening /tmp/mock.log && break; sleep 0.1; done
		pi --mode json --no-session --provider mock --model mock-1 --api-key mock \
			$* -p hello >/dev/null 2>&1
		echo \"MARKER_TOOL=\$(grep -c project_marker /tmp/mock-request.json)\"
	"
}

trusted="$(discover -a)"
untrusted="$(discover -na)"
assert_not_contains "project-local extension loads when trusted" "MARKER_TOOL=0" "$trusted"
assert_contains "and does not load when untrusted"               "MARKER_TOOL=0" "$untrusted"

summary
