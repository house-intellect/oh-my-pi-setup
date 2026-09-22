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
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            import os
            doh_endpoint = os.environ.get("GEMINI_DOH_URL", "https://dns.comss.one/dns-query")
            if isinstance(doh_endpoint, str):
                doh_endpoint = doh_endpoint.encode()
            curl_opts[CurlOpt.DOH_URL] = doh_endpoint
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass
