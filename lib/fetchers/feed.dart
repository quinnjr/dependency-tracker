import 'package:xml/xml.dart';

import '../net.dart';

class FeedEntry {
  const FeedEntry({
    required this.id,
    required this.title,
    this.published,
    this.content,
    this.url,
  });

  final String id;
  final String title;
  final DateTime? published;

  /// Entry body, HTML-unescaped. Null for feeds that carry no body, such as
  /// GitHub's tags.atom.
  final String? content;

  final String? url;
}

Future<List<FeedEntry>> fetchFeed(Net net, Uri url) async =>
    parseFeed((await net.get(url)).body);

List<FeedEntry> parseFeed(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('not well-formed xml: ${e.message}');
  }

  final root = doc.rootElement;
  final name = root.name.local.toLowerCase();
  if (name == 'feed') return _atom(root);
  if (name == 'rss' || name == 'rdf') return _rss(root);
  throw FormatException('not an atom or rss feed: root element <$name>');
}

String? _text(XmlElement parent, String tag) {
  // Two passes, precise first, widened only on a miss. A single wildcard
  // pass (namespace: '*') would let a namespaced sibling with the same local
  // name shadow the real element it sits next to — e.g. WordPress-style RSS
  // commonly carries an empty <atom:link rel="self"/> right before the real
  // <link>, and a wildcard match would find the empty one first and return
  // null for a feed that actually has a URL. Requiring the first pass to
  // match with no namespace qualification means <link> always wins over
  // <atom:link>, while the second (wildcard) pass still finds a
  // Dublin-Core <dc:date> or RSS's <content:encoded> when no unqualified
  // element exists to shadow them.
  //
  // Within each pass, skip elements whose text is empty rather than
  // stopping at the first match — a self-closing element earlier in
  // document order must never win over a populated one later on.
  String? firstNonEmpty(Iterable<XmlElement> elements) {
    for (final el in elements) {
      // innerText already resolves entities, which is what unescapes the
      // HTML that both Atom content and RSS description arrive wrapped in.
      final value = el.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  return firstNonEmpty(parent.findElements(tag)) ??
      firstNonEmpty(parent.findElements(tag, namespace: '*'));
}

List<FeedEntry> _atom(XmlElement feed) {
  return feed.findElements('entry').map((e) {
    final href = _pickAtomLink(e.findElements('link'))?.getAttribute('href');
    final title = _text(e, 'title') ?? '';
    return FeedEntry(
      id: _text(e, 'id') ?? href ?? title,
      title: title,
      published: parseFeedDate(_text(e, 'updated') ?? _text(e, 'published')),
      content: _text(e, 'content') ?? _text(e, 'summary'),
      url: href,
    );
  }).toList();
}

/// Picks the link an entry's [url] should point at. Some feeds emit several
/// `<link>` elements per entry, so preference order matters:
///
/// 1. `rel="alternate"` — the entry's own page, per the Atom spec.
/// 2. A link with no `rel` at all — an unmarked link is the implicit
///    alternate per the Atom spec, so it outranks an explicitly-labelled
///    non-alternate link such as `rel="self"` (which points at the feed,
///    not the entry) or `rel="edit"`.
/// 3. Whatever link came first in document order, as a last resort.
/// 4. `null`, for an entry with no links at all.
XmlElement? _pickAtomLink(Iterable<XmlElement> links) {
  XmlElement? first;
  XmlElement? unmarked;
  for (final link in links) {
    first ??= link;
    final rel = link.getAttribute('rel');
    if (rel == 'alternate') return link;
    if (rel == null) unmarked ??= link;
  }
  return unmarked ?? first;
}

List<FeedEntry> _rss(XmlElement rss) {
  // findAllElements is recursive, so this finds <item>s whether they are
  // nested in <channel> (RSS 2.0) or siblings of it (RSS 1.0 / RDF) — one
  // path for both shapes instead of special-casing RDF. Searching only
  // inside <channel> would silently return [] for a real, non-empty RDF
  // feed (e.g. a CVE feed), which is indistinguishable from "nothing new".
  final items = rss.findAllElements('item');
  return items.map((i) {
    final link = _text(i, 'link');
    final title = _text(i, 'title') ?? '';
    return FeedEntry(
      id: _text(i, 'guid') ?? link ?? title,
      title: title,
      published: parseFeedDate(_text(i, 'pubDate') ?? _text(i, 'date')),
      content: _text(i, 'description') ?? _text(i, 'encoded'),
      url: link,
    );
  }).toList();
}

const Map<String, String> _months = {
  'jan': '01',
  'feb': '02',
  'mar': '03',
  'apr': '04',
  'may': '05',
  'jun': '06',
  'jul': '07',
  'aug': '08',
  'sep': '09',
  'oct': '10',
  'nov': '11',
  'dec': '12',
};

/// Offsets RFC 822 permits by name. Anything else must be numeric.
const Map<String, int> _namedZones = {
  'ut': 0,
  'gmt': 0,
  'z': 0,
  'est': -5,
  'edt': -4,
  'cst': -6,
  'cdt': -5,
  'mst': -7,
  'mdt': -6,
  'pst': -8,
  'pdt': -7,
};

/// Parses the two date formats feeds actually use. Atom mandates ISO 8601,
/// RSS mandates RFC 822, and Dart only understands the former.
DateTime? parseFeedDate(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;

  final iso = DateTime.tryParse(text);
  if (iso != null) return iso.toUtc();

  // e.g. "Mon, 08 Jul 2026 15:02:06 -0700"
  final m = RegExp(
    r'^(?:\w{3},\s*)?(\d{1,2})\s+(\w{3})\s+(\d{2,4})\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,3})?$',
  ).firstMatch(text);
  if (m == null) return null;

  final month = _months[m.group(2)!.toLowerCase()];
  if (month == null) return null;

  var year = int.parse(m.group(3)!);
  if (year < 100) year += year < 70 ? 2000 : 1900;

  final base = DateTime.utc(
    year,
    int.parse(month),
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6) ?? '0'),
  );

  final zone = m.group(7);
  if (zone == null) return base;

  if (zone.startsWith('+') || zone.startsWith('-')) {
    final sign = zone[0] == '-' ? -1 : 1;
    final hours = int.parse(zone.substring(1, 3));
    final minutes = int.parse(zone.substring(3, 5));
    return base.subtract(
      Duration(hours: sign * hours, minutes: sign * minutes),
    );
  }

  final named = _namedZones[zone.toLowerCase()];
  if (named == null) return base;
  return base.subtract(Duration(hours: named));
}
