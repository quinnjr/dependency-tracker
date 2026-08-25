import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../mcp/transport.dart' show constantTimeEquals;

/// Hand-rolled HS256 JWTs — deliberately. One algorithm, no negotiation
/// surface: [verifyJwt] ignores the token's own `alg` header entirely and
/// recomputes an HMAC-SHA256 signature, which is precisely what makes
/// alg-confusion (`alg:none`, RS256-as-HS256) attacks structurally
/// impossible rather than merely rejected.

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String signJwt(Map<String, Object?> claims, List<int> key) {
  final header = _b64(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final payload = _b64(utf8.encode(jsonEncode(claims)));
  final sig = _b64(
    Hmac(sha256, key).convert(utf8.encode('$header.$payload')).bytes,
  );
  return '$header.$payload.$sig';
}

/// Returns the claims, or null for any defect: bad shape, bad signature,
/// undecodable payload, missing or passed `exp`. Expiry is mandatory — a
/// token that cannot expire is a bug in the signer, not a longer session.
Map<String, Object?>? verifyJwt(
  String token,
  List<int> key, {
  DateTime Function()? now,
}) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  final expected = _b64(
    Hmac(sha256, key).convert(utf8.encode('${parts[0]}.${parts[1]}')).bytes,
  );
  if (!constantTimeEquals(expected, parts[2])) return null;
  final Map<String, Object?> claims;
  try {
    claims =
        (jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
                )
                as Map)
            .cast<String, Object?>();
  } catch (_) {
    return null;
  }
  final exp = claims['exp'];
  final t = (now ?? DateTime.now)();
  if (exp is! int || t.millisecondsSinceEpoch ~/ 1000 >= exp) return null;
  return claims;
}
