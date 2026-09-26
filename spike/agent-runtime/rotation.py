"""45 minutes of requests through identity-proxy :4000. Any non-200 after the
first 600 s means the rotated token never reached the injector."""
import time
import urllib.error
import urllib.request

start, sent, bad = time.time(), 0, 0
while time.time() - start < 45 * 60:
    try:
        code = urllib.request.urlopen("http://127.0.0.1:4000/v1/models", timeout=10).status
    except urllib.error.HTTPError as err:
        code = err.code
    except (urllib.error.URLError, OSError):
        # A policy drop or connect timeout raises here, not HTTPError; count it
        # as a failure instead of letting it kill the loop before RESULT prints.
        code = -1
    sent, bad = sent + 1, bad + (code != 200)
    print(time.strftime("%H:%M:%S"), code, flush=True)
    time.sleep(30)
print(f"RESULT requests={sent} non200={bad}", flush=True)
