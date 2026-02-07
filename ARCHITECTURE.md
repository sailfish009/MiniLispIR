# MiniLispIR v0.4 — Self-Improving Compiler Architecture

## Overview

MiniLispIR is a self-improving compiler written entirely in LLVM IR. It reads its own (or any) `.ll` source file, extracts function blocks, runs a cyclic **ir-gen → ir-eval → scoring → feedback** loop on each function, and writes an improved version to disk when convergence is detected. No GPU is required.

## Self-Improvement Flow

```
                         ┌─────────────────────┐
                         │   Input: source.ll   │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │  Extract Functions   │
                         │  (scan for "define") │
                         └──────────┬──────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
              ┌──────────┐   ┌──────────┐   ┌──────────┐
              │ func [0] │   │ func [1] │   │ func [N] │
              └─────┬────┘   └─────┬────┘   └─────┬────┘
                    │               │               │
                    ▼               ▼               ▼
         ┌─────────────────────────────────────────────────┐
         │            Per-Function Cycle Engine             │
         │                                                 │
         │  ┌─────────┐  ┌────────┐  ┌───────┐  ┌──────┐  │
         │  │ IR-Gen  ├─>│IR-Eval ├─>│ Score ├─>│ Feed ├──│──┐
         │  └────▲────┘  └────────┘  └───────┘  │ back │  │  │
         │       │                               └──┬───┘  │  │
         │       │       ┌──────────┐               │      │  │
         │       └───────┤ Registry │<──────────────┘      │  │
         │               └──────────┘                      │  │
         │                                                 │  │
         │  Converge when plateau_count >= patience (5)    │  │
         └─────────────────────────────────────────────────┘  │
                    │                                          │
                    ▼                                          │
         ┌─────────────────────┐                              │
         │ Patch improved funcs│<─────────────────────────────┘
         │ into source text    │
         └──────────┬──────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │ Output: improved.ll │
         └─────────────────────┘
```

## Pipeline Stages

### 1. Source Loading (`@read_file`)

Reads the entire `.ll` file into memory using `fopen`/`fread`/`ftell`. Accepts input and output paths via command-line arguments:

```bash
./minilisp input.ll output_improved.ll
# or use defaults:
./minilisp   # reads minilisp_ir.ll, writes minilisp_ir_improved.ll
```

### 2. Function Extraction (`@extract_functions`)

Scans the source text for lines starting with `"define "`, then tracks brace depth (`{`/`}`) to find the complete function body. For each function, it creates a `%func_seg_ty` record:

```llvm
%func_seg_ty = type {
  i8*,  ; name            - function name (e.g., "vector_push")
  i64,  ; start_offset    - byte offset in source
  i64,  ; end_offset      - byte offset of closing }
  i8*,  ; text            - original function text
  i32,  ; score           - best score achieved
  i8*   ; improved_text   - improved version (null if no improvement)
}
```

### 3. Per-Function Improvement Cycle

For each extracted function, up to **10 cycles** of ir-gen/ir-eval are run:

#### IR-Gen (`@ir_gen`)
- **Seed selection**: 8 predefined Lisp programs covering arithmetic, binding, and nesting.
- **Mutation**: 50% chance to mutate a successful block from the registry.
- 5 mutation strategies: `grow-extend`, `arith-variant`, `chain-calls`, `nest-deeper`, `decrement`.

#### IR-Eval (`@ir_eval`)
Full pipeline: `source → lexer → parser → AST → eval_node → result`

Returns `%eval_result_ty { i8* value, i32 is_valid, i32 numeric_result }`.

Supported operations: `let`, `display`, `+`, `-`, `*`, `if`, `compile`.

#### Scoring (`@ir_score`)

| Criterion | Points |
|-----------|--------|
| Valid execution | +10 |
| Non-zero result | +5 |
| \|result\| > 10 | +3 |
| Even result | +2 |
| Generation bonus | +generation |

#### Convergence Detection

- **Improvement threshold**: score delta must be > 2 to count as improvement.
- **Plateau counter**: increments each cycle without improvement.
- **Patience**: after 5 consecutive non-improving cycles, the function is considered converged.
- On improvement, the plateau counter resets and the block enters the registry.

### 4. Source Patching (`@patch_source`)

Replaces a byte range `[start, end)` in the source text with new text. Uses `memcpy` to construct: `prefix + new_text + suffix`. Offset arithmetic accounts for length differences between old and new text.

### 5. Output Writing (`@write_file`)

Writes the final patched source to disk via `fopen`/`fwrite`. Reports bytes written.

## Data Structures

### IR Block (Registry Entry)

```llvm
%ir_block_ty = type { i8* name, i8* source, i8* ir_text, i32 score, i32 generation, i32 status }
```

### Registry

A `%vector_ty` of successful `%ir_block_ty` pointers. Shared across all function improvement cycles — blocks discovered while improving one function can be reused as mutation material for subsequent functions.

### Environment

Linked list `%env_ty` for `let` variable bindings during evaluation.

## Example Session

```
===== MiniLispIR v0.4 Self-Improving Compiler =====

[load]   source: minilisp_ir.ll (45230 bytes)
[extract] found 36 function blocks
[target] function: vector_new

--- Cycle 0 / 10 (gen 0) ----------------
[ir-gen]   candidate: (let a 3 (let b 7 (+ a b)))
[ir-eval]  result:    10
[score]    value:     15
[IMPROVED] vector_new: 0 -> 15 (+15)

--- Cycle 1 / 10 (gen 1) ----------------
[ir-gen]   candidate: (+ (let a 3 (let b 7 (+ a b))) 42)
[ir-eval]  result:    52
[score]    value:     21
[IMPROVED] vector_new: 15 -> 21 (+6)

--- Cycle 2 / 10 (gen 2) ----------------
[ir-gen]   candidate: (let x 6 (* x 7))
[ir-eval]  result:    42
[score]    value:     22
[skip]     no improvement

...

[CONVERGE] plateau for 5 cycles, saving...
[target] function: vector_push
...

[save]   output: minilisp_ir_improved.ll (45892 bytes)

===== Summary: 12 functions improved, delta=187 =====
```

## Building and Running

```bash
# Compile
clang minilisp_ir_v04.ll -o minilisp -lm

# Run with defaults (reads minilisp_ir.ll, writes minilisp_ir_improved.ll)
./minilisp

# Run with explicit paths
./minilisp my_compiler.ll my_compiler_improved.ll

# Bootstrap: feed output back as input
./minilisp minilisp_ir_improved.ll minilisp_ir_v2.ll
```

## Self-Learning Mechanism

1. **Exploration** — Generate diverse programs from seeds and mutations.
2. **Evaluation** — Execute each candidate through the full lex/parse/eval pipeline.
3. **Selection** — Only candidates that exceed the current best score (by > 2) survive.
4. **Convergence** — Stop when no improvement is found for 5 consecutive attempts.
5. **Persistence** — Write improved source to disk for the next bootstrap iteration.

The cross-function registry creates a compounding effect: improvements found for early functions become mutation material for later ones, enabling progressively more complex programs to emerge.

## Why No GPU

All computation is symbolic at the IR level:

- **AST structures** evolve instead of neural network weights.
- **Score-based selection** replaces backpropagation.
- **Sequential execution** replaces batch/parallel processing.

This is genetic programming applied to compiler IR — programs evolve through mutation and selection pressure.

## Roadmap

- [ ] **`lambda` support** — Evolve function definitions and higher-order calls
- [ ] **Crossover** — Combine subtrees from two successful blocks
- [ ] **Full self-reference** — Feed codegen'd IR back through eval (quine-like loop)
- [ ] **Goal-directed generation** — Reverse search from target output values
- [ ] **Multi-pass bootstrap** — Automated repeated self-compilation with convergence tracking
- [ ] **GPU acceleration** — Parallel candidate evaluation (future)
