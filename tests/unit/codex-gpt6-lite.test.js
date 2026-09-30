import { afterEach, describe, expect, it, vi } from "vitest";

import { CodexExecutor } from "../../open-sse/executors/codex.js";
import { getModelsByProviderId } from "../../open-sse/config/providerModels.js";
import { getCapabilitiesForModel } from "../../open-sse/providers/capabilities.js";
import { getThinkingLevels } from "../../open-sse/providers/thinkingLevels.js";
import * as proxyFetchModule from "../../open-sse/utils/proxyFetch.js";

const credentials = { connectionId: "fixture", accessToken: "fixture-token" };
afterEach(() => vi.restoreAllMocks());

describe("Codex GPT-6 Sol/Luna transport", () => {
  it.each(["gpt-6-sol", "gpt-6-luna"])( "lists %s with Codex capabilities", (model) => {
    const entry = getModelsByProviderId("codex").find((item) => item.id === model);
    expect(entry?.responsesLite).toBe(true);
    expect(entry?.thinkingLevels).toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(getCapabilitiesForModel("codex", model)).toMatchObject({
      vision: true,
      reasoning: true,
      thinkingFormat: "openai",
    });
    expect(getThinkingLevels("codex", model)).toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(getThinkingLevels("codex", `${model}(high)`)).toEqual(entry.thinkingLevels);
  });

  // gpt-6.1-sol is gated behind client_version >= 0.159.0 on the Codex backend, both for the
  // /codex/models catalog entry and for inference ("not supported when using Codex with a
  // ChatGPT account" below that version). Its ladder additionally drops none/minimal, which
  // the backend rejects outright rather than clamping, and adds ultra which the transport does
  // not yet send.
  it("lists gpt-6.1-sol as a Lite model with its own thinking ladder", () => {
    const entry = getModelsByProviderId("codex").find((item) => item.id === "gpt-6.1-sol");
    expect(entry?.responsesLite).toBe(true);
    expect(entry?.thinkingLevels).toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(getThinkingLevels("codex", "gpt-6.1-sol")).toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(getCapabilitiesForModel("codex", "gpt-6.1-sol")).toMatchObject({
      vision: true,
      reasoning: true,
      thinkingFormat: "openai",
    });
  });

  it("clamps unsupported gpt-6.1-sol reasoning values to low", () => {
    for (const effort of ["none", "minimal"]) {
      const body = new CodexExecutor().transformRequest("gpt-6.1-sol", {
        model: "gpt-6.1-sol", input: "hello", reasoning: { effort },
      }, true, credentials);
      expect(body.reasoning.effort).toBe("low");
      expect(body.reasoning.context).toBe("all_turns");
    }
  });

  it("sends gpt-6.1-sol with the Lite header and a client version past its gate", async () => {
    const fetchMock = vi.spyOn(proxyFetchModule, "proxyAwareFetch").mockResolvedValue({
      ok: true, status: 200, headers: new Map(),
    });
    await new CodexExecutor().execute({
      model: "gpt-6.1-sol",
      body: { model: "gpt-6.1-sol", input: "hello", instructions: "Do the task" },
      stream: true,
      credentials,
    });

    const [, options] = fetchMock.mock.calls[0];
    const body = JSON.parse(options.body);
    expect(options.headers["x-openai-internal-codex-responses-lite"]).toBe("true");
    // 0.159.0 is gpt-6.1-sol's floor; anything lower returns
    // "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
    const sent = options.headers.version;
    expect(sent.localeCompare("0.159.0", undefined, { numeric: true })).toBeGreaterThanOrEqual(0);
    expect(body.input[0].type).toBe("additional_tools");
    expect(body.reasoning.context).toBe("all_turns");
  });

  it("keeps a native Responses Lite request intact", () => {
    const executor = new CodexExecutor();
    const input = [
      { type: "additional_tools", role: "developer", tools: [{ type: "function", name: "run", parameters: { type: "object", properties: {} } }] },
      { type: "message", id: "msg_native", role: "developer", content: [{ type: "input_text", text: "Native instructions" }] },
      { type: "message", role: "user", content: [{ type: "input_text", text: "hello" }] },
    ];
    const body = executor.transformRequest("gpt-6-luna", {
      model: "gpt-6-luna", input: structuredClone(input), instructions: "", tools: null, parallel_tool_calls: false,
      reasoning: { effort: "high", context: "all_turns" },
    }, true, credentials);
    const headers = executor.buildHeaders(credentials, true, null, "gpt-6-luna");

    expect(headers["x-openai-internal-codex-responses-lite"]).toBe("true");
    expect(body.instructions).toBe("");
    expect(body.tools).toBeNull();
    expect(body.parallel_tool_calls).toBe(false);
    expect(body.input).toEqual(input);
    expect(body.reasoning).toEqual({ effort: "high", context: "all_turns" });
  });

  it("converts an ordinary Responses request to the Lite shape", () => {
    const executor = new CodexExecutor();
    const tool = { type: "function", name: "run", parameters: { type: "object", properties: {} } };
    const body = executor.transformRequest("gpt-6-sol", {
      model: "gpt-6-sol", input: "hello", instructions: "Do the task", tools: [tool],
    }, true, credentials);

    expect(body.instructions).toBe("");
    expect(body.tools).toBeNull();
    expect(body.parallel_tool_calls).toBe(false);
    expect(body.reasoning).toEqual({ effort: "medium", context: "all_turns" });
    expect(body.input[0]).toEqual({ type: "additional_tools", role: "developer", tools: [tool] });
    expect(body.input[1]).toEqual({ type: "message", role: "developer", content: [{ type: "input_text", text: "Do the task" }] });
    expect(executor.buildHeaders(credentials, true, null, "gpt-6-sol")["x-openai-internal-codex-responses-lite"]).toBe("true");
  });

  it("clamps unsupported GPT-6 reasoning values to Codex's lowest supported level", () => {
    const body = new CodexExecutor().transformRequest("gpt-6-luna", {
      model: "gpt-6-luna", input: "hello", reasoning: { effort: "none" },
    }, true, credentials);

    expect(body.reasoning.effort).toBe("low");
    expect(body.reasoning.context).toBe("all_turns");
  });

  it("sends the Lite shape and header in the actual outbound request", async () => {
    const fetchMock = vi.spyOn(proxyFetchModule, "proxyAwareFetch").mockResolvedValue({
      ok: true, status: 200, headers: new Map(),
    });
    await new CodexExecutor().execute({
      model: "gpt-6-luna",
      body: { model: "gpt-6-luna", input: "hello", instructions: "Do the task" },
      stream: true,
      credentials,
    });

    const [url, options] = fetchMock.mock.calls[0];
    const body = JSON.parse(options.body);
    expect(url).toBe("https://chatgpt.com/backend-api/codex/responses");
    expect(options.headers["x-openai-internal-codex-responses-lite"]).toBe("true");
    // Assert the floor, not a literal: this header must satisfy both the 5.6 family's and
    // gpt-6.1-sol's client-version gates, so a hardcoded literal here just needs rewriting
    // on every Codex CLI bump.
    expect(options.headers.version.localeCompare("0.159.0", undefined, { numeric: true }))
      .toBeGreaterThanOrEqual(0);
    expect(body.model).toBe("gpt-6-luna");
    expect(body.instructions).toBe("");
    expect(body.input[0].type).toBe("additional_tools");
    expect(body.reasoning.context).toBe("all_turns");
  });

  it("keeps the legacy transport for other models", () => {
    const executor = new CodexExecutor();
    const body = executor.transformRequest("gpt-5.5", { model: "gpt-5.5", input: "hello" }, true, credentials);

    expect(body.instructions).toBeTruthy();
    expect(body.input[0].type).not.toBe("additional_tools");
    expect(body.reasoning.context).toBeUndefined();
    expect(executor.buildHeaders(credentials, true, null, "gpt-5.5")["x-openai-internal-codex-responses-lite"]).toBeUndefined();
    expect(getThinkingLevels("codex", "gpt-6-astra")).toContain("none");
    expect(executor.buildHeaders(credentials, true, null, "gpt-6-astra")["x-openai-internal-codex-responses-lite"]).toBeUndefined();
  });
});
