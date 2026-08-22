#!/usr/bin/env bash
# The userland Pi depends on is present, correct and no larger than intended.
source "$(dirname "$0")/lib.sh"

# One container start, everything probed at once.
out="$(in_image '
	echo "uid=$(id -u)"
	echo "home=$HOME"
	echo "cwd=$(pwd)"
	echo "sh=$(readlink /bin/sh)"
	echo "bash=$(bash --version | head -1)"
	echo "git=$(git --version)"
	echo "rg=$(rg --version | head -1)"
	echo "fd=$(fd --version)"
	echo "node=$(node --version)"
	echo "npm=$(npm --version)"
	echo "tsc=$(tsc --version)"
	echo "binbash=$([ -f /bin/bash ] && [ ! -L /bin/bash ] && echo real)"
	for a in ls cat sed awk grep find xargs tar gzip diff patch wget vi env pwd; do
		command -v "$a" >/dev/null || echo "MISSING_APPLET=$a"
	done
	for f in apt apt-get dpkg apk yum su sudo passwd login mount chroot; do
		command -v "$f" >/dev/null && echo "UNEXPECTED_BINARY=$f"
	done
	echo "setuid=$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l)"
	echo "writable_tmp=$(touch /tmp/probe && echo yes)"
	echo "writable_agentdir=$(touch "$PI_CODING_AGENT_DIR/probe" && echo yes)"
	echo "npmcache=$(npm config get cache)"
')"

# Pi probes /bin/bash by absolute path and silently falls back to `sh -c` if it
# is missing, so this assertion is load-bearing, not cosmetic.
assert_eq   "bash is a real file at /bin/bash" "real" "$(sed -n 's/^binbash=//p' <<<"$out")"
assert_contains "bash is GNU bash 5"       "GNU bash, version 5" "$out"
assert_eq   "/bin/sh is busybox"           "busybox" "$(sed -n 's/^sh=//p' <<<"$out")"
assert_contains "git present"              "git=git version 2." "$out"
assert_contains "ripgrep present"          "rg=ripgrep " "$out"
assert_contains "fd present"               "fd=fdfind " "$out"
assert_contains "node 24"                  "node=v24." "$out"
assert_contains "npm present"              "npm=1" "$out"
assert_contains "tsc present"              "tsc=Version 5." "$out"

assert_not_contains "all expected applets linked" "MISSING_APPLET=" "$out"

# The point of building on distroless: nothing here can install software,
# escalate privileges or mount anything.
assert_not_contains "no package manager or privilege tools" "UNEXPECTED_BINARY=" "$out"
assert_eq   "no setuid/setgid binaries"    "0" "$(sed -n 's/^setuid=//p' <<<"$out")"

assert_eq   "runs as the nonroot uid"      "65532" "$(sed -n 's/^uid=//p' <<<"$out")"
assert_eq   "HOME is set"                  "/home/nonroot" "$(sed -n 's/^home=//p' <<<"$out")"
assert_eq   "starts in /workspace"         "/workspace" "$(sed -n 's/^cwd=//p' <<<"$out")"
assert_eq   "/tmp is writable"             "yes" "$(sed -n 's/^writable_tmp=//p' <<<"$out")"
assert_eq   "agent dir is writable"        "yes" "$(sed -n 's/^writable_agentdir=//p' <<<"$out")"
assert_eq   "npm cache is inside /pi"      "/pi/npm-cache" "$(sed -n 's/^npmcache=//p' <<<"$out")"

# Perl is not shipped, so prove the C parts of git actually work end to end.
git_out="$(in_image '
	cd /tmp && rm -rf repo && mkdir repo && cd repo
	git init -q .
	echo hello > a.txt
	git add a.txt
	git -c user.email=t@example.com -c user.name=Test commit -qm "initial"
	echo "commits=$(git log --oneline | wc -l)"
	echo "dirty=$(git status --porcelain | wc -l)"
	echo "branch=$(git rev-parse --abbrev-ref HEAD)"
	echo "show=$(git show --name-only --format= HEAD)"
')"
assert_contains "git commits"                 "commits=1" "$git_out"
assert_contains "git status is clean after commit" "dirty=0" "$git_out"
assert_contains "init.defaultBranch is main"  "branch=main" "$git_out"
assert_contains "git show works"              "show=a.txt" "$git_out"

# A repo created by the host user and bind-mounted in is owned by a uid that is
# not ours: exactly the case /etc/gitconfig's safe.directory exists for.
hostrepo="$(mktemp -d)"
trap 'rm -rf "$hostrepo"' EXIT
git -C "$hostrepo" init -q .
echo host >"$hostrepo/f.txt"
git -C "$hostrepo" add f.txt
git -C "$hostrepo" -c user.email=t@example.com -c user.name=Test commit -qm host >/dev/null
mount_out="$(RUN_FLAGS="$USER_FLAGS -v $hostrepo:/repo" in_image 'git -C /repo log --oneline 2>&1 | head -2')"
assert_not_contains "bind-mounted repo is not 'dubious ownership'" "dubious ownership" "$mount_out"
assert_contains "bind-mounted repo history is readable" "host" "$mount_out"

summary
