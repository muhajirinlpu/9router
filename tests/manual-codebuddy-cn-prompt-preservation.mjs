import assert from "node:assert/strict";
import { CodeBuddyExecutor } from "../open-sse/executors/codebuddy-cn.js";

const executor = new CodeBuddyExecutor();
const credentials = { apiKey: "test" };

function transform(system) {
  return executor.transformRequest(
    "glm-5.2",
    {
      model: "glm-5.2",
      stream: false,
      messages: [
        { role: "system", content: system },
        { role: "user", content: "Summarize the project rules." },
      ],
    },
    false,
    credentials,
  );
}

const projectRules = [
  "# Trantor project rules",
  "Use ./nge and pnpm.",
  "Octane code must be stateless.",
  "Use Indonesian for user-facing UI.",
  "X".repeat(3_500),
].join("\n");
const preserved = transform(projectRules).messages[0].content;
assert.equal(preserved, projectRules);
assert.ok(preserved.includes("Octane code must be stateless."));

const agentAndProjectRules = [
  "You are Claude Code, Anthropic's official CLI for Claude.",
  "# Trantor project rules",
  "Use ./nge and pnpm.",
  "Octane code must be stateless.",
  "X".repeat(3_500),
].join("\n");
const sanitized = transform(agentAndProjectRules).messages[0].content;
assert.ok(!/you are claude code/i.test(sanitized));
assert.ok(!/anthropic's official cli/i.test(sanitized));
assert.ok(sanitized.includes("Use ./nge and pnpm."));
assert.ok(sanitized.includes("Octane code must be stateless."));
assert.ok(sanitized.length > 2_000);

console.log("PASS: long project system prompts are preserved; agent markers are redacted without deleting project rules.");
