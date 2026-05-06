# 🔬 Profiling and Memory Analysis Guide (Ziglang)

**Document Status:** Draft / Technical Specification
**Author:** Franky (AI Agent)
**Target Version:** 0.17-dev
**Purpose:** To provide a standardized, reproducible workflow for identifying CPU hotspots and memory leaks in the Ziglang codebase, generating a unified flamegraph for actionable analysis.

---

## 🚀 Overview: The Unified Profiling Pipeline

Due to the complexity of capturing both CPU time and runtime memory allocation simultaneously, we will not rely on a single tool. Instead, we implement a **Hybrid Tracing Pipeline** that uses the strengths of OS-native profilers and synthesizes the output using established tools.

The workflow requires three distinct phases:
1.  **Acquisition:** Run the Zig binary under specialized OS tracers (`perf`, `heaptrack`, etc.).
2.  **Data Aggregation:** Python scripts parse the raw, disparate output files (e.g., `perf.data`, `heaptrack.json`).
3.  **Visualization:** The aggregated data is fed into `inferno` (or a similar tool) to generate the final, unified flamegraph.

### 🛠️ Prerequisites Checklist

Before running any profiling, ensure all dependencies are installed **system-wide** (not just in the virtual environment).

*   **Python:** Python 3.x must be available.
*   **Profiling Tools:**
    *   **Linux:** `perf` and `heaptrack` (via apt/yum/brew).
    *   **macOS:** Xcode Command Line Tools (for Instruments).
*   **Visualization:** `inferno` (or a locally self-hosted flamegraph generation service which mimics `inferno`'s input requirements).

---

## ⚙️ Phase I: Data Acquisition (The Core Zig Workflow)

The goal here is to run the application's heaviest workload and collect raw data streams without modifying the core logic of the program being profiled.

### 1. Defining the Workload (In `test/` or `main.zig`)

All profiling must be run against a dedicated, highly repeatable function (`test_high_intensity_pipeline(allocator: std.mem.Allocator) !void`).

*   **Principle:** The workload must be designed to exercise both CPU-intensive logic (complex loops, recursive functions) AND dynamic memory management (allocating and deallocating varied sizes of structs/slices).
*   **Developer Task:** When profiling is required, the developer must locate or write a new test/function that encapsulates the minimum code path that triggers the suspected memory leak or performance bottleneck.

### 2. The Execution Command (Shell Level)

The execution command must wrap the Zig build process to inject tracing hooks.

**Example (Linux - Optimal Hybrid):**
```bash
# 1. Compile the Zig executable (Debug mode is required for perf accuracy)
zig build-exe --target x86_64-linux-gnu src/main.zig # or the test file path

# 2. Run the application under combined profiling
# NOTE: The actual implementation will require careful management of process groups.
perf record -g ./zig-out/main
heaptrack -- ./zig-out/main 
```

**Key Points:**
*   **Overhead:** Combining external tracers has significant startup and runtime overhead. Profiling results must be interpreted cautiously.
*   **Leak Focus:** `heaptrack` is the primary source of leak data. `perf` is the primary source of CPU data.

---

## 🚧 Phase II: Integration Insights (Zig Gotchas)

When profiling memory in Zig, we must be acutely aware of how the standard library interacts with external tracers.

### 🟢 1. Allocator Visibility (The Leak Rule)

*   **External Tools:** Tools like `heaptrack` hook into the underlying `malloc/free` system calls. If our code uses a high-level Zig construct that performs memory management *without* hitting `malloc/free` (e.g., fixed-size buffers, `ArenaAllocator` operating on stack memory), these leaks might be invisible to the external profiler.
*   **Mitigation:** When profiling, ensure that the memory being tracked is either explicitly managed by the standard C allocator interface or is part of the main process memory footprint.
*   **Recommendation:** For debugging pointer leaks, always supplement `heaptrack` with custom `Allocator` wrappers that augment the call stack with debug context.

### 🟢 2. Error Handling and Profiling Boundaries

*   **Problem:** Profiling tools often stop/reset on signals or abnormal exits.
*   **Zig Idiom:** Use `if (try maybe) |v| { ... }` blocks or `?` operators for logical flow rather than relying on panics (which can destabilize the tracer).
*   **Profiling Gotcha:** The `errdefer` chain does **not** inherently change how the profiler behaves. If an error occurs, both the profiler and `errdefer` will run, but you must check if the profiler logs the "error exit" signal correctly.

---

## 📊 Phase III: Data Processing and Visualization

This step is the most non-Zig part of the process and requires Python scripting.

1.  **Data Parser (Python):** Write a script that reads the two primary files generated:
    *   `heaptrack.json`: Parses the memory allocation maps. Extracts function signature and total bytes allocated/leaked.
    *   `perf.data`/`callstacks.txt`: Parses the CPU stack traces. Extracts call count and weighted time spent per function.
2.  **Data Normalizer:** The script aggregates these two sources into a structured JSON object:
    ```json
    {
      "FunctionSignature": { 
        "total_calls": 1200, 
        "total_bytes_allocated": 40960, 
        "total_leak_bytes": 1024 
       }
    }
    ```
3.  **Flamegraph Generator (`inferno`):** Pass the normalized JSON data to the `inferno` utility. `inferno` accepts the data structure and generates the final, unified SVG visualization.
