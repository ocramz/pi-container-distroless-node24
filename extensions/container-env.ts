/**
 * Tells the model what kind of box it is in.
 *
 * The image ships a static busybox rather than GNU coreutils, so shell commands
 * the model writes itself see busybox semantics: no `grep -P`, busybox awk
 * instead of gawk, a reduced `find`. Pi's own grep/find tools shell out to
 * ripgrep and fd and are unaffected -- this note is only about the `bash` tool.
 *
 * Doubles as the reference example for extension development in this repo:
 * a single .ts file, no build step, no node_modules (Pi's jiti loader aliases
 * `@earendil-works/*` and `typebox` to its own copies at runtime).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NOTE = `
## Container environment

You are running inside a distroless container. The shell userland is a static
busybox, not GNU coreutils:

- \`grep\` has no \`-P\`; use \`rg\` (ripgrep is installed) for anything beyond basic patterns.
- \`awk\` is busybox awk, not gawk; \`sed\` supports \`-i\` but not GNU-only extensions.
- \`find\` is busybox find; prefer \`fd\` for file discovery.
- Available: bash, git, node, npm, npx, tsc, rg, fd, tar, gzip, diff, patch, wget, vi.
- Not available: any package manager (apt/apk/dpkg), sudo, perl, make, compilers.

The project is mounted at /workspace. Writes outside /workspace and /tmp will
not persist and may fail: the container runs as a non-root user.
`.trim();

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", async (event) => ({
		systemPrompt: `${event.systemPrompt}\n\n${NOTE}`,
	}));
}
