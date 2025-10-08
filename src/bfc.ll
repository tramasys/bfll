source_filename = "bfll"

/* op fields are kind, reserved, a, b, low excursion, high excursion
   op_add = 1       a is a nonzero delta modulo 256
   op_move = 2      a is a signed nonzero pointer delta
   op_input = 3
   op_output = 4
   op_loop_begin = 5 and op_loop_end = 6 use a for the partner index
   op_clear = 7
   op_scan = 8      a is the signed stride
   op_linear = 9   a and b are the first term and term count
   op_check = 10   a cancelled move retains its bounds obligation
   excursions include zero and every intermediate position of a move run */

%Op = type { i32, i32, i64, i64, i64, i64 }
%LinearTerm = type { i64, i64 }
/* vector fields are data, length, capacity and storage has one element type */
%Vector = type { ptr, i64, i64 }

@parsed = internal global %Vector zeroinitializer, align 8
@optimized = internal global %Vector zeroinitializer, align 8
@terms = internal global %Vector zeroinitializer, align 8
@coefficients = internal global %Vector zeroinitializer, align 8
@stack = internal global %Vector zeroinitializer, align 8
@input.file = internal global ptr null, align 8

@err.usage = private constant [37 x i8] c"usage: bfc [--no-bf-opt] program.bf\0A\00"
@err.open = private constant [33 x i8] c"bfll: unable to open input file\0A\00"
@err.read = private constant [26 x i8] c"bfll: input read failure\0A\00"
@err.memory = private constant [47 x i8] c"bfll: allocation failure or capacity overflow\0A\00"
@err.overflow = private constant [30 x i8] c"bfll: pointer delta overflow\0A\00"
@err.ir = private constant [32 x i8] c"bfll: internal malformed bf ir\0A\00"
@err.open.bracket = private constant [21 x i8] c"bfll: unmatched '['\0A\00"
@err.close.bracket = private constant [21 x i8] c"bfll: unmatched ']'\0A\00"
@err.write = private constant [28 x i8] c"bfll: output write failure\0A\00"
@mode.read = private constant [3 x i8] c"rb\00"
@option.no.opt = private constant [12 x i8] c"--no-bf-opt\00"

@stdout = external global ptr
@stderr = external global ptr

declare ptr @realloc(ptr, i64)
declare void @free(ptr)
declare ptr @fopen(ptr, ptr)
declare i32 @fclose(ptr)
declare i32 @fgetc(ptr)
declare i32 @ferror(ptr)
declare i32 @fflush(ptr)
declare i32 @fputs(ptr, ptr)
declare i32 @fprintf(ptr, ptr, ...)
declare i32 @strcmp(ptr, ptr)
declare void @exit(i32) noreturn
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)

/* callers never retain element pointers across a push into the same vector */
define internal void @vector.reserve(ptr %vector, i64 %element.size) {
entry:
  %length.ptr = getelementptr %Vector, ptr %vector, i64 0, i32 1
  %capacity.ptr = getelementptr %Vector, ptr %vector, i64 0, i32 2
  %length = load i64, ptr %length.ptr, align 8
  %capacity = load i64, ptr %capacity.ptr, align 8
  %room = icmp ult i64 %length, %capacity
  br i1 %room, label %done, label %vector.grow

vector.grow:
  %limit = udiv i64 9223372036854775807, %element.size
  %half.limit = lshr i64 %limit, 1
  %too.large = icmp ugt i64 %capacity, %half.limit
  br i1 %too.large, label %allocation.failed, label %vector.allocate

vector.allocate:
  %empty = icmp eq i64 %capacity, 0
  %doubled = mul i64 %capacity, 2
  %next.capacity = select i1 %empty, i64 32, i64 %doubled
  %bytes = mul i64 %next.capacity, %element.size
  %old.data = load ptr, ptr %vector, align 8
  %new.data = call ptr @realloc(ptr %old.data, i64 %bytes)
  %failed = icmp eq ptr %new.data, null
  br i1 %failed, label %allocation.failed, label %vector.commit

vector.commit:
  store ptr %new.data, ptr %vector, align 8
  store i64 %next.capacity, ptr %capacity.ptr, align 8
  br label %done

allocation.failed:
  call void @die(ptr @err.memory)
  unreachable

done:
  ret void
}

define internal ptr @vector.push.slot(ptr %vector, i64 %element.size) {
entry:
  call void @vector.reserve(ptr %vector, i64 %element.size)
  %data = load ptr, ptr %vector, align 8
  %length.ptr = getelementptr %Vector, ptr %vector, i64 0, i32 1
  %length = load i64, ptr %length.ptr, align 8
  %offset = mul i64 %length, %element.size
  %slot = getelementptr i8, ptr %data, i64 %offset
  %next.length = add i64 %length, 1
  store i64 %next.length, ptr %length.ptr, align 8
  ret ptr %slot
}

define internal i64 @vector.length(ptr %vector) {
entry:
  %length.ptr = getelementptr %Vector, ptr %vector, i64 0, i32 1
  %length = load i64, ptr %length.ptr, align 8
  ret i64 %length
}

define internal void @vector.release(ptr %vector) {
entry:
  %data = load ptr, ptr %vector, align 8
  call void @free(ptr %data)
  store %Vector zeroinitializer, ptr %vector, align 8
  ret void
}

define internal i64 @op.push(ptr %vector, i32 %kind, i64 %a, i64 %b, i64 %low, i64 %high) {
entry:
  %index = call i64 @vector.length(ptr %vector)
  %slot = call ptr @vector.push.slot(ptr %vector, i64 40)
  %with.kind = insertvalue %Op zeroinitializer, i32 %kind, 0
  %with.a = insertvalue %Op %with.kind, i64 %a, 2
  %with.b = insertvalue %Op %with.a, i64 %b, 3
  %with.low = insertvalue %Op %with.b, i64 %low, 4
  %op = insertvalue %Op %with.low, i64 %high, 5
  store %Op %op, ptr %slot, align 8
  ret i64 %index
}

define internal ptr @op.at(ptr %vector, i64 %index) {
entry:
  %length = call i64 @vector.length(ptr %vector)
  %valid = icmp ult i64 %index, %length
  br i1 %valid, label %address, label %malformed

address:
  %data = load ptr, ptr %vector, align 8
  %op = getelementptr %Op, ptr %data, i64 %index
  ret ptr %op

malformed:
  call void @die(ptr @err.ir)
  unreachable
}

define internal void @cleanup() {
entry:
  call void @vector.release(ptr @parsed)
  call void @vector.release(ptr @optimized)
  call void @vector.release(ptr @terms)
  call void @vector.release(ptr @coefficients)
  call void @vector.release(ptr @stack)
  %file = load ptr, ptr @input.file, align 8
  %open = icmp ne ptr %file, null
  br i1 %open, label %close, label %done

close:
  %closed = call i32 @fclose(ptr %file)
  store ptr null, ptr @input.file, align 8
  br label %done

done:
  ret void
}

define internal void @die(ptr %message) noreturn {
entry:
  %error.stream = load ptr, ptr @stderr, align 8
  %written = call i32 @fputs(ptr %message, ptr %error.stream)
  call void @cleanup()
  call void @exit(i32 1)
  unreachable
}

/* the vector has no zero add or move and no adjacent add or move operations
   check records preserve failing excursions even when the net move is zero
   ignored bytes never break a run */
define internal void @parse.append(i32 %kind, i64 %delta) {
entry:
  %length = call i64 @vector.length(ptr @parsed)
  %empty = icmp eq i64 %length, 0
  br i1 %empty, label %append, label %previous

previous:
  %last.index = sub i64 %length, 1
  %last.ptr = call ptr @op.at(ptr @parsed, i64 %last.index)
  %last = load %Op, ptr %last.ptr, align 8
  %last.kind = extractvalue %Op %last, 0
  %same.kind = icmp eq i32 %last.kind, %kind
  %is.move = icmp eq i32 %kind, 2
  %was.check = icmp eq i32 %last.kind, 10
  %move.check = and i1 %is.move, %was.check
  %merge = or i1 %same.kind, %move.check
  br i1 %merge, label %combine, label %append

combine:
  %old.delta = extractvalue %Op %last, 2
  %is.add = icmp eq i32 %kind, 1
  br i1 %is.add, label %combine.add, label %combine.move

combine.add:
  %sum = add i64 %old.delta, %delta
  %wrapped = and i64 %sum, 255
  %zero = icmp eq i64 %wrapped, 0
  br i1 %zero, label %remove.add, label %store.add

remove.add:
  %length.ptr = getelementptr %Vector, ptr @parsed, i64 0, i32 1
  store i64 %last.index, ptr %length.ptr, align 8
  ret void

store.add:
  %updated.add = insertvalue %Op %last, i64 %wrapped, 2
  store %Op %updated.add, ptr %last.ptr, align 8
  ret void

combine.move:
  %addition = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %old.delta, i64 %delta)
  %next.delta = extractvalue { i64, i1 } %addition, 0
  %overflow = extractvalue { i64, i1 } %addition, 1
  br i1 %overflow, label %too.long, label %move.extrema

move.extrema:
  %old.low = extractvalue %Op %last, 4
  %old.high = extractvalue %Op %last, 5
  %lower = icmp slt i64 %next.delta, %old.low
  %higher = icmp sgt i64 %next.delta, %old.high
  %low = select i1 %lower, i64 %next.delta, i64 %old.low
  %high = select i1 %higher, i64 %next.delta, i64 %old.high
  %cancelled = icmp eq i64 %next.delta, 0
  %move.kind = select i1 %cancelled, i32 10, i32 2
  %move.with.kind = insertvalue %Op %last, i32 %move.kind, 0
  %move.with.delta = insertvalue %Op %move.with.kind, i64 %next.delta, 2
  %move.with.low = insertvalue %Op %move.with.delta, i64 %low, 4
  %updated.move = insertvalue %Op %move.with.low, i64 %high, 5
  store %Op %updated.move, ptr %last.ptr, align 8
  ret void

too.long:
  call void @die(ptr @err.overflow)
  unreachable

append:
  %negative = icmp slt i64 %delta, 0
  %initial.low = select i1 %negative, i64 %delta, i64 0
  %initial.high = select i1 %negative, i64 0, i64 %delta
  %add.kind = icmp eq i32 %kind, 1
  %byte.delta = and i64 %delta, 255
  %operand = select i1 %add.kind, i64 %byte.delta, i64 %delta
  %op.low = select i1 %add.kind, i64 0, i64 %initial.low
  %op.high = select i1 %add.kind, i64 0, i64 %initial.high
  %inserted = call i64 @op.push(ptr @parsed, i32 %kind, i64 %operand, i64 0, i64 %op.low, i64 %op.high)
  ret void
}

define internal void @parse(ptr %file) {
entry:
  br label %parse.loop

parse.loop:
  %character = call i32 @fgetc(ptr %file)
  switch i32 %character, label %parse.loop [
    i32 -1, label %parse.eof
    i32 43, label %increment
    i32 45, label %decrement
    i32 62, label %right
    i32 60, label %left
    i32 44, label %input
    i32 46, label %output
    i32 91, label %open
    i32 93, label %close
  ]

increment:
  br label %run

decrement:
  br label %run

right:
  br label %run

left:
  br label %run

run:
  %kind = phi i32 [ 1, %increment ], [ 1, %decrement ], [ 2, %right ], [ 2, %left ]
  %delta = phi i64 [ 1, %increment ], [ -1, %decrement ], [ 1, %right ], [ -1, %left ]
  call void @parse.append(i32 %kind, i64 %delta)
  br label %parse.loop

input:
  br label %single

output:
  br label %single

open:
  br label %single

close:
  br label %single

single:
  %single.kind = phi i32 [ 3, %input ], [ 4, %output ], [ 5, %open ], [ 6, %close ]
  %index = call i64 @op.push(ptr @parsed, i32 %single.kind, i64 0, i64 0, i64 0, i64 0)
  br label %parse.loop

parse.eof:
  %error = call i32 @ferror(ptr %file)
  %failed = icmp ne i32 %error, 0
  br i1 %failed, label %read.failed, label %done

read.failed:
  call void @die(ptr @err.read)
  unreachable

done:
  ret void
}

/* successful matching gives every bracket a partner in both directions */
define internal void @match.brackets(ptr %operations) {
entry:
  %length = call i64 @vector.length(ptr %operations)
  %stack.length.ptr = getelementptr %Vector, ptr @stack, i64 0, i32 1
  store i64 0, ptr %stack.length.ptr, align 8
  br label %bracket.walk

bracket.walk:
  %index = phi i64 [ 0, %entry ], [ %next.index, %bracket.next ]
  %done = icmp eq i64 %index, %length
  br i1 %done, label %bracket.finish, label %bracket.inspect

bracket.inspect:
  %op.ptr = call ptr @op.at(ptr %operations, i64 %index)
  %op = load %Op, ptr %op.ptr, align 8
  %kind = extractvalue %Op %op, 0
  switch i32 %kind, label %bracket.next [
    i32 5, label %bracket.push
    i32 6, label %bracket.pop
  ]

bracket.push:
  %slot = call ptr @vector.push.slot(ptr @stack, i64 8)
  store i64 %index, ptr %slot, align 8
  br label %bracket.next

bracket.pop:
  %depth = load i64, ptr %stack.length.ptr, align 8
  %empty = icmp eq i64 %depth, 0
  br i1 %empty, label %unmatched.close, label %bracket.pair

bracket.pair:
  %next.depth = sub i64 %depth, 1
  store i64 %next.depth, ptr %stack.length.ptr, align 8
  %stack.data = load ptr, ptr @stack, align 8
  %top.ptr = getelementptr i64, ptr %stack.data, i64 %next.depth
  %opening = load i64, ptr %top.ptr, align 8
  %open.ptr = call ptr @op.at(ptr %operations, i64 %opening)
  %open.match = getelementptr %Op, ptr %open.ptr, i64 0, i32 2
  %close.match = getelementptr %Op, ptr %op.ptr, i64 0, i32 2
  store i64 %index, ptr %open.match, align 8
  store i64 %opening, ptr %close.match, align 8
  br label %bracket.next

bracket.next:
  %next.index = add i64 %index, 1
  br label %bracket.walk

bracket.finish:
  %remaining = load i64, ptr %stack.length.ptr, align 8
  %balanced = icmp eq i64 %remaining, 0
  br i1 %balanced, label %valid, label %unmatched.open

unmatched.close:
  call void @die(ptr @err.close.bracket)
  unreachable

unmatched.open:
  call void @die(ptr @err.open.bracket)
  unreachable

valid:
  ret void
}

define i32 @main(i32 %argc, ptr %argv) {
entry:
  %valid.args = icmp eq i32 %argc, 2
  br i1 %valid.args, label %open, label %usage

usage:
  call void @die(ptr @err.usage)
  unreachable

open:
  %filename.ptr = getelementptr ptr, ptr %argv, i64 1
  %filename = load ptr, ptr %filename.ptr, align 8
  %file = call ptr @fopen(ptr %filename, ptr @mode.read)
  %missing = icmp eq ptr %file, null
  br i1 %missing, label %open.failed, label %compile

open.failed:
  call void @die(ptr @err.open)
  unreachable

compile:
  store ptr %file, ptr @input.file, align 8
  call void @parse(ptr %file)
  call void @match.brackets(ptr @parsed)
  call void @cleanup()
  ret i32 0
}
