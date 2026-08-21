/// A pure-Dart change notifier with the same contract as Flutter's
/// `ChangeNotifier`, existing so [Store] — and through it the whole engine —
/// can run on the plain Dart VM, where `package:flutter` (via `dart:ui`) is
/// unavailable and `dart run bin/server.dart` must still work. The UI side
/// bridges to the widget tree with `NotifierBuilder` (lib/ui/app.dart)
/// instead of `ListenableBuilder`, which is the one Flutter API this
/// replacement gives up.
class StoreListenable {
  final List<void Function()> _listeners = [];
  bool _disposed = false;

  void addListener(void Function() listener) {
    assert(!_disposed);
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    assert(!_disposed);
    // A copy, so a listener that adds or removes listeners (or triggers a
    // nested notification) never mutates the list mid-iteration — the same
    // reentrancy guarantee Flutter's ChangeNotifier documents.
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}

/// A single observable value over [StoreListenable] — the pure-Dart stand-in
/// for Flutter's `ValueNotifier`, for state (like the web client's last sync
/// error) that both pure sync code and widgets need to share.
class ValueCell<T> extends StoreListenable {
  ValueCell(this._value);

  T _value;
  T get value => _value;
  set value(T next) {
    // No-op when unchanged, so a repeated identical assignment (a cleared
    // error set to null again, the same sync error re-recorded) does not
    // churn a rebuild.
    if (_value == next) return;
    _value = next;
    notifyListeners();
  }
}
