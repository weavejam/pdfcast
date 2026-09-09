"""Register bundle ID com.weavejam.pdfcast + create ASC app record."""
import time, sys
import jwt, requests

KEY_PATH = "D:/AuthKey_KGURBMD94Y.p8"
KEY_ID = "KGURBMD94Y"
ISSUER = "45511867-c1d2-4ac4-82ff-e7e341c6501e"
BUNDLE_ID = "com.weavejam.pdfcast"
APP_NAME = "PDF投屏"
SKU = "pdfcast"
API = "https://api.appstoreconnect.apple.com/v1"


def token():
    key = open(KEY_PATH).read()
    return jwt.encode(
        {"iss": ISSUER, "iat": int(time.time()), "exp": int(time.time()) + 1000,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": KEY_ID})


H = {"Authorization": f"Bearer {token()}"}


def find_bundle_id():
    r = requests.get(f"{API}/bundleIds", headers=H,
                     params={"filter[identifier]": BUNDLE_ID, "limit": 5})
    r.raise_for_status()
    for d in r.json()["data"]:
        if d["attributes"]["identifier"] == BUNDLE_ID:
            return d["id"]
    return None


bid = find_bundle_id()
if bid:
    print(f"bundleId exists: {bid}")
else:
    r = requests.post(f"{API}/bundleIds", headers=H, json={
        "data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE_ID, "name": "pdfcast", "platform": "IOS"}}})
    if r.status_code >= 400:
        print("bundleIds POST failed:", r.status_code, r.text)
        sys.exit(1)
    bid = r.json()["data"]["id"]
    print(f"bundleId created: {bid}")

# list capabilities currently on the bundle id
r = requests.get(f"{API}/bundleIds/{bid}/bundleIdCapabilities", headers=H)
if r.ok:
    caps = [c["attributes"].get("capabilityType") for c in r.json()["data"]]
    print("capabilities:", caps)

# create app record (fastlane pilot upload prerequisite)
r = requests.get(f"{API}/apps", headers=H,
                 params={"filter[bundleId]": BUNDLE_ID, "limit": 5})
r.raise_for_status()
apps = r.json()["data"]
if apps:
    print(f"app exists: {apps[0]['id']} ({apps[0]['attributes']['name']})")
else:
    r = requests.post(f"{API}/apps", headers=H, json={
        "data": {"type": "apps", "attributes": {
            "bundleId": BUNDLE_ID, "name": APP_NAME, "primaryLocale": "zh-Hans",
            "sku": SKU}}})
    if r.status_code >= 400:
        print("apps POST failed:", r.status_code, r.text)
        sys.exit(1)
    print(f"app created: {r.json()['data']['id']}")
