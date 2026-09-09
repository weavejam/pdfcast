"""CI helper: force-refresh Xcode-managed provisioning profiles for pdfcast.

给 App ID 新增 capability（例如 App Groups）后，App Store Connect 上原有的
"iOS Team Provisioning Profile: <bundleid>" 仍然有效但不含新 entitlement。
云托管签名（xcodebuild -allowProvisioningUpdates）在全新 runner 上会直接下载复用
这个旧 profile，而不是重建，于是报：
  Provisioning profile "..." doesn't match the entitlements file's value for the
  com.apple.security.application-groups entitlement.

构建前运行本脚本，把 pdfcast 相关的托管 profile 从账号里清掉，逼签名流程重新生成
一份包含 App Group 的新 profile。

用法（CI 里已把 p8 写到 ~/private_keys）：
  python ci_reset_managed_profiles.py <KEY_ID> <ISSUER_ID> <BUNDLE_PREFIX>
"""
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"


def main():
    key_id, issuer, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
    key = open(os.path.expanduser(f"~/private_keys/AuthKey_{key_id}.p8")).read()
    token = jwt.encode(
        {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 1000,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id})
    h = {"Authorization": f"Bearer {token}"}
    resp = requests.get(f"{API}/profiles", headers=h, params={"limit": 200})
    resp.raise_for_status()
    removed = 0
    for p in resp.json()["data"]:
        name = p["attributes"]["name"]
        if prefix in name:
            d = requests.delete(f"{API}/profiles/{p['id']}", headers=h)
            print("reset managed profile", name, d.status_code)
            removed += 1
    print(f"{removed} managed profile(s) reset for prefix {prefix}")


if __name__ == "__main__":
    main()
