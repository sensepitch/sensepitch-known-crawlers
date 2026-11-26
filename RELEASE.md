# Publish the tier ZIPs to GitHub

Run these commands in Bash from the repository root. Use a clean checkout of `main` at the commit you want to publish, already pushed to GitHub. You need Python 3 with PyYAML, `jq`, `sha256sum`, and an authenticated GitHub CLI with write access to the repository.

## Build and identify the snapshot

Run the code blocks in order in the same shell. If a check fails, resolve it before moving on.

```bash
set -euo pipefail
repo=sensepitch/sensepitch-known-crawlers
sha=$(git rev-parse HEAD)
tag=$(git show -s --format=%cd --date=format:%Y.%m.%d.%H "$sha")
assets=(output/sensepitch-known-crawlers-tier{1,2,3}.zip)

test -z "$(git status --porcelain)"
test "$(gh api "repos/$repo/branches/main" --jq .commit.sha)" = "$sha"
bash release.sh
printf 'Release %s targets %s\n' "$tag" "$sha"
```

The tag uses the committer timestamp in the commit's recorded time zone. For example, `2026-11-26T19:46:48+08:00` yields `2026.11.26.19`.

## Upload the draft

Check for an existing release with `gh release view "$tag" --repo "$repo"`. If it finds a draft for the same commit, resume it as described below. If a release is already published or the tag exists separately, inspect it and stop. Two commits in the same recorded hour can produce the same tag.

```bash
refs=$(gh api "repos/$repo/git/matching-refs/tags/$tag")
jq -e --arg ref "refs/tags/$tag" 'all(.[]; .ref != $ref)' <<< "$refs"

gh release create "$tag" "${assets[@]}" --repo "$repo" --target "$sha" \
  --title "Crawler IP lists $tag" \
  --notes 'Crawler and service IP lists packaged as three tier ZIPs for edge proxies.' \
  --draft
```

If the upload was interrupted, use `gh release view "$tag" --repo "$repo" --json isDraft,targetCommitish,assets` to confirm the draft targets `$sha` and identify missing assets. Upload each missing ZIP with `gh release upload "$tag" "output/<filename>" --repo "$repo"`, substituting its filename. If an uploaded ZIP has the wrong digest, replace that asset in the confirmed draft with the same command and `--clobber`, then recheck all three.

## Verify and publish

Compare GitHub's asset digests with the local ZIPs. Keep the release in draft until every check passes.

```bash
draft=$(gh release view "$tag" --repo "$repo" --json databaseId,isDraft,targetCommitish)
release_id=$(jq -er --arg sha "$sha" \
  'select(.isDraft and .targetCommitish == $sha) | .databaseId' <<< "$draft")
uploaded=$(gh api "repos/$repo/releases/$release_id/assets")
test "$(jq length <<< "$uploaded")" = "${#assets[@]}"

for file in "${assets[@]}"; do
  digest=$(jq -er --arg name "${file##*/}" \
    '.[] | select(.name == $name and .state == "uploaded") | .digest' <<< "$uploaded")
  local_digest=$(sha256sum "$file")
  test "$digest" = "sha256:${local_digest%% *}"
done

gh release edit "$tag" --repo "$repo" --draft=false --latest
```

Confirm the published tag, download the three assets into a temporary directory, and compare them with the originals.

```bash
test "$(gh api "repos/$repo/git/ref/tags/$tag" --jq .object.sha)" = "$sha"
(
  downloads=$(mktemp -d)
  trap 'rm -r -- "$downloads"' EXIT
  gh release download "$tag" --repo "$repo" --dir "$downloads" \
    --pattern 'sensepitch-known-crawlers-tier[123].zip'
  for file in "${assets[@]}"; do
    cmp "$file" "$downloads/${file##*/}"
  done
)
gh release view "$tag" --repo "$repo" --json url --jq .url
```
