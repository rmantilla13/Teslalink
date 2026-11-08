#!/usr/bin/env bash
# One-time Tesla Fleet API partner registration. Run from your computer, not the phone.
#
# Prerequisites:
#   - An app at https://developer.tesla.com (client id + secret)
#   - A domain you control, serving the public key generated below at:
#       https://$DOMAIN/.well-known/appspecific/com.tesla.3p.public-key.pem
#
# Usage: CLIENT_ID=... CLIENT_SECRET=... DOMAIN=example.com REGION=na ./scripts/register-partner.sh
set -euo pipefail

: "${CLIENT_ID:?set CLIENT_ID}"
: "${CLIENT_SECRET:?set CLIENT_SECRET}"
: "${DOMAIN:?set DOMAIN (no https://)}"
REGION="${REGION:-na}"   # na | eu | cn
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
echo "Done. You can now sign in from the app."
