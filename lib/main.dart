import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:draw_your_image/draw_your_image.dart';
import 'package:flutter/material.dart';

/// Chalkboard sample app.
///
/// Write with white chalk on a dark green chalkboard and erase with a
/// blackboard eraser. There are only four elements:
/// 1. Board surface (dark green + wipe marks / dust vignette) — [ChalkboardBackgroundPainter]
/// 2. Chalk strokes (powdery, scratchy look via a grain noise shader)
/// 3. Eraser (BlendMode.dstOut + the same noise for a "patchy erase with
///    scratchy leftovers" look)
/// 4. Clear all
///
/// Stroke input, storage, and saveLayer compositing are delegated to the
/// [Draw] widget from the draw_your_image package; this file only builds
/// "how a single stroke is painted" (the Paint layers). The chalk scratchiness
/// comes from the fragment shader in shaders/chalk.frag.
void main() {
  runApp(const ChalkboardSampleApp());
}

class ChalkboardSampleApp extends StatelessWidget {
  const ChalkboardSampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Chalkboard Sample',
      debugShowCheckedModeBanner: false,
      home: ChalkboardPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Tuning values (every visual knob lives here)
// ---------------------------------------------------------------------------

/// Tuning parameters that define the chalkboard's look (single place to edit).
abstract final class ChalkboardTuning {
  // --- Board surface ---
  /// Base color of the board (dark green). Slightly brighter, used near the
  /// center.
  static const Color boardColor = Color(0xFF2F4A3A);

  /// Darker green falling off toward the edges (the vignette of a well-used
  /// board).
  static const Color boardEdgeColor = Color(0xFF213528);

  /// Number of wipe-mark / chalk-dust smudges. More means a more worn look.
  static const int smudgeCount = 28;

  /// Fixed seed for smudge generation. Keeps the board surface deterministic
  /// so it doesn't flicker across rebuilds.
  static const int smudgeSeed = 20240720;

  /// Blur radius of a smudge (px). Larger spreads the mark more softly.
  static const double smudgeBlur = 14.0;

  // --- White chalk (core) ---
  /// Chalk color (white with a slight warm tint).
  static const Color chalkColor = Color(0xFFF3F1E7);

  /// Base chalk width. Varies with stylus pressure.
  static const double chalkWidth = 12.0;

  /// How "packed" the chalk core is. Smaller drops more grains and looks more
  /// scratchy (0..1).
  static const double chalkDensity = 0.72;

  /// Grain size of the chalk (px per cell). Smaller makes finer grains.
  static const double chalkGrain = 2.6;

  // --- White chalk (soft halo = powderiness) ---
  /// Opacity of the faint halo laid under the core. Adds a dusty feel.
  static const double chalkHaloAlpha = 0.16;

  /// Blur radius of the halo (px).
  static const double chalkHaloBlur = 3.5;

  // --- Eraser ---
  /// Width of the band swept by the eraser (px).
  static const double eraserWidth = 52.0;

  /// How thoroughly the eraser erases. Smaller leaves more residue (0..1).
  static const double eraserDensity = 0.9;

  /// Grain size of the eraser noise (px per cell). Coarser than the chalk to
  /// make the patches larger.
  static const double eraserGrain = 3.4;

  /// Opacity of the "smeared chalk dust" white layered over erased areas.
  /// Kept very faint.
  static const double eraserDustAlpha = 0.05;

  /// Blur radius of the chalk dust layer (px).
  static const double eraserDustBlur = 7.0;
}

// ---------------------------------------------------------------------------
// Pure logic (board smudge generation / stroke seeding)
// ---------------------------------------------------------------------------

/// A single wipe-mark / chalk-dust smudge on the board. Position and radii are
/// stored as normalized values (0..1) independent of screen size, and scaled
/// to actual coordinates at paint time.
class ChalkSmudge {
  const ChalkSmudge({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.rotation,
    required this.opacity,
    required this.lighten,
  });

  /// Center (normalized 0..1 coordinates).
  final Offset center;

  /// Horizontal / vertical radii (ratio 0..1 of width / height).
  final double radiusX;
  final double radiusY;

  /// Rotation of the ellipse (radians). Represents the varying direction of
  /// wipes.
  final double rotation;

  /// Opacity (0..1). Kept small since it is layered thinly over the surface.
  final double opacity;

  /// true = a wiped, brightened mark (whitish) / false = dark chalk-dust
  /// residue (blackish).
  final bool lighten;
}

/// Deterministically generates the board's texture smudges. The same [seed]
/// always yields the same sequence, so the surface looks identical across
/// rebuilds.
List<ChalkSmudge> generateChalkboardSmudges({
  int count = ChalkboardTuning.smudgeCount,
  int seed = ChalkboardTuning.smudgeSeed,
}) {
  final rng = math.Random(seed);
  return List<ChalkSmudge>.generate(count, (_) {
    // Favor brightened wipe marks to get the whitish, hazy look of a
    // well-used board.
    final lighten = rng.nextDouble() < 0.62;
    return ChalkSmudge(
      center: Offset(rng.nextDouble(), rng.nextDouble()),
      radiusX: 0.08 + rng.nextDouble() * 0.22,
      radiusY: 0.04 + rng.nextDouble() * 0.12,
      rotation: rng.nextDouble() * math.pi,
      // Whitish wipe marks directly add haze to the board, so keep them at
      // about half the opacity of the dust residue.
      opacity: lighten
          ? 0.015 + rng.nextDouble() * 0.0225
          : 0.02 + rng.nextDouble() * 0.045,
      lighten: lighten,
    );
  });
}

/// Builds a deterministic per-stroke seed value (roughly 0..1000) from the
/// stroke's representative point ([p] = the first point of the stroke). Passed
/// as u_seed to the chalk/eraser noise shader so each stroke gets its own
/// grain pattern, while the same stroke always repaints identically
/// (no flicker).
double chalkSeedForPoint(Offset p) {
  // Quantize to a 2px grid before hashing so a 1-2px jitter doesn't change
  // the seed.
  final xi = (p.dx / 2).round();
  final yi = (p.dy / 2).round();
  // Mix with the usual large primes for spatial hashing, then clamp to
  // non-negative.
  var h = (xi * 73856093) ^ (yi * 19349663);
  h &= 0x7fffffff;
  return (h % 100000) / 100.0;
}

// ---------------------------------------------------------------------------
// CustomPainter for the board surface
// ---------------------------------------------------------------------------

/// CustomPainter that draws the board surface (dark green + subtle texture
/// smudges).
///
/// A background-only layer laid *under* the chalk stroke layer ([Draw]). It
/// receives precomputed [ChalkSmudge]s and simply scales the normalized
/// coordinates to the size and layers faint ellipses.
class ChalkboardBackgroundPainter extends CustomPainter {
  const ChalkboardBackgroundPainter({required this.smudges});

  /// Deterministically pre-generated wipe marks / dust smudges.
  final List<ChalkSmudge> smudges;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Surface: slightly brighter in the center, darkening toward the edges
    // (the vignette of a well-used board).
    final base = Paint()
      ..shader = ui.Gradient.radial(
        rect.center,
        size.longestSide * 0.72,
        const [ChalkboardTuning.boardColor, ChalkboardTuning.boardEdgeColor],
        const [0.0, 1.0],
      );
    canvas.drawRect(rect, base);

    // Wipe marks and chalk dust. Light = whitish wiped marks,
    // dark = blackish dust residue.
    for (final s in smudges) {
      final center = Offset(
        s.center.dx * size.width,
        s.center.dy * size.height,
      );
      final rx = s.radiusX * size.width;
      final ry = s.radiusY * size.height;
      final color = (s.lighten ? Colors.white : Colors.black).withValues(
        alpha: s.opacity,
      );
      final paint = Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          ChalkboardTuning.smudgeBlur,
        );
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(s.rotation);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant ChalkboardBackgroundPainter oldDelegate) =>
      oldDelegate.smudges != smudges;
}

// ---------------------------------------------------------------------------
// Chalkboard page
// ---------------------------------------------------------------------------

/// The tool currently in use: write with chalk or erase with the eraser.
enum ChalkTool { chalk, eraser }

/// Chalkboard screen. Structured as a three-layer [Stack]:
/// 1. Board surface (dark green + texture smudges) drawn by
///    [ChalkboardBackgroundPainter].
/// 2. A transparent-background [Draw] on top for chalk/eraser strokes.
///    [Draw] composites strokes inside a saveLayer, so the eraser's
///    `BlendMode.dstOut` erases only this layer's chalk and never affects the
///    board surface below.
/// 3. Minimal floating controls (chalk/eraser toggle + clear all).
class ChalkboardPage extends StatefulWidget {
  const ChalkboardPage({super.key});

  @override
  State<ChalkboardPage> createState() => _ChalkboardPageState();
}

class _ChalkboardPageState extends State<ChalkboardPage> {
  /// Completed strokes (chalk and eraser alike, distinguished by a tag in
  /// data).
  List<Stroke> _strokes = [];

  ChalkTool _tool = ChalkTool.chalk;

  /// Board texture smudges are generated deterministically once and never
  /// rebuilt.
  final List<ChalkSmudge> _smudges = generateChalkboardSmudges();

  /// Fragment shader for grain noise. Null until loading completes; in the
  /// meantime a shaderless fallback is used (never crashes before load or on
  /// failure).
  ui.FragmentProgram? _program;

  bool get _isEraser => _tool == ChalkTool.eraser;

  @override
  void initState() {
    super.initState();
    // Load the shader asynchronously. Swallow failures and rely on the
    // fallback painting.
    ui.FragmentProgram.fromAsset('shaders/chalk.frag').then((program) {
      if (mounted) setState(() => _program = program);
    }, onError: (_, _) {});
  }

  /// Tags a starting stroke with the current tool and width. Eraser strokes
  /// get the #eraser flag, which strokePainter uses to switch behavior.
  Stroke _configure(Stroke stroke) {
    return _isEraser
        ? stroke.copyWith(
            width: ChalkboardTuning.eraserWidth,
            data: {#eraser: true},
          )
        : stroke.copyWith(width: ChalkboardTuning.chalkWidth);
  }

  void _clear() => setState(() => _strokes = []);

  /// Chalk uses pressureSensitive for its characteristic width variation;
  /// the eraser uses catmullRom (centerline) to keep the band uniform.
  ui.Path _buildPath(Stroke stroke) {
    return stroke.data?[#eraser] == true
        ? PathBuilderMode.catmullRom.converter(stroke)
        : PathBuilderMode.pressureSensitive.converter(stroke);
  }

  /// Builds a [Paint] using the grain noise shader. Returns null when the
  /// shader is not loaded yet, letting the caller fall back.
  Paint? _grainPaint(
    Size size, {
    required double seed,
    required double grain,
    required double density,
    required Color color,
    required PaintingStyle style,
    required BlendMode blend,
    double? strokeWidth,
  }) {
    final program = _program;
    if (program == null) return null;
    // Create a fresh shader instance per stroke (sharing one would give every
    // stroke the same uniforms). The uniform order matches the declaration
    // order in chalk.frag.
    final shader = program.fragmentShader();
    shader.setFloat(0, size.width); // u_resolution.x
    shader.setFloat(1, size.height); // u_resolution.y
    shader.setFloat(2, color.r); // u_color.r
    shader.setFloat(3, color.g); // u_color.g
    shader.setFloat(4, color.b); // u_color.b
    shader.setFloat(5, color.a); // u_color.a
    shader.setFloat(6, seed); // u_seed
    shader.setFloat(7, grain); // u_grain
    shader.setFloat(8, density); // u_density
    final paint = Paint()
      ..shader = shader
      ..style = style
      ..strokeCap = StrokeCap.round
      ..blendMode = blend;
    if (strokeWidth != null) paint.strokeWidth = strokeWidth;
    return paint;
  }

  /// Returns the Paint layers for one stroke: grainy core + faint halo
  /// (chalk) / patchy erase + smeared dust (eraser), each ordered bottom to
  /// top.
  List<Paint> _paintStroke(Stroke stroke, Size size) {
    // The seed derives from the stroke's coordinates and is deterministic, so
    // the grain pattern survives rebuilds unchanged.
    final seed = stroke.points.isNotEmpty
        ? chalkSeedForPoint(stroke.points.first.position)
        : 0.0;
    return stroke.data?[#eraser] == true
        ? _eraserPaints(stroke, size, seed)
        : _chalkPaints(size, seed);
  }

  List<Paint> _chalkPaints(Size size, double seed) {
    return [
      // 1) Faint halo (powderiness): a blurred, thin white fill. Shows
      //    through the gaps in the core.
      Paint()
        ..color = ChalkboardTuning.chalkColor.withValues(
          alpha: ChalkboardTuning.chalkHaloAlpha,
        )
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          ChalkboardTuning.chalkHaloBlur,
        ),
      // 2) Core: white chalk with its alpha punched out by grain noise.
      _grainPaint(
            size,
            seed: seed,
            grain: ChalkboardTuning.chalkGrain,
            density: ChalkboardTuning.chalkDensity,
            color: ChalkboardTuning.chalkColor,
            style: PaintingStyle.fill,
            blend: BlendMode.srcOver,
          ) ??
          // Fallback (shader not loaded): a solid fill with no grain.
          (Paint()
            ..color = ChalkboardTuning.chalkColor
            ..style = PaintingStyle.fill),
    ];
  }

  List<Paint> _eraserPaints(Stroke stroke, Size size, double seed) {
    return [
      // 1) Patchy erase: dstOut. Erases by the noise's alpha, leaving
      //    scratchy remnants.
      _grainPaint(
            size,
            seed: seed,
            grain: ChalkboardTuning.eraserGrain,
            density: ChalkboardTuning.eraserDensity,
            color: Colors.white,
            style: PaintingStyle.stroke,
            blend: BlendMode.dstOut,
            strokeWidth: stroke.width,
          ) ??
          // Fallback (shader not loaded): erase the swept area uniformly with
          // dstOut.
          (Paint()
            ..color = Colors.white
            ..blendMode = BlendMode.dstOut
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke.width
            ..strokeCap = StrokeCap.round),
      // 2) Smeared chalk dust: a very faint blurred white layered over the
      //    erased area with srcOver.
      Paint()
        ..color = ChalkboardTuning.chalkColor.withValues(
          alpha: ChalkboardTuning.eraserDustAlpha,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          ChalkboardTuning.eraserDustBlur,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ChalkboardTuning.boardColor,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
              // 1) Board surface (outside Draw's saveLayer), untouched by the
              //    eraser compositing.
              Positioned.fill(
                child: CustomPaint(
                  painter: ChalkboardBackgroundPainter(smudges: _smudges),
                ),
              ),
              // 2) Chalk stroke layer. Transparent background so the surface
              //    below shows through.
              Positioned.fill(
                child: Draw(
                  strokes: _strokes,
                  backgroundColor: Colors.transparent,
                  strokeColor: ChalkboardTuning.chalkColor,
                  strokeWidth: ChalkboardTuning.chalkWidth,
                  pathBuilder: _buildPath,
                  onStrokeStarted: (newStroke, currentStroke) =>
                      currentStroke ?? _configure(newStroke),
                  onStrokeDrawn: (stroke) =>
                      setState(() => _strokes = [..._strokes, stroke]),
                  strokePainter: (stroke) => _paintStroke(stroke, size),
                ),
              ),
              // 3) Minimal controls (chalk/eraser + clear all).
              Positioned(
                right: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: _ChalkControls(
                  tool: _tool,
                  onToolChanged: (tool) => setState(() => _tool = tool),
                  onClear: _strokes.isEmpty ? null : _clear,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Control cluster. Minimal setup: chalk/eraser selection and clear all only.
class _ChalkControls extends StatelessWidget {
  const _ChalkControls({
    required this.tool,
    required this.onToolChanged,
    required this.onClear,
  });

  final ChalkTool tool;
  final ValueChanged<ChalkTool> onToolChanged;

  /// Null (disabled) when nothing has been drawn yet.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // A tray one shade darker than the board, to lift the buttons.
        color: ChalkboardTuning.boardEdgeColor.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(
            icon: Icons.edit,
            selected: tool == ChalkTool.chalk,
            onTap: () => onToolChanged(ChalkTool.chalk),
          ),
          const SizedBox(width: 10),
          _ToolButton(
            icon: Icons.rectangle,
            selected: tool == ChalkTool.eraser,
            onTap: () => onToolChanged(ChalkTool.eraser),
          ),
          // Clear-all plays a different role than tool selection, so give it
          // a wider separating gap.
          const SizedBox(width: 18),
          _RoundButton(
            onTap: onClear,
            color: const Color(0xFFB5654A),
            child: const Icon(
              Icons.delete_sweep,
              color: Colors.white,
              size: 26,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tool (chalk/eraser) selection button. The selected one is lifted in chalk
/// white; unselected ones sink into a board-matching green.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final base = selected
        ? ChalkboardTuning.chalkColor
        : const Color(0xFF56705E);
    final iconColor = selected ? ChalkboardTuning.boardEdgeColor : Colors.white;
    return _RoundButton(
      onTap: onTap,
      color: base,
      child: Icon(icon, color: iconColor, size: 26),
    );
  }
}

/// Rounded push button, kept minimal with a bare GestureDetector + Container
/// to avoid extra dependencies.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.onTap,
    required this.color,
    required this.child,
  });

  final VoidCallback? onTap;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: enabled ? color : color.withValues(alpha: 0.4),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: child,
      ),
    );
  }
}
