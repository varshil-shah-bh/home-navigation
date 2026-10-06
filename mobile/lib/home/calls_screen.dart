import 'package:flutter/material.dart';

import '../auth/auth_api.dart';
import '../auth/models/user.dart';
import '../call/call_controller.dart';
import '../live/live_location_client.dart';
import '../map/map_painter.dart';

/// Admin screen listing employees; only those currently online can be called.
class CallsScreen extends StatefulWidget {
  const CallsScreen({
    super.key,
    required this.token,
    required this.client,
    required this.call,
    this.onSignOut,
  });

  final String token;
  final LiveLocationClient client;
  final CallController call;
  final VoidCallback? onSignOut;

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  final _api = AuthApi();
  List<Employee>? _employees;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.employees(widget.token);
      if (!mounted) return;
      setState(() {
        _employees = list;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Call employees',
          style: TextStyle(color: GColors.text, fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, color: GColors.textMuted),
            onPressed: _load,
          ),
          if (widget.onSignOut != null)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout_rounded, color: GColors.redDark),
              onPressed: widget.onSignOut,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.client, widget.call]),
        builder: (context, _) => _body(),
      ),
    );
  }

  Widget _body() {
    final employees = _employees;
    if (employees == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      size: 48,
                      color: GColors.textMuted,
                    ),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(120, 44),
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
    }
    if (employees.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 56, color: GColors.wall),
            SizedBox(height: 8),
            Text(
              'No employees yet',
              style: TextStyle(color: GColors.textMuted),
            ),
          ],
        ),
      );
    }

    final connected = widget.client.state == LiveConnection.connected;
    final byName = [...employees]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final online = [
      for (final e in byName)
        if (widget.client.isOnline(e.id)) e,
    ];
    final offline = [
      for (final e in byName)
        if (!widget.client.isOnline(e.id)) e,
    ];

    return Column(
      children: [
        if (!connected)
          Container(
            width: double.infinity,
            color: const Color(0xFFFCE8E6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Row(
              children: [
                Icon(Icons.wifi_off_rounded, size: 18, color: GColors.redDark),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Not connected to the server. Calls are unavailable.',
                    style: TextStyle(
                      color: GColors.redDark,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _Summary(online: online.length, total: employees.length),
                if (online.isNotEmpty) ...[
                  const _SectionHeader('Online'),
                  for (final e in online) _tile(e, online: true),
                ],
                if (offline.isNotEmpty) ...[
                  const _SectionHeader('Offline'),
                  for (final e in offline) _tile(e, online: false),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(Employee e, {required bool online}) {
    return _EmployeeTile(
      employee: e,
      online: online,
      onCall: online && widget.call.isIdle
          ? () => widget.call.startCall(userId: e.id, name: e.name)
          : null,
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.online, required this.total});

  final int online;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GColors.blue,
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [GColors.blue, GColors.blueDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Colors.white24,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.groups_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$online online',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'of $total ${total == 1 ? 'employee' : 'employees'}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: GColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({
    required this.employee,
    required this.online,
    required this.onCall,
  });

  final Employee employee;
  final bool online;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final e = employee;
    final assist = e.hasDisability;
    final accent = assist ? GColors.assist : GColors.blue;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EAED)),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: online
                    ? accent.withValues(alpha: 0.12)
                    : const Color(0xFFF1F3F4),
                child: assist
                    ? Icon(
                        Icons.accessible_rounded,
                        color: online ? accent : GColors.textMuted,
                      )
                    : Text(
                        e.name.characters.first.toUpperCase(),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: online ? accent : GColors.textMuted,
                        ),
                      ),
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: online ? GColors.green : GColors.wall,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  online ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: online ? GColors.green : GColors.textMuted,
                    fontSize: 13,
                  ),
                ),
                if (assist) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: GColors.assist.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Needs assistance',
                      style: TextStyle(
                        color: GColors.assist,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton.filled(
            tooltip: online ? 'Call ${e.name}' : '${e.name} is offline',
            style: IconButton.styleFrom(
              backgroundColor: GColors.green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFF1F3F4),
              disabledForegroundColor: GColors.wall,
              fixedSize: const Size(46, 46),
            ),
            icon: const Icon(Icons.call),
            onPressed: onCall,
          ),
        ],
      ),
    );
  }
}
