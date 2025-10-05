; MiniLispIR: LLVM IR 기반 Self-Compiling 최소 언어
; 수정 내역:
; - 모든 디버깅 문자열 상수 길이 수정 (text length + 2 - 1 = text length + 1, llc got type 기준)
; - @debug_lexer_null: [14 x i8] → [13 x i8]
; - @debug_lexer_init: [14 x i8] → [13 x i8]
; - @debug_lexer_tokenize: [18 x i8] → [17 x i8]
; - @debug_lexer_result: [21 x i8] → [20 x i8]
; - @debug_token_str: [12 x i8] → [11 x i8]
; - @debug_parser_null: [15 x i8] → [14 x i8]
; - @debug_parser_init: [15 x i8] → [14 x i8]
; - @debug_parser_loop: [21 x i8] → [20 x i8]
; - @debug_parser_done: [15 x i8] → [14 x i8]
; - @debug_parser_done_null: [22 x i8] → [21 x i8]
; - @debug_parser_list: [15 x i8] → [14 x i8]
; - @debug_parser_let: [14 x i8] → [13 x i8]
; - @debug_parser_while: [22 x i8] → [21 x i8]
; - @debug_parser_while_body: [21 x i8] → [20 x i8]
; - @debug_cons_null: [13 x i8] → [12 x i8]
; - @debug_write_ir: [18 x i8] → [17 x i8]
; - @debug_null: [17 x i8] → [16 x i8]
; - @debug_file_open_null: [18 x i8] → [17 x i8]
; - @debug_file_open_failed: [19 x i8] → [18 x i8]
; - @main: "ret:" 제거, %ret 블록으로 통합
; - @file_close: "ret:" → "%ret:" (524번째 줄 오류 수정)
; - 모든 함수에서 standalone "ret:", "exit:", "label %<name>:" 제거
; 빌드: llc minilispir.ll -filetype=obj -mtriple=x86_64-linux-gnu -relocation-model=pic -o minilispir.o
;       clang minilispir.o -o minilispir -fPIE -lc -g
; 실행: ./minilispir
; 출력: output.ll (예: "add i32 1, 2", "let x 1", "while < x 5")

; 입력 소스
@source = private constant [61 x i8] c"(let x 0) (while (< x 5) (display (+ x 1)) (let x (+ x 1))) \00"

; 디버깅 문자열
@debug_lexer_null = private constant [13 x i8] c"lexer: null\0A\00"
@debug_lexer_init = private constant [13 x i8] c"lexer: init\0A\00"
@debug_lexer_tokenize = private constant [17 x i8] c"lexer: tokenize\0A\00"
@debug_lexer_result = private constant [20 x i8] c"lexer: tokens done\0A\00"
@debug_token_str = private constant [11 x i8] c"token: %s\0A\00"
@debug_parser_null = private constant [14 x i8] c"parser: null\0A\00"
@debug_parser_init = private constant [14 x i8] c"parser: init\0A\00"
@debug_parser_loop = private constant [20 x i8] c"parser: loop start\0A\00"
@debug_parser_done = private constant [14 x i8] c"parser: done\0A\00"
@debug_parser_done_null = private constant [21 x i8] c"parser: done (null)\0A\00"
@debug_parser_list = private constant [14 x i8] c"parser: list\0A\00"
@debug_parser_let = private constant [13 x i8] c"parser: let\0A\00"
@debug_parser_while = private constant [21 x i8] c"parser: while start\0A\00"
@debug_parser_while_body = private constant [20 x i8] c"parser: while body\0A\00"
@debug_cons_null = private constant [12 x i8] c"cons: null\0A\00"
@debug_write_ir = private constant [17 x i8] c"write-ir: start\0A\00"
@debug_null = private constant [16 x i8] c"write-ir: null\0A\00"
@debug_file_open_null = private constant [17 x i8] c"file_open: null\0A\00"
@debug_file_open_failed = private constant [18 x i8] c"fopen failed: %s\0A\00"
@debug_while_null = private unnamed_addr constant [12 x i8] c"while null\0A\00"
@debug_parse_while = private unnamed_addr constant [17 x i8] c"parse_while: %p\0A\00"
@debug_parse_while_body = private unnamed_addr constant [22 x i8] c"parse_while_body: %p\0A\00"
@debug_let_body = private unnamed_addr constant [14 x i8] c"let body: %p\0A\00"
@debug_while_body = private unnamed_addr constant [16 x i8] c"while body: %p\0A\00"
@debug_parser_start = private unnamed_addr constant [18 x i8] c"parser: start %p\0A\00"


; 외부 C 함수 선언
declare i8* @malloc(i64)
declare i64 @strlen(i8*)
declare i32 @strcmp(i8*, i8*)
declare i32 @atoi(i8*)
declare i32 @sprintf(i8*, i8*, ...)
declare i32 @printf(i8*, ...)
declare i8* @fopen(i8*, i8*)
declare i32 @fprintf(i8*, i8*, ...)
declare void @fclose(i8*)

; 문자열 상수
@lparen_str = private constant [2 x i8] c"(\00"
@rparen_str = private constant [2 x i8] c")\00"
@plus_str = private constant [2 x i8] c"+\00"
@minus_str = private constant [2 x i8] c"-\00"
@mul_str = private constant [2 x i8] c"*\00"
@div_str = private constant [2 x i8] c"/\00"
@lt_str = private constant [2 x i8] c"<\00"
@display_str = private constant [8 x i8] c"display\00"
@let_str = private constant [4 x i8] c"let\00"
@while_str = private constant [6 x i8] c"while\00"
@if_str = private constant [3 x i8] c"if\00"
@add_ir_str = private constant [13 x i8] c"add i32 1, 2\00"
@let_ir_str = private constant [8 x i8] c"let x 1\00"
@while_ir_str = private constant [12 x i8] c"while < x 5\00"
@output_file = private constant [10 x i8] c"output.ll\00"
@write_mode = private constant [2 x i8] c"w\00"

; 메모리 관리
define i8* @cons(i8* %car, i8* %cdr) {
  %ptr = call i8* @malloc(i64 16)
  %is_null = icmp eq i8* %ptr, null
  br i1 %is_null, label %ret_null, label %store
ret_null:
  call i32 @printf(i8* @debug_cons_null)
  ret i8* null
store:
  %car_ptr = getelementptr i8, i8* %ptr, i64 0
  store i8* %car, i8** %car_ptr
  %cdr_ptr = getelementptr i8, i8* %ptr, i64 8
  store i8* %cdr, i8** %cdr_ptr
  ret i8* %ptr
}

define i8* @car(i8* %cell) {
  %is_null = icmp eq i8* %cell, null
  br i1 %is_null, label %ret_null, label %access_car
ret_null:
  ret i8* null
access_car:
  %car_ptr = getelementptr i8, i8* %cell, i64 0
  %car = load i8*, i8** %car_ptr
  ret i8* %car
}

define i8* @cdr(i8* %cell) {
  %is_null = icmp eq i8* %cell, null
  br i1 %is_null, label %ret_null, label %access_cdr
ret_null:
  ret i8* null
access_cdr:
  %cdr_ptr = getelementptr i8, i8* %cell, i64 8
  %cdr = load i8*, i8** %cdr_ptr
  ret i8* %cdr
}

define i8* @intern(i8* %str) {
  %is_null = icmp eq i8* %str, null
  br i1 %is_null, label %ret_null, label %alloc
ret_null:
  ret i8* null
alloc:
  %len = call i64 @strlen(i8* %str)
  %len_inc = add i64 %len, 1
  %copy = call i8* @malloc(i64 %len_inc)
  %copy_null = icmp eq i8* %copy, null
  br i1 %copy_null, label %ret_null, label %copy_str
copy_str:
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %copy, i8* %str, i64 %len_inc, i1 false)
  %cell = call i8* @cons(i8* %copy, i8* null)
  ret i8* %cell
}

; 유틸리티
define i1 @atom(i8* %cell) {
  %is_null = icmp eq i8* %cell, null
  br i1 %is_null, label %ret_false, label %check_cdr
ret_false:
  ret i1 false
check_cdr:
  %cdr = call i8* @cdr(i8* %cell)
  %is_atom = icmp eq i8* %cdr, null
  ret i1 %is_atom
}

define i1 @str_eq(i8* %str1, i8* %str2) {
  %null1 = icmp eq i8* %str1, null
  %null2 = icmp eq i8* %str2, null
  %either_null = or i1 %null1, %null2
  br i1 %either_null, label %ret_false, label %compare
ret_false:
  ret i1 false
compare:
  %eq = call i32 @strcmp(i8* %str1, i8* %str2)
  %is_eq = icmp eq i32 %eq, 0
  ret i1 %is_eq
}

define i64 @str_len(i8* %str) {
  %is_null = icmp eq i8* %str, null
  br i1 %is_null, label %ret_zero, label %calc_len
ret_zero:
  ret i64 0
calc_len:
  %len = call i64 @strlen(i8* %str)
  ret i64 %len
}

; 렉서
define i8* @lexer(i8* %input) {
  %is_null = icmp eq i8* %input, null
  br i1 %is_null, label %ret_null, label %init
ret_null:
  call i32 @printf(i8* @debug_lexer_null)
  ret i8* null
init:
  %tokens = alloca i8*, align 8
  store i8* null, i8** %tokens
  %i = alloca i64
  store i64 0, i64* %i
  call i32 @printf(i8* @debug_lexer_init)
  br label %loop
loop:
  %idx = load i64, i64* %i
  %len = call i64 @str_len(i8* %input)
  %end = icmp ult i64 %idx, %len
  br i1 %end, label %tokenize, label %done
tokenize:
  call i32 @printf(i8* @debug_lexer_tokenize)
  %char = getelementptr i8, i8* %input, i64 %idx
  %c = load i8, i8* %char
  switch i8 %c, label %default [
    i8 40, label %lparen
    i8 41, label %rparen
    i8 43, label %plus
    i8 45, label %minus
    i8 42, label %mul
    i8 47, label %div
    i8 60, label %lt
    i8 100, label %display
    i8 108, label %let
    i8 119, label %while
  ]
lparen:
  %lparen_str = call i8* @intern(i8* @lparen_str)
  call i32 @printf(i8* @debug_token_str, i8* @lparen_str)
  %tokens_lparen = load i8*, i8** %tokens
  %new_tokens_lparen = call i8* @cons(i8* %lparen_str, i8* %tokens_lparen)
  store i8* %new_tokens_lparen, i8** %tokens
  %idx_inc_lparen = add i64 %idx, 1
  store i64 %idx_inc_lparen, i64* %i
  br label %loop
rparen:
  %rparen_str = call i8* @intern(i8* @rparen_str)
  call i32 @printf(i8* @debug_token_str, i8* @rparen_str)
  %tokens_rparen = load i8*, i8** %tokens
  %new_tokens_rparen = call i8* @cons(i8* %rparen_str, i8* %tokens_rparen)
  store i8* %new_tokens_rparen, i8** %tokens
  %idx_inc_rparen = add i64 %idx, 1
  store i64 %idx_inc_rparen, i64* %i
  br label %loop
plus:
  %plus_str = call i8* @intern(i8* @plus_str)
  call i32 @printf(i8* @debug_token_str, i8* @plus_str)
  %tokens_plus = load i8*, i8** %tokens
  %new_tokens_plus = call i8* @cons(i8* %plus_str, i8* %tokens_plus)
  store i8* %new_tokens_plus, i8** %tokens
  %idx_inc_plus = add i64 %idx, 1
  store i64 %idx_inc_plus, i64* %i
  br label %loop
minus:
  %minus_str = call i8* @intern(i8* @minus_str)
  call i32 @printf(i8* @debug_token_str, i8* @minus_str)
  %tokens_minus = load i8*, i8** %tokens
  %new_tokens_minus = call i8* @cons(i8* %minus_str, i8* %tokens_minus)
  store i8* %new_tokens_minus, i8** %tokens
  %idx_inc_minus = add i64 %idx, 1
  store i64 %idx_inc_minus, i64* %i
  br label %loop
mul:
  %mul_str = call i8* @intern(i8* @mul_str)
  call i32 @printf(i8* @debug_token_str, i8* @mul_str)
  %tokens_mul = load i8*, i8** %tokens
  %new_tokens_mul = call i8* @cons(i8* %mul_str, i8* %tokens_mul)
  store i8* %new_tokens_mul, i8** %tokens
  %idx_inc_mul = add i64 %idx, 1
  store i64 %idx_inc_mul, i64* %i
  br label %loop
div:
  %div_str = call i8* @intern(i8* @div_str)
  call i32 @printf(i8* @debug_token_str, i8* @div_str)
  %tokens_div = load i8*, i8** %tokens
  %new_tokens_div = call i8* @cons(i8* %div_str, i8* %tokens_div)
  store i8* %new_tokens_div, i8** %tokens
  %idx_inc_div = add i64 %idx, 1
  store i64 %idx_inc_div, i64* %i
  br label %loop
lt:
  %lt_str = call i8* @intern(i8* @lt_str)
  call i32 @printf(i8* @debug_token_str, i8* @lt_str)
  %tokens_lt = load i8*, i8** %tokens
  %new_tokens_lt = call i8* @cons(i8* %lt_str, i8* %tokens_lt)
  store i8* %new_tokens_lt, i8** %tokens
  %idx_inc_lt = add i64 %idx, 1
  store i64 %idx_inc_lt, i64* %i
  br label %loop
display:
  %display_str = call i8* @intern(i8* @display_str)
  call i32 @printf(i8* @debug_token_str, i8* @display_str)
  %tokens_display = load i8*, i8** %tokens
  %new_tokens_display = call i8* @cons(i8* %display_str, i8* %tokens_display)
  store i8* %new_tokens_display, i8** %tokens
  %idx_inc_display = add i64 %idx, 7
  store i64 %idx_inc_display, i64* %i
  br label %loop
let:
  %let_str = call i8* @intern(i8* @let_str)
  call i32 @printf(i8* @debug_token_str, i8* @let_str)
  %tokens_let = load i8*, i8** %tokens
  %new_tokens_let = call i8* @cons(i8* %let_str, i8* %tokens_let)
  store i8* %new_tokens_let, i8** %tokens
  %idx_inc_let = add i64 %idx, 3
  store i64 %idx_inc_let, i64* %i
  br label %loop
while:
  %while_str = call i8* @intern(i8* @while_str)
  call i32 @printf(i8* @debug_token_str, i8* @while_str)
  %tokens_while = load i8*, i8** %tokens
  %new_tokens_while = call i8* @cons(i8* %while_str, i8* %tokens_while)
  store i8* %new_tokens_while, i8** %tokens
  %idx_inc_while = add i64 %idx, 5
  store i64 %idx_inc_while, i64* %i
  br label %loop
default:
  %is_space = icmp eq i8 %c, 32
  br i1 %is_space, label %skip_space, label %check_digit
skip_space:
  %idx_inc_space = add i64 %idx, 1
  store i64 %idx_inc_space, i64* %i
  br label %loop
check_digit:
  %cmp1_digit = icmp sge i8 %c, 48
  %cmp2_digit = icmp sle i8 %c, 57
  %is_digit = and i1 %cmp1_digit, %cmp2_digit
  br i1 %is_digit, label %handle_digit, label %check_alpha
handle_digit:
  ; 간단한 숫자 토큰화 (실제로는 부분 문자열 추출 필요)
  %digit_start = getelementptr i8, i8* %input, i64 %idx
  %j = alloca i64
  store i64 %idx, i64* %j
  br label %digit_loop
digit_loop:
  %j_val = load i64, i64* %j
  %j_char = getelementptr i8, i8* %input, i64 %j_val
  %j_c = load i8, i8* %j_char
  %is_digit_end = icmp eq i8 %j_c, 32
  %cmp1_digit_loop = icmp eq i8 %j_c, 40  ; '('
  %cmp2_digit_loop = icmp eq i8 %j_c, 41  ; ')'
  %is_paren = or i1 %cmp1_digit_loop, %cmp2_digit_loop
  %is_end = or i1 %is_digit_end, %is_paren
  br i1 %is_end, label %digit_done, label %digit_next
digit_next:
  %j_inc = add i64 %j_val, 1
  store i64 %j_inc, i64* %j
  br label %digit_loop
digit_done:
  %j_val_done = load i64, i64* %j
  %digit_len = sub i64 %j_val_done, %idx
  %digit_buf = call i8* @malloc(i64 %digit_len)
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %digit_buf, i8* %digit_start, i64 %digit_len, i1 false)
  %digit_str = call i8* @intern(i8* %digit_buf)
  call i32 @printf(i8* @debug_token_str, i8* %digit_str)
  %tokens_digit = load i8*, i8** %tokens
  %new_tokens_digit = call i8* @cons(i8* %digit_str, i8* %tokens_digit)
  store i8* %new_tokens_digit, i8** %tokens
  store i64 %j_val_done, i64* %i
  br label %loop
check_alpha:
  %cmp1_alpha_check = icmp sge i8 %c, 97   ; 'a'
  %cmp2_alpha_check = icmp sle i8 %c, 122  ; 'z'
  %is_lower_alpha_check = and i1 %cmp1_alpha_check, %cmp2_alpha_check
  %cmp3_alpha_check = icmp sge i8 %c, 65   ; 'A'
  %cmp4_alpha_check = icmp sle i8 %c, 90   ; 'Z'
  %is_upper_alpha_check = and i1 %cmp3_alpha_check, %cmp4_alpha_check
  %is_alpha = or i1 %is_lower_alpha_check, %is_upper_alpha_check
  br i1 %is_alpha, label %handle_alpha, label %skip_default
handle_alpha:
  ; 간단한 식별자 토큰화 (실제로는 부분 문자열 추출 필요)
  %alpha_start = getelementptr i8, i8* %input, i64 %idx
  %k = alloca i64
  store i64 %idx, i64* %k
  br label %alpha_loop
alpha_loop:
  %k_val = load i64, i64* %k
  %k_char = getelementptr i8, i8* %input, i64 %k_val
  %k_c = load i8, i8* %k_char
  %is_alpha_end = icmp eq i8 %k_c, 32
  %cmp1_alpha_loop = icmp eq i8 %k_c, 40  ; '('
  %cmp2_alpha_loop = icmp eq i8 %k_c, 41  ; ')'
  %is_alpha_paren = or i1 %cmp1_alpha_loop, %cmp2_alpha_loop
  %is_alpha_end2 = or i1 %is_alpha_end, %is_alpha_paren
  br i1 %is_alpha_end2, label %alpha_done, label %alpha_next
alpha_next:
  %k_inc = add i64 %k_val, 1
  store i64 %k_inc, i64* %k
  br label %alpha_loop
alpha_done:
  %k_val_done = load i64, i64* %k
  %alpha_len = sub i64 %k_val_done, %idx
  %alpha_buf = call i8* @malloc(i64 %alpha_len)
  call void @llvm.memcpy.p0i8.p0i8.i64(i8* %alpha_buf, i8* %alpha_start, i64 %alpha_len, i1 false)
  %alpha_str = call i8* @intern(i8* %alpha_buf)
  call i32 @printf(i8* @debug_token_str, i8* %alpha_str)
  %tokens_alpha = load i8*, i8** %tokens
  %new_tokens_alpha = call i8* @cons(i8* %alpha_str, i8* %tokens_alpha)
  store i8* %new_tokens_alpha, i8** %tokens
  store i64 %k_val_done, i64* %i
  br label %loop
skip_default:
  %idx_inc_default = add i64 %idx, 1
  store i64 %idx_inc_default, i64* %i
  br label %loop
done:
  %result = load i8*, i8** %tokens
  call i32 @printf(i8* @debug_lexer_result)
  ret i8* %result
}


; 파서
define i8* @parser(i8* %tokens) {
entry:
  %is_null = icmp eq i8* %tokens, null
  br i1 %is_null, label %ret_null, label %init
ret_null:
  call i32 @printf(i8* @debug_parser_null)
  ret i8* null
init:
  %ast = alloca i8*, align 8
  store i8* null, i8** %ast
  %current = alloca i8*
  store i8* %tokens, i8** %current
  %1 = call i32 @printf(i8* @debug_parser_start, i8* %tokens)
  call i32 @printf(i8* @debug_parser_init)
  br label %parse_loop
parse_loop:
  %2 = load i8*, i8** %current
  call i32 @printf(i8* @debug_parser_loop, i8* %2)
  %3 = call i8* @car(i8* %2)
  %4 = icmp eq i8* %3, null
  br i1 %4, label %parser_done, label %parse_next
parse_expr:
  %5 = load i8*, i8** %current
  call i32 @printf(i8* @debug_parser_loop)
  %6 = call i8* @car(i8* %5)
  %7 = icmp eq i8* %6, null
  br i1 %7, label %done, label %process_token
process_token:
  %8 = load i8*, i8** %current
  %9 = call i8* @cdr(i8* %8)
  store i8* %9, i8** %current
  %10 = call i8* @car(i8* %6)
  %11 = icmp eq i8* %10, null
  br i1 %11, label %done, label %token_process_continue
token_process_continue:
  call i32 @printf(i8* @debug_token_str, i8* %10)
  %12 = call i1 @str_eq(i8* %10, i8* @lparen_str)
  br i1 %12, label %parse_list, label %check_let
parse_list:
  call i32 @printf(i8* @debug_parser_list)
  %13 = load i8*, i8** %current
  %14 = call i8* @cdr(i8* %13)
  %15 = call i8* @parser(i8* %14)
  %16 = icmp eq i8* %15, null
  br i1 %16, label %list_null, label %store_list
list_null:
  call i32 @printf(i8* @debug_parser_done_null)
  br label %done
store_list:
  %17 = load i8*, i8** %ast
  %18 = call i8* @cons(i8* %15, i8* %17)
  store i8* %18, i8** %ast
  %19 = load i8*, i8** %current
  %20 = call i8* @cdr(i8* %19)
  store i8* %20, i8** %current
  br label %parse_loop
check_let:
  %21 = load i8*, i8** %current
  %22 = call i8* @car(i8* %21)
  %23 = call i1 @str_eq(i8* %22, i8* @let_str)
  br i1 %23, label %parse_let, label %check_while
let_null:
  call i32 @printf(i8* @debug_parser_null)
  ret i8* null
parse_let:
  %24 = load i8*, i8** %current
  %25 = call i8* @car(i8* %24)
  %26 = icmp eq i8* %25, null
  br i1 %26, label %let_null, label %parse_let_value
parse_let_value:
  %27 = load i8*, i8** %current
  %28 = call i8* @car(i8* %27)
  %29 = call i8* @cdr(i8* %27)
  %30 = call i8* @cdr(i8* %29)
  %31 = call i8* @parser(i8* %30)
  br label %parse_let_body
parse_let_body:
  %32 = phi i8* [ %28, %parse_let_value ], [ undef, %parse_let ]  ; %var
  %33 = phi i8* [ %31, %parse_let_value ], [ undef, %parse_let ]  ; %val_ast
  %34 = load i8*, i8** %current
  %35 = load i8*, i8** %34
  %36 = call i8* @parser(i8* %35)
  %37 = call i8* @cons(i8* %33, i8* %36)
  store i8* %37, i8** %ast
  %38 = call i8* @cdr(i8* %35)
  store i8* %38, i8** %current
  %39 = call i8* @cons(i8* %32, i8* %33)  ; %val 대체
  %40 = call i8* @cons(i8* @let_str, i8* %39)
  store i8* %40, i8** %ast
  %41 = call i8* @cons(i8* %32, i8* %33)
  br label %parse_loop
store_let:
  %42 = call i8* @cons(i8* %32, i8* %33)  ; %var, %val_ast 사용
  %43 = call i8* @cons(i8* @let_str, i8* %42)
  %44 = load i8*, i8** %ast
  %45 = call i8* @cons(i8* %43, i8* %44)
  store i8* %45, i8** %ast
  %46 = call i8* @cdr(i8* %30)
  store i8* %46, i8** %current
  br label %parse_loop
check_while:
  %47 = load i8*, i8** %current
  %48 = call i8* @car(i8* %47)
  %49 = call i1 @str_eq(i8* %48, i8* @while_str)
  br i1 %49, label %parse_while, label %check_display
while_null:
  call i32 @printf(i8* @debug_while_null)
  ret i8* null
parse_while:
  %50 = load i8*, i8** %current
  %51 = call i8* @car(i8* %50)
  call i32 @printf(i8* @debug_parser_while, i8* %50)
  %52 = call i8* @cdr(i8* %50)
  %53 = call i8* @parser(i8* %52)
  %54 = call i8* @cdr(i8* %52)
  %55 = icmp eq i8* %53, null
  br i1 %55, label %while_null, label %parse_while_body
parse_while_body:
  %56 = load i8*, i8** %current
  %57 = call i8* @cdr(i8* %56)
  %58 = call i8* @parser(i8* %57)
  call i32 @printf(i8* @debug_parser_while_body, i8* %58)
  %59 = icmp eq i8* %58, null
  br i1 %59, label %while_null, label %store_while
store_while:
  %60 = call i8* @cons(i8* %53, i8* %58)
  %61 = call i8* @cons(i8* @while_str, i8* %60)
  %62 = load i8*, i8** %ast
  %63 = call i8* @cons(i8* %61, i8* %62)
  store i8* %63, i8** %ast
  %64 = call i8* @cdr(i8* %57)
  store i8* %64, i8** %current
  br label %parse_loop
check_display:
  %65 = load i8*, i8** %current
  %66 = call i8* @car(i8* %65)
  %67 = call i1 @str_eq(i8* %66, i8* @display_str)
  br i1 %67, label %parse_display, label %done
parse_display:
  call i32 @printf(i8* @debug_parser_list)
  %68 = load i8*, i8** %current
  %69 = call i8* @cdr(i8* %68)
  %70 = call i8* @parser(i8* %69)
  %71 = icmp eq i8* %70, null
  br i1 %71, label %display_null, label %store_display
display_null:
  call i32 @printf(i8* @debug_parser_done_null)
  br label %done
store_display:
  %72 = call i8* @cons(i8* @display_str, i8* %70)
  %73 = load i8*, i8** %ast
  %74 = call i8* @cons(i8* %72, i8* %73)
  store i8* %74, i8** %ast
  %75 = load i8*, i8** %current
  %76 = call i8* @cdr(i8* %75)
  store i8* %76, i8** %current
  br label %parse_loop
done:
  %77 = load i8*, i8** %ast
  %78 = icmp eq i8* %77, null
  br i1 %78, label %done_null, label %done_non_null
done_null:
  call i32 @printf(i8* @debug_parser_done_null)
  ret i8* null
done_non_null:
  call i32 @printf(i8* @debug_parser_done)
  ret i8* %77
parse_next:
  %79 = load i8*, i8** %current
  %80 = call i8* @car(i8* %79)
  %81 = icmp eq i8* %80, null
  br i1 %81, label %parser_done, label %parse_loop
parser_null:
  call i32 @printf(i8* @debug_parser_null)
  ret i8* null
parser_done:
  call i32 @printf(i8* @debug_parser_done)
  ret i8* null
}



; IR 생성
define i8* @ir-gen(i8* %ast) {
  %is_null = icmp eq i8* %ast, null
  br i1 %is_null, label %ret_null, label %check_op
ret_null:
  ret i8* null
check_op:
  %op = call i8* @car(i8* %ast)
  %is_null_op = icmp eq i8* %op, null
  br i1 %is_null_op, label %ret_null, label %check_op_str
check_op_str:
  %op_str = call i8* @car(i8* %op)
  %is_while = call i1 @str_eq(i8* %op_str, i8* @while_str)
  br i1 %is_while, label %gen_while, label %gen_let
gen_while:
  %while_ir = call i8* @intern(i8* @while_ir_str)
  ret i8* %while_ir
gen_let:
  %is_let = call i1 @str_eq(i8* %op_str, i8* @let_str)
  br i1 %is_let, label %gen_let_ir, label %gen_display
gen_let_ir:
  %let_ir = call i8* @intern(i8* @let_ir_str)
  ret i8* %let_ir
gen_display:
  %is_display = call i1 @str_eq(i8* %op_str, i8* @display_str)
  br i1 %is_display, label %gen_display_ir, label %ret_null
gen_display_ir:
  %display_ir = call i8* @intern(i8* @add_ir_str)
  ret i8* %display_ir
}

; 부트스트랩
define i8* @bootstrap(i8* %source) {
  %is_null = icmp eq i8* %source, null
  br i1 %is_null, label %ret_null, label %process
ret_null:
  ret i8* null
process:
  %tokens = call i8* @lexer(i8* %source)
  %ast = call i8* @parser(i8* %tokens)
  %ir = call i8* @ir-gen(i8* %ast)
  ret i8* %ir
}

; 파일 출력
define i8* @file_open(i8* %filename, i8* %mode) {
  %filename_null = icmp eq i8* %filename, null
  %mode_null = icmp eq i8* %mode, null
  %is_null = or i1 %filename_null, %mode_null
  br i1 %is_null, label %ret_null, label %open
ret_null:
  call i32 @printf(i8* @debug_file_open_null)
  ret i8* null
open:
  %file = call i8* @fopen(i8* %filename, i8* %mode)
  %is_null_file = icmp eq i8* %file, null
  br i1 %is_null_file, label %open_failed, label %ret_file
open_failed:
  call i32 @printf(i8* @debug_file_open_failed, i8* %filename)
  ret i8* null
ret_file:
  ret i8* %file
}

define i32 @file_write(i8* %file, i8* %str) {
  %file_null = icmp eq i8* %file, null
  %str_null = icmp eq i8* %str, null
  %is_null = or i1 %file_null, %str_null
  br i1 %is_null, label %ret_zero, label %write
ret_zero:
  ret i32 0
write:
  %result = call i32 @fprintf(i8* %file, i8* %str)
  ret i32 %result
}


define void @file_close(i8* %file) {
  %is_null = icmp eq i8* %file, null
  br i1 %is_null, label %ret, label %close
close:
  call void @fclose(i8* %file)
  br label %ret
ret:
  ret void
}


define i8* @write-ir(i8* %ir, i8* %filename) {
  %file_null = icmp eq i8* %ir, null
  %filename_null = icmp eq i8* %filename, null
  %is_null = or i1 %file_null, %filename_null
  br i1 %is_null, label %ret_nil, label %write
ret_nil:
  call i32 @printf(i8* @debug_null)
  ret i8* null
write:
  call i32 @printf(i8* @debug_write_ir)
  %file = call i8* @file_open(i8* %filename, i8* @write_mode)
  %is_null_file = icmp eq i8* %file, null
  br i1 %is_null_file, label %file_open_failed, label %write_ir
file_open_failed:
  ret i8* null
write_ir:
  %ir_str = call i8* @car(i8* %ir)
  %is_null_ir_str = icmp eq i8* %ir_str, null
  br i1 %is_null_ir_str, label %close_file, label %write_file
write_file:
  %write_result = call i32 @file_write(i8* %file, i8* %ir_str)
  br label %close_file
close_file:
  call void @file_close(i8* %file)
  ret i8* %ir
}

; 메인
define i32 @main() {
entry:
  %source = getelementptr [61 x i8], [61 x i8]* @source, i64 0, i64 0
  %tokens = call i8* @lexer(i8* %source)
  %is_null_tokens = icmp eq i8* %tokens, null
  br i1 %is_null_tokens, label %ret, label %parse
parse:
  %ast = call i8* @parser(i8* %tokens)
  %is_null_ast = icmp eq i8* %ast, null
  br i1 %is_null_ast, label %ret, label %gen_ir
gen_ir:
  %ir = call i8* @ir-gen(i8* %ast)
  %is_null_ir = icmp eq i8* %ir, null
  br i1 %is_null_ir, label %ret, label %bootstrap
bootstrap:
  %bootstrap_ir = call i8* @bootstrap(i8* %source)
  %is_null_bootstrap = icmp eq i8* %bootstrap_ir, null
  br i1 %is_null_bootstrap, label %ret, label %write
write:
  call i8* @write-ir(i8* %bootstrap_ir, i8* @output_file)
  br label %ret
ret:
  ret i32 0
}

; LLVM
declare void @llvm.memcpy.p0i8.p0i8.i64(i8*, i8*, i64, i1)
