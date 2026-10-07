#!/bin/bash
# 发布 release.sh 已经打好的版本：GitHub Release、quota.bar 服务器副本、
# Homebrew tap、两个网站（旁边的 quota.bar、quota.run 仓库），一次做完。
#
#   ./Scripts/publish_release.sh                    # 版本号取 Info.plist
#   STEPS="mirror" ./Scripts/publish_release.sh     # 只重传服务器副本
#   NOTES=notes.md ./Scripts/publish_release.sh     # 自己写的发布说明
#
# 服务器副本是给打不开或下不动 GitHub 的网络用的：官网的下载按钮直接指向它，
# 应用内更新在 GitHub 连不上时也改从这里取（download/latest.json）。
#
# 前提：CHANGELOG.md 里已有「## <版本> · <日期>」，v<版本> 的 tag 已推送。
#
# 测试版：Info.plist 的版本号带后缀（0.5.28-beta.1）就是测试版。先发测试版，
# 没有问题再发正式版，免得一天给所有人推好几次更新。测试版只发到 GitHub，
# 标成预发布：只有打开了「设置 → 更新 → 测试版更新」的人会收到。
# latest.json、Homebrew 和两个网站都不动，其他人看不到。更新日志不写测试版
# 的标题，改动留在「## 未发布」里，发布说明就取那一节；正式版发布时再把
# 「未发布」改成「## <版本> · <日期>」。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-QuotaBar/QuotaBar}"
TAP="${TAP:-gentpan/homebrew-tap}"
HOST="${SITE_HOST:-root@15.204.80.137}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
ROOT="${SITE_ROOT:-/var/www/quota.bar}"
DIST="${DIST:-dist}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BETA=0
[[ "$VERSION" == *-* ]] && BETA=1
if [ "$BETA" = 1 ]; then
  STEPS="${STEPS:-github}"
else
  STEPS="${STEPS:-github mirror tap site}"
fi
ZIP="$DIST/QuotaBar-$VERSION.zip"
DMG="$DIST/QuotaBar-$VERSION.dmg"
# 官网两个下载按钮用的单一架构安装包，release_thin.sh 打的。
DMG_ARM="$DIST/QuotaBar-$VERSION-apple-silicon.dmg"
DMG_INTEL="$DIST/QuotaBar-$VERSION-intel.dmg"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

die() { echo "error: $*" >&2; exit 1; }
has_step() { [[ " $STEPS " == *" $1 "* ]]; }

if [ "$BETA" = 1 ]; then
  for step in mirror tap site; do
    has_step "$step" && die "$VERSION 是测试版，只发 GitHub 预发布；$step 会让所有人看到它"
  done
fi

[ -f "$ZIP" ] && [ -f "$DMG" ] || die "$DIST 里没有 $VERSION 的 zip 和 dmg，先跑 ./Scripts/release.sh"
[ -f "$DMG_ARM" ] && [ -f "$DMG_INTEL" ] || die "$DIST 里没有 $VERSION 的 Apple 芯片版和 Intel 版 dmg，先跑 ./Scripts/release_thin.sh"
if [ "$BETA" = 1 ]; then
  grep -q "^## 未发布" CHANGELOG.md || die "测试版的发布说明取 CHANGELOG.md 的「## 未发布」，那里还是空的"
else
  grep -q "^## $VERSION " CHANGELOG.md || die "CHANGELOG.md 里还没有「## $VERSION · 日期」，版本还没定稿"
fi
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "没有 v$VERSION 的 tag"
ZIP_SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
ARM_SHA="$(shasum -a 256 "$DMG_ARM" | cut -d' ' -f1)"
INTEL_SHA="$(shasum -a 256 "$DMG_INTEL" | cut -d' ' -f1)"

# 发布说明默认取两份更新日志里这个版本的那一节，英文在前。
# 测试版取「未发布」那一节，前面说明是测试版。
release_notes() {
  python3 - "$VERSION" "$BETA" <<'PY'
import pathlib, re, sys
version, beta = sys.argv[1], sys.argv[2] == "1"
def section(path, heading):
    # heading 是正则：版本号带空格，或「未发布」整行。
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    m = re.search(rf"^## {heading}.*?$(.*?)(?=^## |\Z)", p.read_text(encoding="utf-8"), re.M | re.S)
    return m.group(1).strip() if m else ""
if beta:
    en = section("CHANGELOG.en.md", "Unreleased$")
    zh = section("CHANGELOG.md", "未发布$")
    en = "Beta: only offered with Settings → Updates → Beta updates turned on.\n\n" + en if en else en
    zh = "测试版：只推送给打开了「设置 → 更新 → 测试版更新」的用户。\n\n" + zh if zh else zh
else:
    en, zh = section("CHANGELOG.en.md", re.escape(version) + " "), section("CHANGELOG.md", re.escape(version) + " ")
parts = [s for s in (en, zh) if s]
print("\n\n---\n\n".join(parts))
PY
}

if has_step github; then
  echo "── GitHub Release"
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "  v$VERSION 已存在，跳过"
  else
    notes="${NOTES:-$(mktemp)}"
    [ -n "${NOTES:-}" ] || release_notes > "$notes"
    prerelease=()
    [ "$BETA" = 1 ] && prerelease=(--prerelease --latest=false)
    gh release create "v$VERSION" "$ZIP" "$DMG" "$DMG_ARM" "$DMG_INTEL" --repo "$REPO" \
      --title "QuotaBar $VERSION" --notes-file "$notes" --verify-tag ${prerelease[@]+"${prerelease[@]}"}
  fi
fi

if has_step mirror; then
  echo "── 服务器副本 https://quota.bar/download/"
  "${SSH[@]}" "mkdir -p $ROOT/download"
  # 先传成 .part 再改名：下载到一半的人拿不到半截文件。
  for f in "$ZIP" "$DMG" "$DMG_ARM" "$DMG_INTEL"; do
    name="$(basename "$f")"
    scp -q -i "$KEY" -o BatchMode=yes "$f" "$HOST:$ROOT/download/$name.part"
    "${SSH[@]}" "mv $ROOT/download/$name.part $ROOT/download/$name"
  done
  latest="$(mktemp)"
  notes_file="$(mktemp)"
  if [ -n "${NOTES:-}" ]; then cp "$NOTES" "$notes_file"; else release_notes > "$notes_file"; fi
  python3 - "$VERSION" "$ZIP_SHA" "$DMG_SHA" "$REPO" "$notes_file" "$ARM_SHA" "$INTEL_SHA" > "$latest" <<'PY'
import datetime, json, sys
version, zip_sha, dmg_sha, repo, notes_file, arm_sha, intel_sha = sys.argv[1:8]
base = "https://quota.bar/download"
print(json.dumps({
    "version": version,
    "url": f"{base}/QuotaBar-{version}.zip",
    "sha256": zip_sha,
    "dmg": f"{base}/QuotaBar-{version}.dmg",
    "dmgSha256": dmg_sha,
    "dmgAppleSilicon": f"{base}/QuotaBar-{version}-apple-silicon.dmg",
    "dmgAppleSiliconSha256": arm_sha,
    "dmgIntel": f"{base}/QuotaBar-{version}-intel.dmg",
    "dmgIntelSha256": intel_sha,
    "page": "https://quota.bar/changelog.html",
    "github": f"https://github.com/{repo}/releases/tag/v{version}",
    # 应用内的更新卡片读这里的摘要：英文一节、---、中文一节，和 GitHub 发布说明相同。
    "notes": open(notes_file, encoding="utf-8").read(),
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PY
  scp -q -i "$KEY" -o BatchMode=yes "$latest" "$HOST:$ROOT/download/latest.json"
  "${SSH[@]}" "chown -R www-data:www-data $ROOT/download && chmod 644 $ROOT/download/*"

  # 核对公网上拿到的，而不是服务器上放着的：中间隔着 Cloudflare。
  remote="$("${SSH[@]}" "cd $ROOT/download && sha256sum QuotaBar-$VERSION.zip QuotaBar-$VERSION.dmg QuotaBar-$VERSION-apple-silicon.dmg QuotaBar-$VERSION-intel.dmg" | cut -d' ' -f1 | tr '\n' ' ')"
  [ "$remote" = "$ZIP_SHA $DMG_SHA $ARM_SHA $INTEL_SHA " ] || die "服务器上的文件校验值不对：$remote"
  for f in "$ZIP" "$DMG" "$DMG_ARM" "$DMG_INTEL"; do
    name="$(basename "$f")"
    want="$(stat -f%z "$f")"
    got="$(curl -sI --max-time 30 "https://quota.bar/download/$name" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
    [ "$want" = "$got" ] || die "https://quota.bar/download/$name 线上大小 ${got:-无} ≠ 本地 $want"
    printf "  ✅ %-22s %s B\n" "$name" "$got"
  done
  curl -s --max-time 20 "https://quota.bar/download/latest.json" | grep -q "\"version\": \"$VERSION\"" \
    && echo "  ✅ latest.json          $VERSION" || die "latest.json 线上不是 $VERSION"
fi

if has_step tap; then
  echo "── Homebrew tap"
  work="$(mktemp -d)"
  gh repo clone "$TAP" "$work" -- -q
  cp "$DIST/quotabar.rb" "$work/Casks/quotabar.rb"
  if git -C "$work" diff --quiet; then
    echo "  cask 已是 $VERSION，跳过"
  else
    git -C "$work" add Casks/quotabar.rb
    git -C "$work" commit -q -m "quotabar $VERSION"
    git -C "$work" push -q origin HEAD
    echo "  ✅ $(git -C "$work" log --oneline -1)"
  fi
  rm -rf "$work"
fi

# 两个网站是旁边的独立仓库：quota.bar 首页的版本号、下载链接和更新日志，quota.run 页脚的下载链接，
# 都从本仓库生成，所以发版后两个站都要重新部署。
if has_step site; then
  for site in ${SITES:-../quota.bar ../quota.run}; do
    [ -x "$site/Scripts/deploy_site.sh" ] || die "找不到 $site/Scripts/deploy_site.sh：网站仓库应放在本仓库旁边，或用 SITES 指定"
    echo "── 网站 $(basename "$site")"
    "$site/Scripts/deploy_site.sh"
  done
fi
