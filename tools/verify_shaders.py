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

The check is dual-host: it runs from WSL and natively on Windows alike, because
it needs fxc.exe, which is a Windows binary. Under WSL the paths cross the
boundary through wslpath; natively everything already speaks Windows.

    uv run tools/verify_shaders.py init         # fetch the pinned headers
    uv run tools/verify_shaders.py check        # compile every entry point
    uv run tools/verify_shaders.py check-docs    # refuse prose framing in the docs

There is no baseline to compare against: this project has no shipped behaviour
to preserve, so the point is only "it compiles, here is the pass list, and here
is what it costs".

Eight properties are deliberate and must survive any change to this file:

- Every failure is loud. A shader that compiles *and emits no bytecode* is an
  error here, not a pass, because a missing hash compares equal to another
  missing hash. An earlier version of the companion tool reported a clean pass
  while producing nothing at all.
- An entry point that is missed is a failure. The guard is not line-anchored:
  a macro-generated entry point can sit mid-line once macros expand, and a
  silently skipped entry point is indistinguishable from a passing one.
- Every variant in the matrix is compiled. A variant list is a crossing of
  switches, and a name built by concatenating suffixes can collide with another,
  which would show the same combination twice and leave the other uncompiled --
  coverage read off a report that does not have it. A duplicate name is therefore
  refused at import, so a silently skipped variant cannot hide in a changed list.
- A dialect spelling this tool rewrites cannot be checked by compiling. Storage
  declarations are translated to `RWTexture*` before fxc sees them, so a keyword
  ReShade would reject compiles here regardless -- a shader that loads in this
  check but not in the game. The spellings the translation touches are therefore
  pinned to ReShade's own lexer and a near-miss fails loudly instead of being
  rewritten; that is the `MISSPELLED_STORAGE` guard. It was added after a
  lowercase `storage2d` passed this check and failed in ReShade with a bare
  X3000 pointing at the line rather than the case.
- A compute pass is read from its own wiring: `ComputeShader` and
  `DispatchSizeX/Y/Z` alongside `PixelShader`, compiled at `cs_5_0` rather than
  `ps_5_0`, and a compute pass declaring no dispatch size exits non-zero the way
  ReShade rejects it (error 3012). A pixel-only parse sees none of that and
  would call a technique with a dropped compute pass clean.
- A name ReShade's parser does not know cannot be checked by compiling either,
  and this one is not a translation gap: the intrinsic is real HLSL, so fxc
  implements it and the compile below succeeds on source ReShade refuses with
  X3004 (`undeclared identifier or no matching intrinsic overload`). `fmod` did
  exactly that -- a clean pass here, a failed load in the game -- so the names
  fxc has and ReShade does not are refused outright. That is `NOT_IN_RESHADE`.
- The same blind spot covers a *word* rather than a call. ReShade's lexer emits
  some spellings as a reserved token where HLSL has no such thing, so `float
  sample = ...` is well-formed HLSL that fxc compiles and ReShade rejects at load
  with X3000 (`unexpected reserved word, expected identifier`). That reached a
  game, so the reserved set is read from ReShade's own lexer and refused; that is
  `RESERVED_WORD`.
- A warning is a failure too, with one exception that is the harness's own
  artefact. ReShade prints every warning its compile emits to the log, so one is
  a defect rather than a note: a log a user cannot read is how a real warning
  gets missed, and a genuinely noisy load is what the shader should not ship.
  The check reports a warning entry as `WARN` and fails on it. The single
  exception is `X3579` (`ps_5_0 does not support groupshared, groupshared
  ignored`), which is this harness's own artefact rather than the shader's: the
  whole preprocessed file is compiled once per entry point, so fxc sees the
  compute path's file-scope `groupshared` tally when compiling a pixel entry
  point, where ReShade -- compiling one pass's shader at a time -- does not. The
  game's own log carries no such warning, which is what says the cause is the
  harness. See `HARNESS_WARNINGS`; the split is on the reported code because
  this `fxc` does not accept `/wd`.
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
from typing import NamedTuple

REPO = Path(__file__).resolve().parent.parent
SHADERS = REPO / "Shaders"
WORK = REPO / "tools" / ".work"

# Pinned so the evidence is reproducible: crosire/reshade-shaders @ main.
HEADER_COMMIT = "6db142b4b1a05c764222e5b0bd9a644b7ccfe1dc"
HEADERS = ("ReShade.fxh", "ReShadeUI.fxh", "DrawText.fxh")
HEADER_URL = "https://raw.githubusercontent.com/crosire/reshade-shaders/{}/Shaders/{}"

# Windows Kits roots in both spellings, WSL's /mnt/c and native Windows' C:\.
# The candidates that are not real on the running host simply do not exist, so
# scanning the whole list needs no host detection to get wrong.
KITS = (
    "/mnt/c/Program Files (x86)/Windows Kits/10/bin",
    "/mnt/c/Program Files/Windows Kits/10/bin",
    r"C:\Program Files (x86)\Windows Kits\10\bin",
    r"C:\Program Files\Windows Kits\10\bin",
)

# (name, extra definitions). Every switch is `#ifndef`-guarded in the shader, so
# defining one in the prelude is exactly the path a ReShade-level definition or a
# preset takes -- the check exercises the override rather than a patched copy, and
# every combination is compiled so a guard that drops a pass from the technique
# body cannot hide.
BASE_VARIANTS = (
    ("default", {}),
    ("antibloom-off", {"AutoMaskAntiBloom": "0"}),
    ("diagnostics", {"AutoMaskDiagnostics": "1"}),
    ("antibloom-off-diagnostics", {"AutoMaskAntiBloom": "0", "AutoMaskDiagnostics": "1"}),
)
# The compute switch swaps a pass for one of another type instead of removing it,
# and the depth switch adds a pass at full resolution, so both are crossed with
# everything rather than added beside the four: a guard that drops or misbinds a
# pass has to show at every setting and neither switch may hide the other's.
VARIANTS = tuple(
    (name + ("-compute" if compute else "") + ("-depth" if depth else ""),
     dict(definitions, AutoMaskCompute=str(compute), AutoMaskDepthMotion=str(depth)))
    for depth in (0, 1)
    for compute in (0, 1)
    for name, definitions in BASE_VARIANTS
)
# A changed variant list is exactly where a silently skipped variant could hide, and
# the names are built by concatenating suffixes, so a base name that already ends in
# one of them collides rather than erroring. Two variants under one name means the
# report shows the same combination twice and the other is never compiled, so it is
# refused here instead of being read as coverage that is not there.
_names = [name for name, _ in VARIANTS]
_duplicates = sorted({name for name in _names if _names.count(name) > 1})
if _duplicates:
    # `sys.exit` rather than `fail` below: this runs at import, before the helper
    # is defined.
    sys.exit("FAIL -- duplicate variant name(s) %s; the list must be a crossing of "
             "distinct combinations, or one variant silently stands in for another"
             % ", ".join(_duplicates))
# Sized to the longest variant name so the report stays aligned as switches are added.
VARIANT_WIDTH = max(len(name) for name in _names)

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
# Entry points come in two shapes, and which one a function is decides how it is
# compiled. Both patterns are deliberately NOT line-anchored: a generated entry
# point can sit mid-line once macros expand.
PIXEL_ENTRY_POINT = re.compile(
    r'(?:float4|float3|float2|void)\s+(\w+)\s*\([^)]*\)\s*:\s*SV_Target')
# A compute entry point is a void function, addressed by a group-size attribute on
# it or by a thread-addressing parameter. ReShade takes the group size from the
# function or inline in the pass, so either shape is an entry point; a pass
# binding a name neither pattern finds cannot hide, because every binding is
# cross-checked against the entry points gathered here.
COMPUTE_ENTRY_POINT = re.compile(
    r'\[\s*numthreads\s*\([^)]*\)\s*\]\s*void\s+(\w+)\s*\(')
COMPUTE_ENTRY_POINT_THREADED = re.compile(
    r'void\s+(\w+)\s*\([^)]*SV_(?:DispatchThreadID|GroupID|GroupThreadID|GroupIndex)[^)]*\)')

# The fxc profile each kind of entry point compiles under.
PROFILES = {"pixel": "ps_5_0", "compute": "cs_5_0"}

# Warning codes that are this harness's own artefact rather than a shader defect,
# and so are not failures. The reason is structural: this tool compiles the whole
# preprocessed file once per entry point, so fxc sees every function in it,
# referenced or not, while ReShade emits each pass's shader separately from that
# pass's reachable code. The real log is what proves the difference -- it carries
# no X3579 for a compute variant, which is why this is filtered here instead of
# chased in the shader:
#
# - 3579: `ps_5_0 does not support groupshared, groupshared ignored`. The
#   `groupshared` tally belongs to `CS_Accum` and is declared at file scope because
#   the dialect forbids it inside a shader body (X3010), so a whole-file compile of
#   a pixel entry point carries it into a pixel profile and fxc remarks on it. No
#   pixel pass in the game reaches that declaration. `fxc` here does not accept
#   `/wd` ("Unknown or invalid option" under D3DCompiler 43), so the split has to
#   happen on the codes as reported.
#
# Everything else is the shader's own, and a warning ReShade would print into the
# log the user reads is a defect rather than a note, so it fails the check.
HARNESS_WARNINGS = frozenset((3579,))
WARNING = re.compile(r"warning (X\d+):")

# ReShade's compute dialect is not HLSL: storage objects, group barriers and the
# atomic family are its own surface vocabulary, and ReShade's own codegen
# translates them before handing the result to a shader compiler (storage becomes
# a `RWTexture*`, `barrier()` becomes `GroupMemoryBarrierWithGroupSync()`, and the
# atomics become the `Interlocked*` family). fxc compiles the source itself here,
# so the same translation is written out below -- otherwise no compute entry point
# could be compiled at all, and the whole point of stage 1 would be unreachable.
#
# The declaration spelling of a storage is `<dimension><element>`, and the group
# the storage belongs to is its position in the file; fxc wants neither, so the
# `{ Texture = ...; }` block is dropped and the element type goes into the
# `RWTexture` form.
#
# The dimension letter is CAPITAL and only these spellings are real: ReShade's own
# lexer registers `storage`, `storage1D`, `storage2D` and `storage3D`, nothing
# else. `storage2d` therefore lexes as an ordinary identifier and the declaration
# fails inside ReShade with a bare X3000 pointing at the line rather than the case
# -- and since this tool rewrites the dialect before compiling, a pattern that
# accepted either case would translate an invalid shader into a valid one and
# report it clean. So the pattern is strict here and the near-miss is a loud
# failure below.
STORAGE = re.compile(
    r'\bstorage(1D|2D|3D)?\s*<\s*(\w+)\s*>\s*(\w+)'
    r'\s*(?::[^{};]*)?\{[^{}]*\}\s*;')
# A storage keyword with the dimension letter lowercased: not a keyword at all to
# ReShade, so it is a failure here rather than something to rewrite.
MISSPELLED_STORAGE = re.compile(r'\bstorage[123]d\b')
# Names fxc implements and ReShade's parser does not, so the compile below cannot
# see the mistake: the source is well-formed HLSL and only the effect parser
# rejects it, with X3004 (`undeclared identifier or no matching intrinsic
# overload`). `fmod` is the one that reached a game -- it passed every variant
# here and failed to load -- so the set is refused rather than left to the
# compiler. It is ReShade's own intrinsic table, read from
# `source/effect_symbol_table_intrinsics.inl`, crossed against the HLSL names fxc
# has: everything ReShade does provide (`frac`, `floor`, `round`, `saturate`,
# `lerp`, `smoothstep`, `step`, `mad`, `ddx`/`ddy`, the `tex2D*` family) is
# absent from this list on purpose, and the list is a deny set rather than an
# allow set, so an ordinary identifier -- a local, a uniform, a user function --
# is never mistaken for a missing intrinsic. It is not a translation gap like the
# storage spellings above, so nothing here is rewritten; the call is simply
# refused.
NOT_IN_RESHADE = frozenset((
    "fmod", "clip", "dst", "lit", "noise", "fma", "msad4", "D3DCOLORtoUBYTE4",
    "tex1Dbias", "tex1Dproj", "tex2Dbias", "tex2Dproj", "tex3Dbias", "tex3Dproj",
    "texCUBE", "texCUBEbias", "texCUBEgrad", "texCUBElod", "texCUBEproj",
))
# Matched as a call -- `name(` -- because these only matter where they are called,
# and a bare word has to stay legal so prose and identifiers are untouched. The
# longest names come first so `texCUBElod` is not read as `texCUBE`.
NOT_IN_RESHADE_CALL = re.compile(
    r'\b(%s)\s*\(' % "|".join(sorted(NOT_IN_RESHADE, key=len, reverse=True)))
# The other half of the same blind spot, and a third form of it: a word ReShade's
# lexer emits as a reserved token rather than an identifier. fxc has no such token,
# so `float sample = ...` compiles here and fails in ReShade with X3000 (`unexpected
# 'reserved word', expected 'identifier'`) at load -- which is how this reached a
# game. The list is read from ReShade's own lexer, `source/effect_lexer.cpp`, the
# `(name, tokenid::reserved)` table, not guessed. It is a deny set, so an ordinary
# identifier is never mistaken for a reserved word, and the type-like entries
# (`double`, `half`, `Texture2D`) are in it on purpose: ReShade lexes those as
# reserved too, so writing one as an identifier fails there whatever fxc makes of it.
RESERVED_WORDS = frozenset((
    "SamplerState", "Texture1D", "Texture1DArray", "Texture2D", "Texture2DArray",
    "Texture2DMS", "Texture2DMSArray", "Texture3D", "TextureCube", "TextureCubeArray",
    "asm", "asm_fragment", "auto", "cast", "catch", "centroid", "char", "class",
    "column_major", "compile", "const_cast", "delete", "double", "dynamic_cast", "enum",
    "explicit", "external", "foreach", "friend", "globallycoherent", "goto", "half",
    "half2", "half2x1", "half2x2", "half2x3", "half2x4", "half3", "half3x1", "half3x2",
    "half3x3", "half3x4", "half4", "half4x1", "half4x2", "half4x3", "half4x4", "inline",
    "interface", "long", "mutable", "new", "noinline", "operator", "packed", "packoffset",
    "private", "protected", "public", "register", "reinterpret_cast", "restrict",
    "row_major", "sample", "sampler1DArray", "sampler2DArray", "sampler2DMS",
    "sampler2DMSArray", "samplerCUBE", "samplerCube", "samplerCubeArray", "samplerRECT",
    "samplerRect", "sampler_state", "shared", "short", "signed", "sizeof", "snorm",
    "static_cast", "template", "textureCUBE", "textureRECT", "this", "try", "typedef",
    "union", "unorm", "unsigned", "using", "virtual",
))
# A bare word, so a member (`a.sample`) is refused too -- ReShade rejects the token
# wherever it stands -- while an identifier that merely contains one (`sampler2D`) is
# untouched by the word boundaries. The longest names come first so `half2x1` is read
# before `half2`, and `half` before it as well.
RESERVED_WORD = re.compile(
    r'\b(%s)\b' % "|".join(sorted(RESERVED_WORDS, key=len, reverse=True)))
# A function the shader defines itself, read the same way the entry points are: a
# type keyword, then the name, then a parameter list. A local definition of one of
# the names above is legal in ReShade -- the call resolves to it before any
# intrinsic lookup -- so the guard must not refuse a shader that supplies its own.
FUNCTION_DEFINITION = re.compile(
    r'\b(?:void|float[234]?|half[234]?|double[234]?|int[234]?|uint[234]?|bool[234]?'
    r'|min16\w*|matrix\s*<[^>]+>)\s+(\w+)\s*\(')
STORAGE_DIMENSIONS = {None: "2D", "1D": "1D", "2D": "2D", "3D": "3D"}
# Reading and writing a storage object goes through these intrinsics: a storage
# cannot be indexed in the dialect at all. Its element type is a storage type
# rather than a vector, matrix or array, and the index-expression rule accepts
# only those three -- so `store[coord]` is rejected by ReShade's own parser with
# X3121 (`array, matrix, vector, or indexable object type expected in index
# expression`), reported against the call site rather than the declaration. The
# two intrinsics are the only legal access, and ReShade's codegen emits the
# `name[coord]` form for them before handing the result to a shader compiler,
# which is the same rewrite written out below. The dimensions are spelled as
# ReShade's intrinsics are (`tex1Dfetch`/`tex2Dstore`/`tex3Dstore`), and the
# count of arguments is fixed: a load takes the object and its coordinate, a
# store takes those plus the value.
STORAGE_ACCESS = re.compile(r'\btex([123])D(fetch|store)\s*\(')
MISSPELLED_STORAGE_ACCESS = re.compile(r'\btex[123]d(fetch|store)\b')
STORAGE_ACCESS_ARITY = {"fetch": 2, "store": 3}
# A call, so the arguments are read by balancing parens rather than by a regex:
# an argument can itself contain parens and commas (`uint2(0, 0)`), which a
# comma-splitting pattern would cut through the middle of.
ATOMIC = re.compile(r'\batomic(Add|And|Or|Xor|Min|Max|Exchange|CompareExchange)\s*\(')
# The group barrier and the two memory barriers, which are ReShade intrinsics with
# no fxc counterpart under those names. `barrier` needs the word boundary so it does
# not match inside the other two.
BARRIERS = (
    (re.compile(r'\bbarrier\s*\(\s*\)'), "GroupMemoryBarrierWithGroupSync()"),
    (re.compile(r'\bgroupMemoryBarrier\s*\(\s*\)'), "GroupMemoryBarrier()"),
    (re.compile(r'\bmemoryBarrier\s*\(\s*\)'), "AllMemoryBarrier()"),
)
TECHNIQUE = re.compile(r'technique\s+(\w+)[^{]*\{', re.S)
# A pass may be named (`pass P0 {`) or not (`pass {`), so the name is optional.
# Requiring it to be absent silently matches nothing for a named pass, which is
# indistinguishable from a technique that has no passes at all.
PASS = re.compile(r'pass\s+(?:\w+\s*)?\{([^}]*)\}')
INSTRUCTION_COUNT = re.compile(r'// Approximately (\d+) instruction slots used')


class Pass(NamedTuple):
    """One pass of a technique, as the wiring reads it from the source.

    `kind` is the shader type the pass runs, and it is what decides how the
    entry point compiles. `dispatch` is the group count a compute pass declares
    (x, y and optionally z); a pixel pass has none. `targets` is every render
    target the pass binds, in index order, so a merge of several passes into one
    cannot hide a target it folded behind the check.
    """

    technique: str
    shader: str | None
    kind: str
    targets: tuple[str, ...]
    dispatch: tuple[str, ...] | None


class EntryPoint(NamedTuple):
    """A compilable function and the profile its shape compiles under."""

    name: str
    kind: str


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_fxc() -> Path:
    """Locate fxc.exe: $FXC, then PATH, then the newest Windows Kits SDK.

    The lookup is host-agnostic and runs under WSL and natively on Windows
    alike: the kits sit behind /mnt/c under WSL and behind C:\\ natively, and
    the candidates that are not real on the running host simply do not exist,
    so both spellings are scanned and neither needs detecting.

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
    for root in KITS:
        kits = Path(root)
        if kits.is_dir():
            kits_found += [p / "x64" / "fxc.exe" for p in kits.iterdir()
                           if (p / "x64" / "fxc.exe").is_file()]
    if not kits_found:
        fail("fxc.exe not found; set $FXC to its path (needs the Windows SDK)")
    kits_found.sort(key=lambda p: [int(n) for n in re.findall(r"\d+", p.parent.parent.name)])
    return kits_found[-1]


def windows_path(path: Path) -> str:
    """Hand the path over in the spelling fxc.exe wants on the running host.

    Under WSL the check runs on the Linux side and fxc on the Windows side, so
    the path crosses the boundary and wslpath -w translates it. Natively both
    run on Windows and the path already is in the right spelling.
    """
    if sys.platform == "win32":
        return str(path)
    out = subprocess.run(["wslpath", "-w", str(path)],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def run_fxc(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([str(FXC)] + args, cwd=WORK, capture_output=True,
                          text=True, errors="replace")


def first_error(log: str) -> str:
    match = re.search(r"error X\d+: .*", log)
    return match.group(0).strip() if match else "unknown compile failure"


def fail(why: str) -> None:
    """Exit with a `FAIL -- ...` message. Every guard reports this way, and the exit
    is the point: a check that prints and carries on reports a clean run over data it
    could not read.
    """
    sys.exit("FAIL -- " + why)


def report_hits(label: str, hits: list[str], advice: str) -> int:
    """Print a non-empty hit list under `label` and report the run as failed, so the
    docs check's two lists share one copy of the printing and of that decision.
    """
    if not hits:
        return 0
    print("FAIL -- %d %s:" % (len(hits), label))
    for hit in hits:
        print("  " + hit)
    print("\n" + advice)
    return 1


def source_files() -> list[Path]:
    return sorted(SHADERS.glob("*.fx"))


def header_files() -> list[Path]:
    """The shaders' own headers, `.fxh`, in `Shaders/`.

    Separate from `source_files` on purpose: a header holds no entry point, so
    compiling it as a source is not just unnecessary but wrong -- it would report
    "no entry points found" and "no technique passes found" for a file that is not
    meant to have either. It is still this project's source in every way that
    matters to the comment budget, and it still has to reach the workspace, because
    a shader `#include`s it by name and the preprocessor resolves that against the
    including file's own directory.
    """
    return sorted(SHADERS.glob("*.fxh"))


def workspace_sources() -> list[Path]:
    """Every file the preprocessor needs in the workspace: the shaders and their headers."""
    return source_files() + header_files()


# ---------------------------------------------------------------------- check-docs
# The prose budget every `.md` here and the README keep: state the fact and stop,
# without framing that describes the writing rather than its subject. It is the one
# rule with no other consequence -- the compile check never opens a `.md` -- so the
# mechanically detectable half of it is refused here rather than left to memory.
# docs/editing-conventions.md holds the reasoning; `--list` prints the entries.
#
# The framing is matched by its *verb*, not by a noun alone: "this section explains
# X" is the banned construction, while "this section calls the cheapest half the
# pair" is an internal cross-reference. So the noun alone is not refused.
#
# Deliberately NOT here, because each is usually a real claim: `which is why` and
# `that is why` (a causal link is information), `load-bearing` (a fact about the
# design), and `should`/`must` (an instruction, which is what a convention is).
PROSE_PHRASES = (
    (r"this (?:section|document|review|file|page|chapter)\s+(?:explains?|describes?|shows?|outlines?|"
     r"lists?|covers?|presents?|states?|sets out|summarises|summarizes|examines)",
     "names the writing and its verb rather than the subject"),
    (r"(?:the|this) (?:section|document|review|file|page|chapter) (?:above|below)",
     "points at reading order instead of the fact; use a section number"),
    (r"as (?:we|i) (?:saw|noted|said|have seen|have said)",
     "points at the reading order rather than the fact"),
    (r"as (?:noted|described|stated|explained) (?:above|below|earlier)",
     "points at the reading order rather than the fact"),
    (r"worth (?:stating|recording|noting|saying|mentioning|pointing out)\b",
     "announces that a statement is valuable instead of making it"),
    (r"it is (?:important|worth) (?:to )?(?:note|mention|say)",
     "announces that a statement is valuable instead of making it"),
    (r"it should be (?:noted|said|mentioned|observed)",
     "announces that a statement is valuable instead of making it"),
    (r"in other words", "restatement by construction"),
    (r"as if it were (?:cheap|free|neutral|trivial|obvious)",
     "a rhetorical frame rather than a measurement"),
    (r"(?:that|this) is the (?:strongest|best|main) argument",
     "a worth-label rather than the argument itself"),
    (r"the purpose of this|the goal (?:here )?is to (?:explain|describe|show)",
     "describes the writing's intent rather than its subject"),
)
PROSE = tuple((re.compile(r"(?<![\w-])(?:%s)(?![\w-])" % pattern, re.I), why)
              for pattern, why in PROSE_PHRASES)
# A line carrying this marker is skipped -- the escape hatch for a phrase that is
# genuinely the subject rather than framing, e.g. quoting the rule itself.
PROSE_ALLOW = "prose-ok"
PROSE_FENCE = re.compile(r"^\s*(?:```|~~~)")
PROSE_FILES = (REPO / "README.md", REPO / "AGENTS.md", *(REPO / "docs").glob("*.md"))

# The budget's second half, which only the shader breaks: a comment block longer than
# this is refused, the same way a banned phrase is. `AGENTS.md` calls the HLSL comments
# short and sparse, and this is what "short" is worth in lines -- a number, so a block
# that outgrows the file's own register is a decision rather than a drift. It is not a
# ratio of comments to code: commit history has comment-only commits and one-line fixes
# with a paragraph of reasoning, so that number says nothing about whether a comment
# earns its place. Length is the half a machine can see.
COMMENT_BLOCK_MAX = 4
# The credit block at the head of the shader is fenced with this, and is exempt: it is
# the one ruled block the file's conventions name as an exception.
COMMENT_FENCE = re.compile(r"^\s*//\+{8,}\s*$")


def prose_lines(text: str) -> list[tuple[int, str]]:
    """The lines with fenced code and inline code spans blanked out.

    A phrase inside code is not prose, and this file's own list quotes the
    phrases, so the span is dropped rather than reported.
    """
    kept: list[tuple[int, str]] = []
    in_fence = False
    for number, line in enumerate(text.splitlines(), 1):
        if PROSE_FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        kept.append((number, re.sub(r"`[^`]*`", "", line)))
    return kept


def comment_block_hits() -> list[str]:
    """Every `//` block in the shaders and their headers longer than COMMENT_BLOCK_MAX.

    A run of adjacent `//` lines is one block, so wrapping a comment further down
    counts as lengthening it rather than spreading it. The credit header is fenced
    with `////...` and is skipped, fence and body both, since it is the file's one
    named exception.
    """
    hits: list[str] = []
    for path in workspace_sources():
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        first, last = 0, 0
        for number, line in enumerate(lines + [""], 1):
            fenced = COMMENT_FENCE.match(line)
            commented = line.strip().startswith("//") and not fenced
            if commented and first == 0:
                first = number
            if commented:
                last = number
                continue
            if first and not fenced:
                length = last - first + 1
                block = "\n".join(lines[first - 1:last])
                if length > COMMENT_BLOCK_MAX and PROSE_ALLOW not in block:
                    hits.append("%s:%d-%d: %d-line comment block"
                                % (path.relative_to(REPO), first, last, length))
            # The fence sits just above the header it closes, so entering or leaving
            # the fenced run also ends any block in progress.
            first = last = 0
    return hits


def cmd_check_docs(args) -> int:
    if args.list:
        for pattern, why in PROSE_PHRASES:
            print("%-72s %s" % (pattern, why))
        print("%-72s %s" % ("// block longer than %d lines" % COMMENT_BLOCK_MAX,
                            "the HLSL half of the budget: short and sparse, or marked prose-ok"))
        return 0
    files = [path for path in PROSE_FILES if path.is_file()]
    if not files:
        # Nothing to check is not a pass; say so rather than reporting a clean run.
        fail("no prose files found; nothing was read")
    hits: list[str] = []
    for path in files:
        for number, line in prose_lines(path.read_text(encoding="utf-8", errors="replace")):
            if PROSE_ALLOW in line:
                continue
            for pattern, why in PROSE:
                match = pattern.search(line)
                if match:
                    hits.append("%s:%d: %r -- %s"
                                % (path.relative_to(REPO), number, match.group(0), why))
    failed = report_hits("prose-budget hit(s)", hits,
                         "State the fact and stop. See: "
                         "uv run tools/verify_shaders.py check-docs --list")
    if failed:
        return failed
    long_blocks = comment_block_hits()
    failed = report_hits("comment block(s) over %d lines" % COMMENT_BLOCK_MAX, long_blocks,
                         "Split the block or say it in fewer lines. See: "
                         "uv run tools/verify_shaders.py check-docs --list")
    if failed:
        return failed
    print("PASS -- %d prose file(s), no framing from the list" % len(files))
    return 0


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

def without_comments(text: str) -> str:
    """The source with `//` comments dropped, so prose cannot trip a guard.

    This file's own tooltips name the spellings the guards below refuse, and a
    comment quoting one is not a use of it.
    """
    return re.sub(r"//[^\n]*", "", text)


def include_names(path: Path) -> set[str]:
    """The `.fx`/`.fxh` names `path` includes by quotes, as written.

    `#include` is what decides whether a stale copy in the workspace can stand in
    for a file that is gone, so the names are read from the source rather than
    guessed: a header the shader does not include is a scratch file of the
    author's, not this check's business.
    """
    text = without_comments(path.read_text(encoding="utf-8", errors="replace"))
    return set(re.findall(r'#include\s+"([^"]+\.fxh?)"', text))


def clear_stale_workspace(keep: set[str]) -> list[str]:
    """Delete workspace copies of this project's shader files that no longer exist in it.

    A copy left from an earlier run is a file the current run must not resolve
    against: with a deleted header's stale copy still sitting there, the include
    succeeds and the check reports a clean pass for a shader that cannot load in the
    game -- the loud-failure property the module docstring opens with. The sweep is
    deliberately narrow: only a name the sources themselves `#include` is removed, so
    the author's own probes and captured assembly under `tools/.work/` are left alone.
    """
    removed: list[str] = []
    for name in sorted(keep):
        stale = WORK / name
        if (name.endswith((".fx", ".fxh")) and stale.is_file()
                and not (SHADERS / name).is_file() and name not in HEADERS):
            stale.unlink()
            removed.append(name)
    return removed


def build_workspace(source: Path, definitions: dict[str, str]) -> Path:
    """Preprocess one shader into the workspace; returns the preprocessed path."""
    # Every shader and header is copied in, because a shader `#include`s its header
    # by name and the preprocessor resolves that against its own directory -- `/I`
    # cannot stand in for the copy, since a name that collides with one in the
    # ReShade headers would then be resolved from the wrong file.
    workspace = workspace_sources()
    clear_stale_workspace({name for path in workspace for name in include_names(path)})
    for path in workspace:
        shutil.copy(path, WORK / path.name)
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
        fail("preprocessing failed: %s" % first_error(result.stdout + result.stderr))
    return WORK / "preprocessed.i"


def strip_for_fxc(text: str) -> str:
    """Turn the `.fx` dialect into source fxc can compile.

    Two jobs. Annotations and technique blocks carry no code, so they go -- the
    technique strip runs to end-of-file, which assumes the techniques are the
    last thing in the shader. That is the ReShade convention and what the pack
    does. If code ever followed them it would be dropped here, and a missing
    symbol would surface as a compile error -- loud, not silent.

    Then the compute dialect, which is what ReShade's own codegen emits before it
    calls a shader compiler: storage objects become `RWTexture*`, the group and
    memory barriers get their HLSL names, and the atomics become `Interlocked*`.
    A storage element is addressed as it is in the dialect; the two-argument form
    addresses a `groupshared` variable directly, and the three-argument form picks
    an element out of a storage, which is the only difference between them.
    """
    text = ANNOTATION.sub("", text)
    # Loud guard: if any annotation residue survives, fxc reports it as an
    # unrecognized identifier far from the cause (`ui_type` with no hint that a
    # tooltip broke the strip). Fail here instead, naming the construct.
    residue = re.search(r'\b(ui_\w+|__UNIFORM_\w+)\s*=', text)
    if residue:
        fail("annotation stripping left %r in the source; the "
             "annotation pattern is wrong" % residue.group(0))
    # Loud guard, same reasoning as the annotation one above: a storage keyword
    # ReShade does not know is not a compile error here, because the translation
    # below would rewrite it into valid HLSL and the check would pass a shader the
    # game cannot load. The dimension letter is capital in ReShade's lexer, so a
    # lowercased one is exactly that case.
    misspelled = MISSPELLED_STORAGE.search(without_comments(text))
    if misspelled:
        fail("%r is not a ReShade keyword; the dimension letter is "
             "capital (storage, storage1D, storage2D, storage3D). ReShade "
             "lexes it as an identifier and fails with a bare X3000, and this "
             "check would otherwise translate it into valid HLSL and report it "
             "clean" % misspelled.group(0))
    # Loud guard, on the same reasoning as the storage keyword one above: the
    # intrinsic name is case sensitive, and the translation below would rewrite
    # a lowercased one into valid HLSL, so the misspelling has to fail here.
    misspelled_access = MISSPELLED_STORAGE_ACCESS.search(without_comments(text))
    if misspelled_access:
        fail("%r is not a ReShade intrinsic; the dimension letter is "
             "capital (tex1Dfetch, tex2Dfetch, tex3Dfetch and their store "
             "counterparts). ReShade would report the bare identifier as "
             "undeclared, and this check would otherwise translate it into "
             "valid HLSL and report it clean" % misspelled_access.group(0))
    # Loud guard, the same class as the two above and a third form of it: a word
    # ReShade lexes as a reserved token. fxc has no such token, so this source is
    # well-formed HLSL and the compile below succeeds on a shader ReShade refuses
    # with X3000 -- `float sample = ...` did exactly that. Comments and string
    # literals are dropped first, since `sample` is an ordinary English word and
    # this file's own tooltips say it.
    reserved = RESERVED_WORD.search(drop_comments_and_strings(text))
    if reserved:
        fail("%r is a reserved word in ReShade's lexer, so it cannot be "
             "an identifier there and the effect fails at load with X3000 "
             "('unexpected reserved word, expected identifier'); fxc accepts it, "
             "so this check would compile it clean. Rename the identifier"
             % reserved.group(0))
    # Loud guard, on the same reasoning as the two above but a different cause: the
    # name is real HLSL, so fxc compiles it and the translation has nothing to do
    # with it. Only ReShade's parser rejects it, and it does so at load time with
    # X3004 -- which is a shader that passes this check and fails in the game.
    # A definition of the same name is read out so a shader supplying its own is
    # not refused for calling it.
    code = without_comments(text)
    defined = set(FUNCTION_DEFINITION.findall(code))
    not_in_reshade = [name for name in NOT_IN_RESHADE_CALL.findall(code)
                      if name not in defined]
    if not_in_reshade:
        fail("%r is called but is not one of the intrinsics ReShade's "
             "parser knows, so the effect would fail to load with X3004 "
             "('undeclared identifier or no matching intrinsic overload') while "
             "compiling cleanly here, because fxc does implement it. Use a form "
             "ReShade provides (integer arithmetic, %% , frac, floor, round) "
             "instead" % sorted(not_in_reshade)[0])
    text = re.sub(r"(?sm)^[ \t]*technique\b.*\Z", "", text)
    # Guard before any translation below: the bracket form this rejects is what
    # the access translation produces on its way out, and the declaration names
    # are what it has to read, so it needs the source as written.
    guard_storage_index(text, storages_in(text))
    text = translate_storage(text)
    for pattern, replacement in BARRIERS:
        text = pattern.sub(replacement, text)
    text = translate_atomics(text)
    return translate_storage_access(text)


def drop_comments_and_strings(text: str) -> str:
    """The source with string literals and comments blanked out.

    Reserved words are ordinary English -- `sample`, `new`, `this` -- so a guard
    that read prose or a tooltip would refuse a file over its own comments.
    Strings are blanked before comments for a reason: a `//` inside a literal
    would otherwise be read as a comment and cut the literal short.
    """
    text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return without_comments(text)


def storages_in(text: str) -> set[str]:
    """The names a storage object is declared as.

    The one property a storage declaration carries is its `Texture`, so the name
    to look for in an index expression is the declared name, not the texture's:
    that is the symbol in scope at the call site.
    """
    return {match.group(3) for match in STORAGE.finditer(text)}


def guard_storage_index(text: str, names: set[str]) -> None:
    """Refuse a storage object indexed directly, the way ReShade does.

    A storage cannot be indexed in this dialect at all, so the source this tool
    compiles and ReShade rejects has to be caught here rather than translated
    into valid HLSL: the declaration's element type is a storage type rather
    than a vector, matrix or array, and the index-expression rule accepts only
    those three. ReShade reports it against the call site -- `array, matrix,
    vector, or indexable object type expected in index expression` (X3121) --
    while this check would compile the translated `name[coord]` form clean,
    which is exactly how this reached a real game. Reading and writing a storage
    goes through `tex2Dfetch`/`tex2Dstore` (see `translate_storage_access`).
    """
    code = without_comments(text)
    for name in sorted(names):
        if re.search(r'\b%s\s*\[' % re.escape(name), code):
            fail("'%s' is a storage object, which cannot be indexed in "
                 "ReShade (it would fail with X3121, 'array, matrix, vector, or "
                 "indexable object type expected in index expression'); read and "
                 "write it with tex2Dfetch/tex2Dstore. This check would otherwise "
                 "translate the bracket access into valid HLSL and report it clean"
                 % name)


def translate_storage(text: str) -> str:
    def rewrite(match: re.Match) -> str:
        dimensions = STORAGE_DIMENSIONS[match.group(1)]
        return "RWTexture%s<%s> %s;" % (dimensions, match.group(2), match.group(3))
    return STORAGE.sub(rewrite, text)


def call_arguments(text: str, open_paren: int) -> tuple[list[str], int]:
    """The arguments of the call whose `(` is at `open_paren`, and its `)`."""
    depth, index, arguments, current = 1, open_paren + 1, [], ""
    while index < len(text):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                break
        if char == "," and depth == 1:
            arguments.append(current)
            current = ""
        else:
            current += char
        index += 1
    arguments.append(current)
    return [argument.strip() for argument in arguments], index


def rewrite_calls(text: str, pattern: re.Pattern, render) -> str:
    """Rewrite every call `pattern` finds, with `render` deciding the replacement.

    Both translations below are the same scan: find a call, read its arguments by
    balancing parens (see `call_arguments`), and emit something else in its place.
    Only the emitted text differs, so the walk lives here and each caller supplies a
    `render(match, arguments) -> str`.
    """
    out: list[str] = []
    index = 0
    while True:
        match = pattern.search(text, index)
        if not match:
            out.append(text[index:])
            return "".join(out)
        out.append(text[index:match.start()])
        arguments, close = call_arguments(text, match.end() - 1)
        out.append(render(match, arguments))
        index = close + 1


def translate_atomics(text: str) -> str:
    """Rewrite the atomic family into its `Interlocked*` counterpart.

    The argument shapes differ from the HLSL ones: the dialect takes a storage
    object and an index as two arguments, HLSL takes the addressed element. The
    shared-variable form is passed through with the name alone changed, which is
    the same call in both.

    `atomicCompareExchange` has no expression form in HLSL -- it needs an `out`
    variable for the original, which a call cannot supply -- so it is refused
    rather than translated into something that would not compile for a reason
    nothing here could explain. It is not used by this shader.
    """
    def render(match: re.Match, arguments: list[str]) -> str:
        name = "Interlocked%s" % match.group(1)
        if match.group(1) == "CompareExchange":
            fail("atomicCompareExchange has no HLSL expression form "
                 "(it needs an out parameter); translate it by hand if it is "
                 "ever needed")
        if len(arguments) == 3:
            return "%s(%s[%s], %s)" % (name, arguments[0], arguments[1], arguments[2])
        return "%s(%s)" % (name, ", ".join(arguments))
    return rewrite_calls(text, ATOMIC, render)


def translate_storage_access(text: str) -> str:
    """Rewrite the storage-access intrinsics into the HLSL they stand for.

    This is the other half of the storage translation above: ReShade's dialect
    has no bracket access on a storage object at all, so the only way to read or
    write one is `tex2Dfetch(s, coord)` / `tex2Dstore(s, coord, value)`, and
    ReShade's own codegen turns those into `s[coord] = value` before calling a
    shader compiler. fxc compiles the source itself here, so the same rewrite is
    written out -- and, as with the storage keyword, the spelling the rewrite
    touches is pinned to the real one (see `MISSPELLED_STORAGE_ACCESS`).

    The call is read by balancing parens rather than by a regex, so an argument
    can be any expression. Both forms end at the same place -- the value's
    position in the call -- which is why one function covers the load and the
    store: a load names the element, a store names it and assigns to it. An
    arity that is not the fixed one is a loud failure, because a mismatch would
    otherwise be silently dropped on the floor here while ReShade rejected it.
    """
    def render(match: re.Match, arguments: list[str]) -> str:
        kind = match.group(2)
        if len(arguments) != STORAGE_ACCESS_ARITY[kind]:
            fail("tex%sD%s takes %d argument(s) in ReShade but %d were "
                 "given; the call cannot be translated and would otherwise be "
                 "dropped silently"
                 % (match.group(1), kind, STORAGE_ACCESS_ARITY[kind], len(arguments)))
        addressed = "%s[%s]" % (arguments[0], arguments[1])
        return addressed if kind == "fetch" else "%s = %s" % (addressed, arguments[2])
    return rewrite_calls(text, STORAGE_ACCESS, render)


def entry_points(text: str) -> dict[str, str]:
    """Every entry point in the source, mapped to the kind of shader it is.

    The kind is read from the shape of the function rather than from the pass
    that binds it, because that is what fxc's target has to match: a compute
    entry point compiled at `ps_5_0` fails on its thread-address semantic, and a
    pixel entry point compiled at `cs_5_0` fails on `SV_Target`.
    """
    found: dict[str, str] = {}
    for name in PIXEL_ENTRY_POINT.findall(text):
        found[name] = "pixel"
    for pattern in (COMPUTE_ENTRY_POINT, COMPUTE_ENTRY_POINT_THREADED):
        for name in pattern.findall(text):
            found.setdefault(name, "compute")
    return found


def technique_bindings(preprocessed: str) -> list[Pass]:
    """Every pass of every technique, in order, as it is wired in the source.

    Compiling a single entry point discards the technique blocks, so the pass
    wiring has to be read from the preprocessed source. This is what shows the
    passes still bind the same shader in the documented order -- and what makes
    a pass dropped by a guard visible as a missing pass rather than a silent
    pass. Compute passes are read for their dispatches here; a compute pass
    without both dispatch sizes is rejected the way ReShade rejects it, so a
    technique that loses a compute pass cannot pass for a technique that never
    had one.
    """
    text = without_comments(preprocessed)
    out: list[Pass] = []
    for tech, body in technique_blocks(text):
        passes = PASS.findall(body)
        # Cross-check the parse against the keyword count, the same way the
        # instruction count is cross-checked against the histogram: a pattern
        # that misses a pass must not look like a technique with fewer passes.
        keywords = len(re.findall(r"\bpass\b", body))
        if keywords != len(passes):
            fail("technique %s: parsed %d pass(es) but found %d pass keyword(s); "
                 "the pass pattern is wrong" % (tech, len(passes), keywords))
        found: list[Pass] = []
        for one in passes:
            cs = re.search(r"ComputeShader\s*=\s*(\w+)", one)
            ps = re.search(r"PixelShader\s*=\s*(\w+)", one)
            kind = "compute" if cs else "pixel"
            shader = cs or ps
            # Every render target the pass binds, in index order: RenderTarget,
            # RenderTarget1, ... ReShade accepts only indices 0-7, so the parse
            # carries just those; an index it does not (RenderTarget8) is left
            # unparsed and caught by the keyword cross-check below rather than
            # passing as a target ReShade would reject at load.
            targets = tuple(
                match.group(2)
                for match in sorted(
                    re.finditer(r"RenderTarget([0-7]?)\s*=\s*(\w+)", one),
                    key=lambda m: int(m.group(1) or 0)))
            dispatch = tuple(match.group(1).strip() for match in re.finditer(
                r"DispatchSize[XYZ]\s*=\s*([^;\n]+?)\s*;", one))
            if kind == "compute" and len(dispatch) < 2:
                # ReShade's own error 3012: a compute pass needs both sizes, and
                # a pass that lost one to a bad guard would otherwise read as a
                # pass that simply has fewer properties.
                fail("technique %s: compute pass '%s' declares %d dispatch "
                     "size(s); ReShade requires both DispatchSizeX and DispatchSizeY"
                     % (tech, shader.group(1) if shader else "?", len(dispatch)))
            found.append(Pass(tech, shader.group(1) if shader else None, kind,
                              targets, dispatch or None))
        # The parse is cross-checked against the keyword counts the same way the
        # pass list is: a compute binding or dispatch size the patterns miss must
        # not look like a pass that never declared one.
        for label, pattern, parsed in (
                ("ComputeShader", r"\bComputeShader\b\s*=",
                 sum(1 for bound in found if bound.kind == "compute")),
                ("DispatchSize", r"\bDispatchSize[XYZ]\b\s*=",
                 sum(len(bound.dispatch or ()) for bound in found)),
                ("RenderTarget", r"\bRenderTarget[0-9]*\b\s*=",
                 sum(len(bound.targets) for bound in found))):
            keywords = len(re.findall(pattern, body))
            if keywords != parsed:
                fail("technique %s: parsed %d %s binding(s) but found %d keyword(s); "
                     "the pass pattern is wrong" % (tech, parsed, label, keywords))
        out += found
    return out


def compile_entry(stripped: Path, entry: EntryPoint) -> dict:
    asm = WORK / ("%s.asm" % entry.name)
    binary = WORK / ("%s.bin" % entry.name)
    # Never let a previous run's output be mistaken for this run's result.
    for stale in (asm, binary):
        stale.unlink(missing_ok=True)
    result = run_fxc(["/Gec", "/T", PROFILES[entry.kind], "/E", entry.name,
                      "/I", windows_path(WORK), stripped.name,
                      "/Fc", asm.name, "/Fo", binary.name])
    log = result.stdout + result.stderr
    if result.returncode != 0:
        return {"status": "error", "error": first_error(log)}
    if not binary.is_file():
        # Compiling "succeeded" but emitted nothing: refuse to report it as ok.
        return {"status": "error", "error": "fxc produced no bytecode for %s" % entry.name}
    warnings = [code for code in WARNING.findall(log)
                if int(code[1:]) not in HARNESS_WARNINGS]
    text = asm.read_text(encoding="utf-8", errors="replace")
    match = INSTRUCTION_COUNT.search(text)
    histogram: dict[str, int] = {}
    # fxc's slot count covers executable instructions only, so dcl_* is excluded
    # here too -- otherwise the cross-check trips on a purely definitional gap.
    body = text.split(PROFILES[entry.kind], 1)[-1]
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
        return {"status": "error", "error": "no instruction count in the assembly for %s" % entry.name}
    if sum(histogram.values()) != instructions:
        return {"status": "error",
                "error": "histogram sums to %d but fxc reports %d instructions"
                         % (sum(histogram.values()), instructions)}
    return {"status": "ok", "instructions": instructions,
            "histogram": dict(sorted(histogram.items())),
            "bytecode_sha256": sha256_file(binary),
            "warnings": warnings}


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


def cmd_check(args) -> int:
    if not (WORK / "ReShade.fxh").is_file():
        fail("headers missing; run: uv run tools/verify_shaders.py init")
    sources = source_files()
    if not sources:
        # Nothing to check is not a pass. Say so loudly rather than reporting a
        # clean run over an empty set.
        fail("no shaders found in %s; nothing was compiled"
             % SHADERS.relative_to(REPO))

    failed: list[str] = []
    print("%-*s %-30s %6s  %s" % (VARIANT_WIDTH, "variant", "entry point", "instr", "status"))
    for name, definitions in VARIANTS:
        for source in sources:
            preprocessed = build_workspace(source, definitions)
            text = preprocessed.read_text(encoding="utf-8", errors="replace")
            bindings = technique_bindings(text)
            entries = entry_points(text)
            if not entries:
                failed.append("%s %s: no shader entry points found"
                              % (name, source.name))
                continue
            if not bindings:
                # A shader with no technique passes is not a shader: something
                # dropped them, either a guard or a broken parse. Never a pass.
                failed.append("%s %s: no technique passes found; nothing was wired up"
                              % (name, source.name))
                continue
            if args.pass_list:
                for bound in bindings:
                    wire = bound.shader or "?"
                    if bound.dispatch:
                        wire += " [%s]" % ", ".join(bound.dispatch)
                    target = " + ".join(bound.targets) or "?"
                    print("  %-*s %-22s %-9s %s -> %s"
                          % (VARIANT_WIDTH, name, bound.technique, bound.kind, wire, target))
            # Every binding is checked twice: against the entry points that exist,
            # and against the kind its shape declares. A pass whose shader is a
            # compute entry point but whose function the patterns read as a pixel
            # one would otherwise be compiled at the wrong profile and reported
            # clean.
            missing = sorted({bound.shader for bound in bindings
                              if bound.shader and bound.shader not in entries})
            if missing:
                failed.append("%s %s: techniques bind %s but no such entry point was found"
                              % (name, source.name, ", ".join(missing)))
            for bound in bindings:
                actual = entries.get(bound.shader)
                if actual and actual != bound.kind:
                    failed.append("%s %s: pass binds %s as a %s shader but it reads as a %s one"
                                  % (name, source.name, bound.shader, bound.kind, actual))
            stripped = WORK / "stripped.fx"
            stripped.write_text(strip_for_fxc(text), encoding="utf-8", newline="\n")
            for entry_name, kind in sorted(entries.items()):
                outcome = compile_entry(stripped, EntryPoint(entry_name, kind))
                if outcome["status"] != "ok":
                    failed.append("%s %s %s (%s): %s"
                                  % (name, source.name, entry_name, kind,
                                     outcome.get("error")))
                elif outcome["warnings"]:
                    # A warning is a failure, not a note. ReShade prints every
                    # warning its compile emits into the log it shows the user,
                    # so shipping one means shipping an unreadable log -- which
                    # is how a real warning gets missed. The harness's own
                    # artefact is filtered out of the list it was read from
                    # (see `HARNESS_WARNINGS`), so everything reaching here is
                    # the shader's own.
                    failed.append("%s %s %s (%s): compiled with %s"
                                  % (name, source.name, entry_name, kind,
                                     ", ".join(outcome["warnings"])))
                status = outcome["status"]
                if status == "ok" and outcome["warnings"]:
                    status = "WARN"
                print("%-*s %-30s %6s  %s"
                      % (VARIANT_WIDTH, name, entry_name,
                         outcome.get("instructions", "-"), status))
                if args.hashes and outcome["status"] == "ok":
                    print("  %s %s sha256=%s" % (name, entry_name, outcome["bytecode_sha256"]))
                if args.opcodes and outcome["status"] == "ok":
                    for opcode, count in outcome["histogram"].items():
                        print("      %-14s %d" % (opcode, count))
            print("  %s: %d technique pass(es): %s"
                  % (name, len(bindings),
                     ", ".join(bound.shader or "?" for bound in bindings)))

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
    check.add_argument("--hashes", action="store_true",
                       help="print the bytecode sha256 of each shader, for comparing "
                            "a variant against the same variant before a change")
    check.add_argument("--pass-list", action="store_true",
                       help="print each technique's passes before compiling")
    check.set_defaults(func=cmd_check)

    docs = sub.add_parser("check-docs",
                          help="refuse prose framing in README.md, AGENTS.md and docs/*.md")
    docs.add_argument("--list", action="store_true",
                      help="print the refused phrases and why each is refused")
    docs.set_defaults(func=cmd_check_docs)

    args = parser.parse_args()
    if args.func is not cmd_check_docs:
        # Only the shader check needs the Windows compiler; a docs-only run must
        # not fail for the want of it.
        global FXC
        FXC = find_fxc()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
