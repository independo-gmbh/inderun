# Share card

`source.html` renders `public/og/default.jpg` (1200x630, the `og:image` of every page). Regenerate after editing:

```sh
cd website
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars \
  --window-size=1200,630 --screenshot=/tmp/og.png "file://$PWD/og/source.html"
sips -s format jpeg -s formatOptions 85 /tmp/og.png --out public/og/default.jpg
```
