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


# Implement code highlighting in web-ui (done)

The rendered code blocks in the web UI should have syntax highlighting for better readability. This can be achieved by integrating a syntax highlighting library.

Do a research for what is already available in the used dependencies or what dependency can be added with minimal overhead. Implement the syntax highlighting for code blocks in the web UI, ensuring that it supports multiple programming languages and is visually appealing.

# Lets add a new subagent Panel (done)

The panel should be shown on the right similar to the session panel in the web-ui (proxy mode)
and show the full subagent conversation similar to the normal agent ui. Just collapsablle.

# Subagent timouts are not configurable (Done)

I started the franky process with `FRANKY_FIRST_BYTE_TIMEOUT_MS=120000 ./zig-out/bin/franky --first-byte-timeout-ms 120000 --profile ollama-deepseek-flash --mode proxy --role full --yes` but
the subagent was reported timeout after 30000ms instead

```
⚠ first-byte timeout: provider didn't respond within 30000ms; raise --first-byte-timeout-ms (or set FRANKY_FIRST_BYTE_TIMEOUT_MS) for slow models
⚠ {"ok":false,"error_kind":"agent_error","error_message":"sub-agent failed: timeout — first-byte timeout: provider didn't respond within 30000ms; raise --first-byte-timeout-ms (or set FRANKY_FIRST_BYTE_TIMEOUT_MS) for slow models","hint":"retry; details in error_message","partial_text":"Now let me read all the tool files:","turn_count":3}
```

settings.json snippet
```
"ollama-deepseek-flash": {
    "provider": "gateway",
    "base-url": "https://ollama.com/v1/chat/completions",
    "model": "deepseek-v4-flash:cloud",
    "api-key-env": "OLLAMA_KEY",
    "role": "full",
    "ask-tools": "all",
    "prompts": true,
    "log-level": "trace",
    "http-trace-dir": "${HOME}/.franky/log-trace",
    "thinking": "xhigh",
    "env": {
        "FRANKY_FIRST_BYTE_TIMEOUT_MS": "1200000"
    }
},
```

# The subagent tool panel shows thinkinkg deltas

The subagent tool panel (in the main panel) shows thkining delta that shouldn't be there.


```
(thinking) Let
› (thinking) me systematically
› (thinking) analyze the
› (thinking) memory management
› (thinking) patterns in
› (thinking) the requested
› (thinking) files
› (thinking) . I
› (thinking) 'll start
› (thinking) by reading
› (thinking) the files
› (thinking) and searching
› (thinking) for relevant
› (thinking) patterns.
› I
› 'll start
› by reading
› the
› files
› and searching
› for patterns
› systematically.
→ ls {"path":"/Users/frankittermann/github/franky/src","recursive":true,"maxDepth":3} done
› (thinking) Let
› (thinking) me start
› (thinking) by
› (thinking) reading all
› (thinking) the requested
› (thinking) files.
→ ls {"path":"/Users/frankittermann/github/franky/src/coding/tools"} done
→ read {"path":"/Users/frankittermann/github/franky/src/agent/agent.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/agent/types.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/permissions.zig"} done
› (thinking) Let
› (thinking) me now
› (thinking) read all
› (thinking) the tool
› (thinking) files,
› (thinking) the channel
› (thinking) file
› (thinking) , and
› (thinking) continue
› (thinking) analyzing
› (thinking) patterns
› (thinking) .
› Now let
› me read
› all the
› tool files
› :
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/common.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/bash.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/read.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/write.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/edit.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/grep.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/ls.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/find.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/subagent.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/web_search.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/web_fetch.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/truncate.zig"} done
→ read {"path":"/Users/frankittermann/github/franky/src/coding/tools/workspace.zig"} done
```


# SubAgent final text empty

The transcript contains a lot of context but the final text (aka suganet summary) was empty.
```
{"ok":true,"final_text":"","turn_count":4,"tool_call_count":3,"duration_ms":160330,"session_id":"call_omeabw3t","transcript_path":"/home/agent/.franky/sessions/01KQP7P21RJAS2XK8VKBV745GT/subagents/call_omeabw3t/transcript.json"}
```

Here is the `/home/agent/.franky/sessions/01KQP7P21RJAS2XK8VKBV745GT/subagents/call_omeabw3t/transcript.json` content
```
{
  "version": 3,
  "branch": "main",
  "messages": [
    {"role":"user","timestamp":1777789077991,"content":[{"type":"text","text":"Analyze the test suite and TUI layer of the franky project (Zig 0.17-dev).\n\nRead and summarize:\n\n**Tests:**\n1. test/agent_loop_test.zig\n2. test/agent_class_test.zig\n3. test/gitignore_test.zig\n4. test/parallel_tools_test.zig\n5. test/kitchen_sink_test.zig\n6. test/replay_test.zig\n\n**TUI (Terminal UI):**\n7. src/tui/mod.zig\n8. src/tui/buffer.zig (first 80 lines)\n9. src/tui/cell.zig (first 80 lines)\n10. src/tui/editor.zig (first 80 lines)\n11. src/tui/key_decoder.zig (first 80 lines)\n12. src/tui/region.zig (first 80 lines)\n13. src/tui/text_buffer.zig (first 80 lines)\n14. src/tui/keybindings.zig (first 80 lines)\n15. src/tui/diff_renderer.zig (first 80 lines)\n\n**Also read:**\n16. src/sdk.zig - programmatic SDK facade\n17. src/test_helpers.zig - shared test helpers\n\nProvide a structured analysis covering:\n- Test coverage and patterns\n- How integration tests work (faux provider, agent loop round-trips)\n- Test infrastructure quality\n- TUI architecture and capabilities\n- SDK facade design\n- Any gaps in coverage"}]},
    {"role":"assistant","timestamp":1777789122345,"content":[{"type":"thinking","thinking":"The user wants a comprehensive analysis of the `franky` project, focusing on the test suite and the TUI layer.\nI need to read and summarize 17 specific files: 6 tests, 7 TUI modules (with specific line limits), 1 SDK facade, and 1 test helper.\n\nSince reading all these files will take many steps, I must plan the execution to be systematic and efficient. I will use the `read` tool for each file.\n\n**Plan:**\n1.  Read and summarize the 6 test files.\n2.  Read and summarize the 7 TUI files, respecting the line limits.\n3.  Read and summarize the remaining two files (`src/sdk.zig` and `src/test_helpers.zig`).\n4.  Synthesize the analysis based on the gathered content according to the requested structure (Test coverage, Integration tests, Test infrastructure, TUI architecture, SDK facade design, Gaps).\n\nLet's start with the tests.\n\n**Step 1: Reading Test Files**"},{"type":"toolCall","id":"call_9zj4mm0q","name":"read","arguments":{"path":"test/agent_loop_test.zig"}}],"stopReason":"toolUse","provider":"gateway","model":"gemma4:latest","api":"openai-compatible-gateway","diagnostics":{"finishReasonRaw":"tool_calls","partsSeen":201,"candidatesTokens":245,"thinkingEvents":199,"toolCallEvents":1}},
    {"role":"toolResult","timestamp":1777789122349,"toolCallId":"call_9zj4mm0q","content":[{"type":"text","text":"     1\t//! End-to-end test: faux provider streams text + a tool call, agent loop\n     2\t//! executes the tool, feeds back the result, faux emits a terminating\n     3\t//! text reply. The transcript and event stream must match the spec.\n     4\t\n     5\tconst std = @import(\"std\");\n     6\tconst franky = @import(\"franky\");\n     7\tconst ai = franky.ai;\n     8\tconst at = franky.agent.types;\n     9\tconst loop = franky.agent.loop;\n    10\tconst faux_mod = ai.providers.faux;\n    11\tconst testing = std.testing;\n    12\t\n    13\t// Simple echo tool for testing — returns \"got: <args>\" as text.\n    14\tfn echoTool(\n    15\t    tool: *const at.AgentTool,\n    16\t    allocator: std.mem.Allocator,\n    17\t    io: std.Io,\n    18\t    call_id: []const u8,\n    19\t    args_json: []const u8,\n    20\t    cancel: *ai.stream.Cancel,\n    21\t    on_update: at.OnUpdate,\n    22\t) anyerror!at.ToolResult {\n    23\t    _ = tool;\n    24\t    _ = io;\n    25\t    _ = call_id;\n    26\t    _ = cancel;\n    27\t    _ = on_update;\n    28\t    const text = try std.fmt.allocPrint(allocator, \"got: {s}\", .{args_json});\n    29\t    const arr = try allocator.alloc(ai.types.ContentBlock, 1);\n    30\t    arr[0] = .{ .text = .{ .text = text } };\n    31\t    return .{ .content = arr };\n    32\t}\n    33\t\n    34\t// Bridge: the faux provider's stream function goes through the registry,\n    35\t// so we register a shim that looks up the faux instance from userdata.\n    36\tfn fauxStreamShim(ctx: ai.registry.StreamCtx) anyerror!void {\n    37\t    const faux_ptr: *faux_mod.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));\n    38\t    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);\n    39\t}\n    40\t\n    41\tfn newAgentChannel(gpa: std.mem.Allocator) !loop.AgentChannel {\n    42\t    return try loop.AgentChannel.initWithDrop(\n    43\t        gpa,\n    44\t        128,\n    45\t        at.AgentEvent.deinit,\n    46\t        gpa,\n    47\t    );\n    48\t}\n    49\t\n    50\ttest \"agent loop: text-only assistant produces message_end + turn_end\" {\n    51\t    var threaded = franky.test_helpers.threadedIo();\n    52\t    defer threaded.deinit();\n    53\t    const io = threaded.io();\n    54\t\n    55\t    const gpa = std.testing.allocator;\n    56\t\n    57\t    var faux = faux_mod.FauxProvider.init(gpa);\n    58\t    defer faux.deinit();\n    59\t    try faux.push(.{ .events = &.{\n    60\t        .{ .text = .{ .text = \"hi there\", .chunk_size = 4 } },\n    61\t    } });\n    62\t\n    63\t    var reg = ai.registry.Registry.init(gpa);\n    64\t    defer reg.deinit();\n    65\t    try reg.register(.{\n    66\t        .api = \"faux\",\n    67\t        .provider = \"faux\",\n    68\t        .stream_fn = fauxStreamShim,\n    69\t        .userdata = @ptrCast(&faux),\n    70\t    });\n    71\t\n    72\t    var cancel = ai.stream.Cancel{};\n    73\t    var transcript = loop.Transcript.init(gpa);\n    74\t    defer transcript.deinit();\n    75\t\n    76\t    var ch = try newAgentChannel(gpa);\n    77\t    defer ch.deinit();\n    78\t\n    79\t    const model = ai.types.Model{\n    80\t        .id = \"faux-1\",\n    81\t        .provider = \"faux\",\n    82\t        .api = \"faux\",\n    83\t    };\n    84\t\n    85\t    const config = loop.Config{\n    86\t        .model = model,\n    87\t        .system_prompt = \"you are a test\",\n    88\t        .tools = &.{},\n    89\t        .registry = &reg,\n    90\t        .cancel = &cancel,\n    91\t    };\n    92\t\n    93\t    loop.agentLoop(gpa, io, &transcript, config, &ch);\n    94\t\n    95\t    // Drain events; count message_end.\n    96\t    var turn_starts: u32 = 0;\n    97\t    var message_ends: u32 = 0;\n    98\t    var turn_ends: u32 = 0;\n    99\t    var agent_errors: u32 = 0;\n   100\t    while (ch.next(io)) |ev| {\n   101\t        switch (ev) {\n   102\t            .turn_start => turn_starts += 1,\n   103\t            .message_end => message_ends += 1,\n   104\t            .turn_end => turn_ends += 1,\n   105\t            .agent_error => agent_errors += 1,\n   106\t            else => {},\n   107\t        }\n   108\t        ev.deinit(gpa);\n   109\t    }\n   110\t\n   111\t    try testing.expectEqual(@as(u32, 1), turn_starts);\n   112\t    try testing.expectEqual(@as(u32, 1), message_ends);\n   113\t    try testing.expectEqual(@as(u32, 1), turn_ends);\n   114\t    try testing.expectEqual(@as(u32, 0), agent_errors);\n   115\t    try testing.expectEqual(@as(usize, 1), transcript.messages.items.len);\n   116\t}\n   117\t\n   118\ttest \"agent loop: tool call round-trips — text then tool then text\" {\n   119\t    var threaded = franky.test_helpers.threadedIo();\n   120\t    defer threaded.deinit();\n   121\t    const io = threaded.io();\n   122\t\n   123\t    const gpa = std.testing.allocator;\n   124\t\n   125\t    var faux = faux_mod.FauxProvider.init(gpa);\n   126\t    defer faux.deinit();\n   127\t\n   128\t    // turn 1: assistant asks for a tool call.\n   129\t    try faux.push(.{ .events = &.{\n   130\t        .{ .tool_call = .{\n   131\t            .id = \"call_1\",\n   132\t            .name = \"echo\",\n   133\t            .args_json = \"{\\\"x\\\":1}\",\n   134\t            .args_chunk_size = 3,\n   135\t        } },\n   136\t        .{ .done = .{ .stop_reason = .tool_use } },\n   137\t    } });\n   138\t    // turn 2: assistant stops after seeing tool result.\n   139\t    try faux.push(.{ .events = &.{\n   140\t        .{ .text = .{ .text = \"all done\", .chunk_size = 4 } },\n   141\t        .{ .done = .{ .stop_reason = .stop } },\n   142\t    } });\n   143\t\n   144\t    var reg = ai.registry.Registry.init(gpa);\n   145\t    defer reg.deinit();\n   146\t    try reg.register(.{\n   147\t        .api = \"faux\",\n   148\t        .provider = \"faux\",\n   149\t        .stream_fn = fauxStreamShim,\n   150\t        .userdata = @ptrCast(&faux),\n   151\t    });\n   152\t\n   153\t    var cancel = ai.stream.Cancel{};\n   154\t    var transcript = loop.Transcript.init(gpa);\n   155\t    defer transcript.deinit();\n   156\t\n   157\t    var ch = try newAgentChannel(gpa);\n   158\t    defer ch.deinit();\n   159\t\n   160\t    const echo_tool = at.AgentTool{\n   161\t        .name = \"echo\",\n   162\t        .description = \"echo the args as text\",\n   163\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   164\t        .execute = echoTool,\n   165\t    };\n   166\t\n   167\t    const config = loop.Config{\n   168\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   169\t        .tools = &[_]at.AgentTool{echo_tool},\n   170\t        .registry = &reg,\n   171\t        .cancel = &cancel,\n   172\t    };\n   173\t\n   174\t    loop.agentLoop(gpa, io, &transcript, config, &ch);\n   175\t\n   176\t    // Drain events — count by kind.\n   177\t    var kinds: [9]u32 = @splat(0);\n   178\t    var saw_tool_end_with_echo = false;\n   179\t    while (ch.next(io)) |ev| {\n   180\t        kinds[@intFromEnum(ev)] += 1;\n   181\t        switch (ev) {\n   182\t            .tool_execution_end => |e| {\n   183\t                try testing.expectEqualStrings(\"call_1\", e.call_id);\n   184\t                if (e.result.content.len > 0) {\n   185\t                    switch (e.result.content[0]) {\n   186\t                        .text => |t| {\n   187\t                            if (std.mem.indexOf(u8, t.text, \"got:\") != null) {\n   188\t                                saw_tool_end_with_echo = true;\n   189\t                            }\n   190\t                        },\n   191\t                        else => {},\n   192\t                    }\n   193\t                }\n   194\t            },\n   195\t            else => {},\n   196\t        }\n   197\t        ev.deinit(gpa);\n   198\t    }\n   199\t\n   200\t    try testing.expect(saw_tool_end_with_echo);\n   201\t    // Two turns expected.\n   202\t    try testing.expectEqual(@as(u32, 2), kinds[@intFromEnum(at.AgentEventKind.turn_start)]);\n   203\t    try testing.expectEqual(@as(u32, 2), kinds[@intFromEnum(at.AgentEventKind.turn_end)]);\n   204\t    // 4 message_end: assistant-turn1, toolResult-turn1, assistant-turn2.\n   205\t    // Actually: assistant1, toolResult1, assistant2 = 3.\n   206\t    try testing.expectEqual(@as(u32, 3), kinds[@intFromEnum(at.AgentEventKind.message_end)]);\n   207\t    try testing.expectEqual(@as(u32, 1), kinds[@intFromEnum(at.AgentEventKind.tool_execution_start)]);\n   208\t    try testing.expectEqual(@as(u32, 1), kinds[@intFromEnum(at.AgentEventKind.tool_execution_end)]);\n   209\t\n   210\t    // Transcript: assistant1 (with tool_call), toolResult1, assistant2.\n   211\t    try testing.expectEqual(@as(usize, 3), transcript.messages.items.len);\n   212\t    try testing.expectEqual(ai.types.Role.assistant, transcript.messages.items[0].role);\n   213\t    try testing.expectEqual(ai.types.Role.tool_result, transcript.messages.items[1].role);\n   214\t    try testing.expectEqual(ai.types.Role.assistant, transcript.messages.items[2].role);\n   215\t}\n   216\t\n   217\ttest \"agent loop: before_tool_call can block a call\" {\n   218\t    var threaded = franky.test_helpers.threadedIo();\n   219\t    defer threaded.deinit();\n   220\t    const io = threaded.io();\n   221\t\n   222\t    const gpa = std.testing.allocator;\n   223\t\n   224\t    var faux = faux_mod.FauxProvider.init(gpa);\n   225\t    defer faux.deinit();\n   226\t    try faux.push(.{ .events = &.{\n   227\t        .{ .tool_call = .{ .id = \"c\", .name = \"echo\", .args_json = \"{}\" } },\n   228\t        .{ .done = .{ .stop_reason = .tool_use } },\n   229\t    } });\n   230\t    try faux.push(.{ .events = &.{\n   231\t        .{ .text = .{ .text = \"ok\" } },\n   232\t    } });\n   233\t\n   234\t    var reg = ai.registry.Registry.init(gpa);\n   235\t    defer reg.deinit();\n   236\t    try reg.register(.{\n   237\t        .api = \"faux\",\n   238\t        .provider = \"faux\",\n   239\t        .stream_fn = fauxStreamShim,\n   240\t        .userdata = @ptrCast(&faux),\n   241\t    });\n   242\t\n   243\t    var cancel = ai.stream.Cancel{};\n   244\t    var transcript = loop.Transcript.init(gpa);\n   245\t    defer transcript.deinit();\n   246\t\n   247\t    var ch = try newAgentChannel(gpa);\n   248\t    defer ch.deinit();\n   249\t\n   250\t    const Hook = struct {\n   251\t        fn block(_: ?*anyopaque, _: *const at.AgentTool, _: []const u8, _: []const u8) loop.HookDecision {\n   252\t            return .{ .block = true, .reason_text = \"policy deny\" };\n   253\t        }\n   254\t    };\n   255\t\n   256\t    const echo_tool = at.AgentTool{\n   257\t        .name = \"echo\",\n   258\t        .description = \"\",\n   259\t        .parameters_json = \"{}\",\n   260\t        .execute = echoTool,\n   261\t    };\n   262\t\n   263\t    loop.agentLoop(gpa, io, &transcript, .{\n   264\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   265\t        .tools = &[_]at.AgentTool{echo_tool},\n   266\t        .registry = &reg,\n   267\t        .cancel = &cancel,\n   268\t        .before_tool_call = Hook.block,\n   269\t    }, &ch);\n   270\t\n   271\t    // The tool_execution_end carries an is_error=true result.\n   272\t    var saw_error_result = false;\n   273\t    while (ch.next(io)) |ev| {\n   274\t        switch (ev) {\n   275\t            .tool_execution_end => |e| {\n   276\t                if (e.result.is_error) saw_error_result = true;\n   277\t            },\n   278\t            else => {},\n   279\t        }\n   280\t        ev.deinit(gpa);\n   281\t    }\n   282\t    try testing.expect(saw_error_result);\n   283\t}\n   284\t\n   285\t// ─── v1.4.1 — runtime role gate ───────────────────────────────────\n   286\t\n   287\ttest \"runtime role gate: tool_call for role-disabled built-in emits role_denied\" {\n   288\t    var threaded = franky.test_helpers.threadedIo();\n   289\t    defer threaded.deinit();\n   290\t    const io = threaded.io();\n   291\t    const gpa = testing.allocator;\n   292\t\n   293\t    // Faux script: emit ONE tool_call for `bash` (which is not in\n   294\t    // the registered tools below — under role=plan), then `done`.\n   295\t    var faux = faux_mod.FauxProvider.init(gpa);\n   296\t    defer faux.deinit();\n   297\t    try faux.push(.{ .events = &.{\n   298\t        .{ .tool_call = .{ .id = \"c-1\", .name = \"bash\", .args_json = \"{\\\"command\\\":\\\"ls\\\"}\" } },\n   299\t        .{ .done = .{ .stop_reason = .tool_use } },\n   300\t    } });\n   301\t    // Second turn: model just stops (after seeing the role_denied result).\n   302\t    try faux.push(.{ .events = &.{\n   303\t        .{ .text = .{ .text = \"ack\", .chunk_size = 4 } },\n   304\t        .{ .done = .{ .stop_reason = .stop } },\n   305\t    } });\n   306\t\n   307\t    var reg = ai.registry.Registry.init(gpa);\n   308\t    defer reg.deinit();\n   309\t    try reg.register(.{\n   310\t        .api = \"faux\",\n   311\t        .provider = \"faux\",\n   312\t        .stream_fn = fauxStreamShim,\n   313\t        .userdata = @ptrCast(&faux),\n   314\t    });\n   315\t\n   316\t    var transcript = loop.Transcript.init(gpa);\n   317\t    defer transcript.deinit();\n   318\t    const user_content = try gpa.alloc(ai.types.ContentBlock, 1);\n   319\t    user_content[0] = .{ .text = .{ .text = try gpa.dupe(u8, \"run something\") } };\n   320\t    try transcript.append(.{ .role = .user, .content = user_content, .timestamp = 0 });\n   321\t\n   322\t    var ch = try loop.AgentChannel.initWithDrop(gpa, 256, at.AgentEvent.deinit, gpa);\n   323\t    defer ch.deinit();\n   324\t\n   325\t    // Mimic what `coding.role.RoleGate` does without importing it\n   326\t    // here (this file lives under `test/`; the loop's interface is\n   327\t    // generic).\n   328\t    const Gate = struct {\n   329\t        fn check(_: ?*anyopaque, tool_name: []const u8) ?loop.RoleDenial {\n   330\t            if (std.mem.eql(u8, tool_name, \"bash\")) {\n   331\t                return .{ .current_role = \"plan\", .min_role = \"code\" };\n   332\t            }\n   333\t            return null;\n   334\t        }\n   335\t    };\n   336\t\n   337\t    var cancel: ai.stream.Cancel = .{};\n   338\t    loop.agentLoop(gpa, io, &transcript, .{\n   339\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   340\t        .tools = &[_]at.AgentTool{}, // no tools registered → bash is \"unknown\"\n   341\t        .registry = &reg,\n   342\t        .cancel = &cancel,\n   343\t        .role_denied = Gate.check,\n   344\t    }, &ch);\n   345\t\n   346\t    // We expect a tool_execution_end carrying tool_code = \"role_denied\".\n   347\t    var saw_role_denied = false;\n   348\t    while (ch.next(io)) |ev| {\n   349\t        switch (ev) {\n   350\t            .tool_execution_end => |e| {\n   351\t                if (e.result.is_error) {\n   352\t                    if (e.result.tool_code) |tc| {\n   353\t                        if (std.mem.eql(u8, tc, \"role_denied\")) saw_role_denied = true;\n   354\t                    }\n   355\t                }\n   356\t            },\n   357\t            else => {},\n   358\t        }\n   359\t        ev.deinit(gpa);\n   360\t    }\n   361\t    try testing.expect(saw_role_denied);\n   362\t}\n   363\t\n   364\t// ─── max_turns: cap, extension hook, additive credits ─────────────\n   365\t\n   366\t/// Push N turns into faux, each ending with a tool_call so the loop\n   367\t/// has reason to keep going. The agentLoop should hit the cap when\n   368\t/// turn_count == max_turns.\n   369\tfn pushNTurnsWithToolCall(faux: *faux_mod.FauxProvider, n: u32) !void {\n   370\t    var i: u32 = 0;\n   371\t    while (i < n) : (i += 1) {\n   372\t        try faux.push(.{ .events = &.{\n   373\t            .{ .tool_call = .{\n   374\t                .id = \"call_max_turns\",\n   375\t                .name = \"echo\",\n   376\t                .args_json = \"{\\\"x\\\":1}\",\n   377\t            } },\n   378\t            .{ .done = .{ .stop_reason = .tool_use } },\n   379\t        } });\n   380\t    }\n   381\t}\n   382\t\n   383\ttest \"agent loop: max_turns cap emits max_turns_exceeded with no hook\" {\n   384\t    var threaded = franky.test_helpers.threadedIo();\n   385\t    defer threaded.deinit();\n   386\t    const io = threaded.io();\n   387\t\n   388\t    const gpa = std.testing.allocator;\n   389\t\n   390\t    var faux = faux_mod.FauxProvider.init(gpa);\n   391\t    defer faux.deinit();\n   392\t    try pushNTurnsWithToolCall(&faux, 5); // far more turns scripted than cap\n   393\t\n   394\t    var reg = ai.registry.Registry.init(gpa);\n   395\t    defer reg.deinit();\n   396\t    try reg.register(.{\n   397\t        .api = \"faux\",\n   398\t        .provider = \"faux\",\n   399\t        .stream_fn = fauxStreamShim,\n   400\t        .userdata = @ptrCast(&faux),\n   401\t    });\n   402\t\n   403\t    var cancel = ai.stream.Cancel{};\n   404\t    var transcript = loop.Transcript.init(gpa);\n   405\t    defer transcript.deinit();\n   406\t\n   407\t    var ch = try newAgentChannel(gpa);\n   408\t    defer ch.deinit();\n   409\t\n   410\t    const echo_tool = at.AgentTool{\n   411\t        .name = \"echo\",\n   412\t        .description = \"echo\",\n   413\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   414\t        .execute = echoTool,\n   415\t    };\n   416\t\n   417\t    loop.agentLoop(gpa, io, &transcript, .{\n   418\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   419\t        .tools = &[_]at.AgentTool{echo_tool},\n   420\t        .registry = &reg,\n   421\t        .cancel = &cancel,\n   422\t        .max_turns = 2,\n   423\t    }, &ch);\n   424\t\n   425\t    var turn_starts: u32 = 0;\n   426\t    var max_turns_errors: u32 = 0;\n   427\t    var max_turns_msg: ?[]const u8 = null;\n   428\t    while (ch.next(io)) |ev| {\n   429\t        switch (ev) {\n   430\t            .turn_start => turn_starts += 1,\n   431\t            .agent_error => |d| {\n   432\t                if (d.code == .max_turns_exceeded) {\n   433\t                    max_turns_errors += 1;\n   434\t                    max_turns_msg = d.message;\n   435\t                }\n   436\t            },\n   437\t            else => {},\n   438\t        }\n   439\t        ev.deinit(gpa);\n   440\t    }\n   441\t\n   442\t    try testing.expectEqual(@as(u32, 2), turn_starts);\n   443\t    try testing.expectEqual(@as(u32, 1), max_turns_errors);\n   444\t    // Message should mention the cap that was hit.\n   445\t    try testing.expect(max_turns_msg != null);\n   446\t}\n   447\t\n   448\t/// Hook userdata: counts calls; first call extends by 2, second\n   449\t/// call returns stop. Simulates the UX where the user says\n   450\t/// \"yes once, then no\" when prompted to extend.\n   451\tconst ExtendThenStop = struct {\n   452\t    calls: u32 = 0,\n   453\t    grant: u32 = 2,\n   454\t\n   455\t    fn cb(userdata: ?*anyopaque, used: u32, cap: u32) loop.MaxTurnsDecision {\n   456\t        _ = used;\n   457\t        _ = cap;\n   458\t        const self: *ExtendThenStop = @ptrCast(@alignCast(userdata.?));\n   459\t        self.calls += 1;\n   460\t        if (self.calls == 1) return .{ .extend = self.grant };\n   461\t        return .stop;\n   462\t    }\n   463\t};\n   464\t\n   465\ttest \"agent loop: max_turns hook .extend(N) is additive across calls\" {\n   466\t    var threaded = franky.test_helpers.threadedIo();\n   467\t    defer threaded.deinit();\n   468\t    const io = threaded.io();\n   469\t\n   470\t    const gpa = std.testing.allocator;\n   471\t\n   472\t    var faux = faux_mod.FauxProvider.init(gpa);\n   473\t    defer faux.deinit();\n   474\t    try pushNTurnsWithToolCall(&faux, 10);\n   475\t\n   476\t    var reg = ai.registry.Registry.init(gpa);\n   477\t    defer reg.deinit();\n   478\t    try reg.register(.{\n   479\t        .api = \"faux\",\n   480\t        .provider = \"faux\",\n   481\t        .stream_fn = fauxStreamShim,\n   482\t        .userdata = @ptrCast(&faux),\n   483\t    });\n   484\t\n   485\t    var cancel = ai.stream.Cancel{};\n   486\t    var transcript = loop.Transcript.init(gpa);\n   487\t    defer transcript.deinit();\n   488\t\n   489\t    var ch = try newAgentChannel(gpa);\n   490\t    defer ch.deinit();\n   491\t\n   492\t    const echo_tool = at.AgentTool{\n   493\t        .name = \"echo\",\n   494\t        .description = \"echo\",\n   495\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   496\t        .execute = echoTool,\n   497\t    };\n   498\t\n   499\t    var hook_state = ExtendThenStop{};\n   500\t\n   501\t    loop.agentLoop(gpa, io, &transcript, .{\n   502\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   503\t        .tools = &[_]at.AgentTool{echo_tool},\n   504\t        .registry = &reg,\n   505\t        .cancel = &cancel,\n   506\t        .max_turns = 1,\n   507\t        .on_max_turns = ExtendThenStop.cb,\n   508\t        .on_max_turns_userdata = @ptrCast(&hook_state),\n   509\t    }, &ch);\n   510\t\n   511\t    var turn_starts: u32 = 0;\n   512\t    var max_turns_errors: u32 = 0;\n   513\t    while (ch.next(io)) |ev| {\n   514\t        switch (ev) {\n   515\t            .turn_start => turn_starts += 1,\n   516\t            .agent_error => |d| {\n   517\t                if (d.code == .max_turns_exceeded) max_turns_errors += 1;\n   518\t            },\n   519\t            else => {},\n   520\t        }\n   521\t        ev.deinit(gpa);\n   522\t    }\n   523\t\n   524\t    // 1 (initial cap) + 2 (extension) = 3 turns total.\n   525\t    try testing.expectEqual(@as(u32, 3), turn_starts);\n   526\t    // Hook was called twice: at cap=1 → extend, at cap=3 → stop.\n   527\t    try testing.expectEqual(@as(u32, 2), hook_state.calls);\n   528\t    try testing.expectEqual(@as(u32, 1), max_turns_errors);\n   529\t}\n   530\t\n   531\ttest \"agent loop: max_turns hook returning .stop emits max_turns_exceeded immediately\" {\n   532\t    var threaded = franky.test_helpers.threadedIo();\n   533\t    defer threaded.deinit();\n   534\t    const io = threaded.io();\n   535\t\n   536\t    const gpa = std.testing.allocator;\n   537\t\n   538\t    var faux = faux_mod.FauxProvider.init(gpa);\n   539\t    defer faux.deinit();\n   540\t    try pushNTurnsWithToolCall(&faux, 5);\n   541\t\n   542\t    var reg = ai.registry.Registry.init(gpa);\n   543\t    defer reg.deinit();\n   544\t    try reg.register(.{\n   545\t        .api = \"faux\",\n   546\t        .provider = \"faux\",\n   547\t        .stream_fn = fauxStreamShim,\n   548\t        .userdata = @ptrCast(&faux),\n   549\t    });\n   550\t\n   551\t    var cancel = ai.stream.Cancel{};\n   552\t    var transcript = loop.Transcript.init(gpa);\n   553\t    defer transcript.deinit();\n   554\t\n   555\t    var ch = try newAgentChannel(gpa);\n   556\t    defer ch.deinit();\n   557\t\n   558\t    const echo_tool = at.AgentTool{\n   559\t        .name = \"echo\",\n   560\t        .description = \"echo\",\n   561\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   562\t        .execute = echoTool,\n   563\t    };\n   564\t\n   565\t    const AlwaysStop = struct {\n   566\t        fn cb(userdata: ?*anyopaque, used: u32, cap: u32) loop.MaxTurnsDecision {\n   567\t            _ = userdata;\n   568\t            _ = used;\n   569\t            _ = cap;\n   570\t            return .stop;\n   571\t        }\n   572\t    };\n   573\t\n   574\t    loop.agentLoop(gpa, io, &transcript, .{\n   575\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   576\t        .tools = &[_]at.AgentTool{echo_tool},\n   577\t        .registry = &reg,\n   578\t        .cancel = &cancel,\n   579\t        .max_turns = 2,\n   580\t        .on_max_turns = AlwaysStop.cb,\n   581\t    }, &ch);\n   582\t\n   583\t    var turn_starts: u32 = 0;\n   584\t    var max_turns_errors: u32 = 0;\n   585\t    while (ch.next(io)) |ev| {\n   586\t        switch (ev) {\n   587\t            .turn_start => turn_starts += 1,\n   588\t            .agent_error => |d| {\n   589\t                if (d.code == .max_turns_exceeded) max_turns_errors += 1;\n   590\t            },\n   591\t            else => {},\n   592\t        }\n   593\t        ev.deinit(gpa);\n   594\t    }\n   595\t\n   596\t    try testing.expectEqual(@as(u32, 2), turn_starts);\n   597\t    try testing.expectEqual(@as(u32, 1), max_turns_errors);\n   598\t}\n"}]},
    {"role":"assistant","timestamp":1777789176950,"content":[{"type":"toolCall","id":"call_aglkxnwp","name":"read","arguments":{"path":"test/agent_class_test.zig"}}],"stopReason":"toolUse","provider":"gateway","model":"gemma4:latest","api":"openai-compatible-gateway","diagnostics":{"finishReasonRaw":"tool_calls","partsSeen":2,"candidatesTokens":21,"toolCallEvents":1}},
    {"role":"toolResult","timestamp":1777789176955,"toolCallId":"call_aglkxnwp","content":[{"type":"text","text":"     1\t//! Exercises the high-level Agent wrapper.\n     2\t\n     3\tconst std = @import(\"std\");\n     4\tconst franky = @import(\"franky\");\n     5\tconst ai = franky.ai;\n     6\tconst agent_mod = franky.agent;\n     7\tconst at = agent_mod.types;\n     8\tconst testing = std.testing;\n     9\t\n    10\tfn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {\n    11\t    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));\n    12\t    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);\n    13\t}\n    14\t\n    15\tconst EventCounter = struct {\n    16\t    turn_starts: std.atomic.Value(u32) = .init(0),\n    17\t    turn_ends: std.atomic.Value(u32) = .init(0),\n    18\t    message_ends: std.atomic.Value(u32) = .init(0),\n    19\t    agent_errors: std.atomic.Value(u32) = .init(0),\n    20\t\n    21\t    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {\n    22\t        const self: *EventCounter = @ptrCast(@alignCast(ud.?));\n    23\t        switch (ev) {\n    24\t            .turn_start => _ = self.turn_starts.fetchAdd(1, .monotonic),\n    25\t            .turn_end => _ = self.turn_ends.fetchAdd(1, .monotonic),\n    26\t            .message_end => _ = self.message_ends.fetchAdd(1, .monotonic),\n    27\t            .agent_error => _ = self.agent_errors.fetchAdd(1, .monotonic),\n    28\t            else => {},\n    29\t        }\n    30\t    }\n    31\t};\n    32\t\n    33\ttest \"Agent.prompt runs a turn and broadcasts events\" {\n    34\t    var threaded = franky.test_helpers.threadedIo();\n    35\t    defer threaded.deinit();\n    36\t    const io = threaded.io();\n    37\t\n    38\t    const gpa = testing.allocator;\n    39\t\n    40\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n    41\t    defer faux.deinit();\n    42\t    try faux.push(.{ .events = &.{\n    43\t        .{ .text = .{ .text = \"ok\", .chunk_size = 2 } },\n    44\t    } });\n    45\t\n    46\t    var reg = ai.registry.Registry.init(gpa);\n    47\t    defer reg.deinit();\n    48\t    try reg.register(.{\n    49\t        .api = \"faux\",\n    50\t        .provider = \"faux\",\n    51\t        .stream_fn = fauxShim,\n    52\t        .userdata = @ptrCast(&faux),\n    53\t    });\n    54\t\n    55\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n    56\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n    57\t        .registry = &reg,\n    58\t    });\n    59\t    defer agent.deinit();\n    60\t\n    61\t    var counter: EventCounter = .{};\n    62\t    _ = try agent.subscribe(EventCounter.onEvent, @ptrCast(&counter));\n    63\t\n    64\t    try agent.prompt(\"hello\");\n    65\t    agent.waitForIdle();\n    66\t\n    67\t    try testing.expectEqual(@as(u32, 1), counter.turn_starts.load(.monotonic));\n    68\t    try testing.expectEqual(@as(u32, 1), counter.turn_ends.load(.monotonic));\n    69\t    try testing.expectEqual(@as(u32, 1), counter.message_ends.load(.monotonic));\n    70\t    try testing.expectEqual(@as(u32, 0), counter.agent_errors.load(.monotonic));\n    71\t    // transcript: user + assistant\n    72\t    try testing.expectEqual(@as(usize, 2), agent.transcript.messages.items.len);\n    73\t}\n    74\t\n    75\ttest \"Agent.prompt rejects when already streaming\" {\n    76\t    var threaded = franky.test_helpers.threadedIo();\n    77\t    defer threaded.deinit();\n    78\t    const io = threaded.io();\n    79\t\n    80\t    const gpa = testing.allocator;\n    81\t\n    82\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n    83\t    defer faux.deinit();\n    84\t    // Two steps so two prompts are possible serially.\n    85\t    try faux.push(.{ .events = &.{.{ .text = .{ .text = \"one\", .chunk_size = 8 } }} });\n    86\t    try faux.push(.{ .events = &.{.{ .text = .{ .text = \"two\", .chunk_size = 8 } }} });\n    87\t\n    88\t    var reg = ai.registry.Registry.init(gpa);\n    89\t    defer reg.deinit();\n    90\t    try reg.register(.{\n    91\t        .api = \"faux\",\n    92\t        .provider = \"faux\",\n    93\t        .stream_fn = fauxShim,\n    94\t        .userdata = @ptrCast(&faux),\n    95\t    });\n    96\t\n    97\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n    98\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n    99\t        .registry = &reg,\n   100\t    });\n   101\t    defer agent.deinit();\n   102\t\n   103\t    try agent.prompt(\"one\");\n   104\t    // Racy-but-deterministic: immediately after prompt, is_streaming is true\n   105\t    // (the worker thread holds it until draining completes). Second prompt\n   106\t    // while streaming must return AgentBusy.\n   107\t    // Either it errors (still streaming) or it succeeds (worker already done).\n   108\t    // Both outcomes are legal under this race; we simply assert we reach\n   109\t    // idle and can prompt again.\n   110\t    agent.prompt(\"two\") catch |e| switch (e) {\n   111\t        error.AgentBusy => {},\n   112\t        else => return e,\n   113\t    };\n   114\t    agent.waitForIdle();\n   115\t\n   116\t    // Now the second prompt succeeds.\n   117\t    try agent.prompt(\"two\");\n   118\t    agent.waitForIdle();\n   119\t}\n   120\t\n   121\ttest \"Agent.reset clears transcript\" {\n   122\t    var threaded = franky.test_helpers.threadedIo();\n   123\t    defer threaded.deinit();\n   124\t    const io = threaded.io();\n   125\t\n   126\t    const gpa = testing.allocator;\n   127\t\n   128\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   129\t    defer faux.deinit();\n   130\t    try faux.push(.{ .events = &.{.{ .text = .{ .text = \"hi\" } }} });\n   131\t\n   132\t    var reg = ai.registry.Registry.init(gpa);\n   133\t    defer reg.deinit();\n   134\t    try reg.register(.{ .api = \"faux\", .provider = \"faux\", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });\n   135\t\n   136\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   137\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   138\t        .registry = &reg,\n   139\t    });\n   140\t    defer agent.deinit();\n   141\t\n   142\t    try agent.prompt(\"first\");\n   143\t    agent.waitForIdle();\n   144\t    try testing.expect(agent.transcript.messages.items.len > 0);\n   145\t\n   146\t    agent.reset();\n   147\t    try testing.expectEqual(@as(usize, 0), agent.transcript.messages.items.len);\n   148\t}\n   149\t\n   150\ttest \"Agent.steer: queue + drain round-trip\" {\n   151\t    var threaded = franky.test_helpers.threadedIo();\n   152\t    defer threaded.deinit();\n   153\t    const io = threaded.io();\n   154\t    const gpa = testing.allocator;\n   155\t\n   156\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   157\t    defer faux.deinit();\n   158\t    var reg = ai.registry.Registry.init(gpa);\n   159\t    defer reg.deinit();\n   160\t    try reg.register(.{ .api = \"faux\", .provider = \"faux\", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });\n   161\t\n   162\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   163\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   164\t        .registry = &reg,\n   165\t    });\n   166\t    defer agent.deinit();\n   167\t\n   168\t    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());\n   169\t    try agent.steer(\"be concise\");\n   170\t    try agent.steer(\"prefer diffs\");\n   171\t    try testing.expectEqual(@as(usize, 2), agent.pendingSteerCount());\n   172\t\n   173\t    const drained = try agent.drainSteerQueue();\n   174\t    defer {\n   175\t        for (drained) |m| gpa.free(m);\n   176\t        gpa.free(drained);\n   177\t    }\n   178\t    try testing.expectEqual(@as(usize, 2), drained.len);\n   179\t    try testing.expectEqualStrings(\"be concise\", drained[0]);\n   180\t    try testing.expectEqualStrings(\"prefer diffs\", drained[1]);\n   181\t    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());\n   182\t}\n   183\t\n   184\ttest \"Agent.followUp: separate queue from steer\" {\n   185\t    var threaded = franky.test_helpers.threadedIo();\n   186\t    defer threaded.deinit();\n   187\t    const io = threaded.io();\n   188\t    const gpa = testing.allocator;\n   189\t\n   190\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   191\t    defer faux.deinit();\n   192\t    var reg = ai.registry.Registry.init(gpa);\n   193\t    defer reg.deinit();\n   194\t    try reg.register(.{ .api = \"faux\", .provider = \"faux\", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });\n   195\t\n   196\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   197\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   198\t        .registry = &reg,\n   199\t    });\n   200\t    defer agent.deinit();\n   201\t\n   202\t    try agent.steer(\"S\");\n   203\t    try agent.followUp(\"F1\");\n   204\t    try agent.followUp(\"F2\");\n   205\t    try testing.expectEqual(@as(usize, 1), agent.pendingSteerCount());\n   206\t    try testing.expectEqual(@as(usize, 2), agent.pendingFollowUpCount());\n   207\t\n   208\t    const s = try agent.drainSteerQueue();\n   209\t    defer {\n   210\t        for (s) |m| gpa.free(m);\n   211\t        gpa.free(s);\n   212\t    }\n   213\t    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());\n   214\t    try testing.expectEqual(@as(usize, 2), agent.pendingFollowUpCount());\n   215\t\n   216\t    const f = try agent.drainFollowUpQueue();\n   217\t    defer {\n   218\t        for (f) |m| gpa.free(m);\n   219\t        gpa.free(f);\n   220\t    }\n   221\t    try testing.expectEqualStrings(\"F1\", f[0]);\n   222\t    try testing.expectEqualStrings(\"F2\", f[1]);\n   223\t}\n   224\t\n   225\ttest \"Agent: deinit frees queued-but-not-drained messages\" {\n   226\t    var threaded = franky.test_helpers.threadedIo();\n   227\t    defer threaded.deinit();\n   228\t    const io = threaded.io();\n   229\t    const gpa = testing.allocator;\n   230\t\n   231\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   232\t    defer faux.deinit();\n   233\t    var reg = ai.registry.Registry.init(gpa);\n   234\t    defer reg.deinit();\n   235\t    try reg.register(.{ .api = \"faux\", .provider = \"faux\", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });\n   236\t\n   237\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   238\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   239\t        .registry = &reg,\n   240\t    });\n   241\t    // Leave both queues populated — testing.allocator flags any leak.\n   242\t    try agent.steer(\"leak-check-a\");\n   243\t    try agent.followUp(\"leak-check-b\");\n   244\t    agent.deinit();\n   245\t}\n   246\t\n   247\tconst TextDeltaCounter = struct {\n   248\t    text_deltas: std.atomic.Value(u32) = .init(0),\n   249\t    turn_ends: std.atomic.Value(u32) = .init(0),\n   250\t\n   251\t    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {\n   252\t        const self: *TextDeltaCounter = @ptrCast(@alignCast(ud.?));\n   253\t        switch (ev) {\n   254\t            .message_update => |u| switch (u) {\n   255\t                .text => _ = self.text_deltas.fetchAdd(1, .monotonic),\n   256\t                else => {},\n   257\t            },\n   258\t            .turn_end => _ = self.turn_ends.fetchAdd(1, .monotonic),\n   259\t            else => {},\n   260\t        }\n   261\t    }\n   262\t};\n   263\t\n   264\ttest \"Agent: does NOT deadlock when a turn produces > 128 events (v1.21.0 regression)\" {\n   265\t    // Before v1.21.0, `Agent.workerFn` ran `agentLoop` and the\n   266\t    // event-drain in the same thread sequentially — agentLoop pushed\n   267\t    // events into a 128-cap channel and only THEN did the worker\n   268\t    // drain. A turn that emitted > 128 events would block on\n   269\t    // `out.push` waiting for a consumer that wouldn't run until\n   270\t    // agentLoop returned, which it couldn't because push was\n   271\t    // blocked. Symptom: tool-using turns with thinking deltas (e.g.\n   272\t    // gemma4 via Ollama, observed in franky-do v0.2.x) produced no\n   273\t    // Slack reply for the second turn — the worker thread was hung\n   274\t    // mid-push. v1.21.0 moved agentLoop to a dedicated thread + bumped\n   275\t    // capacity to 4096; this test forces > 128 deltas to prove the\n   276\t    // fix holds.\n   277\t    var threaded = franky.test_helpers.threadedIo();\n   278\t    defer threaded.deinit();\n   279\t    const io = threaded.io();\n   280\t    const gpa = testing.allocator;\n   281\t\n   282\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   283\t    defer faux.deinit();\n   284\t    // chunk_size=1 + a 200-char text → 200 text_delta events on top\n   285\t    // of turn_start / message_start / message_end / turn_end. Old\n   286\t    // 128-cap channel would deadlock; 4096-cap handles this with\n   287\t    // ample headroom.\n   288\t    const long_text = \"x\" ** 200;\n   289\t    try faux.push(.{ .events = &.{\n   290\t        .{ .text = .{ .text = long_text, .chunk_size = 1 } },\n   291\t    } });\n   292\t\n   293\t    var reg = ai.registry.Registry.init(gpa);\n   294\t    defer reg.deinit();\n   295\t    try reg.register(.{\n   296\t        .api = \"faux\",\n   297\t        .provider = \"faux\",\n   298\t        .stream_fn = fauxShim,\n   299\t        .userdata = @ptrCast(&faux),\n   300\t    });\n   301\t\n   302\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   303\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   304\t        .registry = &reg,\n   305\t    });\n   306\t    defer agent.deinit();\n   307\t\n   308\t    var counter: TextDeltaCounter = .{};\n   309\t    _ = try agent.subscribe(TextDeltaCounter.onEvent, @ptrCast(&counter));\n   310\t\n   311\t    try agent.prompt(\"emit a lot\");\n   312\t    agent.waitForIdle(); // would hang forever pre-v1.21.0\n   313\t\n   314\t    try testing.expectEqual(@as(u32, 200), counter.text_deltas.load(.monotonic));\n   315\t    try testing.expectEqual(@as(u32, 1), counter.turn_ends.load(.monotonic));\n   316\t}\n   317\t\n   318\t// v1.22.0 — `Agent.Config.tool_gate` regression. franky-do (and any\n   319\t// future SDK consumer) wires `coding/permissions.SessionGates`\n   320\t// callbacks here to gate tool calls without forking the Agent class.\n   321\t\n   322\tconst ToolGateSpy = struct {\n   323\t    /// Records each `before_tool_call` invocation. Test asserts the\n   324\t    /// userdata round-trips and the call_id/args show up correctly.\n   325\t    invocations: std.atomic.Value(u32) = .init(0),\n   326\t    /// When true, every call returns `{ block: true, ... }` so the\n   327\t    /// tool's executor never runs and the loop emits a synthetic\n   328\t    /// error result instead. Test then checks the emitted\n   329\t    /// `tool_execution_end` event for `is_error = true`.\n   330\t    block_all: bool = false,\n   331\t    /// Last seen by the spy — verified to round-trip from the\n   332\t    /// model's tool_call args.\n   333\t    last_args: std.ArrayList(u8) = .empty,\n   334\t    last_args_mutex: std.Io.Mutex = .init,\n   335\t\n   336\t    fn beforeToolCall(\n   337\t        ud: ?*anyopaque,\n   338\t        tool: *const at.AgentTool,\n   339\t        call_id: []const u8,\n   340\t        args_json: []const u8,\n   341\t    ) franky.agent.loop.HookDecision {\n   342\t        _ = tool;\n   343\t        _ = call_id;\n   344\t        const self: *ToolGateSpy = @ptrCast(@alignCast(ud.?));\n   345\t        _ = self.invocations.fetchAdd(1, .monotonic);\n   346\t        self.last_args_mutex.lockUncancelable(undefined);\n   347\t        defer self.last_args_mutex.unlock(undefined);\n   348\t        self.last_args.clearRetainingCapacity();\n   349\t        self.last_args.appendSlice(testing.allocator, args_json) catch {};\n   350\t        if (self.block_all) {\n   351\t            return .{ .block = true, .reason_text = \"blocked by spy\" };\n   352\t        }\n   353\t        return .{ .block = false };\n   354\t    }\n   355\t};\n   356\t\n   357\tconst ToolEventCounter = struct {\n   358\t    tool_starts: std.atomic.Value(u32) = .init(0),\n   359\t    tool_ends: std.atomic.Value(u32) = .init(0),\n   360\t    last_tool_is_error: std.atomic.Value(bool) = .init(false),\n   361\t\n   362\t    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {\n   363\t        const self: *ToolEventCounter = @ptrCast(@alignCast(ud.?));\n   364\t        switch (ev) {\n   365\t            .tool_execution_start => _ = self.tool_starts.fetchAdd(1, .monotonic),\n   366\t            .tool_execution_end => |e| {\n   367\t                _ = self.tool_ends.fetchAdd(1, .monotonic);\n   368\t                self.last_tool_is_error.store(e.result.is_error, .release);\n   369\t            },\n   370\t            else => {},\n   371\t        }\n   372\t    }\n   373\t};\n   374\t\n   375\tfn unreachableTool(\n   376\t    self: *const at.AgentTool,\n   377\t    allocator: std.mem.Allocator,\n   378\t    io: std.Io,\n   379\t    call_id: []const u8,\n   380\t    args_json: []const u8,\n   381\t    cancel: *ai.stream.Cancel,\n   382\t    on_update: at.OnUpdate,\n   383\t) anyerror!at.ToolResult {\n   384\t    _ = self;\n   385\t    _ = io;\n   386\t    _ = call_id;\n   387\t    _ = args_json;\n   388\t    _ = cancel;\n   389\t    _ = on_update;\n   390\t    // If the gate's `block: true` works, this never executes. The\n   391\t    // test asserts the gate fired AND the executor body never ran\n   392\t    // (via the result's `is_error = true`).\n   393\t    const blocks = try allocator.alloc(ai.types.ContentBlock, 1);\n   394\t    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, \"tool ran (should not happen if gate blocks)\") } };\n   395\t    return .{ .content = blocks };\n   396\t}\n   397\t\n   398\ttest \"Agent.tool_gate.before_tool_call fires with its own userdata; block: true vetoes the call\" {\n   399\t    var threaded = franky.test_helpers.threadedIo();\n   400\t    defer threaded.deinit();\n   401\t    const io = threaded.io();\n   402\t    const gpa = testing.allocator;\n   403\t\n   404\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   405\t    defer faux.deinit();\n   406\t    // One step: model emits a tool_use(noop, {\"x\":1}) and stops.\n   407\t    try faux.push(.{ .events = &.{\n   408\t        .{ .tool_call = .{\n   409\t            .id = \"call-1\",\n   410\t            .name = \"noop\",\n   411\t            .args_json = \"{\\\"x\\\":1}\",\n   412\t            .args_chunk_size = 8,\n   413\t        } },\n   414\t        .{ .done = .{ .stop_reason = .tool_use } },\n   415\t    } });\n   416\t\n   417\t    var reg = ai.registry.Registry.init(gpa);\n   418\t    defer reg.deinit();\n   419\t    try reg.register(.{\n   420\t        .api = \"faux\",\n   421\t        .provider = \"faux\",\n   422\t        .stream_fn = fauxShim,\n   423\t        .userdata = @ptrCast(&faux),\n   424\t    });\n   425\t\n   426\t    const noop_tool: at.AgentTool = .{\n   427\t        .name = \"noop\",\n   428\t        .description = \"no-op tool — should never actually run when the gate blocks.\",\n   429\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\",\\\"properties\\\":{\\\"x\\\":{\\\"type\\\":\\\"integer\\\"}}}\",\n   430\t        .execution_mode = .sequential,\n   431\t        .execute = unreachableTool,\n   432\t    };\n   433\t\n   434\t    var spy: ToolGateSpy = .{ .block_all = true };\n   435\t    defer spy.last_args.deinit(gpa);\n   436\t\n   437\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   438\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   439\t        .registry = &reg,\n   440\t        .tools = &.{noop_tool},\n   441\t        .tool_gate = .{\n   442\t            .userdata = @ptrCast(&spy),\n   443\t            .before_tool_call = ToolGateSpy.beforeToolCall,\n   444\t        },\n   445\t    });\n   446\t    defer agent.deinit();\n   447\t\n   448\t    var counter: ToolEventCounter = .{};\n   449\t    _ = try agent.subscribe(ToolEventCounter.onEvent, @ptrCast(&counter));\n   450\t\n   451\t    try agent.prompt(\"call noop\");\n   452\t    agent.waitForIdle();\n   453\t\n   454\t    // Gate fired exactly once.\n   455\t    try testing.expectEqual(@as(u32, 1), spy.invocations.load(.monotonic));\n   456\t    // Args round-tripped: spy saw the model's tool_call payload.\n   457\t    {\n   458\t        spy.last_args_mutex.lockUncancelable(undefined);\n   459\t        defer spy.last_args_mutex.unlock(undefined);\n   460\t        try testing.expectEqualStrings(\"{\\\"x\\\":1}\", spy.last_args.items);\n   461\t    }\n   462\t    // Loop emitted exactly one tool_execution_end (the synthetic\n   463\t    // error from the veto), and it's marked as an error so the\n   464\t    // model sees the block reason on retry.\n   465\t    try testing.expectEqual(@as(u32, 1), counter.tool_starts.load(.monotonic));\n   466\t    try testing.expectEqual(@as(u32, 1), counter.tool_ends.load(.monotonic));\n   467\t    try testing.expect(counter.last_tool_is_error.load(.acquire));\n   468\t}\n   469\t\n   470\ttest \"Agent.tool_gate is independent of between_turns userdata\" {\n   471\t    // Sanity-check the v1.22.0 fix: per-hook userdata fields on\n   472\t    // `loop.Config` mean `betweenTurnsHook` keeps using the Agent\n   473\t    // self pointer (for queue-drain access) while\n   474\t    // `before_tool_call` uses the gate's userdata. A pre-fix\n   475\t    // implementation that overwrote `hook_userdata` would have\n   476\t    // broken either the queue logic or the tool gate.\n   477\t    var threaded = franky.test_helpers.threadedIo();\n   478\t    defer threaded.deinit();\n   479\t    const io = threaded.io();\n   480\t    const gpa = testing.allocator;\n   481\t\n   482\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   483\t    defer faux.deinit();\n   484\t    try faux.push(.{ .events = &.{\n   485\t        .{ .text = .{ .text = \"ok\", .chunk_size = 2 } },\n   486\t    } });\n   487\t\n   488\t    var reg = ai.registry.Registry.init(gpa);\n   489\t    defer reg.deinit();\n   490\t    try reg.register(.{\n   491\t        .api = \"faux\",\n   492\t        .provider = \"faux\",\n   493\t        .stream_fn = fauxShim,\n   494\t        .userdata = @ptrCast(&faux),\n   495\t    });\n   496\t\n   497\t    var spy: ToolGateSpy = .{};\n   498\t    defer spy.last_args.deinit(gpa);\n   499\t\n   500\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   501\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   502\t        .registry = &reg,\n   503\t        .tool_gate = .{\n   504\t            .userdata = @ptrCast(&spy),\n   505\t            .before_tool_call = ToolGateSpy.beforeToolCall,\n   506\t        },\n   507\t    });\n   508\t    defer agent.deinit();\n   509\t\n   510\t    // followUp queue exercises the between_turns hook → if the\n   511\t    // userdata was overwritten by tool_gate, this would crash or\n   512\t    // silently drop the followUp. We assert the queue still drains\n   513\t    // (a second turn fires).\n   514\t    try agent.prompt(\"first\");\n   515\t    agent.waitForIdle();\n   516\t    try testing.expect(agent.transcript.messages.items.len >= 2);\n   517\t    // No tool calls in this conversation → spy should not have fired.\n   518\t    try testing.expectEqual(@as(u32, 0), spy.invocations.load(.monotonic));\n   519\t}\n   520\t\n   521\t// ─── Agent.Config.max_turns + max_turns_hook ──────────────────────\n   522\t\n   523\t/// Simple echo tool — returns the args back as text. Used by max_turns\n   524\t/// tests to keep the loop going (every turn ends with a tool_call).\n   525\tfn echoForMaxTurns(\n   526\t    tool: *const at.AgentTool,\n   527\t    allocator: std.mem.Allocator,\n   528\t    io: std.Io,\n   529\t    call_id: []const u8,\n   530\t    args_json: []const u8,\n   531\t    cancel: *ai.stream.Cancel,\n   532\t    on_update: at.OnUpdate,\n   533\t) anyerror!at.ToolResult {\n   534\t    _ = tool;\n   535\t    _ = io;\n   536\t    _ = call_id;\n   537\t    _ = cancel;\n   538\t    _ = on_update;\n   539\t    const text = try std.fmt.allocPrint(allocator, \"got: {s}\", .{args_json});\n   540\t    const arr = try allocator.alloc(ai.types.ContentBlock, 1);\n   541\t    arr[0] = .{ .text = .{ .text = text } };\n   542\t    return .{ .content = arr };\n   543\t}\n   544\t\n   545\tconst MaxTurnsCounter = struct {\n   546\t    turn_starts: std.atomic.Value(u32) = .init(0),\n   547\t    max_turns_errors: std.atomic.Value(u32) = .init(0),\n   548\t\n   549\t    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {\n   550\t        const self: *MaxTurnsCounter = @ptrCast(@alignCast(ud.?));\n   551\t        switch (ev) {\n   552\t            .turn_start => _ = self.turn_starts.fetchAdd(1, .monotonic),\n   553\t            .agent_error => |d| {\n   554\t                if (d.code == .max_turns_exceeded) {\n   555\t                    _ = self.max_turns_errors.fetchAdd(1, .monotonic);\n   556\t                }\n   557\t            },\n   558\t            else => {},\n   559\t        }\n   560\t    }\n   561\t};\n   562\t\n   563\tconst ExtendOnceUserdata = struct {\n   564\t    calls: std.atomic.Value(u32) = .init(0),\n   565\t\n   566\t    fn cb(userdata: ?*anyopaque, used: u32, cap: u32) franky.agent.loop.MaxTurnsDecision {\n   567\t        _ = used;\n   568\t        _ = cap;\n   569\t        const self: *ExtendOnceUserdata = @ptrCast(@alignCast(userdata.?));\n   570\t        const n = self.calls.fetchAdd(1, .monotonic);\n   571\t        if (n == 0) return .{ .extend = 2 };\n   572\t        return .stop;\n   573\t    }\n   574\t};\n   575\t\n   576\ttest \"Agent.Config.max_turns is honored — emits max_turns_exceeded at the cap\" {\n   577\t    var threaded = franky.test_helpers.threadedIo();\n   578\t    defer threaded.deinit();\n   579\t    const io = threaded.io();\n   580\t    const gpa = testing.allocator;\n   581\t\n   582\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   583\t    defer faux.deinit();\n   584\t    // Push 5 turns, each ending in a tool_call so the loop wants to\n   585\t    // keep going; cap=2 should stop it after 2 turns.\n   586\t    var i: u32 = 0;\n   587\t    while (i < 5) : (i += 1) {\n   588\t        try faux.push(.{ .events = &.{\n   589\t            .{ .tool_call = .{ .id = \"c\", .name = \"echo\", .args_json = \"{}\" } },\n   590\t            .{ .done = .{ .stop_reason = .tool_use } },\n   591\t        } });\n   592\t    }\n   593\t\n   594\t    var reg = ai.registry.Registry.init(gpa);\n   595\t    defer reg.deinit();\n   596\t    try reg.register(.{\n   597\t        .api = \"faux\",\n   598\t        .provider = \"faux\",\n   599\t        .stream_fn = fauxShim,\n   600\t        .userdata = @ptrCast(&faux),\n   601\t    });\n   602\t\n   603\t    const echo_tool = at.AgentTool{\n   604\t        .name = \"echo\",\n   605\t        .description = \"echo\",\n   606\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   607\t        .execute = echoForMaxTurns,\n   608\t    };\n   609\t\n   610\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   611\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   612\t        .registry = &reg,\n   613\t        .tools = &[_]at.AgentTool{echo_tool},\n   614\t        .max_turns = 2,\n   615\t    });\n   616\t    defer agent.deinit();\n   617\t\n   618\t    var counter: MaxTurnsCounter = .{};\n   619\t    _ = try agent.subscribe(MaxTurnsCounter.onEvent, @ptrCast(&counter));\n   620\t\n   621\t    try agent.prompt(\"go\");\n   622\t    agent.waitForIdle();\n   623\t\n   624\t    try testing.expectEqual(@as(u32, 2), counter.turn_starts.load(.monotonic));\n   625\t    try testing.expectEqual(@as(u32, 1), counter.max_turns_errors.load(.monotonic));\n   626\t}\n   627\t\n   628\ttest \"Agent.Config.max_turns_hook .extend() is additive (credits accumulate)\" {\n   629\t    var threaded = franky.test_helpers.threadedIo();\n   630\t    defer threaded.deinit();\n   631\t    const io = threaded.io();\n   632\t    const gpa = testing.allocator;\n   633\t\n   634\t    var faux = ai.providers.faux.FauxProvider.init(gpa);\n   635\t    defer faux.deinit();\n   636\t    var i: u32 = 0;\n   637\t    while (i < 10) : (i += 1) {\n   638\t        try faux.push(.{ .events = &.{\n   639\t            .{ .tool_call = .{ .id = \"c\", .name = \"echo\", .args_json = \"{}\" } },\n   640\t            .{ .done = .{ .stop_reason = .tool_use } },\n   641\t        } });\n   642\t    }\n   643\t\n   644\t    var reg = ai.registry.Registry.init(gpa);\n   645\t    defer reg.deinit();\n   646\t    try reg.register(.{\n   647\t        .api = \"faux\",\n   648\t        .provider = \"faux\",\n   649\t        .stream_fn = fauxShim,\n   650\t        .userdata = @ptrCast(&faux),\n   651\t    });\n   652\t\n   653\t    const echo_tool = at.AgentTool{\n   654\t        .name = \"echo\",\n   655\t        .description = \"echo\",\n   656\t        .parameters_json = \"{\\\"type\\\":\\\"object\\\"}\",\n   657\t        .execute = echoForMaxTurns,\n   658\t    };\n   659\t\n   660\t    var hook_state: ExtendOnceUserdata = .{};\n   661\t\n   662\t    var agent = try agent_mod.Agent.init(gpa, io, .{\n   663\t        .model = .{ .id = \"faux-1\", .provider = \"faux\", .api = \"faux\" },\n   664\t        .registry = &reg,\n   665\t        .tools = &[_]at.AgentTool{echo_tool},\n   666\t        .max_turns = 1,\n   667\t        .max_turns_hook = .{\n   668\t            .userdata = @ptrCast(&hook_state),\n   669\t            .on_max_turns = ExtendOnceUserdata.cb,\n   670\t        },\n   671\t    });\n   672\t    defer agent.deinit();\n   673\t\n   674\t    var counter: MaxTurnsCounter = .{};\n   675\t    _ = try agent.subscribe(MaxTurnsCounter.onEvent, @ptrCast(&counter));\n   676\t\n   677\t    try agent.prompt(\"go\");\n   678\t    agent.waitForIdle();\n   679\t\n   680\t    // 1 (initial cap) + 2 (extension) = 3 turns. Hook called twice.\n   681\t    try testing.expectEqual(@as(u32, 3), counter.turn_starts.load(.monotonic));\n   682\t    try testing.expectEqual(@as(u32, 2), hook_state.calls.load(.monotonic));\n   683\t    try testing.expectEqual(@as(u32, 1), counter.max_turns_errors.load(.monotonic));\n   684\t}\n"}]},
    {"role":"assistant","timestamp":1777789204257,"content":[{"type":"toolCall","id":"call_k2xct6de","name":"read","arguments":{"path":"test/gitignore_test.zig"}}],"stopReason":"toolUse","provider":"gateway","model":"gemma4:latest","api":"openai-compatible-gateway","diagnostics":{"finishReasonRaw":"tool_calls","partsSeen":2,"candidatesTokens":19,"toolCallEvents":1}},
    {"role":"toolResult","timestamp":1777789204259,"toolCallId":"call_k2xct6de","content":[{"type":"text","text":"     1\t//! Integration test for v0.2.1 — drives the full `ls` and `find` tool\n     2\t//! entry points (through `execute`) against a multi-level tmpdir with\n     3\t//! nested `.gitignore` files. Complements the unit tests in\n     4\t//! `src/coding/gitignore.zig` by covering the code path the agent\n     5\t//! actually uses at runtime (JSON args → execute → ToolResult).\n     6\t\n     7\tconst std = @import(\"std\");\n     8\tconst franky = @import(\"franky\");\n     9\t\n    10\tconst ai = franky.ai;\n    11\tconst at = franky.agent.types;\n    12\tconst ls_tool = franky.coding.tools.ls;\n    13\tconst find_tool = franky.coding.tools.find;\n    14\t\n    15\t/// Build a small canonical tree:\n    16\t///   <base>/\n    17\t///     .gitignore            → \"*.log\\nbuild/\\ntmp/\\n\"\n    18\t///     main.zig\n    19\t///     notes.md\n    20\t///     debug.log             (ignored)\n    21\t///     build/\n    22\t///       out.o               (ignored via `build/` dir rule)\n    23\t///     tmp/\n    24\t///       scratch             (ignored via `tmp/` dir rule)\n    25\t///     pkg/\n    26\t///       .gitignore          → \"!keep.log\\nmock_*.zig\\n\"\n    27\t///       src.zig\n    28\t///       keep.log            (re-included)\n    29\t///       drop.log            (ignored by root *.log)\n    30\t///       mock_user.zig       (ignored by pkg-level rule)\n    31\t///       sub/\n    32\t///         deep.log          (ignored)\n    33\tfn buildTree(io: std.Io, base: []const u8) !void {\n    34\t    const cwd = std.Io.Dir.cwd();\n    35\t    const gpa = std.testing.allocator;\n    36\t    _ = cwd.deleteTree(io, base) catch {};\n    37\t    try cwd.createDirPath(io, base);\n    38\t    try mkdir(io, base, \"build\");\n    39\t    try mkdir(io, base, \"tmp\");\n    40\t    try mkdir(io, base, \"pkg/sub\");\n    41\t    _ = gpa;\n    42\t\n    43\t    try writeFile(io, base, \".gitignore\", \"*.log\\nbuild/\\ntmp/\\n\");\n    44\t    try writeFile(io, base, \"main.zig\", \"// main\\n\");\n    45\t    try writeFile(io, base, \"notes.md\", \"note\\n\");\n    46\t    try writeFile(io, base, \"debug.log\", \"debug\\n\");\n    47\t    try writeFile(io, base, \"build/out.o\", \"obj\\n\");\n    48\t    try writeFile(io, base, \"tmp/scratch\", \"x\\n\");\n    49\t    try writeFile(io, base, \"pkg/.gitignore\", \"!keep.log\\nmock_*.zig\\n\");\n    50\t    try writeFile(io, base, \"pkg/src.zig\", \"pkg\\n\");\n    51\t    try writeFile(io, base, \"pkg/keep.log\", \"keep\\n\");\n    52\t    try writeFile(io, base, \"pkg/drop.log\", \"drop\\n\");\n    53\t    try writeFile(io, base, \"pkg/mock_user.zig\", \"mock\\n\");\n    54\t    try writeFile(io, base, \"pkg/sub/deep.log\", \"deep\\n\");\n    55\t}\n    56\t\n    57\tfn mkdir(io: std.Io, base: []const u8, rel: []const u8) !void {\n    58\t    const gpa = std.testing.allocator;\n    59\t    const path = try std.fs.path.join(gpa, &.{ base, rel });\n    60\t    defer gpa.free(path);\n    61\t    try std.Io.Dir.cwd().createDirPath(io, path);\n    62\t}\n    63\t\n    64\tfn writeFile(io: std.Io, base: []const u8, rel: []const u8, contents: []const u8) !void {\n    65\t    const gpa = std.testing.allocator;\n    66\t    const path = try std.fs.path.join(gpa, &.{ base, rel });\n    67\t    defer gpa.free(path);\n    68\t    var f = try std.Io.Dir.cwd().createFile(io, path, .{});\n    69\t    defer f.close(io);\n    70\t    try f.writeStreamingAll(io, contents);\n    71\t}\n    72\t\n    73\tfn runTool(\n    74\t    comptime tool_module: type,\n    75\t    io: std.Io,\n    76\t    args_json: []const u8,\n    77\t) !at.ToolResult {\n    78\t    const gpa = std.testing.allocator;\n    79\t    var cancel: ai.stream.Cancel = .{};\n    80\t    const t = tool_module.tool();\n    81\t    return try t.execute(&t, gpa, io, \"call-1\", args_json, &cancel, .{});\n    82\t}\n    83\t\n    84\ttest \"integration: ls respects nested .gitignore\" {\n    85\t    var threaded = franky.test_helpers.threadedIo();\n    86\t    defer threaded.deinit();\n    87\t    const io = threaded.io();\n    88\t    const base = \"/tmp/franky_int_gi_ls\";\n    89\t    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};\n    90\t    try buildTree(io, base);\n    91\t\n    92\t    const args = try std.fmt.allocPrint(std.testing.allocator,\n    93\t        \\\\{{\"path\":\"{s}\",\"recursive\":true,\"maxDepth\":10,\"respectGitignore\":true}}\n    94\t    , .{base});\n    95\t    defer std.testing.allocator.free(args);\n    96\t\n    97\t    var res = try runTool(ls_tool, io, args);\n    98\t    defer res.deinit(std.testing.allocator);\n    99\t    const text = res.content[0].text.text;\n   100\t\n   101\t    // Included: unignored code files and the .gitignore files themselves.\n   102\t    try std.testing.expect(std.mem.indexOf(u8, text, \"main.zig\") != null);\n   103\t    try std.testing.expect(std.mem.indexOf(u8, text, \"notes.md\") != null);\n   104\t    try std.testing.expect(std.mem.indexOf(u8, text, \"pkg/src.zig\") != null);\n   105\t    // Re-included by pkg-level negation.\n   106\t    try std.testing.expect(std.mem.indexOf(u8, text, \"keep.log\") != null);\n   107\t\n   108\t    // Excluded: *.log at root, build/ contents, tmp/ contents,\n   109\t    // pkg-level mock_*.zig, pkg/drop.log, descendant .log files under\n   110\t    // pkg/sub (still covered by root *.log).\n   111\t    try std.testing.expect(std.mem.indexOf(u8, text, \"debug.log\") == null);\n   112\t    try std.testing.expect(std.mem.indexOf(u8, text, \"out.o\") == null);\n   113\t    try std.testing.expect(std.mem.indexOf(u8, text, \"scratch\") == null);\n   114\t    try std.testing.expect(std.mem.indexOf(u8, text, \"mock_user.zig\") == null);\n   115\t    try std.testing.expect(std.mem.indexOf(u8, text, \"drop.log\") == null);\n   116\t    try std.testing.expect(std.mem.indexOf(u8, text, \"deep.log\") == null);\n   117\t}\n   118\t\n   119\ttest \"integration: find respects nested .gitignore\" {\n   120\t    var threaded = franky.test_helpers.threadedIo();\n   121\t    defer threaded.deinit();\n   122\t    const io = threaded.io();\n   123\t    const base = \"/tmp/franky_int_gi_find\";\n   124\t    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};\n   125\t    try buildTree(io, base);\n   126\t\n   127\t    const args = try std.fmt.allocPrint(std.testing.allocator,\n   128\t        \\\\{{\"pattern\":\"**/*\",\"cwd\":\"{s}\",\"respectGitignore\":true,\"limit\":500}}\n   129\t    , .{base});\n   130\t    defer std.testing.allocator.free(args);\n   131\t\n   132\t    var res = try runTool(find_tool, io, args);\n   133\t    defer res.deinit(std.testing.allocator);\n   134\t    const text = res.content[0].text.text;\n   135\t\n   136\t    try std.testing.expect(std.mem.indexOf(u8, text, \"main.zig\") != null);\n   137\t    try std.testing.expect(std.mem.indexOf(u8, text, \"pkg/src.zig\") != null);\n   138\t    try std.testing.expect(std.mem.indexOf(u8, text, \"pkg/keep.log\") != null);\n   139\t\n   140\t    try std.testing.expect(std.mem.indexOf(u8, text, \"debug.log\") == null);\n   141\t    try std.testing.expect(std.mem.indexOf(u8, text, \"out.o\") == null);\n   142\t    try std.testing.expect(std.mem.indexOf(u8, text, \"scratch\") == null);\n   143\t    try std.testing.expect(std.mem.indexOf(u8, text, \"mock_user.zig\") == null);\n   144\t    try std.testing.expect(std.mem.indexOf(u8, text, \"drop.log\") == null);\n   145\t    try std.testing.expect(std.mem.indexOf(u8, text, \"deep.log\") == null);\n   146\t}\n   147\t\n   148\ttest \"integration: respectGitignore=false restores full tree\" {\n   149\t    var threaded = franky.test_helpers.threadedIo();\n   150\t    defer threaded.deinit();\n   151\t    const io = threaded.io();\n   152\t    const base = \"/tmp/franky_int_gi_off\";\n   153\t    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};\n   154\t    try buildTree(io, base);\n   155\t\n   156\t    const args = try std.fmt.allocPrint(std.testing.allocator,\n   157\t        \\\\{{\"pattern\":\"**/*\",\"cwd\":\"{s}\",\"respectGitignore\":false,\"limit\":500}}\n   158\t    , .{base});\n   159\t    defer std.testing.allocator.free(args);\n   160\t\n   161\t    var res = try runTool(find_tool, io, args);\n   162\t    defer res.deinit(std.testing.allocator);\n   163\t    const text = res.content[0].text.text;\n   164\t\n   165\t    try std.testing.expect(std.mem.indexOf(u8, text, \"debug.log\") != null);\n   166\t    try std.testing.expect(std.mem.indexOf(u8, text, \"out.o\") != null);\n   167\t    try std.testing.expect(std.mem.indexOf(u8, text, \"mock_user.zig\") != null);\n   168\t    try std.testing.expect(std.mem.indexOf(u8, text, \"deep.log\") != null);\n   169\t}\n"}]},
    {"role":"assistant","timestamp":1777789238163,"content":[{"type":"thinking","thinking":"call:read{path:<|\"|>test/parallel_tools_test.zig<|\"|>}<tool_call|>"}],"stopReason":"stop","provider":"gateway","model":"gemma4:latest","api":"openai-compatible-gateway","diagnostics":{"finishReasonRaw":"stop","partsSeen":20,"candidatesTokens":21,"thinkingEvents":19}}
  ]
}
```

# Deepseek DSML calls

Analzye this tool call it was incorrectly parsed.
```
<｜DSML｜tool_calls>
<｜DSML｜invoke name="grep">
<｜DSML｜parameter name="filesGlob" string="true">**/*.zig</｜DSML｜parameter>
<｜DSML｜parameter name="maxMatches" string="false">20</｜DSML｜parameter>
<｜DSML｜parameter name="path" string="true">/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>
<｜DSML｜parameter name="pattern" string="true">server.*deinit|server\.deinit|server.*close"</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>
tool: grep error
[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>
```