```llvm
; ===========================================================
; MiniLispIR v0.1 - Self-compiler with vector/graph (let, display, +, compile)
; ===========================================================

; ---------- Declarations ----------
declare i8* @malloc(i64)
declare i8* @realloc(i8*, i64)
declare void @free(i8*)
declare i32 @printf(i8*, ...)
declare i32 @strcmp(i8*, i8*)
declare i32 @atoi(i8*)
declare i32 @strlen(i8*)

@fmt_dbg = private constant [11 x i8] c"token: %s\0A\00"
@fmt_run = private constant [13 x i8] c"display: %s\0A\00"
@fmt_ir = private constant [20 x i8] c"; Generated IR: %s\0A\00"

@str_lparen  = private constant [2 x i8] c"(\00"
@str_rparen  = private constant [2 x i8] c")\00"
@str_let     = private constant [4 x i8] c"let\00"
@str_display = private constant [8 x i8] c"display\00"
@str_plus    = private constant [2 x i8] c"+\00"
@str_compile = private constant [8 x i8] c"compile\00"
@str_x       = private constant [2 x i8] c"x\00"
@str_10      = private constant [3 x i8] c"10\00"
@str_20      = private constant [3 x i8] c"20\00"
@str_list    = private constant [5 x i8] c"list\00"
@str_symbol  = private constant [7 x i8] c"symbol\00"
@str_number  = private constant [7 x i8] c"number\00"
@str_quote   = private constant [6 x i8] c"quote\00"
@str_self_source = private constant [37 x i8] c"(compile '(let x 10 (display x))')\00"

; Vector type: { i64 size, i64 capacity, i8** data }
%vector_ty = type { i64, i64, i8** }

; Node type (Graph for AST): { i8* type, i8* value, %vector_ty* children }
%node_ty = type { i8*, i8*, %vector_ty* }

; ---------- Vector Functions ----------
define %vector_ty* @vector_new() {
entry:
  %vec = call i8* @malloc(i64 24)  ; size + capacity + data
  %vec_ptr = bitcast i8* %vec to %vector_ty*
  %size_ptr = getelementptr %vector_ty, %vector_ty* %vec_ptr, i32 0, i32 0
  store i64 0, i64* %size_ptr
  %cap_ptr = getelementptr %vector_ty, %vector_ty* %vec_ptr, i32 0, i32 1
  store i64 4, i64* %cap_ptr  ; initial capacity
  %data_ptr = getelementptr %vector_ty, %vector_ty* %vec_ptr, i32 0, i32 2
  %data_mem = call i8* @malloc(i64 32)  ; 4 * 8 bytes
  %data_cast = bitcast i8* %data_mem to i8**
  store i8** %data_cast, i8*** %data_ptr
  ret %vector_ty* %vec_ptr
}

define void @vector_push(%vector_ty* %vec, i8* %item) {
entry:
  %size_ptr = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 0
  %size = load i64, i64* %size_ptr
  %cap_ptr = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 1
  %cap = load i64, i64* %cap_ptr
  %need_resize = icmp eq i64 %size, %cap
  br i1 %need_resize, label %resize, label %push

resize:
  %new_cap = mul i64 %cap, 2
  store i64 %new_cap, i64* %cap_ptr
  %data_ptr = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 2
  %data = load i8**, i8*** %data_ptr
  %data_i8 = bitcast i8** %data to i8*
  %new_data_size = mul i64 %new_cap, 8
  %new_data = call i8* @realloc(i8* %data_i8, i64 %new_data_size)
  %new_data_cast = bitcast i8* %new_data to i8**
  store i8** %new_data_cast, i8*** %data_ptr
  br label %push

push:
  %data_ptr2 = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 2
  %data2 = load i8**, i8*** %data_ptr2
  %idx_ptr = getelementptr i8*, i8** %data2, i64 %size
  store i8* %item, i8** %idx_ptr
  %new_size = add i64 %size, 1
  store i64 %new_size, i64* %size_ptr
  ret void
}

define i8* @vector_get(%vector_ty* %vec, i64 %idx) {
entry:
  %data_ptr = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 2
  %data = load i8**, i8*** %data_ptr
  %item_ptr = getelementptr i8*, i8** %data, i64 %idx
  %item = load i8*, i8** %item_ptr
  ret i8* %item
}

define i64 @vector_size(%vector_ty* %vec) {
entry:
  %size_ptr = getelementptr %vector_ty, %vector_ty* %vec, i32 0, i32 0
  %size = load i64, i64* %size_ptr
  ret i64 %size
}

; ---------- Node Functions (Graph for AST) ----------
define %node_ty* @node_new(i8* %type, i8* %value) {
entry:
  %node = call i8* @malloc(i64 24)  ; type + value + children
  %node_ptr = bitcast i8* %node to %node_ty*
  %type_ptr = getelementptr %node_ty, %node_ty* %node_ptr, i32 0, i32 0
  store i8* %type, i8** %type_ptr
  %value_ptr = getelementptr %node_ty, %node_ty* %node_ptr, i32 0, i32 1
  store i8* %value, i8** %value_ptr
  %children = call %vector_ty* @vector_new()
  %children_ptr = getelementptr %node_ty, %node_ty* %node_ptr, i32 0, i32 2
  store %vector_ty* %children, %vector_ty** %children_ptr
  ret %node_ty* %node_ptr
}

define void @node_add_child(%node_ty* %parent, %node_ty* %child) {
entry:
  %children_ptr = getelementptr %node_ty, %node_ty* %parent, i32 0, i32 2
  %children = load %vector_ty*, %vector_ty** %children_ptr
  %child_i8 = bitcast %node_ty* %child to i8*
  call void @vector_push(%vector_ty* %children, i8* %child_i8)
  ret void
}

; ---------- String Copy ----------
define i8* @str_copy(i8* %src) {
entry:
  %len = call i32 @strlen(i8* %src)
  %len64 = zext i32 %len to i64
  %mem = call i8* @malloc(i64 %len64)
  %i = alloca i32
  store i32 0, i32* %i
  br label %loop
loop:
  %idx = load i32, i32* %i
  %cond = icmp slt i32 %idx, %len
  br i1 %cond, label %body, label %done
body:
  %srcp = getelementptr i8, i8* %src, i32 %idx
  %val = load i8, i8* %srcp
  %dstp = getelementptr i8, i8* %mem, i32 %idx
  store i8 %val, i8* %dstp
  %next = add i32 %idx, 1
  store i32 %next, i32* %i
  br label %loop
done:
  ret i8* %mem
}

; ---------- Lexer: Source string -> Vector of tokens ----------
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
  %char_ptr = getelementptr i8, i8* %source, i32 %idx
  %char = load i8, i8* %char_ptr
  ; Skip whitespace
  %is_space = icmp eq i8 %char, 32  ; ' '
  br i1 %is_space, label %next, label %check_paren

check_paren:
  ; Check for '('
  %is_lparen = icmp eq i8 %char, 40  ; '('
  br i1 %is_lparen, label %handle_lparen, label %check_rparen

handle_lparen:
  %lparen = call i8* @str_copy(i8* getelementptr ([2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0))
  call void @vector_push(%vector_ty* %tokens, i8* %lparen)
  br label %next

check_rparen:
  ; Check for ')'
  %is_rparen = icmp eq i8 %char, 41  ; ')'
  br i1 %is_rparen, label %handle_rparen, label %check_quote

handle_rparen:
  %rparen = call i8* @str_copy(i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  call void @vector_push(%vector_ty* %tokens, i8* %rparen)
  br label %next

check_quote:
  ; Check for quote ('')
  %is_quote = icmp eq i8 %char, 39  ; '''
  br i1 %is_quote, label %handle_quote, label %check_ident

handle_quote:
  ; Capture everything until the matching closing quote
  %start_idx = add i32 %idx, 1
  %j = alloca i32
  store i32 %start_idx, i32* %j
  br label %quote_loop

quote_loop:
  %j_idx = load i32, i32* %j
  %j_cond = icmp slt i32 %j_idx, %len
  br i1 %j_cond, label %quote_body, label %quote_error

quote_body:
  %j_char_ptr = getelementptr i8, i8* %source, i32 %j_idx
  %j_char = load i8, i8* %j_char_ptr
  %is_end_quote = icmp eq i8 %j_char, 39  ; '''
  br i1 %is_end_quote, label %quote_done, label %quote_next

quote_next:
  %j_next = add i32 %j_idx, 1
  store i32 %j_next, i32* %j
  br label %quote_loop

quote_done:
  ; Extract substring from start_idx to j_idx
  %quote_len = sub i32 %j_idx, %start_idx
  %quote_len64 = zext i32 %quote_len to i64
  %quote_mem = call i8* @malloc(i64 %quote_len64)
  %k = alloca i32
  store i32 0, i32* %k
  br label %quote_copy

quote_copy:
  %k_idx = load i32, i32* %k
  %k_cond = icmp slt i32 %k_idx, %quote_len
  br i1 %k_cond, label %quote_copy_body, label %quote_copy_done

quote_copy_body:
  %src_idx = add i32 %start_idx, %k_idx
  %src_ptr = getelementptr i8, i8* %source, i32 %src_idx
  %src_char = load i8, i8* %src_ptr
  %dst_ptr = getelementptr i8, i8* %quote_mem, i32 %k_idx
  store i8 %src_char, i8* %dst_ptr
  %k_next = add i32 %k_idx, 1
  store i32 %k_next, i32* %k
  br label %quote_copy

quote_copy_done:
  %quote_end = add i32 %j_idx, 1
  store i32 %quote_end, i32* %i
  %quote_token = call %node_ty* @node_new(i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0), i8* %quote_mem)
  %quote_token_i8 = bitcast %node_ty* %quote_token to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %quote_token_i8)
  br label %next

quote_error:
  ; Placeholder: return empty tokens on error
  ret %vector_ty* %tokens

check_ident:
  ; Check for identifier or number
  %is_digit = icmp sge i8 %char, 48
  %is_digit2 = icmp sle i8 %char, 57
  %is_digit3 = and i1 %is_digit, %is_digit2
  br i1 %is_digit3, label %handle_number, label %handle_ident

handle_number:
  ; Collect digits
  %num_start = load i32, i32* %i
  %n = alloca i32
  store i32 %num_start, i32* %n
  br label %num_loop

num_loop:
  %n_idx = load i32, i32* %n
  %n_cond = icmp slt i32 %n_idx, %len
  br i1 %n_cond, label %num_body, label %num_done

num_body:
  %n_char_ptr = getelementptr i8, i8* %source, i32 %n_idx
  %n_char = load i8, i8* %n_char_ptr
  %n_is_digit = icmp sge i8 %n_char, 48
  %n_is_digit2 = icmp sle i8 %n_char, 57
  %n_is_digit3 = and i1 %n_is_digit, %n_is_digit2
  br i1 %n_is_digit3, label %num_next, label %num_done

num_next:
  %n_next = add i32 %n_idx, 1
  store i32 %n_next, i32* %n
  br label %num_loop

num_done:
  %num_len = sub i32 %n_idx, %num_start
  %num_len64 = zext i32 %num_len to i64
  %num_mem = call i8* @malloc(i64 %num_len64)
  %m = alloca i32
  store i32 0, i32* %m
  br label %num_copy

num_copy:
  %m_idx = load i32, i32* %m
  %m_cond = icmp slt i32 %m_idx, %num_len
  br i1 %m_cond, label %num_copy_body, label %num_copy_done

num_copy_body:
  %src_idx2 = add i32 %num_start, %m_idx
  %src_ptr2 = getelementptr i8, i8* %source, i32 %src_idx2
  %src_char2 = load i8, i8* %src_ptr2
  %dst_ptr2 = getelementptr i8, i8* %num_mem, i32 %m_idx
  store i8 %src_char2, i8* %dst_ptr2
  %m_next = add i32 %m_idx, 1
  store i32 %m_next, i32* %m
  br label %num_copy

num_copy_done:
  store i32 %n_idx, i32* %i
  %num_token = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0), i8* %num_mem)
  %num_token_i8 = bitcast %node_ty* %num_token to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %num_token_i8)
  br label %next

handle_ident:
  ; Collect identifier
  %id_start = load i32, i32* %i
  %p = alloca i32
  store i32 %id_start, i32* %p
  br label %id_loop

id_loop:
  %p_idx = load i32, i32* %p
  %p_cond = icmp slt i32 %p_idx, %len
  br i1 %p_cond, label %id_body, label %id_done

id_body:
  %p_char_ptr = getelementptr i8, i8* %source, i32 %p_idx
  %p_char = load i8, i8* %p_char_ptr
  %p_is_space = icmp eq i8 %p_char, 32
  %p_is_paren = icmp eq i8 %p_char, 40
  %p_is_paren2 = icmp eq i8 %p_char, 41
  %p_is_quote = icmp eq i8 %p_char, 39
  %p_is_delim = or i1 %p_is_space, %p_is_paren
  %p_is_delim2 = or i1 %p_is_delim, %p_is_paren2
  %p_is_delim3 = or i1 %p_is_delim2, %p_is_quote
  br i1 %p_is_delim3, label %id_done, label %id_next

id_next:
  %p_next = add i32 %p_idx, 1
  store i32 %p_next, i32* %p
  br label %id_loop

id_done:
  %id_len = sub i32 %p_idx, %id_start
  %id_len64 = zext i32 %id_len to i64
  %id_mem = call i8* @malloc(i64 %id_len64)
  %q = alloca i32
  store i32 0, i32* %q
  br label %id_copy

id_copy:
  %q_idx = load i32, i32* %q
  %q_cond = icmp slt i32 %q_idx, %id_len
  br i1 %q_cond, label %id_copy_body, label %id_copy_done

id_copy_body:
  %src_idx3 = add i32 %id_start, %q_idx
  %src_ptr3 = getelementptr i8, i8* %source, i32 %src_idx3
  %src_char3 = load i8, i8* %src_ptr3
  %dst_ptr3 = getelementptr i8, i8* %id_mem, i32 %q_idx
  store i8 %src_char3, i8* %dst_ptr3
  %q_next = add i32 %q_idx, 1
  store i32 %q_next, i32* %q
  br label %id_copy

id_copy_done:
  store i32 %p_idx, i32* %i
  %id_token = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0), i8* %id_mem)
  %id_token_i8 = bitcast %node_ty* %id_token to i8*
  call void @vector_push(%vector_ty* %tokens, i8* %id_token_i8)
  br label %next

next:
  %next_idx = add i32 %idx, 1
  store i32 %next_idx, i32* %i
  br label %loop

done:
  ret %vector_ty* %tokens
}

; ---------- Parser: Vector of tokens -> Graph AST ----------
define %node_ty* @parser(%vector_ty* %tokens) {
entry:
  %root = call %node_ty* @node_new(i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0), i8* null)
  %stack = call %vector_ty* @vector_new()
  %root_i8 = bitcast %node_ty* %root to i8*
  call void @vector_push(%vector_ty* %stack, i8* %root_i8)
  %i = alloca i64
  store i64 0, i64* %i
  br label %loop

loop:
  %idx = load i64, i64* %i
  %size = call i64 @vector_size(%vector_ty* %tokens)
  %cond = icmp ult i64 %idx, %size
  br i1 %cond, label %body, label %done

body:
  %tok_i8 = call i8* @vector_get(%vector_ty* %tokens, i64 %idx)
  %tok = bitcast i8* %tok_i8 to %node_ty*
  %tok_type_ptr = getelementptr %node_ty, %node_ty* %tok, i32 0, i32 0
  %tok_type = load i8*, i8** %tok_type_ptr
  %tok_value_ptr = getelementptr %node_ty, %node_ty* %tok, i32 0, i32 1
  %tok_value = load i8*, i8** %tok_value_ptr
  ; Check for '('
  %cmp_lparen = call i32 @strcmp(i8* %tok_type, i8* getelementptr ([2 x i8], [2 x i8]* @str_lparen, i32 0, i32 0))
  %is_lparen = icmp eq i32 %cmp_lparen, 0
  br i1 %is_lparen, label %new_list, label %check_rparen

new_list:
  %new_node = call %node_ty* @node_new(i8* getelementptr ([5 x i8], [5 x i8]* @str_list, i32 0, i32 0), i8* null)
  %top_size = call i64 @vector_size(%vector_ty* %stack)
  %top_idx = sub i64 %top_size, 1
  %top_i8 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx)
  %top = bitcast i8* %top_i8 to %node_ty*
  call void @node_add_child(%node_ty* %top, %node_ty* %new_node)
  %new_i8 = bitcast %node_ty* %new_node to i8*
  call void @vector_push(%vector_ty* %stack, i8* %new_i8)
  br label %next

check_rparen:
  %cmp_rparen = call i32 @strcmp(i8* %tok_type, i8* getelementptr ([2 x i8], [2 x i8]* @str_rparen, i32 0, i32 0))
  %is_rparen = icmp eq i32 %cmp_rparen, 0
  br i1 %is_rparen, label %pop_stack, label %check_keyword

pop_stack:
  %stack_size = call i64 @vector_size(%vector_ty* %stack)
  %new_stack_size = sub i64 %stack_size, 1
  %stack_data_ptr = getelementptr %vector_ty, %vector_ty* %stack, i32 0, i32 0
  store i64 %new_stack_size, i64* %stack_data_ptr
  br label %next

check_keyword:
  ; Check for keywords: let, display, compile, +
  %cmp_let = call i32 @strcmp(i8* %tok_value, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %is_let = icmp eq i32 %cmp_let, 0
  br i1 %is_let, label %add_let, label %check_display

add_let:
  %let_node = call %node_ty* @node_new(i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0), i8* null)
  %top_size2 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx2 = sub i64 %top_size2, 1
  %top_i82 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx2)
  %top2 = bitcast i8* %top_i82 to %node_ty*
  call void @node_add_child(%node_ty* %top2, %node_ty* %let_node)
  br label %next

check_display:
  %cmp_display = call i32 @strcmp(i8* %tok_value, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %is_display = icmp eq i32 %cmp_display, 0
  br i1 %is_display, label %add_display, label %check_plus

add_display:
  %disp_node = call %node_ty* @node_new(i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0), i8* null)
  %top_size3 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx3 = sub i64 %top_size3, 1
  %top_i83 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx3)
  %top3 = bitcast i8* %top_i83 to %node_ty*
  call void @node_add_child(%node_ty* %top3, %node_ty* %disp_node)
  br label %next

check_plus:
  %cmp_plus = call i32 @strcmp(i8* %tok_value, i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0))
  %is_plus = icmp eq i32 %cmp_plus, 0
  br i1 %is_plus, label %add_plus, label %check_compile

add_plus:
  %plus_node = call %node_ty* @node_new(i8* getelementptr ([2 x i8], [2 x i8]* @str_plus, i32 0, i32 0), i8* null)
  %top_size4 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx4 = sub i64 %top_size4, 1
  %top_i84 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx4)
  %top4 = bitcast i8* %top_i84 to %node_ty*
  call void @node_add_child(%node_ty* %top4, %node_ty* %plus_node)
  br label %next

check_compile:
  %cmp_compile = call i32 @strcmp(i8* %tok_value, i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0))
  %is_compile = icmp eq i32 %cmp_compile, 0
  br i1 %is_compile, label %add_compile, label %check_symbol

add_compile:
  %comp_node = call %node_ty* @node_new(i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0), i8* null)
  %top_size5 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx5 = sub i64 %top_size5, 1
  %top_i85 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx5)
  %top5 = bitcast i8* %top_i85 to %node_ty*
  call void @node_add_child(%node_ty* %top5, %node_ty* %comp_node)
  br label %next

check_symbol:
  %cmp_symbol = call i32 @strcmp(i8* %tok_type, i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0))
  %is_symbol = icmp eq i32 %cmp_symbol, 0
  br i1 %is_symbol, label %add_symbol, label %check_number

add_symbol:
  %sym_node = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_symbol, i32 0, i32 0), i8* %tok_value)
  %top_size6 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx6 = sub i64 %top_size6, 1
  %top_i86 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx6)
  %top6 = bitcast i8* %top_i86 to %node_ty*
  call void @node_add_child(%node_ty* %top6, %node_ty* %sym_node)
  br label %next

check_number:
  %cmp_number = call i32 @strcmp(i8* %tok_type, i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0))
  %is_number = icmp eq i32 %cmp_number, 0
  br i1 %is_number, label %add_number, label %check_quote

add_number:
  %num_node = call %node_ty* @node_new(i8* getelementptr ([7 x i8], [7 x i8]* @str_number, i32 0, i32 0), i8* %tok_value)
  %top_size7 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx7 = sub i64 %top_size7, 1
  %top_i87 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx7)
  %top7 = bitcast i8* %top_i87 to %node_ty*
  call void @node_add_child(%node_ty* %top7, %node_ty* %num_node)
  br label %next

check_quote:
  %cmp_quote = call i32 @strcmp(i8* %tok_type, i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0))
  %is_quote = icmp eq i32 %cmp_quote, 0
  br i1 %is_quote, label %add_quote, label %next

add_quote:
  %quote_node = call %node_ty* @node_new(i8* getelementptr ([6 x i8], [6 x i8]* @str_quote, i32 0, i32 0), i8* %tok_value)
  %top_size8 = call i64 @vector_size(%vector_ty* %stack)
  %top_idx8 = sub i64 %top_size8, 1
  %top_i88 = call i8* @vector_get(%vector_ty* %stack, i64 %top_idx8)
  %top8 = bitcast i8* %top_i88 to %node_ty*
  call void @node_add_child(%node_ty* %top8, %node_ty* %quote_node)
  br label %next

next:
  %new_idx = add i64 %idx, 1
  store i64 %new_idx, i64* %i
  br label %loop

done:
  ret %node_ty* %root
}

; ---------- Compiler: Graph AST -> LLVM IR string ----------
define i8* @compiler(%node_ty* %ast) {
entry:
  %ir_str = call i8* @str_copy(i8* getelementptr ([20 x i8], [20 x i8]* @fmt_ir, i32 0, i32 0))  ; placeholder
  ret i8* %ir_str
}

; ---------- Eval: Graph AST evaluation ----------
define i8* @eval(%node_ty* %ast) {
entry:
  %type_ptr = getelementptr %node_ty, %node_ty* %ast, i32 0, i32 0
  %type = load i8*, i8** %type_ptr
  %cmp_let = call i32 @strcmp(i8* %type, i8* getelementptr ([4 x i8], [4 x i8]* @str_let, i32 0, i32 0))
  %is_let = icmp eq i32 %cmp_let, 0
  br i1 %is_let, label %do_let, label %check_disp

do_let:
  ret i8* null  ; placeholder

check_disp:
  %cmp_disp = call i32 @strcmp(i8* %type, i8* getelementptr ([8 x i8], [8 x i8]* @str_display, i32 0, i32 0))
  %is_disp = icmp eq i32 %cmp_disp, 0
  br i1 %is_disp, label %do_disp, label %check_compile

do_disp:
  %children_ptr = getelementptr %node_ty, %node_ty* %ast, i32 0, i32 2
  %children = load %vector_ty*, %vector_ty** %children_ptr
  %arg_node_i8 = call i8* @vector_get(%vector_ty* %children, i64 0)
  %arg_node = bitcast i8* %arg_node_i8 to %node_ty*
  %arg_val_ptr = getelementptr %node_ty, %node_ty* %arg_node, i32 0, i32 1
  %arg = load i8*, i8** %arg_val_ptr
  call i32 (i8*, ...) @printf(i8* getelementptr ([13 x i8], [13 x i8]* @fmt_run, i32 0, i32 0), i8* %arg)
  ret i8* %arg

check_compile:
  %cmp_compile = call i32 @strcmp(i8* %type, i8* getelementptr ([8 x i8], [8 x i8]* @str_compile, i32 0, i32 0))
  %is_compile = icmp eq i32 %cmp_compile, 0
  br i1 %is_compile, label %do_compile, label %ret_null

do_compile:
  %children_ptr_compile = getelementptr %node_ty, %node_ty* %ast, i32 0, i32 2
  %children_compile = load %vector_ty*, %vector_ty** %children_ptr_compile
  %source_node_i8 = call i8* @vector_get(%vector_ty* %children_compile, i64 0)
  %source_node = bitcast i8* %source_node_i8 to %node_ty*
  %source_val_ptr = getelementptr %node_ty, %node_ty* %source_node, i32 0, i32 1
  %source = load i8*, i8** %source_val_ptr
  %tokens = call %vector_ty* @lexer(i8* %source)
  %parsed = call %node_ty* @parser(%vector_ty* %tokens)
  %ir = call i8* @compiler(%node_ty* %parsed)
  call i32 (i8*, ...) @printf(i8* getelementptr ([20 x i8], [20 x i8]* @fmt_ir, i32 0, i32 0), i8* %ir)
  ret i8* %ir

ret_null:
  ret i8* null
}

; ---------- REPL ----------
define void @repl() {
entry:
  br label %loop

loop:
  %source = getelementptr [37 x i8], [37 x i8]* @str_self_source, i32 0, i32 0
  %tokens = call %vector_ty* @lexer(i8* %source)
  %ast = call %node_ty* @parser(%vector_ty* %tokens)
  %res = call i8* @eval(%node_ty* %ast)
  br label %loop
}

; ---------- Main ----------
define i32 @main() {
entry:
  call void @repl()
  ret i32 0
}