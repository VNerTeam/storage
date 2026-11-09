#!/usr/bin/env bash
# Giải nén mọi zip trong inbox/ (và ZIP_URL nếu có), tải từng video lên release.
set -euo pipefail

TAG="${RELEASE_TAG:-video-storage}"
BRANCH="${BRANCH:-main}"
MAX_BYTES=$((2 * 1024 * 1024 * 1024 - 1)) # giới hạn 2 GiB / file của GitHub release
EXT_RE='\.(mp4|m4v|mkv|webm|mov|avi|flv|wmv|mpg|mpeg|ts|3gp|ogv)$'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
declare -A used=()
declare -a zips=() del=() rows=()

if [[ -n "${ZIP_URL:-}" ]]; then
  [[ "$ZIP_URL" == https://* ]] || { echo "::error::ZIP_URL phải bắt đầu bằng https://"; exit 1; }
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 -o "$WORK/remote.zip" "$ZIP_URL"
  zips+=("$WORK/remote.zip")
fi
if [[ -d inbox ]]; then
  while IFS= read -r -d '' z; do zips+=("$z"); done < <(find inbox -maxdepth 1 -type f -iname '*.zip' -print0 | sort -z)
fi
if (( ${#zips[@]} == 0 )); then echo "Không có file zip nào để xử lý."; exit 0; fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --title "Video storage" --notes "Kho video tải lên từ file zip. Danh sách và nút copy link nằm ở trang /videos/."
fi
while IFS= read -r n; do
  if [[ -n "$n" ]]; then used["$n"]=1; fi
done < <(gh release view "$TAG" --json assets --jq '.assets[].name')

# Tên file an toàn cho URL, không trùng với file đã có trên release
make_name() {
  local base="$1" ext stem cand i=2
  base="$(printf '%s' "$base" | iconv -c -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$base")"
  ext=".${base##*.}"; ext="${ext,,}"
  stem="${base%.*}"
  stem="$(printf '%s' "$stem" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^[-.]+//; s/[-.]+$//')"
  if [[ -z "$stem" ]]; then stem="video"; fi
  stem="${stem:0:100}"
  cand="$stem$ext"
  while [[ -n "${used[$cand]:-}" ]]; do cand="$stem-$i$ext"; i=$((i + 1)); done
  used["$cand"]=1
  printf '%s' "$cand"
}

stage="$WORK/stage"; mkdir -p "$stage"
for z in "${zips[@]}"; do
  echo "::group::$z"
  zfail=0
  d="$WORK/x"; rm -rf "$d"; mkdir -p "$d"
  set +e; unzip -q -o "$z" -d "$d" -x '__MACOSX/*'; rc=$?; set -e
  if (( rc > 1 )); then
    echo "::error::Không giải nén được $z (zip hỏng hoặc có mật khẩu)"
    fail=1; echo "::endgroup::"; continue
  fi
  count=0
  while IFS= read -r -d '' f; do
    b="$(basename "$f")"
    if [[ "$b" == .* ]]; then continue; fi
    lower="${b,,}"
    if ! [[ "$lower" =~ $EXT_RE ]]; then echo "Bỏ qua (không phải video): $b"; continue; fi
    size="$(stat -c %s "$f")"
    if (( size > MAX_BYTES )); then echo "::warning::$b vượt 2 GiB, bỏ qua"; zfail=1; continue; fi
    name="$(make_name "$b")"
    mv "$f" "$stage/$name"
    ok=0
    for try in 1 2 3; do
      if gh release upload "$TAG" "$stage/$name" --clobber; then ok=1; break; fi
      echo "Tải lên lỗi (lần $try/3), thử lại..."; sleep $((try * 10))
    done
    rm -f "$stage/$name"
    if (( ok )); then
      echo "OK: $name"; count=$((count + 1))
      rows+=("| \`$name\` | $(numfmt --to=iec "$size") | https://github.com/$GH_REPO/releases/download/$TAG/$name |")
    else
      echo "::error::Không tải lên được $name"; zfail=1
    fi
  done < <(find "$d" -type f -print0 | sort -z)
  echo "Đã tải $count video từ $z"
  echo "::endgroup::"
  if (( zfail )); then fail=1; elif [[ "$z" == inbox/* ]]; then del+=("$z"); fi
done

if (( ${#rows[@]} )); then
  { echo "### Video đã tải lên"; echo; echo "| File | Dung lượng | Link tải |"; echo "|---|---|---|"; printf '%s\n' "${rows[@]}"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

# Xoá zip đã xử lý xong để repo không phình to và không bị xử lý lại
if (( ${#del[@]} )); then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git rm -q -- "${del[@]}"
  git commit -q -m "Đã tải lên release $TAG, xoá ${#del[@]} file zip khỏi inbox"
  for i in 1 2 3; do
    if git pull -q --rebase origin "$BRANCH" && git push -q origin "HEAD:$BRANCH"; then break; fi
    sleep 3
  done
fi
exit "$fail"
