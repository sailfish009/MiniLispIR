; ===========================================================
; MiniLispIR v0.4 - Self-Improving Compiler
;
; New in v0.4:
;   - File I/O: reads compiler source from disk, writes improved version
;   - Source-level function extraction and patching
;   - Convergence detection: saves when improvement plateaus
;   - Bootstrap loop: compiler improves its own IR output
;
; Flow:
;   1. Read own source file (input.ll)
;   2. Extract function blocks as text segments
;   3. For each function, run ir-gen/ir-eval cycle
;   4. If improved version scores higher, patch it in
;   5. When score delta < threshold for N cycles, converge
;   6. Write improved source to output file
;
; ===========================================================

; ---------- External Declarations ----------
declare i8* @malloc(i64)
declare i8* @realloc(i8*, i64)
declare void @free(i8*)
declare i32 @printf(i8*, ...)
declare i32 @sprintf(i8*, i8*, ...)
declare i32 @fprintf(%FILE_ty*, i8*, ...)
declare i32 @strcmp(i8*, i8*)
declare i32 @strncmp(i8*, i8*, i64)
declare i32 @atoi(i8*)
declare i32 @strlen(i8*)
declare i8* @memcpy(i8*, i8*, i64)
declare i8* @strstr(i8*, i8*)
declare i64 @time(i64*)

; File I/O
%FILE_ty = type opaque
declare %FILE_ty* @fopen(i8*, i8*)
declare i64 @fread(i8*, i64, i64, %FILE_ty*)
declare i64 @fwrite(i8*, i64, i64, %FILE_ty*)
declare i32 @fclose(%FILE_ty*)
declare i32 @fseek(%FILE_ty*, i64, i32)
declare i64 @ftell(%FILE_ty*)

; ===========================================================
; String Constants
; ===========================================================

; --- Format strings ---
@fmt_int       = private constant [3  x i8] c"%d\00"
@fmt_str       = private constant [3  x i8] c"%s\00"
@fmt_newline   = private constant [2  x i8] c"\0A\00"
@fmt_run       = private constant [13 x i8] c"display: %s\0A\00"

; --- Logging ---
@fmt_banner    = private constant [60 x i8] c"\0A===== MiniLispIR v0.4 Self-Improving Compiler =====\0A\0A\00"
@fmt_load      = private constant [35 x i8] c"[load]   source: %s (%d bytes)\0A\00"
@fmt_extract   = private constant [40 x i8] c"[extract] found %d function blocks\0A\00"
@fmt_cycle     = private constant [45 x i8] c"\0A--- Cycle %d / %d (gen %d) ----------------\0A\00"
@fmt_target    = private constant [35 x i8] c"[target] function: %s\0A\00"
@fmt_gen       = private constant [30 x i8] c"[ir-gen]   candidate: %s\0A\00"
@fmt_eval      = private constant [30 x i8] c"[ir-eval]  result:    %s\0A\00"
@fmt_score     = private constant [30 x i8] c"[score]    value:     %d\0A\00"
@fmt_baseline  = private constant [30 x i8] c"[baseline] score:     %d\0A\00"
@fmt_improved  = private constant [40 x i8] c"[IMPROVED] %s: %d -> %d (+%d)\0A\00"
@fmt_no_improv = private constant [30 x i8] c"[skip]     no improvement\0A\00"
@fmt_converge  = private constant [50 x i8] c"\0A[CONVERGE] plateau for %d cycles, saving...\0A\00"
@fmt_save      = private constant [40 x i8] c"[save]   output: %s (%d bytes)\0A\00"
@fmt_status    = private constant [25 x i8] c"[status]  %s\0A\00"
@fmt_summary   = private constant [55 x i8] c"\0A===== Summary: %d functions improved, delta=%d =====\0A\00"
@fmt_mutate    = private constant [30 x i8] c"[mutate]  strategy: %s\0A\00"
@fmt_patch     = private constant [40 x i8] c"[patch]  replacing function block...\0A\00"
@fmt_err_open  = private constant [30 x i8] c"[ERROR] cannot open: %s\0A\00"
@fmt_err_empty = private constant [25 x i8] c"[ERROR] empty source\0A\00"
@fmt_block_hdr = private constant [50 x i8] c"  [%d] name=%-20s score=%d gen=%d\0A\00"

; --- Token / AST type strings ---
@str_lparen    = private constant [2  x i8] c"(\00"
@str_rparen    = private constant [2  x i8] c")\00"
@str_let       = private constant [4  x i8] c"let\00"
@str_display   = private constant [8  x i8] c"display\00"
@str_plus      = private constant [2  x i8] c"+\00"
@str_minus     = private constant [2  x i8] c"-\00"
@str_mul       = private constant [2  x i8] c"*\00"
@str_compile   = private constant [8  x i8] c"compile\00"
@str_list      = private constant [5  x i8] c"list\00"
@str_symbol    = private constant [7  x i8] c"symbol\00"
@str_number    = private constant [7  x i8] c"number\00"
@str_quote     = private constant [6  x i8] c"quote\00"
@str_if        = private constant [3  x i8] c"if\00"
@str_empty     = private constant [1  x i8] c"\00"

; --- Status strings ---
@str_ok        = private constant [3  x i8] c"OK\00"
@str_fail      = private constant [5  x i8] c"FAIL\00"

; --- File mode strings ---
@str_mode_r    = private constant [2  x i8] c"r\00"
@str_mode_w    = private constant [2  x i8] c"w\00"

; --- Function detection markers ---
@str_define    = private constant [7  x i8] c"define\00"
@str_define_sp = private constant [8  x i8] c"define \00"
@str_func_end  = private constant [3  x i8] c"}\0A\00"
@str_at_sign   = private constant [2  x i8] c"@\00"

; --- Default file paths ---
@default_input  = private constant [17 x i8] c"minilisp_ir.ll\00"
@default_output = private constant [26 x i8] c"minilisp_ir_improved.ll\00"

; --- Mutation helper strings ---
@str_space      = private constant [2  x i8] c" \00"
@str_m_let_pre  = private constant [7  x i8] c"(let v \00"
@str_m_plus_pre = private constant [4  x i8] c"(+ \00"
@str_m_sub_pre  = private constant [4  x i8] c"(- \00"
@str_m_mul_pre  = private constant [4  x i8] c"(* \00"
@str_m_disp_pre = private constant [10 x i8] c"(display \00"
@str_m_two      = private constant [4  x i8] c" 2)\00"
@str_m_one      = private constant [4  x i8] c" 1)\00"

; --- Mutation strategy names ---
@str_m_grow    = private constant [12 x i8] c"grow-extend\00"
@str_m_swap    = private constant [10 x i8] c"swap-args\00"
@str_m_nest    = private constant [12 x i8] c"nest-deeper\00"
@str_m_chain   = private constant [12 x i8] c"chain-calls\00"
@str_m_arith   = private constant [14 x i8] c"arith-variant\00"

; --- IR codegen templates ---
@ir_header     = private constant [45 x i8] c"declare i32 @printf(i8*, ...)\0A\00"
@ir_alloca     = private constant [25 x i8] c"  %%%s = alloca i32\0A\00"
@ir_add_inst   = private constant [30 x i8] c"  %%%s = add i32 %s, %s\0A\00"
@ir_sub_inst   = private constant [30 x i8] c"  %%%s = sub i32 %s, %s\0A\00"
@ir_mul_inst   = private constant [30 x i8] c"  %%%s = mul i32 %s, %s\0A\00"
@ir_disp_fmt   = private constant [70 x i8] c"  call i32 (i8*, ...) @printf(i8* @fmt, i8* %s)\0A\00"
@ir_compile_comment = private constant [25 x i8] c"  ; compile (self-ref)\0A\00"

; --- Seed programs ---
@seed_0 = private constant [12 x i8] c"(+ 10 20)\0A\00"
@seed_1 = private constant [20 x i8] c"(let x 5 (+ x 10))\00"
@seed_2 = private constant [30 x i8] c"(let x 10 (display (+ x 20)))\00"
@seed_3 = private constant [30 x i8] c"(let a 3 (let b 7 (+ a b)))\00"
@seed_4 = private constant [22 x i8] c"(let x 100 (- x 42))\00"
@seed_5 = private constant [19 x i8] c"(let x 6 (* x 7))\00"
@seed_6 = private constant [37 x i8] c"(let a 10 (let b 20 (+ a (+ b 5))))\00"
@seed_7 = private constant [36 x i8] c"(let x 2 (let y 3 (* x (+ y 4))))\00"

; ===========================================================
; Type Definitions
; ===========================================================

%vector_ty      = type { i64, i64, i8** }
%node_ty        = type { i8*, i8*, %vector_ty* }
%env_ty         = type { i8*, i8*, %env_ty* }
%eval_result_ty = type { i8*, i32, i32 }

; IR block: { name, source, ir_text, score, generation, status }
%ir_block_ty = type { i8*, i8*, i8*, i32, i32, i32 }

; Function segment: { name, start_offset, end_offset, text, score, improved_text }
%func_seg_ty = type { i8*, i64, i64, i8*, i32, i8* }

; Improvement snapshot:
; { total_score, num_improved, generation, source_text }
%snapshot_ty = type { i32, i32, i32, i8* }

; ===========================================================
; RNG (xorshift32)
; ===========================================================
@rng_state = global i32 0

define void @rng_seed(i32 %seed) {
entry:
  store i32 %seed, i32* @rng_state
  ret void
}

define i32 @rng_next() {
entry:
  %s = load i32, i32* @rng_state
  %s1 = shl i32 %s, 13
  %s2 = xor i32 %s, %s1
  %s3 = lshr i32 %s2, 17
  %s4 = xor i32 %s2, %s3
  %s5 = shl i32 %s4, 5
  %s6 = xor i32 %s4, %s5
  store i32 %s6, i32* @rng_state
  %mask = and i32 %s6, 2147483647
  ret i32 %mask
}

define i32 @rng_range(i32 %lo, i32 %hi) {
entry:
  %r = call i32 @rng_next()
  %span = sub i32 %hi, %lo
  %mod = urem i32 %r, %span
  %val = add i32 %lo, %mod
  ret i32 %val
}

; ===========================================================
; String Utilities
; ===========================================================

define i8* @str_copy(i8* %src) {
entry:
  %len = call i32 @strlen(i8* %src)
  %len64 = zext i32 %len to i64
  %alloc = add i64 %len64, 1
  %mem = call i8* @malloc(i64 %alloc)
  call i8* @memcpy(i8* %mem, i8* %src, i64 %alloc)
  ret i8* %mem
}

define i8* @str_concat(i8* %a, i8* %b) {
entry:
  %la = call i32 @strlen(i8* %a)
  %lb = call i32 @strlen(i8* %b)
  %total = add i32 %la, %lb
  %t64 = zext i32 %total to i64
  %alloc = add i64 %t64, 1
  %mem = call i8* @malloc(i64 %alloc)
  %la64 = zext i32 %la to i64
  call i8* @memcpy(i8* %mem, i8* %a, i64 %la64)
  %dst = getelementptr i8, i8* %mem, i32 %la
  %lb64 = zext i32 %lb to i64
  %lb64_1 = add i64 %lb64, 1
  call i8* @memcpy(i8* %dst, i8* %b, i64 %lb64_1)
  ret i8* %mem
}

define i8* @str_from_substr(i8* %src, i32 %start, i32 %length) {
entry:
  %len64 = zext i32 %length to i64
  %alloc = add i64 %len64, 1
  %mem = call i8* @malloc(i64 %alloc)
  %off = getelementptr i8, i8* %src, i32 %start
  call i8* @memcpy(i8* %mem, i8* %off, i64 %len64)
  %end_ptr = getelementptr i8, i8* %mem, i32 %length
  store i8 0, i8* %end_ptr
  ret i8* %mem
}

; substr by i64 offsets for file operations
define i8* @str_substr_64(i8* %src, i64 %start, i64 %length) {
entry:
  %alloc = add i64 %length, 1
  %mem = call i8* @malloc(i64 %alloc)
  %off = getelementptr i8, i8* %src, i64 %start
  call i8* @memcpy(i8* %mem, i8* %off, i64 %length)
  %end_ptr = getelementptr i8, i8* %mem, i64 %length
  store i8 0, i8* %end_ptr
  ret i8* %mem
}

define i8* @int_to_str(i32 %val) {
entry:
  %buf = call i8* @malloc(i64 20)
  call i32 (i8*, i8*, ...) @sprintf(i8* %buf, i8* getelementptr ([3 x i8], [3 x i8]* @fmt_int, i32 0, i32 0), i32 %val)
  ret i8* %buf
}

define i32 @abs_i32(i32 %x) {
entry:
  %neg = icmp slt i32 %x, 0
  br i1 %neg, label %do_neg, label %done
do_neg:
  %nx = sub i32 0, %x
  ret i32 %nx
done:
  ret i32 %x
}

; ===========================================================
; Vector
; ===========================================================

define %vector_ty* @vector_new() {
entry:
  %v = call i8* @malloc(i64 24)
  %vp = bitcast i8* %v to %vector_ty*
  %sp = getelementptr %vector_ty, %vector_ty* %vp, i32 0, i32 0
  store i64 0, i64* %sp
  %cp = getelementptr %vector_ty, %vector_ty* %vp, i32 0, i32 1
  store i64 8, i64* %cp
  %dp = getelementptr %vector_ty, %vector_ty* %vp, i32 0, i32 2
  %dm = call i8* @malloc(i64 64)
  %dc = bitcast i8* %dm to i8**
  store i8** %dc, i8*** %dp
  ret %vector_ty* %vp
}

define void @vector_push(%vector_ty* %v, i8* %item) {
entry:
  %sp = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 0
  %sz = load i64, i64* %sp
  %cp = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 1
  %cap = load i64, i64* %cp
  %full = icmp eq i64 %sz, %cap
  br i1 %full, label %resize, label %push
resize:
  %nc = mul i64 %cap, 2
  store i64 %nc, i64* %cp
  %dp = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 2
  %d = load i8**, i8*** %dp
  %di = bitcast i8** %d to i8*
  %ns = mul i64 %nc, 8
  %nd = call i8* @realloc(i8* %di, i64 %ns)
  %ndc = bitcast i8* %nd to i8**
  store i8** %ndc, i8*** %dp
  br label %push
push:
  %dp2 = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 2
  %d2 = load i8**, i8*** %dp2
  %ip = getelementptr i8*, i8** %d2, i64 %sz
  store i8* %item, i8** %ip
  %ns2 = add i64 %sz, 1
  store i64 %ns2, i64* %sp
  ret void
}

define i8* @vector_get(%vector_ty* %v, i64 %idx) {
entry:
  %dp = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 2
  %d = load i8**, i8*** %dp
  %ip = getelementptr i8*, i8** %d, i64 %idx
  %item = load i8*, i8** %ip
  ret i8* %item
}

define i64 @vector_size(%vector_ty* %v) {
entry:
  %sp = getelementptr %vector_ty, %vector_ty* %v, i32 0, i32 0
  %sz = load i64, i64* %sp
  ret i64 %sz
}

; ===========================================================
; AST Node
; ===========================================================

define %node_ty* @node_new(i8* %type, i8* %value) {
entry:
  %n = call i8* @malloc(i64 24)
  %np = bitcast i8* %n to %node_ty*
  %tp = getelementptr %node_ty, %node_ty* %np, i32 0, i32 0
  store i8* %type, i8** %tp
  %vp = getelementptr %node_ty, %node_ty* %np, i32 0, i32 1
  store i8* %value, i8** %vp
  %ch = call %vector_ty* @vector_new()
  %chp = getelementptr %node_ty, %node_ty* %np, i32 0, i32 2
  store %vector_ty* %ch, %vector_ty** %chp
  ret %node_ty* %np
}

define void @node_add_child(%node_ty* %p, %node_ty* %c) {
entry:
  %chp = getelementptr %node_ty, %node_ty* %p, i32 0, i32 2
  %ch = load %vector_ty*, %vector_ty** %chp
  %ci = bitcast %node_ty* %c to i8*
  call void @vector_push(%vector_ty* %ch, i8* %ci)
  ret void
}

define i64 @node_num_children(%node_ty* %n) {
entry:
  %chp = getelementptr %node_ty, %node_ty* %n, i32 0, i32 2
  %ch = load %vector_ty*, %vector_ty** %chp
  %sz = call i64 @vector_size(%vector_ty* %ch)
  ret i64 %sz
}

define %node_ty* @node_get_child(%node_ty* %n, i64 %idx) {
entry:
  %chp = getelementptr %node_ty, %node_ty* %n, i32 0, i32 2
  %ch = load %vector_ty*, %vector_ty** %chp
  %ci = call i8* @vector_get(%vector_ty* %ch, i64 %idx)
  %cn = bitcast i8* %ci to %node_ty*
  ret %node_ty* %cn
}

define i8* @node_type(%node_ty* %n) {
entry:
  %tp = getelementptr %node_ty, %node_ty* %n, i32 0, i32 0
  %t = load i8*, i8** %tp
  ret i8* %t
}

define i8* @node_value(%node_ty* %n) {
entry:
  %vp = getelementptr %node_ty, %node_ty* %n, i32 0, i32 1
  %val = load i8*, i8** %vp
  ret i8* %val
}

; ===========================================================
; Environment
; ===========================================================

define %env_ty* @env_new() {
entry:
  ret %env_ty* null
}

define %env_ty* @env_set(%env_ty* %env, i8* %name, i8* %value) {
entry:
  %m = call i8* @malloc(i64 24)
  %ep = bitcast i8* %m to %env_ty*
  %np = getelementptr %env_ty, %env_ty* %ep, i32 0, i32 0
  store i8* %name, i8** %np
  %vp = getelementptr %env_ty, %env_ty* %ep, i32 0, i32 1
  store i8* %value, i8** %vp
  %xp = getelementptr %env_ty, %env_ty* %ep, i32 0, i32 2
  store %env_ty* %env, %env_ty** %xp
  ret %env_ty* %ep
}

define i8* @env_get(%env_ty* %env, i8* %name) {
entry:
  %is_null = icmp eq %env_ty* %env, null
  br i1 %is_null, label %not_found, label %check
check:
  %cnp = getelementptr %env_ty, %env_ty* %env, i32 0, i32 0
  %cn = load i8*, i8** %cnp
  %cmp = call i32 @strcmp(i8* %cn, i8* %name)
  %eq = icmp eq i32 %cmp, 0
  br i1 %eq, label %found, label %next
found:
  %vp = getelementptr %env_ty, %env_ty* %env, i32 0, i32 1
  %val = load i8*, i8** %vp
  ret i8* %val
next:
  %xp = getelementptr %env_ty, %env_ty* %env, i32 0, i32 2
  %nx = load %env_ty*, %env_ty** %xp
  %r = call i8* @env_get(%env_ty* %nx, i8* %name)
  ret i8* %r
not_found:
  ret i8* null
}

; ===========================================================
; Lexer
; ===========================================================

define %vector_ty* @lexer(i8* %source) {
entry:
  %tokens = call %vector_ty* @vector_new()
  %len = call i32 @strlen(i8* %source)
  %i = alloca i32
  store i32 0, i32* %i
  br label %loop

loop:
  %idx = load i32, i32* %i
  %cond = icmp slt i32 %idx, %len
  br i1 %cond, label %body, label %done

body:
  %cp = getelementptr i8, i8* %source, i32 %idx
  %ch = load i8, i8* %cp
  %ws1 = icmp eq i8 %ch, 32
  %ws2 = icmp eq i8 %ch, 9
  %ws3 = icmp eq i8 %ch, 10
  %ws4 = icmp eq i8 %ch, 13
  %w12 = or i1 %ws1, %ws2
  %w34 = or i1 %ws3, %ws4
  %is_ws = or i1 %w12, %w34
  br i1 %is_ws, label %skip_ws, label %ck_lp

skip_ws:
  %wn = add i32 %idx, 1
  store i32 %wn, i32* %i
  br label %loop

ck_lp:
  %is_lp = icmp eq i8 %ch, 40
  br i1 %is_lp, label %do_lp, label %ck_rp
do_lp:
  %lpn = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0), i8* null)
  %lpi = bitcast %node_ty* %lpn to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %lpi)
  %ln = add i32 %idx, 1
  store i32 %ln, i32* %i
  br label %loop

ck_rp:
  %is_rp = icmp eq i8 %ch, 41
  br i1 %is_rp, label %do_rp, label %ck_qt
do_rp:
  %rpn = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0), i8* null)
  %rpi = bitcast %node_ty* %rpn to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %rpi)
  %rn = add i32 %idx, 1
  store i32 %rn, i32* %i
  br label %loop

ck_qt:
  %is_qt = icmp eq i8 %ch, 39
  br i1 %is_qt, label %do_qt, label %ck_dg
do_qt:
  %qs = add i32 %idx, 1
  %j = alloca i32
  store i32 %qs, i32* %j
  br label %qt_lp
qt_lp:
  %jv = load i32, i32* %j
  %jc = icmp slt i32 %jv, %len
  br i1 %jc, label %qt_bd, label %qt_er
qt_bd:
  %jcp = getelementptr i8, i8* %source, i32 %jv
  %jch = load i8, i8* %jcp
  %jeq = icmp eq i8 %jch, 39
  br i1 %jeq, label %qt_dn, label %qt_nx
qt_nx:
  %ji = add i32 %jv, 1
  store i32 %ji, i32* %j
  br label %qt_lp
qt_dn:
  %ql = sub i32 %jv, %qs
  %qstr = call i8* @str_from_substr(i8* %source, i32 %qs, i32 %ql)
  %qn = call %node_ty* @node_new(i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0), i8* %qstr)
  %qi = bitcast %node_ty* %qn to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %qi)
  %qe = add i32 %jv, 1
  store i32 %qe, i32* %i
  br label %loop
qt_er:
  ret %vector_ty* %tokens

ck_dg:
  %d1 = icmp sge i8 %ch, 48
  %d2 = icmp sle i8 %ch, 57
  %is_dg = and i1 %d1, %d2
  br i1 %is_dg, label %do_num, label %do_id
do_num:
  %ns = load i32, i32* %i
  %ni = alloca i32
  store i32 %ns, i32* %ni
  br label %nm_lp
nm_lp:
  %nv = load i32, i32* %ni
  %nc = icmp slt i32 %nv, %len
  br i1 %nc, label %nm_bd, label %nm_dn
nm_bd:
  %ncp = getelementptr i8, i8* %source, i32 %nv
  %nch = load i8, i8* %ncp
  %nd1 = icmp sge i8 %nch, 48
  %nd2 = icmp sle i8 %nch, 57
  %ndd = and i1 %nd1, %nd2
  br i1 %ndd, label %nm_nx, label %nm_dn
nm_nx:
  %nni = add i32 %nv, 1
  store i32 %nni, i32* %ni
  br label %nm_lp
nm_dn:
  %nl = sub i32 %nv, %ns
  %nstr = call i8* @str_from_substr(i8* %source, i32 %ns, i32 %nl)
  %nn = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0), i8* %nstr)
  %nni2 = bitcast %node_ty* %nn to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %nni2)
  store i32 %nv, i32* %i
  br label %loop

do_id:
  %ids = load i32, i32* %i
  %pi = alloca i32
  store i32 %ids, i32* %pi
  br label %id_lp
id_lp:
  %pv = load i32, i32* %pi
  %pc = icmp slt i32 %pv, %len
  br i1 %pc, label %id_bd, label %id_dn
id_bd:
  %pcp = getelementptr i8, i8* %source, i32 %pv
  %pch = load i8, i8* %pcp
  %pd1 = icmp eq i8 %pch, 32
  %pd2 = icmp eq i8 %pch, 40
  %pd3 = icmp eq i8 %pch, 41
  %pd4 = icmp eq i8 %pch, 39
  %pd5 = icmp eq i8 %pch, 9
  %pd6 = icmp eq i8 %pch, 10
  %pd7 = icmp eq i8 %pch, 13
  %pa = or i1 %pd1, %pd2
  %pb = or i1 %pa, %pd3
  %pcc = or i1 %pb, %pd4
  %pdd = or i1 %pcc, %pd5
  %pe = or i1 %pdd, %pd6
  %pf = or i1 %pe, %pd7
  br i1 %pf, label %id_dn, label %id_nx
id_nx:
  %pni = add i32 %pv, 1
  store i32 %pni, i32* %pi
  br label %id_lp
id_dn:
  %idl = sub i32 %pv, %ids
  %idstr = call i8* @str_from_substr(i8* %source, i32 %ids, i32 %idl)
  %idn = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0), i8* %idstr)
  %idi = bitcast %node_ty* %idn to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %idi)
  store i32 %pv, i32* %i
  br label %loop

done:
  ret %vector_ty* %tokens
}

; ===========================================================
; Parser
; ===========================================================

define %node_ty* @parser(%vector_ty* %tokens) {
entry:
  %root = call %node_ty* @node_new(i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0), i8* null)
  %stack = call %vector_ty* @vector_new()
  %ri = bitcast %node_ty* %root to i8*
  call void @vector_push(%vector_ty* %stack, i8* %ri)
  %i = alloca i64
  store i64 0, i64* %i
  br label %loop

loop:
  %idx = load i64, i64* %i
  %sz = call i64 @vector_size(%vector_ty* %tokens)
  %cond = icmp ult i64 %idx, %sz
  br i1 %cond, label %body, label %done

body:
  %ti = call i8* @vector_get(%vector_ty* %tokens, i64 %idx)
  %tok = bitcast i8* %ti to %node_ty*
  %tt = call i8* @node_type(%node_ty* %tok)
  %tv = call i8* @node_value(%node_ty* %tok)

  %clp = call i32 @strcmp(i8* %tt, i8* getelementptr ([2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0))
  %ilp = icmp eq i32 %clp, 0
  br i1 %ilp, label %new_list, label %ck_rp

new_list:
  %nl = call %node_ty* @node_new(i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0), i8* null)
  %ts1 = call i64 @vector_size(%vector_ty* %stack)
  %ti1 = sub i64 %ts1, 1
  %t18 = call i8* @vector_get(%vector_ty* %stack, i64 %ti1)
  %t1n = bitcast i8* %t18 to %node_ty*
  call void @node_add_child(%node_ty* %t1n, %node_ty* %nl)
  %nli = bitcast %node_ty* %nl to i8*
  call void @vector_push(%vector_ty* %stack, i8* %nli)
  br label %next

ck_rp:
  %crp = call i32 @strcmp(i8* %tt, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  %irp = icmp eq i32 %crp, 0
  br i1 %irp, label %pop_st, label %handle_atom
pop_st:
  %ss = call i64 @vector_size(%vector_ty* %stack)
  %ns = sub i64 %ss, 1
  %ssp = getelementptr %vector_ty, %vector_ty* %stack, i32 0, i32 0
  store i64 %ns, i64* %ssp
  br label %next

handle_atom:
  %is_sym_t = call i32 @strcmp(i8* %tt, i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0))
  %is_sym = icmp eq i32 %is_sym_t, 0
  br i1 %is_sym, label %classify, label %add_orig
classify:
  %vn = icmp eq i8* %tv, null
  br i1 %vn, label %add_orig, label %kw_let

kw_let:
  %kl = call i32 @strcmp(i8* %tv, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %il = icmp eq i32 %kl, 0
  br i1 %il, label %mk_let, label %kw_disp
mk_let:
  %letn = call %node_ty* @node_new(i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0), i8* null)
  br label %add_kw

kw_disp:
  %kd = call i32 @strcmp(i8* %tv, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %idd = icmp eq i32 %kd, 0
  br i1 %idd, label %mk_disp, label %kw_plus
mk_disp:
  %dispn = call %node_ty* @node_new(i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0), i8* null)
  br label %add_kw

kw_plus:
  %kp = call i32 @strcmp(i8* %tv, i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0))
  %ipp = icmp eq i32 %kp, 0
  br i1 %ipp, label %mk_plus, label %kw_minus
mk_plus:
  %plusn = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0), i8* null)
  br label %add_kw

kw_minus:
  %km = call i32 @strcmp(i8* %tv, i8* getelementptr ([2 x i8], [2 x i8]* @str_minus, i32 0, i32 0))
  %imm = icmp eq i32 %km, 0
  br i1 %imm, label %mk_minus, label %kw_mul
mk_minus:
  %minn = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_minus, i32 0, i32 0), i8* null)
  br label %add_kw

kw_mul:
  %kmu = call i32 @strcmp(i8* %tv, i8* getelementptr ([2 x i8], [2 x i8]* @str_mul, i32 0, i32 0))
  %imu = icmp eq i32 %kmu, 0
  br i1 %imu, label %mk_mul, label %kw_comp
mk_mul:
  %muln = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_mul, i32 0, i32 0), i8* null)
  br label %add_kw

kw_comp:
  %kc = call i32 @strcmp(i8* %tv, i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0))
  %icc = icmp eq i32 %kc, 0
  br i1 %icc, label %mk_comp, label %kw_if
mk_comp:
  %compn = call %node_ty* @node_new(i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0), i8* null)
  br label %add_kw

kw_if:
  %ki = call i32 @strcmp(i8* %tv, i8* getelementptr ([3 x i8], [3 x i8]* @str_if, i32 0, i32 0))
  %ifi = icmp eq i32 %ki, 0
  br i1 %ifi, label %mk_if, label %add_orig
mk_if:
  %ifn = call %node_ty* @node_new(i8* getelementptr ([3 x i8], [3 x i8]* @str_if, i32 0, i32 0), i8* null)
  br label %add_kw

add_kw:
  %kwn = phi %node_ty* [%letn, %mk_let], [%dispn, %mk_disp], [%plusn, %mk_plus],
                        [%minn, %mk_minus], [%muln, %mk_mul], [%compn, %mk_comp],
                        [%ifn, %mk_if]
  %ts2 = call i64 @vector_size(%vector_ty* %stack)
  %ti2 = sub i64 %ts2, 1
  %t28 = call i8* @vector_get(%vector_ty* %stack, i64 %ti2)
  %t2n = bitcast i8* %t28 to %node_ty*
  call void @node_add_child(%node_ty* %t2n, %node_ty* %kwn)
  br label %next

add_orig:
  %ts3 = call i64 @vector_size(%vector_ty* %stack)
  %ti3 = sub i64 %ts3, 1
  %t38 = call i8* @vector_get(%vector_ty* %stack, i64 %ti3)
  %t3n = bitcast i8* %t38 to %node_ty*
  call void @node_add_child(%node_ty* %t3n, %node_ty* %tok)
  br label %next

next:
  %ni = add i64 %idx, 1
  store i64 %ni, i64* %i
  br label %loop

done:
  ret %node_ty* %root
}

; ===========================================================
; Eval (recursive, with env)
; ===========================================================

define i8* @eval_node(%node_ty* %ast, %env_ty* %env) {
entry:
  %type = call i8* @node_type(%node_ty* %ast)
  %value = call i8* @node_value(%node_ty* %ast)

  %cn = call i32 @strcmp(i8* %type, i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0))
  %in = icmp eq i32 %cn, 0
  br i1 %in, label %ret_val, label %ck_sym
ret_val:
  ret i8* %value

ck_sym:
  %cs = call i32 @strcmp(i8* %type, i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0))
  %is = icmp eq i32 %cs, 0
  br i1 %is, label %do_lookup, label %ck_quote
do_lookup:
  %looked = call i8* @env_get(%env_ty* %env, i8* %value)
  %fnd = icmp ne i8* %looked, null
  br i1 %fnd, label %ret_looked, label %ret_sym
ret_looked:
  ret i8* %looked
ret_sym:
  ret i8* %value

ck_quote:
  %cq = call i32 @strcmp(i8* %type, i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0))
  %iq = icmp eq i32 %cq, 0
  br i1 %iq, label %ret_qt, label %ck_list
ret_qt:
  ret i8* %value

ck_list:
  %cl = call i32 @strcmp(i8* %type, i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0))
  %il = icmp eq i32 %cl, 0
  br i1 %il, label %eval_list, label %ret_null

eval_list:
  %nch = call i64 @node_num_children(%node_ty* %ast)
  %hch = icmp ugt i64 %nch, 0
  br i1 %hch, label %dispatch, label %ret_null

dispatch:
  %first = call %node_ty* @node_get_child(%node_ty* %ast, i64 0)
  %ft = call i8* @node_type(%node_ty* %first)

  ; let
  %dl = call i32 @strcmp(i8* %ft, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %il2 = icmp eq i32 %dl, 0
  br i1 %il2, label %do_let, label %ck_disp

do_let:
  %ln = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %lname = call i8* @node_value(%node_ty* %ln)
  %le = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %lv = call i8* @eval_node(%node_ty* %le, %env_ty* %env)
  %ne = call %env_ty* @env_set(%env_ty* %env, i8* %lname, i8* %lv)
  %lb = call %node_ty* @node_get_child(%node_ty* %ast, i64 3)
  %lr = call i8* @eval_node(%node_ty* %lb, %env_ty* %ne)
  ret i8* %lr

ck_disp:
  %dd = call i32 @strcmp(i8* %ft, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %idd = icmp eq i32 %dd, 0
  br i1 %idd, label %do_disp, label %ck_plus
do_disp:
  %de = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %dv = call i8* @eval_node(%node_ty* %de, %env_ty* %env)
  call i32 (i8*, ...) @printf(i8* getelementptr ([13 x i8], [13 x i8]* @fmt_run, i32 0, i32 0), i8* %dv)
  ret i8* %dv

ck_plus:
  %dp = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0))
  %ipp = icmp eq i32 %dp, 0
  br i1 %ipp, label %do_plus, label %ck_minus
do_plus:
  %pl = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %pls = call i8* @eval_node(%node_ty* %pl, %env_ty* %env)
  %pr = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %prs = call i8* @eval_node(%node_ty* %pr, %env_ty* %env)
  %pli = call i32 @atoi(i8* %pls)
  %pri = call i32 @atoi(i8* %prs)
  %psum = add i32 %pli, %pri
  %pstr = call i8* @int_to_str(i32 %psum)
  ret i8* %pstr

ck_minus:
  %dm = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_minus, i32 0, i32 0))
  %imm = icmp eq i32 %dm, 0
  br i1 %imm, label %do_minus, label %ck_mul
do_minus:
  %ml = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %mls = call i8* @eval_node(%node_ty* %ml, %env_ty* %env)
  %mr = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %mrs = call i8* @eval_node(%node_ty* %mr, %env_ty* %env)
  %mli = call i32 @atoi(i8* %mls)
  %mri = call i32 @atoi(i8* %mrs)
  %mdif = sub i32 %mli, %mri
  %mstr = call i8* @int_to_str(i32 %mdif)
  ret i8* %mstr

ck_mul:
  %dmu = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_mul, i32 0, i32 0))
  %imu = icmp eq i32 %dmu, 0
  br i1 %imu, label %do_mul, label %ck_if
do_mul:
  %ul = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %uls = call i8* @eval_node(%node_ty* %ul, %env_ty* %env)
  %ur = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %urs = call i8* @eval_node(%node_ty* %ur, %env_ty* %env)
  %uli = call i32 @atoi(i8* %uls)
  %uri = call i32 @atoi(i8* %urs)
  %uprod = mul i32 %uli, %uri
  %ustr = call i8* @int_to_str(i32 %uprod)
  ret i8* %ustr

ck_if:
  %dif = call i32 @strcmp(i8* %ft, i8* getelementptr ([3 x i8], [3 x i8]* @str_if, i32 0, i32 0))
  %iif = icmp eq i32 %dif, 0
  br i1 %iif, label %do_if, label %ck_comp
do_if:
  %icn = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %icv = call i8* @eval_node(%node_ty* %icn, %env_ty* %env)
  %ici = call i32 @atoi(i8* %icv)
  %icz = icmp ne i32 %ici, 0
  br i1 %icz, label %if_then, label %if_else
if_then:
  %thn = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %thv = call i8* @eval_node(%node_ty* %thn, %env_ty* %env)
  ret i8* %thv
if_else:
  %ifnch = call i64 @node_num_children(%node_ty* %ast)
  %has_else = icmp ugt i64 %ifnch, 3
  br i1 %has_else, label %do_else, label %ret_zero
do_else:
  %eln = call %node_ty* @node_get_child(%node_ty* %ast, i64 3)
  %elv = call i8* @eval_node(%node_ty* %eln, %env_ty* %env)
  ret i8* %elv
ret_zero:
  %zs = call i8* @int_to_str(i32 0)
  ret i8* %zs

ck_comp:
  %dc = call i32 @strcmp(i8* %ft, i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0))
  %icc = icmp eq i32 %dc, 0
  br i1 %icc, label %do_comp, label %eval_seq
do_comp:
  %csn = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %csv = call i8* @eval_node(%node_ty* %csn, %env_ty* %env)
  %ctk = call %vector_ty* @lexer(i8* %csv)
  %cas = call %node_ty* @parser(%vector_ty* %ctk)
  %cir = call i8* @codegen_node(%node_ty* %cas)
  ret i8* %cir

eval_seq:
  %sn = call i64 @node_num_children(%node_ty* %ast)
  %si = alloca i64
  store i64 0, i64* %si
  %sr = alloca i8*
  store i8* null, i8** %sr
  br label %seq_lp
seq_lp:
  %sv = load i64, i64* %si
  %sc = icmp ult i64 %sv, %sn
  br i1 %sc, label %seq_bd, label %seq_dn
seq_bd:
  %sch = call %node_ty* @node_get_child(%node_ty* %ast, i64 %sv)
  %svl = call i8* @eval_node(%node_ty* %sch, %env_ty* %env)
  store i8* %svl, i8** %sr
  %sni = add i64 %sv, 1
  store i64 %sni, i64* %si
  br label %seq_lp
seq_dn:
  %sfn = load i8*, i8** %sr
  ret i8* %sfn

ret_null:
  ret i8* null
}

; ===========================================================
; Codegen (AST -> IR text)
; ===========================================================

define i8* @codegen_node(%node_ty* %ast) {
entry:
  %type = call i8* @node_type(%node_ty* %ast)

  %cn = call i32 @strcmp(i8* %type, i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0))
  %in = icmp eq i32 %cn, 0
  br i1 %in, label %g_num, label %g_ck_sym
g_num:
  %nv = call i8* @node_value(%node_ty* %ast)
  ret i8* %nv

g_ck_sym:
  %cs = call i32 @strcmp(i8* %type, i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0))
  %is = icmp eq i32 %cs, 0
  br i1 %is, label %g_sym, label %g_ck_qt
g_sym:
  %sv = call i8* @node_value(%node_ty* %ast)
  ret i8* %sv

g_ck_qt:
  %cq = call i32 @strcmp(i8* %type, i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0))
  %iq = icmp eq i32 %cq, 0
  br i1 %iq, label %g_qt, label %g_ck_list
g_qt:
  %qv = call i8* @node_value(%node_ty* %ast)
  ret i8* %qv

g_ck_list:
  %cl = call i32 @strcmp(i8* %type, i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0))
  %il = icmp eq i32 %cl, 0
  br i1 %il, label %g_list, label %g_default

g_list:
  %nch = call i64 @node_num_children(%node_ty* %ast)
  %hch = icmp ugt i64 %nch, 0
  br i1 %hch, label %g_dispatch, label %g_empty

g_dispatch:
  %first = call %node_ty* @node_get_child(%node_ty* %ast, i64 0)
  %ft = call i8* @node_type(%node_ty* %first)

  ; Codegen each known form, sequence for unknown
  %gl = call i32 @strcmp(i8* %ft, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %il2 = icmp eq i32 %gl, 0
  br i1 %il2, label %g_let, label %g_ck_disp

g_let:
  %le = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %lev = call i8* @codegen_node(%node_ty* %le)
  %lb = call %node_ty* @node_get_child(%node_ty* %ast, i64 3)
  %lbv = call i8* @codegen_node(%node_ty* %lb)
  %l1 = call i8* @str_concat(i8* %lev, i8* getelementptr ([2 x i8], [2 x i8]* @fmt_newline, i32 0, i32 0))
  %l2 = call i8* @str_concat(i8* %l1, i8* %lbv)
  ret i8* %l2

g_ck_disp:
  %gd = call i32 @strcmp(i8* %ft, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %idd = icmp eq i32 %gd, 0
  br i1 %idd, label %g_disp, label %g_ck_plus
g_disp:
  %de = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %dev = call i8* @codegen_node(%node_ty* %de)
  %d1 = call i8* @str_concat(i8* getelementptr ([70 x i8], [70 x i8]* @ir_disp_fmt, i32 0, i32 0), i8* %dev)
  ret i8* %d1

g_ck_plus:
  %gp = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0))
  %ipp = icmp eq i32 %gp, 0
  br i1 %ipp, label %g_plus, label %g_ck_minus
g_plus:
  %pl = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %plv = call i8* @codegen_node(%node_ty* %pl)
  %pr = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %prv = call i8* @codegen_node(%node_ty* %pr)
  %ps = call i8* @str_concat(i8* getelementptr ([30 x i8], [30 x i8]* @ir_add_inst, i32 0, i32 0), i8* %plv)
  %ps2 = call i8* @str_concat(i8* %ps, i8* %prv)
  ret i8* %ps2

g_ck_minus:
  %gm = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_minus, i32 0, i32 0))
  %imm = icmp eq i32 %gm, 0
  br i1 %imm, label %g_minus, label %g_ck_mul
g_minus:
  %mll = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %mlv = call i8* @codegen_node(%node_ty* %mll)
  %mrl = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %mrv = call i8* @codegen_node(%node_ty* %mrl)
  %ms = call i8* @str_concat(i8* getelementptr ([30 x i8], [30 x i8]* @ir_sub_inst, i32 0, i32 0), i8* %mlv)
  %ms2 = call i8* @str_concat(i8* %ms, i8* %mrv)
  ret i8* %ms2

g_ck_mul:
  %gmu = call i32 @strcmp(i8* %ft, i8* getelementptr ([2 x i8], [2 x i8]* @str_mul, i32 0, i32 0))
  %imu = icmp eq i32 %gmu, 0
  br i1 %imu, label %g_mul, label %g_seq
g_mul:
  %ull = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %ulv = call i8* @codegen_node(%node_ty* %ull)
  %url = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %urv = call i8* @codegen_node(%node_ty* %url)
  %us = call i8* @str_concat(i8* getelementptr ([30 x i8], [30 x i8]* @ir_mul_inst, i32 0, i32 0), i8* %ulv)
  %us2 = call i8* @str_concat(i8* %us, i8* %urv)
  ret i8* %us2

g_seq:
  %sqn = call i64 @node_num_children(%node_ty* %ast)
  %sqi = alloca i64
  store i64 0, i64* %sqi
  %sqr = alloca i8*
  %emp = call i8* @str_copy(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0))
  store i8* %emp, i8** %sqr
  br label %sq_lp
sq_lp:
  %sv = load i64, i64* %sqi
  %scc = icmp ult i64 %sv, %sqn
  br i1 %scc, label %sq_bd, label %sq_dn
sq_bd:
  %sch = call %node_ty* @node_get_child(%node_ty* %ast, i64 %sv)
  %scv = call i8* @codegen_node(%node_ty* %sch)
  %prev = load i8*, i8** %sqr
  %cat = call i8* @str_concat(i8* %prev, i8* %scv)
  store i8* %cat, i8** %sqr
  %snni = add i64 %sv, 1
  store i64 %snni, i64* %sqi
  br label %sq_lp
sq_dn:
  %sfn = load i8*, i8** %sqr
  ret i8* %sfn

g_empty:
  %e1 = call i8* @str_copy(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0))
  ret i8* %e1

g_default:
  %e2 = call i8* @str_copy(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0))
  ret i8* %e2
}

; ===========================================================
; File I/O Helpers
; ===========================================================

; Read entire file into string, returns {i8* data, i64 size} via out params
; Returns i8* (null on failure)
define i8* @read_file(i8* %path, i64* %out_size) {
entry:
  %fp = call %FILE_ty* @fopen(i8* %path, i8* getelementptr ([2 x i8], [2 x i8]* @str_mode_r, i32 0, i32 0))
  %is_null = icmp eq %FILE_ty* %fp, null
  br i1 %is_null, label %fail, label %seek_end

seek_end:
  call i32 @fseek(%FILE_ty* %fp, i64 0, i32 2)  ; SEEK_END
  %size = call i64 @ftell(%FILE_ty* %fp)
  call i32 @fseek(%FILE_ty* %fp, i64 0, i32 0)  ; SEEK_SET
  %alloc = add i64 %size, 1
  %buf = call i8* @malloc(i64 %alloc)
  call i64 @fread(i8* %buf, i64 1, i64 %size, %FILE_ty* %fp)
  call i32 @fclose(%FILE_ty* %fp)
  ; Null-terminate
  %end_ptr = getelementptr i8, i8* %buf, i64 %size
  store i8 0, i8* %end_ptr
  store i64 %size, i64* %out_size
  ret i8* %buf

fail:
  store i64 0, i64* %out_size
  ret i8* null
}

; Write string to file
define i32 @write_file(i8* %path, i8* %data) {
entry:
  %fp = call %FILE_ty* @fopen(i8* %path, i8* getelementptr ([2 x i8], [2 x i8]* @str_mode_w, i32 0, i32 0))
  %is_null = icmp eq %FILE_ty* %fp, null
  br i1 %is_null, label %fail, label %do_write

do_write:
  %len = call i32 @strlen(i8* %data)
  %len64 = zext i32 %len to i64
  call i64 @fwrite(i8* %data, i64 1, i64 %len64, %FILE_ty* %fp)
  call i32 @fclose(%FILE_ty* %fp)
  ret i32 %len

fail:
  ret i32 0
}

; ===========================================================
; Source Function Extractor
;
; Scans .ll source text for "define" lines, extracts each
; function block (from "define" to closing "}") as a segment.
; ===========================================================

define %vector_ty* @extract_functions(i8* %source, i64 %source_len) {
entry:
  %segments = call %vector_ty* @vector_new()
  %i = alloca i64
  store i64 0, i64* %i
  %func_count = alloca i32
  store i32 0, i32* %func_count
  br label %scan_loop

scan_loop:
  %pos = load i64, i64* %i
  %cond = icmp ult i64 %pos, %source_len
  br i1 %cond, label %scan_body, label %scan_done

scan_body:
  ; Check if current line starts with "define "
  %cur_ptr = getelementptr i8, i8* %source, i64 %pos
  %cmp_def = call i32 @strncmp(i8* %cur_ptr,
    i8* getelementptr ([8 x i8], [8 x i8]* @str_define_sp, i32 0, i32 0), i64 7)
  %is_define = icmp eq i32 %cmp_def, 0
  br i1 %is_define, label %found_func, label %next_char

found_func:
  ; Extract function name: find '@' then read until '('
  %at_ptr = call i8* @strstr(i8* %cur_ptr, i8* getelementptr ([2 x i8], [2 x i8]* @str_at_sign, i32 0, i32 0))
  %has_at = icmp ne i8* %at_ptr, null
  br i1 %has_at, label %extract_name, label %next_char

extract_name:
  %at_off = ptrtoint i8* %at_ptr to i64
  %cur_off = ptrtoint i8* %cur_ptr to i64
  ; Skip '@'
  %name_start_ptr = getelementptr i8, i8* %at_ptr, i64 1
  ; Find '(' to end the name
  %ni = alloca i64
  store i64 0, i64* %ni
  br label %name_loop

name_loop:
  %nidx = load i64, i64* %ni
  %nc_ptr = getelementptr i8, i8* %name_start_ptr, i64 %nidx
  %nc = load i8, i8* %nc_ptr
  %is_paren = icmp eq i8 %nc, 40  ; '('
  %is_end = icmp eq i8 %nc, 0
  %stop = or i1 %is_paren, %is_end
  br i1 %stop, label %name_done, label %name_next

name_next:
  %nni = add i64 %nidx, 1
  store i64 %nni, i64* %ni
  br label %name_loop

name_done:
  %name_len = load i64, i64* %ni
  ; Compute offset of name_start_ptr from source base
  %ns_off_raw = ptrtoint i8* %name_start_ptr to i64
  %src_base = ptrtoint i8* %source to i64
  %ns_off = sub i64 %ns_off_raw, %src_base
  %func_name = call i8* @str_substr_64(i8* %source, i64 %ns_off, i64 %name_len)

  ; Now find the closing "}\n" for this function
  %func_start = load i64, i64* %i
  %ji = alloca i64
  store i64 %pos, i64* %ji
  %brace_depth = alloca i32
  store i32 0, i32* %brace_depth
  %found_open = alloca i32
  store i32 0, i32* %found_open
  br label %brace_loop

brace_loop:
  %bpos = load i64, i64* %ji
  %bcond = icmp ult i64 %bpos, %source_len
  br i1 %bcond, label %brace_body, label %brace_done

brace_body:
  %bchar_ptr = getelementptr i8, i8* %source, i64 %bpos
  %bchar = load i8, i8* %bchar_ptr
  %is_open = icmp eq i8 %bchar, 123   ; '{'
  br i1 %is_open, label %inc_depth, label %ck_close

inc_depth:
  %d1 = load i32, i32* %brace_depth
  %d2 = add i32 %d1, 1
  store i32 %d2, i32* %brace_depth
  store i32 1, i32* %found_open
  br label %brace_next

ck_close:
  %is_close = icmp eq i8 %bchar, 125  ; '}'
  br i1 %is_close, label %dec_depth, label %brace_next

dec_depth:
  %d3 = load i32, i32* %brace_depth
  %d4 = sub i32 %d3, 1
  store i32 %d4, i32* %brace_depth
  %fo = load i32, i32* %found_open
  %was_open = icmp eq i32 %fo, 1
  %at_zero = icmp eq i32 %d4, 0
  %func_end_cond = and i1 %was_open, %at_zero
  br i1 %func_end_cond, label %func_complete, label %brace_next

brace_next:
  %bni = add i64 %bpos, 1
  store i64 %bni, i64* %ji
  br label %brace_loop

func_complete:
  ; End offset is bpos + 1 (include the '}')
  %func_end = add i64 %bpos, 1
  ; Skip past any trailing newline
  %after_close = getelementptr i8, i8* %source, i64 %func_end
  %after_char = load i8, i8* %after_close
  %is_newline = icmp eq i8 %after_char, 10
  %actual_end = select i1 %is_newline, i64 1, i64 0
  %func_end_final = add i64 %func_end, %actual_end

  ; Extract text
  %func_text_len = sub i64 %func_end_final, %func_start
  %func_text = call i8* @str_substr_64(i8* %source, i64 %func_start, i64 %func_text_len)

  ; Create func_seg
  %seg_mem = call i8* @malloc(i64 48)
  %seg = bitcast i8* %seg_mem to %func_seg_ty*
  ; name
  %seg_np = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 0
  store i8* %func_name, i8** %seg_np
  ; start_offset
  %seg_sp = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 1
  store i64 %func_start, i64* %seg_sp
  ; end_offset
  %seg_ep = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 2
  store i64 %func_end_final, i64* %seg_ep
  ; text
  %seg_tp = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 3
  store i8* %func_text, i8** %seg_tp
  ; score = 0
  %seg_scp = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 4
  store i32 0, i32* %seg_scp
  ; improved_text = null
  %seg_imp = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 5
  store i8* null, i8** %seg_imp

  %seg_i8 = bitcast %func_seg_ty* %seg to i8*
  call void @vector_push(%vector_ty* %segments, i8* %seg_i8)

  %fc = load i32, i32* %func_count
  %fc2 = add i32 %fc, 1
  store i32 %fc2, i32* %func_count

  ; Advance past this function
  store i64 %func_end_final, i64* %i
  br label %scan_loop

brace_done:
  ; Unterminated function, skip
  br label %next_char

next_char:
  %npos = add i64 %pos, 1
  store i64 %npos, i64* %i
  br label %scan_loop

scan_done:
  %final_count = load i32, i32* %func_count
  call i32 (i8*, ...) @printf(i8* getelementptr ([40 x i8], [40 x i8]* @fmt_extract, i32 0, i32 0), i32 %final_count)
  ret %vector_ty* %segments
}

; ===========================================================
; IR-Eval for source strings (reused from v0.3)
; ===========================================================

define %eval_result_ty* @ir_eval(i8* %source) {
entry:
  %rm = call i8* @malloc(i64 24)
  %rp = bitcast i8* %rm to %eval_result_ty*
  %tokens = call %vector_ty* @lexer(i8* %source)
  %tok_sz = call i64 @vector_size(%vector_ty* %tokens)
  %has_tok = icmp ugt i64 %tok_sz, 0
  br i1 %has_tok, label %do_parse, label %eval_fail
do_parse:
  %ast = call %node_ty* @parser(%vector_ty* %tokens)
  %nch = call i64 @node_num_children(%node_ty* %ast)
  %has_ast = icmp ugt i64 %nch, 0
  br i1 %has_ast, label %do_eval, label %eval_fail
do_eval:
  %env = call %env_ty* @env_new()
  %result = call i8* @eval_node(%node_ty* %ast, %env_ty* %env)
  %is_valid = icmp ne i8* %result, null
  br i1 %is_valid, label %eval_ok, label %eval_fail
eval_ok:
  %vp = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 0
  store i8* %result, i8** %vp
  %ip = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 1
  store i32 1, i32* %ip
  %num = call i32 @atoi(i8* %result)
  %np = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 2
  store i32 %num, i32* %np
  ret %eval_result_ty* %rp
eval_fail:
  %vp2 = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 0
  store i8* null, i8** %vp2
  %ip2 = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 1
  store i32 0, i32* %ip2
  %np2 = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 2
  store i32 0, i32* %np2
  ret %eval_result_ty* %rp
}

; ===========================================================
; Scoring & Feedback (from v0.3)
; ===========================================================

define i32 @ir_score(%eval_result_ty* %result, i32 %generation) {
entry:
  %valid_ptr = getelementptr %eval_result_ty, %eval_result_ty* %result, i32 0, i32 1
  %valid = load i32, i32* %valid_ptr
  %is_valid = icmp eq i32 %valid, 1
  br i1 %is_valid, label %score_valid, label %score_zero
score_valid:
  %score = alloca i32
  store i32 10, i32* %score
  %num_ptr = getelementptr %eval_result_ty, %eval_result_ty* %result, i32 0, i32 2
  %num = load i32, i32* %num_ptr
  %nz = icmp ne i32 %num, 0
  br i1 %nz, label %add_nz, label %ck_mag
add_nz:
  %s1 = load i32, i32* %score
  %s2 = add i32 %s1, 5
  store i32 %s2, i32* %score
  br label %ck_mag
ck_mag:
  %abs = call i32 @abs_i32(i32 %num)
  %big = icmp sgt i32 %abs, 10
  br i1 %big, label %add_mag, label %ck_even
add_mag:
  %s3 = load i32, i32* %score
  %s4 = add i32 %s3, 3
  store i32 %s4, i32* %score
  br label %ck_even
ck_even:
  %rem = srem i32 %num, 2
  %ev = icmp eq i32 %rem, 0
  br i1 %ev, label %add_even, label %add_gen
add_even:
  %s5 = load i32, i32* %score
  %s6 = add i32 %s5, 2
  store i32 %s6, i32* %score
  br label %add_gen
add_gen:
  %s7 = load i32, i32* %score
  %s8 = add i32 %s7, %generation
  store i32 %s8, i32* %score
  %final = load i32, i32* %score
  ret i32 %final
score_zero:
  ret i32 0
}

; ===========================================================
; Mutation (from v0.3)
; ===========================================================

define i8* @mutate_source(i8* %src) {
entry:
  %choice = call i32 @rng_range(i32 0, i32 5)
  %rand_val = call i32 @rng_range(i32 1, i32 100)
  %rand_str = call i8* @int_to_str(i32 %rand_val)

  %c0 = icmp eq i32 %choice, 0
  br i1 %c0, label %m_grow, label %t1
m_grow:
  %g1 = call i8* @str_concat(i8* getelementptr ([7 x i8], [7 x i8]* @str_m_let_pre, i32 0, i32 0), i8* %rand_str)
  %g2 = call i8* @str_concat(i8* %g1, i8* getelementptr ([2 x i8], [2 x i8]* @str_space, i32 0, i32 0))
  %g3 = call i8* @str_concat(i8* %g2, i8* %src)
  %g4 = call i8* @str_concat(i8* %g3, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  ret i8* %g4
t1:
  %c1 = icmp eq i32 %choice, 1
  br i1 %c1, label %m_arith, label %t2
m_arith:
  %a1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_plus_pre, i32 0, i32 0), i8* %src)
  %a2 = call i8* @str_concat(i8* %a1, i8* getelementptr ([2 x i8], [2 x i8]* @str_space, i32 0, i32 0))
  %a3 = call i8* @str_concat(i8* %a2, i8* %rand_str)
  %a4 = call i8* @str_concat(i8* %a3, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  ret i8* %a4
t2:
  %c2 = icmp eq i32 %choice, 2
  br i1 %c2, label %m_chain, label %t3
m_chain:
  %ch1 = call i8* @str_concat(i8* getelementptr ([10 x i8], [10 x i8]* @str_m_disp_pre, i32 0, i32 0), i8* %src)
  %ch2 = call i8* @str_concat(i8* %ch1, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  ret i8* %ch2
t3:
  %c3 = icmp eq i32 %choice, 3
  br i1 %c3, label %m_scale, label %m_dec
m_scale:
  %sc1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_mul_pre, i32 0, i32 0), i8* %src)
  %sc2 = call i8* @str_concat(i8* %sc1, i8* getelementptr ([4 x i8], [4 x i8]* @str_m_two, i32 0, i32 0))
  ret i8* %sc2
m_dec:
  %dc1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_sub_pre, i32 0, i32 0), i8* %src)
  %dc2 = call i8* @str_concat(i8* %dc1, i8* getelementptr ([4 x i8], [4 x i8]* @str_m_one, i32 0, i32 0))
  ret i8* %dc2
}

; ===========================================================
; IR-Gen: generate candidate test programs for a function
; ===========================================================

define i8* @ir_gen(%vector_ty* %registry, i32 %generation) {
entry:
  %num_seeds = add i32 0, 8
  %reg_sz = call i64 @vector_size(%vector_ty* %registry)
  %has_reg = icmp ugt i64 %reg_sz, 0
  br i1 %has_reg, label %maybe_mutate, label %pick_seed
maybe_mutate:
  %coin = call i32 @rng_range(i32 0, i32 100)
  %do_mut = icmp slt i32 %coin, 50
  br i1 %do_mut, label %mutate_existing, label %pick_seed
mutate_existing:
  %reg_sz32 = trunc i64 %reg_sz to i32
  %pick_idx = call i32 @rng_range(i32 0, i32 %reg_sz32)
  %pick_idx64 = zext i32 %pick_idx to i64
  %block_i8 = call i8* @vector_get(%vector_ty* %registry, i64 %pick_idx64)
  %block = bitcast i8* %block_i8 to %ir_block_ty*
  %block_src_ptr = getelementptr %ir_block_ty, %ir_block_ty* %block, i32 0, i32 1
  %block_src = load i8*, i8** %block_src_ptr
  %mutated = call i8* @mutate_source(i8* %block_src)
  ret i8* %mutated
pick_seed:
  %seed_idx = call i32 @rng_range(i32 0, i32 %num_seeds)
  %c0 = icmp eq i32 %seed_idx, 0
  br i1 %c0, label %s0, label %t1
s0: %r0 = call i8* @str_copy(i8* getelementptr ([12 x i8], [12 x i8]* @seed_0, i32 0, i32 0))
    ret i8* %r0
t1: %c1 = icmp eq i32 %seed_idx, 1
    br i1 %c1, label %s1, label %t2
s1: %r1 = call i8* @str_copy(i8* getelementptr ([20 x i8], [20 x i8]* @seed_1, i32 0, i32 0))
    ret i8* %r1
t2: %c2 = icmp eq i32 %seed_idx, 2
    br i1 %c2, label %s2, label %t3
s2: %r2 = call i8* @str_copy(i8* getelementptr ([30 x i8], [30 x i8]* @seed_2, i32 0, i32 0))
    ret i8* %r2
t3: %c3 = icmp eq i32 %seed_idx, 3
    br i1 %c3, label %s3, label %t4
s3: %r3 = call i8* @str_copy(i8* getelementptr ([30 x i8], [30 x i8]* @seed_3, i32 0, i32 0))
    ret i8* %r3
t4: %c4 = icmp eq i32 %seed_idx, 4
    br i1 %c4, label %s4, label %t5
s4: %r4 = call i8* @str_copy(i8* getelementptr ([22 x i8], [22 x i8]* @seed_4, i32 0, i32 0))
    ret i8* %r4
t5: %c5 = icmp eq i32 %seed_idx, 5
    br i1 %c5, label %s5, label %t6
s5: %r5 = call i8* @str_copy(i8* getelementptr ([19 x i8], [19 x i8]* @seed_5, i32 0, i32 0))
    ret i8* %r5
t6: %c6 = icmp eq i32 %seed_idx, 6
    br i1 %c6, label %s6, label %s7
s6: %r6 = call i8* @str_copy(i8* getelementptr ([37 x i8], [37 x i8]* @seed_6, i32 0, i32 0))
    ret i8* %r6
s7: %r7 = call i8* @str_copy(i8* getelementptr ([36 x i8], [36 x i8]* @seed_7, i32 0, i32 0))
    ret i8* %r7
}

; ===========================================================
; Source Patcher: replace function text in source
; ===========================================================

define i8* @patch_source(i8* %source, i64 %start, i64 %end, i8* %new_text) {
entry:
  %src_len = call i32 @strlen(i8* %source)
  %src_len64 = zext i32 %src_len to i64
  %new_len = call i32 @strlen(i8* %new_text)
  %new_len64 = zext i32 %new_len to i64
  %old_len = sub i64 %end, %start
  ; result_len = src_len - old_len + new_len
  %result_len = sub i64 %src_len64, %old_len
  %result_len2 = add i64 %result_len, %new_len64
  %alloc = add i64 %result_len2, 1
  %result = call i8* @malloc(i64 %alloc)
  ; Copy prefix [0, start)
  call i8* @memcpy(i8* %result, i8* %source, i64 %start)
  ; Copy new_text
  %mid_ptr = getelementptr i8, i8* %result, i64 %start
  call i8* @memcpy(i8* %mid_ptr, i8* %new_text, i64 %new_len64)
  ; Copy suffix [end, src_len)
  %suffix_dst = getelementptr i8, i8* %mid_ptr, i64 %new_len64
  %suffix_src = getelementptr i8, i8* %source, i64 %end
  %suffix_len = sub i64 %src_len64, %end
  %suffix_len1 = add i64 %suffix_len, 1  ; include null
  call i8* @memcpy(i8* %suffix_dst, i8* %suffix_src, i64 %suffix_len1)
  ret i8* %result
}

; ===========================================================
; Main Self-Improvement Loop
;
; 1. Read input .ll file
; 2. Extract function blocks
; 3. For each function, run ir-gen/ir-eval cycles
; 4. Track best scores, detect convergence
; 5. Patch improved functions back into source
; 6. Write output .ll file
; ===========================================================

; Configuration (used as literals in self_improve):
;   convergence_patience = 5   (cycles without improvement before converge)
;   max_cycles_per_func  = 10  (max attempts per function)
;   improvement_threshold = 2  (minimum score delta)

define void @self_improve(i8* %input_path, i8* %output_path) {
entry:
  call i32 (i8*, ...) @printf(i8* getelementptr ([60 x i8], [60 x i8]* @fmt_banner, i32 0, i32 0))

  ; Read source file
  %file_size = alloca i64
  %source = call i8* @read_file(i8* %input_path, i64* %file_size)
  %is_null = icmp eq i8* %source, null
  br i1 %is_null, label %err_open, label %loaded

err_open:
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_err_open, i32 0, i32 0), i8* %input_path)
  ret void

loaded:
  %fsize = load i64, i64* %file_size
  %fsize32 = trunc i64 %fsize to i32
  call i32 (i8*, ...) @printf(i8* getelementptr ([35 x i8], [35 x i8]* @fmt_load, i32 0, i32 0), i8* %input_path, i32 %fsize32)

  ; Extract functions
  %segments = call %vector_ty* @extract_functions(i8* %source, i64 %fsize)
  %num_funcs = call i64 @vector_size(%vector_ty* %segments)

  ; Working copy of source that we'll patch
  %working = alloca i8*
  %working_copy = call i8* @str_copy(i8* %source)
  store i8* %working_copy, i8** %working

  ; Global tracking
  %total_improved = alloca i32
  store i32 0, i32* %total_improved
  %total_delta = alloca i32
  store i32 0, i32* %total_delta
  %generation = alloca i32
  store i32 0, i32* %generation
  %registry = call %vector_ty* @vector_new()

  ; Process each function
  %fi = alloca i64
  store i64 0, i64* %fi
  br label %func_loop

func_loop:
  %fv = load i64, i64* %fi
  %fcond = icmp ult i64 %fv, %num_funcs
  br i1 %fcond, label %func_body, label %func_done

func_body:
  %seg_i8 = call i8* @vector_get(%vector_ty* %segments, i64 %fv)
  %seg = bitcast i8* %seg_i8 to %func_seg_ty*
  %seg_name_ptr = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 0
  %seg_name = load i8*, i8** %seg_name_ptr

  call i32 (i8*, ...) @printf(i8* getelementptr ([35 x i8], [35 x i8]* @fmt_target, i32 0, i32 0), i8* %seg_name)

  ; Run improvement cycles for this function
  %best_score = alloca i32
  store i32 0, i32* %best_score
  %plateau_count = alloca i32
  store i32 0, i32* %plateau_count
  %ci = alloca i32
  store i32 0, i32* %ci
  br label %cycle_loop

cycle_loop:
  %cv = load i32, i32* %ci
  %max_cy = icmp slt i32 %cv, 10  ; max_cycles_per_func
  br i1 %max_cy, label %ck_plateau, label %cycle_done

ck_plateau:
  %plat = load i32, i32* %plateau_count
  %converged = icmp sge i32 %plat, 5  ; convergence_patience
  br i1 %converged, label %do_converge, label %cycle_body

do_converge:
  call i32 (i8*, ...) @printf(i8* getelementptr ([50 x i8], [50 x i8]* @fmt_converge, i32 0, i32 0), i32 %plat)
  br label %cycle_done

cycle_body:
  %gen_val = load i32, i32* %generation
  call i32 (i8*, ...) @printf(i8* getelementptr ([45 x i8], [45 x i8]* @fmt_cycle, i32 0, i32 0), i32 %cv, i32 10, i32 %gen_val)

  ; IR-Gen: produce a candidate
  %candidate = call i8* @ir_gen(%vector_ty* %registry, i32 %gen_val)
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_gen, i32 0, i32 0), i8* %candidate)

  ; IR-Eval
  %eval_res = call %eval_result_ty* @ir_eval(i8* %candidate)
  %val_ptr = getelementptr %eval_result_ty, %eval_result_ty* %eval_res, i32 0, i32 0
  %val = load i8*, i8** %val_ptr
  %has_val = icmp ne i8* %val, null
  br i1 %has_val, label %print_result, label %no_result

print_result:
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_eval, i32 0, i32 0), i8* %val)
  br label %do_score

no_result:
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_status, i32 0, i32 0),
    i8* getelementptr ([5 x i8], [5 x i8]* @str_fail, i32 0, i32 0))
  br label %do_score

do_score:
  %score = call i32 @ir_score(%eval_result_ty* %eval_res, i32 %gen_val)
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_score, i32 0, i32 0), i32 %score)

  ; Check improvement
  %prev_best = load i32, i32* %best_score
  %delta = sub i32 %score, %prev_best
  %is_improved = icmp sgt i32 %delta, 2  ; improvement_threshold
  br i1 %is_improved, label %record_improvement, label %no_improvement

record_improvement:
  store i32 %score, i32* %best_score
  store i32 0, i32* %plateau_count  ; reset plateau counter
  call i32 (i8*, ...) @printf(i8* getelementptr ([40 x i8], [40 x i8]* @fmt_improved, i32 0, i32 0),
    i8* %seg_name, i32 %prev_best, i32 %score, i32 %delta)

  ; Add to registry
  %blk = call i8* @malloc(i64 48)
  %blk_p = bitcast i8* %blk to %ir_block_ty*
  %blk_np = getelementptr %ir_block_ty, %ir_block_ty* %blk_p, i32 0, i32 0
  store i8* %seg_name, i8** %blk_np
  %blk_sp = getelementptr %ir_block_ty, %ir_block_ty* %blk_p, i32 0, i32 1
  store i8* %candidate, i8** %blk_sp
  %blk_scp = getelementptr %ir_block_ty, %ir_block_ty* %blk_p, i32 0, i32 3
  store i32 %score, i32* %blk_scp
  %blk_gp = getelementptr %ir_block_ty, %ir_block_ty* %blk_p, i32 0, i32 4
  store i32 %gen_val, i32* %blk_gp
  call void @vector_push(%vector_ty* %registry, i8* %blk)

  ; Store improved text in segment
  %seg_imp2 = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 5
  ; Generate improved IR text via codegen
  %imp_tok = call %vector_ty* @lexer(i8* %candidate)
  %imp_ast = call %node_ty* @parser(%vector_ty* %imp_tok)
  %imp_ir = call i8* @codegen_node(%node_ty* %imp_ast)
  store i8* %imp_ir, i8** %seg_imp2

  ; Update segment score
  %seg_scp2 = getelementptr %func_seg_ty, %func_seg_ty* %seg, i32 0, i32 4
  store i32 %score, i32* %seg_scp2

  br label %next_cycle

no_improvement:
  %plat2 = load i32, i32* %plateau_count
  %plat3 = add i32 %plat2, 1
  store i32 %plat3, i32* %plateau_count
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_no_improv, i32 0, i32 0))
  br label %next_cycle

next_cycle:
  %cni = add i32 %cv, 1
  store i32 %cni, i32* %ci
  %gni = load i32, i32* %generation
  %gni2 = add i32 %gni, 1
  store i32 %gni2, i32* %generation
  br label %cycle_loop

cycle_done:
  ; Check if this function was improved
  %final_score = load i32, i32* %best_score
  %was_improved = icmp sgt i32 %final_score, 0
  br i1 %was_improved, label %count_improved, label %next_func

count_improved:
  %ti = load i32, i32* %total_improved
  %ti2 = add i32 %ti, 1
  store i32 %ti2, i32* %total_improved
  %td = load i32, i32* %total_delta
  %td2 = add i32 %td, %final_score
  store i32 %td2, i32* %total_delta
  br label %next_func

next_func:
  %fni = add i64 %fv, 1
  store i64 %fni, i64* %fi
  br label %func_loop

func_done:
  ; === Write output ===
  %final_source = load i8*, i8** %working
  %written = call i32 @write_file(i8* %output_path, i8* %final_source)
  call i32 (i8*, ...) @printf(i8* getelementptr ([40 x i8], [40 x i8]* @fmt_save, i32 0, i32 0), i8* %output_path, i32 %written)

  ; Summary
  %final_ti = load i32, i32* %total_improved
  %final_td = load i32, i32* %total_delta
  call i32 (i8*, ...) @printf(i8* getelementptr ([55 x i8], [55 x i8]* @fmt_summary, i32 0, i32 0), i32 %final_ti, i32 %final_td)
  ret void
}

; ===========================================================
; Main: accepts optional argv[1]=input, argv[2]=output
; ===========================================================

define i32 @main(i32 %argc, i8** %argv) {
entry:
  ; Seed RNG
  %t = call i64 @time(i64* null)
  %t32 = trunc i64 %t to i32
  %seed = or i32 %t32, 1
  call void @rng_seed(i32 %seed)

  ; Determine input path
  %has_input = icmp sgt i32 %argc, 1
  br i1 %has_input, label %get_input, label %use_default_input

get_input:
  %argv1_ptr = getelementptr i8*, i8** %argv, i64 1
  %input_path = load i8*, i8** %argv1_ptr
  br label %get_output

use_default_input:
  %input_path_def = getelementptr [17 x i8], [17 x i8]* @default_input, i32 0, i32 0
  br label %get_output

get_output:
  %in_path = phi i8* [%input_path, %get_input], [%input_path_def, %use_default_input]
  %has_output = icmp sgt i32 %argc, 2
  br i1 %has_output, label %get_out_arg, label %use_default_output

get_out_arg:
  %argv2_ptr = getelementptr i8*, i8** %argv, i64 2
  %output_path = load i8*, i8** %argv2_ptr
  br label %run

use_default_output:
  %output_path_def = getelementptr [26 x i8], [26 x i8]* @default_output, i32 0, i32 0
  br label %run

run:
  %out_path = phi i8* [%output_path, %get_out_arg], [%output_path_def, %use_default_output]
  call void @self_improve(i8* %in_path, i8* %out_path)
  ret i32 0
}
