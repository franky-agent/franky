# DeepSeek DSML Tool calls — Analysis & Implementation Plan (DONE)

## Context

DeepSeek-V3.2 and V4 models emit tool calls using **DSML (DeepSeek Markup Language)**, an XML-like markup language embedded in the model's text output — not as structured `tool_calls[]` JSON in the SSE delta. This is similar to how some Llama/Cloudflare models emit `{"type":"function","name":"X","parameters":{...}}` as text, which franky already handles via the `text_tool_call_fallback` path.

Reference: https://docs.vllm.ai/en/latest/api/vllm/tokenizers/deepseek_v4_encoding/

---

## What DSML looks like (Done)

The model emits something like this in its text output:

```
Here's what I'll do:

<｜DSML｜tool_calls>
<｜DSML｜invoke name="read">
<｜DSML｜parameter name="path" string="true">/some/file.zig
```


# SubAgent tool execution progress (DONE)

The subagent tool execution missing progress updates for the user at least in web-ui (proxy mode). May its also mising in other modes as well. Let's make a plan how to show subagent progress to the user without polluting the agent loop context window.

# Read tool for directories (Done)

Some models use the read tool on directories in this case we should treat it as an ls tool call
```
{"name":"read","arguments":"{\"path\":\"/Users/frankittermann/github/franky/src/coding\"}"}},{"id":"call_puivqkgs","type":"function","function":{"name":"read","arguments":"{\"path\":\"/Users/frankittermann/github/franky/src/tui\"}"}}]},{"role":"tool","tool_call_id":"call_5h2bxt3j","content":"[read_failed] IsDir"}
```

# Inject current folder into system prompt (Done)

Some models haluzinated current folders before the really check with pwd.
```
tool: ls error
{"path":"/Users/adam/Developer/franky-do"}
[file_not_found] /Users/adam/Developer/franky-do
```

# Tool result Panel (Done)

Use the same style then for the sub-agent tools panel

```html
<div class="tool-head">tool: <span class="tool-name">read</span> <span class="tool-status">done</span><button type="button" class="tool-result-toggle" aria-expanded="false">▶</button></div>
```

The subagent tool itself should only have one button that shows the tool panel (as implemented) and
at the same time the subagent tool result (when done or error) including error message.

# Grep tool for files (Done | Needs Verification)

The grep tool should support search in file or path.
```
tool: grep error
{"pattern":"fn saveBuiltin","path":"src/coding/profiles.zig"}
[not_a_directory] src/coding/profiles.zig
```

# Grep parsing error (Done | Needs Verification)
```
tool: grep error
{"filesGlob":"**/tools/subagent.zig","path":"/Users/frankittermann/github/franky/src/coding","pattern":"pub const Preset\\b"}
[grep_bad_regex] invalid escape sequence at position 17 in pattern pub const Preset\b\ (use regex=false for literal substring search)
tool: grep error
{"filesGlob":"**/tools/subagent.zig","path":"/Users/frankittermann/github/franky/src/coding","pattern":"pub fn register\\b"}
[grep_bad_regex] invalid escape sequence at position 16 in pattern pub fn register\b\ (use regex=false for literal substring search)
```

# Add websearch tool using Ollama Web Search (D4one)

Consider also support for other web search api's. Ollama is just the first provider.

> ## Documentation Index
> Fetch the complete documentation index at: https://docs.ollama.com/llms.txt
> Use this file to discover all available pages before exploring further.

## Web search

Ollama's web search API can be used to augment models with the latest information to reduce hallucinations and improve accuracy.

Web search is provided as a REST API with deeper tool integrations in the Python and JavaScript libraries. This also enables models like OpenAI’s gpt-oss models to conduct long-running research tasks.

### Authentication

For access to Ollama's web search API, create an [API key](https://ollama.com/settings/keys). A free Ollama account is required.

### Web search API

Performs a web search for a single query and returns relevant results.

#### Request

`POST https://ollama.com/api/web_search`

* `query` (string, required): the search query string
* `max_results` (integer, optional): maximum results to return (default 5, max 10)

#### Response

Returns an object containing:

* `results` (array): array of search result objects, each containing:
  * `title` (string): the title of the web page
  * `url` (string): the URL of the web page
  * `content` (string): relevant content snippet from the web page

#### Examples

<Note>
  Ensure OLLAMA\_API\_KEY is set or it must be passed in the Authorization header.
</Note>

##### cURL Request

```bash theme={"system"}
curl https://ollama.com/api/web_search \
  --header "Authorization: Bearer $OLLAMA_API_KEY" \
	-d '{
	  "query":"what is ollama?"
	}'
```

**Response**

```json theme={"system"}
{
  "results": [
    {
      "title": "Ollama",
      "url": "https://ollama.com/",
      "content": "Cloud models are now available..."
    },
    {
      "title": "What is Ollama? Introduction to the AI model management tool",
      "url": "https://www.hostinger.com/tutorials/what-is-ollama",
      "content": "Ariffud M. 6min Read..."
    },
    {
      "title": "Ollama Explained: Transforming AI Accessibility and Language ...",
      "url": "https://www.geeksforgeeks.org/artificial-intelligence/ollama-explained-transforming-ai-accessibility-and-language-processing/",
      "content": "Data Science Data Science Projects Data Analysis..."
    }
  ]
}
```

##### Python library

```python theme={"system"}
import ollama
response = ollama.web_search("What is Ollama?")
print(response)
```

**Example output**

```python theme={"system"}

results = [
    {
        "title": "Ollama",
        "url": "https://ollama.com/",
        "content": "Cloud models are now available in Ollama..."
    },
    {
        "title": "What is Ollama? Features, Pricing, and Use Cases - Walturn",
        "url": "https://www.walturn.com/insights/what-is-ollama-features-pricing-and-use-cases",
        "content": "Our services..."
    },
    {
        "title": "Complete Ollama Guide: Installation, Usage & Code Examples",
        "url": "https://collabnix.com/complete-ollama-guide-installation-usage-code-examples",
        "content": "Join our Discord Server..."
    }
]

```

More Ollama [Python example](https://github.com/ollama/ollama-python/blob/main/examples/web-search.py)

##### JavaScript Library

```tsx theme={"system"}
import { Ollama } from "ollama";

const client = new Ollama();
const results = await client.webSearch("what is ollama?");
console.log(JSON.stringify(results, null, 2));
```

**Example output**

```json theme={"system"}
{
  "results": [
    {
      "title": "Ollama",
      "url": "https://ollama.com/",
      "content": "Cloud models are now available..."
    },
    {
      "title": "What is Ollama? Introduction to the AI model management tool",
      "url": "https://www.hostinger.com/tutorials/what-is-ollama",
      "content": "Ollama is an open-source tool..."
    },
    {
      "title": "Ollama Explained: Transforming AI Accessibility and Language Processing",
      "url": "https://www.geeksforgeeks.org/artificial-intelligence/ollama-explained-transforming-ai-accessibility-and-language-processing/",
      "content": "Ollama is a groundbreaking..."
    }
  ]
}
```

More Ollama [JavaScript example](https://github.com/ollama/ollama-js/blob/main/examples/websearch/websearch-tools.ts)

### Web fetch API

Fetches a single web page by URL and returns its content.

#### Request

`POST https://ollama.com/api/web_fetch`

* `url` (string, required): the URL to fetch

#### Response

Returns an object containing:

* `title` (string): the title of the web page
* `content` (string): the main content of the web page
* `links` (array): array of links found on the page

#### Examples

##### cURL Request

```python theme={"system"}
curl --request POST \
  --url https://ollama.com/api/web_fetch \
  --header "Authorization: Bearer $OLLAMA_API_KEY" \
  --header 'Content-Type: application/json' \
  --data '{
      "url": "ollama.com"
  }'
```

**Response**

```json theme={"system"}
{
  "title": "Ollama",
  "content": "[Cloud models](https://ollama.com/blog/cloud-models) are now available in Ollama...",
  "links": [
    "http://ollama.com/",
    "http://ollama.com/models",
    "https://github.com/ollama/ollama"
  ]

```

##### Python SDK

```python theme={"system"}
from ollama import web_fetch

result = web_fetch('https://ollama.com')
print(result)
```

**Result**

```python theme={"system"}
WebFetchResponse(
    title='Ollama',
    content='[Cloud models](https://ollama.com/blog/cloud-models) are now available in Ollama\n\n**Chat & build
with open models**\n\n[Download](https://ollama.com/download) [Explore
models](https://ollama.com/models)\n\nAvailable for macOS, Windows, and Linux',
    links=['https://ollama.com/', 'https://ollama.com/models', 'https://github.com/ollama/ollama']
)
```

##### JavaScript SDK

```tsx theme={"system"}
import { Ollama } from "ollama";

const client = new Ollama();
const fetchResult = await client.webFetch("https://ollama.com");
console.log(JSON.stringify(fetchResult, null, 2));
```

**Result**

```json theme={"system"}
{
  "title": "Ollama",
  "content": "[Cloud models](https://ollama.com/blog/cloud-models) are now available in Ollama...",
  "links": [
    "https://ollama.com/",
    "https://ollama.com/models",
    "https://github.com/ollama/ollama"
  ]
}
```

### Building a search agent

Use Ollama’s web search API as a tool to build a mini search agent.

This example uses Alibaba’s Qwen 3 model with 4B parameters.

```bash theme={"system"}
ollama pull qwen3:4b
```

```python theme={"system"}
from ollama import chat, web_fetch, web_search

available_tools = {'web_search': web_search, 'web_fetch': web_fetch}

messages = [{'role': 'user', 'content': "what is ollama's new engine"}]

while True:
  response = chat(
    model='qwen3:4b',
    messages=messages,
    tools=[web_search, web_fetch],
    think=True
    )
  if response.message.thinking:
    print('Thinking: ', response.message.thinking)
  if response.message.content:
    print('Content: ', response.message.content)
  messages.append(response.message)
  if response.message.tool_calls:
    print('Tool calls: ', response.message.tool_calls)
    for tool_call in response.message.tool_calls:
      function_to_call = available_tools.get(tool_call.function.name)
      if function_to_call:
        args = tool_call.function.arguments
        result = function_to_call(**args)
        print('Result: ', str(result)[:200]+'...')
        # Result is truncated for limited context lengths
        messages.append({'role': 'tool', 'content': str(result)[:2000 * 4], 'tool_name': tool_call.function.name})
      else:
        messages.append({'role': 'tool', 'content': f'Tool {tool_call.function.name} not found', 'tool_name': tool_call.function.name})
  else:
    break
```

**Result**

```
Thinking:  Okay, the user is asking about Ollama's new engine. I need to figure out what they're referring to. Ollama is a company that develops large language models, so maybe they've released a new model or an updated version of their existing engine....

Tool calls:  [ToolCall(function=Function(name='web_search', arguments={'max_results': 3, 'query': 'Ollama new engine'}))]
Result:  results=[WebSearchResult(content='# New model scheduling\n\n## September 23, 2025\n\nOllama now includes a significantly improved model scheduling system. Ahead of running a model, Ollama’s new engine

Thinking:  Okay, the user asked about Ollama's new engine. Let me look at the search results.

First result is from September 23, 2025, talking about new model scheduling. It mentions improved memory management, reduced crashes, better GPU utilization, and multi-GPU performance. Examples show speed improvements and accurate memory reporting. Supported models include gemma3, llama4, qwen3, etc...

Content:  Ollama has introduced two key updates to its engine, both released in 2025:

1. **Enhanced Model Scheduling (September 23, 2025)**
   - **Precision Memory Management**: Exact memory allocation reduces out-of-memory crashes and optimizes GPU utilization.
   - **Performance Gains**: Examples show significant speed improvements (e.g., 85.54 tokens/s vs 52.02 tokens/s) and full GPU layer utilization.
   - **Multi-GPU Support**: Improved efficiency across multiple GPUs, with accurate memory reporting via tools like `nvidia-smi`.
   - **Supported Models**: Includes `gemma3`, `llama4`, `qwen3`, `mistral-small3.2`, and more.

2. **Multimodal Engine (May 15, 2025)**
   - **Vision Support**: First-class support for vision models, including `llama4:scout` (109B parameters), `gemma3`, `qwen2.5vl`, and `mistral-small3.1`.
   - **Multimodal Tasks**: Examples include identifying animals in multiple images, answering location-based questions from videos, and document scanning.

These updates highlight Ollama's focus on efficiency, performance, and expanded capabilities for both text and vision tasks.
```

#### Context length and agents

Web search results can return thousands of tokens. It is recommended to increase the context length of the model to at least \~32000 tokens. Search agents work best with full context length. [Ollama's cloud models](https://docs.ollama.com/cloud) run at the full context length.


# Analzye the latest Deepseek diagnostics

```
== franky diagnostics ===
mode:        proxy
session:     01KQNJ5GX7DCA931RDBZTZPGMM
provider:    gateway
model:       deepseek-v4-flash:cloud
trace dir:   /home/agent/.franky/log-trace
reducer dir: /home/agent/.franky/sessions/01KQNJ5GX7DCA931RDBZTZPGMM
transcript:  100 assistant turns / 234 messages

Per-turn:
  #1  ts=1777766431009  stop=toolUse  blocks=thinking:1,toolCall:1  parts=27 cand=144 thoughts=0 events=26
  #2  ts=1777766435076  stop=toolUse  blocks=thinking:1,toolCall:1  parts=32 cand=152 thoughts=0 events=31
  #3  ts=1777766437292  stop=toolUse  blocks=thinking:1,toolCall:1  parts=33 cand=152 thoughts=0 events=32
  #4  ts=1777766441758  stop=toolUse  blocks=thinking:1,toolCall:2  parts=44 cand=248 thoughts=0 events=44
  #5  ts=1777766461534  stop=toolUse  blocks=thinking:1,toolCall:2  parts=115 cand=396 thoughts=0 events=115
  #6  ts=1777766541201  stop=toolUse  blocks=thinking:1,toolCall:1  parts=545 cand=1040 thoughts=0 events=544
  #7  ts=1777766553526  stop=toolUse  blocks=thinking:1,toolCall:2  parts=524 cand=1069 thoughts=0 events=524
  #8  ts=1777766586641  stop=toolUse  blocks=thinking:1,toolCall:1  parts=479 cand=947 thoughts=0 events=478
  #9  ts=1777766615896  stop=toolUse  blocks=thinking:1,toolCall:2  parts=432 cand=1063 thoughts=0 events=432
  #10  ts=1777766623971  stop=toolUse  blocks=thinking:1,toolCall:1  parts=12 cand=124 thoughts=0 events=11
  #11  ts=1777766634847  stop=toolUse  blocks=thinking:1,toolCall:1  parts=53 cand=311 thoughts=0 events=52
  #12  ts=1777766639090  stop=toolUse  blocks=thinking:1,toolCall:1  parts=14 cand=117 thoughts=0 events=13
  #13  ts=1777766672423  stop=toolUse  blocks=thinking:1,toolCall:2  parts=1348 cand=2540 thoughts=0 events=1348
  #14  ts=1777766692325  stop=toolUse  blocks=thinking:1,toolCall:1  parts=872 cand=1628 thoughts=0 events=871
  #15  ts=1777766720165  stop=toolUse  blocks=thinking:1,toolCall:1  parts=751 cand=1416 thoughts=0 events=750
  #16  ts=1777766733034  stop=toolUse  blocks=thinking:1,toolCall:1  parts=523 cand=1027 thoughts=0 events=522
  #17  ts=1777766786822  stop=toolUse  blocks=thinking:1,toolCall:2  parts=725 cand=1455 thoughts=0 events=725
  #18  ts=1777766924406  stop=toolUse  blocks=thinking:1,toolCall:2  parts=491 cand=1041 thoughts=0 events=491
  #19  ts=1777766927788  stop=toolUse  blocks=thinking:1,toolCall:1  parts=65 cand=202 thoughts=0 events=64
  #20  ts=1777767010876  stop=toolUse  blocks=thinking:1,toolCall:2  parts=757 cand=1513 thoughts=0 events=757
  #21  ts=1777767031577  stop=toolUse  blocks=thinking:1,toolCall:2  parts=275 cand=692 thoughts=0 events=275
  #22  ts=1777767113422  stop=toolUse  blocks=thinking:1,toolCall:1  parts=687 cand=1302 thoughts=0 events=686
  #23  ts=1777767117005  stop=toolUse  blocks=thinking:1,toolCall:1  parts=24 cand=129 thoughts=0 events=23
  #24  ts=1777767207304  stop=toolUse  blocks=text:1,thinking:1,toolCall:2  parts=1443 cand=2611 thoughts=0 events=1443
  #25  ts=1777767234137  stop=toolUse  blocks=thinking:1,toolCall:1  parts=533 cand=1016 thoughts=0 events=532
  #26  ts=1777767352970  stop=toolUse  blocks=thinking:1,toolCall:2  parts=1650 cand=3052 thoughts=0 events=1650
  #27  ts=1777767358711  stop=toolUse  blocks=thinking:1,toolCall:2  parts=68 cand=297 thoughts=0 events=68
  #28  ts=1777767363433  stop=toolUse  blocks=thinking:1,toolCall:1  parts=9 cand=103 thoughts=0 events=8
  #29  ts=1777767370575  stop=toolUse  blocks=thinking:1,toolCall:2  parts=270 cand=644 thoughts=0 events=270
  #30  ts=1777767402140  stop=toolUse  blocks=thinking:1,toolCall:2  parts=313 cand=736 thoughts=0 events=313
  #31  ts=1777767437901  stop=toolUse  blocks=thinking:1,toolCall:1  parts=188 cand=425 thoughts=0 events=187
  #32  ts=1777767451024  stop=toolUse  blocks=thinking:1,toolCall:1  parts=400 cand=803 thoughts=0 events=399
  #33  ts=1777767467319  stop=toolUse  blocks=thinking:1,toolCall:1  parts=525 cand=1036 thoughts=0 events=524
  #34  ts=1777767592796  stop=toolUse  blocks=thinking:1,toolCall:2  parts=2002 cand=3694 thoughts=0 events=2002
  #35  ts=1777767598754  stop=toolUse  blocks=thinking:1,toolCall:1  parts=188 cand=389 thoughts=0 events=187
  #36  ts=1777767610914  stop=toolUse  blocks=thinking:1,toolCall:1  parts=244 cand=534 thoughts=0 events=243
  #37  ts=1777767618680  stop=toolUse  blocks=thinking:1,toolCall:1  parts=309 cand=670 thoughts=0 events=308
  #38  ts=1777767630652  stop=toolUse  blocks=thinking:1,toolCall:1  parts=343 cand=714 thoughts=0 events=342
  #39  ts=1777767680259  stop=toolUse  blocks=thinking:1,toolCall:2  parts=726 cand=1478 thoughts=0 events=726
  #40  ts=1777767713543  stop=toolUse  blocks=thinking:1,toolCall:1  parts=1449 cand=2659 thoughts=0 events=1448
  #41  ts=1777767757050  stop=toolUse  blocks=text:1,thinking:1,toolCall:2  parts=1219 cand=2386 thoughts=0 events=1219
  #42  ts=1777767782286  stop=toolUse  blocks=thinking:1,toolCall:2  parts=845 cand=1590 thoughts=0 events=845
  #43  ts=1777767811008  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=755 cand=1384 thoughts=0 events=754
  #44  ts=1777767822010  stop=toolUse  blocks=thinking:1,toolCall:1  parts=199 cand=447 thoughts=0 events=198
  #45  ts=1777767834172  stop=toolUse  blocks=thinking:1,toolCall:1  parts=200 cand=450 thoughts=0 events=199
  #46  ts=1777767861194  stop=toolUse  blocks=text:1,thinking:1,toolCall:2  parts=913 cand=1749 thoughts=0 events=913
  #47  ts=1777767875800  stop=toolUse  blocks=thinking:1,toolCall:1  parts=630 cand=1188 thoughts=0 events=629
  #48  ts=1777767884480  stop=toolUse  blocks=thinking:1,toolCall:1  parts=301 cand=619 thoughts=0 events=300
  #49  ts=1777767913385  stop=toolUse  blocks=thinking:1,toolCall:1  parts=1092 cand=2006 thoughts=0 events=1091
  #50  ts=1777767922000  stop=toolUse  blocks=thinking:1,toolCall:1  parts=234 cand=502 thoughts=0 events=233
  #51  ts=1777767984212  stop=toolUse  blocks=thinking:1,toolCall:1  parts=416 cand=832 thoughts=0 events=415
  #52  ts=1777767999953  stop=toolUse  blocks=thinking:1,toolCall:2  parts=409 cand=847 thoughts=0 events=409
  #53  ts=1777768017037  stop=toolUse  blocks=thinking:1,toolCall:2  parts=277 cand=648 thoughts=0 events=277
  #54  ts=1777768055807  stop=toolUse  blocks=thinking:1,toolCall:2  parts=1516 cand=2821 thoughts=0 events=1516
  #55  ts=1777768078931  stop=toolUse  blocks=thinking:1,toolCall:1  parts=900 cand=1947 thoughts=0 events=899
  #56  ts=1777768116142  stop=toolUse  blocks=thinking:1,toolCall:1  parts=1493 cand=3080 thoughts=0 events=1492
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768116003-0055-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768116003-0055-<provider>.txt --name <descriptive>
      tool failure: bash (call_tqdeugyj) — exit: code=1
[stdout]
1/1 repro2.test.go vet with empty environ...pkg_dir=EolUUOzlIXsoDiFJ/.
term.exited=1
stdout=
stderr=package EolUUOzlIXsoDiFJ is not in std (/usr/lib/go-1.24/src/EolUUOzlIXsoDiFJ)

FAIL…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #57  ts=1777768137042  stop=toolUse  blocks=thinking:1,toolCall:1  parts=256 cand=1001 thoughts=0 events=255
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768137018-0056-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768137018-0056-<provider>.txt --name <descriptive>
      tool failure: bash (call_4zgsrior) — exit: code=1
[stdout]
/tmp/repro3.zig:21:23: error: root source file struct 'fs' has no member named 'cwd'
    const cwd = std.fs.cwd();
                ~~~~~~^~~~
/usr/local/bin/lib/std/fs.zig:1:1: note: s…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #58  ts=1777768149987  stop=toolUse  blocks=thinking:1,toolCall:1  parts=534 cand=1044 thoughts=0 events=533
  #59  ts=1777768167706  stop=toolUse  blocks=thinking:1,toolCall:2  parts=438 cand=970 thoughts=0 events=438
  #60  ts=1777768220607  stop=toolUse  blocks=thinking:1,toolCall:1  parts=1014 cand=2230 thoughts=0 events=1013
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768220514-0059-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768220514-0059-<provider>.txt --name <descriptive>
      tool failure: bash (call_4v9g74sb) — exit: code=1
[stdout]
/tmp/repro4.zig:9:9: error: local variable is never mutated
    var env = std.process.Environ{ .block = .{} };
        ^~~
/tmp/repro4.zig:9:9: note: consider using 'const'
/tmp/repro4…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #61  ts=1777768227509  stop=toolUse  blocks=thinking:1,toolCall:3  parts=131 cand=468 thoughts=0 events=132
  #62  ts=1777768297228  stop=toolUse  blocks=thinking:1,toolCall:1  parts=1885 cand=3793 thoughts=0 events=1884
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768297055-0061-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768297055-0061-<provider>.txt --name <descriptive>
      tool failure: bash (call_w8j9kj8i) — exit: code=1
[stdout]
1/1 repro5.test.full repro of gofmt test...sub_path='GqoB16H25sqg9ymK'
abs_path='GqoB16H25sqg9ymK/test.go'
term.exited=2
stdout=>>><<<
stderr=>>>stat GqoB16H25sqg9ymK/test.go: no such …
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #63  ts=1777768328878  stop=toolUse  blocks=thinking:1,toolCall:2  parts=105 cand=388 thoughts=0 events=105
  #64  ts=1777768365578  stop=toolUse  blocks=thinking:1,toolCall:1  parts=125 cand=715 thoughts=0 events=124
  #65  ts=1777768386723  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=423 cand=871 thoughts=0 events=422
  #66  ts=1777768397822  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=253 cand=1028 thoughts=0 events=252
      FLAGS: TOOL_ERROR
      first text: "The issue is clear. `std.testing.tmpDir(.{})` creates directories under `.zig-ca…"
      trace:      /home/agent/.franky/log-trace/1777768397799-0065-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768397799-0065-<provider>.txt --name <descriptive>
      tool failure: edit (call_grqillx6) — edit_ambiguous: edit 2: `old` matches multiple times
        HINT: Edit `old` matched multiple times. Widen `old` with more surrounding context (e.g. include the line above and below) until it uniquely identifies the target. If a function-/declaration-level match is still ambiguous, split into two edits.
  #67  ts=1777768437533  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=46 cand=1280 thoughts=0 events=45
  #68  ts=1777768443867  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=14 cand=118 thoughts=0 events=13
  #69  ts=1777768453422  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=270 cand=864 thoughts=0 events=269
      FLAGS: TOOL_ERROR
      first text: "I see the "already formatted" test also has a content issue. The `well_formatted…"
      trace:      /home/agent/.franky/log-trace/1777768453396-0068-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768453396-0068-<provider>.txt --name <descriptive>
      tool failure: edit (call_b80trtcf) — edit_no_match: edit 0: `old` not found
        HINT: Edit `old` not found. DO NOT widen `old` with more context — that won't help if the original guess is wrong. Re-read the file with the `read` tool to get the actual bytes, then copy-paste the exact text into `old`.
  #70  ts=1777768482777  stop=toolUse  blocks=thinking:1,toolCall:1  parts=22 cand=131 thoughts=0 events=21
  #71  ts=1777768500471  stop=toolUse  blocks=thinking:1,toolCall:1  parts=166 cand=1085 thoughts=0 events=165
  #72  ts=1777768510980  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=108 cand=291 thoughts=0 events=107
  #73  ts=1777768531034  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=100 cand=329 thoughts=0 events=99
      FLAGS: TOOL_ERROR
      first text: "The `well_formatted` input isn't actually well-formatted either — `gofmt` want…"
      trace:      /home/agent/.franky/log-trace/1777768531022-0072-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768531022-0072-<provider>.txt --name <descriptive>
      tool failure: edit (call_e8ruq91f) — edit_no_match: edit 0: `old` not found
        HINT: Edit `old` not found. DO NOT widen `old` with more context — that won't help if the original guess is wrong. Re-read the file with the `read` tool to get the actual bytes, then copy-paste the exact text into `old`.
  #74  ts=1777768535877  stop=toolUse  blocks=thinking:1,toolCall:1  parts=15 cand=119 thoughts=0 events=14
  #75  ts=1777768541066  stop=toolUse  blocks=thinking:1,toolCall:1  parts=72 cand=278 thoughts=0 events=71
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768541058-0074-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768541058-0074-<provider>.txt --name <descriptive>
      tool failure: edit (call_96hdy9q1) — edit_no_match: edit 0: `old` not found
        HINT: Edit `old` not found. DO NOT widen `old` with more context — that won't help if the original guess is wrong. Re-read the file with the `read` tool to get the actual bytes, then copy-paste the exact text into `old`.
  #76  ts=1777768550904  stop=toolUse  blocks=thinking:1,toolCall:1  parts=18 cand=128 thoughts=0 events=17
  #77  ts=1777768564337  stop=toolUse  blocks=thinking:1,toolCall:1  parts=22 cand=122 thoughts=0 events=21
  #78  ts=1777768572729  stop=toolUse  blocks=thinking:1,toolCall:1  parts=58 cand=224 thoughts=0 events=57
  #79  ts=1777768581078  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=147 cand=378 thoughts=0 events=146
  #80  ts=1777768585332  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=24 cand=129 thoughts=0 events=23
      FLAGS: TOOL_ERROR
      first text: "Now let me run the tests:"
      trace:      /home/agent/.franky/log-trace/1777768585329-0079-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768585329-0079-<provider>.txt --name <descriptive>
      tool failure: bash (call_9pqmdcat) — exit: code=1
[stdout]
test
+- run test franky-golang-tests 15 pass, 2 fail (17 total)
error: 'go_dev.test.govetExecute: passes on well-formed package' failed:
       /usr/local/bin/lib/std/testing.zig:615:1…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #81  ts=1777768617865  stop=toolUse  blocks=thinking:1,toolCall:1  parts=42 cand=590 thoughts=0 events=41
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768617859-0080-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768617859-0080-<provider>.txt --name <descriptive>
      tool failure: bash (call_7ajuk4rj) — exit: code=1
[stdout]
1/1 repro7.test.go vet with full path and HOME set...full_path=.zig-cache/tmp/-mx9zpUHV_y5IRMr/.
term.exited=1
stdout=>>><<<
stderr=>>>no required module provides package .zig-cache/tm…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #82  ts=1777768665757  stop=toolUse  blocks=thinking:1,toolCall:2  parts=125 cand=427 thoughts=0 events=125
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768665745-0081-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768665745-0081-<provider>.txt --name <descriptive>
      tool failure: bash (call_h3bhqpon) — exit: code=2
[stdout]
ls: cannot access '/Users/frankittermann/github/franky/franky-golang/go.mod': No such file or directory
cat: /Users/frankittermann/github/franky/franky-golang/go.mod: No such file or d…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
      tool failure: bash (call_v8963p75) — exit: code=1
[stdout]
ls: cannot access '/Users/frankittermann/github/go.mod': No such file or directory
cat: /Users/frankittermann/github/franky/go.mod: No such file or directory (os error 2)
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #83  ts=1777768682813  stop=toolUse  blocks=thinking:1,toolCall:1  parts=98 cand=759 thoughts=0 events=97
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768682803-0082-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768682803-0082-<provider>.txt --name <descriptive>
      tool failure: bash (call_akchx36c) — exit: code=1
[stdout]
/tmp/repro8.zig:26:30: error: no field or member function named 'realpath' in 'Io.Dir'
    const full_path = try cwd.realpath(io, &buf, ".zig-cache");
                          ~~~^~~~…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #84  ts=1777768722009  stop=toolUse  blocks=thinking:1,toolCall:1  parts=224 cand=504 thoughts=0 events=223
  #85  ts=1777768748035  stop=toolUse  blocks=thinking:1,toolCall:2  parts=278 cand=662 thoughts=0 events=278
  #86  ts=1777768778317  stop=toolUse  blocks=thinking:1,toolCall:2  parts=153 cand=484 thoughts=0 events=153
  #87  ts=1777768815138  stop=toolUse  blocks=thinking:1,toolCall:1  parts=261 cand=559 thoughts=0 events=260
  #88  ts=1777768827006  stop=toolUse  blocks=thinking:1,toolCall:1  parts=171 cand=397 thoughts=0 events=170
  #89  ts=1777768832972  stop=toolUse  blocks=thinking:1,toolCall:1  parts=166 cand=397 thoughts=0 events=165
  #90  ts=1777768871533  stop=toolUse  blocks=thinking:1,toolCall:1  parts=131 cand=836 thoughts=0 events=130
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768871520-0089-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768871520-0089-<provider>.txt --name <descriptive>
      tool failure: bash (call_dtj07qnb) — exit: code=1
[stdout]
/tmp/repro9.zig:26:30: error: root source file struct 'posix' has no member named 'getcwd'
    const cwd = try std.posix.getcwd(&cwd_buf);
                    ~~~~~~~~~^~~~~~~
/usr/loc…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #91  ts=1777768900297  stop=toolUse  blocks=thinking:1,toolCall:1  parts=177 cand=912 thoughts=0 events=176
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777768900279-0090-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777768900279-0090-<provider>.txt --name <descriptive>
      tool failure: bash (call_s82nmn5p) — exit: code=1
[stdout]
/tmp/repro10.zig:27:28: error: no field or member function named 'getPath' in 'Io.Dir'
    const cwd = try cwd_dir.getPath(io, &buf);
                    ~~~~~~~^~~~~~~~
/usr/local/bin…
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #92  ts=1777768945584  stop=toolUse  blocks=text:1,thinking:1,toolCall:2  parts=340 cand=751 thoughts=0 events=340
  #93  ts=1777768954622  stop=toolUse  blocks=thinking:1,toolCall:1  parts=209 cand=474 thoughts=0 events=208
  #94  ts=1777769001380  stop=toolUse  blocks=thinking:1,toolCall:2  parts=106 cand=363 thoughts=0 events=106
  #95  ts=1777769012212  stop=toolUse  blocks=thinking:1,toolCall:1  parts=183 cand=452 thoughts=0 events=182
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777769012194-0094-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777769012194-0094-<provider>.txt --name <descriptive>
      tool failure: bash (call_qzmg45m1) — exit: code=2
[stdout]

ls: cannot access '/Users/frankittermann/github/franky/go.work': No such file or directory
ls: cannot access '/Users/frankittermann/github/franky/franky-golang/go.work': No such file …
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #96  ts=1777769027866  stop=toolUse  blocks=thinking:1,toolCall:1  parts=542 cand=1027 thoughts=0 events=541
  #97  ts=1777769034314  stop=toolUse  blocks=thinking:1,toolCall:2  parts=83 cand=272 thoughts=0 events=83
  #98  ts=1777769058924  stop=toolUse  blocks=thinking:1,toolCall:1  parts=826 cand=1950 thoughts=0 events=825
      FLAGS: TOOL_ERROR
      trace:      /home/agent/.franky/log-trace/1777769058847-0097-<provider>.txt
      → fixture:  franky fixture /home/agent/.franky/log-trace/1777769058847-0097-<provider>.txt --name <descriptive>
      tool failure: bash (call_w32c8qj2) — exit: code=1
[stdout]
1/1 repro11.test.go vet with cwd option...tmp_dir_path=.zig-cache/tmp/MLhM6tgrqNm5ayUX
term.exited=1
stdout=>>><<<
stderr=>>>build cache is required, but could not be located: GOCACHE …
        HINT: Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.
  #99  ts=1777769070144  stop=toolUse  blocks=text:1,thinking:1,toolCall:1  parts=359 cand=720 thoughts=0 events=358
  #100  ts=1777769104944  stop=toolUse  blocks=thinking:1,toolCall:1  parts=323 cand=672 thoughts=0 events=322

Summary: 16 anomaly across 100 turns
Reference: docs/reference/diagnostics.md
```


# Implement code highlighting in web-ui

The rendered code blocks in the web UI should have syntax highlighting for better readability. This can be achieved by integrating a syntax highlighting library.

Do a research for what is already available in the used dependencies or what dependency can be added with minimal overhead. Implement the syntax highlighting for code blocks in the web UI, ensuring that it supports multiple programming languages and is visually appealing.