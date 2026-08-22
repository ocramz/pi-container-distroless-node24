# pi-container-distroless-node24

OCI container for the [Pi coding agent](https://pi.dev/), built on distroless Node 24.

One image covers three jobs: running Pi against a project, developing Pi extensions, and
testing them. It has no package manager, no setuid binaries, and runs as a non-root user.

```bash
podman pull ghcr.io/ocramz/pi-container-distroless-node24:latest
```

## Use it

```bash
# interactive agent on the current directory
make run

# or by hand
podman run --rm -it \
  --userns=keep-id:uid=65532,gid=65532 \
  -e ANTHROPIC_API_KEY \
  -v "$PWD:/workspace:z" \
  -v pi-agent-state:/pi/agent \
  ghcr.io/ocramz/pi-container-distroless-node24:latest
```

The entrypoint is `pi`, so anything after the image name is Pi's own arguments:

```bash
podman run --rm ... IMAGE --mode json -p "summarise this repo"
```

**Bind mounts and uids.** The image runs as uid 65532 while your files belong to you.
[`scripts/user-flags.sh`](scripts/user-flags.sh) prints the right flag for your engine —
`--userns=keep-id` under rootless Podman, `--user $(id -u):$(id -g)` under Docker and under
Podman on macOS (where the machine is rootful and virtiofs passes host uids straight
through). `make run` and the test suite both use it, so they cannot drift apart.

**State.** Pi's config, sessions and credentials live in `/pi/agent`
(`PI_CODING_AGENT_DIR`), not `~/.pi`. Mount a named volume there to keep sessions between
runs. Note that mounting over the whole directory shadows the bundled `container-env`
extension; mount `/pi/agent/sessions` alone if you want to keep it.

## What is in the image

Distroless ships glibc, OpenSSL, CA certificates and a Node 24 runtime — and deliberately
nothing else. Pi is not self-contained: it spawns `/bin/bash`, `rg`, `fd`, `git` and `npm`.
So the build assembles the smallest userland that makes those work and copies it on top:

| | |
| --- | --- |
| shell | GNU bash 5.2 at `/bin/bash` — Pi probes that exact path and silently degrades to `sh -c` without it |
| userland | one static busybox (~1 MB) with a [curated applet allowlist](scripts/busybox-applets.txt) |
| search | ripgrep and fd, pre-installed so Pi never downloads them at runtime |
| vcs | git (without perl — see below) |
| node | Node 24, npm, npx, and `tsc` for extension development |

Nothing else. No apt/dpkg/apk, no sudo or su, no setuid binaries, no compilers. The test
suite asserts all of that.

**Busybox, not GNU coreutils.** Pi's own `grep` and `find` tools shell out to ripgrep and
fd, so they are unaffected. Only shell commands the *model* writes see busybox semantics:
no `grep -P`, busybox awk rather than gawk, a reduced `find`. The bundled
[`container-env`](extensions/container-env.ts) extension tells the model this up front, and
also serves as the reference example for extension development in this repo.

**git without perl.** Debian's git hard-depends on perl, which would add ~35 MB for
`git add -p` and friends. Core git — status, add, commit, diff, log, clone/fetch/push over
https — is C builtins and works; the perl-based and server-side subcommands
(`git add -p`, `git daemon`, `git http-backend`, `git svn`, `scalar`) are not shipped.

Size: **355 MB uncompressed, 118 MB compressed** (arm64). Roughly 120 MB of that is the
Node runtime and 165 MB is Pi's own dependency tree — its provider SDKs (openai, google,
anthropic, aws) dominate.

## Develop extensions in it

Extensions need no `node_modules` at runtime: Pi's jiti loader aliases `@earendil-works/*`
and `typebox` to its own copies. Type-checking does need pointing at them, which is all
[`tests/fixtures/ext/tsconfig.json`](tests/fixtures/ext/tsconfig.json) does — copy it next
to your extension:

```json
{
  "compilerOptions": {
    "paths": {
      "*": [
        "/opt/pi/lib/node_modules/*",
        "/opt/pi/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/*"
      ]
    }
  }
}
```

```bash
make shell
# inside:
tsc --noEmit -p tsconfig.json     # type-check
pi -e ./my-extension.ts           # run it
```

Project-local extensions in `.pi/extensions/` load once the project is trusted (`pi -a`).

## Build and test

```bash
make build     # build for this machine's architecture
make test      # build, then run the integration suite
make smoke     # just the fast toolchain + CLI checks
make shell     # bash inside the image
make size      # size and the layers this repo adds
make help      # all targets
```

`ENGINE=docker make build` works too. Pi's version is pinned in one place — `PI_VERSION` in
the [Makefile](Makefile) — and flows into the build and CI from there.

### The test suite

Four suites, 58 assertions, no API key and no network:

| suite | covers |
| --- | --- |
| [`test_toolchain.sh`](tests/test_toolchain.sh) | every binary Pi needs runs; git works end to end on a bind-mounted repo; no package manager, privilege tool or setuid binary is present |
| [`test_pi_cli.sh`](tests/test_pi_cli.sh) | Pi starts, reports the pinned version, and does not phone home under `--network=none` |
| [`test_agent_loop.sh`](tests/test_agent_loop.sh) | a **complete agent loop** — extension tool call, `bash` tool call, final answer |
| [`test_extension_dev.sh`](tests/test_extension_dev.sh) | type-checking (including that a deliberate error is caught), npm as the container user, project-local discovery gated on trust |

The agent-loop suite is the interesting one. It starts the container with `--network=none`
and runs a scripted, dependency-free OpenAI-compatible server
([`mock-llm/server.mjs`](tests/fixtures/mock-llm/server.mjs)) on loopback inside it. Pi
talks to that, so the real streaming client, the real tool loop and the real `/bin/bash`
all get exercised with nothing external to flake on. The mock also records each request,
which is how the suite checks that the bundled extension's note actually reached the model
and that an untrusted project's extension did not load.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) builds and tests on native
`ubuntu-24.04` and `ubuntu-24.04-arm` runners, pushes each architecture to GHCR
by digest, then assembles a multi-arch manifest tagged `latest`, `sha-<short>`,
`pi-<version>`, plus the git tag on `v*` releases, and attaches build provenance.

Pull requests build and test but never push.

## Layout

```
Dockerfile                      three stages: userland, pi install, runtime
scripts/collect-rootfs.sh       assembles the userland; verifies the library closure
scripts/busybox-applets.txt     the applet allowlist
scripts/user-flags.sh           uid mapping for the current engine
extensions/container-env.ts     bundled extension / reference example
tests/                          integration suite and fixtures
```

`collect-rootfs.sh` is the load-bearing part of the build. It links the busybox applets,
copies bash/git/rg/fd, resolves their shared-library closure with `ldd`, skips anything
distroless already ships, and then **fails the build** if any dependency is unresolved —
the alternative failure mode is a binary that exists but dies with "No such file or
directory" at runtime.
