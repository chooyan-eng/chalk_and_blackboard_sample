#version 460 core
#include <flutter/runtime_effect.glsl>

// 白チョーク / 黒板消しに共通の「粒状ノイズ」シェーダ。ストロークの塗り面(path)に
// 対して呼ばれ、ノイズでアルファをまだらに抜くことで、チョーク特有の粉っぽい掠れを
// 作る。黒板消しは同じノイズを BlendMode.dstOut の Paint で使い「まだらに消えて
// 掠れが残る」消え方にする(合成モードは Dart 側の Paint が決め、ここは色・アルファ
// だけを返す)。出力はプリマルチプライドアルファ。

uniform vec2 u_resolution; // キャンバス実寸(未使用だが LayoutBuilder から渡す)
uniform vec4 u_color;      // チョーク色(rgb)と基準アルファ(a)
uniform float u_seed;      // ストローク由来の決定的シード(粒の並びを変える)
uniform float u_grain;     // 粒の細かさ(px/セル)。小さいほど細粒
uniform float u_density;   // 詰まり具合(0..1)。小さいほど掠れる

out vec4 fragColor;

// 2D ハッシュ(0..1)。座標から擬似乱数を作る定番の実装。
float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// 値ノイズ(なめらかに補間したハッシュ)。粒に「かたまり」感を持たせる。
float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 seed = vec2(u_seed * 0.017, u_seed * 0.023);

  // 粗い塊(粉のムラ)＋細かい粒(ザラつき)を重ねてチョークらしい斑を作る。
  float coarse = valueNoise(pos / max(u_grain * 3.0, 0.5) + seed);
  float fine = hash(floor(pos / max(u_grain, 0.5)) + seed * 7.0);
  float n = mix(coarse, fine, 0.55);

  // density が高いほどしきい値が下がり、多くのセルが残る(=詰まった芯)。
  // 低いほど残るセルが減り、掠れる。両端を smoothstep でやわらげる。
  float threshold = 1.0 - u_density;
  float coverage = smoothstep(threshold - 0.18, threshold + 0.18, n);

  float alpha = u_color.a * coverage;
  // Flutter のフラグメントシェーダはプリマルチプライドアルファを期待する。
  fragColor = vec4(u_color.rgb * alpha, alpha);
}
