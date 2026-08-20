#!/usr/bin/env bash
#
# 検証用の仮想ディスクを作成する（すべてsparse＝実使用分しか消費しない）
#
#   ./vm/mkvms.sh              既定セットを作成
#   ./vm/mkvms.sh name 480G    個別に作成
#
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)/disks"
mkdir -p "$D"

mk() {
  local n="$1" s="$2"
  if [ -f "$D/$n.qcow2" ]; then
    printf '  %-12s 既存（スキップ）\n' "$n"
  else
    qemu-img create -f qcow2 "$D/$n.qcow2" "$s" >/dev/null
    printf '  %-12s %s 作成\n' "$n" "$s"
  fi
}

if [ $# -eq 2 ]; then
  mk "$1" "$2"
else
  echo "既定セットを作成:"
  mk master    40G      # 反復用マスター（小さく作って高速に回す）
  mk target40  40G      # 同容量テスト（拡張なし）
  mk target80  80G      # 拡張テスト（マスターの2倍）
  mk usb       64G      # イメージ保存領域（USB相当）
  echo
  echo "  ※ 実サイズ検証(240G→480G)が必要になったら:"
  echo "     ./vm/mkvms.sh master240 240G && ./vm/mkvms.sh target480 480G"
fi
echo
du -sh --apparent-size "$D"/*.qcow2 2>/dev/null | sed 's/^/  仮想: /'
du -sh "$D"/*.qcow2 2>/dev/null | sed 's/^/  実消費: /'
