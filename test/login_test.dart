import 'package:deptracker/bootstrap/app_resources.dart';
import 'package:deptracker/notify.dart';
import 'package:deptracker/ui/login.dart';
import 'package:deptracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuth implements AuthController {
  _FakeAuth({this.zeroUsers = false, this.registrationOpen = true});

  @override
  final StoreListenable changes = StoreListenable();

  @override
  bool authenticated = false;
  @override
  String? username;
  @override
  String? role;
  @override
  bool zeroUsers;
  @override
  bool registrationOpen;

  final calls = <String>[];
  String? nextError;

  @override
  Future<String?> login(String username, String password) async {
    calls.add('login:$username');
    return nextError;
  }

  @override
  Future<String?> register(String username, String password) async {
    calls.add('register:$username');
    return nextError;
  }

  @override
  Future<void> logout() async => calls.add('logout');

  @override
  Future<void> setRegistrationOpen(bool open) async =>
      calls.add('setRegistrationOpen:$open');
}

Widget screen(AuthController auth) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: LoginScreen(auth: auth),
);

void main() {
  testWidgets('zero users gets the create-first-admin-account form', (
    tester,
  ) async {
    final auth = _FakeAuth(zeroUsers: true);
    await tester.pumpWidget(screen(auth));

    expect(find.textContaining('becomes the admin account'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('login-username')), 'owner');
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'a-strong-password',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(auth.calls, ['register:owner']);
  });

  testWidgets('with accounts, the form signs in and renders failures inline', (
    tester,
  ) async {
    final auth = _FakeAuth()..nextError = 'invalid credentials';
    await tester.pumpWidget(screen(auth));

    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('login-username')), 'joseph');
    await tester.enterText(find.byKey(const Key('login-password')), 'x');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(auth.calls, ['login:joseph']);
    expect(find.text('invalid credentials'), findsOneWidget);
  });

  testWidgets('the register toggle appears only while registration is open', (
    tester,
  ) async {
    await tester.pumpWidget(screen(_FakeAuth(registrationOpen: false)));
    expect(find.text('Register instead'), findsNothing);

    await tester.pumpWidget(screen(_FakeAuth()));
    expect(find.text('Register instead'), findsOneWidget);

    await tester.tap(find.text('Register instead'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
  });
}
