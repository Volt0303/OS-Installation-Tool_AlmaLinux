#!/usr/bin/env bash
#
# VMを起動する（UEFI / OVMF）
#
#   ./vm/run.sh iso                  自作ISOのみ起動（メニュー確認）
#   ./vm/run.sh iso master usb       キャプチャ試験（master＋保存先USB）
#   ./vm/run.sh iso target80 usb     復元試験（ターゲット＋USB）
#   ./vm/run.sh disk target80        復元後のディスクから起動（起動確認）
#   ./vm/run.sh alma master          AlmaLinuxをインストール（マスター作成）
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
MEM="${MEM:-4096}"; CPUS="${CPUS:-4}"; VNC="${VNC:-1}"     # VNC :1 = ポート5901

# --- 起動元の決定 -------------------------------------------------------
ARGS=( -machine q35,accel=kvm -cpu host -m "$MEM" -smp "$CPUS" )
case "$MODE" in
  iso)   SRC="$ROOT/build/fandf-osinstall.iso"
         [ -f "$SRC" ] || { echo "エラー: $SRC がありません → ./build.sh を実行"; exit 1; }
         ARGS+=( -drive file="$SRC",if=none,id=cd0,media=cdrom
                 -device ide-cd,drive=cd0,bus=ide.0 -boot order=d ) ;;
  alma)  SRC="$(ls -1 "$ROOT"/build/AlmaLinux-9*.iso 2>/dev/null | head -1 || true)"
         [ -n "$SRC" ] || { echo "エラー: build/ に AlmaLinux-9*.iso を置いてください"; exit 1; }
         ARGS+=( -drive file="$SRC",if=none,id=cd0,media=cdrom
                 -device ide-cd,drive=cd0,bus=ide.0 -boot order=d ) ;;
  disk)  ARGS+=( -boot order=c ) ;;
  *)     echo "使い方: ./vm/run.sh {iso|alma|disk} [ディスク名...]"; exit 1 ;;
esac

# --- ディスク接続 -------------------------------------------------------
NAME="${1:-live}"
i=0
for d in "$@"; do
  f="$D/$d.qcow2"
  [ -f "$f" ] || { echo "エラー: $f がありません → ./vm/mkvms.sh $d <サイズ>"; exit 1; }
  # 実機(m-1)と同じ /dev/sdX になるよう SATA(AHCI) で接続し、シリアル番号も付与する
  ARGS+=( -drive file="$f",if=none,id=d$i,format=qcow2
          -device ide-hd,drive=d$i,bus=ide.$((i+1)),serial="VMDISK$(printf '%04d' $((1000+i)))" )
  i=$((i+1))
done

# --- UEFI変数領域（VMごとに書き込み可能なコピーを持たせる）--------------
VARS="$D/${NAME}_VARS.fd"
[ -f "$VARS" ] || cp "$OVMF_VARS" "$VARS"
ARGS+=( -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE"
        -drive if=pflash,format=raw,unit=1,file="$VARS" )

# --- 画面（VNC）--------------------------------------------------------
ARGS+=( -vnc ":$VNC" -k ja -usb -device usb-tablet )

cat <<MSG

  起動モード : $MODE
  ディスク   : ${*:-（なし）}
  画面       : VNC :$VNC  →  別ターミナルで  vncviewer localhost:$VNC
                            （未導入なら  sudo dnf install -y tigervnc）
  終了       : このターミナルで Ctrl+C

MSG
exec "$QEMU" "${ARGS[@]}"
