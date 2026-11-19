#!/usr/bin/env bash
# Saves live responses from the site (status + body) for checking the app's parsers. Read-only GETs, like a browser.
set -u
OUT=${1:-out}; mkdir -p "$OUT"
SITE=https://www.farmatotal.com.py
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
JAR="$OUT/cookies.txt"

get() {  # get <name> <url>
  curl -sS -L -A "$UA" -b "$JAR" -c "$JAR" -o "$OUT/$1" -D "$OUT/$1.headers" -w "%{http_code}  $2\n" "$2" >> "$OUT/status.txt" 2>&1
}

get products.json  "$SITE/?rest_route=/wc/store/v1/products&per_page=3&on_sale=true"
get categories.json "$SITE/?rest_route=/wc/store/v1/products/categories"
get cart.json      "$SITE/?rest_route=/wc/store/v1/cart"
get home.html      "$SITE/rastrear-pedido/"
get sucursales.html "$SITE/sucursales/"

# Scripts of the branch popup and store locator: they show how each plugin loads and selects branches.
for f in $(grep -oE "$SITE/wp-content/(plugins|themes)/[^\"' ]*(multi-inventory|agile-store|stock-validation|custom-scripts)[^\"' ]*\.js[^\"' ]*" \
             "$OUT/home.html" "$OUT/sucursales.html" 2>/dev/null | sed 's/^[^:]*://' | sort -u); do
  get "js-$(basename "${f%%\?*}")" "$f"
done

# Store locator list, as its script requests it (nonce from the page).
NONCE=$(grep -oE 'ASL_REMOTE=\{[^}]*"nonce":"[0-9a-f]+"' "$OUT/sucursales.html" | grep -oE '[0-9a-f]{6,}"$' | tr -d '"')
echo "asl nonce: ${NONCE:-none}" >> "$OUT/status.txt"
get asl_stores.json "$SITE/wp-admin/admin-ajax.php?action=asl_load_stores&nonce=$NONCE&load_all=1&layout=1"

cat "$OUT/status.txt"
