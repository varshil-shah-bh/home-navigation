import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../map/map_painter.dart';
import '../auth_api.dart';
import '../auth_controller.dart';
import '../models/user.dart';
import '../validators.dart';
import 'auth_widgets.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  UserRole _role = UserRole.employee;
  bool _hasDisability = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await AuthScope.of(context).signup(
        name: _name.text,
        email: _email.text,
        password: _password.text,
        role: _role,
        hasDisability: _hasDisability,
      );
      TextInput.finishAutofillContext();
      // The auth gate below now shows the app; drop this pushed route.
      navigator.popUntil((route) => route.isFirst);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create account',
      subtitle: 'Join to start navigating your home',
      showBack: true,
      footer: AuthSwitchPrompt(
        prompt: 'Already have an account?',
        action: 'Sign in',
        onTap: () => Navigator.of(context).maybePop(),
      ),
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ErrorBanner(_error!),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                validator: validateName,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                validator: validateEmail,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _password,
                validator: validatePassword,
                autofillHints: const [AutofillHints.newPassword],
              ),
              const SizedBox(height: 24),
              const _SectionLabel('I am signing up as'),
              const SizedBox(height: 10),
              SegmentedButton<UserRole>(
                segments: const [
                  ButtonSegment(
                    value: UserRole.employee,
                    label: Text('Employee'),
                    icon: Icon(Icons.badge_outlined),
                  ),
                  ButtonSegment(
                    value: UserRole.admin,
                    label: Text('Admin'),
                    icon: Icon(Icons.admin_panel_settings_outlined),
                  ),
                ],
                selected: {_role},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              const SizedBox(height: 24),
              _DisabilityTile(
                value: _hasDisability,
                onChanged: (v) => setState(() => _hasDisability = v),
              ),
              const SizedBox(height: 28),
              PrimaryButton(label: 'Create account', loading: _loading, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: GColors.text,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _DisabilityTile extends StatelessWidget {
  const _DisabilityTile({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: value ? const Color(0xFFE8F0FE) : const Color(0xFFF8F9FA),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: value ? GColors.blue : const Color(0xFFE8EAED)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        secondary: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: value ? GColors.blue : Colors.white,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.accessible_rounded,
            color: value ? Colors.white : GColors.textMuted,
          ),
        ),
        title: const Text(
          'Person with a disability',
          style: TextStyle(fontWeight: FontWeight.w600, color: GColors.text),
        ),
        subtitle: const Text(
          'Helps us tailor routes and accessibility features',
          style: TextStyle(fontSize: 12.5, color: GColors.textMuted),
        ),
      ),
    );
  }
}
