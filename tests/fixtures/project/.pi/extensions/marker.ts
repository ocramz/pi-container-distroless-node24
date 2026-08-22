/**
 * Project-local fixture extension.
 *
 * Lives in `.pi/extensions/`, which Pi only loads once the project is trusted
 * (`-a`). The test asserts both halves of that: the tool shows up in the
 * request Pi sends to the model with `-a`, and does not without it.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "project_marker",
		label: "Project marker",
		description: "Marker tool proving project-local extension discovery works",
		parameters: Type.Object({}),
		async execute() {
			return { content: [{ type: "text", text: "marker" }], details: {} };
		},
	});
}
