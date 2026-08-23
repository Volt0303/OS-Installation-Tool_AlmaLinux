#!/usr/bin/env bash
#
# VMを起動する（UEFI / OVMF / SATA接続）
#
#   ./vm/run.sh iso                  自作ISOのみ起動（メニュー確認）
#   ./vm/run.sh iso master usb       キャプチャ試験（master＋保存先）
#   ./vm/run.sh iso target80 usb     復元＋拡張試験
#   ./vm/run.sh disk target80        復元後のディスクから起動（起動確認）
#   ./vm/run.sh alma master          AlmaLinuxをインストール（マスター作成）
#
#   環境変数: MEM(既定4096) CPUS(4) VNC(1) KEEPVARS=1(UEFI変数を保持)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/vm/disks"; mkdir -p "$D"

QEMU=/usr/libexec/qemu-kvm
[ -x "$QEMU" ] || QEMU="$(command -v qemu-system-x86_64 || true)"
[ -x "$QEMU" ] || { echo "エラー: qemu-kvm が見つかりません"; exit 1; }

OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd
[ -f "$OVMF_CODE" ] || { echo "エラー: OVMF(UEFI)がありません → dnf install edk2-ovmf"; exit 1; }

MODE="${1:-iso}"; shift || true
MEM="${MEM:-4096}"; CPUS="${CPUS:-4}"; VNC="${VNC:-1}"; KEEPVARS="${KEEPVARS:-0}"

ARGS=( -machine q35,accel=kvm -cpu host -m "$MEM" -smp "$CPUS" )

# --- 起動元（CD）------------------------------------------------------
CD=""
case "$MODE" in
  iso)  CD="$ROOT/build/fandf-osinstall.iso"
        [ -f "$CD" ] || { echo "エラー: $CD がありません → ./build.sh を実行"; exit 1; } ;;
  alma) CD="$(ls -1 "$ROOT"/build/AlmaLinux-9*.iso 2>/dev/null | head -1 || true)"
        [ -n "$CD" ] || { echo "エラー: build/ に AlmaLinux-9*.iso を置いてください"; exit 1; } ;;
  disk) ;;
  *)    echo "使い方: ./vm/run.sh {iso|alma|disk} [ディスク名...]"; exit 1 ;;
esac

# bootindex が小さいものから起動する。CD起動時はCDを最優先にする
if [ -n "$CD" ]; then
  ARGS+=( -drive file="$CD",if=none,id=cd0,media=cdrom,readonly=on
          -device ide-cd,drive=cd0,bus=ide.0,bootindex=0 )
  IDX=1
else
  IDX=0
fi

# --- ディスク接続（実機と同じ /dev/sdX になるよう SATA で接続）--------
# ディスク名は vm/disks/<名前>.qcow2 のほか、/dev/sdX を直接指定できる
#   例) sudo ./vm/run.sh disk /dev/sdb  … 作成したUSBをVMで起動テストする
i=0
for d in "$@"; do
  if [ "${d#/dev/}" != "$d" ]; then
    f="$d"; FMT=raw
    [ -b "$f" ] || { echo "エラー: $f はブロックデバイスではありません"; exit 1; }
    [ -r "$f" ] || { echo "エラー: $f を読めません（sudo で実行してください）"; exit 1; }
  else
    f="$D/$d.qcow2"; FMT=qcow2
    [ -f "$f" ] || { echo "エラー: $f がありません → ./vm/mkvms.sh $d <サイズ>"; exit 1; }
  fi
  ARGS+=( -drive file="$f",if=none,id=d$i,format=$FMT
          -device ide-hd,drive=d$i,bus=ide.$((i+1)),serial="VMDISK$(printf '%04d' $((1000+i)))",bootindex=$((IDX+i)) )
  i=$((i+1))
done

# --- UEFI変数領域 -----------------------------------------------------
# 既定では毎回まっさらな状態から起動する。
#   → 前回インストール時の起動エントリが残っていてCDから起動できない事故を防ぐ
#   → 復元後の「NVRAMに何も無い実機」と同じ条件になるため検証としても正しい
NAME="$(basename "${1:-live}")"
VARS="$D/${MODE}_${NAME}_VARS.fd"
if [ "$KEEPVARS" != 1 ] || [ ! -f "$VARS" ]; then cp -f "$OVMF_VARS" "$VARS"; fi
ARGS+=( -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE"
        -drive if=pflash,format=raw,unit=1,file="$VARS" )

ARGS+=( -vnc ":$VNC" -k ja -usb -device usb-tablet )

cat <<MSG

  起動モード : $MODE $([ -n "$CD" ] && echo "(CD: $(basename "$CD"))")
  ディスク   : ${*:-（なし）}
  UEFI変数   : $([ "$KEEPVARS" = 1 ] && echo "保持" || echo "毎回初期化（KEEPVARS=1 で保持）")
  画面       : VNC :$VNC  →  別ターミナルで  vncviewer localhost:$VNC
  終了       : このターミナルで Ctrl+C

MSG
exec "$QEMU" "${ARGS[@]}"
