enum UserRole {
  employee('Employee'),
  admin('Admin');

  const UserRole(this.label);

  final String label;

  static UserRole fromJson(String value) =>
      values.firstWhere((r) => r.name == value, orElse: () => UserRole.employee);
}

class User {
  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.hasDisability,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final UserRole role;
  final bool hasDisability;
  final DateTime createdAt;

  bool get isAdmin => role == UserRole.admin;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        role: UserRole.fromJson(json['role'] as String),
        hasDisability: json['hasDisability'] as bool,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role.name,
        'hasDisability': hasDisability,
        'createdAt': createdAt.toIso8601String(),
      };
}

class AuthSession {
  const AuthSession({required this.token, required this.user});

  final String token;
  final User user;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        token: json['token'] as String,
        user: User.fromJson(json['user'] as Map<String, dynamic>),
      );
}
