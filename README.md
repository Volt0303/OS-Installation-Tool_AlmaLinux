# F&F OSインストールツール（AlmaLinux版 / Clonezillaベース）

エフアンドエフ株式会社向け。AlmaLinux 9.8 のマスターをキャプチャし、
同一機種（IPC1600-IMB-A8000M）へ復元するカスタム Clonezilla Live USB。

## 確定仕様
| 項目 | 内容 |
|---|---|
| 対象機種 | IPC1600-IMB-A8000M（単一機種） |
| OS | AlmaLinux 9.8 |
| ディスク | SATA SSD 240GB / GPT / UEFI（Secure Boot 無効） |
| パーティション | sda1 ESP(vfat 600M) / sda2 /boot(xfs 1G) / sda3 LVM PV |
| LVM | VG=almalinux, LV=root(xfs) / home(xfs) / swap |
| ファイルシステム | **XFS**（ext4 ではない） |
| 容量拡張 | マスター ≤ ターゲット。増加分は **root** へ割当 |
| 拡張手順 | growpart → pvresize → lvextend → xfs_growfs |
| 一般化 | SSHホスト鍵 / machine-id / NetworkManager接続 の削除 |
| USB | 1本（part1: Clonezilla Live / part2: イメージ保存） |

## 開発環境の役割分担
| 環境 | 役割 |
|---|---|
| VPS (Ubuntu) | コーディングのみ。ビルド・VMは動かさない |
| m-2 (Intel/AlmaLinux 9.8) | ビルド＋VM試験の主戦場 |
| m-1 (AMD/IPC1600) | 最終ベアメタル検証のみ |

## 使い方（m-2 側）
```
git pull && ./build.sh && ./vm/run.sh target
```
