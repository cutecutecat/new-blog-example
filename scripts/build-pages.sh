#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/.site}"
SITE_KEY="${SITE_KEY:-all}"

GITHUB_REPOSITORY_VALUE="${GITHUB_REPOSITORY:-}"
if [[ -n "$GITHUB_REPOSITORY_VALUE" ]]; then
  DEFAULT_REPO_NAME="${GITHUB_REPOSITORY_VALUE##*/}"
else
  DEFAULT_REPO_NAME=""
fi

REPO_NAME="${REPO_NAME:-$DEFAULT_REPO_NAME}"
REPO_OWNER="${REPO_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
PROJECT_PAGES="${PROJECT_PAGES:-1}"

if [[ -n "${SITE_ORIGIN:-}" ]]; then
  SITE_ORIGIN="${SITE_ORIGIN%/}"
elif [[ -n "$REPO_OWNER" ]]; then
  SITE_ORIGIN="https://${REPO_OWNER}.github.io"
else
  SITE_ORIGIN="https://example.com"
fi

if [[ -n "${BASE_PREFIX:-}" ]]; then
  PUBLIC_BASE_PREFIX="$BASE_PREFIX"
elif [[ "$PROJECT_PAGES" == "1" && -n "$REPO_NAME" ]]; then
  PUBLIC_BASE_PREFIX="/$REPO_NAME"
else
  PUBLIC_BASE_PREFIX=""
fi

if [[ -n "$PUBLIC_BASE_PREFIX" ]]; then
  PUBLIC_BASE_PREFIX="/${PUBLIC_BASE_PREFIX#/}"
  PUBLIC_BASE_PREFIX="${PUBLIC_BASE_PREFIX%/}"
fi

FULL_SITE_PREFIX="${SITE_ORIGIN}${PUBLIC_BASE_PREFIX}"

echo "Building to: $OUT_DIR"
echo "Site origin: $SITE_ORIGIN"
echo "Public base prefix: ${PUBLIC_BASE_PREFIX:-/}"
echo "Site key: $SITE_KEY"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
touch "$OUT_DIR/.nojekyll"

build_hugo() {
  local source_dir="$1"
  local target_dir="$2"
  local base_url="${FULL_SITE_PREFIX}/${target_dir}/"
  hugo \
    --source "$ROOT_DIR/$source_dir" \
    --destination "$OUT_DIR/$target_dir" \
    --baseURL "$base_url"
}

build_astro() {
  local source_dir="$1"
  local target_dir="$2"
  local project_dir="$ROOT_DIR/$source_dir"
  local project_dist="$project_dir/dist"
  local final_out="$OUT_DIR/$target_dir"
  local base_path="${PUBLIC_BASE_PREFIX}/${target_dir}/"
  base_path="/${base_path#/}"
  base_path="${base_path//\/\//\/}"
  local site_url="${FULL_SITE_PREFIX}/${target_dir}/"

  rm -rf "$project_dir/.astro" "$project_dist" "$final_out"

  pnpm --dir "$project_dir" install --frozen-lockfile
  # NOTE(bug-workaround): Astro 6 may throw ENOENT in image optimization when
  # outDir points directly to a shared external folder (e.g. "$OUT_DIR/$target_dir"),
  # because it may still resolve intermediate assets from "$project_dir/.astro/_astro".
  # Build to the default project-local dist first, then copy to unified .site output.
  pnpm --dir "$project_dir" exec astro build \
    --site "$site_url" \
    --base "$base_path"

  mkdir -p "$final_out"
  cp -a "$project_dist/." "$final_out/"
}

build_site() {
  local site_key="$1"
  case "$site_key" in
    hugo-openai)
      build_hugo "hugo-examples/example-openai" "."
      ;;
    hugo-hashnode)
      build_hugo "hugo-examples/example-hashnode" "."
      ;;
    astro-openai)
      build_astro "astro-examples/example-openai" "."
      ;;
    astro-hashnode)
      build_astro "astro-examples/example-hashnode" "."
      ;;
    *)
      echo "Unsupported SITE_KEY: $site_key" >&2
      exit 1
      ;;
  esac
}

if [[ "$SITE_KEY" == "all" ]]; then
  build_hugo "hugo-examples/example-openai" "hugo-openai"
  build_hugo "hugo-examples/example-hashnode" "hugo-hashnode"
  build_astro "astro-examples/example-openai" "astro-openai"
  build_astro "astro-examples/example-hashnode" "astro-hashnode"

  cat > "$OUT_DIR/index.html" <<HTML
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Projects Portal</title>
  <style>
    :root { color-scheme: light; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(135deg, #f5f7fb, #eef2ff);
      min-height: 100vh;
      display: grid;
      place-items: center;
      color: #111827;
    }
    main {
      width: min(760px, 92vw);
      background: rgba(255, 255, 255, 0.86);
      border: 1px solid #e5e7eb;
      border-radius: 16px;
      padding: 28px;
      box-shadow: 0 10px 28px rgba(17, 24, 39, 0.08);
      backdrop-filter: blur(4px);
    }
    h1 { margin-top: 0; margin-bottom: 8px; font-size: 1.75rem; }
    p { margin-top: 0; color: #4b5563; }
    ul { list-style: none; margin: 18px 0 0; padding: 0; display: grid; gap: 10px; }
    a {
      display: block;
      text-decoration: none;
      color: #0f172a;
      border: 1px solid #d1d5db;
      border-radius: 10px;
      padding: 12px 14px;
      background: #fff;
    }
    a:hover { border-color: #3b82f6; box-shadow: 0 4px 16px rgba(59, 130, 246, 0.12); }
  </style>
</head>
<body>
  <main>
    <h1>Unified GitHub Pages</h1>
    <p>Four projects in one repository, published under one GitHub Pages site.</p>
    <ul>
      <li><a href="./hugo-openai/">Hugo - OpenAI Theme</a></li>
      <li><a href="./hugo-hashnode/">Hugo - Hashnode Theme</a></li>
      <li><a href="./astro-openai/">Astro - OpenAI Theme</a></li>
      <li><a href="./astro-hashnode/">Astro - Hashnode Theme</a></li>
    </ul>
  </main>
</body>
</html>
HTML
else
  build_site "$SITE_KEY"
fi

echo "Done. Output structure:"
find "$OUT_DIR" -maxdepth 2 -type d | sort
