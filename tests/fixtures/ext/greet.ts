/**
 * Fixture extension: registers one tool the mock model is scripted to call.
 *
 * Deliberately written the way a real extension would be -- a single .ts file
 * with no build step and no node_modules -- so that loading it end to end also
 * proves the image supports extension development.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "greet",
		label: "Greet",
		description: "Greet someone by name",
		parameters: Type.Object({
			name: Type.String({ description: "Name to greet" }),
		}),
		async execute(_toolCallId, params) {
			return {
				content: [{ type: "text", text: `Hello, ${params.name}!` }],
				details: {},
			};
		},
	});
}
