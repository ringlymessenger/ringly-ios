#!/usr/bin/env bash
#
# Собирает Frameworks/LibXray.xcframework — обфусцированный транспорт (VLESS+Reality) для обхода
# блокировок. Без него приложение собирается и работает, но мостики недоступны: BridgeTunnelFactory
# через `#if canImport(LibXray)` подставляет заглушку.
#
# Почему скрипт, а не файл в репозитории: xcframework весит ~256 МБ, а один только бинарник
# устройства — 90 МБ. GitHub ругается на файлы больше 50 МБ и отказывается принимать больше 100 МБ,
# так что без git-lfs в репозиторий это не кладётся. Поэтому — как Pods: собирается на месте.
#
#   ./scripts/build-libxray.sh
#
# Требуется: Go, Python 3, Xcode. gomobile скрипт сборки ставит сам.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/libxray-build"
OUT="$REPO_ROOT/Frameworks/LibXray.xcframework"

# Версия libXray. ⚠️ Обновляя, сверяйте LibXrayAPIVersion в invoke_model.go с константой
# `apiVersion` в RinglyCore/LibXrayBridgeTunnel.swift: номер проверяется на точное равенство,
# и расхождение даёт `unsupported apiVersion` на каждый вызов — туннель молча не поднимется.
LIBXRAY_REF="${LIBXRAY_REF:-main}"

echo "==> libXray ($LIBXRAY_REF) → $OUT"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
git clone --depth 1 --branch "$LIBXRAY_REF" https://github.com/XTLS/libXray.git "$WORK_DIR/libXray"

cd "$WORK_DIR/libXray"
export PATH="$PATH:$(go env GOPATH)/bin"
python3 build/main.py apple gomobile

# Сборочный скрипт делает четыре среза: iOS, симулятор, macOS и Mac Catalyst — 595 МБ.
# Оставляем только нужные два; это ещё и единственный способ уложиться в вес, пригодный для работы.
echo "==> оставляем только срезы iOS"
rm -rf "$OUT"
mkdir -p "$REPO_ROOT/Frameworks"
xcodebuild -create-xcframework \
	-framework "$WORK_DIR/libXray/LibXray.xcframework/ios-arm64/LibXray.framework" \
	-framework "$WORK_DIR/libXray/LibXray.xcframework/ios-arm64_x86_64-simulator/LibXray.framework" \
	-output "$OUT"

rm -rf "$WORK_DIR"
echo "==> готово: $(du -sh "$OUT" | cut -f1)"
echo "    Фреймворк уже прописан в проекте (Link Binary With Libraries у таргета «ringly app»)."
echo "    ⚠️ Он СТАТИЧЕСКИЙ — линкуется, но НЕ встраивается, и НЕ подключается к NotificationService."
