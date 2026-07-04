import urllib.request
import json
url = 'https://api.github.com/repos/5ec1cff/Action/releases'
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req) as response:
        releases = json.loads(response.read().decode())
        for r in releases[:15]:
            print(r['name'], r['created_at'])
except Exception as e:
    print('Error:', e)
