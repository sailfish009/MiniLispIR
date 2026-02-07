# MiniLispIR v0.3 — Self-Learning Compiler Architecture

## Overview

MiniLispIR is a self-learning compiler written entirely in LLVM IR. It implements a cyclic **ir-gen → ir-eval → feedback** loop that generates new IR function blocks, evaluates them, scores the results, and feeds successful blocks back into the generation pipeline. No GPU is required — all learning happens through symbolic evolution of AST structures at the IR level.

## Cycle Engine

```
┌──────────────────────────────────────────────────────────────┐
│                        run_cycle(N)                          │
│                                                              │
│   ┌─────────┐    ┌──────────┐    ┌─────────┐    ┌────────┐  │
│   │ IR-Gen  │───>│ IR-Eval  │───>│ Scoring │───>│Feedback│  │
│   │         │    │          │    │         │    │        │  │
│   │ generate│    │ lex/parse│    │validate │    │decide  │  │
│   │ source  │    │ /eval    │    │+ assess │    │fate    │  │
│   └────▲────┘    └──────────┘    └─────────┘    └───┬────┘  │
│        │                                            │        │
│        │         ┌──────────┐                       │        │
│        └─────────│ Registry │◄──────────────────────┘        │
│                  │(success  │                                 │
│                  │ blocks)  │                                 │
│                  └──────────┘                                 │
└──────────────────────────────────────────────────────────────┘
```

## Pipeline Stages

### 1. IR-Gen (`@ir_gen`)

Produces new source programs through two strategies:

- **Seed selection**: Randomly picks from 8 predefined seed programs covering arithmetic, variable binding, and nested expressions.
- **Mutation**: When the registry contains successful blocks, there is a 50% chance of mutating an existing block instead of picking a fresh seed.

Five mutation strategies are available:

| Strategy | Transformation | Example |
|----------|---------------|---------|
| `grow-extend` | `(let v <rand> <existing>)` | Add a variable binding layer |
| `arith-variant` | `(+ <existing> <rand>)` | Extend with arithmetic |
| `chain-calls` | `(display <existing>)` | Wrap in an output call |
| `nest-deeper` | `(* <existing> 2)` | Scale the result |
| `decrement` | `(- <existing> 1)` | Subtract from the result |

### 2. IR-Eval (`@ir_eval`)

Executes the generated source through the full compilation pipeline:

```
source string → lexer → tokens → parser → AST → eval_node → result
```

Returns an `%eval_result_ty` struct:

```llvm
%eval_result_ty = type { i8* value, i32 is_valid, i32 numeric_result }
```

Supported operations: `let`, `display`, `+`, `-`, `*`, `if`, `compile`.

### 3. Scoring (`@ir_score`)

Quantifies the quality of an evaluation result:

| Criterion | Points |
|-----------|--------|
| Valid execution (eval succeeded) | +10 |
| Non-zero result | +5 |
| \|result\| > 10 (nontrivial magnitude) | +3 |
| Even result (structural property) | +2 |
| Generation bonus | +generation |

### 4. Feedback (`@ir_feedback`)

Determines the fate of each block based on its score:

- **Threshold** = `12 + generation` (selection pressure increases over time)
- `score >= threshold` → **KEEP** (stored in registry)
- `score >= 20` → **KEEP + MUTATE** candidate (used as raw material for the next generation)
- `score < threshold` → **DISCARD**

## Data Structures

### IR Block

```llvm
%ir_block_ty = type { i8* name, i8* source, i8* ir_text, i32 score, i32 generation, i32 status }
; status: 0 = pending, 1 = ok, 2 = fail
```

Each block stores the original source, the generated IR text, its score, the generation it was created in, and its validation status.

### Registry

A dynamic vector (`%vector_ty`) of successful IR blocks. Blocks in the registry serve as building material for future generations via mutation.

### Environment

A linked list (`%env_ty`) used during evaluation for variable bindings introduced by `let` expressions.

## Example Output

```
=== Cycle 0 / 20 ===============
[ir-gen]  function: (let a 3 (let b 7 (+ a b)))
[ir-eval] result:   10
[score]   value:    15
[status]  KEEP
[best]    score=15  gen=0
-------------------------------------------

=== Cycle 1 / 20 ===============
[mutate]  strategy: arith-variant
[ir-gen]  function: (+ (let a 3 (let b 7 (+ a b))) 42)
[ir-eval] result:   52
[score]   value:    21
[status]  KEEP
[best]    score=21  gen=1
-------------------------------------------

=== Cycle 5 / 20 ===============
[mutate]  strategy: grow-extend
[ir-gen]  function: (let v 73 (+ (let a 3 (let b 7 (+ a b))) 42))
[ir-eval] result:   52
[score]   value:    25
[status]  KEEP
-------------------------------------------

=== Final Registry: 12 successful blocks ===
  [0] score=15  gen=0  name=(let a 3 (let b 7 (+ a b)))
  [1] score=21  gen=1  name=(+ (let a 3 (let b 7 (+ a b))) 42)
  ...
[best]    score=25  gen=5
```

## Self-Learning Mechanism

The system follows a genetic programming approach where programs themselves are the evolving entities:

1. **Exploration** — Start from seed programs and generate diverse program structures.
2. **Evaluation** — Verify that generated code actually executes successfully.
3. **Selection** — Only blocks that pass the scoring threshold survive into the registry.
4. **Evolution** — Surviving blocks are mutated to produce more complex programs.
5. **Pressure** — The passing threshold increases with each generation, driving higher-quality output over time.

## Why No GPU

All "learning" is symbolic, operating at the IR level:

- **AST structures** evolve instead of neural network weights.
- **Score-based selection** replaces backpropagation.
- **Sequential per-generation execution** replaces batch processing.

This is closer to genetic programming than deep learning — the programs themselves are the population being evolved.

## Building and Running

```bash
# Compile with Clang/LLVM
clang minilisp_ir_v03.ll -o minilisp -lm

# Run (executes 20 generations by default)
./minilisp
```

The RNG is seeded from `time()`, so each run produces different results. To get reproducible runs, modify the seed in `@main`.

## Roadmap

- **`lambda` support** — Evolve function definitions and higher-order calls.
- **Type validation** — Add type safety scoring in IR-Eval.
- **Crossover** — Combine subtrees from two successful blocks.
- **Full self-reference** — Feed codegen'd IR text back through eval for a complete quine-like loop.
- **Goal-directed generation** — Search backward from a target output value.
- **GPU acceleration** — Parallel evaluation of candidate blocks (future).
