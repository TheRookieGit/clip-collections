import Foundation

enum Scripts {
    /// Scrolls down in steps until the page stops growing, so lazy images start loading; gives up after `seconds`.
    static let scroll = #"""
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const deadline = Date.now() + seconds * 1000;
    let y = 0, last = -1, still = 0;
    while (Date.now() < deadline && still < 3) {
      y += Math.max(400, window.innerHeight * 0.8);
      window.scrollTo(0, y);
      await sleep(180);
      const h = document.documentElement.scrollHeight;
      if (y >= h) { still = h === last ? still + 1 : 0; last = h; await sleep(220); }
    }
    window.scrollTo(0, 0);
    const until = Date.now() + 6000;
    while (Date.now() < until) {
      const pending = [...document.images].filter(i => !i.complete).length;
      if (!pending) break;
      await sleep(250);
    }
    return true;
    """#

    /// Runs Readability on a copy of the page, after moving lazy-loading addresses into src. Returns JSON.
    /// Runs in an isolated world, so a page cannot tamper with it.
    static func readability(library: String) -> String {
        #"""
        const module = undefined;
        \#(library)
        const lazyAttrs = ['data-src','data-original','data-actualsrc','data-original-src','data-lazy-src','data-url','data-img-url','data-croporisrc'];
        const clone = document.cloneNode(true);
        const absolute = (u) => { try { return new URL(u, document.baseURI).href; } catch { return ''; } };
        const largest = (srcset) => {
          let best = '', bestW = -1;
          for (const part of (srcset || '').split(/,\s+/)) {
            const [u, d] = part.trim().split(/\s+/);
            const w = d ? parseFloat(d) * (d.endsWith('x') ? 1000 : 1) : 0;
            if (u && w > bestW) { best = u; bestW = w; }
          }
          return best;
        };
        for (const img of clone.querySelectorAll('img')) {
          let src = '';
          for (const a of lazyAttrs) if (img.getAttribute(a)) { src = img.getAttribute(a); break; }
          const set = img.getAttribute('srcset') || img.getAttribute('data-srcset');
          if (set) src = largest(set) || src;
          src = src || img.getAttribute('src') || '';
          if (src) img.setAttribute('src', absolute(src));
          img.removeAttribute('srcset'); img.removeAttribute('loading'); img.removeAttribute('style');
          img.removeAttribute('width'); img.removeAttribute('height');
        }
        for (const el of clone.querySelectorAll('[style*="visibility"],[style*="opacity"]')) el.removeAttribute('style');
        const meta = (...names) => {
          for (const n of names) {
            const m = document.querySelector(`meta[property="${n}"],meta[name="${n}"],meta[itemprop="${n}"]`);
            if (m && m.content) return m.content;
          }
          return '';
        };
        const t = document.querySelector('#publish_time');
        let article = null, error = '';
        try { article = new Readability(clone, { keepClasses: false, charThreshold: 140 }).parse(); } catch (e) { error = String(e); }
        const pageImages = [...document.images].filter(i => i.naturalWidth >= 300 && i.naturalHeight >= 200).length;
        if (!article) return JSON.stringify({ error: error || 'no article', pageImages });
        const box = document.createElement('div'); box.innerHTML = article.content;
        for (const bad of box.querySelectorAll('script,style,iframe,object,embed,form,link,meta,svg,video,audio,source')) bad.remove();
        const images = [...box.querySelectorAll('img')].map(i => i.getAttribute('src') || '');
        return JSON.stringify({
          title: article.title || document.title || '', byline: article.byline || '',
          site: article.siteName || meta('og:site_name') || location.hostname,
          published: article.publishedTime || meta('article:published_time','datePublished','pubdate','og:article:published_time','publishdate') || (t && t.textContent.trim()) || '',
          content: box.innerHTML, images, textLength: article.length || 0, pageImages, text: (box.textContent || '').slice(0, 3000),
        });
        """#
    }
}
