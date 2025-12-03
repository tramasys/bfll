import os
from pathlib import Path
import random
import re
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CLANG = shlex.split(os.environ.get("CLANG", "clang"))
LLVM_AS = shlex.split(os.environ.get("LLVM_AS", "llvm-as"))
OPT = shlex.split(os.environ.get("OPT", "opt"))
BFC = ROOT / "bfc"
MODULES = 0
RUNS = 0


def checked(command, **kwargs):
    result = subprocess.run(
        [str(part) for part in command],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        **kwargs,
    )
    assert result.returncode == 0, (
        command, result.returncode, result.stderr.decode(errors="replace")
    )
    return result


def verify(path):
    global MODULES
    bitcode = path.with_suffix(".bc")
    checked([*LLVM_AS, path, "-o", bitcode])
    checked([*OPT, "-passes=verify", bitcode, "-disable-output"])
    MODULES += 1


def reference(source, data=b"", limit=5_000_000):
    commands = [byte for byte in source if byte in b"+-<>[],."]
    stack = []
    partners = {}
    for index, command in enumerate(commands):
        if command == ord("["):
            stack.append(index)
        elif command == ord("]"):
            assert stack
            opening = stack.pop()
            partners[opening] = index
            partners[index] = opening
    assert not stack
    tape = bytearray(30000)
    pointer = pc = input_index = steps = 0
    output = bytearray()
    while pc < len(commands):
        steps += 1
        assert steps <= limit, "reference program exceeded its step budget"
        command = commands[pc]
        if command == ord("+"):
            tape[pointer] = (tape[pointer] + 1) & 255
        elif command == ord("-"):
            tape[pointer] = (tape[pointer] - 1) & 255
        elif command == ord(">"):
            pointer += 1
            if pointer == 30000:
                return bytes(output), 1
        elif command == ord("<"):
            pointer -= 1
            if pointer < 0:
                return bytes(output), 1
        elif command == ord("."):
            output.append(tape[pointer])
        elif command == ord(","):
            tape[pointer] = data[input_index] if input_index < len(data) else 0
            input_index += 1
        elif command == ord("[") and not tape[pointer]:
            pc = partners[pc]
        elif command == ord("]") and tape[pointer]:
            pc = partners[pc]
        pc += 1
    return bytes(output), 0


def compile_pair(directory, name, source, structure=None, native=True):
    path = directory / (name + ".bf")
    path.write_bytes(source)
    executables = []
    for optimized in (True, False):
        stem = name + (".opt" if optimized else ".plain")
        llvm = directory / (stem + ".ll")
        command = [BFC]
        if not optimized:
            command.append("--no-bf-opt")
        result = checked([*command, path])
        assert result.stderr == b""
        llvm.write_bytes(result.stdout)
        verify(llvm)
        text = result.stdout.decode()
        assert not re.search(r"^\d+:", text, re.MULTILINE)
        assert "getelementptr inbounds" not in text
        assert not re.search(r"\bi(?:8|32|64)\*", text)
        if optimized and structure:
            structure(text)
        if not optimized:
            assert "bf.linear." not in text and "bf.scan." not in text
        if native:
            executable = directory / stem
            checked([*CLANG, "-O2", "-Wno-override-module", llvm, "-o", executable])
            executables.append(executable)
    return executables


def execute(executable, data=b""):
    global RUNS
    result = subprocess.run(
        [str(executable)], input=data, capture_output=True, timeout=5
    )
    RUNS += 1
    assert result.returncode in (0, 1), (executable, result.returncode, result.stderr)
    if result.returncode:
        assert b"bfll: tape bounds error" in result.stderr
    else:
        assert result.stderr == b""
    return result.stdout, result.returncode


def contains(*needles, absent=()):
    def check(text):
        for needle in needles:
            assert needle in text, needle
        for needle in absent:
            assert needle not in text, needle
    return check


CLEAR = contains("store i8 0, ptr %cell.", absent=("bf.loop.", "bf.linear."))
LINEAR = contains("mul i8", "bf.linear.", absent=("bf.loop.",))
SCAN = contains("bf.scan.", absent=("bf.loop.",))
GENERIC = contains("bf.loop.", absent=("bf.linear.", "bf.scan."))


def semantic_cases(directory):
    cases = [
        ("empty", b"", b"", None),
        ("comments", b"words only\x00\x80\xff\n", b"", None),
        ("hello", (ROOT / "examples/hello.bf").read_bytes(), b"", None),
        ("cat", (ROOT / "examples/cat.bf").read_bytes(), b"abc\x80\xff\n", None),
        ("transfer-example", (ROOT / "examples/transfer.bf").read_bytes(), b"", LINEAR),
        ("nested", b"++[>++[>+<-]<-]>>.", b"", contains("bf.loop.", "bf.linear.")),
        ("bytes-eof", b",.,.,.,.,.", b"\x00\x7f\x80\xff", None),
        ("wrap-up", b"+" * 256 + b".", b"", contains(absent=("add i8",))),
        ("wrap-down", b"-.", b"", contains("add i8 %value.0, 255")),
        ("mixed-add", b"++hello++---.", b"", contains("add i8 %value.0, 1")),
        ("cancel-add", b"+-.", b"", contains(absent=("add i8",))),
        ("mixed-move", b">>>>><<<+.", b"", contains("add i64 %move.index.0, 2")),
        ("cancel-move", b"><.", b"", contains(absent=("move.next.",))),
        ("fold-through-zero", b">+-<.", b"", None),
        ("left-bound", b"<", b"", None),
        ("right-bound", b">" * 30000, b"", None),
        ("last-cell", b">" * 29999 + b"+.", b"", None),
        ("hidden-left", b".<>", b"", None),
        ("hidden-right", b">" * 30000 + b"<" * 30000, b"", None),
        ("clear-minus", b",[-].", b"\xff", CLEAR),
        ("clear-plus", b",[+].", b"\xff", CLEAR),
        ("clear-minus-three", b",[---].", b"\x01", CLEAR),
        ("clear-plus-three", b",[+++].", b"\x80", CLEAR),
        ("even-clear", b"++[--].", b"", GENERIC),
        ("even-clear-zero", b"[--].", b"", GENERIC),
        ("linear-copy", b"+++[->+<]>.", b"", LINEAR),
        ("linear-double", b"+++[->++<]>.", b"", LINEAR),
        ("linear-two-targets", b"+++[->+>+<<]>.>.", b"", LINEAR),
        ("linear-positive", b"+++[+>+<]>.", b"", LINEAR),
        ("linear-odd", b"+++[--->++>+++<<]>.>.", b"", LINEAR),
        ("linear-negative-target", b"+++[->---<]>.", b"", LINEAR),
        ("linear-repeated-target", b"+++[->++<+>---<---]>.", b"", LINEAR),
        ("linear-left-target", b">+++[-<++>]<.", b"", LINEAR),
        ("linear-skip-left", b"[<+>-].", b"", LINEAR),
        ("linear-fail-left", b"+[<+>-]", b"", LINEAR),
        ("linear-skip-right", b">" * 29999 + b"[->+<].", b"", LINEAR),
        ("linear-fail-right", b">" * 29999 + b"+[->+<]", b"", LINEAR),
        ("linear-cancelled-target", b">" * 29999 + b"+[->+-<]", b"", contains("bf.linear.")),
        ("linear-excursion", b">" * 29998 + b"+[->><<]", b"", contains("bf.linear.")),
        ("linear-zero-terms", b"+[->><<].", b"", contains("bf.linear.", absent=("mul i8",))),
        ("linear-zero-terms-skip", b"[<+->-].", b"", contains("bf.linear.", absent=("mul i8",))),
        ("even-linear", b"++[-->+<]>.", b"", GENERIC),
        ("missing-source", b"[>+<].", b"", GENERIC),
        ("moving-loop", b"+[->+>]<.", b"", GENERIC),
        ("scan-right", b"+>+>+<<[>].", b"", SCAN),
        ("scan-left", b">+>+[<].", b"", SCAN),
        ("scan-right-three", b"+>>>+<<<[>>>].", b"", SCAN),
        ("scan-left-three", b">>>+>>>+[<<<].", b"", SCAN),
        ("scan-left-error", b"+[<]", b"", SCAN),
        ("scan-right-error", b">" * 29999 + b"+[>]", b"", SCAN),
        ("scan-skip", b"[<<<].", b"", SCAN),
        ("scan-hidden-excursion", b">" * 29998 + b"+[>><]", b"", SCAN),
        ("empty-loop-zero", b"[].", b"", GENERIC),
        ("nested-depth", b"[" * 128 + b"+" + b"]" * 128 + b".", b"", None),
        ("vector-growth", b"+." * 600, b"", None),
    ]
    for name, source, data, structure in cases:
        expected = reference(source, data)
        pair = compile_pair(directory, name, source, structure)
        for executable in pair:
            assert execute(executable, data) == expected, name
    assert reference((ROOT / "examples/hello.bf").read_bytes())[0] == b"Hello World!\n"
    assert reference((ROOT / "examples/transfer.bf").read_bytes())[0] == b"A"
    compile_pair(directory, "deep-nesting", b"[" * 4096 + b"+" + b"]" * 4096, native=False)
    print(f"{len(cases)} semantic cases passed", flush=True)


def delta(value):
    value &= 255
    return b"+" * value if value <= 128 else b"-" * (256 - value)


def move(distance):
    return b">" * distance if distance >= 0 else b"<" * -distance


def randomized_cases(directory):
    rng = random.Random(20250917)
    for case in range(24):
        source = bytearray(b">" * 6)
        data = bytearray()
        for _ in range(8):
            odd = rng.randrange(1, 256, 2)
            first = rng.randrange(256)
            source.extend(b"," + b"[" + delta(first))
            data.append(rng.randrange(256))
            position = 0
            for _ in range(rng.randrange(2, 9)):
                target = rng.choice([-3, -2, -1, 1, 2, 3])
                source.extend(move(target - position) + delta(rng.randrange(256)))
                position = target
            source.extend(move(-position) + delta(odd - first) + b"]")
            for offset in [-3, -2, -1, 0, 1, 2, 3]:
                source.extend(move(offset) + b"." + move(-offset))
        expected = reference(source, data)
        pair = compile_pair(directory, f"random-{case}", source)
        for executable in pair:
            assert execute(executable, data) == expected, case
    print("24 deterministic random programs passed", flush=True)


def exhaustive_inverses(directory):
    source = bytearray()
    for odd in range(1, 256, 2):
        source.extend(
            b">[-]+++++++>[-]+++++++++++<<,["
            + delta(odd) + b">++>---<<]>.>.<" + b"<"
        )
    pair = compile_pair(directory, "all-odd-deltas", source, LINEAR)
    for value in range(256):
        expected = bytearray()
        for odd in range(1, 256, 2):
            iterations = (-value * pow(odd, -1, 256)) & 255
            expected.extend(((7 + iterations * 2) & 255, (11 - iterations * 3) & 255))
        results = [execute(executable, bytes([value]) * 128) for executable in pair]
        assert results[0] == results[1] == (bytes(expected), 0), value
    print("all 32768 odd-delta and source-byte combinations passed", flush=True)


def nonterminating_cases(directory):
    for name, source in [("empty-spin", b"+[]"), ("even-spin", b"+[--]"),
                         ("cancelled-move-spin", b"+[><]")]:
        pair = compile_pair(directory, name, source, GENERIC)
        for executable in pair:
            try:
                subprocess.run([executable], capture_output=True, timeout=0.3)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError(f"{name} unexpectedly terminated")
    print("nonterminating loops remain nonterminating", flush=True)


def compiler_errors(directory):
    path = directory / "bad.bf"
    for command in ([BFC], [BFC, "--no-bf-opt"], [BFC, directory / "missing.bf"],
                    [BFC, "--unknown", path], [BFC, "a", "b", "c"]):
        result = subprocess.run(command, capture_output=True, timeout=5)
        assert result.returncode == 1 and result.stdout == b"" and result.stderr
    for source, message in [(b"]", b"unmatched ']'"), (b"[", b"unmatched '['"),
                            (b"[][[]", b"unmatched '['"), (b"[]]", b"unmatched ']'")]:
        path.write_bytes(source)
        for option in ([], ["--no-bf-opt"]):
            result = subprocess.run([BFC, *option, path], capture_output=True, timeout=5)
            assert result.returncode == 1 and result.stdout == b""
            assert message in result.stderr
    if Path("/dev/full").exists():
        with open("/dev/full", "wb") as output:
            result = subprocess.run(
                [BFC, ROOT / "examples/hello.bf"], stdout=output, stderr=subprocess.PIPE,
                timeout=5,
            )
        assert result.returncode == 1 and b"output write failure" in result.stderr
        with open("/dev/full", "wb") as output:
            result = subprocess.run(
                [directory / "hello.opt"], stdout=output, stderr=subprocess.PIPE,
                timeout=5,
            )
        assert result.returncode == 1 and b"output write failure" in result.stderr
    if os.name == "posix":
        result = subprocess.run([BFC, directory], capture_output=True, timeout=5)
        assert result.returncode == 1 and b"input read failure" in result.stderr
    print("cli, syntax, read and write errors passed", flush=True)


def allocation_failures(directory):
    mocks = {
        "realloc": "define ptr @realloc(ptr %old, i64 %size) {\nentry:\n  ret ptr null\n}\n",
        "calloc": "define ptr @calloc(i64 %count, i64 %size) {\nentry:\n  ret ptr null\n}\n",
    }
    for name, text in mocks.items():
        mock = directory / (name + ".ll")
        mock.write_text(text)
        verify(mock)
        executable = directory / ("fail-" + name)
        module = ROOT / "src/bfc.ll" if name == "realloc" else directory / "hello.opt.ll"
        if name == "calloc":
            # retain the call so llvm cannot elide this failure injection
            probe = directory / "allocation-probe.ll"
            probe.write_text(module.read_text().replace(
                "declare ptr @calloc(i64, i64)", "declare ptr @calloc(i64, i64) nobuiltin"
            ))
            verify(probe)
            module = probe
        checked([*CLANG, "-O2", "-Wno-override-module", module, mock, "-o", executable])
        args = [executable, ROOT / "examples/hello.bf"] if name == "realloc" else [executable]
        result = subprocess.run(args, capture_output=True, timeout=5)
        assert result.returncode == 1 and b"allocation failure" in result.stderr, (
            name, result.returncode, result.stdout, result.stderr
        )
        assert result.stdout == b""
    print("compiler and generated tape allocation failures passed", flush=True)


def internal_errors(directory):
    compiler = (ROOT / "src/bfc.ll").read_text().replace(
        "define i32 @main(i32 %argc, ptr %argv)",
        "define internal i32 @compiler.main(i32 %argc, ptr %argv)", 1
    )
    probes = [
        ("bad-index", "  %op = call ptr @op.at(ptr @parsed, i64 0)", b"malformed bf ir"),
        ("bad-inverse", "  %inverse = call i64 @inverse256(i64 2)", b"malformed bf ir"),
        ("bad-opcode",
         "  %index = call i64 @op.push(ptr @parsed, i32 99, i64 0, i64 0, i64 0, i64 0)\n"
         "  call void @codegen(ptr @parsed)", b"malformed bf ir"),
        ("delta-overflow",
         "  %index = call i64 @op.push(ptr @parsed, i32 2, i64 9223372036854775807, "
         "i64 0, i64 0, i64 9223372036854775807)\n"
         "  call void @parse.append(i32 2, i64 1)", b"pointer delta overflow"),
        ("capacity-overflow",
         "  store %Vector { ptr null, i64 9223372036854775807, i64 9223372036854775807 }, "
         "ptr @parsed, align 8\n"
         "  call void @vector.reserve(ptr @parsed, i64 40)", b"capacity overflow"),
        ("bad-term",
         "  call void @term.push(ptr @terms, i64 0, i64 1)\n"
         "  call void @emit.linear(i64 0, i64 0, i64 1, i64 0, i64 0)", b"malformed bf ir"),
    ]
    for name, body, message in probes:
        path = directory / (name + ".ll")
        path.write_text(compiler + "\ndefine i32 @main() {\nentry:\n" + body
                        + "\n  ret i32 0\n}\n")
        verify(path)
        executable = directory / name
        checked([*CLANG, "-O2", "-Wno-override-module", path, "-o", executable])
        result = subprocess.run([executable], capture_output=True, timeout=5)
        assert result.returncode == 1 and message in result.stderr, name
        assert message not in result.stdout
    print("malformed ir and arithmetic overflow diagnostics passed", flush=True)

def main():
    for tool in (LLVM_AS, OPT, CLANG):
        print(checked([*tool, "--version"]).stdout.decode().splitlines()[:2], flush=True)
    with tempfile.TemporaryDirectory(prefix="bfll-tests-") as temporary:
        directory = Path(temporary)
        compiler_ir = directory / "compiler.ll"
        compiler_ir.write_bytes((ROOT / "src/bfc.ll").read_bytes())
        verify(compiler_ir)
        semantic_cases(directory)
        randomized_cases(directory)
        exhaustive_inverses(directory)
        nonterminating_cases(directory)
        compiler_errors(directory)
        allocation_failures(directory)
        internal_errors(directory)
    print(f"passed with {MODULES} verified modules and {RUNS} native executions")


if __name__ == "__main__":
    main()
