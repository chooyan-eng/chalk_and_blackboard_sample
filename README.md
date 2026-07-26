# chalkboard_sample

A self-contained Flutter sample app that renders a chalk-and-blackboard experience
using a fragment shader.

- Blackboard (background): dark-green vignette + wipe marks and chalk-dust
  unevenness (`CustomPainter`)
- Chalk drawing: grainy noise in a fragment shader reproduces the powdery,
  scratchy texture of chalk
- Eraser: the same noise shader applied with `BlendMode.dstOut`, so strokes are
  erased unevenly, leaving faint chalk traces behind
- Clear all

## Implementation Details

- **Layer structure**: a 3-layer `Stack` — the blackboard surface (background
  painter) → a transparent-background `Draw` (stroke layer) → the control UI.
  `Draw` composites strokes inside a `saveLayer`, so the eraser's
  `BlendMode.dstOut` only removes chalk in the stroke layer and never affects
  the board underneath.
- **Chalk scratchiness**: `shaders/chalk.frag` knocks out alpha in a mottled
  pattern using value noise + hashing. Chalk uses `srcOver`, while the eraser
  uses the same shader with `dstOut` (the blend mode is decided by the `Paint`
  on the Dart side; the shader only returns color and alpha).
- **Determinism**: the board's unevenness uses a fixed seed, and each stroke's
  grain uses a seed derived from the stroke's start point, so nothing flickers
  across rebuilds.
- **Fallback**: before the shader loads (or if loading fails), drawing falls
  back to solid strokes / uniform erasing, so the app still works in any
  environment.
- **Pressure sensitivity**: chalk uses `PathBuilderMode.pressureSensitive`, so
  stroke width responds to pressure with a stylus such as the Apple Pencil.
  The eraser is a uniform band (`catmullRom`).

All visual tuning values (colors, grain size, scratchiness, etc.) are gathered
in `ChalkboardTuning` in `main.dart`.
