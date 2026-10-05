import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/auth_controller.dart';
import 'auth/screens/login_screen.dart';
import 'ble/ble_permissions.dart';
import 'map/map_painter.dart';
import 'map/map_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = AuthController()..restore();
  runApp(HomePocApp(auth: auth));
  unawaited(requestBlePermissions());
}

class HomePocApp extends StatelessWidget {
  const HomePocApp({super.key, required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE8EAED)),
    );

    return AuthScope(
      controller: auth,
      child: MaterialApp(
        title: 'Home Map POC',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: GColors.blue,
            primary: GColors.blue,
            surface: Colors.white,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: GColors.land,
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF8F9FA),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            prefixIconColor: GColors.textMuted,
            labelStyle: const TextStyle(color: GColors.textMuted),
            border: inputBorder,
            enabledBorder: inputBorder,
            focusedBorder: inputBorder.copyWith(
              borderSide: const BorderSide(color: GColors.blue, width: 1.6),
            ),
            errorBorder: inputBorder.copyWith(
              borderSide: const BorderSide(color: GColors.red),
            ),
            focusedErrorBorder: inputBorder.copyWith(
              borderSide: const BorderSide(color: GColors.red, width: 1.6),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: GColors.blue,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          segmentedButtonTheme: SegmentedButtonThemeData(
            style: SegmentedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              selectedBackgroundColor: const Color(0xFFE8F0FE),
              selectedForegroundColor: GColors.blueDark,
              side: const BorderSide(color: Color(0xFFDADCE0)),
            ),
          ),
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    return switch (auth.status) {
      AuthStatus.unknown => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      AuthStatus.authenticated => Scaffold(body: MapView(onSignOut: auth.logout)),
      AuthStatus.unauthenticated => const LoginScreen(),
    };
  }
}
