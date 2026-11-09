#!/usr/bin/env bash
# One-time Tesla Fleet API partner registration. Run from your computer, not the phone.
#
# Prerequisites:
#   - An app at https://developer.tesla.com (client id + secret)
#   - A domain you control, serving the public key generated below at:
#       https://$DOMAIN/.well-known/appspecific/com.tesla.3p.public-key.pem
#
# Usage: CLIENT_ID=... CLIENT_SECRET=... DOMAIN=example.com REGION=na ./scripts/register-partner.sh
#
# It ends by printing a teslalink://setup link (and a QR code, with `brew install qrencode`)
# that fills in the app's developer app details on the phone. Already registered? Print just
# the link with LINK_ONLY=1 (DOMAIN isn't needed then). REDIRECT_URI defaults to the app's own.
set -euo pipefail

: "${CLIENT_ID:?set CLIENT_ID}"
: "${CLIENT_SECRET:?set CLIENT_SECRET}"
REGION="${REGION:-na}"   # na | eu | cn
REDIRECT_URI="${REDIRECT_URI:-teslalink://auth/callback}"

print_setup_link() {
  local link
  link=$(python3 -I -c 'import sys, urllib.parse as u
q = lambda s: u.quote(s, safe="")
print("teslalink://setup?client_id=%s&client_secret=%s&redirect_uri=%s&region=%s" % tuple(q(a) for a in sys.argv[1:5]))' \
    "$CLIENT_ID" "$CLIENT_SECRET" "$REDIRECT_URI" "$REGION")
  echo
  echo "Setup link for the phone. It contains your client secret: don't post or share it."
  echo "$link"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$link"
    echo "Scan it with the iPhone's camera, or copy the link into TeslaLink's setup (Paste)."
  else
    echo "(brew install qrencode to also get a QR code to scan.) Copy the link into TeslaLink's setup (Paste)."
  fi
}

if [[ "${LINK_ONLY:-}" == "1" ]]; then
  print_setup_link
  exit 0
fi

: "${DOMAIN:?set DOMAIN (no https://)}"
case "$REGION" in
  na) API="https://fleet-api.prd.na.vn.cloud.tesla.com" ;;
  eu) API="https://fleet-api.prd.eu.vn.cloud.tesla.com" ;;
  cn) API="https://fleet-api.prd.cn.vn.cloud.tesla.cn" ;;
  *) echo "REGION must be na, eu or cn" >&2; exit 1 ;;
esac

if [[ ! -f private-key.pem ]]; then
  echo "Generating prime256v1 key pair (keep private-key.pem secret and out of git)..."
  openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem
  openssl ec -in private-key.pem -pubout -out com.tesla.3p.public-key.pem
  echo "Upload com.tesla.3p.public-key.pem to https://$DOMAIN/.well-known/appspecific/com.tesla.3p.public-key.pem"
  read -r -p "Press Enter once it is reachable... "
fi

echo "Requesting partner token..."
TOKEN=$(curl -sS --fail -X POST https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode 'scope=openid vehicle_device_data vehicle_location' \
  --data-urlencode "audience=$API" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

echo "Registering $DOMAIN in region $REGION..."
curl -sS --fail -X POST "$API/api/1/partner_accounts" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"domain\": \"$DOMAIN\"}"
echo
echo "Registered."
print_setup_link
