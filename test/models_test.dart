import 'package:deptracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FetchedRelease.withNotes', () {
    // The merge step in fetchers.dart calls this for every version: the
    // registry is authoritative about which versions exist and when they
    // shipped, GitHub is the only source of notes. The `??` in each field is
    // what keeps that split intact — overwriting with null would discard the
    // registry's data for any version GitHub has no entry for.
    const base = FetchedRelease(
      version: '1.2.3',
      notesMd: 'registry notes',
      url: 'https://pub.dev/packages/http',
    );

    test('applies notes and url when both are given', () {
      final merged = base.withNotes('github notes', 'https://github.com/x/y');
      expect(merged.notesMd, 'github notes');
      expect(merged.url, 'https://github.com/x/y');
    });

    test('keeps the existing values when given nulls', () {
      // This is the no-matching-GitHub-entry case, and the one that matters:
      // a version present in the registry but absent from GitHub's feed must
      // keep whatever it already had.
      final merged = base.withNotes(null, null);
      expect(merged.notesMd, 'registry notes');
      expect(merged.url, 'https://pub.dev/packages/http');
    });

    test('carries version and publishedAt through untouched', () {
      final dated = FetchedRelease(
        version: '9.9.9',
        publishedAt: DateTime.utc(2024, 6, 1),
      );
      final merged = dated.withNotes('notes', 'https://example.com');
      expect(merged.version, '9.9.9');
      expect(merged.publishedAt, DateTime.utc(2024, 6, 1));
    });

    test('fills a field that was null without disturbing the other', () {
      const noNotes = FetchedRelease(version: '1.0.0', url: 'https://a/b');
      final merged = noNotes.withNotes('now has notes', null);
      expect(merged.notesMd, 'now has notes');
      expect(merged.url, 'https://a/b');
    });
  });
}
