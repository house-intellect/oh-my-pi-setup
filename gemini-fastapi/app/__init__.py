# Gemini API Server Package
try:
    from curl_cffi import CurlOpt
    from curl_cffi.requests.session import BaseSession

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {}
            kwargs["curl_options"] = curl_opts
        import os
        if isinstance(curl_opts, dict):
            if CurlOpt.DOH_URL not in curl_opts:
                doh_endpoint = os.environ.get("GEMINI_DOH_URL", "https://dns.dns-ai.ru/dns-query")
                if isinstance(doh_endpoint, str):
                    doh_endpoint = doh_endpoint.encode()
                curl_opts[CurlOpt.DOH_URL] = doh_endpoint
            ca_bundle = os.environ.get("CURL_CA_BUNDLE") or os.environ.get("SSL_CERT_FILE")
            if ca_bundle and hasattr(CurlOpt, "CAINFO") and CurlOpt.CAINFO not in curl_opts:
                curl_opts[CurlOpt.CAINFO] = ca_bundle.encode() if isinstance(ca_bundle, str) else ca_bundle
        ca_bundle = os.environ.get("CURL_CA_BUNDLE") or os.environ.get("SSL_CERT_FILE")
        if ca_bundle and ("verify" not in kwargs or kwargs.get("verify") is True):
            kwargs["verify"] = ca_bundle
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

