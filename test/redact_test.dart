import 'package:deptracker/redact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(clearSecrets);

  test('replaces a registered secret anywhere in the text', () {
    registerSecret('ghp_abcdefghijklmnop');
    expect(
      redact('GET failed: Bearer ghp_abcdefghijklmnop rejected'),
      'GET failed: Bearer «redacted» rejected',
    );
  });

  test('replaces every occurrence', () {
    registerSecret('ghp_abcdefghijklmnop');
    final out = redact('ghp_abcdefghijklmnop and ghp_abcdefghijklmnop');
    expect(out, '«redacted» and «redacted»');
  });

  test('handles multiple registered secrets', () {
    registerSecret('ghp_abcdefghijklmnop');
    registerSecret('mcp_tok_zyxwvutsrqponml');
    expect(
      redact('ghp_abcdefghijklmnop / mcp_tok_zyxwvutsrqponml'),
      '«redacted» / «redacted»',
    );
  });

  test('ignores null and empty registrations', () {
    registerSecret(null);
    registerSecret('');
    expect(redact('nothing to do'), 'nothing to do');
  });

  test('ignores implausibly short secrets so common words survive', () {
    registerSecret('abc');
    expect(redact('abcdef'), 'abcdef');
  });

  test('is safe when the secret contains regex metacharacters', () {
    registerSecret(r'tok+en.with*meta(chars)');
    expect(redact(r'value=tok+en.with*meta(chars);'), 'value=«redacted»;');
  });

  test('leaves text alone when nothing is registered', () {
    expect(redact('404 Not Found'), '404 Not Found');
  });
}
