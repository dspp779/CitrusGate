#!/usr/bin/env python3
"""Fetch a Taiwan Beanfun MapleStory web-start OTP.

The caller must already have a valid Beanfun browser session.  Pass its Cookie
header through BEANFUN_COOKIE or a mode-600 file; credentials are never stored
by this program.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import html
import http.cookiejar
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


HOST = "tw.beanfun.com"
LOGIN_HOST = "tw.newlogin.beanfun.com"
SERVICE_CODE = "610074"
SERVICE_REGION = "T9"
PPPPP_LITERAL = "1F552AEAFF976018F942B13690C990F60ED01510DDF89165F1658CCE7BC21DBA"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36"
)


class BeanfunError(RuntimeError):
    pass


@dataclass(frozen=True)
class Account:
    account_id: str
    sn: str
    display_name: str


@dataclass(frozen=True)
class StartData:
    key: str
    account_id: str
    sn: str
    display_name: str
    create_time: str
    guard_name: str
    guard_value: str


def _one(pattern: str, text: str, label: str, flags: int = 0) -> str:
    match = re.search(pattern, text, flags)
    if not match:
        raise BeanfunError(f"找不到 {label}；Beanfun 頁面格式可能已變更或登入已失效")
    return html.unescape(match.group(1))


def parse_accounts(page: str) -> list[Account]:
    accounts = []
    for tag in re.findall(r"<div\b[^>]*>", page, re.I):
        attributes = {
            name.lower(): html.unescape(value)
            for name, _quote, value in re.findall(
                r"([\w:-]+)\s*=\s*(['\"])(.*?)\2", tag, re.I | re.S
            )
        }
        account_id = attributes.get("id", "")
        sn = attributes.get("sn", "")
        display_name = attributes.get("name", "")
        if account_id and sn.isdigit() and display_name:
            accounts.append(Account(account_id, sn, display_name))
    if not accounts:
        raise BeanfunError("帳號清單為空；請確認 Cookie 仍有效且楓之谷帳號已建立")
    return accounts


def parse_start_data(page: str) -> StartData:
    key_match = re.search(
        r"GetResultByLongPolling(?:&amp;|&)key=([0-9a-fA-F-]{36})", page
    )
    if not key_match:
        raise BeanfunError("找不到 long-poll key；Beanfun 頁面格式可能已變更或登入已失效")
    key = key_match.group(1)

    account_id = _one(r'ServiceAccountID:\s*"([^"]+)"', page, "service account ID")
    sn = _one(r'ServiceAccountSN:\s*"([^"]+)"', page, "service account SN")
    display_name = _one(
        r'ServiceAccountDisplayName:\s*"([^"]+)"', page, "service account name"
    )
    create_time = _one(
        r'ServiceAccountCreateTime:\s*"([^"]+)"', page, "service account create time"
    )

    # record_service_start.aspx appends a per-session anti-replay pair.  Its
    # field name is the ASP.NET session id, so it cannot be hard-coded.
    guard_match = re.search(
        r'MyAccountData\.ServiceAccountCreateTime\s*\+\s*"&([^="]+)=([^"]+)"\s*;',
        page,
    )
    if not guard_match:
        raise BeanfunError("找不到 record_service_start 的動態驗證欄位")
    guard_name = guard_match.group(1)
    guard_value = urllib.parse.unquote_plus(guard_match.group(2))

    return StartData(
        key, account_id, sn, display_name, create_time, guard_name, guard_value
    )


def parse_secret_code(page: str) -> str:
    return _one(r"m_strSecretCode\s*=\s*'([^']+)'", page, "SecretCode")


def parse_otp_response(response: str) -> tuple[bytes, bytes]:
    status, separator, payload = response.strip().partition(";")
    if separator != ";":
        raise BeanfunError(f"OTP 回應格式不正確：{response[:120]!r}")
    if status != "1":
        raise BeanfunError(f"Beanfun 拒絕 OTP 請求：{payload[:200]}")
    if len(payload) < 24:
        raise BeanfunError("OTP 加密資料太短")
    key = payload[:8].encode("ascii")
    try:
        encrypted = bytes.fromhex(payload[8:])
    except ValueError as exc:
        raise BeanfunError("OTP 加密資料不是十六進位") from exc
    return key, encrypted


def decrypt_des_ecb(key: bytes, encrypted: bytes) -> str:
    commands = [
        ["openssl", "enc", "-d", "-des-ecb", "-provider", "legacy", "-provider", "default",
         "-K", key.hex(), "-nopad"],
        ["openssl", "enc", "-d", "-des-ecb", "-K", key.hex(), "-nopad"],
    ]
    last_error = ""
    for command in commands:
        try:
            result = subprocess.run(command, input=encrypted, capture_output=True, check=False)
        except FileNotFoundError as exc:
            raise BeanfunError("找不到 openssl，無法解密 OTP") from exc
        if result.returncode == 0:
            plain = result.stdout
            if plain and 1 <= plain[-1] <= 8 and plain.endswith(bytes([plain[-1]]) * plain[-1]):
                plain = plain[: -plain[-1]]
            return plain.rstrip(b"\0").decode("utf-8")
        last_error = result.stderr.decode("utf-8", "replace").strip()
    raise BeanfunError(f"DES 解密失敗：{last_error}")


def redact_url(url: str) -> str:
    """Hide credentials that Beanfun unusually places in an OTP query string."""
    parsed = urllib.parse.urlsplit(url)
    sensitive = {"webtoken", "secretcode", "ppppp"}
    query_parts = []
    for part in parsed.query.split("&") if parsed.query else []:
        name, separator, _value = part.partition("=")
        if urllib.parse.unquote_plus(name).lower() in sensitive:
            query_parts.append(f"{name}=<redacted>")
        else:
            query_parts.append(part if separator else name)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, "&".join(query_parts), parsed.fragment)
    )


def format_safe_form(data: dict[str, str]) -> str:
    """Render useful POST fields without exposing the per-session guard."""
    public_fields = {
        "service_code",
        "service_region",
        "service_account_id",
        "sotp",
        "service_account_display_name",
        "service_account_create_time",
    }
    parts = [f"{name}={value}" for name, value in data.items() if name in public_fields]
    if any(name not in public_fields for name in data):
        parts.append("<dynamic-session-guard>=<redacted>")
    return "&".join(parts)


class BeanfunClient:
    def __init__(
        self,
        cookie: str,
        timeout: float = 25.0,
        verbose: bool = False,
        quiet: bool = False,
        unsafe_debug: bool = False,
    ):
        self.cookie = cookie.strip()
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )
        self.timeout = timeout
        self.verbose = verbose
        self.quiet = quiet
        self.unsafe_debug = unsafe_debug
        self.last_url = ""
        self.last_status = 0
        self.last_headers: dict[str, str] = {}

    def status(self, message: str) -> None:
        if not self.quiet:
            print(message, file=sys.stderr, flush=True)

    def request(
        self,
        url: str,
        *,
        data: dict[str, str] | None = None,
        json_data: object | None = None,
        referer: str | None = None,
        extra_headers: dict[str, str] | None = None,
        started: threading.Event | None = None,
    ) -> str:
        if data is not None and json_data is not None:
            raise BeanfunError("同一個 request 不能同時使用 form 與 JSON body")
        if data is not None:
            body = urllib.parse.urlencode(data).encode()
        elif json_data is not None:
            body = json.dumps(json_data, separators=(",", ":")).encode()
        else:
            body = None
        headers = {
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
        }
        if self.cookie:
            headers["Cookie"] = self.cookie
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            headers["X-Requested-With"] = "XMLHttpRequest"
        elif json_data is not None:
            headers["Content-Type"] = "application/json"
        if referer:
            headers["Referer"] = referer
        if extra_headers:
            headers.update(extra_headers)
        display_url = url if self.unsafe_debug else redact_url(url)
        method = "POST" if body is not None else "GET"
        self.status(f"  → {method} {display_url}")
        if data is not None:
            display_form = (
                urllib.parse.urlencode(data) if self.unsafe_debug else format_safe_form(data)
            )
            self.status(f"    參數：{display_form}")
        elif json_data is not None and self.verbose:
            self.status(
                f"    JSON：{json.dumps(json_data, ensure_ascii=False, separators=(',', ':'))}"
            )
        if self.verbose and referer:
            self.status(
                f"    Referer：{referer if self.unsafe_debug else redact_url(referer)}"
            )
        try:
            if started is not None:
                # Signals that request construction/logging is complete and the
                # worker is about to enter the blocking network operation.
                started.set()
            with self.opener.open(
                urllib.request.Request(url, data=body, headers=headers), timeout=self.timeout
            ) as response:
                response_body = response.read().decode("utf-8", "replace")
                self.last_url = response.geturl()
                self.last_status = response.status
                self.last_headers = dict(response.headers.items())
                self.status(f"  ← HTTP {response.status}，收到 {len(response_body)} 字元")
                if self.verbose and self.last_url != url:
                    self.status(f"    最終 URL：{self.last_url}")
                return response_body
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:200]
            raise BeanfunError(f"HTTP {exc.code}: {display_url}\n{detail}") from exc
        except urllib.error.URLError as exc:
            raise BeanfunError(f"連線失敗：{display_url}: {exc.reason}") from exc

    def cookie_value(self, name: str) -> str:
        manual = re.search(rf"(?:^|;\s*){re.escape(name)}=([^;]+)", self.cookie, re.I)
        if manual:
            return manual.group(1)
        matches = [cookie.value for cookie in self.cookie_jar if cookie.name.lower() == name.lower()]
        return matches[-1] if matches else ""

    def cookie_header_for(self, url: str) -> str:
        if self.cookie:
            return self.cookie
        request = urllib.request.Request(url)
        self.cookie_jar.add_cookie_header(request)
        return request.get_header("Cookie", "")

    def describe_cookies(self) -> None:
        self.status("  Cookie jar：")
        for cookie in sorted(self.cookie_jar, key=lambda item: (item.domain, item.name)):
            value = cookie.value if self.unsafe_debug else "<redacted>"
            self.status(
                f"    domain={cookie.domain}，path={cookie.path}，"
                f"{cookie.name}={value}"
            )

    def qr_login(
        self,
        qr_file: str,
        *,
        open_qr: bool = True,
        poll_timeout: float = 75.0,
    ) -> str:
        """Create a Beanfun web session by waiting for a Gama Play QR confirmation."""
        self.status("[登入 1/7] 建立 tw.beanfun.com ASP.NET session")
        home_url = f"https://{HOST}/"
        self.request(home_url)

        now = datetime.datetime.now()
        dt = now.strftime("%Y%m%d%H%M%S.") + f"{now.microsecond // 1000:03d}"
        gateway_query = urllib.parse.urlencode(
            {
                "service": "999999_T0",
                "dt": dt,
                "url": home_url,
            },
            quote_via=urllib.parse.quote,
        )
        gateway_url = f"https://{HOST}/beanfun_block/bflogin/default.aspx?{gateway_query}"
        self.status("[登入 2/7] 取得 Beanfun SessionKey（pSKey）")
        self.request(gateway_url, referer=home_url)
        final_query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.last_url).query)
        session_key = (final_query.get("skey") or final_query.get("pSKey") or [""])[0]
        if not session_key:
            raise BeanfunError(f"登入 redirect 中找不到 SessionKey：{self.last_url}")
        self.status(f"  SessionKey={session_key}")

        login_url = f"https://login.beanfun.com/Login/Index?pSKey={session_key}"
        self.status("[登入 3/7] 取得 CSRF token 與 QR code")
        login_page = self.request(login_url, referer=self.last_url)
        verification_token = _one(
            r'name="__RequestVerificationToken"[^>]*value="([^"]+)"',
            login_page,
            "RequestVerificationToken",
            re.I,
        )
        api_headers = {
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://login.beanfun.com",
            "RequestVerificationToken": verification_token,
        }
        init_text = self.request(
            "https://login.beanfun.com/Login/InitLogin",
            referer=login_url,
            extra_headers=api_headers,
        )
        try:
            init_result = json.loads(init_text)
            qr_image = init_result["ResultData"]["QRImage"]
            deep_link = init_result["ResultData"].get("DeepLink", "")
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise BeanfunError(f"InitLogin 回應格式不正確：{init_text[:300]}") from exc
        if init_result.get("ResultCode") != 1:
            raise BeanfunError(f"InitLogin 失敗：{init_result.get('ResultMessage', init_text[:200])}")
        try:
            qr_bytes = base64.b64decode(qr_image, validate=True)
        except (ValueError, TypeError) as exc:
            raise BeanfunError("InitLogin 的 QRImage 不是有效 base64") from exc
        qr_path = os.path.abspath(os.path.expanduser(qr_file))
        qr_directory = os.path.dirname(qr_path)
        if qr_directory:
            os.makedirs(qr_directory, exist_ok=True)
        descriptor = os.open(qr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(qr_bytes)
        self.status(f"  QR 圖檔：{qr_path}（{len(qr_bytes)} bytes）")
        if self.unsafe_debug:
            self.status(f"  RequestVerificationToken={verification_token}")
            self.status(f"  DeepLink={deep_link}")
        if open_qr and sys.platform == "darwin":
            result = subprocess.run(["open", qr_path], check=False, capture_output=True)
            if result.returncode != 0:
                self.status("  無法自動開啟 QR 圖檔，請手動開啟")

        self.status("[登入 4/7] 等待 Gama Play 掃碼確認")
        poll_url = "https://login.beanfun.com/QRLogin/CheckLoginStatus"
        deadline = time.monotonic() + poll_timeout
        while True:
            poll_text = self.request(
                poll_url,
                json_data={},
                referer=login_url,
                extra_headers=api_headers,
            )
            try:
                poll_result = json.loads(poll_text)
            except json.JSONDecodeError as exc:
                raise BeanfunError(f"QR polling 回應不是 JSON：{poll_text[:300]}") from exc
            result_code = poll_result.get("ResultCode")
            result_message = poll_result.get("ResultMessage", "")
            self.status(
                f"  QR polling：ResultCode={result_code}，ResultMessage={result_message!r}"
            )
            if result_code == 1 or result_message == "Success":
                break
            if result_message == "Token Expired":
                raise BeanfunError("QR code 已過期，請重新執行")
            if time.monotonic() >= deadline:
                raise BeanfunError(f"等待 QR 登入超過 {poll_timeout:g} 秒")
            time.sleep(2)

        self.status("[登入 5/7] 完成 QRLogin 並取得 AuthKey")
        qr_complete_text = self.request(
            "https://login.beanfun.com/QRLogin/QRLogin",
            referer=login_url,
            extra_headers=api_headers,
        )
        try:
            qr_complete = json.loads(qr_complete_text)
        except json.JSONDecodeError as exc:
            raise BeanfunError(f"QRLogin 回應不是 JSON：{qr_complete_text[:300]}") from exc
        if qr_complete.get("ResultCode") != 1:
            raise BeanfunError(
                f"QRLogin 失敗：{qr_complete.get('ResultMessage', qr_complete_text[:200])}"
            )
        send_login_page = self.request(
            "https://login.beanfun.com/Login/SendLogin",
            referer=login_url,
            extra_headers=api_headers,
        )
        auth_key = _one(
            r'name="AuthKey"[^>]*value="([^"]+)"',
            send_login_page,
            "AuthKey",
            re.I,
        )
        self.status(f"  AuthKey={auth_key if self.unsafe_debug else '<redacted>'}")

        self.status("[登入 6/7] 交換 tw.beanfun.com WebToken")
        return_url = f"https://{HOST}/beanfun_block/bflogin/return.aspx"
        self.request(
            return_url,
            data={"SessionKey": session_key, "AuthKey": auth_key},
            referer="https://login.beanfun.com/Login/SendLogin",
        )
        # Some server variants return a relative Location after the form POST;
        # urllib follows normal redirects automatically.  A final home request
        # also initializes the authenticated ASP.NET session used by game pages.
        self.request(home_url, referer=return_url)

        self.status("[登入 7/7] 檢查 Beanfun Cookie")
        required = ["ASP.NET_SessionId", "bfWebToken", "bfUID", "bfTD"]
        missing = [name for name in required if not self.cookie_value(name)]
        self.describe_cookies()
        if missing:
            raise BeanfunError("登入完成但缺少 Cookie：" + ", ".join(missing))
        tw_cookie_header = self.cookie_header_for(home_url)
        self.status(
            f"  Cookie: {tw_cookie_header if self.unsafe_debug else '<redacted>'}"
        )
        return tw_cookie_header

    def accounts(self) -> list[Account]:
        self.status("[1/6] 取得楓之谷帳號清單")
        web_token = self.cookie_value("bfWebToken")
        if not web_token:
            raise BeanfunError("Cookie 中缺少 bfWebToken，無法授權 game_zone")
        auth_query = urllib.parse.urlencode(
            {
                "channel": "game_zone",
                "page_and_query": (
                    "game_start.aspx?service_code_and_region="
                    f"{SERVICE_CODE}_{SERVICE_REGION}"
                ),
                "web_token": web_token,
            },
            quote_via=urllib.parse.quote,
        )
        auth_url = f"https://{HOST}/beanfun_block/auth.aspx?{auth_query}"
        self.status("  先以 bfWebToken 授權 game_zone")
        self.request(auth_url, referer=f"https://{HOST}/")
        query = urllib.parse.urlencode(
            {"sc": SERVICE_CODE, "sr": SERVICE_REGION, "dt": time.strftime("%Y%m%d%H%M%S")}
        )
        page = self.request(
            f"https://{HOST}/beanfun_block/game_zone/game_server_account_list.aspx?{query}"
        )
        accounts = parse_accounts(page)
        self.status(f"  解析到 {len(accounts)} 個帳號：")
        for account in accounts:
            self.status(
                f"    id={account.account_id}，sn={account.sn}，name={account.display_name}"
            )
        return accounts

    def otp(self, account: Account, ppppp_override: str | None = None) -> str:
        self.status(
            f"[2/6] 初始化遊戲啟動：id={account.account_id}，sn={account.sn}，name={account.display_name}"
        )
        query = urllib.parse.urlencode(
            {
                "service_code": SERVICE_CODE,
                "service_region": SERVICE_REGION,
                "sotp": account.sn,
                "dt": time.strftime("%Y%m%d%H%M%S"),
            }
        )
        step2_url = f"https://{HOST}/beanfun_block/game_zone/game_start_step2.aspx?{query}"
        step2 = self.request(step2_url)
        start = parse_start_data(step2)
        self.status("  從 step2 取得：")
        self.status(f"    LongPolling key={start.key}")
        self.status(f"    account_id={start.account_id}")
        self.status(f"    sn={start.sn}")
        self.status(f"    name={start.display_name}")
        self.status(f"    create_time={start.create_time}")
        if self.unsafe_debug:
            self.status(f"    dynamic_session_guard：{start.guard_name}={start.guard_value}")
        else:
            self.status("    dynamic_session_guard=<redacted>")
        if start.account_id != account.account_id or start.sn != account.sn:
            raise BeanfunError("step2 回傳的帳號與所選帳號不同，已停止以避免取錯 OTP")

        self.status("[3/6] 取得 OTP SecretCode")
        secret = parse_secret_code(
            self.request(f"https://{LOGIN_HOST}/generic_handlers/get_cookies.ashx", referer=step2_url)
        )
        self.status(
            f"  SecretCode={secret if self.unsafe_debug else '<redacted>'}（{len(secret)} 字元）"
        )
        ppppp = ppppp_override or PPPPP_LITERAL
        if self.unsafe_debug:
            self.status(f"  ppppp={ppppp}")
        else:
            self.status(
                f"  ppppp={'使用命令列覆寫值' if ppppp_override else '使用內建協定常數'}（內容遮蔽）"
            )

        record_data = {
            "service_code": SERVICE_CODE,
            "service_region": SERVICE_REGION,
            "service_account_id": start.account_id,
            "sotp": start.sn,
            "service_account_display_name": start.display_name,
            "service_account_create_time": start.create_time,
            start.guard_name: start.guard_value,
        }
        poll_query = urllib.parse.urlencode(
            {"meth": "GetResultByLongPolling", "key": start.key, "_": int(time.time() * 1000)}
        )
        poll_url = f"https://{HOST}/generic_handlers/get_result.ashx?{poll_query}"
        record_url = f"https://{HOST}/beanfun_block/generic_handlers/record_service_start.ashx"

        self.status("[4/6] 登記遊戲啟動")
        record = self.request(record_url, data=record_data, referer=step2_url)
        if not re.search(r"['\"]?intResult['\"]?\s*:\s*1", record):
            raise BeanfunError(f"record_service_start 失敗：{record[:200]}")
        self.status("  record_service_start：Success（intResult=1）")

        self.status(f"[5/6] 背景啟動 Long polling：key={start.key}")
        poll_started = threading.Event()

        def run_long_poll() -> None:
            try:
                poll = self.request(poll_url, referer=step2_url, started=poll_started)
                try:
                    poll_json = json.loads(poll.replace("'", '"'))
                except json.JSONDecodeError:
                    poll_json = {}
                if poll_json.get("intResult") not in (None, 1):
                    self.status(f"  LongPolling 背景回應失敗：{poll[:200]}")
                elif poll_json:
                    self.status(
                        "  LongPolling 背景結果："
                        f"intResult={poll_json.get('intResult')}，"
                        f"strOutstring={poll_json.get('strOutstring', '')!r}"
                    )
                else:
                    self.status(f"  LongPolling 背景回應：{poll[:160]}")
            except BeanfunError as exc:
                self.status(f"  LongPolling 背景連線結束：{exc}")

        poll_thread = threading.Thread(
            target=run_long_poll,
            name="beanfun-long-poll",
            daemon=True,
        )
        poll_thread.start()
        if not poll_started.wait(timeout=1.0):
            raise BeanfunError("LongPolling 背景工作未能啟動")
        self.status("  LongPolling 已在背景等待；主流程繼續取得 OTP")

        web_token = self.cookie_value("bfWebToken")
        if not web_token:
            raise BeanfunError("Cookie 中缺少 bfWebToken")
        if self.unsafe_debug:
            self.status(f"  WebToken={web_token}")
        # Beanfun expects CreateTime's space as %20 rather than form-style '+'.
        otp_query = urllib.parse.urlencode(
            {
                "SN": start.key,
                "WebToken": web_token,
                "SecretCode": secret,
                "ppppp": ppppp,
                "ServiceCode": SERVICE_CODE,
                "ServiceRegion": SERVICE_REGION,
                "ServiceAccount": start.account_id,
                "CreateTime": start.create_time,
                "d": int(time.time() * 1000),
            },
            quote_via=urllib.parse.quote,
        )
        self.status("[6/6] 取得並解密 WebStart OTP")
        if self.unsafe_debug:
            self.status(f"  WebToken={web_token}")
            self.status(f"  SecretCode={secret}")
            self.status(f"  ppppp={ppppp}")
        else:
            self.status("  WebToken=<redacted>，SecretCode=<redacted>，ppppp=<redacted>")
        response = self.request(
            f"https://{HOST}/beanfun_block/generic_handlers/get_webstart_otp.ashx?{otp_query}",
            referer=step2_url,
        )
        key, encrypted = parse_otp_response(response)
        if self.unsafe_debug:
            self.status(
                f"  OTP envelope：狀態=1，DES key={key.decode('ascii', 'replace')}，"
                f"密文={encrypted.hex()}"
            )
        else:
            self.status(
                f"  OTP envelope：狀態=1，DES key=<redacted>，密文={len(encrypted)} bytes"
            )
        otp = decrypt_des_ecb(key, encrypted)
        self.status(f"  OTP 解密成功：{len(otp)} 字元")
        return otp


def read_cookie(args: argparse.Namespace) -> str:
    if args.cookie_file:
        mode = stat.S_IMODE(os.stat(args.cookie_file).st_mode)
        if mode & 0o077:
            raise BeanfunError("Cookie 檔案權限過寬；請先執行 chmod 600 <檔案>")
        with open(args.cookie_file, encoding="utf-8") as cookie_file:
            value = " ".join(cookie_file.read().strip().split())
    else:
        value = os.environ.get("BEANFUN_COOKIE", "").strip()
    if not value and not args.qr_login:
        raise BeanfunError("請設定 BEANFUN_COOKIE，或使用 --cookie-file 指定 mode 600 檔案")
    return value


def select_account(accounts: list[Account], account_id: str | None) -> Account:
    if account_id:
        for account in accounts:
            if account.account_id == account_id or account.sn == account_id:
                return account
        raise BeanfunError(f"找不到帳號 {account_id}")
    if len(accounts) == 1:
        return accounts[0]
    if not sys.stdin.isatty():
        raise BeanfunError("有多個帳號；請用 --account 指定 account ID 或 SN")
    for index, account in enumerate(accounts, 1):
        print(f"{index}. {account.display_name}  ({account.account_id}, SN {account.sn})")
    try:
        return accounts[int(input("選擇帳號：")) - 1]
    except (ValueError, IndexError) as exc:
        raise BeanfunError("帳號選擇無效") from exc


def build_launch_arguments(account: Account, otp: str) -> str:
    """Build Beanfun's MapleStory argv using ServiceAccountID, not display name."""
    return (
        "tw.login.maplestory.beanfun.com 8484 BeanFun "
        f"{account.account_id} {otp}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="取得台灣 Beanfun 楓之谷 WebStart OTP")
    parser.add_argument("--account", help="service account ID 或 SN；多帳號時必填")
    parser.add_argument("--cookie-file", help="Cookie header 檔案（權限必須為 600）")
    parser.add_argument(
        "--qr-login",
        action="store_true",
        help="不使用現成 Cookie，顯示 Gama Play QR code 並自動完成登入",
    )
    parser.add_argument(
        "--qr-file",
        default="/tmp/beanfun-login-qr.png",
        help="QR code PNG 輸出位置（預設：/tmp/beanfun-login-qr.png）",
    )
    parser.add_argument(
        "--no-open-qr",
        action="store_true",
        help="不自動以 macOS Preview 開啟 QR code",
    )
    parser.add_argument(
        "--qr-timeout",
        type=float,
        default=75.0,
        help="等待 QR 掃碼的秒數（預設：75）",
    )
    parser.add_argument(
        "--save-cookie",
        help="將登入後 tw.beanfun.com Cookie header 存成 mode-600 檔案",
    )
    parser.add_argument("--ppppp", help="覆寫 Beanfun 協定的 ppppp 常數（通常不需要）")
    parser.add_argument("--list", action="store_true", help="只列出遊戲帳號")
    parser.add_argument("--verbose", action="store_true", help="另外顯示每次 request 的 Referer")
    parser.add_argument("--quiet", action="store_true", help="不顯示進度，只輸出結果")
    parser.add_argument(
        "--unsafe-debug",
        action="store_true",
        help="不遮蔽 Cookie、token、SecretCode、session guard 與 DES 資料",
    )
    args = parser.parse_args()
    try:
        cookie = read_cookie(args)
        client = BeanfunClient(
            cookie,
            verbose=args.verbose,
            quiet=args.quiet,
            unsafe_debug=args.unsafe_debug,
        )
        if args.unsafe_debug:
            client.status("*** UNSAFE DEBUG：以下輸出包含可重用的登入憑證 ***")
            if cookie:
                client.status(f"Cookie: {cookie}")
        if args.qr_login:
            cookie = client.qr_login(
                args.qr_file,
                open_qr=not args.no_open_qr,
                poll_timeout=args.qr_timeout,
            )
            if args.save_cookie:
                cookie_path = os.path.abspath(os.path.expanduser(args.save_cookie))
                descriptor = os.open(
                    cookie_path,
                    os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                    0o600,
                )
                os.fchmod(descriptor, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as cookie_file:
                    cookie_file.write(cookie + "\n")
                client.status(f"  Cookie 已存至 {cookie_path}（mode 600）")
        accounts = client.accounts()
        if args.list:
            for account in accounts:
                print(f"{account.account_id}\t{account.sn}\t{account.display_name}")
            return 0
        account = select_account(accounts, args.account)
        otp = client.otp(account, args.ppppp)
        print(f"帳號：{account.display_name}")
        print(f"OTP：{otp}")
        print(f"啟動參數：{build_launch_arguments(account, otp)}")
        return 0
    except BeanfunError as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
