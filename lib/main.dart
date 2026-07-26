import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:draw_your_image/draw_your_image.dart';
import 'package:flutter/material.dart';

/// 黒板サンプルアプリ。
///
/// 深緑の黒板に白チョークで書き、黒板消しで消す。要素は4つだけ:
/// 1. 黒板の地(深緑＋拭き跡・粉ムラのビネット) — [ChalkboardBackgroundPainter]
/// 2. チョーク描画(粒状ノイズシェーダで粉っぽい掠れ)
/// 3. 黒板消し(BlendMode.dstOut ＋ 同じノイズで「まだらに消えて掠れが残る」)
/// 4. 全クリア
///
/// ストロークの入力・保持・saveLayer 合成は draw_your_image パッケージの [Draw] に
/// 任せ、このファイルは「1本のストロークをどう塗るか(Paint 層)」だけを組み立てる。
/// チョークの掠れは shaders/chalk.frag のフラグメントシェーダが作る。
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
// 調整値(見た目のつまみは全部ここ)
// ---------------------------------------------------------------------------

/// 黒板の見た目を決める調整パラメータの一覧(単一の置き場)。
abstract final class ChalkboardTuning {
  // --- 黒板の地 ---
  /// 黒板の基調色(深緑)。中央付近に使う明るめの緑。
  static const Color boardColor = Color(0xFF2F4A3A);

  /// 黒板の縁に向かって落とす暗い緑(使い込んだ周辺の暗がり=ビネット)。
  static const Color boardEdgeColor = Color(0xFF213528);

  /// 拭き跡・チョーク粉のムラ(スマッジ)の枚数。多いほど使用感が増す。
  static const int smudgeCount = 28;

  /// スマッジ生成の固定シード。リビルドで黒板の地がチラつかないための決定性。
  static const int smudgeSeed = 20240720;

  /// スマッジのぼかし半径(px)。大きいほど跡がふんわり広がる。
  static const double smudgeBlur = 14.0;

  // --- 白チョーク(芯) ---
  /// チョークの色(わずかに温かみのある白)。
  static const Color chalkColor = Color(0xFFF3F1E7);

  /// チョークの基準の太さ。スタイラスの筆圧で増減する。
  static const double chalkWidth = 12.0;

  /// チョーク芯の「詰まり具合」。小さいほど粒が抜けて掠れる(0..1)。
  static const double chalkDensity = 0.72;

  /// チョークの粒の細かさ(px/セル)。小さいほど細かい粒になる。
  static const double chalkGrain = 2.6;

  // --- 白チョーク(淡いハロ=粉っぽさ) ---
  /// 芯の周りに敷く淡い光背の不透明度。粉が舞った感じを足す。
  static const double chalkHaloAlpha = 0.16;

  /// 光背のぼかし半径(px)。
  static const double chalkHaloBlur = 3.5;

  // --- 黒板消し ---
  /// 黒板消しでなぞる帯の太さ(px)。
  static const double eraserWidth = 52.0;

  /// 黒板消しの「消え具合」。小さいほど消し残りが増える(0..1)。
  static const double eraserDensity = 0.9;

  /// 黒板消しのノイズの粒の粗さ(px/セル)。チョークより粗くしてムラを大きくする。
  static const double eraserGrain = 3.4;

  /// 消した跡へ重ねる「伸びたチョーク粉」の白の不透明度。ごく薄く。
  static const double eraserDustAlpha = 0.05;

  /// チョーク粉レイヤのぼかし半径(px)。
  static const double eraserDustBlur = 7.0;
}

// ---------------------------------------------------------------------------
// 純粋ロジック(黒板の地のムラ生成・ストロークのシード)
// ---------------------------------------------------------------------------

/// 黒板の拭き跡・チョーク粉の1枚分のムラ。座標・半径は画面サイズに依らない
/// 正規化値(0..1)で持ち、描画時にサイズを掛けて実座標へ直す。
class ChalkSmudge {
  const ChalkSmudge({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.rotation,
    required this.opacity,
    required this.lighten,
  });

  /// 中心(0..1 の正規化座標)。
  final Offset center;

  /// 横・縦半径(幅・高さに対する 0..1 の比率)。
  final double radiusX;
  final double radiusY;

  /// 楕円の回転(ラジアン)。拭いた向きのばらつきを表す。
  final double rotation;

  /// 不透明度(0..1)。地に薄く乗せるので小さめ。
  final double opacity;

  /// true = 拭いて明るくなった跡(白寄り) / false = チョーク粉の暗い残り(黒寄り)。
  final bool lighten;
}

/// 黒板の質感ムラを決定的に生成する。同じ [seed] なら常に同じ並びを返すので、
/// リビルドしても地の見た目が変わらない。
List<ChalkSmudge> generateChalkboardSmudges({
  int count = ChalkboardTuning.smudgeCount,
  int seed = ChalkboardTuning.smudgeSeed,
}) {
  final rng = math.Random(seed);
  return List<ChalkSmudge>.generate(count, (_) {
    // 拭き跡(明)を多めにして、使い込んで白っぽく曇った黒板らしさを出す。
    final lighten = rng.nextDouble() < 0.62;
    return ChalkSmudge(
      center: Offset(rng.nextDouble(), rng.nextDouble()),
      radiusX: 0.08 + rng.nextDouble() * 0.22,
      radiusY: 0.04 + rng.nextDouble() * 0.12,
      rotation: rng.nextDouble() * math.pi,
      // 白寄りの拭き跡は黒板の白み(曇り)に直結するため、粉残りの半分程度に抑える。
      opacity: lighten
          ? 0.015 + rng.nextDouble() * 0.0225
          : 0.02 + rng.nextDouble() * 0.045,
      lighten: lighten,
    );
  });
}

/// ストロークの代表点([p]=描き始めの点)から、そのストローク固有の決定的な
/// シード値(0..1000 程度)を作る。チョーク/黒板消しのノイズシェーダに渡す
/// u_seed に使い、ストロークごとに粒の出方を変えつつ、同じストロークなら
/// 再描画で毎回同じ見た目になるようにする(チラつき防止)。
double chalkSeedForPoint(Offset p) {
  // 1〜2px の微差でシードが暴れないよう、2px 格子へ量子化してからハッシュする。
  final xi = (p.dx / 2).round();
  final yi = (p.dy / 2).round();
  // 空間ハッシュの定番の大きな素数で撹拌し、非負へ落とす。
  var h = (xi * 73856093) ^ (yi * 19349663);
  h &= 0x7fffffff;
  return (h % 100000) / 100.0;
}

// ---------------------------------------------------------------------------
// 黒板の地を描く CustomPainter
// ---------------------------------------------------------------------------

/// 黒板の地(深緑＋うっすら質感ムラ)を描く CustomPainter。
///
/// チョークのストローク層([Draw])の「下」に敷く背景専用。計算済みの
/// [ChalkSmudge] 列を受け取り、正規化座標をサイズへ掛けて楕円を薄く重ねるだけ。
class ChalkboardBackgroundPainter extends CustomPainter {
  const ChalkboardBackgroundPainter({required this.smudges});

  /// 決定的に生成済みの拭き跡・粉ムラ。
  final List<ChalkSmudge> smudges;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 地: 中央を少し明るく、縁へ向けて暗く落とす(使い込んだ黒板のビネット)。
    final base = Paint()
      ..shader = ui.Gradient.radial(
        rect.center,
        size.longestSide * 0.72,
        const [ChalkboardTuning.boardColor, ChalkboardTuning.boardEdgeColor],
        const [0.0, 1.0],
      );
    canvas.drawRect(rect, base);

    // 拭き跡・チョーク粉。明は白寄り(拭いた跡)、暗は黒寄り(粉残り)。
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
// 黒板画面
// ---------------------------------------------------------------------------

/// いま使っている道具。チョークで書くか、黒板消しで消すか。
enum ChalkTool { chalk, eraser }

/// 黒板画面。構造は3層の [Stack]:
/// 1. 黒板の地(深緑＋質感ムラ)を [ChalkboardBackgroundPainter] で描く。
/// 2. その上に透明背景の [Draw] を重ね、チョーク/黒板消しのストロークを描く。
///    [Draw] は strokes を saveLayer 内で合成するので、黒板消しの
///    `BlendMode.dstOut` はこの層のチョークだけを消し、下の地には影響しない。
/// 3. 最小の操作系(チョーク/黒板消しの切替＋全消し)をフローティングで重ねる。
class ChalkboardPage extends StatefulWidget {
  const ChalkboardPage({super.key});

  @override
  State<ChalkboardPage> createState() => _ChalkboardPageState();
}

class _ChalkboardPageState extends State<ChalkboardPage> {
  /// 描き終えたストローク(チョーク・黒板消しとも data のタグで区別する)。
  List<Stroke> _strokes = [];

  ChalkTool _tool = ChalkTool.chalk;

  /// 黒板の質感ムラは一度だけ決定的に生成し、リビルドで作り直さない。
  final List<ChalkSmudge> _smudges = generateChalkboardSmudges();

  /// 粒状ノイズのフラグメントシェーダ。読み込み完了までは null で、その間は
  /// シェーダ無しのフォールバック描画にする(読み込み前・失敗時でも落ちない)。
  ui.FragmentProgram? _program;

  bool get _isEraser => _tool == ChalkTool.eraser;

  @override
  void initState() {
    super.initState();
    // シェーダは非同期ロード。失敗しても握りつぶし、フォールバック描画に任せる。
    ui.FragmentProgram.fromAsset('shaders/chalk.frag').then((program) {
      if (mounted) setState(() => _program = program);
    }, onError: (_, _) {});
  }

  /// 描き始めるストロークに道具のタグ・太さを付ける。黒板消しは #eraser を立て、
  /// strokePainter で消し方を切り替える。
  Stroke _configure(Stroke stroke) {
    return _isEraser
        ? stroke.copyWith(
            width: ChalkboardTuning.eraserWidth,
            data: {#eraser: true},
          )
        : stroke.copyWith(width: ChalkboardTuning.chalkWidth);
  }

  void _clear() => setState(() => _strokes = []);

  /// チョーク特有の太さ変化はチョークのときだけ pressureSensitive を使い、黒板消しは
  /// 均一な帯にするため catmullRom(中心線)にする。
  ui.Path _buildPath(Stroke stroke) {
    return stroke.data?[#eraser] == true
        ? PathBuilderMode.catmullRom.converter(stroke)
        : PathBuilderMode.pressureSensitive.converter(stroke);
  }

  /// 粒状ノイズシェーダの [Paint] を作る。シェーダ未ロードなら null を返し、
  /// 呼び出し側でフォールバックさせる。
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
    // シェーダはストロークごとに新しいインスタンスを作る(使い回すと全ストロークが
    // 同じ uniform になる)。uniform の並びは chalk.frag の宣言順に対応。
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

  /// ストローク1本ぶんの Paint 層を返す。粒状の芯＋淡いハロ(チョーク)/
  /// まだら消し＋伸びた粉(黒板消し)を、それぞれ下→上の順で重ねる。
  List<Paint> _paintStroke(Stroke stroke, Size size) {
    // シードはストローク座標由来で決定的。リビルドしても粒の並びが変わらない。
    final seed = stroke.points.isNotEmpty
        ? chalkSeedForPoint(stroke.points.first.position)
        : 0.0;
    return stroke.data?[#eraser] == true
        ? _eraserPaints(stroke, size, seed)
        : _chalkPaints(size, seed);
  }

  List<Paint> _chalkPaints(Size size, double seed) {
    return [
      // 1) 淡いハロ(粉っぽさ): 塗り面をぼかした薄い白。芯の抜けから透けて見える。
      Paint()
        ..color = ChalkboardTuning.chalkColor.withValues(
          alpha: ChalkboardTuning.chalkHaloAlpha,
        )
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          ChalkboardTuning.chalkHaloBlur,
        ),
      // 2) 芯: 粒状ノイズでアルファをまだらに抜いた白チョーク。
      _grainPaint(
            size,
            seed: seed,
            grain: ChalkboardTuning.chalkGrain,
            density: ChalkboardTuning.chalkDensity,
            color: ChalkboardTuning.chalkColor,
            style: PaintingStyle.fill,
            blend: BlendMode.srcOver,
          ) ??
          // フォールバック(シェーダ未ロード): 粒無しのベタ塗り。
          (Paint()
            ..color = ChalkboardTuning.chalkColor
            ..style = PaintingStyle.fill),
    ];
  }

  List<Paint> _eraserPaints(Stroke stroke, Size size, double seed) {
    return [
      // 1) まだら消し: dstOut。ノイズのアルファぶんだけ消え、掠れが残る。
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
          // フォールバック(シェーダ未ロード): 均一な dstOut でなぞった所を消す。
          (Paint()
            ..color = Colors.white
            ..blendMode = BlendMode.dstOut
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke.width
            ..strokeCap = StrokeCap.round),
      // 2) 伸びたチョーク粉: 消した跡へ、ごく薄い白のぼかしを srcOver で重ねる。
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
              // 1) 黒板の地(Draw の saveLayer の外)。消しゴムの合成に汚されない。
              Positioned.fill(
                child: CustomPaint(
                  painter: ChalkboardBackgroundPainter(smudges: _smudges),
                ),
              ),
              // 2) チョーク描画層。背景は透明にして下の地を見せる。
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
              // 3) 最小の操作系(チョーク/黒板消し＋全消し)。
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

/// 操作クラスタ。チョーク/黒板消しの選択と全消しだけの最小構成。
class _ChalkControls extends StatelessWidget {
  const _ChalkControls({
    required this.tool,
    required this.onToolChanged,
    required this.onClear,
  });

  final ChalkTool tool;
  final ValueChanged<ChalkTool> onToolChanged;

  /// 何も描いていないときは null(押せない)。
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // 黒板より一段暗い受け皿で、ボタンを浮かせる。
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
          // 全消しは道具選択と役割が違うので、区切りの余白を広めに取る。
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

/// 道具(チョーク/黒板消し)の選択ボタン。選択中はチョーク白で浮かせ、非選択は
/// 黒板になじむ緑にして暗く沈める。
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

/// 角丸の押しボタン。本体アプリでは自作の「ぷっくり」パーツを使うが、サンプルは
/// 依存を減らすため素の GestureDetector + Container で最小に作る。
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
