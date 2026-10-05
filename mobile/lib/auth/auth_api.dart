import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models/user.dart';

/// Override with `--dart-define=API_BASE_URL=http://host:port`.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://192.168.0.135:3000',
);

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

class AuthApi {
  AuthApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Future<AuthSession> signup({
    required String name,
    required String email,
    required String password,
    required UserRole role,
    required bool hasDisability,
  }) async {
    final json = await _send('POST', '/api/auth/signup', body: {
      'name': name,
      'email': email,
      'password': password,
      'role': role.name,
      'hasDisability': hasDisability,
    });
    return AuthSession.fromJson(json);
  }

  Future<AuthSession> login({required String email, required String password}) async {
    final json = await _send('POST', '/api/auth/login', body: {
      'email': email,
      'password': password,
    });
    return AuthSession.fromJson(json);
  }

  Future<User> me(String token) async {
    final json = await _send('GET', '/api/auth/me', token: token);
    return User.fromJson(json['user'] as Map<String, dynamic>);
  }

  /// Admin only.
  Future<List<Employee>> employees(String token) async {
    final json = await _send('GET', '/api/users/employees', token: token);
    return [
      for (final e in json['employees'] as List<dynamic>)
        Employee.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final request = http.Request(method, Uri.parse('$apiBaseUrl$path'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      });
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on SocketException {
      throw const ApiException('Cannot reach the server. Check your Wi-Fi connection.');
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.');
    } on http.ClientException {
      throw const ApiException('Cannot reach the server. Check your Wi-Fi connection.');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      data = const {};
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return data;
    throw ApiException(
      data['message'] as String? ?? 'Something went wrong (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }
}
