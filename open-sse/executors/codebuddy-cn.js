import { DefaultExecutor } from "./default.js";

/**
 * CodeBuddyExecutor — talks to https://copilot.tencent.com/v2/chat/completions
 *
 * CodeBuddy is OpenAI-compatible but rejects non-stream chat requests
 * (HTTP 400, code 11101 "Non-stream chat request is currently not supported").
 * The same-format (openai→openai) translator path leaves body.stream as the
 * client sent it, so we force it true here — 9router still re-aggregates the
 * SSE into a JSON response for non-streaming clients.
 */
export class CodeBuddyExecutor extends DefaultExecutor {
  constructor() {
    super("codebuddy-cn");
  }

  transformRequest(model, body, stream, credentials) {
    const transformed = super.transformRequest(model, body, stream, credentials);
    transformed.stream = true;

    // CodeBuddy CN can reject some CLI-agent identity markers as sensitive
    // content. Preserve the caller's system instructions (including long project
    // rules): only redact the marker text that triggers the filter. Replacing an
    // entire system message destroys project instructions and is not acceptable.
    const AGENT_MARKERS = [
      [/you are claude code/gi, "You are a coding assistant"],
      [/claude.?code.+official.+cli/gi, "coding assistant CLI"],
      [/anthropic.+official.+cli/gi, "coding assistant CLI"],
      [/anxthxropic.+official.+cli/gi, "coding assistant CLI"],
      [/you are (?:cursor|windsurf|cline|aider|continue|copilot|cody)/gi, "You are a coding assistant"],
      [/you are an? (?:ai )?(?:coding |code )?agent/gi, "You are a coding assistant"],
      [/cc_entrypoint\s*=\s*(?:cli|vscode|jetbrains|gui)/gi, "client_entrypoint=editor"],
      [/claude.?code.+issues/gi, "coding-assistant issues"],
      [/give feedback.+claude.?code/gi, "give feedback about the coding assistant"],
      [/you are .{0,30}(?:powerful )?ai agent/gi, "You are a coding assistant"],
      [/orchestration capabilities/gi, "coordination capabilities"],
      [/OhMyOpenCode/gi, "coding workflow"],
      [/<\/?agent-identity>/gi, ""],
      [/<\/?Role>/gi, ""],
      [/<\/?Behavior_Instructions>/gi, ""],
    ];
    const sanitizeSystemPrompt = (content) => {
      const text = typeof content === "string"
        ? content
        : Array.isArray(content)
          ? content.map((block) => (block && typeof block.text === "string" ? block.text : "")).join("\n")
          : "";
      if (!text) return content;
      const sanitized = AGENT_MARKERS.reduce(
        (value, [pattern, replacement]) => value.replace(pattern, replacement),
        text,
      );
      if (sanitized === text) return content;
      return typeof content === "string"
        ? sanitized
        : [{ type: "text", text: sanitized }];
    };
    if (Array.isArray(transformed.messages)) {
      transformed.messages = transformed.messages.map((message) =>
        !message || message.role !== "system"
          ? message
          : { ...message, content: sanitizeSystemPrompt(message.content) },
      );
    }

    // CodeBuddy only surfaces model reasoning when the request carries the CLI's
    // OpenAI-style params: reasoning_effort + reasoning_summary:"auto". 9router's
    // thinking pipeline sets reasoning_effort only when the client asks, and never
    // sets reasoning_summary — so reasoning never shows. Mirror the CLI here.
    const eff = transformed.reasoning_effort;
    if (eff === "none" || eff === "off") {
      delete transformed.reasoning_effort; // gateway has no "none" — just omit
    } else if (eff) {
      // Client explicitly asked for reasoning — mirror the CLI's reasoning_summary
      // so CodeBuddy surfaces the model's reasoning.
      transformed.reasoning_summary = "auto";
    }
    // No reasoning requested: leave both unset. Forcing reasoning_effort:"medium"
    // + reasoning_summary on plain requests makes CodeBuddy trip its content
    // filter and return an error (#2071).
    return transformed;
  }
}

export default CodeBuddyExecutor;
