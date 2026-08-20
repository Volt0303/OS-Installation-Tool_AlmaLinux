#!/usr/bin/env bash
#
# F&F OSインストールツール（AlmaLinux版）
# Clonezilla Live ISO をリマスターし、自作の日本語メニューを組み込んだ
# 起動可能な ISO を生成する。
#
#   使い方:  ./build.sh [元ISOのパス]
#   出力  :  build/fandf-osinstall.iso
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/build/work"
OUT="$ROOT/build/fandf-osinstall.iso"

INSTALL_DIR="/usr/local/bin"
ENTRY="$INSTALL_DIR/fandf-menu"
OCS_LANG="${OCS_LANG:-ja_JP.UTF-8}"   # 起動時ロケール（英語にする場合は en_US.UTF-8）
COMP="${COMP:-zstd}"                  # squashfs圧縮（zstd=高速 / xz=高圧縮）

# --clean を付けるとキャッシュを破棄して最初からやり直す
CLEAN=0
[ "${1:-}" = "--clean" ] && { CLEAN=1; shift; }

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mエラー:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 事前確認
SRC="${1:-}"
[ -n "$SRC" ] || SRC="$(ls -1 "$ROOT"/build/clonezilla-live-*.iso 2>/dev/null | head -1 || true)"
[ -n "$SRC" ] && [ -f "$SRC" ] || die "Clonezilla Live の ISO が build/ にありません（引数でパス指定も可）"
for c in xorriso unsquashfs mksquashfs; do
  command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません（xorriso / squashfs-tools を導入してください）"
done
[ -f "$ROOT/src/fandf-menu" ] || die "src/fandf-menu がありません"
msg "元ISO: $SRC"

# ---------------------------------------------------------------- 1. 全展開
[ "$CLEAN" = 1 ] && { echo "  （--clean: キャッシュを破棄）"; sudo rm -rf "$WORK"; }
mkdir -p "$WORK"
if [ -f "$WORK/iso/live/filesystem.squashfs" ] && [ -d "$WORK/rootfs" ]; then
  msg "1/7 展開はキャッシュを使用（やり直すには ./build.sh --clean）"
else
  msg "1/7 ISO を丸ごと展開（初回のみ・数分かかります）"
  sudo rm -rf "$WORK"; mkdir -p "$WORK"
  xorriso -osirrox on -indev "$SRC" -extract / "$WORK/iso" >/dev/null 2>&1 \
    || die "ISO の展開に失敗しました"
  sudo chmod -R u+w "$WORK/iso"         # 展開直後は読み取り専用のため書き込み可に
  [ -f "$WORK/iso/live/filesystem.squashfs" ] || die "/live/filesystem.squashfs がありません"
fi

# ---------------------------------------------------------------- 2. 解凍
if [ -d "$WORK/rootfs/usr" ]; then
  msg "2/7 squashfs の解凍はキャッシュを使用"
else
  msg "2/7 squashfs を解凍（初回のみ）"
  sudo unsquashfs -q -d "$WORK/rootfs" "$WORK/iso/live/filesystem.squashfs" >/dev/null
fi

# ---------------------------------------------------------------- 3. 注入
msg "3/7 自作スクリプトを注入 → $INSTALL_DIR"
sudo rm -rf "$WORK/rootfs$INSTALL_DIR/fandf-"*      # 前回分を除去
sudo mkdir -p "$WORK/rootfs$INSTALL_DIR"
sudo cp -a "$ROOT/src/." "$WORK/rootfs$INSTALL_DIR/"
sudo chown -R 0:0 "$WORK/rootfs$INSTALL_DIR"
sudo chmod -R 0755 "$WORK/rootfs$INSTALL_DIR"

# ---------------------------------------------------------------- 4. 再圧縮
msg "4/7 squashfs を再圧縮（$COMP）"
sudo rm -f "$WORK/iso/live/filesystem.squashfs"
sudo mksquashfs "$WORK/rootfs" "$WORK/iso/live/filesystem.squashfs" \
     -comp "$COMP" -b 1M -noappend -no-progress >/dev/null \
  || die "mksquashfs に失敗（COMP=xz ./build.sh で再試行できます）"

# ---------------------------------------------------------------- 5. 起動設定
msg "5/7 起動パラメータを書き換え"
# キャッシュ利用時に二重適用しないよう、設定ファイルだけ毎回originalへ戻す
for d in /boot /EFI /syslinux /isolinux; do
  [ -d "$WORK/iso$d" ] || continue
  sudo rm -rf "$WORK/iso$d"
  xorriso -osirrox on -indev "$SRC" -extract "$d" "$WORK/iso$d" >/dev/null 2>&1 || true
  sudo chmod -R u+w "$WORK/iso$d" 2>/dev/null || true
done
PATCHED=0
while IFS= read -r f; do
  grep -q 'ocs_live_run=' "$f" 2>/dev/null || continue
  # 既存の言語/キーマップ指定を除去し、ocs_live_run の置換と同時にまとめて付与する
  sudo sed -i -E \
    -e "s| ocs_lang=\"[^\"]*\"||g" \
    -e "s| ocs_live_keymap=\"[^\"]*\"||g" \
    -e "s| ocs_live_batch=\"[^\"]*\"||g" \
    -e "s|ocs_live_run=\"[^\"]*\"|ocs_live_run=\"$ENTRY\" ocs_lang=\"$OCS_LANG\" ocs_live_keymap=\"NONE\" ocs_live_batch=\"yes\"|g" \
    -e "s| locales=[^[:space:]\"]*| locales=$OCS_LANG|g" \
    -e "s| keyboard-layouts=[^[:space:]\"]*| keyboard-layouts=NONE|g" \
    "$f"
  echo "    修正: ${f#"$WORK/iso"}"
  PATCHED=$((PATCHED+1))
done < <(find "$WORK/iso" -type f \( -name '*.cfg' -o -name '*.conf' \))
[ "$PATCHED" -gt 0 ] || die "ocs_live_run を含む起動設定が見つかりません"

# ---------------------------------------------------------------- 6. ISO再構築
msg "6/7 ISO を再構築（元の起動レコードを引き継ぎ、全ファイルを反映）"
rm -f "$OUT"
xorriso -indev "$SRC" -outdev "$OUT" \
        -boot_image any replay \
        -update_r "$WORK/iso" / \
        -commit >/dev/null 2>&1 || die "ISO の再構築に失敗しました"

# ---------------------------------------------------------------- 7. 検証
msg "7/7 出力ISOを読み直して検証"
VER="$WORK/verify"; rm -rf "$VER"; mkdir -p "$VER"
for d in /boot /EFI /syslinux /isolinux; do
  xorriso -osirrox on -indev "$OUT" -extract "$d" "$VER$d" >/dev/null 2>&1 || true
done
if grep -rqs "ocs_live_run=\"$ENTRY\"" "$VER"; then
  echo "    ✅ 自作メニューが設定されています"
  grep -rhos 'ocs_live_run="[^"]*" ocs_lang="[^"]*" ocs_live_keymap="[^"]*"' "$VER" | sort -u | sed 's/^/       /'
else
  echo "    ❌ 出力ISOに反映されていません（元の設定のままです）"
  grep -rhos 'ocs_live_run="[^"]*"' "$VER" | sort -u | sed 's/^/       /'
  die "検証に失敗しました"
fi
if grep -rqs ' locales=[^ ]' "$VER"; then
  echo "    ✅ locales / keyboard-layouts も設定済み"
fi

msg "完成: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "  VMで試す : ./vm/run.sh iso"
echo "  USBに書く: sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
