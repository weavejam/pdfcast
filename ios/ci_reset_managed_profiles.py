"""CI helper: diagnose + refresh signing assets for pdfcast App Groups.

给 App ID 新增 capability（例如 App Groups）后，云托管签名 archive 会报：
  Provisioning profile "..." doesn't match the entitlements file's value for the
  com.apple.security.application-groups entitlement.

本脚本用 CI 的 ASC key（唯一能访问 QTKH7M6UMC 团队）：
  1) 打印账号里所有 profile（名字/类型/状态）——确认托管 profile 是否真的存在于 ASC；
  2) 打印两个 bundleId 的 capabilities 以及 App Groups 关系里实际挂着的 group——
     这是 profile 生成器看到的“真相”，用来判断门户上的分配是否真同步到了 API；
  3) 删除名字里含 bundle 前缀的 profile（若有），逼签名重建。

用法：python ci_reset_managed_profiles.py <KEY_ID> <ISSUER_ID> <BUNDLE_PREFIX>
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

    # 1) 所有 profile
    resp = requests.get(f"{API}/profiles", headers=h, params={"limit": 200})
    resp.raise_for_status()
    profs = resp.json()["data"]
    print(f"--- {len(profs)} profile(s) in account ---")
    for p in profs:
        a = p["attributes"]
        print(f"  [{a.get('profileType')}] {a.get('profileState')}  {a['name']}  ({p['id']})")

    # 2) 两个 bundleId 的 capabilities + app groups
    for ident in ("com.weavejam.pdfcast", "com.weavejam.pdfcast.share"):
        b = requests.get(f"{API}/bundleIds", headers=h,
                         params={"filter[identifier]": ident, "limit": 5,
                                 "include": "bundleIdCapabilities"})
        b.raise_for_status()
        data = b.json()["data"]
        if not data:
            print(f"--- {ident}: NOT FOUND ---")
            continue
        bid = data[0]["id"]
        caps = requests.get(f"{API}/bundleIds/{bid}/bundleIdCapabilities", headers=h)
        caps.raise_for_status()
        types = [c["attributes"].get("capabilityType") for c in caps.json()["data"]]
        print(f"--- {ident} ({bid}) capabilities: {types} ---")
        # App Groups 关系（appGroups 是 bundleId 的关联资源）
        try:
            ag = requests.get(f"{API}/bundleIds/{bid}/appGroups", headers=h)
            if ag.status_code < 400:
                names = [g["attributes"].get("identifier") for g in ag.json().get("data", [])]
                print(f"    assigned appGroups: {names}")
            else:
                print(f"    appGroups query -> {ag.status_code} {ag.text[:200]}")
        except Exception as e:  # noqa: BLE001
            print(f"    appGroups query error: {e}")

    # 3) 删掉含前缀的 profile（若有）
    removed = 0
    for p in profs:
        if prefix in p["attributes"]["name"]:
            d = requests.delete(f"{API}/profiles/{p['id']}", headers=h)
            print("reset managed profile", p["attributes"]["name"], d.status_code)
            removed += 1
    print(f"{removed} managed profile(s) reset for prefix {prefix}")


if __name__ == "__main__":
    main()
