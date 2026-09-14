#!/usr/bin/env bash
#
# scripts/report_version.sh
# ────────────────────────────
# Run this right after cutting a real build (`flutter build apk --release`,
# `flutter build ipa`, ...) — reads this app's OWN version straight out of
# pubspec.yaml and reports it to the server, so the "Currently Published
# Version" shown on the web app's App Update admin page
# (client/src/Components/Common/AppUpdateModeCard.jsx) reflects what you
# actually just built, not something typed by hand and left stale.
#
# This does NOT set the minimum required version and does NOT turn Force
# Update on — that's still a deliberate admin decision made separately on
# the web page, once you've decided this new build is safe to require.
#
# Usage:
#   ./scripts/report_version.sh
#   RELEASE_SERVER_URL=https://audit.hqepl.com/api/v1 ./scripts/report_version.sh   # production
#   ./scripts/report_version.sh --url https://audit.hqepl.com/api/v1 --secret xxxx
#
# Needs the same secret as the server's APP_UPDATE_REPORT_SECRET (server/.env)
# — set it via RELEASE_SECRET env var or --secret, never commit a real one here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBSPEC="$SCRIPT_DIR/../pubspec.yaml"

# Matches the current dev API base in lib/core/constants/api_constants.dart
# — override with --url or RELEASE_SERVER_URL for a production release.
SERVER_URL="${RELEASE_SERVER_URL:-https://devaudit.hqepl.com/api/v1}"
SECRET="${RELEASE_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) SERVER_URL="$2"; shift 2 ;;
    --secret) SECRET="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SECRET" ]]; then
  echo "Error: no release secret given. Pass --secret <value> or set RELEASE_SECRET." >&2
  exit 1
fi

if [[ ! -f "$PUBSPEC" ]]; then
  echo "Error: pubspec.yaml not found at $PUBSPEC" >&2
  exit 1
fi

# pubspec.yaml's version line looks like "version: 1.1.2+7" — take just the
# "1.1.2" part; the server only ever compares major.minor.patch(.build),
# never the Android-only build-number suffix.
RAW_VERSION="$(grep -E '^version:' "$PUBSPEC" | head -1 | sed -E 's/^version:[[:space:]]*//')"
VERSION="${RAW_VERSION%%+*}"

if [[ -z "$VERSION" ]]; then
  echo "Error: could not find a 'version:' line in $PUBSPEC" >&2
  exit 1
fi

echo "Reporting version $VERSION (from $RAW_VERSION) to $SERVER_URL ..."

HTTP_STATUS="$(curl -s -o /tmp/report_version_response.json -w "%{http_code}" \
  -X POST "$SERVER_URL/app-update/report-version" \
  -H "Content-Type: application/json" \
  -H "x-release-secret: $SECRET" \
  -d "{\"version\": \"$VERSION\"}")"

BODY="$(cat /tmp/report_version_response.json)"
rm -f /tmp/report_version_response.json

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
  echo "✅ Reported version $VERSION successfully."
  echo "$BODY"
else
  echo "❌ Failed to report version (HTTP $HTTP_STATUS):" >&2
  echo "$BODY" >&2
  exit 1
fi
