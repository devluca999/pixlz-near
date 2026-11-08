# Pixl Memory for Chrome

Select text on any page → right-click **Save to Pixl Memory** (or press **⌥⇧S**). The passage is saved to the Pixl Memory service on your Mac, encrypted. Its link reopens the page scrolled to that passage and highlights it, using a [text fragment](https://wicg.github.io/scroll-to-text-fragment/) (`#:~:text=…`).

## Install

1. Start the service and copy its token:
   ```sh
   make -C memory serve
   cd memory && uv run pixl-memory token
   ```
2. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and pick this `extension/` folder.
3. The settings page opens. Paste the token, then **Save and test**.

Click the frog in the toolbar to see, search and delete your highlights. Each title opens its passage.

## How the link is built

- Partial words at the edges of the selection are dropped, because fragments only match whole words.
- Up to 80 characters: the whole passage is the match. Longer: its first and last four words (`text=start,end`).
- If those words appear more than once on the page, up to three words of context are added on each side (`text=prefix-,start,-suffix`).
- Punctuation stranded at the edges by trimming, like the `(` left from `(aposemat…`, is dropped.
- Any existing `#hash` is kept; any old `:~:` directive is replaced.

**Where the links work** (tested on en.wikipedia.org/wiki/Frog, 2026-11-08):
- **Chrome:** clicking a saved link scrolls to and highlights the passage. That includes a short phrase, a long passage, and "the frog" (35 matches on the page; the context words pick the right one).
- **Other apps:** a link opened from another app (`open URL`, the Mac overlay, Notes, Slack…) reaches the default browser with its `#:~:text=` intact.
- **Other browsers:** Safari 16.1+, Edge and Firefox 131+ also support text fragments. Browsers without support just open the page.
- **Limits:** browsers only apply a fragment on a navigation the user starts: a click, or a link opened from another app. A script-triggered navigation opens the page without the highlight. If the page text has changed since you saved it, the page opens unhighlighted. Text inside iframes isn't reachable.
- Selections in form fields, `chrome://` pages and the PDF viewer are saved as plain text, without a fragment link.

## Privacy and permissions

| Permission | Why |
|---|---|
| `contextMenus` | the "Save to Pixl Memory" item |
| `activeTab`, `scripting` | read the selection and the text around it, only in the tab where you just used the menu or shortcut |
| `storage` | the token and port, in this browser profile |
| `http://127.0.0.1/*` | the local service; nothing goes to any other host |

No content scripts run on pages you don't save from. There is no analytics and no remote code.

## Develop

No build step and no dependencies.

```sh
cd extension && node --test   # fragment builder and icon (Node 22+)
```

The toolbar icon is a 16×16 Frogg drawn in code (`icon.js`). The repo keeps PNGs in Git LFS, and a clone without LFS would break the extension.
