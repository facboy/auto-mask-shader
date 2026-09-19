#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Offline compile-and-cost check for the AutoMask shader.

ReShade compiles its effects at runtime, so an ordinary compiler cannot read an
`.fx` file as-is: the effect dialect adds annotations and technique blocks, and
ReShade injects the BUFFER_* macros. Annotations and technique blocks carry no
code -- they are metadata and wiring, parsed and discarded when one entry point
is compiled -- so the way to get real bytecode out is to preprocess the file,
drop those two constructs and hand the result to fxc, entirely in a scratch copy
under tools/.work/. The repository files are never modified.

    uv run tools/verify_shaders.py init    # fetch the pinned headers
    uv run tools/verify_shaders.py check   # compile every entry point

There is no baseline to compare against: this project has no shipped behaviour
to preserve, so the point is only "it compiles, here is the pass list, and here
is what it costs".

Two properties are deliberate and must survive any change to this file:

- Every failure is loud. A shader that compiles *and emits no bytecode* is an
  error here, not a pass, because a missing hash compares equal to another
  missing hash. An earlier version of the companion tool reported a clean pass
  while producing nothing at all.
- An entry point that is missed is a failure. The guard is not line-anchored:
  a macro-generated entry point can sit mid-line once macros expand, and a
  silently skipped entry point is indistinguishable from a passing one.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SHADERS = REPO / "Shaders"
WORK = REPO / "tools" / ".work"

# Pinned so the evidence is reproducible: crosire/reshade-shaders @ main.
HEADER_COMMIT = "6db142b4b1a05c764222e5b0bd9a644b7ccfe1dc"
HEADERS = ("ReShade.fxh", "ReShadeUI.fxh", "DrawText.fxh")
HEADER_URL = "https://raw.githubusercontent.com/crosire/reshade-shaders/{}/Shaders/{}"

# (name, extra definitions). Both switches are `#ifndef`-guarded in the shader,
# so defining them in the prelude is exactly the path a ReShade-level definition
# or a preset takes -- the check exercises the override rather than a patched
# copy, and every combination is compiled so a guard that drops a pass from the
# technique body cannot hide.
VARIANTS = (
    ("default", {}),
    ("antibloom-off", {"AutoMaskAntiBloom": "0"}),
    ("diagnostics", {"AutoMaskDiagnostics": "1"}),
    ("antibloom-off-diagnostics", {"AutoMaskAntiBloom": "0", "AutoMaskDiagnostics": "1"}),
)

# An annotation block is `< ... >` containing `key = value;` pairs and possibly a
# bare macro such as `__UNIFORM_SLIDER_FLOAT1`. It is NOT matched by walking to
# the next `;`, because a value can legitimately contain one -- a tooltip with a
# semicolon in its prose broke that assumption and left `ui_type = "slider";`
# un-stripped, which fxc then rejected with "unrecognized identifier 'ui_type'".
# So a quoted value is matched whole, semicolons and all, and the lookahead keeps
# the pattern off ordinary `<` comparisons.
ANNOTATION = re.compile(
    r'<(?=[^<>]*=)'                                                  # annotations always have an `=`
    r'(?:\s*(?:__UNIFORM_\w+'                                        # bare macro token
    r'|[A-Za-z_]\w*\s*=\s*(?:"[^"]*"|[^;>])*\s*;))*'                 # key = value;
    r'\s*>')
# Deliberately NOT line-anchored: a generated entry point can sit mid-line.
ENTRY_POINT = re.compile(
    r'(?:float4|float3|float2|void)\s+(\w+)\s*\([^)]*\)\s*:\s*SV_Target')
TECHNIQUE = re.compile(r'technique\s+(\w+)[^{]*\{', re.S)
# A pass may be named (`pass P0 {`) or not (`pass {`), so the name is optional.
# Requiring it to be absent silently matches nothing for a named pass, which is
# indistinguishable from a technique that has no passes at all.
PASS = re.compile(r'pass\s+(?:\w+\s*)?\{([^}]*)\}')
INSTRUCTION_COUNT = re.compile(r'// Approximately (\d+) instruction slots used')


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_fxc() -> Path:
    """Locate fxc.exe: $FXC, then PATH, then the newest Windows Kits SDK.

    The choice of SDK version does not affect what this check reports. That was
    measured rather than assumed: the shader that ReShade refused to compile
    (X3511 on a forced unroll) compiles cleanly under every installed fxc at every
    optimisation level, oldest and newest alike. So there is nothing to be gained
    by preferring one version, and the newest is simply the most predictable
    default.

    The consequence is worth keeping in mind: an `ok` from this check means the
    HLSL is well-formed and the passes are wired as documented. It does not mean
    ReShade will accept it, and no installed fxc can tell you the difference.
    """
    for candidate in (os.environ.get("FXC"), shutil.which("fxc.exe")):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    kits_found = []
    for candidate in ("/mnt/c/Program Files (x86)/Windows Kits/10/bin",
                      "/mnt/c/Program Files/Windows Kits/10/bin"):
        kits = Path(candidate)
        if kits.is_dir():
            kits_found += [p / "x64" / "fxc.exe" for p in kits.iterdir()
                           if (p / "x64" / "fxc.exe").is_file()]
    if not kits_found:
        sys.exit("FAIL -- fxc.exe not found; set $FXC to its path (needs the Windows SDK)")
    kits_found.sort(key=lambda p: [int(n) for n in re.findall(r"\d+", p.parent.parent.name)])
    return kits_found[-1]


def windows_path(path: Path) -> str:
    out = subprocess.run(["wslpath", "-w", str(path)],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def run_fxc(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([str(FXC)] + args, cwd=WORK, capture_output=True,
                          text=True, errors="replace")


def first_error(log: str) -> str:
    match = re.search(r"error X\d+: .*", log)
    return match.group(0).strip() if match else "unknown compile failure"


def source_files() -> list[Path]:
    return sorted(SHADERS.glob("*.fx"))


# --------------------------------------------------------------------------- init

def cmd_init(args) -> int:
    WORK.mkdir(parents=True, exist_ok=True)
    for name in HEADERS:
        dest = WORK / name
        url = HEADER_URL.format(HEADER_COMMIT, name)
        with urllib.request.urlopen(url) as response:
            payload = response.read()
        digest = hashlib.sha256(payload).hexdigest()
        if dest.is_file() and sha256_file(dest) == digest:
            print("up to date  %s" % name)
            continue
        dest.write_bytes(payload)
        print("fetched     %s  sha256=%s" % (name, digest[:16]))
    print("workspace ready at %s (headers pinned at %s)"
          % (WORK.relative_to(REPO), HEADER_COMMIT[:12]))
    print("fxc: %s" % FXC)
    return 0


# -------------------------------------------------------------------------- check

def build_workspace(source: Path, definitions: dict[str, str]) -> Path:
    """Preprocess one shader into the workspace; returns the preprocessed path."""
    shutil.copy(source, WORK / source.name)
    prelude = ["#define __RESHADE__ 52000", "#define __RESHADE_FXC__ 1",
               "#define BUFFER_WIDTH      2560", "#define BUFFER_HEIGHT     1440",
               "#define BUFFER_RCP_WIDTH  (1.0 / 2560.0)",
               "#define BUFFER_RCP_HEIGHT (1.0 / 1440.0)", "#define RGBA8 28"]
    # Blank the shader's own guarded defaults so the variant's value is the one
    # that takes effect, whatever order the file declares them in.
    prelude += ["#undef %s" % key for key in definitions]
    prelude += ["#define %s %s" % (key, value) for key, value in definitions.items()]
    prelude.append('#include "%s"' % source.name)
    (WORK / "build.fx").write_text("\n".join(prelude) + "\n",
                                   encoding="utf-8", newline="\n")

    result = run_fxc(["/P", "preprocessed.i", "/I", windows_path(WORK), "build.fx"])
    if result.returncode != 0:
        sys.exit("FAIL -- preprocessing failed: %s" % first_error(result.stdout + result.stderr))
    return WORK / "preprocessed.i"


def strip_render_metadata(text: str) -> str:
    """Remove annotations and technique blocks -- neither produces code.

    The technique strip runs to end-of-file, which assumes the techniques are the
    last thing in the shader. That is the ReShade convention and what the pack
    does. If code ever followed them it would be dropped here, and a missing
    symbol would surface as a compile error -- loud, not silent.
    """
    text = ANNOTATION.sub("", text)
    # Loud guard: if any annotation residue survives, fxc reports it as an
    # unrecognized identifier far from the cause (`ui_type` with no hint that a
    # tooltip broke the strip). Fail here instead, naming the construct.
    residue = re.search(r'\b(ui_\w+|__UNIFORM_\w+)\s*=', text)
    if residue:
        sys.exit("FAIL -- annotation stripping left %r in the source; the "
                 "annotation pattern is wrong" % residue.group(0))
    return re.sub(r"(?sm)^[ \t]*technique\b.*\Z", "", text)


def compile_entry(stripped: Path, entry: str) -> dict:
    asm = WORK / ("%s.asm" % entry)
    binary = WORK / ("%s.bin" % entry)
    # Never let a previous run's output be mistaken for this run's result.
    for stale in (asm, binary):
        stale.unlink(missing_ok=True)
    result = run_fxc(["/Gec", "/T", "ps_5_0", "/E", entry, "/I", windows_path(WORK),
                      stripped.name, "/Fc", asm.name, "/Fo", binary.name])
    log = result.stdout + result.stderr
    if result.returncode != 0:
        return {"status": "error", "error": first_error(log)}
    if not binary.is_file():
        # Compiling "succeeded" but emitted nothing: refuse to report it as ok.
        return {"status": "error", "error": "fxc produced no bytecode for %s" % entry}
    text = asm.read_text(encoding="utf-8", errors="replace")
    match = INSTRUCTION_COUNT.search(text)
    histogram: dict[str, int] = {}
    # fxc's slot count covers executable instructions only, so dcl_* is excluded
    # here too -- otherwise the cross-check trips on a purely definitional gap.
    body = text.split("ps_5_0", 1)[-1]
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("dcl_"):
            continue
        opcode = line.split()[0].split("_")[0]
        histogram[opcode] = histogram.get(opcode, 0) + 1
    instructions = int(match.group(1)) if match else None
    # Two independent readings of the same shader, so a broken parse cannot
    # masquerade as a clean result.
    if instructions is None:
        return {"status": "error", "error": "no instruction count in the assembly for %s" % entry}
    if sum(histogram.values()) != instructions:
        return {"status": "error",
                "error": "histogram sums to %d but fxc reports %d instructions"
                         % (sum(histogram.values()), instructions)}
    return {"status": "ok", "instructions": instructions,
            "histogram": dict(sorted(histogram.items())),
            "bytecode_sha256": sha256_file(binary)}


def technique_blocks(text: str) -> list[tuple[str, str]]:
    """Yield (name, body) per technique, by brace matching.

    A regex that expects the closing brace on its own line rejects a technique
    written on one line, which is valid ReShade. Matching braces accepts both
    shapes; the pass-count cross-check in the caller is still what catches a
    pattern that under-matches.
    """
    out: list[tuple[str, str]] = []
    for match in TECHNIQUE.finditer(text):
        depth, index = 1, match.end()
        start = index
        while index < len(text) and depth:
            char = text[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            index += 1
        out.append((match.group(1), text[start:index - 1]))
    return out


def technique_bindings(preprocessed: str) -> list[list[str | None]]:
    """Every pass as [technique, pixel shader, render target], in order.

    Compiling a single entry point discards the technique blocks, so the pass
    wiring has to be read from the preprocessed source. This is what shows the
    passes still bind the same shader in the documented order -- and what makes
    a pass dropped by a guard visible as a missing pass rather than a silent
    pass.
    """
    text = re.sub(r"//[^\n]*", "", preprocessed)
    out: list[list[str | None]] = []
    for tech, body in technique_blocks(text):
        passes = PASS.findall(body)
        # Cross-check the parse against the keyword count, the same way the
        # instruction count is cross-checked against the histogram: a pattern
        # that misses a pass must not look like a technique with fewer passes.
        keywords = len(re.findall(r"\bpass\b", body))
        if keywords != len(passes):
            sys.exit("FAIL -- technique %s: parsed %d pass(es) but found %d pass keyword(s); "
                     "the pass pattern is wrong" % (tech, len(passes), keywords))
        for one in passes:
            ps = re.search(r"PixelShader\s*=\s*(\w+)", one)
            rt = re.search(r"RenderTarget\s*=\s*(\w+)", one)
            out.append([tech, ps.group(1) if ps else None,
                        rt.group(1) if rt else None])
    return out


def cmd_check(args) -> int:
    if not (WORK / "ReShade.fxh").is_file():
        sys.exit("FAIL -- headers missing; run: uv run tools/verify_shaders.py init")
    sources = source_files()
    if not sources:
        # Nothing to check is not a pass. Say so loudly rather than reporting a
        # clean run over an empty set.
        sys.exit("FAIL -- no shaders found in %s; nothing was compiled"
                 % SHADERS.relative_to(REPO))

    failed: list[str] = []
    print("%-26s %-30s %6s  %s" % ("variant", "entry point", "instr", "status"))
    for name, definitions in VARIANTS:
        for source in sources:
            preprocessed = build_workspace(source, definitions)
            text = preprocessed.read_text(encoding="utf-8", errors="replace")
            bindings = technique_bindings(text)
            entries = sorted(set(ENTRY_POINT.findall(text)))
            if not entries:
                failed.append("%s %s: no pixel shader entry points found"
                              % (name, source.name))
                continue
            if not bindings:
                # A shader with no technique passes is not a shader: something
                # dropped them, either a guard or a broken parse. Never a pass.
                failed.append("%s %s: no technique passes found; nothing was wired up"
                              % (name, source.name))
                continue
            if args.pass_list:
                for tech, ps, rt in bindings:
                    print("  %-24s %-22s %s -> %s" % (name, tech, ps, rt))
            used = {ps for _, ps, _ in bindings}
            missing = sorted(used - set(entries))
            if missing:
                failed.append("%s %s: techniques bind %s but no such entry point was found"
                              % (name, source.name, ", ".join(missing)))
            stripped = WORK / "stripped.fx"
            stripped.write_text(strip_render_metadata(text), encoding="utf-8", newline="\n")
            for entry in entries:
                outcome = compile_entry(stripped, entry)
                if outcome["status"] != "ok":
                    failed.append("%s %s %s: %s"
                                  % (name, source.name, entry, outcome.get("error")))
                print("%-26s %-30s %6s  %s"
                      % (name, entry, outcome.get("instructions", "-"), outcome["status"]))
                if args.opcodes and outcome["status"] == "ok":
                    for opcode, count in outcome["histogram"].items():
                        print("      %-14s %d" % (opcode, count))
            print("  %s: %d technique pass(es): %s"
                  % (name, len(bindings),
                     ", ".join(ps or "?" for _, ps, _ in bindings)))

    if failed:
        print("\nFAIL -- %d problem(s):" % len(failed))
        for problem in failed:
            print("  " + problem)
        return 1
    print("\nPASS -- every entry point compiled, with bytecode and a matching histogram")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init", help="fetch the pinned ReShade headers")
    init.set_defaults(func=cmd_init)

    check = sub.add_parser("check", help="compile every entry point in every variant")
    check.add_argument("--opcodes", action="store_true",
                       help="print the opcode histogram for each shader")
    check.add_argument("--pass-list", action="store_true",
                       help="print each technique's passes before compiling")
    check.set_defaults(func=cmd_check)

    args = parser.parse_args()
    global FXC
    FXC = find_fxc()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
