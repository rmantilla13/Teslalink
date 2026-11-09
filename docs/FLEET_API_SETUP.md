# Tesla Fleet API setup

TeslaLink talks to Tesla's official **Fleet API**. The old "owner API" that TeslaMate
originally used is being shut down for third parties, so a personal developer app is needed.
This is a one-time setup and needs no server afterwards.

## 1. Create a developer app

1. Sign in at <https://developer.tesla.com> and create an application.
2. **Scopes:** *Vehicle Information* and *Vehicle Location*. TeslaLink is read-only, so
   command scopes are not needed.
3. **Allowed origin:** your domain, e.g. `https://example.com`.
4. **Redirect URI:** one of
   - `teslalink://auth/callback` (custom URL scheme, already registered in `Info.plist`), or
   - `https://example.com/teslalink/callback`. This needs an Associated Domains entitlement
     (`webcredentials:example.com`) and an `apple-app-site-association` file on the domain.
     Use this if the portal won't accept a custom scheme.
5. Note the **client ID** and **client secret**.

## 2. Register as a partner (once per region)

Tesla requires a public key hosted on your domain, even for read-only apps. Any static
hosting works (GitHub Pages, Cloudflare Pages, Netlify).

```bash
CLIENT_ID=... CLIENT_SECRET=... DOMAIN=example.com REGION=na ./scripts/register-partner.sh
```

The script generates the key pair, waits while you upload
`com.tesla.3p.public-key.pem` to `https://example.com/.well-known/appspecific/`, then
registers the domain. Keep `private-key.pem` out of git. It's only needed if you add
vehicle commands later.

## 3. Configure the app

The app walks you through steps 1 to 3: on the welcome screen, **Connect Tesla account**
opens the setup when there's no developer app yet (later: **Settings → Advanced → Tesla
developer app**). The quickest way to fill it in is the setup link the partner script prints
at the end:

```bash
# already registered? print just the link (and a QR code with `brew install qrencode`)
CLIENT_ID=... CLIENT_SECRET=... REGION=na LINK_ONLY=1 ./scripts/register-partner.sh
```

Scan the QR code with the iPhone's camera, or copy the `teslalink://setup?…` link into the
setup screen's **Paste** button. The app shows what the link would change and asks before
saving anything. It warns loudly when a link would send Tesla's sign-in anywhere but back to
the app (`teslalink://auth/callback`), because whoever runs that address would receive your
sign-in code. You can also type the client ID, secret and redirect URI in the same screen.

The client secret is kept in the Keychain on the phone. Or build the developer app in:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # git-ignored
# fill in bundle id, team id, client id/secret, redirect URI
xcodegen && open TeslaLink.xcodeproj
```

> **About the client secret.** Tesla's code exchange requires it, and anything compiled
> into an app, typed into it or carried by a setup link can be extracted. That's fine for a
> personal build on your own phone. Don't distribute a build that contains it, and don't
> share the setup link or its QR code. A public release needs a tiny token exchange endpoint
> instead, which is the one piece of "external stuff" you can't avoid.

### Linking Tesla accounts

After setup, **Connect Tesla account** opens Tesla's sign-in and comes straight back with the
account's cars. Add more under **Settings → Tesla accounts → Add Tesla account**: Tesla's page
opens without remembering the previous sign-in, so a second person can use their own
details. Every account signs in through the same developer app. A car shared between two
accounts (a second driver's) is logged once, by the account linked first. Disconnecting an
account stops its cars updating; their history stays on the phone.

**Regions.** Tesla keeps every account in one region: North America with Asia-Pacific,
Europe with the Middle East and Africa, or China. The app starts from the phone's country
(changeable under the Connect button). If Tesla's token says the account lives elsewhere,
the app asks you to sign in once more there. Register the partner domain (step 2) in every
region your accounts use; an account in an unregistered region shows that in Settings.

**Not yet verified against a real account:** the app reads the region (`ou_code`) and user
(`sub`) from Tesla's token, and treats HTTP 412 as "partner not registered in this region".
Tesla doesn't document these, so they're read defensively: when a claim is missing, the app
uses the region you picked and tells accounts apart by their cars.

## 4. Costs

Tesla bills Fleet API usage per request: data requests, wake-ups and commands are priced
separately. Personal accounts have usually been covered by a monthly credit, but check
current pricing on developer.tesla.com. TeslaLink keeps the bill down by:

- checking a sleeping car with the non-waking `GET /vehicles/{vin}` instead of `vehicle_data`,
- never sending `wake_up`,
- polling slower than TeslaMate while driving (10 s instead of 2.5 s) and using phone GPS for the track,
- leaving the car alone after 15 idle minutes so it can sleep.

All intervals can be changed in **Settings → Polling**.
