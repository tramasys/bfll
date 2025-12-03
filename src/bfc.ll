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
declare i64 @fwrite(ptr, i64, i64, ptr)
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

/* use recorded partners rather than searching a loop body */
define internal i64 @loop.partner(ptr %operations, i64 %index) {
entry:
  %op.ptr = call ptr @op.at(ptr %operations, i64 %index)
  %op = load %Op, ptr %op.ptr, align 8
  %kind = extractvalue %Op %op, 0
  %partner = extractvalue %Op %op, 2
  %other.ptr = call ptr @op.at(ptr %operations, i64 %partner)
  %other = load %Op, ptr %other.ptr, align 8
  %other.kind = extractvalue %Op %other, 0
  %backlink = extractvalue %Op %other, 2
  %is.open = icmp eq i32 %kind, 5
  %is.close = icmp eq i32 %kind, 6
  %is.loop = or i1 %is.open, %is.close
  %expected = select i1 %is.open, i32 6, i32 5
  %kind.valid = icmp eq i32 %other.kind, %expected
  %link.valid = icmp eq i64 %backlink, %index
  %forward = icmp ugt i64 %partner, %index
  %backward = icmp ult i64 %partner, %index
  %direction.valid = select i1 %is.open, i1 %forward, i1 %backward
  %valid.pair = and i1 %kind.valid, %link.valid
  %valid.direction = and i1 %is.loop, %direction.valid
  %valid = and i1 %valid.pair, %valid.direction
  br i1 %valid, label %done, label %malformed

malformed:
  call void @die(ptr @err.ir)
  unreachable

done:
  ret i64 %partner
}

define internal i1 @try.simple.loop(i64 %opening, i64 %closing) {
entry:
  %body.index = add i64 %opening, 1
  %after.single = add i64 %body.index, 1
  %single = icmp eq i64 %after.single, %closing
  br i1 %single, label %inspect, label %reject

inspect:
  %body.ptr = call ptr @op.at(ptr @parsed, i64 %body.index)
  %body = load %Op, ptr %body.ptr, align 8
  %kind = extractvalue %Op %body, 0
  %delta = extractvalue %Op %body, 2
  %low = extractvalue %Op %body, 4
  %high = extractvalue %Op %body, 5
  switch i32 %kind, label %reject [
    i32 1, label %clear.test
    i32 2, label %scan.accept
  ]

clear.test:
  /* precisely the odd deltas are invertible modulo 256 */
  %odd.bit = and i64 %delta, 1
  %odd = icmp ne i64 %odd.bit, 0
  br i1 %odd, label %clear.accept, label %reject

clear.accept:
  %clear.index = call i64 @op.push(ptr @optimized, i32 7, i64 0, i64 0, i64 0, i64 0)
  ret i1 true

scan.accept:
  %scan.index = call i64 @op.push(ptr @optimized, i32 8, i64 %delta, i64 0, i64 %low, i64 %high)
  ret i1 true

reject:
  ret i1 false
}

/* small loop bodies justify linear lookup in a reusable coefficient vector */
define internal void @coefficient.add(i64 %offset, i64 %delta) {
entry:
  %length = call i64 @vector.length(ptr @coefficients)
  %data = load ptr, ptr @coefficients, align 8
  br label %coefficient.search

coefficient.search:
  %index = phi i64 [ 0, %entry ], [ %next.index, %coefficient.next ]
  %done = icmp eq i64 %index, %length
  br i1 %done, label %coefficient.append, label %coefficient.inspect

coefficient.inspect:
  %term.ptr = getelementptr %LinearTerm, ptr %data, i64 %index
  %stored.offset = load i64, ptr %term.ptr, align 8
  %found = icmp eq i64 %stored.offset, %offset
  br i1 %found, label %coefficient.update, label %coefficient.next

coefficient.next:
  %next.index = add i64 %index, 1
  br label %coefficient.search

coefficient.update:
  %value.ptr = getelementptr %LinearTerm, ptr %term.ptr, i64 0, i32 1
  %old = load i64, ptr %value.ptr, align 8
  %sum = add i64 %old, %delta
  %wrapped = and i64 %sum, 255
  store i64 %wrapped, ptr %value.ptr, align 8
  ret void

coefficient.append:
  call void @term.push(ptr @coefficients, i64 %offset, i64 %delta)
  ret void
}

define internal void @term.push(ptr %vector, i64 %offset, i64 %factor) {
entry:
  %slot = call ptr @vector.push.slot(ptr %vector, i64 16)
  %with.offset = insertvalue %LinearTerm zeroinitializer, i64 %offset, 0
  %term = insertvalue %LinearTerm %with.offset, i64 %factor, 1
  store %LinearTerm %term, ptr %slot, align 8
  ret void
}

define internal i64 @coefficient.get(i64 %offset) {
entry:
  %length = call i64 @vector.length(ptr @coefficients)
  %data = load ptr, ptr @coefficients, align 8
  br label %search

search:
  %index = phi i64 [ 0, %entry ], [ %next.index, %next ]
  %done = icmp eq i64 %index, %length
  br i1 %done, label %absent, label %inspect

inspect:
  %term.ptr = getelementptr %LinearTerm, ptr %data, i64 %index
  %term = load %LinearTerm, ptr %term.ptr, align 8
  %stored.offset = extractvalue %LinearTerm %term, 0
  %found = icmp eq i64 %stored.offset, %offset
  br i1 %found, label %present, label %next

next:
  %next.index = add i64 %index, 1
  br label %search

present:
  %coefficient = extractvalue %LinearTerm %term, 1
  ret i64 %coefficient

absent:
  ret i64 0
}

/* extended euclid tracks the coefficient of delta in each remainder */
define internal i64 @inverse256(i64 %delta) {
entry:
  br label %euclid.loop

euclid.loop:
  %old.remainder = phi i64 [ 256, %entry ], [ %remainder, %euclid.step ]
  %remainder = phi i64 [ %delta, %entry ], [ %next.remainder, %euclid.step ]
  %old.coefficient = phi i64 [ 0, %entry ], [ %coefficient, %euclid.step ]
  %coefficient = phi i64 [ 1, %entry ], [ %next.coefficient, %euclid.step ]
  %done = icmp eq i64 %remainder, 0
  br i1 %done, label %euclid.finish, label %euclid.step

euclid.step:
  %quotient = sdiv i64 %old.remainder, %remainder
  %remainder.product = mul i64 %quotient, %remainder
  %next.remainder = sub i64 %old.remainder, %remainder.product
  %coefficient.product = mul i64 %quotient, %coefficient
  %next.coefficient = sub i64 %old.coefficient, %coefficient.product
  br label %euclid.loop

euclid.finish:
  %invertible = icmp eq i64 %old.remainder, 1
  br i1 %invertible, label %normalize, label %malformed

normalize:
  %inverse = and i64 %old.coefficient, 255
  ret i64 %inverse

malformed:
  call void @die(ptr @err.ir)
  unreachable
}

/* relative position starts and ends at zero and all coefficients wrap to bytes
   only add and move bodies qualify and the source coefficient must be odd
   check is the bounds metadata left by a cancelled move */
define internal i1 @try.linear.loop(i64 %opening, i64 %closing) {
entry:
  %scratch.length = getelementptr %Vector, ptr @coefficients, i64 0, i32 1
  store i64 0, ptr %scratch.length, align 8
  %body.start = add i64 %opening, 1
  br label %linear.walk

linear.walk:
  %index = phi i64 [ %body.start, %entry ], [ %next.index, %linear.next ]
  %relative.ptr = phi i64 [ 0, %entry ], [ %next.relative, %linear.next ]
  %low = phi i64 [ 0, %entry ], [ %next.low, %linear.next ]
  %high = phi i64 [ 0, %entry ], [ %next.high, %linear.next ]
  %done = icmp eq i64 %index, %closing
  br i1 %done, label %linear.test, label %linear.inspect

linear.inspect:
  %op.ptr = call ptr @op.at(ptr @parsed, i64 %index)
  %op = load %Op, ptr %op.ptr, align 8
  %kind = extractvalue %Op %op, 0
  %delta = extractvalue %Op %op, 2
  switch i32 %kind, label %linear.reject [
    i32 1, label %linear.add
    i32 2, label %linear.move
    i32 10, label %linear.move
  ]

linear.add:
  call void @coefficient.add(i64 %relative.ptr, i64 %delta)
  br label %linear.next

linear.move:
  %run.low = extractvalue %Op %op, 4
  %run.high = extractvalue %Op %op, 5
  %move.sum = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %relative.ptr, i64 %delta)
  %low.sum = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %relative.ptr, i64 %run.low)
  %high.sum = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %relative.ptr, i64 %run.high)
  %moved = extractvalue { i64, i1 } %move.sum, 0
  %moved.low = extractvalue { i64, i1 } %low.sum, 0
  %moved.high = extractvalue { i64, i1 } %high.sum, 0
  %move.overflow = extractvalue { i64, i1 } %move.sum, 1
  %low.overflow = extractvalue { i64, i1 } %low.sum, 1
  %high.overflow = extractvalue { i64, i1 } %high.sum, 1
  %extrema.overflow = or i1 %low.overflow, %high.overflow
  %overflow = or i1 %extrema.overflow, %move.overflow
  br i1 %overflow, label %linear.reject, label %linear.move.safe

linear.move.safe:
  %lower = icmp slt i64 %moved.low, %low
  %higher = icmp sgt i64 %moved.high, %high
  %merged.low = select i1 %lower, i64 %moved.low, i64 %low
  %merged.high = select i1 %higher, i64 %moved.high, i64 %high
  br label %linear.next

linear.next:
  %next.relative = phi i64 [ %relative.ptr, %linear.add ], [ %moved, %linear.move.safe ]
  %next.low = phi i64 [ %low, %linear.add ], [ %merged.low, %linear.move.safe ]
  %next.high = phi i64 [ %high, %linear.add ], [ %merged.high, %linear.move.safe ]
  %next.index = add i64 %index, 1
  br label %linear.walk

linear.test:
  %returns = icmp eq i64 %relative.ptr, 0
  %source.delta = call i64 @coefficient.get(i64 0)
  %odd.bit = and i64 %source.delta, 1
  %odd = icmp eq i64 %odd.bit, 1
  %eligible = and i1 %returns, %odd
  br i1 %eligible, label %linear.accept, label %linear.reject

linear.accept:
  %inverse = call i64 @inverse256(i64 %source.delta)
  %negative.inverse = sub i64 0, %inverse
  %first.term = call i64 @vector.length(ptr @terms)
  %coefficient.count = call i64 @vector.length(ptr @coefficients)
  %coefficient.data = load ptr, ptr @coefficients, align 8
  br label %linear.terms

linear.terms:
  %term.index = phi i64 [ 0, %linear.accept ], [ %next.term, %linear.term.next ]
  %terms.done = icmp eq i64 %term.index, %coefficient.count
  br i1 %terms.done, label %linear.finish, label %linear.term.inspect

linear.term.inspect:
  %term.ptr = getelementptr %LinearTerm, ptr %coefficient.data, i64 %term.index
  %term = load %LinearTerm, ptr %term.ptr, align 8
  %offset = extractvalue %LinearTerm %term, 0
  %coefficient = extractvalue %LinearTerm %term, 1
  %product = mul i64 %negative.inverse, %coefficient
  %factor = and i64 %product, 255
  %source = icmp eq i64 %offset, 0
  %cancelled = icmp eq i64 %factor, 0
  %omit = or i1 %source, %cancelled
  br i1 %omit, label %linear.term.next, label %linear.term.append

linear.term.append:
  call void @term.push(ptr @terms, i64 %offset, i64 %factor)
  br label %linear.term.next

linear.term.next:
  %next.term = add i64 %term.index, 1
  br label %linear.terms

linear.finish:
  %arena.length = call i64 @vector.length(ptr @terms)
  %term.count = sub i64 %arena.length, %first.term
  %linear.index = call i64 @op.push(ptr @optimized, i32 9, i64 %first.term, i64 %term.count, i64 %low, i64 %high)
  ret i1 true

linear.reject:
  ret i1 false
}

/* a flat walk enters preserved bodies naturally without using the call stack
   accepted loops skip their entire range and a final stack pass patches copies */
define internal void @optimize() {
entry:
  %length = call i64 @vector.length(ptr @parsed)
  br label %optimize.walk

optimize.walk:
  %index = phi i64 [ 0, %entry ], [ %next.index, %copy ], [ %after.loop, %accepted ]
  %done = icmp eq i64 %index, %length
  br i1 %done, label %optimize.finish, label %inspect

inspect:
  %op.ptr = call ptr @op.at(ptr @parsed, i64 %index)
  %op = load %Op, ptr %op.ptr, align 8
  %kind = extractvalue %Op %op, 0
  %is.open = icmp eq i32 %kind, 5
  br i1 %is.open, label %analyze, label %copy

analyze:
  %closing = call i64 @loop.partner(ptr @parsed, i64 %index)
  %simple = call i1 @try.simple.loop(i64 %index, i64 %closing)
  br i1 %simple, label %accepted, label %analyze.linear

analyze.linear:
  %linear = call i1 @try.linear.loop(i64 %index, i64 %closing)
  br i1 %linear, label %accepted, label %copy

accepted:
  %after.loop = add i64 %closing, 1
  br label %optimize.walk

copy:
  %slot = call ptr @vector.push.slot(ptr @optimized, i64 40)
  store %Op %op, ptr %slot, align 8
  %next.index = add i64 %index, 1
  br label %optimize.walk

optimize.finish:
  call void @match.brackets(ptr @optimized)
  ret void
}

@format.i64 = private constant [5 x i8] c"%lld\00"

@ir.header = private constant [1367 x i8] c"source_filename = \22brainfuck\22

@stderr = external global ptr
@stdout = external global ptr
@bounds.message = private constant [25 x i8] c\22bfll: tape bounds error\5C0A\5C00\22
@memory.message = private constant [26 x i8] c\22bfll: allocation failure\5C0A\5C00\22
@io.message = private constant [28 x i8] c\22bfll: output write failure\5C0A\5C00\22

declare ptr @calloc(i64, i64)
declare void @free(ptr)
declare i32 @getchar()
declare i32 @putchar(i32)
declare i32 @fputs(ptr, ptr)
declare i32 @fflush(ptr)
declare i32 @ferror(ptr)

/* compare offsets before adding to avoid signed overflow */
define internal i1 @bf.valid(i64 %index, i64 %low, i64 %high) {
entry:
  %lower.limit = sub i64 0, %index
  %upper.limit = sub i64 29999, %index
  %low.valid = icmp sge i64 %low, %lower.limit
  %high.valid = icmp sle i64 %high, %upper.limit
  %valid = and i1 %low.valid, %high.valid
  ret i1 %valid
}

define internal i32 @bf.fail(ptr %tape, ptr %message) {
entry:
  %error.stream = load ptr, ptr @stderr, align 8
  %reported = call i32 @fputs(ptr %message, ptr %error.stream)
  call void @free(ptr %tape)
  ret i32 1
}

define i32 @main() {
entry:
  %data_index = alloca i64, align 8
  store i64 0, ptr %data_index, align 8
  %tape = call ptr @calloc(i64 30000, i64 1)
  %allocation.failed = icmp eq ptr %tape, null
  br i1 %allocation.failed, label %bf.memory.error, label %bf.start

bf.start:
\00"

@ir.footer = private constant [771 x i8] c"  br label %bf.done

bf.done:
  %output.stream = load ptr, ptr @stdout, align 8
  %flush.status = call i32 @fflush(ptr %output.stream)
  %output.status = call i32 @ferror(ptr %output.stream)
  %flush.failed = icmp ne i32 %flush.status, 0
  %output.failed = icmp ne i32 %output.status, 0
  %io.failed = or i1 %flush.failed, %output.failed
  br i1 %io.failed, label %bf.io.error, label %bf.return

bf.return:
  call void @free(ptr %tape)
  ret i32 0

bf.bounds.error:
  %bounds.status = call i32 @bf.fail(ptr %tape, ptr @bounds.message)
  ret i32 %bounds.status

bf.memory.error:
  %memory.status = call i32 @bf.fail(ptr %tape, ptr @memory.message)
  ret i32 %memory.status

bf.io.error:
  %io.status = call i32 @bf.fail(ptr %tape, ptr @io.message)
  ret i32 %io.status
}
\00"

@ir.address = private constant [106 x i8] c"  %index.$i = load i64, ptr %data_index, align 8
  %cell.$i = getelementptr i8, ptr %tape, i64 %index.$i
\00"

@ir.load = private constant [46 x i8] c"  %value.$i = load i8, ptr %cell.$i, align 1
\00"

@ir.add = private constant [76 x i8] c"  %sum.$i = add i8 %value.$i, $a
  store i8 %sum.$i, ptr %cell.$i, align 1
\00"

@ir.move.check = private constant [213 x i8] c"  %move.index.$i = load i64, ptr %data_index, align 8
  %move.valid.$i = call i1 @bf.valid(i64 %move.index.$i, i64 $a, i64 $b)
  br i1 %move.valid.$i, label %bf.move.$i.ok, label %bf.bounds.error

bf.move.$i.ok:
\00"

@ir.move.store = private constant [98 x i8] c"  %move.next.$i = add i64 %move.index.$i, $a
  store i64 %move.next.$i, ptr %data_index, align 8
\00"

@ir.input = private constant [231 x i8] c"  %input.$i = call i32 @getchar()
  %eof.$i = icmp eq i32 %input.$i, -1
  %input.byte.$i = trunc i32 %input.$i to i8
  %input.value.$i = select i1 %eof.$i, i8 0, i8 %input.byte.$i
  store i8 %input.value.$i, ptr %cell.$i, align 1
\00"

@ir.output = private constant [251 x i8] c"  %output.byte.$i = zext i8 %value.$i to i32
  %output.status.$i = call i32 @putchar(i32 %output.byte.$i)
  %output.failed.$i = icmp eq i32 %output.status.$i, -1
  br i1 %output.failed.$i, label %bf.io.error, label %bf.output.$i.ok

bf.output.$i.ok:
\00"

@ir.loop.begin = private constant [47 x i8] c"  br label %bf.loop.$i.cond

bf.loop.$i.cond:
\00"

@ir.loop.test = private constant [126 x i8] c"  %nonzero.$i = icmp ne i8 %value.$i, 0
  br i1 %nonzero.$i, label %bf.loop.$i.body, label %bf.loop.$i.end

bf.loop.$i.body:
\00"

@ir.loop.end = private constant [46 x i8] c"  br label %bf.loop.$i.cond

bf.loop.$i.end:
\00"

/* templates substitute only $i, $a, $b and $c with signed decimal values */
define internal void @emit.text(ptr %text) {
entry:
  %stream = load ptr, ptr @stdout, align 8
  %status = call i32 @fputs(ptr %text, ptr %stream)
  %failed = icmp slt i32 %status, 0
  br i1 %failed, label %write.failed, label %done

write.failed:
  call void @die(ptr @err.write)
  unreachable

done:
  ret void
}

define internal void @emit.span(ptr %text, i64 %length) {
entry:
  %stream = load ptr, ptr @stdout, align 8
  %written = call i64 @fwrite(ptr %text, i64 1, i64 %length, ptr %stream)
  %failed = icmp ne i64 %written, %length
  br i1 %failed, label %write.failed, label %done

write.failed:
  call void @die(ptr @err.write)
  unreachable

done:
  ret void
}

define internal void @emit.i64(i64 %number) {
entry:
  %stream = load ptr, ptr @stdout, align 8
  %status = call i32 (ptr, ptr, ...) @fprintf(ptr %stream, ptr @format.i64, i64 %number)
  %failed = icmp slt i32 %status, 0
  br i1 %failed, label %write.failed, label %done

write.failed:
  call void @die(ptr @err.write)
  unreachable

done:
  ret void
}

define internal void @emit(ptr %template, i64 %id, i64 %a, i64 %b, i64 %c) {
entry:
  br label %writer.scan

writer.scan:
  %cursor = phi ptr [ %template, %entry ], [ %next.byte, %writer.advance ], [ %after.key, %writer.number ]
  %start = phi ptr [ %template, %entry ], [ %start, %writer.advance ], [ %after.key, %writer.number ]
  %length = phi i64 [ 0, %entry ], [ %next.length, %writer.advance ], [ 0, %writer.number ]
  %byte = load i8, ptr %cursor, align 1
  switch i8 %byte, label %writer.advance [
    i8 0, label %writer.finish
    i8 36, label %writer.key
  ]

writer.advance:
  %next.byte = getelementptr i8, ptr %cursor, i64 1
  %next.length = add i64 %length, 1
  br label %writer.scan

writer.key:
  call void @emit.span(ptr %start, i64 %length)
  %key.ptr = getelementptr i8, ptr %cursor, i64 1
  %key = load i8, ptr %key.ptr, align 1
  switch i8 %key, label %malformed [
    i8 105, label %writer.id
    i8 97, label %writer.a
    i8 98, label %writer.b
    i8 99, label %writer.c
  ]

writer.id:
  br label %writer.number

writer.a:
  br label %writer.number

writer.b:
  br label %writer.number

writer.c:
  br label %writer.number

writer.number:
  %value = phi i64 [ %id, %writer.id ], [ %a, %writer.a ], [ %b, %writer.b ], [ %c, %writer.c ]
  call void @emit.i64(i64 %value)
  %after.key = getelementptr i8, ptr %cursor, i64 2
  br label %writer.scan

writer.finish:
  call void @emit.span(ptr %start, i64 %length)
  ret void

malformed:
  call void @die(ptr @err.ir)
  unreachable
}

define internal void @emit.address(i64 %id) {
entry:
  call void @emit(ptr @ir.address, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.load(i64 %id) {
entry:
  call void @emit.address(i64 %id)
  call void @emit(ptr @ir.load, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.add(i64 %id, i64 %delta) {
entry:
  call void @emit.load(i64 %id)
  call void @emit(ptr @ir.add, i64 %id, i64 %delta, i64 0, i64 0)
  ret void
}

/* low <= delta <= high makes the checked sum safe */
define internal void @emit.move(i64 %id, i64 %delta, i64 %low, i64 %high) {
entry:
  call void @emit(ptr @ir.move.check, i64 %id, i64 %low, i64 %high, i64 0)
  %cancelled = icmp eq i64 %delta, 0
  br i1 %cancelled, label %done, label %move.store

move.store:
  call void @emit(ptr @ir.move.store, i64 %id, i64 %delta, i64 0, i64 0)
  br label %done

done:
  ret void
}

define internal void @emit.input(i64 %id) {
entry:
  call void @emit.address(i64 %id)
  call void @emit(ptr @ir.input, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.output(i64 %id) {
entry:
  call void @emit.load(i64 %id)
  call void @emit(ptr @ir.output, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.loop.begin(i64 %id) {
entry:
  call void @emit(ptr @ir.loop.begin, i64 %id, i64 0, i64 0, i64 0)
  call void @emit.load(i64 %id)
  call void @emit(ptr @ir.loop.test, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.loop.end(i64 %opening.id) {
entry:
  call void @emit(ptr @ir.loop.end, i64 %opening.id, i64 0, i64 0, i64 0)
  ret void
}

@ir.clear = private constant [37 x i8] c"  store i8 0, ptr %cell.$i, align 1
\00"

@ir.scan = private constant [672 x i8] c"  br label %bf.scan.$i.cond

bf.scan.$i.cond:
  %scan.index.$i = load i64, ptr %data_index, align 8
  %scan.cell.$i = getelementptr i8, ptr %tape, i64 %scan.index.$i
  %scan.value.$i = load i8, ptr %scan.cell.$i, align 1
  %scan.nonzero.$i = icmp ne i8 %scan.value.$i, 0
  br i1 %scan.nonzero.$i, label %bf.scan.$i.move, label %bf.scan.$i.end

bf.scan.$i.move:
  %scan.valid.$i = call i1 @bf.valid(i64 %scan.index.$i, i64 $b, i64 $c)
  br i1 %scan.valid.$i, label %bf.scan.$i.checked, label %bf.bounds.error

bf.scan.$i.checked:
  %scan.next.$i = add i64 %scan.index.$i, $a
  store i64 %scan.next.$i, ptr %data_index, align 8
  br label %bf.scan.$i.cond

bf.scan.$i.end:
\00"

define internal void @emit.clear(i64 %id) {
entry:
  call void @emit.address(i64 %id)
  call void @emit(ptr @ir.clear, i64 %id, i64 0, i64 0, i64 0)
  ret void
}

define internal void @emit.scan(i64 %id, i64 %stride, i64 %low, i64 %high) {
entry:
  call void @emit(ptr @ir.scan, i64 %id, i64 %stride, i64 %low, i64 %high)
  ret void
}

@ir.linear.begin = private constant [315 x i8] c"  %linear.nonzero.$i = icmp ne i8 %value.$i, 0
  br i1 %linear.nonzero.$i, label %bf.linear.$i.check, label %bf.linear.$i.end

bf.linear.$i.check:
  %linear.valid.$i = call i1 @bf.valid(i64 %index.$i, i64 $a, i64 $b)
  br i1 %linear.valid.$i, label %bf.linear.$i.apply, label %bf.bounds.error

bf.linear.$i.apply:
\00"

@ir.linear.term = private constant [363 x i8] c"  %linear.index.$i.$b = add i64 %index.$i, $a
  %linear.cell.$i.$b = getelementptr i8, ptr %tape, i64 %linear.index.$i.$b
  %linear.old.$i.$b = load i8, ptr %linear.cell.$i.$b, align 1
  %linear.scaled.$i.$b = mul i8 %value.$i, $c
  %linear.sum.$i.$b = add i8 %linear.old.$i.$b, %linear.scaled.$i.$b
  store i8 %linear.sum.$i.$b, ptr %linear.cell.$i.$b, align 1
\00"

@ir.linear.end = private constant [85 x i8] c"  store i8 0, ptr %cell.$i, align 1
  br label %bf.linear.$i.end

bf.linear.$i.end:
\00"

/* every term uses the original source and offset zero is excluded
   the excursion check proves every target address valid before any transfer
   a zero source skips both checks and transfers just as the original loop did */
define internal void @emit.linear(i64 %id, i64 %first, i64 %count, i64 %low, i64 %high) {
entry:
  %arena.length = call i64 @vector.length(ptr @terms)
  %first.valid = icmp ule i64 %first, %arena.length
  %remaining = sub i64 %arena.length, %first
  %count.valid = icmp ule i64 %count, %remaining
  %range.valid = and i1 %first.valid, %count.valid
  br i1 %range.valid, label %linear.begin, label %malformed

linear.begin:
  call void @emit.load(i64 %id)
  call void @emit(ptr @ir.linear.begin, i64 %id, i64 %low, i64 %high, i64 0)
  %data = load ptr, ptr @terms, align 8
  %end = add i64 %first, %count
  br label %linear.walk

linear.walk:
  %index = phi i64 [ %first, %linear.begin ], [ %next.index, %linear.emit ]
  %done = icmp eq i64 %index, %end
  br i1 %done, label %linear.finish, label %linear.inspect

linear.inspect:
  %term.ptr = getelementptr %LinearTerm, ptr %data, i64 %index
  %term = load %LinearTerm, ptr %term.ptr, align 8
  %offset = extractvalue %LinearTerm %term, 0
  %factor = extractvalue %LinearTerm %term, 1
  %not.source = icmp ne i64 %offset, 0
  %above.low = icmp sge i64 %offset, %low
  %below.high = icmp sle i64 %offset, %high
  %in.envelope = and i1 %above.low, %below.high
  %offset.valid = and i1 %not.source, %in.envelope
  %factor.nonzero = icmp ne i64 %factor, 0
  %factor.byte = icmp ule i64 %factor, 255
  %factor.valid = and i1 %factor.nonzero, %factor.byte
  %term.valid = and i1 %offset.valid, %factor.valid
  br i1 %term.valid, label %linear.emit, label %malformed

linear.emit:
  call void @emit(ptr @ir.linear.term, i64 %id, i64 %offset, i64 %index, i64 %factor)
  %next.index = add i64 %index, 1
  br label %linear.walk

linear.finish:
  call void @emit(ptr @ir.linear.end, i64 %id, i64 0, i64 0, i64 0)
  ret void

malformed:
  call void @die(ptr @err.ir)
  unreachable
}

/* operation indices are stable label ids and each emitter leaves an open block
   the next control edge or footer terminates that block */
define internal void @codegen(ptr %operations) {
entry:
  call void @emit.text(ptr @ir.header)
  %length = call i64 @vector.length(ptr %operations)
  br label %codegen.walk

codegen.walk:
  %index = phi i64 [ 0, %entry ], [ %next.index, %codegen.next ]
  %done = icmp eq i64 %index, %length
  br i1 %done, label %codegen.finish, label %codegen.op

codegen.op:
  %op.ptr = call ptr @op.at(ptr %operations, i64 %index)
  %op = load %Op, ptr %op.ptr, align 8
  %kind = extractvalue %Op %op, 0
  %a = extractvalue %Op %op, 2
  %b = extractvalue %Op %op, 3
  %low = extractvalue %Op %op, 4
  %high = extractvalue %Op %op, 5
  switch i32 %kind, label %malformed [
    i32 1, label %codegen.add
    i32 2, label %codegen.move
    i32 3, label %codegen.input
    i32 4, label %codegen.output
    i32 5, label %codegen.open
    i32 6, label %codegen.close
    i32 7, label %codegen.clear
    i32 8, label %codegen.scan
    i32 9, label %codegen.linear
    i32 10, label %codegen.move
  ]

codegen.add:
  call void @emit.add(i64 %index, i64 %a)
  br label %codegen.next

codegen.move:
  call void @emit.move(i64 %index, i64 %a, i64 %low, i64 %high)
  br label %codegen.next

codegen.input:
  call void @emit.input(i64 %index)
  br label %codegen.next

codegen.output:
  call void @emit.output(i64 %index)
  br label %codegen.next

codegen.open:
  call void @emit.loop.begin(i64 %index)
  br label %codegen.next

codegen.close:
  call void @emit.loop.end(i64 %a)
  br label %codegen.next

codegen.clear:
  call void @emit.clear(i64 %index)
  br label %codegen.next

codegen.scan:
  call void @emit.scan(i64 %index, i64 %a, i64 %low, i64 %high)
  br label %codegen.next

codegen.linear:
  call void @emit.linear(i64 %index, i64 %a, i64 %b, i64 %low, i64 %high)
  br label %codegen.next

codegen.next:
  %next.index = add i64 %index, 1
  br label %codegen.walk

codegen.finish:
  call void @emit.text(ptr @ir.footer)
  %stream = load ptr, ptr @stdout, align 8
  %status = call i32 @fflush(ptr %stream)
  %error = call i32 @ferror(ptr %stream)
  %flush.failed = icmp ne i32 %status, 0
  %stream.failed = icmp ne i32 %error, 0
  %failed = or i1 %flush.failed, %stream.failed
  br i1 %failed, label %write.failed, label %complete

write.failed:
  call void @die(ptr @err.write)
  unreachable

malformed:
  call void @die(ptr @err.ir)
  unreachable

complete:
  ret void
}

define i32 @main(i32 %argc, ptr %argv) {
entry:
  switch i32 %argc, label %usage [
    i32 2, label %default.options
    i32 3, label %parse.option
  ]

default.options:
  %first.ptr = getelementptr ptr, ptr %argv, i64 1
  %first = load ptr, ptr %first.ptr, align 8
  %lone.option = call i32 @strcmp(ptr %first, ptr @option.no.opt)
  %missing.filename = icmp eq i32 %lone.option, 0
  br i1 %missing.filename, label %usage, label %open

parse.option:
  %option.ptr = getelementptr ptr, ptr %argv, i64 1
  %option = load ptr, ptr %option.ptr, align 8
  %comparison = call i32 @strcmp(ptr %option, ptr @option.no.opt)
  %recognized = icmp eq i32 %comparison, 0
  br i1 %recognized, label %open, label %usage

usage:
  call void @die(ptr @err.usage)
  unreachable

open:
  %filename.index = phi i64 [ 1, %default.options ], [ 2, %parse.option ]
  %bf.opt = phi i1 [ true, %default.options ], [ false, %parse.option ]
  %filename.ptr = getelementptr ptr, ptr %argv, i64 %filename.index
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
  %close.status = call i32 @fclose(ptr %file)
  store ptr null, ptr @input.file, align 8
  %close.failed = icmp ne i32 %close.status, 0
  br i1 %close.failed, label %read.failed, label %choose.optimization

read.failed:
  call void @die(ptr @err.read)
  unreachable

choose.optimization:
  br i1 %bf.opt, label %optimize, label %generate

optimize:
  call void @optimize()
  br label %generate

generate:
  %operations = phi ptr [ @parsed, %choose.optimization ], [ @optimized, %optimize ]
  call void @codegen(ptr %operations)
  call void @cleanup()
  ret i32 0
}
