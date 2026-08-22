#!/usr/bin/env bash
#
# Assemble the userland that gets copied into the distroless image.
#
# Distroless ships glibc, libssl and nothing else -- no shell, no coreutils, no
# package manager. Pi needs a real bash (dist/utils/shell.js prefers /bin/bash),
# git, ripgrep and fd. This script collects exactly those, plus a static busybox
# for everything else, into a rootfs tree that can be COPY'd onto distroless.
#
# Usage: collect-rootfs.sh <rootfs-dir> [runtime-base-dir]
#
# runtime-base-dir is a copy of the target image's filesystem. Anything already
# present there (glibc, libssl, libstdc++, ...) is not copied again -- shipping a
# second identical libc would add ~25MB to the image for nothing.
set -euo pipefail

ROOT="${1:?usage: collect-rootfs.sh <rootfs-dir> [runtime-base-dir]}"
BASE="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_LIST="$HERE/busybox-applets.txt"

# Is this path already provided by the target image?
provided() { [ -n "$BASE" ] && [ -e "$BASE$1" ]; }

log() { printf '==> %s\n' "$*"; }

mkdir -p "$ROOT"/{bin,lib,usr/bin,usr/lib,usr/share,etc,tmp,workspace,pi/agent/extensions,pi/npm-cache,home/nonroot}

# ---------------------------------------------------------------------------
# busybox: one static binary, many applet symlinks
# ---------------------------------------------------------------------------
log "installing busybox applets"
cp /bin/busybox "$ROOT/bin/busybox"

mapfile -t available < <(/bin/busybox --list)
declare -A have=()
for a in "${available[@]}"; do have["$a"]=1; done

applet_count=0
while read -r applet; do
	applet="${applet%%#*}"
	applet="$(printf '%s' "$applet" | tr -d '[:space:]')"
	[ -n "$applet" ] || continue
	if [ -z "${have[$applet]:-}" ]; then
		echo "ERROR: '$applet' is not a busybox applet in this build" >&2
		exit 1
	fi
	ln -sf busybox "$ROOT/bin/$applet"
	applet_count=$((applet_count + 1))
done <"$APPLET_LIST"
log "linked $applet_count applets"

# Shebangs in the wild assume /usr/bin/env; busybox dispatches on argv[0].
ln -sf ../../bin/busybox "$ROOT/usr/bin/env"

# ---------------------------------------------------------------------------
# real binaries
# ---------------------------------------------------------------------------
# bash must exist at /bin/bash: Pi probes that exact path and silently degrades
# to `sh -c` if it is missing.
log "installing bash, git, ripgrep, fd"
cp "$(command -v bash)" "$ROOT/bin/bash"
ln -sf ../../bin/bash "$ROOT/usr/bin/bash"

cp "$(command -v git)" "$ROOT/usr/bin/git"
cp -a /usr/lib/git-core "$ROOT/usr/lib/git-core"
cp -a /usr/share/git-core "$ROOT/usr/share/git-core"

cp "$(command -v rg)" "$ROOT/usr/bin/rg"
# Debian ships fd as `fdfind`; Pi looks for either, but shell commands say `fd`.
cp "$(command -v fdfind)" "$ROOT/usr/bin/fdfind"
ln -sf fdfind "$ROOT/usr/bin/fd"

# git-core is ~100 hardlinks to a handful of real binaries. Hardlinks do not
# reliably survive the trip into an image layer, and if they break the image
# grows by hundreds of MB. Collapse every hardlink group to one real file plus
# symlinks, with /usr/bin/git as the canonical target for its own group.
log "de-duplicating git-core"
declare -A canonical=()
canonical["$(stat -c %i "$ROOT/usr/bin/git")"]="/usr/bin/git"
dedup=0
while IFS= read -r f; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	inode="$(stat -c %i "$f")"
	target="${canonical[$inode]:-}"
	if [ -z "$target" ]; then
		canonical["$inode"]="${f#"$ROOT"}"
		continue
	fi
	ln -sf "$(realpath --relative-to="$(dirname "$f")" "$ROOT$target")" "$f"
	dedup=$((dedup + 1))
done < <(find "$ROOT/usr/lib/git-core" -maxdepth 1 -type f | sort)
log "replaced $dedup git-core hardlinks with symlinks"

# Debian's git hard-depends on perl, which we do not ship (~35MB for `git add -p`
# and friends). Drop the scripts that would fail with a confusing ENOENT instead
# of leaving them to be discovered at runtime.
perl_dropped=0
while IFS= read -r -d '' f; do
	if [ ! -L "$f" ] && head -c 64 "$f" 2>/dev/null | head -n1 | grep -q 'perl'; then
		rm -f "$f"
		perl_dropped=$((perl_dropped + 1))
	fi
done < <(find "$ROOT/usr/lib/git-core" -maxdepth 1 -type f -print0)
log "dropped $perl_dropped perl-dependent git subcommands"

# Server-side and legacy-SCM git commands: ~11MB of binaries that only make
# sense on a git host or a foreign-VCS bridge. A sandbox clones, commits and
# pushes over https -- git-remote-http(s) and git-http-fetch/push stay.
for cmd in git-daemon git-http-backend git-shell git-imap-send git-instaweb \
	git-cvsserver git-p4 git-svn scalar; do
	rm -f "$ROOT/usr/lib/git-core/$cmd" "$ROOT/usr/bin/$cmd"
done

# ---------------------------------------------------------------------------
# shared library closure
# ---------------------------------------------------------------------------
# Copy every library our binaries resolve, to the exact path ldd reports, so it
# lands where the dynamic loader will look inside distroless. Copying over a lib
# distroless already ships is safe: both are Debian 12 builds.
is_elf() {
	[ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]
}

collect_libs() {
	local target="$1"
	ldd "$target" 2>/dev/null | sed -nE 's|.*=> (/[^ ]+).*|\1|p; s|^\s*(/lib[^ ]*ld-[^ ]+) \(0x.*|\1|p'
}

log "resolving shared library closure"
declare -A copied=()
round=0
while :; do
	round=$((round + 1))
	new=0
	# Snapshot the file list: we add files to $ROOT inside the loop, and
	# traversing a directory while writing to it is asking for trouble.
	mapfile -t files < <(find "$ROOT" -type f)
	for bin in "${files[@]}"; do
		is_elf "$bin" || continue
		while read -r lib; do
			[ -n "$lib" ] || continue
			[ -e "$lib" ] || continue
			[ -z "${copied[$lib]:-}" ] || continue
			if provided "$lib"; then
				copied["$lib"]=base
				continue
			fi
			mkdir -p "$ROOT$(dirname "$lib")"
			cp -aL "$lib" "$ROOT$lib"
			copied["$lib"]=1
			new=$((new + 1))
		done < <(collect_libs "$bin")
	done
	[ "$new" -gt 0 ] || break
	log "  round $round: +$new libraries"
done
log "copied ${#copied[@]} libraries"

# ---------------------------------------------------------------------------
# verify: every dependency of every ELF must be present inside the rootfs
# ---------------------------------------------------------------------------
# This is the guard that catches a library present in the builder image but
# absent from distroless -- the failure mode would otherwise be a runtime
# "No such file or directory" from a binary that exists.
log "verifying closure"
missing=0
mapfile -t files < <(find "$ROOT" -type f)
for bin in "${files[@]}"; do
	is_elf "$bin" || continue
	while read -r lib; do
		[ -n "$lib" ] || continue
		if [ ! -e "$ROOT$lib" ] && ! provided "$lib"; then
			echo "MISSING: $lib (needed by ${bin#"$ROOT"})" >&2
			missing=$((missing + 1))
		fi
	done < <(collect_libs "$bin")
	if ldd "$bin" 2>/dev/null | grep -q 'not found'; then
		echo "UNRESOLVED: ${bin#"$ROOT"}" >&2
		ldd "$bin" | grep 'not found' >&2
		missing=$((missing + 1))
	fi
done

if [ "$missing" -gt 0 ]; then
	echo "ERROR: $missing unresolved library dependencies" >&2
	exit 1
fi
log "closure OK"

# ---------------------------------------------------------------------------
# config files
# ---------------------------------------------------------------------------
# /workspace is a bind mount owned by a uid that is not ours; without
# safe.directory every git command fails with "dubious ownership".
cat >"$ROOT/etc/gitconfig" <<'EOF'
[safe]
	directory = *
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

# ---------------------------------------------------------------------------
# prune + permissions
# ---------------------------------------------------------------------------
rm -rf "$ROOT/usr/share/doc" "$ROOT/usr/share/man" "$ROOT/usr/share/locale" "$ROOT/usr/share/info"

# The image must also work under `--user $(id -u)` with a uid that has no
# /etc/passwd entry, so every directory Pi writes to is world-writable.
chmod 1777 "$ROOT/tmp"
chmod 0777 "$ROOT/workspace" "$ROOT/home/nonroot" "$ROOT/pi" "$ROOT/pi/agent" "$ROOT/pi/agent/extensions" "$ROOT/pi/npm-cache"

log "rootfs size: $(du -sh "$ROOT" | cut -f1)"
