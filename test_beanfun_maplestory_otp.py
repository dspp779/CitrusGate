import importlib.util
import os
import pathlib
import sys
import tempfile
import threading
import time
import unittest


SCRIPT = pathlib.Path(__file__).with_name("beanfun_maplestory_otp.py")
SPEC = importlib.util.spec_from_file_location("beanfun_otp", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class BeanfunOtpParsingTests(unittest.TestCase):
    START_PAGE = '''
    var MyAccountData = {ServiceAccountID: "T90000000000000000",
      ServiceAccountSN: "1234567", ServiceAccountDisplayName: "example_account",
      ServiceAccountCreateTime: "2024-01-15 12:34:56"};
    url: "/generic_handlers/get_result.ashx?meth=GetResultByLongPolling&key=00000000-1111-4222-8333-444444444444"
    data = "&service_account_create_time=" + MyAccountData.ServiceAccountCreateTime + "&abcdefghijklmnopqrstuvwx=example%3d";
    '''

    def test_parse_account_list(self):
        page = '<div id="T90000000000000000" sn="1234567" name="a&amp;b">'
        self.assertEqual(
            MODULE.parse_accounts(page),
            [MODULE.Account("T90000000000000000", "1234567", "a&b")],
        )

    def test_parse_account_list_allows_reordered_and_single_quoted_attributes(self):
        page = "<div class='Account' name='second&amp;name' visible='1' sn='7654321' id='T9123'>"
        self.assertEqual(
            MODULE.parse_accounts(page),
            [MODULE.Account("T9123", "7654321", "second&name")],
        )

    def test_launch_arguments_use_service_account_id_not_display_name(self):
        account = MODULE.Account("T90000000000000000", "1234567", "example_account")
        self.assertEqual(
            MODULE.build_launch_arguments(account, "0123456789"),
            "tw.login.maplestory.beanfun.com 8484 BeanFun "
            "T90000000000000000 0123456789",
        )

    def test_accounts_authorizes_game_zone_before_loading_list(self):
        class FakeClient(MODULE.BeanfunClient):
            def __init__(fake_self):
                super().__init__("bfWebToken=web-token", quiet=True)
                fake_self.calls = []

            def request(fake_self, url, **kwargs):
                fake_self.calls.append(url)
                if "game_server_account_list.aspx" in url:
                    return '<div id="T900" sn="1234567" name="account">'
                return "ok"

        client = FakeClient()
        self.assertEqual(client.accounts()[0].sn, "1234567")
        self.assertIn("auth.aspx", client.calls[0])
        self.assertIn("channel=game_zone", client.calls[0])
        self.assertIn("web_token=web-token", client.calls[0])
        self.assertIn("game_server_account_list.aspx", client.calls[1])

    def test_parse_start_data_uses_exact_key_and_decodes_guard(self):
        result = MODULE.parse_start_data(self.START_PAGE)
        self.assertEqual(result.key, "00000000-1111-4222-8333-444444444444")
        self.assertEqual(result.guard_name, "abcdefghijklmnopqrstuvwx")
        self.assertEqual(result.guard_value, "example=")

    def test_parse_otp_response(self):
        key, encrypted = MODULE.parse_otp_response("1;123456780001020304050607")
        self.assertEqual(key, b"12345678")
        self.assertEqual(encrypted, bytes.fromhex("0001020304050607"))

    def test_rejects_failed_otp(self):
        with self.assertRaisesRegex(MODULE.BeanfunError, "拒絕"):
            MODULE.parse_otp_response("0;invalid session")

    def test_des_decrypt_known_vector(self):
        self.assertEqual(
            MODULE.decrypt_des_ecb(b"12345678", bytes.fromhex("897923ff842ec7e7")),
            "OTP12345",
        )

    def test_redact_url(self):
        redacted = MODULE.redact_url(
            "https://example.test/otp?SN=public&CreateTime=2024-01-15%2012%3A34%3A56&WebToken=secret&SecretCode=also-secret&ppppp=x"
        )
        self.assertIn("SN=public", redacted)
        self.assertIn("CreateTime=2024-01-15%2012%3A34%3A56", redacted)
        self.assertNotIn("secret", redacted)
        self.assertNotIn("ppppp=x", redacted)

    def test_safe_form_hides_dynamic_session_guard(self):
        rendered = MODULE.format_safe_form(
            {
                "service_code": "610074",
                "service_account_display_name": "example_account",
                "abcdefghijklmnopqrstuvwx": "secret-guard-value",
            }
        )
        self.assertIn("service_code=610074", rendered)
        self.assertIn("service_account_display_name=example_account", rendered)
        self.assertIn("<dynamic-session-guard>=<redacted>", rendered)
        self.assertNotIn("abcdefghijklmnopqrstuvwx", rendered)
        self.assertNotIn("secret-guard-value", rendered)

    def test_full_flow_records_before_poll_and_percent_encodes_create_time(self):
        class FakeClient(MODULE.BeanfunClient):
            def __init__(fake_self):
                super().__init__("bfWebToken=web-token", quiet=True)
                fake_self.calls = []

            def request(fake_self, url, *, data=None, referer=None, started=None):
                fake_self.calls.append((url, data))
                if started is not None:
                    started.set()
                if "game_start_step2.aspx" in url:
                    return self.START_PAGE
                if "get_cookies.ashx" in url:
                    return "var m_strSecretCode = 'secret-code';"
                if "record_service_start.ashx" in url:
                    return "{ 'intResult': 1, 'strOutstring': 'Success' }"
                if "get_result.ashx" in url:
                    return '{ "intResult": 1, "objResult": "" }'
                if "get_webstart_otp.ashx" in url:
                    return "1;12345678897923ff842ec7e7"
                self.fail(f"unexpected URL: {url}")

        client = FakeClient()
        otp = client.otp(MODULE.Account("T90000000000000000", "1234567", "example_account"))
        self.assertEqual(otp, "OTP12345")
        paths = [url.split("?", 1)[0].rsplit("/", 1)[-1] for url, _ in client.calls]
        self.assertLess(paths.index("record_service_start.ashx"), paths.index("get_result.ashx"))
        otp_url = next(url for url, _ in client.calls if "get_webstart_otp.ashx" in url)
        self.assertIn("CreateTime=2024-01-15%2012%3A34%3A56", otp_url)
        self.assertIn(f"ppppp={MODULE.PPPPP_LITERAL}", otp_url)

    def test_otp_does_not_wait_for_hanging_long_poll(self):
        class HangingPollClient(MODULE.BeanfunClient):
            def __init__(fake_self):
                super().__init__("bfWebToken=web-token", quiet=True)
                fake_self.release_poll = threading.Event()

            def request(fake_self, url, *, data=None, referer=None, started=None):
                if started is not None:
                    started.set()
                if "game_start_step2.aspx" in url:
                    return self.START_PAGE
                if "get_cookies.ashx" in url:
                    return "var m_strSecretCode = 'secret-code';"
                if "record_service_start.ashx" in url:
                    return "{ 'intResult': 1, 'strOutstring': 'Success' }"
                if "get_result.ashx" in url:
                    fake_self.release_poll.wait(timeout=2)
                    return '{ "intResult": 1 }'
                if "get_webstart_otp.ashx" in url:
                    return "1;12345678897923ff842ec7e7"
                self.fail(f"unexpected URL: {url}")

        client = HangingPollClient()
        before = time.monotonic()
        try:
            otp = client.otp(
                MODULE.Account("T90000000000000000", "1234567", "example_account")
            )
        finally:
            client.release_poll.set()
        self.assertEqual(otp, "OTP12345")
        self.assertLess(time.monotonic() - before, 0.5)

    def test_qr_login_exchanges_session_and_auth_keys_for_web_cookies(self):
        class FakeQrClient(MODULE.BeanfunClient):
            def __init__(fake_self):
                super().__init__("", quiet=True, unsafe_debug=True)
                fake_self.calls = []
                fake_self.logged_in = False

            def request(
                fake_self,
                url,
                *,
                data=None,
                json_data=None,
                referer=None,
                extra_headers=None,
                started=None,
            ):
                fake_self.calls.append(
                    {
                        "url": url,
                        "data": data,
                        "json_data": json_data,
                        "referer": referer,
                        "headers": extra_headers or {},
                    }
                )
                if "bflogin/default.aspx" in url:
                    fake_self.last_url = (
                        "https://tw.newlogin.beanfun.com/checkin_step2.aspx"
                        "?skey=202607abcdefghijkl&display_mode=2"
                    )
                    return "checkin"
                if "/Login/Index" in url:
                    return '<input name="__RequestVerificationToken" type="hidden" value="csrf-token" />'
                if "/Login/InitLogin" in url:
                    import base64
                    import json

                    return json.dumps(
                        {
                            "ResultCode": 1,
                            "ResultData": {
                                "QRImage": base64.b64encode(b"fake-png").decode(),
                                "DeepLink": "gameplapp://example",
                            },
                        }
                    )
                if "/QRLogin/CheckLoginStatus" in url:
                    return '{"ResultCode":1,"ResultMessage":"Success"}'
                if url.endswith("/QRLogin/QRLogin"):
                    return '{"ResultCode":1,"ResultMessage":"Success"}'
                if url.endswith("/Login/SendLogin"):
                    return '<input name="AuthKey" type="hidden" value="auth-key" />'
                if url.endswith("/beanfun_block/bflogin/return.aspx"):
                    fake_self.logged_in = True
                    return "redirect"
                if url == "https://tw.beanfun.com/":
                    return "home"
                self.fail(f"unexpected URL: {url}")

            def cookie_value(fake_self, name):
                return f"value-{name}" if fake_self.logged_in else ""

            def cookie_header_for(fake_self, url):
                self.assertEqual(url, "https://tw.beanfun.com/")
                return (
                    "ASP.NET_SessionId=session; bfWebToken=web; "
                    "bfUID=uid; bfTD=td"
                )

            def describe_cookies(fake_self):
                pass

        client = FakeQrClient()
        with tempfile.TemporaryDirectory() as directory:
            qr_path = os.path.join(directory, "qr.png")
            cookie = client.qr_login(qr_path, open_qr=False, poll_timeout=1)
            self.assertEqual(pathlib.Path(qr_path).read_bytes(), b"fake-png")
            self.assertEqual(os.stat(qr_path).st_mode & 0o777, 0o600)

        self.assertIn("bfWebToken=web", cookie)
        poll = next(call for call in client.calls if "CheckLoginStatus" in call["url"])
        self.assertEqual(poll["json_data"], {})
        self.assertEqual(poll["headers"]["RequestVerificationToken"], "csrf-token")
        exchange = next(
            call for call in client.calls if call["url"].endswith("bflogin/return.aspx")
        )
        self.assertEqual(
            exchange["data"],
            {"SessionKey": "202607abcdefghijkl", "AuthKey": "auth-key"},
        )


if __name__ == "__main__":
    unittest.main()
