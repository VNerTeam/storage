#!/usr/bin/env bash
# Giải nén mọi zip trong inbox/ (và ZIP_URL nếu có), tải từng video lên release.
# Release đầy (quá số file hoặc quá dung lượng) thì tự tạo release mới: video-storage, video-storage-002, ...
set -euo pipefail

PREFIX="video-storage"
BRANCH="${BRANCH:-main}"
MAX_ASSETS="${RELEASE_MAX_ASSETS:-900}"
MAX_BYTES=$(( ${RELEASE_MAX_GB:-2} * 1024 * 1024 * 1024 ))
FILE_MAX=$((2 * 1024 * 1024 * 1024 - 1)) # giới hạn 2 GiB / file của GitHub
EXT_RE='\.(mp4|m4v|mkv|webm|mov|avi|flv|wmv|mpg|mpeg|ts|3gp|ogv)$'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
declare -A used=() rel_count=() rel_bytes=()
declare -a zips=() del=() rows=()
cur=""; maxidx=0

if [[ -n "${ZIP_URL:-}" ]]; then
  [[ "$ZIP_URL" == https://* ]] || { echo "::error::ZIP_URL phải bắt đầu bằng https://"; exit 1; }
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 -o "$WORK/remote.zip" "$ZIP_URL"
  zips+=("$WORK/remote.zip")
fi
if [[ -d inbox ]]; then
  while IFS= read -r -d '' z; do zips+=("$z"); done < <(find inbox -maxdepth 1 -type f -iname '*.zip' -print0 | sort -z)
fi
if (( ${#zips[@]} == 0 )); then echo "Không có file zip nào để xử lý."; exit 0; fi

# Đọc các release đang có (video-storage, video-storage-002, ...)
while IFS= read -r tag; do
  [[ "$tag" =~ ^${PREFIX}(-([0-9]+))?$ ]] || continue
  idx=1; if [[ -n "${BASH_REMATCH[2]:-}" ]]; then idx=$((10#${BASH_REMATCH[2]})); fi
  (( idx > maxidx )) && maxidx=$idx
  id="$(gh api "repos/$GH_REPO/releases/tags/$tag" --jq .id)"
  c=0; b=0
  while IFS=$'\t' read -r n s; do
    if [[ -n "$n" ]]; then used["$n"]=1; c=$((c + 1)); b=$((b + s)); fi
  done < <(gh api --paginate "repos/$GH_REPO/releases/$id/assets?per_page=100" --jq '.[] | "\(.name)\t\(.size)"')
  rel_count["$tag"]=$c; rel_bytes["$tag"]=$b
  cur="$tag"  # release có số lớn nhất (danh sách sắp xếp bên dưới)
done < <(gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[].tag_name' | sort -V)

new_release() {
  local n=$((maxidx + 1)) tag
  if (( n == 1 )); then tag="$PREFIX"; else tag="$(printf '%s-%03d' "$PREFIX" "$n")"; fi
  gh release create "$tag" --title "Video storage #$n" --notes "Kho video tải lên từ file zip. Danh sách và nút copy link nằm ở trang /videos/."
  maxidx=$n; cur="$tag"; rel_count["$tag"]=0; rel_bytes["$tag"]=0
}
# Chọn release còn chỗ cho file có dung lượng $1
pick_release() {
  local s="$1" c b
  if [[ -n "$cur" ]]; then
    c="${rel_count[$cur]}"; b="${rel_bytes[$cur]}"
    if (( c < MAX_ASSETS )) && { (( c == 0 )) || (( b + s <= MAX_BYTES )); }; then return 0; fi
  fi
  new_release
}

# Tên file an toàn cho URL, không trùng với file đã có
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
    if (( size > FILE_MAX )); then echo "::warning::$b vượt 2 GiB, bỏ qua"; zfail=1; continue; fi
    name="$(make_name "$b")"
    pick_release "$size"
    tag="$cur"
    mv "$f" "$stage/$name"
    ok=0
    for try in 1 2 3; do
      if gh release upload "$tag" "$stage/$name" --clobber; then ok=1; break; fi
      echo "Tải lên lỗi (lần $try/3), thử lại..."; sleep $((try * 10))
    done
    rm -f "$stage/$name"
    if (( ok )); then
      echo "OK: $name → $tag"; count=$((count + 1))
      rel_count["$tag"]=$(( ${rel_count[$tag]} + 1 )); rel_bytes["$tag"]=$(( ${rel_bytes[$tag]} + size ))
      rows+=("| \`$name\` | $(numfmt --to=iec "$size") | https://github.com/$GH_REPO/releases/download/$tag/$name |")
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
  git commit -q -m "Đã tải video lên release, xoá ${#del[@]} file zip khỏi inbox"
  for i in 1 2 3; do
    if git pull -q --rebase origin "$BRANCH" && git push -q origin "HEAD:$BRANCH"; then break; fi
    sleep 3
  done
fi
exit "$fail"
