#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 update.json 生成 ECDSA-P256 签名（C-2 信任锚）。

用法：
    python3 _sign_update.py [update.json 路径] [私钥 PEM 路径]

约定：
- 私钥默认读取环境变量 `YOUTIAO_SIGN_KEY`；未设置时回退到
  `E:/WorkBuddy/6/youtiao-release-keys/update_sign_key.pem`（与 release jks 同目录的
  本地安全位置，**绝不**提交进仓库，仅存在于发版机 / CI 密钥里）。
- 签名对象：update.json 解析为对象后「剔除 signature 字段」，再按
  `json.dumps(obj, sort_keys=True, separators=(',',':'), ensure_ascii=False)`
  规范化为字节 —— 与 App 端 `_canonicalJson` 严格对齐。
- 签名算法：ECDSA over SHA-256；Dart 端 `ECDSASigner(SHA256Digest())` 会自动对消息做 SHA-256，
  故此处用 `ec.ECDSA(hashes.SHA256())` 一致。
- 签名值取原始 (r || s) 各 32 字节大端，base64 后写入 `signature` 字段，回写 update.json。

App 端（lib/services/update_checker.dart）会在拉到清单后，若含 `signature` 则强校验，
校验失败直接拒收，从而闭环「Gitee/TLS 被攻破也无法投毒」的信任链。

依赖：pip install cryptography
"""
import base64
import json
import os
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

DEFAULT_JSON = Path(__file__).resolve().parent / "update.json"
# 私钥「绝不」进仓库：默认指向与 release jks 同目录的本地安全位置，
# 也可用环境变量 YOUTIAO_SIGN_KEY 覆盖（CI / 换机时）。仓库内不应存在该文件。
DEFAULT_KEY = Path(
    os.environ.get(
        "YOUTIAO_SIGN_KEY",
        "E:/WorkBuddy/6/youtiao-release-keys/update_sign_key.pem",
    )
)


def canonical_bytes(obj: dict) -> bytes:
    """与 App 端 _canonicalJson 对齐的规范化字节。"""
    signable = {k: v for k, v in obj.items() if k != "signature"}
    return json.dumps(
        signable, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def main() -> int:
    json_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_JSON
    key_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_KEY

    if not json_path.exists():
        print(f"[sign] 未找到清单：{json_path}", file=sys.stderr)
        return 1
    if not key_path.exists():
        print(
            f"[sign] 未找到私钥：{key_path}\n"
            f"       请先用 `openssl ecparam -name prime256v1 -genkey -noout -out {key_path}` 生成，"
            f"并妥善保管、切勿提交。",
            file=sys.stderr,
        )
        return 1

    obj = json.loads(json_path.read_text(encoding="utf-8"))
    payload = canonical_bytes(obj)

    private_key = serialization.load_pem_private_key(
        key_path.read_bytes(), password=None
    )
    if not isinstance(private_key, ec.EllipticCurvePrivateKey):
        print("[sign] 私钥不是 EC 私钥", file=sys.stderr)
        return 1

    der = private_key.sign(payload, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    obj["signature"] = base64.b64encode(raw).decode("ascii")

    json_path.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[sign] 已写入 signature 字段（base64，{len(raw)} 字节原始签名）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
