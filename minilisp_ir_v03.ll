; ===========================================================
; MiniLispIR v0.3 - Self-Learning Compiler
;
; Architecture:
;   ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
;   │ IR-Gen  │───>│ Registry │───>│ IR-Eval  │───>│ Feedback │
;   │(generate│    │(store IR │    │(execute &│    │(score &  │
;   │ new IR) │<───│ blocks)  │<───│ validate)│<───│ mutate)  │
;   └─────────┘    └──────────┘    └──────────┘    └──────────┘
;
; IR-Gen:  Produces new IR function blocks from templates + mutations
; IR-Eval: Interprets/validates generated IR, produces result + status
; Feedback: Scores results, decides keep/discard/mutate
; Registry: Stores successful IR blocks for reuse as building blocks
;
; No GPU. Pure CPU interpretation of IR blocks as data.
; ===========================================================

; ---------- External Declarations ----------
declare i8* @malloc(i64)
declare i8* @realloc(i8*, i64)
declare void @free(i8*)
declare i32 @printf(i8*, ...)
declare i32 @sprintf(i8*, i8*, ...)
declare i32 @strcmp(i8*, i8*)
declare i32 @atoi(i8*)
declare i32 @strlen(i8*)
declare i8* @memcpy(i8*, i8*, i64)
declare i64 @time(i64*)

; ===========================================================
; String Constants
; ===========================================================

; --- Format strings ---
@fmt_dbg       = private constant [11 x i8] c"token: %s\0A\00"
@fmt_run       = private constant [13 x i8] c"display: %s\0A\00"
@fmt_ir        = private constant [20 x i8] c"; Generated IR: %s\0A\00"
@fmt_int       = private constant [3  x i8] c"%d\00"
@fmt_str       = private constant [3  x i8] c"%s\00"
@fmt_newline   = private constant [2  x i8] c"\0A\00"
@fmt_cycle     = private constant [40 x i8] c"\0A=== Cycle %d / %d ===============\0A\00"
@fmt_gen       = private constant [25 x i8] c"[ir-gen]  function: %s\0A\00"
@fmt_eval      = private constant [25 x i8] c"[ir-eval] result:   %s\0A\00"
@fmt_score     = private constant [25 x i8] c"[score]   value:    %d\0A\00"
@fmt_status    = private constant [25 x i8] c"[status]  %s\0A\00"
@fmt_reg_size  = private constant [30 x i8] c"[registry] size: %d blocks\0A\00"
@fmt_best      = private constant [30 x i8] c"[best]    score=%d  gen=%d\0A\00"
@fmt_mutate    = private constant [30 x i8] c"[mutate]  strategy: %s\0A\00"
@fmt_sep       = private constant [45 x i8] c"-------------------------------------------\0A\00"
@fmt_final     = private constant [50 x i8] c"\0A=== Final Registry: %d successful blocks ===\0A\00"
@fmt_block     = private constant [40 x i8] c"  [%d] score=%d gen=%d name=%s\0A\00"

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
@str_lambda    = private constant [7  x i8] c"lambda\00"
@str_empty     = private constant [1  x i8] c"\00"

; --- Status strings ---
@str_ok        = private constant [3  x i8] c"OK\00"
@str_fail      = private constant [5  x i8] c"FAIL\00"
@str_keep      = private constant [5  x i8] c"KEEP\00"
@str_discard   = private constant [8  x i8] c"DISCARD\00"
@str_mutated   = private constant [8  x i8] c"MUTATED\00"

; --- Mutation strategy names ---
@str_m_grow    = private constant [12 x i8] c"grow-extend\00"
@str_m_swap    = private constant [10 x i8] c"swap-args\00"
@str_m_nest    = private constant [12 x i8] c"nest-deeper\00"
@str_m_chain   = private constant [12 x i8] c"chain-calls\00"
@str_m_arith   = private constant [14 x i8] c"arith-variant\00"

; --- IR template fragments ---
@ir_header     = private constant [45 x i8] c"declare i32 @printf(i8*, ...)\0A\00"
@ir_fmt_decl   = private constant [40 x i8] c"@fmt = constant [4 x i8] c\22%s\0A\00\22\0A\00"
@ir_func_start = private constant [30 x i8] c"define i32 @%s() {\0Aentry:\0A\00"
@ir_func_end   = private constant [5  x i8] c"}\0A\0A\00"
@ir_ret_i32    = private constant [18 x i8] c"  ret i32 %s\0A\00"
@ir_add_inst   = private constant [30 x i8] c"  %%%s = add i32 %s, %s\0A\00"
@ir_sub_inst   = private constant [30 x i8] c"  %%%s = sub i32 %s, %s\0A\00"
@ir_mul_inst   = private constant [30 x i8] c"  %%%s = mul i32 %s, %s\0A\00"
@ir_alloca     = private constant [25 x i8] c"  %%%s = alloca i32\0A\00"
@ir_store      = private constant [30 x i8] c"  store i32 %s, i32* %%%s\0A\00"
@ir_load       = private constant [30 x i8] c"  %%%s = load i32, i32* %%%s\0A\00"
@ir_comment    = private constant [10 x i8] c"  ; %s\0A\00"

; --- Source templates (seed programs for generation) ---
@seed_0 = private constant [12 x i8] c"(+ 10 20)\0A\00"
@seed_1 = private constant [20 x i8] c"(let x 5 (+ x 10))\00"
@seed_2 = private constant [30 x i8] c"(let x 10 (display (+ x 20)))\00"
@seed_3 = private constant [35 x i8] c"(let a 3 (let b 7 (+ a b)))\00"
@seed_4 = private constant [25 x i8] c"(let x 100 (- x 42))\00"
@seed_5 = private constant [30 x i8] c"(let x 6 (* x 7))\00"
@seed_6 = private constant [40 x i8] c"(let a 10 (let b 20 (+ a (+ b 5))))\00"
@seed_7 = private constant [45 x i8] c"(let x 2 (let y 3 (* x (+ y 4))))\00"

; ===========================================================
; Type Definitions
; ===========================================================

; Vector: { i64 size, i64 capacity, i8** data }
%vector_ty = type { i64, i64, i8** }

; AST Node: { i8* type, i8* value, %vector_ty* children }
%node_ty = type { i8*, i8*, %vector_ty* }

; Environment: { i8* name, i8* value, %env_ty* next }
%env_ty = type { i8*, i8*, %env_ty* }

; IR Block descriptor:
; { i8* name, i8* source, i8* ir_text, i32 score, i32 generation, i32 status }
; status: 0=pending, 1=ok, 2=fail
%ir_block_ty = type { i8*, i8*, i8*, i32, i32, i32 }

; Eval result: { i8* value, i32 is_valid, i32 numeric_result }
%eval_result_ty = type { i8*, i32, i32 }

; ===========================================================
; Pseudo-random number generator (xorshift32 state)
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
  ; xorshift32
  %s1 = shl i32 %s, 13
  %s2 = xor i32 %s, %s1
  %s3 = lshr i32 %s2, 17
  %s4 = xor i32 %s2, %s3
  %s5 = shl i32 %s4, 5
  %s6 = xor i32 %s4, %s5
  store i32 %s6, i32* @rng_state
  ; make positive
  %mask = and i32 %s6, 2147483647
  ret i32 %mask
}

; rng_range(lo, hi) -> [lo, hi)
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

define i8* @int_to_str(i32 %val) {
entry:
  %buf = call i8* @malloc(i64 20)
  call i32 (i8*, i8*, ...) @sprintf(i8* %buf, i8* getelementptr ([3 x i8], [3 x i8]* @fmt_int, i32 0, i32 0), i32 %val)
  ret i8* %buf
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
; Environment (linked list)
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
; Lexer (source string -> vector of %node_ty* tokens)
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
; Parser (tokens -> AST)
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

  ; '(' -> push new list
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
  ; Check if symbol is a keyword
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
; Eval: recursive AST evaluation with environment
; Supports: let, display, +, -, *, compile, if, numbers, symbols
; ===========================================================

define i8* @eval_node(%node_ty* %ast, %env_ty* %env) {
entry:
  %type = call i8* @node_type(%node_ty* %ast)
  %value = call i8* @node_value(%node_ty* %ast)

  ; --- number ---
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
  br i1 %fnd, label %ret_looked, label %ret_sym_name

ret_looked:
  ret i8* %looked

ret_sym_name:
  ret i8* %value

ck_quote:
  %cq = call i32 @strcmp(i8* %type, i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0))
  %iq = icmp eq i32 %cq, 0
  br i1 %iq, label %ret_quote, label %ck_list

ret_quote:
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

  ; --- let ---
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

; (if cond then else)
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
  ; check if else branch exists
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

; generic sequence
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
; Codegen: AST -> IR text (string)
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

  ; let
  %gl = call i32 @strcmp(i8* %ft, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %il2 = icmp eq i32 %gl, 0
  br i1 %il2, label %g_let, label %g_ck_disp

g_let:
  %ln = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %lname = call i8* @node_value(%node_ty* %ln)
  %le = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %lev = call i8* @codegen_node(%node_ty* %le)
  %lb = call %node_ty* @node_get_child(%node_ty* %ast, i64 3)
  %lbv = call i8* @codegen_node(%node_ty* %lb)
  ; "  %<n> = alloca i32\n  store i32 <val>, i32* %<n>\n" + body
  %l1 = call i8* @str_copy(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0))
  %l2 = call i8* @str_concat(i8* %l1, i8* getelementptr ([25 x i8], [25 x i8]* @ir_alloca, i32 0, i32 0))
  %l3 = call i8* @str_concat(i8* %l2, i8* %lev)
  %l4 = call i8* @str_concat(i8* %l3, i8* getelementptr ([2 x i8], [2 x i8]* @fmt_newline, i32 0, i32 0))
  %l5 = call i8* @str_concat(i8* %l4, i8* %lbv)
  ret i8* %l5

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
  br i1 %imu, label %g_mul, label %g_ck_comp

g_mul:
  %ull = call %node_ty* @node_get_child(%node_ty* %ast, i64 1)
  %ulv = call i8* @codegen_node(%node_ty* %ull)
  %url = call %node_ty* @node_get_child(%node_ty* %ast, i64 2)
  %urv = call i8* @codegen_node(%node_ty* %url)
  %us = call i8* @str_concat(i8* getelementptr ([30 x i8], [30 x i8]* @ir_mul_inst, i32 0, i32 0), i8* %ulv)
  %us2 = call i8* @str_concat(i8* %us, i8* %urv)
  ret i8* %us2

g_ck_comp:
  %gc = call i32 @strcmp(i8* %ft, i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0))
  %icc = icmp eq i32 %gc, 0
  br i1 %icc, label %g_comp, label %g_seq

g_comp:
  %cir = call i8* @str_copy(i8* getelementptr ([25 x i8], [25 x i8]* @ir_compile_comment, i32 0, i32 0))
  ret i8* %cir

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
  %sc = icmp ult i64 %sv, %sqn
  br i1 %sc, label %sq_bd, label %sq_dn

sq_bd:
  %sch = call %node_ty* @node_get_child(%node_ty* %ast, i64 %sv)
  %scv = call i8* @codegen_node(%node_ty* %sch)
  %prev = load i8*, i8** %sqr
  %cat = call i8* @str_concat(i8* %prev, i8* %scv)
  store i8* %cat, i8** %sqr
  %sni = add i64 %sv, 1
  store i64 %sni, i64* %sqi
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
; IR Block management
; ===========================================================

define %ir_block_ty* @ir_block_new(i8* %name, i8* %source, i32 %generation) {
entry:
  ; struct size: 3 pointers + 3 i32 = 24 + 12 = 36, align to 48
  %m = call i8* @malloc(i64 48)
  %bp = bitcast i8* %m to %ir_block_ty*
  %np = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 0
  store i8* %name, i8** %np
  %sp = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 1
  store i8* %source, i8** %sp
  ; ir_text = null initially
  %ip = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 2
  store i8* null, i8** %ip
  ; score = 0
  %scp = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 3
  store i32 0, i32* %scp
  ; generation
  %gp = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 4
  store i32 %generation, i32* %gp
  ; status = 0 (pending)
  %stp = getelementptr %ir_block_ty, %ir_block_ty* %bp, i32 0, i32 5
  store i32 0, i32* %stp
  ret %ir_block_ty* %bp
}

; ===========================================================
; =================== CORE CYCLE ENGINE ====================
; ===========================================================
;
; ir_gen:    Generate source code (pick seed or mutate existing)
; ir_eval:   Lex -> Parse -> Eval the source, check validity
; ir_score:  Assign a score based on eval result properties
; ir_feedback: Decide keep/discard/mutate based on score
;

; ---------- ir_gen: produce a new source program ----------
; Strategy: pick a seed, optionally mutate based on generation
define i8* @ir_gen(%vector_ty* %registry, i32 %generation) {
entry:
  ; Number of seeds
  %num_seeds = add i32 0, 8

  ; Check if we have successful blocks in registry to build upon
  %reg_sz = call i64 @vector_size(%vector_ty* %registry)
  %has_reg = icmp ugt i64 %reg_sz, 0
  br i1 %has_reg, label %maybe_mutate, label %pick_seed

maybe_mutate:
  ; 50% chance to mutate an existing successful block
  %coin = call i32 @rng_range(i32 0, i32 100)
  %do_mut = icmp slt i32 %coin, 50
  br i1 %do_mut, label %mutate_existing, label %pick_seed

mutate_existing:
  ; Pick a random block from registry
  %reg_sz32 = trunc i64 %reg_sz to i32
  %pick_idx = call i32 @rng_range(i32 0, i32 %reg_sz32)
  %pick_idx64 = zext i32 %pick_idx to i64
  %block_i8 = call i8* @vector_get(%vector_ty* %registry, i64 %pick_idx64)
  %block = bitcast i8* %block_i8 to %ir_block_ty*
  %block_src_ptr = getelementptr %ir_block_ty, %ir_block_ty* %block, i32 0, i32 1
  %block_src = load i8*, i8** %block_src_ptr
  ; Apply a mutation
  %mutated = call i8* @mutate_source(i8* %block_src)
  ; Log mutation strategy
  %strat = call i32 @rng_range(i32 0, i32 5)
  ret i8* %mutated

pick_seed:
  %seed_idx = call i32 @rng_range(i32 0, i32 %num_seeds)

  %c0 = icmp eq i32 %seed_idx, 0
  br i1 %c0, label %s0, label %t1
s0:
  %r0 = call i8* @str_copy(i8* getelementptr ([12 x i8], [12 x i8]* @seed_0, i32 0, i32 0))
  ret i8* %r0
t1:
  %c1 = icmp eq i32 %seed_idx, 1
  br i1 %c1, label %s1, label %t2
s1:
  %r1 = call i8* @str_copy(i8* getelementptr ([20 x i8], [20 x i8]* @seed_1, i32 0, i32 0))
  ret i8* %r1
t2:
  %c2 = icmp eq i32 %seed_idx, 2
  br i1 %c2, label %s2, label %t3
s2:
  %r2 = call i8* @str_copy(i8* getelementptr ([30 x i8], [30 x i8]* @seed_2, i32 0, i32 0))
  ret i8* %r2
t3:
  %c3 = icmp eq i32 %seed_idx, 3
  br i1 %c3, label %s3, label %t4
s3:
  %r3 = call i8* @str_copy(i8* getelementptr ([35 x i8], [35 x i8]* @seed_3, i32 0, i32 0))
  ret i8* %r3
t4:
  %c4 = icmp eq i32 %seed_idx, 4
  br i1 %c4, label %s4, label %t5
s4:
  %r4 = call i8* @str_copy(i8* getelementptr ([25 x i8], [25 x i8]* @seed_4, i32 0, i32 0))
  ret i8* %r4
t5:
  %c5 = icmp eq i32 %seed_idx, 5
  br i1 %c5, label %s5, label %t6
s5:
  %r5 = call i8* @str_copy(i8* getelementptr ([30 x i8], [30 x i8]* @seed_5, i32 0, i32 0))
  ret i8* %r5
t6:
  %c6 = icmp eq i32 %seed_idx, 6
  br i1 %c6, label %s6, label %s7
s6:
  %r6 = call i8* @str_copy(i8* getelementptr ([40 x i8], [40 x i8]* @seed_6, i32 0, i32 0))
  ret i8* %r6
s7:
  %r7 = call i8* @str_copy(i8* getelementptr ([45 x i8], [45 x i8]* @seed_7, i32 0, i32 0))
  ret i8* %r7
}

; ---------- mutate_source: apply random transformation ----------
; Mutations:
;   0: wrap in (let v <rand> <src>) - grow/extend
;   1: wrap in (+ <src> <rand>)     - arithmetic variant
;   2: wrap in (display <src>)      - chain call
;   3: wrap in (* <src> 2)          - scale
;   4: wrap in (- <src> 1)          - decrement
define i8* @mutate_source(i8* %src) {
entry:
  %choice = call i32 @rng_range(i32 0, i32 5)
  %rand_val = call i32 @rng_range(i32 1, i32 100)
  %rand_str = call i8* @int_to_str(i32 %rand_val)

  %c0 = icmp eq i32 %choice, 0
  br i1 %c0, label %m_grow, label %t1

m_grow:
  ; (let v <rand> <src>)
  %g1 = call i8* @str_copy(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0))
  %g2 = call i8* @str_concat(i8* %g1, i8* getelementptr ([7 x i8], [7 x i8]* @str_m_let_pre, i32 0, i32 0))
  %g3 = call i8* @str_concat(i8* %g2, i8* %rand_str)
  %g4 = call i8* @str_concat(i8* %g3, i8* getelementptr ([2 x i8], [2 x i8]* @str_space, i32 0, i32 0))
  %g5 = call i8* @str_concat(i8* %g4, i8* %src)
  %g6 = call i8* @str_concat(i8* %g5, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_mutate, i32 0, i32 0),
    i8* getelementptr ([12 x i8], [12 x i8]* @str_m_grow, i32 0, i32 0))
  ret i8* %g6

t1:
  %c1 = icmp eq i32 %choice, 1
  br i1 %c1, label %m_arith, label %t2

m_arith:
  ; (+ <src> <rand>)
  %a1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_plus_pre, i32 0, i32 0), i8* %src)
  %a2 = call i8* @str_concat(i8* %a1, i8* getelementptr ([2 x i8], [2 x i8]* @str_space, i32 0, i32 0))
  %a3 = call i8* @str_concat(i8* %a2, i8* %rand_str)
  %a4 = call i8* @str_concat(i8* %a3, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_mutate, i32 0, i32 0),
    i8* getelementptr ([14 x i8], [14 x i8]* @str_m_arith, i32 0, i32 0))
  ret i8* %a4

t2:
  %c2 = icmp eq i32 %choice, 2
  br i1 %c2, label %m_chain, label %t3

m_chain:
  ; (display <src>)
  %ch1 = call i8* @str_concat(i8* getelementptr ([10 x i8], [10 x i8]* @str_m_disp_pre, i32 0, i32 0), i8* %src)
  %ch2 = call i8* @str_concat(i8* %ch1, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_mutate, i32 0, i32 0),
    i8* getelementptr ([12 x i8], [12 x i8]* @str_m_chain, i32 0, i32 0))
  ret i8* %ch2

t3:
  %c3 = icmp eq i32 %choice, 3
  br i1 %c3, label %m_scale, label %m_dec

m_scale:
  ; (* <src> 2)
  %sc1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_mul_pre, i32 0, i32 0), i8* %src)
  %sc2 = call i8* @str_concat(i8* %sc1, i8* getelementptr ([4 x i8], [4 x i8]* @str_m_two, i32 0, i32 0))
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_mutate, i32 0, i32 0),
    i8* getelementptr ([12 x i8], [12 x i8]* @str_m_nest, i32 0, i32 0))
  ret i8* %sc2

m_dec:
  ; (- <src> 1)
  %dc1 = call i8* @str_concat(i8* getelementptr ([4 x i8], [4 x i8]* @str_m_sub_pre, i32 0, i32 0), i8* %src)
  %dc2 = call i8* @str_concat(i8* %dc1, i8* getelementptr ([4 x i8], [4 x i8]* @str_m_one, i32 0, i32 0))
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_mutate, i32 0, i32 0),
    i8* getelementptr ([14 x i8], [14 x i8]* @str_m_arith, i32 0, i32 0))
  ret i8* %dc2
}

; Mutation helper strings
@str_space      = private constant [2  x i8] c" \00"
@str_m_let_pre  = private constant [7  x i8] c"(let v \00"
@str_m_plus_pre = private constant [4  x i8] c"(+ \00"
@str_m_sub_pre  = private constant [4  x i8] c"(- \00"
@str_m_mul_pre  = private constant [4  x i8] c"(* \00"
@str_m_disp_pre = private constant [10 x i8] c"(display \00"
@str_m_two      = private constant [4  x i8] c" 2)\00"
@str_m_one      = private constant [4  x i8] c" 1)\00"

@ir_disp_fmt    = private constant [70 x i8] c"  call i32 (i8*, ...) @printf(i8* @fmt, i8* %s)\0A\00"
@ir_compile_comment = private constant [25 x i8] c"  ; compile (self-ref)\0A\00"

; ---------- ir_eval: evaluate a source string, return result + validity ----------
define %eval_result_ty* @ir_eval(i8* %source) {
entry:
  ; Allocate result struct
  %rm = call i8* @malloc(i64 24)
  %rp = bitcast i8* %rm to %eval_result_ty*

  ; Lex
  %tokens = call %vector_ty* @lexer(i8* %source)
  %tok_sz = call i64 @vector_size(%vector_ty* %tokens)
  %has_tok = icmp ugt i64 %tok_sz, 0
  br i1 %has_tok, label %do_parse, label %eval_fail

do_parse:
  ; Parse
  %ast = call %node_ty* @parser(%vector_ty* %tokens)
  %nch = call i64 @node_num_children(%node_ty* %ast)
  %has_ast = icmp ugt i64 %nch, 0
  br i1 %has_ast, label %do_eval, label %eval_fail

do_eval:
  ; Eval
  %env = call %env_ty* @env_new()
  %result = call i8* @eval_node(%node_ty* %ast, %env_ty* %env)

  ; Check if result is non-null
  %is_valid = icmp ne i8* %result, null
  br i1 %is_valid, label %eval_ok, label %eval_fail

eval_ok:
  %vp = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 0
  store i8* %result, i8** %vp
  %ip = getelementptr %eval_result_ty, %eval_result_ty* %rp, i32 0, i32 1
  store i32 1, i32* %ip
  ; Try to convert to numeric
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

; ---------- ir_score: score a result ----------
; Scoring criteria:
;   +10 if valid (eval succeeded)
;   +5  if numeric result != 0 (nontrivial computation)
;   +3  if result > 10 (interesting magnitude)
;   +2  if result is even (structural property)
;   +generation bonus (older successful blocks worth more)
define i32 @ir_score(%eval_result_ty* %result, i32 %generation) {
entry:
  %valid_ptr = getelementptr %eval_result_ty, %eval_result_ty* %result, i32 0, i32 1
  %valid = load i32, i32* %valid_ptr
  %is_valid = icmp eq i32 %valid, 1
  br i1 %is_valid, label %score_valid, label %score_zero

score_valid:
  %score = alloca i32
  store i32 10, i32* %score          ; base score for valid

  %num_ptr = getelementptr %eval_result_ty, %eval_result_ty* %result, i32 0, i32 2
  %num = load i32, i32* %num_ptr

  ; +5 if non-zero
  %nz = icmp ne i32 %num, 0
  br i1 %nz, label %add_nz, label %ck_mag

add_nz:
  %s1 = load i32, i32* %score
  %s2 = add i32 %s1, 5
  store i32 %s2, i32* %score
  br label %ck_mag

ck_mag:
  ; +3 if |result| > 10
  %abs = call i32 @abs_i32(i32 %num)
  %big = icmp sgt i32 %abs, 10
  br i1 %big, label %add_mag, label %ck_even

add_mag:
  %s3 = load i32, i32* %score
  %s4 = add i32 %s3, 3
  store i32 %s4, i32* %score
  br label %ck_even

ck_even:
  ; +2 if even
  %rem = srem i32 %num, 2
  %ev = icmp eq i32 %rem, 0
  br i1 %ev, label %add_even, label %add_gen

add_even:
  %s5 = load i32, i32* %score
  %s6 = add i32 %s5, 2
  store i32 %s6, i32* %score
  br label %add_gen

add_gen:
  ; +generation (rewarding evolution depth)
  %s7 = load i32, i32* %score
  %s8 = add i32 %s7, %generation
  store i32 %s8, i32* %score

  %final = load i32, i32* %score
  ret i32 %final

score_zero:
  ret i32 0
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

; ---------- ir_feedback: decide fate of a block ----------
; Returns: 0=discard, 1=keep, 2=keep+mutate
define i32 @ir_feedback(i32 %score, i32 %generation) {
entry:
  ; Threshold increases with generation (gets harder to pass)
  %threshold = add i32 12, %generation
  %pass = icmp sge i32 %score, %threshold
  br i1 %pass, label %decide_keep, label %decide_discard

decide_keep:
  ; High-scoring blocks get marked for mutation to produce offspring
  %high = icmp sge i32 %score, 20
  br i1 %high, label %keep_mutate, label %keep_only

keep_mutate:
  ret i32 2

keep_only:
  ret i32 1

decide_discard:
  ret i32 0
}

; ===========================================================
; Main Cycle Loop
; ===========================================================

define void @run_cycle(i32 %num_cycles) {
entry:
  %registry = call %vector_ty* @vector_new()   ; successful blocks
  %best_score = alloca i32
  store i32 0, i32* %best_score
  %best_gen = alloca i32
  store i32 0, i32* %best_gen
  %gen = alloca i32
  store i32 0, i32* %gen
  br label %cycle_loop

cycle_loop:
  %g = load i32, i32* %gen
  %cont = icmp slt i32 %g, %num_cycles
  br i1 %cont, label %cycle_body, label %cycle_done

cycle_body:
  ; Print cycle header
  call i32 (i8*, ...) @printf(i8* getelementptr ([40 x i8], [40 x i8]* @fmt_cycle, i32 0, i32 0), i32 %g, i32 %num_cycles)

  ; === IR-GEN ===
  %source = call i8* @ir_gen(%vector_ty* %registry, i32 %g)
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_gen, i32 0, i32 0), i8* %source)

  ; === IR-EVAL ===
  %eval_res = call %eval_result_ty* @ir_eval(i8* %source)
  %val_ptr = getelementptr %eval_result_ty, %eval_result_ty* %eval_res, i32 0, i32 0
  %val = load i8*, i8** %val_ptr
  %valid_ptr = getelementptr %eval_result_ty, %eval_result_ty* %eval_res, i32 0, i32 1
  %valid = load i32, i32* %valid_ptr

  ; Print eval result
  %has_val = icmp ne i8* %val, null
  br i1 %has_val, label %print_val, label %print_fail

print_val:
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_eval, i32 0, i32 0), i8* %val)
  br label %do_score

print_fail:
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_status, i32 0, i32 0),
    i8* getelementptr ([5 x i8], [5 x i8]* @str_fail, i32 0, i32 0))
  br label %do_score

do_score:
  ; === SCORE ===
  %score = call i32 @ir_score(%eval_result_ty* %eval_res, i32 %g)
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_score, i32 0, i32 0), i32 %score)

  ; === FEEDBACK ===
  %decision = call i32 @ir_feedback(i32 %score, i32 %g)

  ; Handle decision
  %is_keep = icmp sge i32 %decision, 1
  br i1 %is_keep, label %do_keep, label %do_discard

do_keep:
  ; Create block and add to registry
  %fname = call i8* @str_concat(i8* getelementptr ([1 x i8], [1 x i8]* @str_empty, i32 0, i32 0), i8* %source)
  %block = call %ir_block_ty* @ir_block_new(i8* %fname, i8* %source, i32 %g)
  ; Set score
  %bsp = getelementptr %ir_block_ty, %ir_block_ty* %block, i32 0, i32 3
  store i32 %score, i32* %bsp
  ; Set status = 1 (ok)
  %bstp = getelementptr %ir_block_ty, %ir_block_ty* %block, i32 0, i32 5
  store i32 1, i32* %bstp
  ; Also generate IR text
  %tok2 = call %vector_ty* @lexer(i8* %source)
  %ast2 = call %node_ty* @parser(%vector_ty* %tok2)
  %ir_text = call i8* @codegen_node(%node_ty* %ast2)
  %bitp = getelementptr %ir_block_ty, %ir_block_ty* %block, i32 0, i32 2
  store i8* %ir_text, i8** %bitp
  ; Push to registry
  %bi = bitcast %ir_block_ty* %block to i8*
  call void @vector_push(%vector_ty* %registry, i8* %bi)

  ; Print status
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_status, i32 0, i32 0),
    i8* getelementptr ([5 x i8], [5 x i8]* @str_keep, i32 0, i32 0))

  ; Update best
  %cur_best = load i32, i32* %best_score
  %is_better = icmp sgt i32 %score, %cur_best
  br i1 %is_better, label %update_best, label %after_keep

update_best:
  store i32 %score, i32* %best_score
  store i32 %g, i32* %best_gen
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_best, i32 0, i32 0), i32 %score, i32 %g)
  br label %after_keep

after_keep:
  br label %next_cycle

do_discard:
  call i32 (i8*, ...) @printf(i8* getelementptr ([25 x i8], [25 x i8]* @fmt_status, i32 0, i32 0),
    i8* getelementptr ([8 x i8], [8 x i8]* @str_discard, i32 0, i32 0))
  br label %next_cycle

next_cycle:
  ; Print separator
  call i32 (i8*, ...) @printf(i8* getelementptr ([45 x i8], [45 x i8]* @fmt_sep, i32 0, i32 0))

  %ng = add i32 %g, 1
  store i32 %ng, i32* %gen
  br label %cycle_loop

cycle_done:
  ; === Final report ===
  %final_sz = call i64 @vector_size(%vector_ty* %registry)
  %final_sz32 = trunc i64 %final_sz to i32
  call i32 (i8*, ...) @printf(i8* getelementptr ([50 x i8], [50 x i8]* @fmt_final, i32 0, i32 0), i32 %final_sz32)

  ; Print each block
  %ri = alloca i64
  store i64 0, i64* %ri
  br label %report_loop

report_loop:
  %rv = load i64, i64* %ri
  %rc = icmp ult i64 %rv, %final_sz
  br i1 %rc, label %report_body, label %report_done

report_body:
  %rbi = call i8* @vector_get(%vector_ty* %registry, i64 %rv)
  %rb = bitcast i8* %rbi to %ir_block_ty*
  %rb_name_ptr = getelementptr %ir_block_ty, %ir_block_ty* %rb, i32 0, i32 0
  %rb_name = load i8*, i8** %rb_name_ptr
  %rb_score_ptr = getelementptr %ir_block_ty, %ir_block_ty* %rb, i32 0, i32 3
  %rb_score = load i32, i32* %rb_score_ptr
  %rb_gen_ptr = getelementptr %ir_block_ty, %ir_block_ty* %rb, i32 0, i32 4
  %rb_gen = load i32, i32* %rb_gen_ptr
  %rv32 = trunc i64 %rv to i32
  call i32 (i8*, ...) @printf(i8* getelementptr ([40 x i8], [40 x i8]* @fmt_block, i32 0, i32 0),
    i32 %rv32, i32 %rb_score, i32 %rb_gen, i8* %rb_name)

  %rni = add i64 %rv, 1
  store i64 %rni, i64* %ri
  br label %report_loop

report_done:
  ; Print best overall
  %fb = load i32, i32* %best_score
  %fg = load i32, i32* %best_gen
  call i32 (i8*, ...) @printf(i8* getelementptr ([30 x i8], [30 x i8]* @fmt_best, i32 0, i32 0), i32 %fb, i32 %fg)
  ret void
}

; ===========================================================
; Main Entry Point
; ===========================================================

define i32 @main() {
entry:
  ; Seed RNG from time
  %t = call i64 @time(i64* null)
  %t32 = trunc i64 %t to i32
  ; Ensure non-zero seed
  %seed = or i32 %t32, 1
  call void @rng_seed(i32 %seed)

  ; Run 20 cycles of ir-gen / ir-eval / feedback
  call void @run_cycle(i32 20)

  ret i32 0
}
