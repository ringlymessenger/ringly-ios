#!/usr/bin/env bash
#
# Выгрузка исходников релиза в ПУБЛИЧНЫЙ репозиторий ringly-ios (лицензия AGPL-3.0).
#
# Схема: разработка — в этом (приватном) репозитории, в публичный на каждый релиз App Store уходит
# один коммит — точный снимок кода этой версии, БЕЗ истории (в истории приватного остались удалённые
# внутренние документы и старые конфиги). Тег публичного = версия.
#
#   ./scripts/publish-public.sh <путь-к-клону-ringly-ios> <тег> [коммит]
#   ./scripts/publish-public.sh ~/Desktop/ringly-ios v1.1
#
# Коммит по умолчанию — HEAD; укажите тот, из которого собрана сборка в App Store, если HEAD ушёл
# дальше. Скрипт ничего не отправляет в сеть: проверьте результат и сделайте push сами.
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }

DEST="${1:-}"; TAG="${2:-}"; REF="${3:-HEAD}"
[ -n "$DEST" ] && [ -n "$TAG" ] || die "использование: $0 <путь-к-клону-ringly-ios> <тег> [коммит]"

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

# Выгружаем только закоммиченное: снимок обязан совпадать с тем, из чего собрана сборка.
git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || die "нет такого коммита: $REF"
if [ "$REF" = "HEAD" ] && ! git diff --quiet HEAD; then
	die "есть незакоммиченные изменения — закоммитьте или укажите коммит явно"
fi

[ -d "$DEST/.git" ] || die "$DEST — не git-репозиторий (сначала: git clone <url публичного репозитория> \"$DEST\")"
git -C "$DEST" diff --quiet HEAD 2>/dev/null || [ -z "$(git -C "$DEST" rev-parse --verify --quiet HEAD)" ] \
	|| die "в $DEST есть незакоммиченные изменения"
if git -C "$DEST" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
	die "тег $TAG в публичном репозитории уже есть"
fi

# Версия и номер сборки — как их считает сам проект: MARKETING_VERSION и число коммитов
# (build phase «Auto build number»).
# Весь вывод читаем целиком (без grep -m1/head на трубе: при pipefail ранний выход давал бы SIGPIPE).
VERSION="$(git show "$REF:ringly app.xcodeproj/project.pbxproj" | sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' | sort -u)"
BUILD="$(git rev-list --count "$REF")"
[ -n "$VERSION" ] || die "не нашёл MARKETING_VERSION"
[ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" = "1" ] || die "MARKETING_VERSION различается в конфигурациях: $(echo $VERSION)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Только отслеживаемые файлы этого коммита — без истории, Pods, DerivedData и прочего.
git archive "$REF" | tar -x -C "$TMP"

# Что не публикуем: личные настройки Xcode, служебные файлы разработки, файлы самого публикатора.
EXCLUDE=(
	"ringly app.xcodeproj/xcuserdata"
	"ringly app.xcodeproj/project.xcworkspace/xcuserdata"
	"ringly app.xcworkspace/xcuserdata"
	"login-screen.png"
	"CLAUDE.md"
	".claude"
	"docs"
	"docs-shared"
	"scripts/public"
)
for p in "${EXCLUDE[@]}"; do rm -rf "$TMP/$p"; done
find "$TMP" -name "xcuserdata" -type d -prune -exec rm -rf {} +
find "$TMP" -name ".DS_Store" -delete

# Файлы, которые есть только в публичном репозитории.
cp scripts/public/README.md scripts/public/LICENSE scripts/public/SECURITY.md "$TMP/"

# Последний рубеж: явные признаки секретов. Совпадение — остановка, а не предупреждение.
if grep -rInE \
	-e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
	-e 'AKIA[0-9A-Z]{16}' \
	-e 'ghp_[A-Za-z0-9]{30,}' \
	-e 'xox[abp]-[A-Za-z0-9-]{10,}' \
	-e 'sk_live_[A-Za-z0-9]{10,}' \
	-e 'AIza[0-9A-Za-z_-]{35}' \
	--include='*' "$TMP" >/dev/null; then
	grep -rInE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'AKIA[0-9A-Z]{16}' -e 'ghp_[A-Za-z0-9]{30,}' \
		-e 'xox[abp]-[A-Za-z0-9-]{10,}' -e 'sk_live_[A-Za-z0-9]{10,}' -e 'AIza[0-9A-Za-z_-]{35}' "$TMP" | sed "s|$TMP/||" >&2
	die "похоже на секрет — выгрузка остановлена"
fi
for f in GoogleService-Info.plist "*.p8" "*.p12" "*.mobileprovision" "*.cer" ".env"; do
	if [ -n "$(find "$TMP" -name "$f" -print -quit)" ]; then die "в снимке есть $f — выгрузка остановлена"; fi
done

# Подменяем содержимое публичного репозитория снимком (удалённые в приватном файлы уйдут и тут).
rsync -a --delete --exclude '.git' "$TMP/" "$DEST/"

git -C "$DEST" add -A
if git -C "$DEST" diff --cached --quiet; then
	die "изменений нет — этот код уже опубликован"
fi
git -C "$DEST" commit -q -m "Ringly iOS $VERSION (build $BUILD)" \
	-m "Source of the App Store release $VERSION, build $BUILD."
git -C "$DEST" tag -a "$TAG" -m "Ringly iOS $VERSION (build $BUILD)"

echo "✅ Ringly iOS $VERSION (сборка $BUILD) → $DEST, тег $TAG"
echo "   Проверьте:  git -C \"$DEST\" show --stat HEAD | head -40"
echo "   Отправьте:  git -C \"$DEST\" push origin HEAD --tags"
