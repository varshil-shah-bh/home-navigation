import 'package:flutter/widgets.dart';

import 'auth_api.dart';
import 'auth_storage.dart';
import 'models/user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthController extends ChangeNotifier {
  AuthController({AuthApi? api, AuthStorage? storage})
      : _api = api ?? AuthApi(),
        _storage = storage ?? const AuthStorage();

  final AuthApi _api;
  final AuthStorage _storage;

  AuthStatus _status = AuthStatus.unknown;
  AuthSession? _session;

  AuthStatus get status => _status;
  User? get user => _session?.user;
  String? get token => _session?.token;

  /// Restores a saved session so the user stays signed in across launches.
  Future<void> restore() async {
    final saved = await _storage.read();
    if (saved == null) {
      _setSession(null);
      return;
    }
    _setSession(saved);

    // Refresh the profile in the background; only sign out if the token is rejected.
    try {
      final fresh = await _api.me(saved.token);
      _session = AuthSession(token: saved.token, user: fresh);
      await _storage.saveUser(fresh);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isUnauthorized) await logout();
    }
  }

  Future<void> login({required String email, required String password}) async {
    final session = await _api.login(email: email.trim(), password: password);
    await _storage.save(session);
    _setSession(session);
  }

  Future<void> signup({
    required String name,
    required String email,
    required String password,
    required UserRole role,
    required bool hasDisability,
  }) async {
    final session = await _api.signup(
      name: name.trim(),
      email: email.trim(),
      password: password,
      role: role,
      hasDisability: hasDisability,
    );
    await _storage.save(session);
    _setSession(session);
  }

  Future<void> logout() async {
    await _storage.clear();
    _setSession(null);
  }

  void _setSession(AuthSession? session) {
    _session = session;
    _status = session == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
    notifyListeners();
  }
}

class AuthScope extends InheritedNotifier<AuthController> {
  const AuthScope({super.key, required AuthController controller, required super.child})
      : super(notifier: controller);

  static AuthController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AuthScope>()!.notifier!;
}
