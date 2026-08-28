# OSインストールツール（AlmaLinux版 / Clonezillaベース）

エフアンドエフ株式会社向け。AlmaLinux 9.8 のマスターをキャプチャし、
同一機種（IPC1600-IMB-A8000M）へ復元するカスタム Clonezilla Live USB。

Clonezilla Live（GPL）をベースに、日本語メニュー・容量拡張・一般化処理を組み込んでいる。

---

## 1. 確定仕様

| 項目 | 内容 |
|---|---|
| 対象機種 | IPC1600-IMB-A8000M（単一機種） |
| OS | AlmaLinux 9.8 |
| ディスク | SATA SSD / GPT / UEFI（Secure Boot 無効） |
| パーティション | sda1 ESP(vfat 600M) / sda2 /boot(xfs 1G) / sda3 LVM PV |
| LVM | VG=`almalinux`、LV=`root`(xfs) / `home`(xfs) / `swap` |
| ファイルシステム | **XFS**（ext4 ではない） |
| 容量拡張 | マスター ≤ ターゲット。増加分は **root** へ割当。縮小は非対応 |
| 一般化 | 機体固有情報を削除（§4参照） |
| USB | 1本（第1区画: Clonezilla Live / 第2区画: イメージ保存） |
| 運用 | スタンドアロン（ネットワーク不要） |

---

## 2. ファイル構成

```
build.sh                 ISOリマスター（Clonezilla Live に自作スクリプトを組み込む）
src/                     USBに組み込まれるスクリプト（/usr/local/bin へ配置）
├── fandf-menu           日本語メインメニュー（起動時に自動実行）
├── fandf-common         共通関数（ログ・起動USB除外・ディスク/イメージ選択）
├── fandf-initimg        保存領域の初期化（GPT + ext4 + ラベル FANDF-IMG）
├── fandf-capture        キャプチャ（ocs-sr savedisk）
├── fandf-restore        復元（ocs-sr restoredisk）→ 拡張・一般化を呼び出す
├── fandf-expand         容量拡張（LVM + XFS）
└── fandf-generalize     一般化処理
tools/
└── mkusb.sh             実機用USBの作成（ISO書き込み + 保存領域作成）
vm/
├── mkvms.sh             検証用の仮想ディスク作成
└── run.sh               VM起動（UEFI/OVMF、物理デバイス起動にも対応）
```

---

## 3. メニュー構成

```
0 : 保存領域の初期化（USB作成時のみ）
1 : マスターイメージ 抽出（キャプチャ）
2 : ターゲットへの 復元        ← 拡張・一般化まで自動実行
3 : ディスク／イメージ 確認
4 : イメージ 削除
5 : コマンド操作（保守用）
9 : 終了（シャットダウン）
```

### 安全機構
- **起動USBを自動判定して選択候補から除外**（`/run/live/medium` から特定）
- 破壊的操作の前に、対象ディスクの**容量・モデル・シリアル番号**を表示して確認
- キャプチャは一時名で作成し、**SHA-256検証後に正式名へリネーム**（中断イメージを一覧に出さない）
- イメージ一覧は Clonezilla の `disk`/`parts` の有無で判定（`lost+found`・`*.tmp` を自動除外）

---

## 4. 容量拡張と一般化

### 容量拡張（`fandf-expand`）
ターゲットがマスターより大きい場合のみ実行。同容量なら何もしない。

```
sgdisk -e        GPTバックアップヘッダをディスク末尾へ移動（※必須）
growpart/sfdisk  LVMのPVパーティションを末尾まで拡張
pvresize         物理ボリュームに反映
lvextend         root へ空き全部を割当（-l +100%FREE）
xfs_growfs       XFSを拡張（※マウント中でないと拡張できない）
```

> `sgdisk -e` が必要な理由：小容量のイメージを大容量ディスクへ復元すると、
> GPTのバックアップヘッダが旧ディスク末尾の位置に残るため。

### 一般化（`fandf-generalize`）
復元先を「別個体」として起動できる状態にする。復元後に自動実行。

| 削除対象 | 理由 |
|---|---|
| `/etc/ssh/ssh_host_*` | 初回起動時に `sshd-keygen` が再生成 |
| `/etc/machine-id`（空化）、`/var/lib/dbus/machine-id` | 初回起動時に systemd が再生成 |
| `/etc/NetworkManager/system-connections/*` | 機体固有のネットワーク設定 |
| `/etc/udev/rules.d/70-persistent-net.rules` 等 | MAC依存の設定 |
| **`/etc/lvm/devices/system.devices`**、`archive/*`、`backup/*` | **§7参照。別ディスクへの復元に必須** |
| `/var/lib/systemd/random-seed` | 全機が同じ乱数の種を持つのを防ぐ |
| `/var/lib/NetworkManager/secret_key` 等 | NetworkManagerの内部状態 |

---

## 5. 使い方

### ビルド（m-2）
```bash
./build.sh              # 通常（展開結果をキャッシュ利用、1分程度）
./build.sh --clean      # キャッシュ破棄して最初から（5〜8分）
COMP=xz ./build.sh      # 圧縮率優先（納品時にISOを小さくする場合）
```
ビルド末尾で出力ISOを読み直し、起動パラメータが正しく反映されたかを自動検証する。

### 実機用USBの作成（m-2）
```bash
lsblk -o NAME,SIZE,TYPE,RM,MODEL      # ★必ずデバイス名を確認（RM=1 がUSB）
sudo ./tools/mkusb.sh /dev/sdX
```
確認は3段階（ディスク全体か／システム領域がマウントされていないか／**シリアル番号下4桁の入力**）。

完成するUSB：
```
/dev/sdX
├─sdX1  約636M  iso9660  Clonezilla Live + 日本語メニュー（起動領域）
└─sdX2  残り    ext4     FANDF-IMG（イメージ保存領域）
```

### VMでの検証（m-2）
```bash
./vm/mkvms.sh                     # 仮想ディスク作成（sparse）
./vm/run.sh iso                   # メニュー確認のみ
./vm/run.sh iso master usb        # キャプチャ試験
./vm/run.sh iso target80 usb      # 復元＋拡張試験
./vm/run.sh disk target80         # 復元結果の起動確認
./vm/run.sh alma master           # AlmaLinuxをインストール（マスター作成）
sudo ./vm/run.sh disk /dev/sdX    # 作成したUSBをVMで起動テスト
```
画面は VNC（別ターミナルで `vncviewer localhost:1`）。
UEFI変数は毎回初期化されるため、「起動エントリが何も無い実機」と同じ条件で検証できる。

---

## 6. 開発環境

| 環境 | 役割 | 備考 |
|---|---|---|
| VPS (Ubuntu) | コーディングのみ | ビルド・VMは動かさない |
| m-2 (Intel i9-12900E / AlmaLinux 9.8 / 500GB) | ビルド＋VM検証 | 客先提供。作業は `~/work/` 配下 |
| m-1 (IPC1600-IMB-A8000M / AMD Ryzen 7 PRO 8840U) | 実機検証 | 客先提供。USB起動が必要なため現地作業 |

```
VPS で編集 → push → m-2 で git pull && ./build.sh → VM検証 → USB作成 → 実機検証
```

⚠️ **m-2 へOSを復元してはならない**（開発環境一式が消失する）。

---

## 7. 技術メモ（重要）

### LVMデバイスファイルによる起動不能（対処済み）
AlmaLinux 9 は `/etc/lvm/devices/system.devices` に**マスターの物理ディスク識別子**を記録する。

```
IDTYPE=sys_wwid IDNAME=naa.500a075100400027 DEVNAME=/dev/sda3 PVID=... PART=3
```

別の物理ディスクへ復元すると識別子が一致せず、LVMがPVを認識できなくなる。
`rd.lvm.lv` に指定された `root`/`swap` は initramfs が有効化するため起動はするが、
指定外の **`home` が有効化されず、fstabのマウント失敗で emergency mode に落ちる**。

- 同一ディスクへの復元では発生しない（識別子が一致するため）
- 検証VMのマスターに `home` が無かったため、仮想環境では再現しなかった
- → 一般化処理で当該ファイルを削除することで解決（実機で検証済み）

### マスター作成時の注意
保留中のシステム更新（`/system-update`）が残った状態でキャプチャすると、
**復元した全機が初回起動時に同じ更新処理を実行する**。
マスター作成時は更新を適用し、再起動まで完了させてからキャプチャすること。

### 実測値
| 項目 | 値 |
|---|---|
| マスター（223.6GB ディスク） | イメージ **8.8GB**（使用ブロックのみ取得） |
| USB保存領域（55.7GB） | 約5〜6イメージ保存可能 |
| キャプチャ所要時間 | 約10分 |
| 復元＋拡張＋一般化 | 約10分 |

---

## 8. 検証状況

### 仮想環境（m-2）
| 項目 | 結果 |
|---|---|
| ISOのUEFI起動・日本語メニュー | ✅ |
| キャプチャ／復元 | ✅ |
| 容量拡張 40G→80G（root 34.4G→75G） | ✅ |
| 同容量復元（拡張スキップ） | ✅ |
| 一般化（machine-id・SSH鍵・乱数シードの再生成） | ✅ |
| 復元後の起動（UEFI変数が空の状態） | ✅ |

### 実機（m-1 / IPC1600-IMB-A8000M）
| 項目 | 結果 |
|---|---|
| USBからのUEFI起動 | ✅ |
| 起動USBの自動除外 | ✅ |
| モデル名・シリアル番号の表示 | ✅ `SED2QII-LP 240GB` / `SN:0124090500400027` |
| キャプチャ（223.6GB → 8.8GB） | ✅ |
| 240GB → 240GB 復元・起動 | ✅ |
| **240GB → 960GB 復元・拡張（root 741GB）・起動** | ✅ |
| 一般化（削除16件） | ✅ |
| 復元後に `/home` がマウントされること | ✅ |

**2026-08-28 時点で、技術的な検証項目はすべて完了。**

---

## 9. 納品物

| 成果物 | 状態 |
|---|---|
| ソースコード一式（本リポジトリ） | ✅ |
| ブータブルUSB作成手順書 | 作成中 |
| 操作マニュアル | 作成中 |
| マスター準備手順書 | 作成中 |
| テスト報告書 | 作成中 |

Clonezilla Live は GPL のため、カスタマイズ部分を含むソースコードを提供する。
