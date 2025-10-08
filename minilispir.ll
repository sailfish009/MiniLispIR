; ===========================================================
; MiniLispIR v0.0005
; Core Objectives:
; 1) Implement ir-gen / ir-eval: convert MiniLispIR code → LLVM IR and execute
; 2) Integrate adversarial generation and contrastive learning
; 3) Support learning of IR representations within the language
; 4) Long-term goal: Self-Compiling minimal language independent of LLVM IR platform
;
; Current Version:
; - Supports let bindings, display, and numeric evaluation
; - REPL / basic eval is functional
;
; Future Plans:
; - Extend environment structure for multiple variable bindings
; - Add arithmetic operations, conditionals, loops
; - Implement adversarial learning based IR optimization
; - Achieve full LLVM IR independent self-hosting
; ===========================================================


; ---------- 선언 ----------
declare i8* @fopen(i8*, i8*)
declare i32 @fclose(i8*)
declare i32 @fputs(i8*, i8*)
declare i32 @puts(i8*)
declare i8* @malloc(i64)
declare i32 @printf(i8*, ...)
declare i32 @strcmp(i8*, i8*)
declare i32 @atoi(i8*)

@fmt_dbg = private constant [11 x i8] c"token: %s\0A\00"
@fmt_run = private constant [13 x i8] c"display: %s\0A\00"

@str_lparen  = private constant [2 x i8] c"(\00"
@str_rparen  = private constant [2 x i8] c")\00"
@str_let     = private constant [4 x i8] c"let\00"
@str_display = private constant [8 x i8] c"display\00"
@str_x       = private constant [2 x i8] c"x\00"
@str_10      = private constant [3 x i8] c"10\00"

%cell_ty = type { i8*, i8* }

; ---------- cons cell ----------
define i8* @cons(i8* %car, i8* %cdr) {
entry:
  %ptr = call i8* @malloc(i64 16)
  %cell = bitcast i8* %ptr to %cell_ty*
  %carp = getelementptr %cell_ty, %cell_ty* %cell, i32 0, i32 0
  store i8* %car, i8** %carp
  %cdrp = getelementptr %cell_ty, %cell_ty* %cell, i32 0, i32 1
  store i8* %cdr, i8** %cdrp
  ret i8* %ptr
}

define i8* @car(i8* %cell) {
entry:
  %c = bitcast i8* %cell to %cell_ty*
  %p = getelementptr %cell_ty, %cell_ty* %c, i32 0, i32 0
  %v = load i8*, i8** %p
  ret i8* %v
}

define i8* @cdr(i8* %cell) {
entry:
  %c = bitcast i8* %cell to %cell_ty*
  %p = getelementptr %cell_ty, %cell_ty* %c, i32 0, i32 1
  %v = load i8*, i8** %p
  ret i8* %v
}

; ---------- 문자열 생성 ----------
define i8* @make_str(i8* %src, i32 %len) {
entry:
  %size = add i32 %len, 1
  %size64 = zext i32 %size to i64
  %mem = call i8* @malloc(i64 %size64)
  %i = alloca i32, align 4
  store i32 0, i32* %i
  br label %loop
loop:
  %idx = load i32, i32* %i
  %cond = icmp slt i32 %idx, %len
  br i1 %cond, label %body, label %done
body:
  %srcptr = getelementptr i8, i8* %src, i32 %idx
  %val = load i8, i8* %srcptr
  %dstptr = getelementptr i8, i8* %mem, i32 %idx
  store i8 %val, i8* %dstptr
  %nxt = add i32 %idx, 1
  store i32 %nxt, i32* %i
  br label %loop
done:
  %endptr = getelementptr i8, i8* %mem, i32 %len
  store i8 0, i8* %endptr
  ret i8* %mem
}

; ---------- Lexer ----------
define i8* @lexer() {
entry:
  %t0_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0
  %t0 = call i8* @make_str(i8* %t0_ptr, i32 1)
  %t1_ptr = getelementptr inbounds [4 x i8], [4 x i8]* @str_let, i32 0, i32 0
  %t1 = call i8* @make_str(i8* %t1_ptr, i32 3)
  %t2_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0
  %t2 = call i8* @make_str(i8* %t2_ptr, i32 1)
  %t3_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_x, i32 0, i32 0
  %t3 = call i8* @make_str(i8* %t3_ptr, i32 1)
  %t4_ptr = getelementptr inbounds [3 x i8], [3 x i8]* @str_10, i32 0, i32 0
  %t4 = call i8* @make_str(i8* %t4_ptr, i32 2)
  %t5_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0
  %t5 = call i8* @make_str(i8* %t5_ptr, i32 1)
  %t6_ptr = getelementptr inbounds [8 x i8], [8 x i8]* @str_display, i32 0, i32 0
  %t6 = call i8* @make_str(i8* %t6_ptr, i32 7)
  %t7_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_x, i32 0, i32 0
  %t7 = call i8* @make_str(i8* %t7_ptr, i32 1)
  %t8_ptr = getelementptr inbounds [2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0
  %t8 = call i8* @make_str(i8* %t8_ptr, i32 1)
  ; cons 리스트
  %n8 = call i8* @cons(i8* %t8, i8* null)
  %n7 = call i8* @cons(i8* %t7, i8* %n8)
  %n6 = call i8* @cons(i8* %t6, i8* %n7)
  %n5 = call i8* @cons(i8* %t5, i8* %n6)
  %n4 = call i8* @cons(i8* %t4, i8* %n5)
  %n3 = call i8* @cons(i8* %t3, i8* %n4)
  %n2 = call i8* @cons(i8* %t2, i8* %n3)
  %n1 = call i8* @cons(i8* %t1, i8* %n2)
  %n0 = call i8* @cons(i8* %t0, i8* %n1)
  ret i8* %n0
}

; ---------- Eval ----------
define i8* @eval(i8* %tokens, i8* %env) {
entry:
  %is_null = icmp eq i8* %tokens, null
  br i1 %is_null, label %ret_null, label %check_car

check_car:
  %t = call i8* @car(i8* %tokens)
  %cmp_let = call i32 @strcmp(i8* %t, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %cmp_disp = call i32 @strcmp(i8* %t, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %is_let = icmp eq i32 %cmp_let, 0
  %is_disp = icmp eq i32 %cmp_disp, 0
  br i1 %is_let, label %do_let, label %check_disp

do_let:
  %rest_let = call i8* @cdr(i8* %tokens)
  %x_sym = call i8* @car(i8* %rest_let)
  %rest_cdr = call i8* @cdr(i8* %rest_let)
  %val_tok  = call i8* @car(i8* %rest_cdr)
  ; 숫자 -> 문자열 반환
  %val_str = call i8* @make_str(i8* %val_tok, i32 2)
  ret i8* %val_str

check_disp:
  br i1 %is_disp, label %do_disp, label %ret_null

do_disp:
  %rest = call i8* @cdr(i8* %tokens)
  %arg = call i8* @car(i8* %rest)
  call i32 (i8*, ...) @printf(i8* getelementptr ([13 x i8], [13 x i8]* @fmt_run, i32 0, i32 0), i8* %arg)
  ret i8* %arg

ret_null:
  ret i8* null
}

; ---------- REPL ----------
define void @repl() {
entry:                       ; entry 블록: 함수 진입점
  br label %loop             ; 실제 루프는 loop 블록으로

loop:                        ; 반복 루프 블록
  %tokens = call i8* @lexer()
  %res = call i8* @eval(i8* %tokens, i8* null)
  br label %loop             ; 반복
}


; ---------- Display ----------
define void @display(i8* %tokens) {
entry:
  %is_null = icmp eq i8* %tokens, null
  br i1 %is_null, label %done, label %loop

loop:
  %t = call i8* @car(i8* %tokens)
  call i32 (i8*, ...) @printf(i8* getelementptr([11 x i8], [11 x i8]* @fmt_dbg, i32 0, i32 0), i8* %t)
  %next = call i8* @cdr(i8* %tokens)
  call void @display(i8* %next)
  br label %done

done:
  ret void
}

; ---------- Main ----------
define i32 @main() {
entry:
  call void @repl()
  ret i32 0
}

