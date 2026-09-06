# -*- coding: utf-8 -*-
"""
generate_sfx.py — 为「青菱沃野 - 地块拼接」程序化生成游戏音效。

用法：
    python generate_sfx.py [--out DIR]

输出（相对本项目根目录）：
    audio/sfx/*.wav          44.1kHz / 16-bit / 单声道，Godot 可直接导入
    audio/sfx_preview.html   内嵌音频的试听页面（双击即可在浏览器试听）

全部声音由振荡器、滤波噪声与包络合成；随机数使用固定种子，
重复运行结果完全一致。要调整某个音效，直接改对应的 build_* 函数。
"""

import argparse
import base64
import math
import os
import wave

import numpy as np

SR = 44100
RNG = np.random.default_rng(20260905)


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

def tvec(dur: float) -> np.ndarray:
    return np.arange(int(dur * SR)) / SR


def osc(freq) -> np.ndarray:
    """freq 为标量或逐采样点频率数组，返回正弦波。"""
    freq = np.asarray(freq, dtype=float)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase)


def sweep_f(f0: float, f1: float, dur: float, curve: float = 1.0) -> np.ndarray:
    """f0 到 f1 的逐采样点瞬时频率，curve>1 后段变化更快。"""
    t = tvec(dur)
    return f0 + (f1 - f0) * (t / dur) ** curve


def noise(dur: float) -> np.ndarray:
    return RNG.standard_normal(int(dur * SR))


def slow_noise(dur: float, rate: float) -> np.ndarray:
    """平滑的慢速随机曲线（用于低频幅度调制），取值约 [-1, 1]。"""
    n_pts = int(dur * rate) + 3
    pts = RNG.standard_normal(n_pts)
    x = np.arange(n_pts) / rate
    y = np.interp(tvec(dur), x, pts)
    m = np.max(np.abs(y)) or 1.0
    return y / m


def env_exp(dur: float, attack: float, tau: float) -> np.ndarray:
    """线性起音 + 指数衰减包络。"""
    t = tvec(dur)
    a = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return a * np.exp(-np.maximum(t - attack, 0.0) / tau)


def env_ad(dur: float, attack: float, hold: float, release: float) -> np.ndarray:
    """线性起音-保持-释放包络。"""
    t = tvec(dur)
    env = np.ones_like(t)
    env[t < attack] = t[t < attack] / attack
    rel = t > dur - release
    env[rel] = np.maximum(0.0, (dur - t[rel]) / release)
    return env


# ---------------------------------------------------------------------------
# 滤波器（一阶 IIR，用截断脉冲响应 + 卷积实现，因果且无环绕伪影）
# ---------------------------------------------------------------------------

def _onepole_kernel(fc: float) -> np.ndarray:
    a = 1.0 - math.exp(-2.0 * math.pi * fc / SR)
    n = int(math.ceil(math.log(1e-4) / math.log(1.0 - a)))
    n = min(max(n, 1), 400000)
    return a * (1.0 - a) ** np.arange(n)


def lowpass(x: np.ndarray, fc: float) -> np.ndarray:
    return np.convolve(x, _onepole_kernel(fc))[: len(x)]


def highpass(x: np.ndarray, fc: float) -> np.ndarray:
    return x - lowpass(x, fc)


def bandpass(x: np.ndarray, f1: float, f2: float) -> np.ndarray:
    return lowpass(highpass(x, f1), f2)


# ---------------------------------------------------------------------------
# 混音工具
# ---------------------------------------------------------------------------

def silence(dur: float) -> np.ndarray:
    return np.zeros(int(dur * SR))


def mix(*tracks: np.ndarray) -> np.ndarray:
    n = max(len(t) for t in tracks)
    out = np.zeros(n)
    for t in tracks:
        out[: len(t)] += t
    return out


def add_at(dst: np.ndarray, src: np.ndarray, t0: float) -> None:
    i = int(t0 * SR)
    j = min(len(dst), i + len(src))
    if i < len(dst):
        dst[i:j] += src[: j - i]


def tone(freq: float, dur: float, attack: float, tau: float,
         harmonics=((1, 1.0), (2, 0.35), (3, 0.12)),
         detune: float = 0.0, detune_gain: float = 0.3) -> np.ndarray:
    """带泛音（可含合唱失谐）的乐音。"""
    t = tvec(dur)
    ph = 2.0 * np.pi * freq * t
    x = np.zeros_like(t)
    for mult, g in harmonics:
        x += g * np.sin(mult * ph)
    if detune > 0.0:
        x += detune_gain * np.sin(2.0 * np.pi * freq * (1.0 + detune) * t)
    return x * env_exp(dur, attack, tau)


def make_loop(x: np.ndarray, loop_dur: float, fade: float = 0.6) -> np.ndarray:
    """从较长信号 x 中截取无缝循环段（首尾交叉淡化）。"""
    n = int(loop_dur * SR)
    f = min(int(fade * SR), len(x) - n)
    y = x[:n].copy()
    idx = np.arange(f)
    w = idx / f
    y[:f] = x[:f] * w + x[n:n + f] * (1.0 - w)
    return y


# ---------------------------------------------------------------------------
# WAV 输出
# ---------------------------------------------------------------------------

def to_wav_bytes(x: np.ndarray, peak: float) -> bytes:
    m = np.max(np.abs(x))
    if m < 1e-9:
        m = 1.0
    y = x * (peak / m)
    pcm = np.clip(y * 32767.0, -32768, 32767).astype("<i2")
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def S(name, data, label, usage, peak=0.7):
    return {"name": name, "data": data, "label": label, "usage": usage, "peak": peak}


# ---------------------------------------------------------------------------
# 各音效构建函数
# ---------------------------------------------------------------------------

def build_ui_click():
    tick = osc(sweep_f(1750, 1450, 0.06)) * env_exp(0.06, 0.001, 0.012) * 0.9
    click = highpass(noise(0.03), 3200) * env_exp(0.03, 0.0005, 0.007) * 0.5
    return S("ui_click", mix(tick, click), "UI 点击", "按钮、选项确认", peak=0.45)


def build_ui_hover():
    x = osc(2500.0) * env_exp(0.04, 0.001, 0.009)
    return S("ui_hover", x, "UI 悬停", "鼠标掠过按钮（音量已压低）", peak=0.22)


def build_tile_pickup():
    swish = bandpass(noise(0.14), 500, 2200) * env_exp(0.14, 0.012, 0.06) * 0.8
    blip = osc(sweep_f(320, 640, 0.12)) * env_exp(0.12, 0.02, 0.05) * 0.25
    return S("tile_pickup", mix(swish, blip), "拿起地块", "从手牌拿起地块", peak=0.4)


def build_tile_place():
    thud = osc(sweep_f(170, 62, 0.16, 0.7)) * env_exp(0.16, 0.002, 0.055)
    knock = osc(sweep_f(420, 240, 0.05)) * env_exp(0.05, 0.001, 0.02) * 0.3
    snap = highpass(noise(0.045), 2400) * env_exp(0.045, 0.0005, 0.012) * 0.4
    return S("tile_place", mix(thud, knock, snap), "放置地块", "地块落到棋盘（核心反馈音）", peak=0.85)


def build_tile_rotate():
    base = silence(0.21)
    for i, (t0, g) in enumerate([(0.0, 0.5), (0.065, 0.65), (0.13, 0.8)]):
        tick = bandpass(noise(0.022), 1600, 6000) * env_exp(0.022, 0.0005, 0.006)
        blip = osc(sweep_f(1050 + i * 80, 900 + i * 80, 0.03)) * env_exp(0.03, 0.001, 0.008) * 0.5
        add_at(base, mix(tick, blip) * g, t0)
    return S("tile_rotate", base, "旋转地块", "每按一次旋转播放（棘轮三连响）", peak=0.6)


def build_tile_invalid():
    base = silence(0.32)
    for t0, f in [(0.0, 150.0), (0.17, 135.0)]:
        t = tvec(0.11)
        ph = 2.0 * np.pi * f * t
        buzz = (np.sin(ph) + 0.4 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph))
        buzz *= env_exp(0.11, 0.004, 0.045)
        add_at(base, lowpass(buzz, 700), t0)
    return S("tile_invalid", base, "无效放置", "规则不允许的边口 / 位置", peak=0.5)


def build_plant_seed():
    dig = lowpass(noise(0.22), 380) * env_exp(0.22, 0.004, 0.07)
    crunch = bandpass(noise(0.06), 250, 1100) * env_exp(0.06, 0.002, 0.02) * 0.6
    base = mix(dig)
    add_at(base, crunch, 0.09)
    return S("plant_seed", base, "播种", "把植物种进可种植 LAND", peak=0.7)


def build_plant_grow():
    rise_dur = 0.3
    t = tvec(rise_dur)
    grow_env = np.minimum(t / 0.06, 1.0) * np.exp(-np.maximum(t - 0.06, 0.0) / 0.22)
    rise = osc(sweep_f(240, 660, rise_dur, 1.4)) * grow_env
    base = mix(rise)
    pop1 = osc(sweep_f(950, 800, 0.03)) * env_exp(0.03, 0.001, 0.01) * 0.4
    pop2 = osc(sweep_f(1250, 1050, 0.03)) * env_exp(0.03, 0.001, 0.01) * 0.3
    add_at(base, pop1, 0.20)
    add_at(base, pop2, 0.26)
    return S("plant_grow", base, "植物生长", "植物进入下一生长阶段", peak=0.7)


def build_plant_wilt():
    dur = 0.62
    t = tvec(dur)
    freq = 330 + (120 - 330) * (t / dur) ** 0.8
    freq = freq + 15.0 * np.sin(2.0 * np.pi * 5.5 * t) * (t / dur)  # 颤音渐强
    env = env_exp(dur, 0.04, 0.28)
    tone_a = osc(freq) * env * 0.8
    tone_b = osc(freq * 0.985) * env * 0.35
    breath = bandpass(noise(dur), 300, 1400) * env_exp(dur, 0.06, 0.3) * 0.18
    return S("plant_wilt", mix(tone_a, tone_b, breath), "植物枯萎", "缺水枯萎状态切换", peak=0.55)


def build_harvest():
    base = silence(0.32)
    pop = osc(sweep_f(680, 210, 0.08, 0.8)) * env_exp(0.08, 0.001, 0.045) * 0.9
    add_at(base, pop, 0.0)
    for t0, f, g in [(0.05, 1568.0, 0.22), (0.11, 2093.0, 0.18)]:
        add_at(base, osc(f) * env_exp(0.1, 0.001, 0.035) * g, t0)
    return S("harvest", base, "收获", "收获成熟植物 / 得到植物", peak=0.8)


def build_score_point():
    base = silence(0.55)
    add_at(base, tone(659.25, 0.3, 0.004, 0.10), 0.0)
    add_at(base, tone(880.0, 0.42, 0.004, 0.13) * 1.1, 0.085)
    return S("score_point", base, "得分", "结算得分 / 计分跳字", peak=0.6)


def build_water_drop():
    dur = 0.16
    rise_n = int(0.06 * SR)
    t1 = np.arange(rise_n) / rise_n
    f_rise = 480 + (1050 - 480) * t1 ** 1.8
    t2 = np.arange(dur * SR - rise_n) / SR
    f_fall = 1050 + (880 - 1050) * (t2 / (dur - 0.06))
    freq = np.concatenate([f_rise, f_fall])
    body = osc(freq) * env_exp(dur, 0.002, 0.05)
    tick = highpass(noise(0.02), 4000) * env_exp(0.02, 0.0003, 0.005) * 0.2
    return S("water_drop", mix(body, tick), "水滴", "单滴水 / 轻量水反馈", peak=0.6)


def build_water_splash():
    dur = 0.5
    body = lowpass(noise(dur), 1300) * env_exp(dur, 0.004, 0.10) * 0.9
    sizzle = bandpass(noise(dur), 2200, 9000) * env_exp(dur, 0.001, 0.045) * 0.3
    base = mix(body, sizzle)
    for t0, f0, f1, g in [(0.16, 1500, 1900, 0.30), (0.27, 1200, 1600, 0.25)]:
        d = 0.09
        add_at(base, osc(sweep_f(f0, f1, d)) * env_exp(d, 0.002, 0.035) * g, t0)
    return S("water_splash", base, "水花", "挖开水渠 / 水网连通瞬间", peak=0.85)


def build_water_flow_loop():
    loop_dur, fade = 4.0, 0.6
    total = loop_dur + fade
    base = highpass(lowpass(noise(total), 550), 70) * 0.9
    gurgle = bandpass(noise(total), 700, 2400) * (0.25 + 0.2 * (0.5 + 0.5 * slow_noise(total, 2.1)))
    x = base + gurgle
    x *= 0.75 + 0.25 * (0.5 + 0.5 * slow_noise(total, 1.3))
    y = make_loop(x, loop_dur, fade)
    return S("water_flow_loop", y, "水流循环", "环境音：棋盘上存在供水网络时循环播放", peak=0.5)


def build_turn_start():
    base = silence(0.75)
    add_at(base, tone(392.0, 0.35, 0.005, 0.12) * 0.6, 0.0)
    add_at(base, tone(523.25, 0.5, 0.005, 0.16) * 0.75, 0.13)
    return S("turn_start", base, "回合开始", "轮到某玩家行动", peak=0.5)


def build_victory():
    base = silence(1.7)
    notes = [
        (523.25, 0.00, 0.22, 0.08, 0.55),
        (659.25, 0.13, 0.22, 0.08, 0.55),
        (783.99, 0.26, 0.22, 0.08, 0.60),
        (1046.50, 0.42, 0.85, 0.35, 0.80),
    ]
    for f, t0, d, tau, g in notes:
        add_at(base, tone(f, d, 0.005, tau, detune=0.004) * g, t0)
    # 轻微回声
    echo = base * 0.22
    add_at(base, echo, 0.22)
    return S("victory", base, "胜利", "对局胜利结算", peak=0.75)


def build_defeat():
    base = silence(1.5)
    notes = [
        (220.00, 0.00, 0.55, 0.30, 0.55),
        (174.61, 0.40, 0.55, 0.30, 0.55),
        (146.83, 0.80, 0.65, 0.40, 0.65),
    ]
    for f, t0, d, tau, g in notes:
        add_at(base, tone(f, d, 0.04, tau, harmonics=((1, 1.0), (2, 0.25))) * g, t0)
    return S("defeat", lowpass(base, 900), "失败", "对局失败结算", peak=0.6)


ALL_BUILDERS = [
    build_ui_click, build_ui_hover, build_tile_pickup, build_tile_place,
    build_tile_rotate, build_tile_invalid,
    build_plant_seed, build_plant_grow, build_plant_wilt, build_harvest,
    build_water_drop, build_water_splash, build_water_flow_loop,
    build_score_point, build_turn_start, build_victory, build_defeat,
]


# ---------------------------------------------------------------------------
# 试听页面
# ---------------------------------------------------------------------------

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>青菱沃野 · 音效试听</title>
<style>
  :root {{ color-scheme: light; }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font-family: "Microsoft YaHei", system-ui, sans-serif;
         background: #f4f8f5; color: #1e3329; }}
  .wrap {{ max-width: 880px; margin: 0 auto; padding: 28px 20px 60px; }}
  h1 {{ font-size: 22px; margin: 0 0 6px; }}
  h1 span {{ color: #2e7d5b; }}
  .sub {{ color: #5a7267; font-size: 13px; line-height: 1.7; margin-bottom: 22px; }}
  code {{ background: #e4efe8; border-radius: 4px; padding: 1px 6px;
         font-size: 12.5px; color: #1c5c40; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(255px, 1fr)); gap: 14px; }}
  .card {{ background: #fff; border: 1px solid #dde8e1; border-radius: 10px; padding: 14px 16px; }}
  .card h3 {{ margin: 0 0 2px; font-size: 15px; }}
  .card .usage {{ color: #62756c; font-size: 12px; margin-bottom: 8px; line-height: 1.5; }}
  .card audio {{ width: 100%; height: 34px; }}
  .name {{ display: inline-block; margin-top: 8px; }}
  footer {{ margin-top: 26px; color: #7a8c83; font-size: 12px; line-height: 1.8; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>青菱沃野 <span>· 程序化音效试听</span></h1>
  <div class="sub">
    共 {count} 个音效，位于 <code>audio/sfx/</code>（44.1kHz / 16-bit 单声道 WAV，Godot 可直接导入）。<br>
    已注册 Autoload <code>Sfx</code>，在任意脚本中调用：<code>Sfx.play("tile_place")</code>；
    循环环境音：<code>Sfx.play_loop("water_flow_loop")</code> / <code>Sfx.stop_loop("water_flow_loop")</code>。
  </div>
  <div class="grid">{cards}</div>
  <footer>
    全部声音由 <code>tools/generate_sfx.py</code> 以振荡器 + 滤波噪声 + 包络合成，固定随机种子、可复现。<br>
    重新生成：在项目根目录运行 <code>python tools/generate_sfx.py</code>（修改对应 build_* 函数可调整单个音效）。
  </footer>
</div>
</body>
</html>
"""

CARD_TEMPLATE = """
<div class="card">
  <h3>{label}</h3>
  <div class="usage">{usage}</div>
  <audio controls preload="none" src="data:audio/wav;base64,{b64}"></audio>
  <div class="name"><code>{name}</code></div>
</div>
"""


def build_html(sounds, out_path):
    cards = []
    for s in sounds:
        b64 = base64.b64encode(to_wav_bytes(s["data"], s["peak"])).decode("ascii")
        cards.append(CARD_TEMPLATE.format(label=s["label"], usage=s["usage"],
                                          name=s["name"], b64=b64))
    html = HTML_TEMPLATE.format(count=len(sounds), cards="".join(cards))
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.normpath(os.path.join(here, "..", "audio", "sfx"))
    parser = argparse.ArgumentParser(description="生成青菱沃野游戏音效")
    parser.add_argument("--out", default=default_out, help="WAV 输出目录")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    sounds = [b() for b in ALL_BUILDERS]
    for s in sounds:
        data = to_wav_bytes(s["data"], s["peak"])
        path = os.path.join(args.out, s["name"] + ".wav")
        with open(path, "wb") as f:
            f.write(data)
        print("  %-20s %6.2fs %7.1f KB" % (s["name"], len(s["data"]) / SR, len(data) / 1024))

    preview = os.path.normpath(os.path.join(args.out, "..", "sfx_preview.html"))
    build_html(sounds, preview)
    print("\n共生成 %d 个音效 -> %s" % (len(sounds), args.out))
    print("试听页面 -> %s" % preview)


if __name__ == "__main__":
    main()
