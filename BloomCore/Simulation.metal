// 滲みシミュレーションの Metal カーネル群。
// BloomCore framework の default.metallib にコンパイルされ、
// SimulationEngine が Bundle(for:) 経由でロードする。
//
// 顔料は float3 = RGB 各チャンネルの吸光度(Beer-Lambert)。ブラシの色は
// K = -ln(color) として吸光度に変換され、スタンプ時に積まれる。流れ方・乾き方は
// チャンネル共通の物理に乗り、render で paper * exp(-pigment) で色になる。
// 異なる色が重なると吸光度が加算される = 減法混色になる。
#include <metal_stdlib>
using namespace metal;

// Swift 側の SimParams / Stamp とレイアウトを一致させること
struct SimParams {
    uint  width;
    uint  height;
    float flowRate;        // 水の移動係数
    float evapRate;        // 蒸発量 / substep
    float depositRate;     // 乾燥時の顔料沈着率
    float paperInfluence;  // 紙の凹凸が水頭に与える影響
    float wetThreshold;    // これ未満は「乾いている」
    float edgeEvapBoost;   // 濡れ領域の縁での蒸発ブースト(エッジダークニング)
    float granulation;     // 紙の谷への沈着強調(粒状感)
    uint  stampCount;
    float activeFactor;    // render でアクティブ層を合成する係数(非表示なら 0)
    float coverageK;       // 顔料量 → 被覆(不透明度)への変換係数
    float activeOpacity;   // アクティブ層の不透明度
};

// --- レイヤー合成のヘルパー(アフィングレーズ)-------------------------
// 各層は下の色 r を r → a·r + b に変換する。
//   a = T·(1-occ), b = T·occ,  T = exp(-D)(透過色), occ = opacity·被覆
// 薄い顔料(occ≈0)は a≈T,b≈0 で純粋な乗算フィルタ = 全力で色を付けつつ下を透かす(水彩)。
// 濃い顔料(occ≈1)は a≈0,b≈T で下を自分の色に置き換える(不透明)。
// アフィン変換は合成できるので、下/上の層スタックは (A,B) 1 組へ畳み込める。
struct Affine { float3 a; float3 b; };

static inline Affine layerAffine(float3 D, float opacity, float coverageK) {
    float lum = dot(D, float3(0.299, 0.587, 0.114));
    float occ = opacity * (1.0 - exp(-coverageK * lum));
    float3 T = exp(-D);
    return Affine{ T * (1.0 - occ), T * occ };
}

// acc(下から積んだ変換)の上に層変換 L を重ねる: 合成 = L ∘ acc
static inline void composeAffine(thread float3& accA, thread float3& accB, Affine L) {
    accA = L.a * accA;
    accB = L.a * accB + L.b;
}

struct Stamp {
    float2 pos;      // グリッド座標
    float  radius;
    float  water;
    float3 pigment;  // RGB 吸光度の増分(色 × 量)
    float  dryness;  // 0: ウェット(全面に乗る) / 1: ドライ(紙の凸部にだけ乗る = かすれ)
};

static inline uint idxOf(uint2 g, uint width) { return g.y * width + g.x; }

// --- ブラシスタンプ: 水と顔料を落とす ---------------------------------
kernel void stampKernel(device float*        W      [[buffer(0)]],
                        device float3*       P      [[buffer(1)]],
                        constant Stamp*      stamps [[buffer(2)]],
                        constant SimParams&  prm    [[buffer(3)]],
                        device const float*  H      [[buffer(4)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.width || gid.y >= prm.height) return;
    float2 pos = float2(gid);
    uint i = idxOf(gid, prm.width);
    float w = W[i];
    float3 p = P[i];
    float h = H[i];
    for (uint s = 0; s < prm.stampCount; s++) {
        float d = distance(pos, stamps[s].pos);
        float r = stamps[s].radius;
        if (d < r) {
            float t = d / r;
            float fall = 1.0 - t * t;
            fall *= fall; // 柔らかい四次フォールオフ
            // ドライブラシ: 紙の凸部(H 高)にだけ顔料が引っかかる = かすれ
            float grainMask = mix(1.0, smoothstep(0.45, 0.62, h), stamps[s].dryness);
            w += stamps[s].water * fall * grainMask;
            p += stamps[s].pigment * (fall * grainMask);
        }
    }
    // 水の上限を高めに取ると、中心に高い水頭の溜まりができて外へ押し出す力が生まれる(ブルーム)
    W[i] = min(w, 8.0);
    P[i] = min(p, float3(6.0));
}

// --- 水流: 水頭(水量 + 紙の凹凸)の差で水が動き、顔料を運ぶ -----------
kernel void flowKernel(device const float*  Win  [[buffer(0)]],
                       device const float3* Pin  [[buffer(1)]],
                       device float*        Wout [[buffer(2)]],
                       device float3*       Pout [[buffer(3)]],
                       device const float*  H    [[buffer(4)]],
                       constant SimParams&  prm  [[buffer(5)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.width || gid.y >= prm.height) return;
    uint i = idxOf(gid, prm.width);
    float wi = Win[i];
    float3 pi = Pin[i];
    float headI = wi + prm.paperInfluence * H[i];

    float newW = wi;
    float3 newP = pi;

    const int2 offs[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int n = 0; n < 4; n++) {
        int2 nc = int2(gid) + offs[n];
        if (nc.x < 0 || nc.y < 0 || nc.x >= int(prm.width) || nc.y >= int(prm.height)) continue;
        uint j = idxOf(uint2(nc), prm.width);
        float wj = Win[j];
        float3 pj = Pin[j];
        float headJ = wj + prm.paperInfluence * H[j];
        float f = prm.flowRate * (headJ - headI); // f > 0: j -> i に流入
        if (f > 0.0) {
            if (wj <= prm.wetThreshold) continue;     // 乾いた場所からは流れない(ピン留め)
            float amt = min(f, wj * 0.2);             // 隣の保有量で制限(対称なので質量保存)
            newW += amt;
            newP += pj * (amt / max(wj, 1e-4));
        } else {
            if (wi <= prm.wetThreshold) continue;
            float amt = min(-f, wi * 0.2);
            newW -= amt;
            newP -= pi * (amt / max(wi, 1e-4));
        }
    }
    Wout[i] = max(newW, 0.0);
    Pout[i] = max(newP, float3(0.0));
}

// --- 乾燥: 蒸発(縁ほど速い)と顔料の沈着 ------------------------------
kernel void dryKernel(device float*        W   [[buffer(0)]],
                      device float3*       P   [[buffer(1)]],
                      device float3*       D   [[buffer(2)]],
                      device const float*  H   [[buffer(3)]],
                      constant SimParams&  prm [[buffer(4)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.width || gid.y >= prm.height) return;
    uint i = idxOf(gid, prm.width);
    float w = W[i];
    float3 p = P[i];
    if (w <= 0.0 && p.x <= 0.0 && p.y <= 0.0 && p.z <= 0.0) return;

    // 濡れた隣接セルが少ない = 縁 → 蒸発を強める(エッジダークニングの源)
    // 隣接セルは他スレッドが同時更新中なので近似値だが、視覚目的には十分
    float wetN = 0.0;
    const int2 offs[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int n = 0; n < 4; n++) {
        int2 nc = int2(gid) + offs[n];
        if (nc.x < 0 || nc.y < 0 || nc.x >= int(prm.width) || nc.y >= int(prm.height)) continue;
        if (W[idxOf(uint2(nc), prm.width)] > prm.wetThreshold) wetN += 1.0;
    }
    float evap = prm.evapRate * (1.0 + prm.edgeEvapBoost * (1.0 - wetN / 4.0));
    float wNew = max(w - evap, 0.0);

    // 失われた水の割合に応じて顔料が紙に沈着する。紙の谷(H が低い)ほど多く = 粒状感
    float lossFrac = (w > 1e-4) ? clamp((w - wNew) / w, 0.0, 1.0) : 1.0;
    float grain = 1.0 + prm.granulation * (0.5 - H[i]);
    float3 dep = min(p * (lossFrac * prm.depositRate * grain), p);
    p -= dep;
    D[i] += dep;

    if (wNew <= 0.0) { // 完全に乾いたら残りも全て沈着
        D[i] += p;
        p = float3(0.0);
    }
    W[i] = wNew;
    P[i] = p;
}

// --- レイヤー合成: アフィン累積 (accA, accB) の上に 1 層を重ねる ----------
// 下→上の順で各層を dispatch して below/above の (A,B) を畳み込む。
// accA は単位元 1、accB は 0 で初期化しておくこと。
kernel void compositeLayerKernel(device float3*       accA    [[buffer(0)]],
                                 device float3*       accB    [[buffer(1)]],
                                 device const float3* D       [[buffer(2)]],
                                 constant float&      opacity [[buffer(3)]],
                                 constant SimParams&  prm     [[buffer(4)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.width || gid.y >= prm.height) return;
    uint i = idxOf(gid, prm.width);
    float3 A = accA[i], B = accB[i];
    composeAffine(A, B, layerAffine(D[i], opacity, prm.coverageK));
    accA[i] = A;
    accB[i] = B;
}

// --- 表示: 紙の色 × Beer-Lambert 吸収 ----------------------------------
static float sampleBilinear(device const float* buf, float2 pos, uint w, uint h)
{
    float2 mx = float2(float(w - 1), float(h - 1));
    float2 p = clamp(pos, float2(0.0), mx);
    uint2 p0 = uint2(floor(p));
    uint2 p1 = min(p0 + 1, uint2(w - 1, h - 1));
    float2 f = p - float2(p0);
    float v00 = buf[p0.y * w + p0.x];
    float v10 = buf[p0.y * w + p1.x];
    float v01 = buf[p1.y * w + p0.x];
    float v11 = buf[p1.y * w + p1.x];
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

static float3 sampleBilinear3(device const float3* buf, float2 pos, uint w, uint h)
{
    float2 mx = float2(float(w - 1), float(h - 1));
    float2 p = clamp(pos, float2(0.0), mx);
    uint2 p0 = uint2(floor(p));
    uint2 p1 = min(p0 + 1, uint2(w - 1, h - 1));
    float2 f = p - float2(p0);
    float3 v00 = buf[p0.y * w + p0.x];
    float3 v10 = buf[p0.y * w + p1.x];
    float3 v01 = buf[p1.y * w + p0.x];
    float3 v11 = buf[p1.y * w + p1.x];
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}


// belowA/B・aboveA/B: アクティブ層より下/上の可視層を畳み込んだアフィン変換 (A,B)。
// Dactive: アクティブ層 / P: ウェット顔料(アクティブ層上に乗る)。
// 色は 紙 → 下層変換 → アクティブ層変換 → 上層変換 の順に適用する。
kernel void renderKernel(texture2d<float, access::write> out [[texture(0)]],
                         device const float*  W       [[buffer(0)]],
                         device const float3* P       [[buffer(1)]],
                         device const float3* belowA  [[buffer(2)]],
                         device const float3* belowB  [[buffer(3)]],
                         device const float3* aboveA  [[buffer(4)]],
                         device const float3* aboveB  [[buffer(5)]],
                         device const float3* Dactive [[buffer(6)]],
                         device const float*  H       [[buffer(7)]],
                         constant SimParams&  prm     [[buffer(8)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 scale = float2(prm.width, prm.height) / float2(out.get_width(), out.get_height());
    float2 g = (float2(gid) + 0.5) * scale - 0.5;

    float  ws = sampleBilinear(W, g, prm.width, prm.height);
    float3 ps = sampleBilinear3(P, g, prm.width, prm.height);
    float3 bA = sampleBilinear3(belowA, g, prm.width, prm.height);
    float3 bB = sampleBilinear3(belowB, g, prm.width, prm.height);
    float3 aA = sampleBilinear3(aboveA, g, prm.width, prm.height);
    float3 aB = sampleBilinear3(aboveB, g, prm.width, prm.height);
    float3 dActive = sampleBilinear3(Dactive, g, prm.width, prm.height);
    float  hs = sampleBilinear(H, g, prm.width, prm.height);

    float3 r = float3(0.985, 0.975, 0.960) * (0.97 + 0.03 * hs); // 紙
    r = bA * r + bB;                                             // 下層
    if (prm.activeFactor > 0.5) {                               // アクティブ層 + ウェット
        Affine L = layerAffine(dActive + ps * 0.9, prm.activeOpacity, prm.coverageK);
        r = L.a * r + L.b;
    }
    r = aA * r + aB;                                             // 上層

    r *= 1.0 - 0.06 * clamp(ws, 0.0, 1.0); // 濡れ艶
    out.write(float4(r, 1.0), gid);
}
