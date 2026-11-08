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

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # git-ignored
# fill in bundle id, team id, client id/secret, redirect URI
xcodegen && open TeslaLink.xcodeproj
```

You can also leave these empty and type them into **Settings → Advanced → Developer app**
on the device.

> **About the client secret.** Tesla's code exchange requires it, and anything compiled
> into an app can be extracted. That's fine for a personal build installed on your own
> phone. Don't distribute a build that contains it. A public release needs a tiny token
> exchange endpoint instead, which is the one piece of "external stuff" you can't avoid.

## 4. Costs

Tesla bills Fleet API usage per request: data requests, wake-ups and commands are priced
separately. Personal accounts have usually been covered by a monthly credit, but check
current pricing on developer.tesla.com. TeslaLink keeps the bill down by:

- checking a sleeping car with the non-waking `GET /vehicles/{vin}` instead of `vehicle_data`,
- never sending `wake_up`,
- polling slower than TeslaMate while driving (10 s instead of 2.5 s) and using phone GPS for the track,
- leaving the car alone after 15 idle minutes so it can sleep.

All intervals can be changed in **Settings → Polling**.
