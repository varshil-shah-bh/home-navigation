final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? validateEmail(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return 'Email is required';
  if (!_emailPattern.hasMatch(v)) return 'Enter a valid email';
  return null;
}

String? validatePassword(String? value) {
  final v = value ?? '';
  if (v.isEmpty) return 'Password is required';
  if (v.length < 8) return 'Use at least 8 characters';
  if (v.length > 72) return 'Use at most 72 characters';
  return null;
}

String? validateName(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return 'Name is required';
  if (v.length < 2) return 'Name is too short';
  if (v.length > 100) return 'Name is too long';
  return null;
}
