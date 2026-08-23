#!/usr/bin/env bash
#
# 実機用 OSインストールUSB の作成
#
#   sudo ./tools/mkusb.sh /dev/sdX [ISOのパス]
#
# 処理内容
#   ① ISO を USB へ書き込む（起動領域ができる）
#   ② GPTバックアップヘッダを USB の末尾へ移動する
#   ③ 残りの領域に イメージ保存用パーティション（ext4 / ラベル FANDF-IMG）を作成
#
# ※ 指定したUSBの内容はすべて消去されます
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMGLABEL="FANDF-IMG"

c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
line()   { printf '%s\n' "------------------------------------------------------------"; }
die()    { c_err "エラー: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "root権限で実行してください（sudo ./tools/mkusb.sh ...）"
for c in dd sgdisk partprobe mkfs.ext4 lsblk; do
  command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません（gdisk / e2fsprogs を導入してください）"
done

DEV="${1:-}"
ISO="${2:-$ROOT/build/fandf-osinstall.iso}"
[ -n "$DEV" ] || die "使い方: sudo ./tools/mkusb.sh /dev/sdX [ISO]"
[ -b "$DEV" ] || die "$DEV はブロックデバイスではありません"
[ -f "$ISO" ] || die "ISOがありません: $ISO"

# --- 安全確認 ① パーティションではなくディスク全体か --------------------
[ "$(lsblk -dno TYPE "$DEV")" = "disk" ] || die "$DEV はディスク全体ではありません（/dev/sdb のように指定）"

# --- 安全確認 ② システム領域がマウントされていないか --------------------
# / や /boot 等が乗っていれば、それはシステムディスク → 絶対に拒否する
SYSMNT="$(lsblk -no MOUNTPOINTS "$DEV" 2>/dev/null \
          | grep -Ex '/|/boot|/boot/efi|/home|/usr|/var|/etc|\[SWAP\]' || true)"
if [ -n "$SYSMNT" ]; then
  c_err "$DEV にはシステム領域（$(echo "$SYSMNT" | tr '\n' ' ')）がマウントされています。"
  c_err "システムディスクを指定している可能性があります。"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
  die "中止しました"
fi
# それ以外（デスクトップによる自動マウント等）は書き込み前に解除する
AUTOMNT="$(lsblk -no MOUNTPOINTS "$DEV" 2>/dev/null | grep '[^[:space:]]' || true)"
[ -n "$AUTOMNT" ] && c_warn "  ※ 自動マウントを検出（書き込み前に解除します）: $(echo "$AUTOMNT" | tr '\n' ' ')"

# --- 情報表示 ------------------------------------------------------------
MODEL="$(lsblk -dno MODEL  "$DEV" | xargs)"
SERIAL="$(lsblk -dno SERIAL "$DEV" | xargs)"
SIZE="$(lsblk -dno SIZE   "$DEV" | xargs)"
RM="$(lsblk -dno RM       "$DEV" | xargs)"
ISOSZ="$(du -h "$ISO" | cut -f1)"

echo; line
echo "  === OSインストールUSB の作成 ==="
line
printf '  書き込むISO : %s (%s)\n' "$(basename "$ISO")" "$ISOSZ"
printf '  対象デバイス: %s\n' "$DEV"
printf '    モデル    : %s\n' "${MODEL:-不明}"
printf '    容量      : %s\n' "$SIZE"
printf '    シリアル  : %s\n' "${SERIAL:-不明}"
printf '    リムーバブル: %s\n' "$([ "$RM" = 1 ] && echo "はい（USB等）" || echo "いいえ ← 内蔵ディスクの可能性")"
line
[ "$RM" = 1 ] || c_warn "  ⚠ リムーバブルではありません。内蔵ディスクを指定していないか必ず確認してください"
c_warn "  ※ $DEV の内容はすべて消去されます（取り消せません）"
echo

# --- 安全確認 ③ シリアル番号の下4桁を入力させる（誤消去の最終防止）-----
if [ -n "$SERIAL" ] && [ "$SERIAL" != "不明" ]; then
  SUF="${SERIAL: -4}"
  read -rp "確認のため、シリアル番号の下4桁を入力してください: " IN
  [ "$IN" = "$SUF" ] || die "確認番号が一致しません。処理を中止しました"
else
  c_warn "  シリアル番号が取得できないため、デバイス名で確認します"
  read -rp "対象デバイス名をそのまま入力してください（例: $DEV）: " IN
  [ "$IN" = "$DEV" ] || die "入力が一致しません。処理を中止しました"
fi
read -rp "本当に作成しますか？ (y/N): " YN
[ "${YN,,}" = "y" ] || { c_warn "中止しました"; exit 0; }

# --- ① ISO書き込み -------------------------------------------------------
echo; echo "① ISO を書き込み中..."
umount "$DEV"?* 2>/dev/null || true
dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync || die "書き込みに失敗しました"
sync; partprobe "$DEV" >/dev/null 2>&1 || true; udevadm settle 2>/dev/null || sleep 2

# --- ② GPTバックアップヘッダを末尾へ ------------------------------------
# ISOはUSBより小さいため、バックアップGPTがディスク中間に残る。これを末尾へ移す。
echo "② GPTバックアップヘッダを末尾へ移動"
sgdisk -e "$DEV" >/dev/null 2>&1 || c_warn "   sgdisk -e で警告（続行します）"
partprobe "$DEV" >/dev/null 2>&1 || true; udevadm settle 2>/dev/null || sleep 2

# --- ③ イメージ保存領域の作成 -------------------------------------------
echo "③ イメージ保存領域を作成（ext4 / ラベル $IMGLABEL）"
BEFORE="$(lsblk -lno NAME,TYPE "$DEV" | awk '$2=="part"{print $1}')"
sgdisk -n 0:0:0 -t 0:8300 -c 0:"$IMGLABEL" "$DEV" >/dev/null 2>&1 \
  || die "パーティションの作成に失敗しました"
partprobe "$DEV" >/dev/null 2>&1 || true; udevadm settle 2>/dev/null || sleep 3

AFTER="$(lsblk -lno NAME,TYPE "$DEV" | awk '$2=="part"{print $1}')"
NEW="$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort) | head -1)"
[ -n "$NEW" ] || die "新しいパーティションが認識できません"
NEWPART="/dev/$NEW"

mkfs.ext4 -q -F -L "$IMGLABEL" "$NEWPART" || die "フォーマットに失敗しました"
sync

# --- 検証 ----------------------------------------------------------------
echo
line
c_ok "  作成完了"
line
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$DEV"
echo
if [ "$(blkid -L "$IMGLABEL" 2>/dev/null)" = "$NEWPART" ]; then
  c_ok "  ✅ イメージ保存領域: $NEWPART (ラベル $IMGLABEL)"
else
  c_warn "  ⚠ ラベルの確認ができませんでした"
fi
echo
echo "  このUSBを対象PCに挿し、UEFIの起動メニューから選択してください。"
