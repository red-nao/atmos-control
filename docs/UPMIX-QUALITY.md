# アップミックス品質の改善計画 — Auro-Matic / Apple Spatialize Stereo / Sonos TV Audio Swap に並ぶまで

このドキュメントは「このプロジェクトのアップミックス (F4, `STFTUpmixer`) を、Auro-Matic・Apple の
Spatialize Stereo・Sonos の TV Audio Swap と同レベルに持っていくには何をすればいいか」への回答です。
推測ではなく、**リポジトリに同梱した測定ツール (`tools/upmix-lab/`) の実測値**を根拠にしています。

> 言語について: このドキュメントだけ日本語です (依頼者が日本語のため)。他の `docs/` と `README.md` は
> 従来どおり英語です。

---

## 0. 結論（先に要点）

既存カーネルの問題は「アルゴリズムのアイデアが間違っている」のではなく、
**レベルとマスクの扱いが数式的に詰め切れていない**ことでした。具体的には 4 つのバグ級の欠陥があり、
いずれも数十行の修正で消えます。さらに Auro-Matic がやっている
「反射レイヤー」 (下の層の遅延コピー＋高域を軽く落とす) を足すことで、高度方向の natural nature が出ます。

| # | 症状 | 現行 (Classic) | 新カーネル (Natural) | 修正の内容 |
|---|------|---------------|---------------------|-----------|
| 1 | 中央付近が沈む | パン掃引で **2.88 dB の落ち込み** | **0.00 dB (平坦)** | 中心則をエネルギー保存形に (`γ = √(2(2c−c²))`) |
| 2 | ハードパン音が後ろへ飛ぶ | 定位 **100 % がサラウンド** (前 −120 dB) | サラウンド −10.3 dB / 前 −0.4 dB | アンビエンス判定に「L/R のレベルが同程度」条件を追加 |
| 3 | 低域が後ろ・上へ漏れる | <120 Hz が sur/height に **+0.9 dB** | **−17.5 dB** | 送出側に 150 Hz ハイパス (bass management) |
| 4 | アップミックス ON で音量が上がる | COLA 1.5 で除算 → **+2.5 dB** ホット | 後段 AGC で on/off 一致 (auto level) | 除算を 2.0 に修正 + ゆっくりしたレベル補正 |
| 5 | アタックが後ろに回る | アタック/テール比 −1.4 dB | −4.7 dB (7.1.4) / −10.2 dB (5.1) | 非対称平滑 + オンセットゲート |
| 6 | ハイトが「明るい膜」のような不自然さ | >2 kHz の位相拡散コピーのみ | 下の層の遅延・帯域整形コピー (反射) | Auro-Matic 型の反射レイヤー |
| 7 | 音楽が痩せる / 定位がぼやける | 前 L+R の音色偏差 8.88 dB | **1.45 dB** | 直接音を透過させるマスク (冪等・エネルギー保存) |

測定条件は 48 kHz / FFT 2048 / auto-level off、レイアウト 7.1.4 と 5.1 の両方。
生の表は `tools/upmix-lab/out/measurements-714.txt` と `measurements-51.txt`。

**やることは 3 段階です:**

- **P0 (完了・同梱済み)** — 上記 1〜7 + `strength` / `spread` / `transients` / `reflections` /
  `bass management` / `auto level` の各パラメータ。`UpmixConfig.quality = .natural` が既定になり、
  UI から Classic / Natural を即時 A/B できます。
- **P1 (次の 1〜2 週間)** — 帯域集約とマルチレゾリューション (クリック/ノイズ対策)、センターの
  spread、レンダラ側の調整 (reverb blend / AmbienceBed の比較)、実測でのバランス合わせ (§4)。
- **P2 (研究枠)** — ステム分離ベースのアップミックス (ニューラル)、個人 HRTF 連動、など (§5)。

---

## 1. 現状の診断 (実測)

`tools/upmix-lab/upmix_lab.py` は Swift カーネルの忠実な NumPy 移植 (`KernelV1`) と、提案カーネル
(`KernelV2`)、測定スイート、簡易バイノーラル・モニタ、聴き比べ用 WAV 出力を持ちます。
再現は:

```bash
python3 tools/upmix-lab/upmix_lab.py --compare --level --curve --layout 714
python3 tools/upmix-lab/upmix_lab.py --compare --layout 51
python3 tools/upmix-lab/upmix_lab.py --wav --layout 714     # out/ に聴き比べ用 WAV
```

### 1.1 中央付近のレベル低下 (2.88 dB) — 最大の「安っぽさ」の原因

パン定位を 17 点に振った定常音の出力レベル (入力比, dB):

```
pan position ->   -1.00 -0.88 -0.75 -0.62 -0.50 -0.38 -0.25 -0.12 +0.00 +0.12 +0.25 +0.38 +0.50 +0.62 +0.75 +0.88 +1.00
v1 (current)      -0.02 -0.10 -0.45 -1.05 -1.87 -2.67 -2.88 -1.92 -0.00 -1.92 -2.88 -2.67 -1.87 -1.05 -0.45 -0.10 -0.01
v2 (proposed)     -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00 -0.00
```

中央のすぐ脇 (−0.25〜−0.38) で **2.7〜2.9 dB** 沈みます。しかも `c` (センター引き抜き量) は
**ビンごと・フレームごとに動く**ので、この落ち込みは静的な EQ ではなく
**ダイナミックなレベル変調 = ポンピング**として聞こえます。ボーカルやギターが少し左右に動くだけで
音量が揺れる、これが「解像度が低い・安っぽい」印象の主因です。

原因は中心則の係数です。現行は L/R 側を `1−c`、センターを `√2·c` にスケールしていますが、これは
`c = 0` と `c = 1` でしかエネルギーが一致しません。`α = 1−c` とすると正しい係数は

```
γ = √(2·(1 − α²)) = √(2·(2c − c²))
```

で、これで全 `c` でエネルギーが厳密に保存されます (v2 の 0.00 dB)。

### 1.2 ハードパンした直接音が「アンビエンス」と誤判定される

片側に完全に振った定位のコヒーレントな音 (定位が −1.0 の 1 kHz トーン):

```
              surround      front          L
v1 (current)    +0.0 dB   -120.0 dB   -120.0 dB     ← 100 % 後ろへ
v2 (proposed)  -10.3 dB     -0.4 dB     -0.4 dB     ← 前の定位を保つ
```

低域 (60 Hz 中心、デコリレート済み) とトランジェント:

```
<120 Hz energy in the surrounds/height, vs input:   v1 +0.9 dB   → v2 −17.5 dB
surround attack/tail (click train):                 v1 −1.4 dB   → v2 −4.7 dB
```

原因は推定器の設計です。現行は「コヒーレンス γ² が低い = アンビエンス」という 1 条件だけで判定しますが、
**片側に振った音は定義上コヒーレンスが低い**ため、直接音がアンビエンス扱いになります。
Avendano & Jot (2002) は明確に 2 条件目「**L/R のレベルが同程度であること**」を要求しています。

追加した指標 (レベル類似度):

```
lsim = 2·√(P_LL·P_RR) / (P_LL + P_RR)   ∈ [0,1]
D(拡散度) = (1 − γ²)·lsim³
```

これで `D` はハードパンで 0、無相関ノイズで 1 になります。

### 1.3 低域がサラウンド/ハイトに漏れる

Auro-3D も Dolby も、アップミックスしたチャンネルには必ずクロスオーバー (80〜120 Hz) をかけます。
低域は方向感がなく、後ろ・上に回すと**音楽の重心が後ろに落ちて「こもる」**だけだからです。
現行実装は LFE とハイト送りの帯域制限はしてあるものの、サラウンド送りはフルレンジです。

### 1.4 出力が 2.5 dB ホット (COLA の数値間違い)

√Hann を分析・合成の 2 回かけるので、hop = N/4 での重ね合わせは **ちょうど 2.0** になります。
現行コードは 1.5 で割っており、素通しに対して **+2.4988 dB** のゲイン誤差がありました
(「ON にすると音が前に出る/大きくなる」の正体)。修正後は `strength = 0` で
**最大絶対誤差 2.2e-16** の完全なパススルーになります。

### 1.5 トランジェントと音色

```
synthetic song: front L+R deviation 8.88 dB → 1.45 dB   (7.1.4)
                eardrum deviation    4.87 dB → 2.33 dB
                IACC 0.853 (stereo ref 0.923) → 0.885
```

「前 L+R の音色偏差 8.88 dB」= 直接音がマスク処理で壊れている、という意味です。Auro-Matic が
徹底して「元の定位と音色を壊さない」方向に振っているのと真逆でした。

### 1.6 ハイト層の作り方

現行: 2 kHz 以上だけの、遅延なし・位相回転だけのコピー。これは耳にとって「耳元で拡散した明るい膜」
であり、上方の**反射**として知覚されません。Auro-Matic の説明は明快で、
「下の層の情報を、わずかな遅延と、高域を軽く落として上にコピーする (隣接チャンネルを多め、
対角は最小)」= **初期反射の合成**です。ここを置き換えるのが P0 の 6 番目です。

### 1.7 アップミックス ON/OFF で音量・前方の量感が変わる

合成楽曲で「アップミックス後のベッド合計 / 鼓膜 (簡易バイノーラル) の RMS / 前 2ch のエネルギー」
を、素のステレオとの比で測ったもの:

```
                        bed       binaural   front pair
v1 (current)          -0.11 dB   -0.42 dB   -6.93 dB
v2 (auto level off)   +0.35 dB   -0.11 dB   -3.61 dB
v2 (auto level on)    +0.15 dB   -0.33 dB   -3.80 dB
```

- v1 は**前 2ch が 6.93 dB も痩せる** (拡散成分が後方へ移り、直接音もマスクで削られる)。
  これが「アップミックスすると中身が薄くなる」の正体で、v2 では −3.6 dB まで緩和。
- 総量は v1/v2 とも ±0.5 dB 以内。v2 の `auto level` はベッド合計を入力に合わせて +0.35 → +0.15 dB。
- 前 2ch の残存量は `Ambience spread` で調整できます (既定 0.6。小さくすると前方の量感が増えます)。

---

## 2. 参照実装は実際に何をしているか

### 2.1 Auro-Matic (Auro-3D)

- **入力チャンネルを加工しない**。ステアリング/行列抽出をせず、元の 5.1/7.1 はそのまま。
- ハイト/上層は「下の層のコピー」を**わずかな遅延つき・高域を軽く落として**配置 (隣接多め・対角最小)。
- リバーブ (反射パターン) を付加して初期反射を模す。
- **Strength 0–15** (既定 10–12) = アップミックスする上層/サラウンドの量。**0 で完全に無効**。
- プリセット Small / Medium / Large / Speech、Space = リバーブの長さ。
- 思想: 「録音を**拡張**する。楽器の位置を動かさない」。

→ **借りるもの**: 反射レイヤー、Strength マスター、低域の管理、「直接音を触らない」原則。

### 2.2 Apple Spatialize Stereo

- 端末内でリアルタイムの HRTF アップミックス。モード Off / Fixed / Head-Tracked。
- できるのは「広げる・空間化する」であり、真のオブジェクト定位は作れない。
- すべてのアプリで動作する代わりに、素材によって**音色とボーカルの明瞭度が変わる**という代償がある。

→ **借りるもの**: 遅延 (1 ウィンドウ) とレイテンシの割り切り、ヘッドトラッキングとの併用時の注意。
→ **逆に**: このプロジェクトの `Classic` は概ねこの方向の実装 (1024/2048, MPEG_5_1_A 相当) なので、
「Apple と同程度」は P0 で達成済み、「Auro-Matic 以上」を狙うなら反射レイヤーが必須。

### 2.3 Sonos TV Audio Swap (Soundbar + Ace)

- サウンドバー側が空間ミックスを計算し、**Ace へ直接 Wi-Fi で転送**する。
- ステレオ素材ではサウンドバーが**仮想化した空間ミックス (＝アップミックス)** を作る。
- Spatial Audio / Dynamic Head Tracking はユーザートグル。
- レビューの評価は「包まれ感・空間は良いが、ピンポイントの方向感は限定的」。

→ **借りるもの**: 「包まれ感を作るのは (音色を壊さない) 拡散成分であり、定位の鋭さとは別軸」という
評価軸。包まれ感は **IACC (両耳間相関)** で測れます (§3.2)。

---

## 3. 改善案 (P0: 実装済み)

実装は `Sources/SpatialEngine/STFTUpmixer.swift` に 2 カーネル共存の形で入れてあります。
`UpmixConfig.quality` で**即時に**切り替えられるので、聴き比べは 1 クリックです。

### 3.1 カーネルの式 (Natural)

ビンごとに:

```
γ²  = 平滑化したコヒーレンス (τ = 120 ms, バイアス補正済み)
lsim = 2√(P_LL·P_RR)/(P_LL+P_RR)        # レベル類似度
D    = (1 − γ²)·lsim³                    # 拡散度マスク (0=直接音, 1=アンビエンス)
D   ← 非対称平滑 (直接寄りは速く τ≈5–30 ms [transients], 拡散寄りは遅く τ≈150 ms)
D   ← D · gate · strength                # gate: オンセット検出で 6 フレーム 0.15 倍
gd     = √(1 − D)                        # 直接音マスク
gSend  = √(D·spread)·ambient             # サラウンド/ハイトへ
gFront = √(D·(1−spread))                # 前 2ch に残す (位相を軽く拡散)
α = 1 − c,  c = (1−|β|)²·center·strength
γ = √(2(1 − α²))                         # エネルギー厳密な中心則
L' = gd(α·m + s) + gFront·Φ_L·L
R' = gd(α·m − s) + gFront·Φ_R·R
C' = gd·γ·m
Ls' = gSend·HP150(L),  Rs' = gSend·HP150(R)     # 低域は前へ残す
Vhl' = gSend·HP150·LP7k(L) + 反射レイヤー
```

- `spread` は「抽出したアンビエンスのうち、前 2ch を離れてサラウンド/ハイトに行く割合」。
  0 で前だけ (控えめ)、1 で全部後方 (没入)。**電力保存のクロスフェード**なので、掃引しても
  総エネルギーは変化しません。
- `strength` は Auro-Matic の Strength と同じ役割 (0 で完全バイパス)。
- 反射レイヤー (7.1.4 のみ): `{Vhl,Vhr,Ltr,Rtr,Rls,Rrs}` × `{L,R,C,Ls,Rs}` の行列、
  遅延 11/17/13/23/9/9 ms、重みは物理的な隣接度 (真下 1.0、隣 0.3–0.65、対角 0.05–0.12)、
  150 Hz HP → 5 kHz の緩い HF トリム。**時間領域で出力サンプルに足す** (STFT 内で位相ランプを
  かけると窓が 1 周して 11 ms の反射がプリエコーになるため)。
- `auto level`: ベッド合計電力が入力と一致するよう 2 秒時定数でゲインを微調整 (on/off の音量差対策)。

### 3.2 数値の意味と目標値

| 指標 | 意味 | 目標 |
|------|------|------|
| pan spread | 定位を振ったときのレベル偏差 | **≤ 0.5 dB** |
| hard-pan leak | ハードパン音のサラウンド漏れ | **≤ −10 dB** |
| bass <120 Hz in sends | 低域の後方/上方漏れ | **≤ −15 dB** |
| transient attack/tail | アタックの後方漏れ (低いほど良い) | **≤ −3 dB** |
| IACC (バイノーラル) | 両耳間相関 (低いほど包まれる) | 0.80–0.90 (ステレオ参照 0.92) |
| front L+R deviation | 直接音の音色破壊 | **≤ 1.5 dB** |
| eardrum deviation | 鼓膜での音色偏差 | **≤ 2.5 dB** |
| null (strength = 0) | パススルー精度 | **≤ 1e-6** |

### 3.3 新しいパラメータ (UI)

| パラメータ | 範囲 | 既定 | 意味 |
|-----------|------|------|------|
| **Kernel** | Classic / Natural | **Natural** | カーネル選択 (即時 A/B) |
| **Strength** | 0…1 | 1.0 | 効果の総量 (0 = 完全バイパス) |
| **Ambience spread** | 0…1 | 0.6 | アンビエンスのうち後方/上方へ回す割合 |
| **Transient preservation** | 0…1 | 1.0 | アタックを前へ残す強さ |
| **Reflections** | −24…+6 dB | 0 | 反射レイヤーの量 (−24 でほぼ無効) |
| **Bass management** | on/off | on | 送出側 150 Hz ハイパス |
| **Auto level** | on/off | on | on/off の音量合わせ (2 s) |

既存の `Center strength` / `Surround level` / `Height level` / `Decorrelation` / `Ambient bias` /
`Surround spread` / `LFE` / `FFT size` はそのままです。

---

## 4. P1 — 次にやるべきこと (まだ未実装)

1. **帯域集約 (critical band) でのマスク決定**
   現在は 1 ビンごとに `D` を決めるため、狭帯域のノイズやクリックでマスクが暴れます。
   1/3 オクターブ程度にまとめてから決め、**ビンごとの値は再配分**すると、ハイハットや
   サ行の「シュワシュワした位相感」が減ります。
2. **マルチレゾリューション (2 つ目の短い窓)**
   1024 と 2048 を同時に走らせ、オンセット検出とトランジェントのマスクだけ短い窓から取る方式。
   レイテンシは増やさずに、アタックの精度だけ上げられます。
3. **センターの spread**
   センター成分を L/R にも少し戻す (Dolby の "Center Spread" 相当)。ヘッドホンでは
   C 定位が「頭の中」に張り付くのを緩和します。`centerStrength` の逆方向パラメータ。
4. **レンダラ側の比較検証**
   `SourceMode = AmbienceBed` (ベッドを内部デコーダに任せる) と現行のポイントソース方式を
   バイノーラルで比較。特に背面 (Rls/Rrs) の定位はレンダラ依存です。
   また現在 ReverbBlend が全バスに 1 % かかっており、反射レイヤーと二重になります。
   Natural では送り先バスの ReverbBlend を 0 にする選択肢を検討。
5. **実測でのバランス合わせ**
   アップミックス後の各チャンネルを 1 本ずつ鳴らし、`--wav-multichannel` の出力を
   バイノーラル・モニタで聴いて、7.1.4 の 12 本の相対レベルを実測カーブに合わせる
   (今は物理的な隣接重みのみ)。
6. **サンプルレート/レイテンシの整理**
   192 kHz でも反射ディレイが正しくスケールするか、`maxFrames` の上限で
   リングが破綻しないかの確認。

---

## 5. P2 — 研究枠 (やるとしたら)

- **ステム分離ベース** (音楽ソース分離 → ステムごとに LCR へ配置): 近年の研究 (DAFx 2026 など) は
  これでアップミックスの品質を大きく上げています。CPU は重いが、ボーカル/楽器の定位が
  「ビンごとの確率」ではなく「トラック」になるため、ハードパンや同時発音の問題が原理的に消えます。
- **ニューラル・アンビエンス抽出** (PAEDB 系)。
- **個人 HRTF 連動**: このプロジェクトは既に personalization を持っているので、
  アップミックスのセンター/ハイトの重みを HRTF プロファイルに合わせて微調整。
- **バーチャル・ハイトの知覚校正**: 45° のハイトをバイノーラルでどう知覚するかの実測
  (個人差が大きい領域)。

---

## 6. 検証と聴き比べの手順

```bash
# 1) 測定 (Python 3 + numpy のみ)
python3 tools/upmix-lab/upmix_lab.py --compare --level --layout 714
python3 tools/upmix-lab/upmix_lab.py --compare          --layout 51

# 2) 聴き比べ用 WAV (48 kHz / IEEE float / 7.1.4)
python3 tools/upmix-lab/upmix_lab.py --wav --layout 714
#   out/song_input_stereo.wav            元のステレオ
#   out/song_stereo_binaural_ref.wav     ±30° に置いただけのステレオ (基準)
#   out/song_v1_714_binaural.wav         現行カーネル
#   out/song_v2_714_binaural.wav         提案カーネル
python3 tools/upmix-lab/upmix_lab.py --wav --layout 714 --wav-multichannel   # 生の 7.1.4 ベッド

# 3) 自分の曲で
python3 tools/upmix-lab/upmix_lab.py --wav --input ~/Music/test.wav --layout 714
```

バイノーラル・モニタは自作の簡易 HRTF (Woodworth の ITD + 角度依存の頭部遮蔽 + 仰角依存の
ピナノッチ) なので、**方向の妥当性を見るためのもの**であり、Apple の HRTF そのものではありません。
最終判断は実機 (macOS 26 / Apple Silicon) で:

```bash
swift build -c release
bash App/build-app.sh release
ATMOS_PREVIEW=1 open -n dist/atmos-control.app
# Full Control ▸ Upmix ▸ Advanced ▸ Kernel を Classic ↔ Natural (即時切り替え)
# Strength 0 / 1 で on/off の音量差を確認 (auto level on)
```

---

## 7. 実装ファイルと注意点

| ファイル | 変更 |
|---------|------|
| `Sources/SpatialEngine/STFTUpmixer.swift` | Classic / Natural の 2 カーネル、反射レイヤー、auto level、`scale` 修正 |
| `Sources/SpatialEngine/UpmixConfig.swift` | `quality` + 7 パラメータ追加、緩いデコード (既存の保存値と互換) |
| `Sources/SpatialEngine/Decorrelator.swift` | `tauMax` / `segment` の上書き引数 (前方アンビエンス用の緩い位相カーブ) |
| `Sources/AtmosControlApp/EngineController.swift` | `setUpmix(...)` 拡張 (全て即時反映) |
| `Sources/AtmosControlApp/UpmixView.swift` | Kernel ピッカー + 新スライダー |
| `Sources/AtmosControlApp/Ranges.swift` | 新パラメータの範囲・表示 |
| `tools/upmix-lab/upmix_lab.py` | 測定・試作・WAV 出力 (依存: numpy のみ) |
| `README.md` | Upmix 節の更新 |

**開発時の注意 (RT スレッド)**

- `process()` は**アロケーション禁止**。このため Natural カーネルの選択は
  `enum` 比較ではなく **Bool** (`pNatural`) で行っています (`String` 列挙の比較は
  ヒープ参照が発生し得ます)。
- 追加バッファは全て `init` で確保し `deinit` で解放。
- パラメータは 32-bit スカラを直接読み、フレームごとに平滑化 (テアリングは聴感上無害)。

**未検証**

- このドキュメントの数値はすべて Python ラボの値で、**Swift 側はこの環境に Swift ツールチェーンが
  ないため未コンパイル**です。macOS で `swift build -c release` →
  実機試聴 → `--compare` の再測定、という順で確認してください。
- 反射レイヤーの遅延 (11〜23 ms) は STFT レイテンシ (1 ウィンドウ = 42.7 ms @2048) とは独立に
  遅延バッファで実装しているので、動画のリップシンク許容量 (≈125 ms) の範囲内です。

---

## 付録 A. 実測表 (生データ)

7.1.4 と 5.1 の全表は `tools/upmix-lab/out/measurements-714.txt` /
`measurements-51.txt` にあります (このドキュメントの数値はそこから引用)。

## 付録 B. 参考文献

- Avendano, C., Jot, J.-M. (2002) *A frequency-domain approach to multichannel upmix* —
  コヒーレンス + レベル類似度による 1 次アンビエンス抽出。本実装の理論的基礎。
- Vickers, E. (2010) *Frequency-domain two-to-three channel upmix* — センター抽出の実務的な扱い。
- Auro Technologies, *Auro-Matic* 製品資料 / Onkyo 実装マニュアル —
  反射レイヤー、Strength、プリセット、ベース層を触らない方針。
- Apple, *Spatialize Stereo* (iOS/macOS) — HRTF による仮想化とモード。
- Sonos, *TV Audio Swap* サポート資料 / レビュー — サウンドバー側で計算した空間ミックスを
  Ace に直接送る構成。
