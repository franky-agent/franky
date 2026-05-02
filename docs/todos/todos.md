# DeepSeek DSML Tool calls — Analysis & Implementation Plan

## Context

DeepSeek-V3.2 and V4 models emit tool calls using **DSML (DeepSeek Markup Language)**, an XML-like markup language embedded in the model's text output — not as structured `tool_calls[]` JSON in the SSE delta. This is similar to how some Llama/Cloudflare models emit `{"type":"function","name":"X","parameters":{...}}` as text, which franky already handles via the `text_tool_call_fallback` path.

Reference: https://docs.vllm.ai/en/latest/api/vllm/tokenizers/deepseek_v4_encoding/

---

## What DSML looks like

The model emits something like this in its text output:

```
Here's what I'll do:

<｜DSML｜tool_calls>
<｜DSML｜invoke name="read">
<｜DSML｜parameter name="path" string="true">/some/file.zig