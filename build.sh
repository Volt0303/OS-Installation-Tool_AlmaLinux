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

# 組み込み先（squashfs内のパス）と、起動時に実行するスクリプト
INSTALL_DIR="/usr/local/bin"
ENTRY="$INSTALL_DIR/fandf-menu"
OCS_LANG="${OCS_LANG:-ja_JP.UTF-8}"   # 起動時ロケール（英語にする場合は en_US.UTF-8）

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mエラー:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 事前確認
SRC="${1:-}"
[ -n "$SRC" ] || SRC="$(ls -1 "$ROOT"/build/clonezilla-live-*.iso 2>/dev/null | head -1 || true)"
[ -n "$SRC" ] && [ -f "$SRC" ] || die "Clonezilla Live の ISO が build/ にありません（引数でパス指定も可）"

for c in xorriso unsquashfs mksquashfs; do
  command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません（xorriso / squashfs-tools を導入してください）"
done
[ -d "$ROOT/src" ] || die "src/ がありません"

msg "元ISO: $SRC"

# ---------------------------------------------------------------- 1. 展開
msg "1/6 ISO から squashfs と起動設定を取り出し"
sudo rm -rf "$WORK"; mkdir -p "$WORK"
xorriso -osirrox on -indev "$SRC" \
        -extract /live/filesystem.squashfs "$WORK/filesystem.squashfs" >/dev/null 2>&1 \
  || die "filesystem.squashfs を取り出せません（Clonezilla Live の ISO か確認してください）"

# 起動設定（BIOS: /syslinux, UEFI: /EFI, /boot/grub）を取り出す
for d in /syslinux /EFI /boot; do
  xorriso -osirrox on -indev "$SRC" -extract "$d" "$WORK/iso$d" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------- 2. 解凍
msg "2/6 squashfs を解凍（rootfs）"
sudo rm -rf "$WORK/rootfs"
sudo unsquashfs -q -d "$WORK/rootfs" "$WORK/filesystem.squashfs" >/dev/null

# ---------------------------------------------------------------- 3. 注入
msg "3/6 自作スクリプトを注入 → $INSTALL_DIR"
sudo mkdir -p "$WORK/rootfs$INSTALL_DIR"
sudo cp -a "$ROOT/src/." "$WORK/rootfs$INSTALL_DIR/"
sudo chown -R 0:0 "$WORK/rootfs$INSTALL_DIR"
sudo chmod -R 0755 "$WORK/rootfs$INSTALL_DIR"
[ -f "$WORK/rootfs$ENTRY" ] || die "起動対象 $ENTRY が src/ にありません（src/fandf-menu を用意してください）"

# ---------------------------------------------------------------- 4. 再圧縮
msg "4/6 squashfs を再圧縮"
sudo rm -f "$WORK/filesystem.new.squashfs"
sudo mksquashfs "$WORK/rootfs" "$WORK/filesystem.new.squashfs" \
     -comp xz -b 1M -noappend -no-progress >/dev/null

# ---------------------------------------------------------------- 5. 起動設定
msg "5/6 起動パラメータを書き換え（ocs_live_run → $ENTRY）"
mapfile -t CFGS < <(find "$WORK/iso" -type f \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null || true)
PATCHED=0
for f in "${CFGS[@]:-}"; do
  grep -q 'ocs_live_run=' "$f" 2>/dev/null || continue
  # ocs_live_run: 自作メニューを指定
  # locales / keyboard-layouts: 空だと起動時に言語・キーボードの選択画面が出るため固定
  sudo sed -i -E \
    -e "s|ocs_live_run=\"[^\"]*\"|ocs_live_run=\"$ENTRY\"|g" \
    -e "s|ocs_lang=\"[^\"]*\"|ocs_lang=\"$OCS_LANG\"|g" \
    -e "s| locales=[^[:space:]\"]*| locales=$OCS_LANG|g" \
    -e "s| keyboard-layouts=[^[:space:]\"]*| keyboard-layouts=NONE|g" \
    -e "s|ocs_live_keymap=\"[^\"]*\"|ocs_live_keymap=\"NONE\"|g" \
    "$f"
  PATCHED=$((PATCHED+1))
done
[ "$PATCHED" -gt 0 ] || die "ocs_live_run を含む起動設定が見つかりません（ISOの構成を確認してください）"
echo "    書き換えた設定ファイル: $PATCHED 件"
echo "    確認 → $(grep -ohm1 'ocs_live_run="[^"]*"' "${CFGS[@]}" | head -1) / $(grep -ohm1 'locales=[^ "]*' "${CFGS[@]}" | head -1)"

# ---------------------------------------------------------------- 6. ISO再構築
msg "6/6 ISO を再構築（元の起動レコードを引き継ぎ）"
rm -f "$OUT"
XARGS=( -indev "$SRC" -outdev "$OUT" -boot_image any replay
        -rm_r /live/filesystem.squashfs --
        -map "$WORK/filesystem.new.squashfs" /live/filesystem.squashfs )
for f in "${CFGS[@]:-}"; do
  grep -q "ocs_live_run=\"$ENTRY\"" "$f" 2>/dev/null || continue
  rel="/${f#"$WORK/iso/"}"
  XARGS+=( -rm_r "$rel" -- -map "$f" "$rel" )
done
xorriso "${XARGS[@]}" -commit >/dev/null 2>&1 || die "ISO の再構築に失敗しました"

msg "完成: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "  VMで試す : ./vm/run.sh iso"
echo "  USBに書く: sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
